#!/usr/bin/env bash
set -Eeuo pipefail
# These assertions are bare `grep -Fq` under `set -e`, so a stale expectation
# ends the run with an exit code and not one word about where. This makes each
# of them name itself on the way out. Guarded on errexit still being on,
# because a non-zero exit inside a deliberate `set +e` block is an expected
# result being collected, not an assertion giving up.
trap 'case $- in *e*) printf "%s: line %s gave up: %s\n" "${0##*/}" "$LINENO" "$BASH_COMMAND" >&2 ;; esac' ERR

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
install -d -m 0755 "$TMP/repo" "$TMP/package"

while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'pkgname = %s\npkgver = 1.0-1\narch = any\n' "$name" \
    >"$TMP/package/.PKGINFO"
  bsdtar -cf "$TMP/repo/${name}-1.0-1-any.pkg.tar.zst" \
    -C "$TMP/package" .PKGINFO
done <"$ROOT/installer/expected-packages.txt"
printf '%s\n' 'local repository database' >"$TMP/repo/kibaos.db.tar.gz"
printf '%s\n' 'must not enter the image' >"$TMP/repo/private-signing-key.txt"
(cd "$TMP/repo" && sha256sum kibaos.db.tar.gz >SHA256SUMS)

if env \
  KIBAOS_ARCH_SNAPSHOT=2026/02/30 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_invalid_date" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/invalid_date.out" 2>&1; then
  echo 'impossible snapshot date unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'build-iso: KIBAOS_ARCH_SNAPSHOT is not a real calendar date' \
  "$TMP/invalid_date.out"
[[ ! -e $TMP/work_invalid_date ]]

if env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_MAX_ISO_BYTES=invalid \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_invalid" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/invalid_max_bytes.out" 2>&1; then
  echo 'non-numeric KIBAOS_MAX_ISO_BYTES unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'build-iso: KIBAOS_MAX_ISO_BYTES must be a positive integer' "$TMP/invalid_max_bytes.out"
[[ ! -e $TMP/work_invalid ]]

if env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_GUI_RELEASE=2 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_invalid_gui" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/invalid_gui.out" 2>&1; then
  echo 'invalid KIBAOS_GUI_RELEASE unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'build-iso: KIBAOS_GUI_RELEASE must be 0 or 1' "$TMP/invalid_gui.out"
[[ ! -e $TMP/work_invalid_gui ]]

if env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_GUI_RELEASE=1 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_gui_development" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/gui_development.out" 2>&1; then
  echo 'development-channel GUI release unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'build-iso: GUI releases require candidate or public KIBAOS_RELEASE_CHANNEL' \
  "$TMP/gui_development.out"
[[ ! -e $TMP/work_gui_development ]]

# A release build must not silently claim provenance when signatures are
# required and the build is not allowed to make its own key. Stage-only mode
# still validates this policy before touching the work directory, so this is
# safe to exercise without mkarchiso or a keyring.
if env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_REQUIRE_ISO_SIGNATURE=1 \
  KIBAOS_ISO_RANDOM_SIGNING_KEY=0 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_unsigned_required" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/unsigned_required.out" 2>&1; then
  echo 'signature-required stage unexpectedly passed without a signing key' >&2
  exit 1
fi
grep -Fq 'KIBAOS_ISO_SIGNING_KEY is required when ISO signatures are required' \
  "$TMP/unsigned_required.out"
[[ ! -e $TMP/work_unsigned_required ]]

env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_RELEASE_CHANNEL=candidate \
  KIBAOS_GUI_RELEASE=1 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/stage.out"

staged=$TMP/work/profile/airootfs/opt/kibaos/repo
expected=$(grep -Evc '^[[:space:]]*(#|$)' "$ROOT/installer/expected-packages.txt")
actual=$(find "$staged" -maxdepth 1 -type f -name '*.pkg.tar.*' \
  ! -name '*.sig' | wc -l)
[[ $actual -eq $expected ]]
[[ ! -e $staged/private-signing-key.txt ]]
[[ -r $staged/packages.lock ]]
[[ -r $staged/SHA256SUMS ]]
[[ -r $staged/kibaos.db.tar.gz ]]
(cd "$staged" && sha256sum -c \
  <(awk '!/^#/ {print $1 "  " $2}' packages.lock)) >/dev/null
grep -Fxq reflector "$ROOT/installer/archiso/packages.x86_64"
grep -Fxq archlinux-keyring "$ROOT/installer/archiso/packages.x86_64"
# The graphical installer's whole toolkit, including the compositor. GTK 4 on
# a bare virtual console has nothing to draw on, so a package list with the
# toolkit and no compositor ships a front end that can never be displayed.
for package in gtk4 libadwaita python-gobject cage python-cairo ttf-jetbrains-mono; do
  grep -Fxq "$package" "$ROOT/installer/archiso/packages.x86_64"
done
[[ -r $TMP/work/profile/airootfs/etc/kibaos-installer/gui-release-manifest.json ]]
[[ -r $TMP/work/profile/airootfs/etc/kibaos-installer/gui-enabled ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-tui ]]
[[ ! -e $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer ]]
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-staging.sh ]]
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-wifi.sh ]]
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-keyboard.sh ]]
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-hardware.sh ]]
[[ -x $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-live-wl-guard ]]
[[ -r $TMP/work/profile/airootfs/etc/modprobe.d/kibaos-live-broadcom-wl.conf ]]
[[ -r $TMP/work/profile/airootfs/etc/udev/rules.d/60-kibaos-live-wl.rules ]]
grep -Fxq 'wifi.powersave=2' "$TMP/work/profile/airootfs/etc/NetworkManager/conf.d/90-kibaos-wifi.conf"
grep -Fxq DisableDownloadTimeout "$ROOT/installer/archiso/pacman.conf"
grep -Fq 'MAX_ISO_BYTES=${KIBAOS_MAX_ISO_BYTES:-4294967296}' "$ROOT/installer/build-iso.sh"
grep -Fq 'iso_bytes=' "$ROOT/installer/build-iso.sh"
grep -Fq 'package_count=' "$ROOT/installer/build-iso.sh"
grep -Fq 'package_bytes=' "$ROOT/installer/build-iso.sh"
grep -Fq 'RELEASE_CHANNEL=${KIBAOS_RELEASE_CHANNEL:-development}' "$ROOT/installer/build-iso.sh"
grep -Fq "printf 'release_channel=%s\\n' \"\$RELEASE_CHANNEL\"" "$ROOT/installer/build-iso.sh"
grep -Fq 'packages_lock_sha256=' "$ROOT/installer/build-iso.sh"
grep -Fq 'GUI_RELEASE=${KIBAOS_GUI_RELEASE:-0}' "$ROOT/installer/build-iso.sh"
grep -Fxq 'LocalFileSigLevel = Required' "$ROOT/installer/archiso/pacman.conf"
grep -Fxq 'LocalFileSigLevel = Required' \
  "$ROOT/installer/archiso/airootfs/etc/pacman.conf"
grep -Fxq 'LocalFileSigLevel = Optional' \
  "$TMP/work/profile/pacman.conf"
grep -Fxq 'LocalFileSigLevel = Optional' \
  "$TMP/work/profile/airootfs/etc/pacman.conf"
# A filesystem the picker offers has to be one the image can make. The engine
# refuses `--filesystem xfs` without mkfs.xfs, and the front ends hide what the
# image cannot make - so dropping xfsprogs does not break anything visibly, it
# just silently removes a choice this installer says it supports.
grep -Fxq 'xfsprogs' "$ROOT/installer/archiso/packages.x86_64" || {
  echo 'test-build-iso-stage: the image cannot make an xfs root, so the installer cannot offer one' >&2
  exit 1
}

# The default profile is intentionally text-only. This second stage catches a
# future change that makes the graphical payload or its runtime closure leak
# into a routine development build.
env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work_text_only" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/text-only.out"
text_profile=$TMP/work_text_only/profile
[[ -x $text_profile/airootfs/usr/local/sbin/kibaos-installer-tui ]]
[[ ! -e $text_profile/airootfs/usr/local/sbin/kibaos-installer ]]
[[ -r $text_profile/airootfs/usr/local/lib/kibaos/kibaos-staging.sh ]]
[[ -r $text_profile/airootfs/usr/local/lib/kibaos/kibaos-wifi.sh ]]
[[ -r $text_profile/airootfs/usr/local/lib/kibaos/kibaos-keyboard.sh ]]
[[ ! -e $text_profile/airootfs/usr/local/sbin/kibaos-installer-gui ]]
[[ ! -e $text_profile/airootfs/usr/local/sbin/kibaos-installer-gui-bridge ]]
[[ ! -e $text_profile/airootfs/etc/kibaos-installer/gui-enabled ]]
[[ ! -e $text_profile/airootfs/etc/kibaos-installer/gui-release-manifest.json ]]
for package in cage gtk4 libadwaita python-cairo python-gobject ttf-jetbrains-mono; do
  ! grep -Fxq "$package" "$text_profile/packages.x86_64" || {
    echo "test-build-iso-stage: GUI runtime package $package leaked into text-only profile" >&2
    exit 1
  }
done
! grep -Fq '/usr/local/sbin/kibaos-installer-gui' "$text_profile/profiledef.sh"
! grep -Fq '/usr/local/lib/kibaos/kibaos_gui/' "$text_profile/profiledef.sh"

# The two packages the speech boot entry is made of. Same argument as xfsprogs
# above: without them the entry still appears in the menu, still boots, and
# says nothing, which is a worse failure than not offering it. espeakup is the
# console reader the entry starts; brltty is what a braille display needs, and
# its presence is also what makes the text installer choose its plain
# rendering without being asked.
# The keyboard, which the installer reads out of a directory rather than asking
# a command about.
#
# `kibaos_valid_keymap` looks in /usr/share/kbd/keymaps, `loadkeys` applies the
# choice to the live console, and `setfont` is how the text installer honours
# a text size. All three come from kbd, which was not on the image: on a real
# ISO every keymap was rejected and the picker offered nothing.
#
# The test suite could not see it, and that is the point of checking here. The
# unit tests point KIBAOS_KEYMAP_DIR at a fixture, so the fixture made them
# pass while the image lacked the package entirely. A path the installer reads
# at runtime is a package the image has to carry, and only this test is looking
# at the image.
grep -Fxq 'kbd' "$ROOT/installer/archiso/packages.x86_64" || {
  echo 'test-build-iso-stage: kbd is missing, so no keyboard layout can be chosen' >&2
  exit 1
}
grep -Fxq 'terminus-font' "$ROOT/installer/archiso/packages.x86_64" || {
  echo 'test-build-iso-stage: terminus-font is missing, so text size does nothing on the console' >&2
  exit 1
}

for _access in espeakup brltty; do
  grep -Fxq "$_access" "$ROOT/installer/archiso/packages.x86_64" || {
    echo "test-build-iso-stage: $_access is missing, so the speech entry would boot to silence" >&2
    exit 1
  }
done

# The boot menu, which is the first screen anyone sees.
#
# One entry per front end, each naming itself on the kernel command line, and
# the default one selected in loader.conf by a filename that exists. A boot
# menu whose default points at a missing entry is a machine that boots to a
# firmware screen, which is the one failure nobody can debug from the console.
entries=$ROOT/installer/archiso/efiboot/loader/entries
for entry in gui speech text safe serial none; do
  grep -lq "kibaos.installer=$entry" "$entries"/*.conf || {
    echo "test-build-iso-stage: no boot entry asks for the $entry front end" >&2
    exit 1
  }
done
# The serial entry, and the pair of conditions that keep it from fighting the
# console one. Both units are enabled on the image, so the only thing stopping
# two installers drawing over one machine is that each refuses the other's
# command line. That is a condition in a unit file, which is the sort of thing
# that gets deleted during a tidy-up and produces a symptom nobody can explain.
serial_unit=$ROOT/installer/archiso/airootfs/etc/systemd/system/kibaos-installer-serial.service
console_unit=$ROOT/installer/archiso/airootfs/etc/systemd/system/kibaos-installer-autostart.service
grep -Fxq 'ConditionKernelCommandLine=kibaos.installer=serial' "$serial_unit" || {
  echo 'test-build-iso-stage: the serial unit would start on every boot' >&2
  exit 1
}
grep -Fxq 'ConditionKernelCommandLine=!kibaos.installer=serial' "$console_unit" || {
  echo 'test-build-iso-stage: the console unit would also start on a serial boot' >&2
  exit 1
}
if grep -Eq '^(After|Wants)=.*dev-tty1\.device' "$console_unit"; then
  echo 'test-build-iso-stage: waiting for tty1 can prevent the installer from starting' >&2
  exit 1
fi
# The line that decides whether the graphical installer can start at all.
#
# plymouth holds DRM master until it is told to go, and `cage` cannot become
# DRM master while it is there, so the whole renderer negotiation fails for a
# reason that is not about graphics, behind the boot screen that is causing it.
# Every getty on the image carries this ordering. This unit replaces the getty
# on tty1 and shipped without it, and the symptom was the default boot entry
# showing a boot screen, then black, then the text installer.
grep -Fxq 'After=plymouth-quit.service' "$console_unit" || {
  echo 'test-build-iso-stage: the installer can start before the boot screen has gone' >&2
  exit 1
}
# The seat, which is the other thing that has to exist before a compositor can
# start and the one that stopped this working at all. libseat can get a seat
# from seatd or from a logind session, and a systemd oneshot has no logind
# session, so on this image it has to be seatd. Both units are wanted by
# multi-user.target, so without the ordering they start in whatever order
# systemd picks, and losing that race costs the whole graphical installer.
grep -Fxq 'After=seatd.service' "$console_unit" || {
  echo 'test-build-iso-stage: the installer can start before there is a seat to open' >&2
  exit 1
}
[[ -L $TMP/work/profile/airootfs/etc/systemd/system/multi-user.target.wants/seatd.service ]] || {
  echo 'test-build-iso-stage: seatd is on the image and nothing starts it' >&2
  exit 1
}
grep -Fq 'TTYPath=/dev/ttyS0' "$serial_unit" || {
  echo 'test-build-iso-stage: the serial unit does not put the installer on the serial line' >&2
  exit 1
}
[[ -L $TMP/work/profile/airootfs/etc/systemd/system/multi-user.target.wants/kibaos-installer-serial.service ]] || {
  echo 'test-build-iso-stage: the serial unit is staged but never enabled' >&2
  exit 1
}

for entry in "$entries"/*.conf; do
  grep -Fq 'cow_spacesize=4G' "$entry" || {
    echo "test-build-iso-stage: ${entry##*/} does not give the live overlay room to prefetch" >&2
    exit 1
  }
  grep -Fq 'archisosearchuuid=%ARCHISO_UUID%' "$entry" || {
    echo "test-build-iso-stage: ${entry##*/} would not find its own image" >&2
    exit 1
  }
done
default_entry=$(awk '$1 == "default" {print $2; exit}' \
  "$ROOT/installer/archiso/efiboot/loader/loader.conf")
[[ -r $entries/$default_entry ]] || {
  echo "test-build-iso-stage: the default boot entry $default_entry does not exist" >&2
  exit 1
}
grep -Fq 'kibaos.installer=gui' "$entries/$default_entry" || {
  echo 'test-build-iso-stage: the default boot entry does not start the graphical installer' >&2
  exit 1
}

# And the half that reads it back. An entry that names a front end nothing acts
# on is a boot menu that lies.
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-autostart ]] || {
  echo 'test-build-iso-stage: the boot menu choice is never read on the image' >&2
  exit 1
}
[[ -r $TMP/work/profile/airootfs/root/.bash_profile ]] || {
  echo 'test-build-iso-stage: live console profile is missing' >&2
  exit 1
}
[[ -r $TMP/work/profile/airootfs/etc/systemd/system/kibaos-installer-autostart.service ]] || {
  echo 'test-build-iso-stage: the boot-selected installer service is missing' >&2
  exit 1
}
[[ -L $TMP/work/profile/airootfs/etc/systemd/system/multi-user.target.wants/kibaos-installer-autostart.service ]] || {
  echo 'test-build-iso-stage: the boot-selected installer service is not enabled' >&2
  exit 1
}
[[ -L $TMP/work/profile/airootfs/etc/systemd/system/systemd-firstboot.service ]] || {
  echo 'test-build-iso-stage: generic Arch first-boot prompt is not masked' >&2
  exit 1
}
[[ $(readlink "$TMP/work/profile/airootfs/etc/systemd/system/systemd-firstboot.service") == /dev/null ]] || {
  echo 'test-build-iso-stage: first-boot mask does not point to /dev/null' >&2
  exit 1
}
grep -Fq 'ExecStart=/usr/local/sbin/kibaos-installer-autostart' \
  "$TMP/work/profile/airootfs/etc/systemd/system/kibaos-installer-autostart.service"
grep -Fq 'Before=getty@tty1.service' \
  "$TMP/work/profile/airootfs/etc/systemd/system/kibaos-installer-autostart.service"
! grep -Eq '^[[:space:]]*/usr/local/sbin/kibaos-installer-autostart([[:space:]]|$)' \
  "$TMP/work/profile/airootfs/root/.bash_profile" || {
  echo 'test-build-iso-stage: login shell still launches a second installer' >&2
  exit 1
}
grep -Fq -- '--noissue' "$ROOT/installer/archiso/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf"
for entry in "$entries"/*.conf; do
  grep -Eq '(^|[[:space:]])quiet([[:space:]]|$)' "$entry" || {
    echo "test-build-iso-stage: ${entry##*/} leaves boot chatter visible" >&2
    exit 1
  }
done
grep -Fxq 'editor no' "$ROOT/installer/archiso/efiboot/loader/loader.conf"
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-refresh-mirrors ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-install-failure ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-secure-boot-sign ]]
[[ -r $TMP/work/profile/airootfs/usr/local/share/kibaos/90-kibaos-secure-boot.hook ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-tui ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-gui ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-gui-bridge ]]
[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-installer-start ]]
# Every module in the source package, not a list written out here. A module
# that exists and is not staged is an installer that raises ImportError on the
# image and nowhere else, and a hand-maintained list is exactly how that ships.
for module in "$ROOT"/installer/lib/kibaos_gui/*.py; do
  module=${module##*/}
  [[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos_gui/$module ]] || {
    echo "test-build-iso-stage: kibaos_gui/$module is not staged onto the image" >&2
    exit 1
  }
  grep -Fq "\"/usr/local/lib/kibaos/kibaos_gui/$module\"" \
    "$ROOT/installer/archiso/profiledef.sh" || {
    echo "test-build-iso-stage: kibaos_gui/$module has no ownership entry in profiledef.sh" >&2
    exit 1
  }
done
for _sheet in "$ROOT"/installer/lib/kibaos_gui/*.css; do
  _sheet=${_sheet##*/}
  [[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos_gui/$_sheet ]] || {
    echo "test-build-iso-stage: kibaos_gui/$_sheet is not staged onto the image" >&2
    exit 1
  }
  grep -Fq "\"/usr/local/lib/kibaos/kibaos_gui/$_sheet\"" \
    "$ROOT/installer/archiso/profiledef.sh" || {
    echo "test-build-iso-stage: kibaos_gui/$_sheet has no ownership entry in profiledef.sh" >&2
    exit 1
  }
done
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos_gui/theme.css ]]
[[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/kibaos-tips ]]
grep -Fq '/usr/local/lib/kibaos/kibaos-tips' "$ROOT/installer/archiso/profiledef.sh"
# The brand artwork has to reach the image, or the installer draws a window
# with no logo in it and the graphics test cannot see that from source.
[[ -r $TMP/work/profile/airootfs/usr/local/share/kibaos/kibaos-mark.png ]]
[[ -r $TMP/work/profile/airootfs/usr/local/share/kibaos/kibaos-wordmark.png ]]
# The wallpapers, every one the manifest names, at the mode the image expects.
#
# Derived from the manifest rather than counted, because the manifest is what
# the front end reads: a picture staged and not indexed is a picture nothing
# will ever show, and a picture indexed and not staged is a caption naming a
# file that is not there.
_wallpapers=$TMP/work/profile/airootfs/usr/local/share/kibaos/wallpapers
[[ -r $_wallpapers/manifest.tsv ]] ||
  { echo 'build-iso.sh does not stage the wallpaper manifest' >&2; exit 1; }
while IFS=$'\t' read -r _picture _rest; do
  [[ -n ${_picture:-} && ${_picture:0:1} != '#' ]] || continue
  [[ -r $_wallpapers/$_picture ]] ||
    { echo "build-iso.sh does not stage wallpapers/$_picture" >&2; exit 1; }
  _mode=$(stat -c '%a' "$_wallpapers/$_picture")
  [[ $_mode == 644 ]] ||
    { echo "wallpapers/$_picture staged as $_mode, not 644" >&2; exit 1; }
done < "$ROOT/installer/wallpapers/manifest.tsv"
# The Bible, every book the manifest names, at the mode the image expects, and
# the manifest itself. The interesting failure is not a missing file: it is an
# image carrying sixty six books, which is what three of the four candidate
# sources turned out to be, so the count is checked here as well as in
# `test-bible.sh`. The archive the text is made from must not be staged; it is
# a source, and two and a half megabytes the image would never open.
_bible=$TMP/work/profile/airootfs/usr/local/share/kibaos/bible
[[ -r $_bible/manifest.tsv ]] ||
  { echo 'build-iso.sh does not stage the Bible manifest' >&2; exit 1; }
_books=0
while IFS=$'\t' read -r _code _section _short _name _chapters _verses _book; do
  [[ -n ${_code:-} && ${_code:0:1} != '#' && -n ${_book:-} ]] || continue
  [[ -r $_bible/$_book ]] ||
    { echo "build-iso.sh does not stage bible/$_book" >&2; exit 1; }
  _mode=$(stat -c '%a' "$_bible/$_book")
  [[ $_mode == 644 ]] ||
    { echo "bible/$_book staged as $_mode, not 644" >&2; exit 1; }
  _books=$(( _books + 1 ))
done < "$ROOT/installer/bible/manifest.tsv"
(( _books == 80 )) ||
  { echo "the image carries $_books books, and the edition with the Apocrypha has 80" >&2; exit 1; }
[[ ! -e $_bible/eng-kjv_usfm.zip ]] ||
  { echo 'build-iso.sh stages the Bible source archive, which the image never reads' >&2; exit 1; }
# The boot screen, which is the one piece of this that nothing on this side of
# a real boot can execute. There is no way to run a plymouth script here, so
# what is checked instead is every joint it hangs from: the five files present,
# the theme name agreeing in the two places it is written, the package on the
# image, and the initramfs hook that carries the whole thing into the boot.
# Each of those failing alone produces the same symptom, a boot that quietly
# scrolls kernel messages instead, which looks like nothing was ever built.
_theme=$TMP/work/profile/airootfs/usr/share/plymouth/themes/kibaos
for _part in kibaos.plymouth kibaos.script field-0.png field-1.png field-2.png \
             kibaos-mark.png kibaos-wordmark.png; do
  [[ -r $_theme/$_part ]] ||
    { echo "build-iso.sh does not stage the boot screen's $_part" >&2; exit 1; }
  _mode=$(stat -c '%a' "$_theme/$_part")
  [[ $_mode == 644 ]] ||
    { echo "boot screen $_part staged as $_mode, not 644" >&2; exit 1; }
  grep -Fq "/usr/share/plymouth/themes/kibaos/$_part" \
    "$ROOT/installer/archiso/profiledef.sh" ||
    { echo "profiledef.sh has no permissions entry for the boot screen's $_part" >&2; exit 1; }
done
grep -Fq 'Theme=kibaos' \
  "$TMP/work/profile/airootfs/etc/plymouth/plymouthd.conf" ||
  { echo 'plymouthd.conf does not name the kibaos theme' >&2; exit 1; }
grep -Fq 'ShowDelay=0' \
  "$TMP/work/profile/airootfs/etc/plymouth/plymouthd.conf" ||
  { echo 'plymouthd.conf waits before showing the boot screen' >&2; exit 1; }
grep -Fxq 'plymouth' "$ROOT/installer/archiso/packages.x86_64" ||
  { echo 'the boot screen is themed and plymouth is not on the image' >&2; exit 1; }
# The hook, and its position. After `udev`, because it needs device nodes to
# find a graphics card, and a hook order that puts it first is a boot screen
# that never draws.
_hooks=$(grep '^HOOKS=' "$ROOT/installer/archiso/airootfs/etc/mkinitcpio.conf.d/archiso.conf")
[[ $_hooks == *"udev plymouth"* ]] ||
  { echo "the plymouth hook is not directly after udev: $_hooks" >&2; exit 1; }
# `splash` on the entries that have somebody looking at a screen, and off the
# three that do not. The speech entry is the one that matters: a splash there
# covers the console messages, which are the only thing anybody in that seat
# can be read aloud from.
for _entry in 01-kibaos-gui 03-kibaos-tui 04-kibaos-safe; do
  grep -q '^options .*[[:space:]]splash[[:space:]]' \
    "$entries/$_entry.conf" ||
    { echo "$_entry does not boot with splash" >&2; exit 1; }
done
for _entry in 02-kibaos-speech 05-kibaos-shell 06-kibaos-serial; do
  if grep -q '^options .*[[:space:]]splash[[:space:]]' \
    "$entries/$_entry.conf"; then
    echo "$_entry boots with splash and should not" >&2
    exit 1
  fi
done
# Every shell library in the source tree, not a list typed here. Both front
# ends source these by name and exit if one is missing, so a library added to
# the tree and forgotten in build-iso.sh is a text installer that will not
# start on the image and starts fine on the machine that built it. That has
# already happened once, to a GUI module, which is why the loop above derives
# its list the same way.
for _lib in "$ROOT"/installer/lib/kibaos-*.sh; do
  _name=$(basename "$_lib")
  [[ -r $TMP/work/profile/airootfs/usr/local/lib/kibaos/$_name ]] ||
    { echo "build-iso.sh does not stage lib/$_name" >&2; exit 1; }
  grep -Fq "/usr/local/lib/kibaos/$_name" "$ROOT/installer/archiso/profiledef.sh" ||
    { echo "profiledef.sh has no permissions entry for lib/$_name" >&2; exit 1; }
done
# Every program in bin/, derived the same way and for the same reason.
#
# The libraries have been checked this way for a while; the programs were a
# list typed by hand, and a program added to the tree and left out of it is a
# feature that works on every machine that built the image and on no machine
# that boots it. That is exactly what happened to the download rate sampler:
# the engine treats a missing sampler as "no meter", so the install succeeds,
# the screen is simply missing a line, and nothing anywhere says why.
while IFS= read -r _bin; do
  _name=$(basename "$_bin")
  _found=$(find "$TMP/work/profile/airootfs" -name "$_name" -type f -print -quit 2>/dev/null)
  [[ -n $_found ]] ||
    { echo "build-iso.sh does not stage bin/$_name onto the image" >&2; exit 1; }
  [[ -x $_found ]] ||
    { echo "bin/$_name is staged without the executable bit" >&2; exit 1; }
  grep -Fq "/$_name\"]=" "$ROOT/installer/archiso/profiledef.sh" ||
    { echo "profiledef.sh has no permissions entry for bin/$_name" >&2; exit 1; }
done < <(find "$ROOT/installer/bin" -maxdepth 1 -type f -perm -u+x -print | LC_ALL=C sort)

# Every systemd unit in units/, for the reason above and one more.
#
# The engine looks for the unit on the image first and falls back to a path
# relative to its own directory, which resolves to nothing on a real install.
# So an unstaged unit is not a broken install, it is an install that quietly
# skips the whole block: the machine boots, the accessibility settings are
# never confirmed, and nothing anywhere says why.
while IFS= read -r _unit; do
  _name=$(basename "$_unit")
  [[ -r $TMP/work/profile/airootfs/usr/local/share/kibaos/$_name ]] ||
    { echo "build-iso.sh does not stage units/$_name onto the image" >&2; exit 1; }
  grep -Fq "/usr/local/share/kibaos/$_name\"]=" "$ROOT/installer/archiso/profiledef.sh" ||
    { echo "profiledef.sh has no permissions entry for units/$_name" >&2; exit 1; }
done < <(find "$ROOT/installer/units" -maxdepth 1 -type f -name '*.service' -print | LC_ALL=C sort)

[[ -x $TMP/work/profile/airootfs/usr/local/sbin/kibaos-network-diagnostics ]]
grep -Fq -- 'root with no password' "$ROOT/installer/archiso/airootfs/etc/motd"
grep -Fq -- 'not copied to the installed system' "$ROOT/installer/archiso/airootfs/etc/motd"
grep -Fq '/usr/local/sbin/kibaos-installer-tui' "$ROOT/installer/archiso/profiledef.sh"
grep -Fq 'text)   "$START" --text' \
  "$ROOT/installer/archiso/airootfs/usr/local/sbin/kibaos-installer-autostart"
grep -Fq 'TUI=$(_find kibaos-installer-tui)' "$ROOT/installer/bin/kibaos-installer-start"
! grep -Fq 'kibaos-installer ' \
  "$ROOT/installer/archiso/airootfs/usr/local/sbin/kibaos-installer-autostart"
for staged in /usr/local/sbin/kibaos-installer-gui \
  /usr/local/sbin/kibaos-installer-gui-bridge \
  /usr/local/sbin/kibaos-installer-start \
  /usr/local/lib/kibaos/kibaos_gui/bridge.py \
  /usr/local/lib/kibaos/kibaos_gui/flow.py \
  /usr/local/lib/kibaos/kibaos_gui/app.py \
  /usr/local/lib/kibaos/kibaos_gui/theme.css \
  /usr/local/share/kibaos/kibaos-mark.png; do
  grep -Fq "$staged" "$ROOT/installer/archiso/profiledef.sh"
done
grep -Fq 'kibaos-installer-start' "$ROOT/installer/archiso/airootfs/etc/motd"
# The staged front end must resolve its libraries from the image, not from a
# source tree that will not exist on the installation media.
grep -Fq '/usr/local/lib/kibaos/$name' "$ROOT/installer/bin/kibaos-installer-tui"
grep -Fq '/usr/local/lib/kibaos/$name' "$ROOT/installer/bin/kibaos-installer-start"
grep -Fq '/usr/local/lib/kibaos' "$ROOT/installer/bin/kibaos-installer-gui"
grep -Fq '/usr/local/sbin/kibaos-installer-gui-bridge' \
  "$ROOT/installer/lib/kibaos_gui/bridge.py"
grep -Fq '/usr/local/sbin/kibaos-installer-tui' \
  "$ROOT/installer/bin/kibaos-installer-gui-bridge"
grep -Fq '/usr/local/sbin/kibaos-network-diagnostics' "$ROOT/installer/archiso/profiledef.sh"
[[ -L $TMP/work/profile/airootfs/etc/systemd/system/multi-user.target.wants/kibaos-refresh-mirrors.service ]]
[[ ! -e $TMP/work/profile/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service ]]

# Repository metadata is authenticated separately from the package lock when a
# verified release repository supplies SHA256SUMS. A tampered database must
# stop staging before mkarchiso can consume it.
printf '%s\n' 'tampered repository database' >>"$TMP/repo/kibaos.db.tar.gz"
if env \
  KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
  KIBAOS_REPO_DIR="$TMP/repo" \
  KIBAOS_ALLOW_UNSIGNED=1 \
  KIBAOS_INSTALLER_WORK_ROOT="$TMP/work-tampered" \
  "$ROOT/installer/build-iso.sh" --stage-only >"$TMP/tampered.out" 2>&1; then
  echo 'tampered repository metadata unexpectedly staged' >&2
  exit 1
fi
grep -Fq 'source repository SHA256SUMS verification failed' "$TMP/tampered.out"

echo 'installer ISO staging test: PASS'
