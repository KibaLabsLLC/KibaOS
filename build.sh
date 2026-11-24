#!/bin/bash
set -ex
KIBA_ARCH="x86_64"
export KIBA_ARCH
echo "=== KibaOS build target: $KIBA_ARCH ==="
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
grep -q '^alpm:' "$AIROOTFS/etc/passwd" 2>/dev/null||echo 'alpm:x:951:951::/var/cache/pacman/pkg:/usr/bin/nologin' >>"$AIROOTFS/etc/passwd"
grep -q '^alpm:' "$AIROOTFS/etc/group" 2>/dev/null||echo 'alpm:x:951:' >>"$AIROOTFS/etc/group"
grep -q '^alpm:' "$AIROOTFS/etc/shadow" 2>/dev/null||echo 'alpm:!*:19000::::::' >>"$AIROOTFS/etc/shadow"
mkdir -p "$AIROOTFS/var/cache/pacman/pkg"
chmod 755 "$AIROOTFS/var/cache/pacman" "$AIROOTFS/var/cache/pacman/pkg"
pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm
pacman -Su --noconfirm
pacman -S --noconfirm --needed \
base-devel git squashfs-tools libisoburn mtools dosfstools \
cmake ninja meson \
grub \
arch-install-scripts \
openssl curl imagemagick jq \
python-docutils
install_archiso(){
pacman -S --noconfirm --needed archiso
}
install_archiso
WORKDIR="/w"
ISO="kibaos-v$RUN_NUM"
PROFILE="$WORKDIR/kiba-profile"
AIROOTFS="$PROFILE/airootfs"
cd "$WORKDIR"
cp -r /usr/share/archiso/configs/releng/ "$PROFILE"
if [ -f "$PROFILE/airootfs/usr/lib/initcpio/install/archiso" ];then
sed -i '/11-dm-initramfs\.rules/d' \
"$PROFILE/airootfs/usr/lib/initcpio/install/archiso"
fi
mkdir -p "$AIROOTFS"
sed -i 's/^CheckSpace/#CheckSpace/' "$PROFILE/pacman.conf"
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' "$PROFILE/pacman.conf"
cat >"$PROFILE/profiledef.sh" <<'PROFILEDEF'
#!/usr/bin/env bash
iso_name="kibaos"
iso_label="KIBAOS"
iso_publisher="Kiba Labs, LLC <https://kibaos.com>"
iso_application="KibaOS — A friendly OS"
iso_version="$(date +%Y.%m)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1048576' '-Xdict-size' '1048576' '-no-duplicates' '-noappend')
file_permissions=(
["/etc/shadow"]="0:0:400"
["/etc/gshadow"]="0:0:400"
["/root"]="0:0:750"
["/home/liveuser"]="1000:1000:750")
PROFILEDEF
chmod +x "$PROFILE/profiledef.sh"
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i "s/bootmodes=('uefi.grub')/bootmodes=('uefi-aarch64.systemd-boot.esp' 'uefi-aarch64.systemd-boot.eltorito')/" "$PROFILE/profiledef.sh"
sed -i 's/arch="x86_64"/arch="aarch64"/' "$PROFILE/profiledef.sh"
sed -i "s/'-Xbcj' 'x86'/'-Xbcj' 'arm64'/" "$PROFILE/profiledef.sh"
fi
mkdir -p "$AIROOTFS/etc"
cat >"$AIROOTFS/etc/os-release" <<'OSRELEASE'
NAME="KibaOS"
PRETTY_NAME="KibaOS"
ID=kibaos
BUILD_ID=rolling
VENDOR_NAME="Kiba Labs"
ANSI_COLOR="1;36"
HOME_URL="https://kibaos.com"
DOCUMENTATION_URL="https://github.com/KibaLabsLLC/KibaOS/blob/main/WIKI.md"
LOGO=kibaos
OSRELEASE
cat >"$PROFILE/packages.x86_64" <<'PACKAGES'
archlinux-keyring
dosfstools
mtools
base
linux
linux-headers
amd-ucode
intel-ucode
mkinitcpio
mkinitcpio-archiso
earlyoom
fakeroot
efibootmgr
bluez
nftables
libnetfilter_queue
sudo
bash
irqbalance
zram-generator
nano
curl
wget
git
power-profiles-daemon
xdg-user-dirs
bluez-utils
go
sof-firmware
thermald
icu
gcc
debugedit
base-devel
python
pyalpm
parted
gptfdisk
pv
pkg-config
greetd
greetd-tuigreet
dconf
gsettings-desktop-schemas
webkit2gtk-4.1
python-gobject
grim
slurp
wl-clipboard
tesseract
tesseract-data-eng
libnotify
gtklock
wlopm
wlr-randr
gvfs
gvfs-mtp
gvfs-smb
accountsservice
sassc
meson
ninja
vulkan-headers
vulkan-icd-loader
wayland
wayland-protocols
wlroots0.20
cairo
pango
pixman
libdrm
libevdev
libxml2
freetype2
libpng
harfbuzz
fribidi
glib2
sysprof
rust
libinput
libjpeg-turbo
libxkbcommon
nlohmann-json
yyjson
boost
glm
network-manager-applet
pipewire
pipewire-pulse
pipewire-alsa
pipewire-jack
wireplumber
networkmanager

ntfs-3g
exfatprogs
polkit
udisks2
upower
fastfetch
xdg-desktop-portal
xdg-desktop-portal-gtk
xdg-desktop-portal-wlr
imagemagick
eglinfo
gnupg
v4l2loopback-dkms
xdg-utils
gawk
gtk4-layer-shell
gstreamer
gst-plugins-base
gst-plugins-good
gst-plugins-bad
plymouth
squashfs-tools

qemu-guest-agent
dialog
iproute2
openbsd-netcat
zenity
pciutils


lvm2

tuned
# --- GPU drivers / firmware ---
mesa
vulkan-radeon
vulkan-intel
vulkan-nouveau
intel-media-driver
libva-intel-driver
libva-mesa-driver
linux-firmware
linux-firmware-amd
linux-firmware-amdgpu
linux-firmware-atheros
linux-firmware-broadcom
linux-firmware-cirrus
linux-firmware-intel
linux-firmware-mediatek
linux-firmware-nvidia
linux-firmware-other
linux-firmware-radeon
linux-firmware-realtek
linux-firmware-ti
linux-firmware-liquidio
linux-firmware-marvell
linux-firmware-mellanox
linux-firmware-nfp
linux-firmware-qcom
linux-firmware-qlogic
PACKAGES
if [ "$KIBA_ARCH" = "x86_64" ];then
cat >>"$PROFILE/packages.x86_64" <<'NVIDIAPKGS'
nvidia-open
nvidia-utils
egl-wayland
libva-nvidia-driver
NVIDIAPKGS
fi
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i '/^linux-firmware-intel$/d' "$PROFILE/packages.x86_64"
sed -i '/^\(amd\|intel\)-ucode$/d' "$PROFILE/packages.x86_64"
sed -i '/^# linux-firmware split the Intel GuC\/HuC blobs/,/^# fails and KWin can never get a working renderer/d' \
"$PROFILE/packages.x86_64"
sed -i '/^thermald$/d' "$PROFILE/packages.x86_64"
sed -i '/^syslinux$/d' "$PROFILE/packages.x86_64"
sed -i '/^mkinitcpio-archiso$/d' "$PROFILE/packages.x86_64"
sed -i 's/^linux$/linux-aarch64/; s/^linux-headers$/linux-aarch64-headers/' \
"$PROFILE/packages.x86_64"
mv "$PROFILE/packages.x86_64" "$PROFILE/packages.aarch64"
fi
mkdir -p "$AIROOTFS/etc/mkinitcpio.conf.d"
cat >"$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf" <<'INITRAMFS'
HOOKS=(base udev kms plymouth keyboard keymap modconf memdisk archiso block filesystems)
COMPRESSION="gzip"
INITRAMFS
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i 's/ memdisk / /' "$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf"
fi
cat >"$AIROOTFS/etc/mkinitcpio.conf.d/installed.conf" <<'INSTALLED_HOOKS'
HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap block filesystems fsck)
COMPRESSION="gzip"
INSTALLED_HOOKS
mkdir -p "$AIROOTFS/etc/mkinitcpio.d"
cat >"$AIROOTFS/etc/mkinitcpio.d/linux.preset" <<'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux.img'
PRESET
if [ "$KIBA_ARCH" = "aarch64" ];then
rm -f "$AIROOTFS/etc/mkinitcpio.d/linux-aarch64.preset"
fi
rm -rf "$PROFILE/syslinux"
if [ "$KIBA_ARCH" = "x86_64" ];then
rm -rf "$PROFILE/efiboot"
mkdir -p "$PROFILE/grub"
cat >"$PROFILE/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=0
insmod all_video
insmod gfxterm
terminal_output gfxterm

search --no-floppy --set=root --label %ARCHISO_LABEL%

menuentry "KibaOS" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
    initrd /%INSTALL_DIR%/boot/intel-ucode.img /%INSTALL_DIR%/boot/amd-ucode.img /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry "KibaOS (safe mode)" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
    initrd /%INSTALL_DIR%/boot/intel-ucode.img /%INSTALL_DIR%/boot/amd-ucode.img /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' {
    fwsetup
}
GRUBCFG
else
mkdir -p "$PROFILE/efiboot/loader/entries"
cat >"$PROFILE/efiboot/loader/loader.conf" <<'LOADERCONF'
timeout 0
default kibaos.conf
LOADERCONF
cat >"$PROFILE/efiboot/loader/entries/kibaos.conf" <<'ENTRYCONF'
title   KibaOS
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
ENTRYCONF
cat >"$PROFILE/efiboot/loader/entries/kibaos-safe.conf" <<'ENTRYCONF'
title   KibaOS (safe mode)
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
ENTRYCONF
fi
PACMAN_CONF="$PROFILE/pacman.conf"
if [ -f "$PACMAN_CONF" ];then
grep -q 'NoExtract' "$PACMAN_CONF"||sed -i '/^\[options\]/a NoExtract  = usr/share/man/* usr/share/info/* usr/share/doc/*\nNoExtract  = usr/share/locale/* !usr/share/locale/en_US/* !usr/share/locale/en_GB/* !usr/share/locale/locale.alias' \
"$PACMAN_CONF"
fi
LIVE_HASH=$(openssl passwd -6 "live")
grep -q '^liveuser:' "$AIROOTFS/etc/passwd" 2>/dev/null||echo 'liveuser:x:1000:1000:KibaOS Live User:/home/liveuser:/bin/bash' >>"$AIROOTFS/etc/passwd"
grep -q '^liveuser:' "$AIROOTFS/etc/group" 2>/dev/null||echo 'liveuser:x:1000:liveuser' >>"$AIROOTFS/etc/group"
grep -q '^liveuser:' "$AIROOTFS/etc/shadow" 2>/dev/null||echo "liveuser:$LIVE_HASH:19000:0:99999:7:::" >>"$AIROOTFS/etc/shadow"
mkdir -p "$AIROOTFS/home/liveuser"
mkdir -p "$AIROOTFS/etc/sudoers.d"
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' >"$AIROOTFS/etc/sudoers.d/liveuser"
chmod 0440 "$AIROOTFS/etc/sudoers.d/liveuser"
WANTS="$AIROOTFS/etc/systemd/system"
mkdir -p "$WANTS/default.target.wants" "$WANTS/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/graphical.target "$WANTS/default.target"
ln -sf /usr/lib/systemd/system/kibaos-greetd.service "$WANTS/display-manager.service"
ln -sf /usr/lib/systemd/system/pacman-init.service "$WANTS/multi-user.target.wants/pacman-init.service"
ln -sf /usr/lib/systemd/system/bluetooth.service "$WANTS/multi-user.target.wants/bluetooth.service"
mkdir -p "$AIROOTFS/root"
cat >"$AIROOTFS/root/customize_airootfs.sh" <<'CUSTOMIZE'
#!/usr/bin/env bash
set -e
export GVFS_DISABLE_FUSE=1
rm -f /etc/machine-id
touch /etc/machine-id
systemd-machine-id-setup
rm /usr/lib/sysusers.d/basic.conf
rm /usr/lib/sysusers.d/arch.conf
systemd-sysusers||true
systemd-tmpfiles --create 2>/dev/null||true
id polkitd &>/dev/null||useradd -r -U -M -d /run/polkit -s /usr/bin/nologin polkitd
useradd -r -s /usr/bin/nologin -U alpm 2>/dev/null||true
mkdir -p /var/cache/pacman/pkg
chmod 755 /var/cache/pacman /var/cache/pacman/pkg
chown -R alpm:alpm /var/cache/pacman
if [ "$(uname -m)" = "x86_64" ];then
cat >/etc/pacman.d/mirrorlist <<'MIRRORLIST'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://america.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
MIRRORLIST
fi
sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
if [ "$(uname -m)" = "aarch64" ];then
pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
fi
pacman -Syy --noconfirm
pacman -Scc --noconfirm
systemctl disable earlyoom 2>/dev/null||true
mkdir -p /etc/systemd/oomd.conf.d
cat >/etc/systemd/oomd.conf.d/kibaos.conf <<'OOMDCONF'
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureDurationSec=20s
OOMDCONF
systemctl enable systemd-oomd
cat >/etc/sysctl.d/99-kibaos.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
net.core.netdev_max_backlog=16384
SYSCTL
pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' >/etc/locale.conf
echo 'kibaos' >/etc/hostname
cat >/etc/hosts <<'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   kibaos.localdomain kibaos
HOSTS
for g in users wheel audio video input network storage power;do
groupadd -r "$g" 2>/dev/null||true
usermod -aG "$g" liveuser 2>/dev/null||true
done
echo "liveuser:live"|chpasswd
grep -qx '/bin/bash' /etc/shells||echo '/bin/bash' >>/etc/shells
cp -aT /etc/skel/ /home/liveuser/ 2>/dev/null||true
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#IdleAction=ignore/IdleAction=ignore/' /etc/systemd/logind.conf
grep -q 'IdleActionSec' /etc/systemd/logind.conf||echo 'IdleActionSec=0' >>/etc/systemd/logind.conf
grep -q 'HandleHibernateKey' /etc/systemd/logind.conf||echo 'HandleHibernateKey=ignore' >>/etc/systemd/logind.conf
grep -q 'HandleLidSwitchDocked' /etc/systemd/logind.conf||echo 'HandleLidSwitchDocked=ignore' >>/etc/systemd/logind.conf
grep -q 'HandleLidSwitchExternalPower' /etc/systemd/logind.conf||echo 'HandleLidSwitchExternalPower=ignore' >>/etc/systemd/logind.conf
grep -q 'HandlePowerKey' /etc/systemd/logind.conf&&sed -i 's/^HandlePowerKey=.*/HandlePowerKey=poweroff/' /etc/systemd/logind.conf
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
WALLPAPER_URL="https://raw.githubusercontent.com/KibaLabsLLC/KibaOS/eb32d69184b0ab434031bdbcf10e7f05230bf04a/assets/wallpapers/914336476_1020081810382353_5994052822657741584_n.webp"
WALLPAPER_DEST="/usr/share/kibaos/wallpaper.jpg"
LOGO_SRC="/usr/share/kibaos/logo-raw.png"
LOGO_256="/usr/share/kibaos/logo-256.png"
LOGO_96="/usr/share/kibaos/logo-96.png"
LOGO_48="/usr/share/kibaos/logo-48.png"
LOGO_32="/usr/share/kibaos/logo-32.png"
INSTALLER_LOGO="/usr/share/kibaos/installer-logo.png"
mkdir -p /usr/share/kibaos /usr/share/pixmaps
if curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-wallpaper-src "$WALLPAPER_URL"&&magick /tmp/kiba-wallpaper-src[0] -quality 92 "$WALLPAPER_DEST";then
:
else
magick -size 1920x1080 gradient:"#003f5c-#0099cc" "$WALLPAPER_DEST"
fi
rm -f /tmp/kiba-wallpaper-src
if [ -f "$LOGO_SRC" ]&&file "$LOGO_SRC"|grep -qi 'image';then
magick "$LOGO_SRC" -filter Lanczos -resize 256x256 "$LOGO_256"
magick "$LOGO_SRC" -filter Lanczos -resize 96x96 "$LOGO_96"
magick "$LOGO_SRC" -filter Lanczos -resize 48x48 "$LOGO_48"
magick "$LOGO_SRC" -filter Lanczos -resize 32x32 "$LOGO_32"
rm -f "$LOGO_SRC"
else
for sz in 256 96 48 32;do
magick -size ${sz}x$sz xc:none \
-fill '#0099cc' -draw "circle $((sz/2)),$((sz/2)) $((sz/2)),1" \
"/usr/share/kibaos/logo-$sz.png"
done
fi
cp "$LOGO_256" /usr/share/pixmaps/kibaos.png
ln -sf /usr/share/pixmaps/kibaos.png /usr/share/pixmaps/kibaos-logo.png
mkdir -p /usr/share/icons/hicolor/256x256/apps \
/usr/share/icons/hicolor/48x48/apps \
/usr/share/icons/hicolor/32x32/apps
cp "$LOGO_256" /usr/share/icons/hicolor/256x256/apps/kibaos.png
cp "$LOGO_48" /usr/share/icons/hicolor/48x48/apps/kibaos.png
cp "$LOGO_32" /usr/share/icons/hicolor/32x32/apps/kibaos.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
BADGE_WHITE_SRC="/usr/share/kibaos/badge-white.png"
magick "$LOGO_256" -alpha extract -threshold 50% /tmp/kiba-badge-alpha.png
magick -size 256x256 xc:white /tmp/kiba-badge-white.png
magick /tmp/kiba-badge-white.png /tmp/kiba-badge-alpha.png \
-alpha off -compose CopyOpacity -composite "$BADGE_WHITE_SRC"
rm -f /tmp/kiba-badge-alpha.png /tmp/kiba-badge-white.png
mkdir -p /usr/share/icons/hicolor/scalable/actions \
/usr/share/icons/hicolor/symbolic/actions \
/usr/share/icons/hicolor/24x24/actions \
/usr/share/icons/hicolor/22x22/actions \
/usr/share/icons/hicolor/16x16/actions
for sz in 16 22 24 32 48;do
magick "$BADGE_WHITE_SRC" -filter Lanczos -resize ${sz}x$sz \
"/usr/share/icons/hicolor/${sz}x$sz/actions/pane-show-symbolic.png"
done
cp "$BADGE_WHITE_SRC" /usr/share/icons/hicolor/scalable/actions/pane-show-symbolic.png
cp "$BADGE_WHITE_SRC" /usr/share/icons/hicolor/symbolic/actions/pane-show-symbolic.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
cp "$LOGO_256" "$INSTALLER_LOGO"
pacman -Syu --noconfirm git
set -euo pipefail
mkdir -p /usr/share/icons/hicolor/scalable/actions
cp /usr/share/kibaos/logo-256.png /usr/share/icons/hicolor/scalable/actions/kibaos-watermark-symbolic.png 2>/dev/null||true
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
userdel -r builduser 2>/dev/null||true
rm -f /etc/sudoers.d/builduser
KIBA_PLYMOUTH_DIR="/usr/share/plymouth/themes/kibaos"
KIBA_SPLASH_SRC="/tmp/kiba-assets-splash"
rm -rf "$KIBA_SPLASH_SRC"
_splash_ok=0
for _try in 1 2 3 4 5;do
if git clone --depth 1 https://github.com/KibaLabsLLC/Assets "$KIBA_SPLASH_SRC"&&[ -f "$KIBA_SPLASH_SRC/Splash/install.sh" ];then
_splash_ok=1
break
fi
echo "!! Assets clone attempt $_try/5 failed -- retrying in 5s" >&2
rm -rf "$KIBA_SPLASH_SRC"
sleep 5
done
[ "$_splash_ok" -eq 1 ]||{
echo "ERROR: could not fetch KibaLabsLLC/Assets (Splash/install.sh)" >&2
exit 1
}
mkdir -p /etc/plymouth
cat >/etc/plymouth/plymouthd.conf <<'PLYMOUTHD'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD
chmod +x "$KIBA_SPLASH_SRC/Splash/install.sh"
(cd "$KIBA_SPLASH_SRC/Splash"&&./install.sh)||echo "!! Splash install.sh reported a failure (usually the initramfs rebuild) -- checking theme files anyway" >&2
for _f in kibaos.plymouth kibaos.script background.png logo.png raccoon.png;do
[ -s "$KIBA_PLYMOUTH_DIR/$_f" ]||{
echo "ERROR: Splash asset $_f was not installed into $KIBA_PLYMOUTH_DIR" >&2
exit 1
}
done
echo "=== Boot splash: KibaLabsLLC/Assets Splash installed via install.sh ==="
magick "$KIBA_PLYMOUTH_DIR/logo.png" -filter Lanczos -resize '480x480>' /usr/share/kibaos/plymouth-logo.png||cp "$KIBA_PLYMOUTH_DIR/logo.png" /usr/share/kibaos/plymouth-logo.png
cp /usr/share/kibaos/plymouth-logo.png /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner;do
if [ -d "/usr/share/plymouth/themes/$_theme_dir" ];then
cp /usr/share/kibaos/plymouth-logo.png "/usr/share/plymouth/themes/$_theme_dir/watermark.png"
fi
done
rm -f /etc/xdg/autostart/cutefish-dock.desktop /etc/xdg/autostart/wl-dock.desktop
pacman -R --noconfirm cutefish-dock 2>/dev/null||true
pacman -Rns --noconfirm wl-dock 2>/dev/null||true
rm -f /usr/bin/wl-dock
# Resolve JACK provider conflict: prefer pipewire-jack, drop jack2
if pacman -Q jack2 >/dev/null 2>&1;then
pacman -Rdd --noconfirm jack2
fi
pacman -S --noconfirm --needed pipewire-jack qt6-multimedia-ffmpeg
# ---- KibaDE (https://github.com/KibaLabsLLC/KibaDE) replaces AuraDE ----------------------------------------
# build-chromeos-ash.sh builds chrome + chrome_sandbox from the pinned Chromium checkout; the PKGBUILD then
# packages that exact output (KIBAOS_SKIP_CHROMIUM_BUILD=1) together with the session/launcher files, and the
# support packages (shill-nm-adapter, system/account helpers, login, greeter) are built from the same repo.
# Everything runs as the unprivileged kibabuild user because makepkg and depot_tools refuse root.
KIBADE_REPO_URL="https://github.com/KibaLabsLLC/KibaDE"
KIBADE_HOME="/home/kibabuild"
KIBADE_BUILD="$KIBADE_HOME/kibade-build"
echo "=== Building KibaDE from $KIBADE_REPO_URL ==="
_pre_pkgs="$(pacman -Qq)"
pacman -Syu --noconfirm --needed \
base-devel git python python-pip nodejs ninja gn pkgconf clang lld bison flex gperf patch \
rust cargo rsync libarchive file weston pam wayland wayland-protocols greetd greetd-tuigreet
id kibabuild >/dev/null 2>&1||useradd -m kibabuild
echo 'kibabuild ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/kibabuild
chmod 440 /etc/sudoers.d/kibabuild
install -d -o kibabuild -g kibabuild "$KIBADE_BUILD" "$KIBADE_BUILD/pkgdest"
cat >"$KIBADE_HOME/kibade-build.sh" <<'KIBADEBUILD'
#!/bin/bash
set -euo pipefail
B="$HOME/kibade-build"
KIBADE="$B/KibaDE"
export PKGDEST="$B/pkgdest"
rm -rf "$KIBADE"
_ok=0
for _try in 1 2 3 4 5;do
if git clone --depth 1 https://github.com/KibaLabsLLC/KibaDE "$KIBADE";then _ok=1;break;fi
echo "!! KibaDE clone attempt $_try/5 failed -- retrying in 10s" >&2
rm -rf "$KIBADE"
sleep 10
done
[ "$_ok" -eq 1 ]||{ echo "ERROR: could not clone KibaLabsLLC/KibaDE" >&2;exit 1; }
[ -x "$KIBADE/build-chromeos-ash.sh" ]||chmod +x "$KIBADE/build-chromeos-ash.sh"
# depot_tools + the pinned Chromium checkout, with the KibaDE patch series verified
[ -d "$B/depot_tools/.git" ]||git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$B/depot_tools"
export PATH="$B/depot_tools:$PATH"
REV="$(tr -d '[:space:]' <"$KIBADE/pins/chromium.sha")"
[[ "$REV" =~ ^[0-9a-fA-F]{40}$ ]]||{ echo "ERROR: bad pins/chromium.sha: $REV" >&2;exit 1; }
export KIBAOS_WORKDIR="$B" KIBAOS_DEPOT_TOOLS="$B/depot_tools" KIBAOS_BOOTSTRAP_JOBS="$(nproc)"
bash "$KIBADE/ci/bootstrap-chromium-src.sh" --revision "$REV" --target "$B/chromium-bootstrap" --run --verify-series
export CHROME_SRC="$B/chromium-bootstrap/src"
[ -d "$CHROME_SRC/.git" ]||{ echo "ERROR: Chromium checkout missing at $CHROME_SRC" >&2;exit 1; }
# build-chromeos-ash.sh: 'build' = gn gen + ninja (chrome chrome_sandbox) + verify + stage.
# 'prepare' (repo sync of the ChromiumOS minilayout) is skipped: the source is the bootstrapped CHROME_SRC above.
export CHROMIUMOS_DIR="$B/chromium-bootstrap" DEPOT_TOOLS_DIR="$B/depot_tools" OUTPUT_DIR="$CHROME_SRC/out/Ash" JOBS="$(nproc)"
cd "$KIBADE"
bash ./build-chromeos-ash.sh build||echo "!! build-chromeos-ash.sh exited non-zero (checking the build output anyway)" >&2
[ -x "$OUTPUT_DIR/chrome" ]&&[ -x "$OUTPUT_DIR/chrome_sandbox" ]||{ echo "ERROR: build-chromeos-ash.sh did not produce chrome + chrome_sandbox in $OUTPUT_DIR" >&2;exit 1; }
# Package that build output (complete runtime tree, session scripts, setuid sandbox) with the repo's PKGBUILD.
cd "$KIBADE/chromiumos-ash"
rm -rf pkg src
KIBAOS_SKIP_CHROMIUM_BUILD=1 KIBAOS_OUT_DIR="$OUTPUT_DIR" makepkg -f -d --noconfirm --nocheck
for _p in shill-nm-adapter kibaos-system-helper kibaos-account-helper kibaos-login kibaos-greeter;do
echo "=== makepkg $_p ==="
(cd "$KIBADE/$_p"&&rm -rf pkg src&&makepkg -f -d --noconfirm --nocheck)
done
ls -l "$PKGDEST"
KIBADEBUILD
chmod 755 "$KIBADE_HOME/kibade-build.sh"
chown kibabuild:kibabuild "$KIBADE_HOME/kibade-build.sh"
su - kibabuild -c "$KIBADE_HOME/kibade-build.sh"||{ echo "ERROR: KibaDE build failed" >&2;exit 1; }
for _n in chromiumos-ash shill-nm-adapter kibaos-system-helper kibaos-account-helper kibaos-login kibaos-greeter;do
ls "$KIBADE_BUILD"/pkgdest/"$_n"-[0-9]*.pkg.tar.* >/dev/null 2>&1||{ echo "ERROR: no built package for $_n" >&2;exit 1; }
done
pacman -U --noconfirm "$KIBADE_BUILD"/pkgdest/*.pkg.tar.*||{ echo "ERROR: could not install the KibaDE packages" >&2;exit 1; }
if [ -x /usr/bin/kibaos-session-supervisor ]&&[ -f /usr/share/wayland-sessions/chromiumos-ash.desktop ]&&[ -x /usr/lib/chromiumos-ash/chrome ];then
echo "=== KibaDE installed ==="
else
echo "ERROR: KibaDE install failed -- Budgie is gone, so there is no desktop to fall back to" >&2
exit 1
fi
# The build tree (Chromium checkout + out/) must never reach the squashfs; drop build-only toolchain packages too.
rm -rf "$KIBADE_BUILD" "$KIBADE_HOME/kibade-build.sh"
rm -f /etc/sudoers.d/kibabuild
userdel -r kibabuild 2>/dev/null||true
_drop=""
for _t in clang lld gn bison flex gperf nodejs patch python-pip;do
if ! printf '%s\n' "$_pre_pkgs"|grep -qx "$_t"&&pacman -Q "$_t" >/dev/null 2>&1;then _drop="$_drop $_t";fi
done
[ -n "$_drop" ]&&{ pacman -Rns --noconfirm $_drop||echo "!! could not remove build-only packages:$_drop" >&2; }
unset _pre_pkgs _drop
# Find every file containing the string (raw bytes), then same-length replace, binary-safe, display-case only
# Rebrand AuraDE -> KibaOS and set the tagline. The old raw grep|sed could not see
# names inside gzip/brotli-compressed .pak entries or UTF-16 strings, which is where
# the "Welcome to AuraDE" OOBE title lives. This walks paks properly.
pacman -S --noconfirm --needed python python-brotli||echo "!! python-brotli missing -- brotli pak entries will be skipped" >&2
cat >/usr/local/bin/kiba-rebrand <<'KIBAREBRAND'
#!/usr/bin/env python3
"""Rebrand AuraDE -> KibaOS everywhere it can hide, and set the tagline.

Handles what a raw `grep -F | sed` cannot see:
  * .pak resource bundles (v5): entries are gzip/brotli compressed, so the
    name is invisible until decompressed. Entries are rewritten and the pak is
    rebuilt (ids, aliases and entry order unchanged, verified before writing).
  * UTF-16LE strings (Chromium keeps many as char16_t).
  * Only the display spelling "AuraDE" (never AURADE_* env vars or *Aurade* identifiers).
  * "Arch Linux", "Chromium OS", "ChromiumOS" and "Linux" -> "KibaOS", but ONLY inside the AuraDE
    trees (AURA_ROOTS: chromiumos-ash incl. the chrome binary, and the greeter), never
    under /usr/share or /opt generally. Applies to text, pak entries and ELF binaries.
    Whole-token matches only: identifiers, paths, "GNU/Linux", "Linux-syscall-note" and
    user-agent strings ("X11; Linux x86_64") are left alone.
Name swaps are same length (6 chars) so ELF binaries stay valid; the tagline is
only rewritten in paks and text files, where length may change.
"""
import gzip, os, re, struct, sys

# Display name ONLY. AURADE_* are environment variables read by the session scripts and
# *Aurade* (requestAuradeNetworkApps, onAuradeUpdateClick_ ...) are identifiers shared
# between the WebUI JS and the browser binary: renaming either breaks things.
NAME = [("AuraDE", "KibaOS")]
TAGLINES_OLD = ["Fast. Secure. Effortless."]
TAGLINE_NEW = "Fast. Simple. Limitless."
BROTLI_MAGIC = b"\x1e\x9b"
try:
    import brotli
except Exception:
    brotli = None

stats = {"paks": 0, "entries": 0, "files": 0, "skipped": [], "elf_patched": 0, "elf_too_long": {}}

# Terms rewritten to KibaOS inside the AuraDE trees only. ORDER MATTERS: "Arch Linux"
# must go before "Linux" or it would come out as "Arch KibaOS".
EXTRA = [("Arch Linux", "KibaOS"), ("Chromium OS", "KibaOS"), ("ChromiumOS", "KibaOS"), ("Linux", "KibaOS")]
AURA_ROOTS = ("/usr/lib/chromiumos-ash/", "/usr/lib/kibaos-greeter/")

def _extra_rx(old, enc, binary):
    o = re.escape(old.encode(enc))
    if enc == "utf-8":
        pre = rb"(?<![A-Za-z0-9_/.\-])"
        post = rb"(?![A-Za-z0-9_/\-]|\.[a-z])"
        if old == "Linux":  # leave user-agent style "X11; Linux x86_64" alone
            pre += rb"(?<!; )"
            post += rb"(?! (?:x86_64|i[3-6]86|aarch64|armv\d))"
        Q = rb"[\'\"`]"  # skip a bare quoted 'Linux' (JS platform checks like ua.includes('Linux'))
        body = rb"(?:(?<!" + Q + rb")" + o + rb"|(?<=" + Q + rb")" + o + rb"(?!" + Q + rb"))"
        tail = rb"(?=\x00)"
    else:
        pre = rb"(?<![A-Za-z0-9_/.\-]\x00)"
        post = rb"(?![A-Za-z0-9_/\-]\x00|\.\x00[a-z]\x00)"
        body = o
        tail = rb"(?=\x00\x00)"
    # In a binary the replacement is padded with NULs, which is only correct when the
    # match runs to the end of a NUL-terminated string, so require the terminator.
    return re.compile(pre + (o if binary else body) + (tail if binary else post))

_RX = {}
def extra_rx(old, enc, binary):
    k = (old, enc, binary)
    if k not in _RX:
        _RX[k] = _extra_rx(old, enc, binary)
    return _RX[k]

def has_extra(d):
    return any(old.encode(e) in d for old, _ in EXTRA for e in ("utf-8", "utf-16-le"))

def in_aura(path):
    return os.path.abspath(path).startswith(AURA_ROOTS)

def is_text_blob(raw):
    return b"\x00" not in raw[:8192] and not raw.startswith(
        (b"\x7fELF", b"\x89PNG", b"GIF8", b"\xff\xd8", b"wOFF", b"wOF2", b"RIFF", b"\x00asm"))

def swap_extra(b, binary, path=""):
    """Arch Linux / ChromiumOS / Linux -> KibaOS. Text: any length. ELF: only where the
    replacement is not longer (NUL-padded); longer ones are counted and reported."""
    out = b
    for old, new in EXTRA:
        for enc in ("utf-8", "utf-16-le"):
            o, n = old.encode(enc), new.encode(enc)
            if o not in out:
                continue
            rx = extra_rx(old, enc, binary)
            if binary and len(n) > len(o):
                c = len(rx.findall(out))
                if c:
                    stats["elf_too_long"][(path, old)] = stats["elf_too_long"].get((path, old), 0) + c
                continue
            rep = n + b"\x00" * (len(o) - len(n)) if binary else n
            out, c = rx.subn(lambda m, r=rep: r, out)
            if binary:
                stats["elf_patched"] += c
    return out

def swap(b, tagline):
    """Replace in UTF-8 and UTF-16LE; returns (new_bytes, changed)."""
    out = b
    pairs = list(NAME)
    if tagline:
        pairs.extend((t, TAGLINE_NEW) for t in TAGLINES_OLD)
    for old, new in pairs:
        for enc in ("utf-8", "utf-16-le"):
            o, n = old.encode(enc), new.encode(enc)
            if o in out:
                out = out.replace(o, n)
    return out, out != b

# ---- OOBE welcome-screen art ------------------------------------------------
# The welcome page stacks a static first frame (iron-icon oobe-illos:connect-illo)
# under a Lottie player (welcome_screen_animation.json). There is no file to swap:
# both are pak entries and the SVG/Lottie are themed vector art. So: (1) the page
# markup is edited to show a plain <img> of /images/cfm/welcome.svg instead (the
# JS looks the Lottie element up with querySelector + instanceof, so removing it
# is safe), and (2) that SVG resource -- identified by content, ids move between
# builds -- is replaced with one that wraps the KibaOS raccoon art (data: URI
# inside an SVG-as-image is not subject to the page CSP).
WELCOME_ART_B64 = "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"
WELCOME_SVG = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
               'width="1600" height="600" viewBox="0 0 1600 600"><image width="1600" height="600" '
               'preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,' + WELCOME_ART_B64 + '"/></svg>').encode()
WELCOME_IMG = b'<img src="/images/cfm/welcome.svg" class="oobe-illustration" id="kibaWelcomeImage" aria-hidden="true">'
import re
WELCOME_BLOCK = re.compile(rb'<iron-icon id="welcomeAnimationFirstFrame".*?</oobe-cr-lottie>', re.S)
art_done = {"html": 0, "svg": 0}

def welcome_art(raw):
    # /images/cfm/welcome.svg: the 664x355 video-call illustration (replaced by the full KibaOS banner). (Not <svg id="welcomeSvg">,
    # which belongs to the graduation app.)
    if raw.startswith(b'<svg version="1.1" id="Layer_1"') and b'viewBox="0 0 664 355"' in raw[:700]:
        art_done["svg"] += 1
        return WELCOME_SVG
    if b'id="welcomeAnimationFirstFrame"' in raw and b'welcome_screen_animation.json' in raw:
        new, n = WELCOME_BLOCK.subn(WELCOME_IMG, raw)
        if n:
            art_done["html"] += 1
            return new
    return raw

def unpack_entry(p):
    if p[:2] == b"\x1f\x8b":
        return "gzip", gzip.decompress(p)
    if p[:2] == BROTLI_MAGIC:
        if brotli is None:
            raise RuntimeError("brotli entry but python brotli module missing")
        size = int.from_bytes(p[2:8], "little")
        raw = brotli.decompress(p[8:])
        if len(raw) != size:
            raise RuntimeError("brotli size mismatch")
        return "brotli", raw
    return None, p

def pack_entry(kind, raw):
    if kind == "gzip":
        return gzip.compress(raw, 9, mtime=0)
    if kind == "brotli":
        return BROTLI_MAGIC + len(raw).to_bytes(6, "little") + brotli.compress(raw)
    return raw

def do_pak(path):
    d = open(path, "rb").read()
    # Locale paks (locales/*.pak) are gzip-compressed as a WHOLE FILE around a
    # normal pak; unwrap, rewrite the inner pak, and gzip it back.
    if d[:2] == b"\x1f\x8b":
        return do_pak_bytes(path, gzip.decompress(d), True)
    return do_pak_bytes(path, d, False)

def do_pak_bytes(path, d, wrapped):
    if len(d) < 12 or struct.unpack_from("<I", d, 0)[0] != 5:
        stats["skipped"].append(path + " (not pak v5)")
        return False
    enc = d[4]
    count, acount = struct.unpack_from("<HH", d, 8)
    ents = [struct.unpack_from("<HI", d, 12 + i * 6) for i in range(count + 1)]
    abase = 12 + (count + 1) * 6
    aliases = d[abase:abase + acount * 4]
    payloads, changed = [], 0
    for i in range(count):
        p = d[ents[i][1]:ents[i + 1][1]]
        try:
            kind, raw = unpack_entry(p)
        except Exception as e:
            stats["skipped"].append("%s entry %d: %s" % (path, ents[i][0], e))
            payloads.append(p)
            continue
        raw2 = welcome_art(raw)
        new, ch = swap(raw2, True)
        if in_aura(path) and is_text_blob(new) and has_extra(new):
            new2 = swap_extra(new, False, path)
            ch = ch or new2 != new
            new = new2
        ch = ch or raw2 is not raw
        if ch:
            p = pack_entry(kind, new)
            changed += 1
        payloads.append(p)
    if not changed:
        return False
    # rebuild
    head = d[:8] + struct.pack("<HH", count, acount)
    off = 12 + (count + 1) * 6 + acount * 4
    table, body = b"", b""
    for i in range(count):
        table += struct.pack("<HI", ents[i][0], off + len(body))
        body += payloads[i]
    table += struct.pack("<HI", ents[count][0], off + len(body))
    out = head + table + aliases + body
    # verify: same ids, same alias table, same count
    c2, a2 = struct.unpack_from("<HH", out, 8)
    e2 = [struct.unpack_from("<HI", out, 12 + i * 6) for i in range(c2 + 1)]
    assert (c2, a2) == (count, acount)
    assert [x[0] for x in e2] == [x[0] for x in ents]
    assert out[abase:abase + acount * 4] == aliases
    tmp = path + ".kiba-tmp"
    open(tmp, "wb").write(gzip.compress(out, 9, mtime=0) if wrapped else out)
    os.chmod(tmp, os.stat(path).st_mode)
    os.replace(tmp, path)
    stats["paks"] += 1
    stats["entries"] += changed
    return True

def do_file(path):
    # never touch signed/keyed material: a changed byte breaks the signature
    if "keyring" in path or "gnupg" in path or path.endswith((".gpg", ".sig", ".asc", ".kbx", ".key", ".pem")):
        return
    try:
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) > 2 * 1024 ** 3:
            return
        d = open(path, "rb").read()
    except OSError:
        return
    extra = in_aura(path) and has_extra(d)
    if b"AuraDE" not in d and "AuraDE".encode("utf-16-le") not in d and not extra and \
       not any(t.encode() in d or t.encode("utf-16-le") in d for t in TAGLINES_OLD):
        if not path.endswith(".pak"):
            return
    if path.endswith(".pak"):
        do_pak(path)
        return
    is_elf = d.startswith(b"\x7fELF")
    is_text = b"\x00" not in d[:8192] and not is_elf
    new, ch = swap(d, is_text)
    if extra and (is_text or is_elf):
        new = swap_extra(new, is_elf, path)
        ch = new != d
    if ch:
        mode = os.stat(path).st_mode
        open(path, "wb").write(new)
        os.chmod(path, mode)
        stats["files"] += 1

def pak_entries(path):
    d = open(path, "rb").read()
    if d[:2] == b"\x1f\x8b":
        d = gzip.decompress(d)
    if len(d) < 12 or struct.unpack_from("<I", d, 0)[0] != 5:
        return
    count = struct.unpack_from("<H", d, 8)[0]
    ents = [struct.unpack_from("<HI", d, 12 + i * 6) for i in range(count + 1)]
    for i in range(count):
        p = d[ents[i][1]:ents[i + 1][1]]
        try:
            p = unpack_entry(p)[1]
        except Exception:
            continue
        yield ents[i][0], p

def verify(roots):
    """Fail the build if the welcome title could still say AuraDE."""
    bad = []
    for root in roots:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                path = os.path.join(dp, f)
                if f.endswith(".pak") and not os.path.islink(path):
                    for i, p in pak_entries(path):
                        if b"AuraDE" in p or "AuraDE".encode("utf-16-le") in p:
                            bad.append("%s entry %d" % (path, i))
    en = [r for r in roots if os.path.isdir(r)]
    found_locale = any(os.path.exists(os.path.join(r, "locales", "en-US.pak")) for r in en)
    print("kiba-rebrand: verify: %d pak entr(ies) still contain AuraDE; en-US locale pak %s"
          % (len(bad), "present" if found_locale else "NOT FOUND"))
    for b in bad[:20]:
        print("kiba-rebrand: STILL AuraDE: " + b, file=sys.stderr)
    return not bad and found_locale

def main(roots):
    for root in roots:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                do_file(os.path.join(dp, f))
    print("kiba-rebrand: welcome art: page=%(html)d svg=%(svg)d" % art_done)
    print("kiba-rebrand: %(paks)d pak(s) / %(entries)d pak entries / %(files)d file(s) rewritten" % stats)
    print("kiba-rebrand: %d ELF string(s) patched in place (NUL-padded)" % stats["elf_patched"])
    for (pth, term), c in sorted(stats["elf_too_long"].items()):
        print("kiba-rebrand: NOTE %s: %d x \"%s\" not patched in the binary (KibaOS is longer; "
              "same-length only)" % (pth, c, term), file=sys.stderr)
    for s in stats["skipped"]:
        print("kiba-rebrand: SKIPPED " + s, file=sys.stderr)
    if not verify(roots):
        sys.exit(2)

if __name__ == "__main__":
    main(sys.argv[1:] or ["/usr/lib/chromiumos-ash", "/usr/lib/kibaos-greeter", "/usr/share"])
KIBAREBRAND
chmod +x /usr/local/bin/kiba-rebrand
python3 /usr/local/bin/kiba-rebrand /usr/lib/chromiumos-ash /usr/lib/kibaos-greeter /usr/share /opt||{ echo "ERROR: kiba-rebrand failed" >&2;exit 1; }
# Verify: no display-case name left in ASCII or UTF-16, anywhere that ships
_left="$(grep -rlaE 'AuraDE|A.u.r.a.D.E|Fast\. Secure\. Effortless' /usr/lib/chromiumos-ash /usr/lib/kibaos-greeter /usr/share /opt 2>/dev/null|grep -v '\.pak$'||true)"
[ -n "$_left" ]&&echo "!! rebrand: display-name strings still present in: $_left" >&2
# Keep the tool and re-run it whenever pacman reinstalls/updates the AuraDE packages --
# otherwise an update (or the installer pulling the package again) restores "AuraDE".
mkdir -p /etc/pacman.d/hooks
cat >/etc/pacman.d/hooks/99-kibaos-rebrand.hook <<'KIBAHOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = chromiumos-ash
Target = kibaos-greeter

[Action]
Description = Rebranding AuraDE -> KibaOS...
When = PostTransaction
Exec = /usr/bin/python3 /usr/local/bin/kiba-rebrand /usr/lib/chromiumos-ash /usr/lib/kibaos-greeter
KIBAHOOK
# Ash's default wallpaper. The supported knob is KIBAOS_DEFAULT_WALLPAPER in /etc/kibaos/features.conf:
# chromiumos-ash (the launcher) turns it into --default-wallpaper-large/-small and, because the ChromeOS
# time-of-day wallpaper would otherwise replace it at first sign-in, disables that feature (and its screen saver).
# (The old `sed` on chromiumos-ash-session was a no-op: that script has no CHROME= line, and the launcher that
# builds the flags is /usr/bin/chromiumos-ash and never read CHROME_FLAGS.)
mkdir -p /etc/kibaos
[ -f /etc/kibaos/features.conf ]||: >/etc/kibaos/features.conf
if grep -q '^KIBAOS_DEFAULT_WALLPAPER=' /etc/kibaos/features.conf;then
sed -i 's|^KIBAOS_DEFAULT_WALLPAPER=.*|KIBAOS_DEFAULT_WALLPAPER=/usr/share/kibaos/wallpaper.jpg|' /etc/kibaos/features.conf
else
printf '\nKIBAOS_DEFAULT_WALLPAPER=/usr/share/kibaos/wallpaper.jpg\n' >>/etc/kibaos/features.conf
fi
chmod 644 /usr/share/kibaos/wallpaper.jpg
grep -q '^KIBAOS_DEFAULT_WALLPAPER=/usr/share/kibaos/wallpaper.jpg$' /etc/kibaos/features.conf||{ echo "ERROR: could not set the Ash default wallpaper" >&2;exit 1; }
id kibabuild >/dev/null 2>&1||useradd -m kibabuild
echo 'kibabuild ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/kibabuild
chmod 440 /etc/sudoers.d/kibabuild
LI_OK=0
for _try in 1 2 3 4 5;do
if su - kibabuild -c 'cd /tmp && rm -rf lost-island && git clone https://github.com/MarcoZorn/lost-island && cd lost-island/packaging && makepkg -si --noconfirm --needed';then
LI_OK=1
break
fi
echo "!! lost-island build attempt $_try/5 failed -- retrying in 10s" >&2
sleep 10
done
if [ "$LI_OK" -eq 1 ]&&command -v lost-island >/dev/null 2>&1;then
echo "=== lost-island installed ==="
else
echo "!! lost-island build failed -- continuing without it" >&2
fi
rm -rf /tmp/lost-island
rm -f /etc/sudoers.d/kibabuild
userdel -r kibabuild 2>/dev/null||true
ADWAITA_ICONS="/usr/share/icons/Adwaita"
LAUNCHER_MASTER="/tmp/kibaos-launcher-icon.png"
if [ -f "$LOGO_256" ];then
cp "$LOGO_256" "$LAUNCHER_MASTER"
else
magick -size 512x512 xc:none \
-fill black -draw "circle 256,256 256,16" \
-stroke white -strokewidth 20 -fill none -draw "circle 256,256 256,60" \
"$LAUNCHER_MASTER"
fi
if [ -d "$ADWAITA_ICONS" ];then
find "$ADWAITA_ICONS" -path '*/places/start-here-symbolic.svg' -print0 2>/dev/null|while IFS= read -r -d '' _svg;do
_dir=$(dirname "$_svg")
_size=$(basename "$(dirname "$_dir")")
_px="${_size%%x*}"
case "$_px" in
''|*[!0-9]*)_px=256
esac
magick "$LAUNCHER_MASTER" -filter Lanczos -resize "${_px}x$_px" \
"$_dir/start-here-symbolic.png"
rm -f "$_svg"
done
gtk-update-icon-cache -f "$ADWAITA_ICONS" 2>/dev/null||true
fi
rm -f "$LAUNCHER_MASTER"
echo "=== Taskbar launcher icon: KibaOS boot-logo badge installed ==="
mkdir -p /usr/share/themes/KibaOS/gtk-3.0
mkdir -p /usr/share/themes/KibaOS/gtk-4.0
mkdir -p /etc/gtk-3.0
cat >/etc/gtk-3.0/settings.ini <<'GTK3RC'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
GTK3RC
mkdir -p /etc/gtk-4.0
cat >/etc/gtk-4.0/settings.ini <<'GTK4RC'
[Settings]
gtk-application-prefer-dark-theme=1
GTK4RC
cat >/etc/gtk-3.0/gtk.css <<'GTK3PANEL'
/* ════════════════════════════════════════════════════════════════════════
 * KibaOS Organic Motion Language
 * Nothing alive moves with symmetric, linear timing — things settle into
 * rest faster than they drift away from it. These three curves (named for
 * documentation; GTK CSS has no custom-property/var() support, so the
 * literal cubic-bezier values are repeated at each use site below) encode
 * that asymmetry instead of using GTK's default flat "ease":
 *
 *   settle  cubic-bezier(0.22, 1, 0.36, 1)     — easeOutQuint. Entering a
 *           state (hover, focus, opening). Quick, confident, no bounce.
 *   fade    cubic-bezier(0.5, 0, 0.75, 0)       — easeInQuart. Leaving a
 *           state. Slightly slower than settle — things drift off, they
 *           don't snap off.
 *   spring  cubic-bezier(0.34, 1.56, 0.64, 1)   — easeOutBack. Reserved
 *           for ONE thing only: the physical switch knob, where a small
 *           positional overshoot reads as a twig springing back rather
 *           than a robotic snap. Used nowhere else — overusing overshoot
 *           reads as cartoonish rather than organic.
 *   grow    cubic-bezier(0.16, 1, 0.3, 1)       — easeOutExpo. Reserved
 *           for STRUCTURAL reveals (Raven and the Budgie Menu appearing/
 *           dismissing), never for small in-place state changes. A leaf
 *           unfurling and a light switching on are different kinds of
 *           motion even though both are "something turning on" — settle
 *           is the latter (a value flips, fast and certain), grow is the
 *           former (a whole shape is arriving, slightly unhurried at the
 *           start before resolving quickly). Kept distinct from settle
 *           so the two don't blur into a single generic "ease-ish" feel.
 *
 * Organic radius scale — every corner-radius below is a mild asymmetric
 * quad (top-left top-right bottom-right bottom-left) instead of one flat
 * number on all four corners. The spread is deliberately small (2-6px on
 * surfaces in the 16-28px range) so it reads as machined-but-grown at a
 * glance — closer to a river stone or a leaf edge than a die-cut card —
 * without tipping into the blobby/cartoonish territory a bigger spread
 * would. Applied only to the handful of surfaces that carry the brand
 * (panel, Raven, Budgie Menu, OSD, tooltips, context menus), not to every
 * button and row — restraint matters more than coverage here.
 *
 * Caveat: this only governs GTK widget-state transitions — it's NOT doing
 * compositor-level window drag physics. KWin does ship its own Wobbly
 * Windows effect, but it isn't enabled by default in this image (see the
 * KWIN CONFIG section for the whole story on that), so window dragging is
 * flat/rigid movement for now — nothing to verify here, it's just off
 * until/unless that effect gets turned on. Raven/the Budgie Menu's
 * open/close slide is still Budgie's own compiled animation code, not GTK
 * CSS — the opacity transitions below are best-effort and may be
 * superseded by that native motion. Verify visually.
 * ════════════════════════════════════════════════════════════════════════ */

/* === KibaOS: Floating white squircle panel (top; the VibePanel dock sits at the bottom) ===
 * GTK3 CSS can't draw a true superellipse, so the "squircle" is a
 * rounded rectangle with a radius of ~38% of the 42px panel height (16px) --
 * (the old top bar is gone, so this is the only bar). White fill with
 * dark text/icons; the soft shadow keeps it readable on light wallpapers. */
.budgie-panel {
    margin: 8px 120px 0 120px;
    border-radius: 16px;
    background-image: none;
    background-color: #ffffff;
    color: #1b1f27;
    border: 1px solid rgba(0, 0, 0, 0.06);
    box-shadow:
        0 8px 28px rgba(0, 0, 0, 0.22),
        0 2px 6px  rgba(0, 0, 0, 0.12);
    padding: 0 10px;
}
.budgie-panel .budgie-applet-button,
.budgie-panel button.flat {
    border-radius: 12px;
    background: transparent;
    color: #1b1f27;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0); /* fade out */
}
.budgie-panel .budgie-applet-button:hover,
.budgie-panel button.flat:hover {
    background-color: rgba(0, 0, 0, 0.07);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1); /* settle in */
}
.budgie-panel .budgie-applet-button:active,
.budgie-panel button.flat:active {
    background-color: rgba(0, 153, 204, 0.25);
    transition: background-color 90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.budgie-panel .launcher:checked,
.budgie-panel .launcher.running {
    border-bottom: 2px solid #0099cc;
    border-radius: 0;
    transition: border-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: Raven (notification + quick-settings sidebar) as a floating glass card === */
frame.raven-frame,
.raven-background {
    margin: 8px 8px 8px 0;
    border-radius: 20px 26px 24px 28px;
    background-image: radial-gradient(ellipse at 80% -20%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.72);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow:
        0 12px 48px rgba(0, 0, 0, 0.50),
        inset 0 1px 0 rgba(255, 255, 255, 0.10);
    opacity: 1;
    transition: opacity 280ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
frame.raven-frame > border { border-style: none; box-shadow: none; }
.raven-header,
.raven-section-header {
    color: #e8eef5;
    font-weight: 600;
    padding: 14px 18px 6px 18px;
}
/* notification + applet rows rendered as individual cards */
.raven-background row,
.raven-background list row {
    margin: 5px 12px;
    padding: 10px 12px;
    border-radius: 14px;
    background-color: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background row:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* quick-toggle pills: wifi / bluetooth / focus / airplane mode, etc. */
.raven-background button.toggle,
.raven-background .quick-toggle {
    border-radius: 16px;
    background-color: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    padding: 10px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background button.toggle:checked,
.raven-background .quick-toggle:checked {
    background-color: rgba(0, 153, 204, 0.35);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    160ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* volume / brightness sliders as rounded pill tracks */
.raven-background scale trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
.raven-background scale highlight {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}
.raven-background scale slider {
    background-color: #ffffff;
    border-radius: 999px;
    min-width: 14px;
    min-height: 14px;
}

/* === KibaOS: Budgie Menu (app launcher popover) as a floating glass card === */
popover.budgie-menu,
.budgie-menu-window {
    border-radius: 22px 28px 20px 26px;
    background-image: radial-gradient(ellipse at 20% -30%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.80);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 12px 48px rgba(0, 0, 0, 0.50);
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
.budgie-menu-window entry,
popover.budgie-menu entry {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.10);
    padding: 8px 16px;
    color: #e8eef5;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.budgie-menu-window entry:focus,
popover.budgie-menu entry:focus {
    background-color: rgba(255, 255, 255, 0.12);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
button.budgie-menu-launcher {
    border-radius: 14px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button.budgie-menu-launcher:hover {
    background-color: rgba(0, 153, 204, 0.20);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: GTK places sidebar (Nemo + GTK open/save dialogs) glass card === */
placessidebar {
    background-color: transparent;
    border-radius: 18px;
}
placessidebar row {
    border-radius: 12px;
    margin: 2px 6px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
placessidebar row:selected {
    background-color: rgba(0, 153, 204, 0.25);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: switches everywhere (budgie-control-center, GTK apps) ========
 * The one and only spot using the "spring" overshoot curve — the knob
 * physically travels, so a little organic overshoot is visible motion,
 * not just a colour flicker. */
switch slider {
    transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1);
}
switch:checked {
    background-color: rgba(0, 153, 204, 0.85);
    transition: background-color 220ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch {
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* ════════════════════════════════════════════════════════════════════════
 * KibaOS extra polish pass — the small stuff that adds up
 * ════════════════════════════════════════════════════════════════════════ */

/* Crisp, on-brand focus rings instead of GTK's default dotted/heavy outline —
 * keyboard navigation should always be obvious, never ugly. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Tooltips as small glass cards, matching Raven/the menu popover language
 * instead of GTK's flat dark rectangle. */
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
tooltip decoration { background: transparent; box-shadow: none; }

/* Thin, rounded, low-profile scrollbars — always present but never loud. */
scrollbar {
    background-color: transparent;
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
scrollbar slider:active {
    background-color: rgba(0, 153, 204, 0.65);
}

/* Selected text uses the accent colour, not GTK's default blue. */
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}

/* Checkboxes/radios: rounded box, accent fill when checked, same settle/fade
 * pair as everything else — these were the one obviously-untouched stock
 * GTK widget left standing next to switches/sliders that already got it. */
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Progress bars: rounded pill track matching the volume/brightness sliders
 * in Raven, instead of GTK's square-edged default. */
progressbar trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
progressbar progress {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Right-click / app context menus as the same floating glass card as
 * Raven and the Budgie Menu, instead of a flat GTK menu rectangle. */
menu,
popover.menu > contents {
    background-color: rgba(20, 26, 40, 0.92);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 10px 14px 11px 13px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px;
}
menuitem,
modelbutton {
    border-radius: 8px;
    padding: 6px 10px;
    transition: background-color 180ms cubic-bezier(0.5, 0, 0.75, 0);
}
menuitem:hover,
modelbutton:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 120ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* The volume/brightness/etc. on-screen bezel (.osd) as a small floating
 * glass pill, matching everything else instead of GTK's plain dark box. */
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}

/* Unfocused windows recede slightly — a small depth cue that makes the
 * focused window unambiguous at a glance, especially with several floating
 * glass panels/popovers on screen at once. */
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}
window:not(:backdrop) {
    transition: opacity 180ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Linked button groups (segmented controls) read as one pill-shaped
 * control instead of GTK's default row of square-joined buttons. */
.linked > button {
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.linked > button:first-child { border-radius: 10px 0 0 10px; }
.linked > button:last-child  { border-radius: 0 10px 10px 0; }
GTK3PANEL
mkdir -p /etc/gtk-4.0
cat >/etc/gtk-4.0/gtk.css <<'GTK4CSS'
/* KibaOS unified GTK4 override */
@define-color accent_color #0099cc;
@define-color accent_bg_color #0099cc;
@define-color accent_fg_color #ffffff;
@define-color window_bg_color #1e2430;
@define-color window_fg_color #e8eef5;
@define-color view_bg_color #252c3a;
@define-color view_fg_color #dde5ef;
@define-color card_bg_color #2a3242;
@define-color popover_bg_color #2a3242;
@define-color sidebar_bg_color #1a2030;
@define-color headerbar_bg_color #1a2030;
@define-color headerbar_fg_color #dde5ef;

window, .window-frame          { border-radius: 16px 20px 18px 22px; }
headerbar                      { border-radius: 18px 22px 0 0; }
.card, frame, .frame           { border-radius: 13px 16px 14px 17px; }
button                         { border-radius: 10px; }
entry                          { border-radius: 10px; }
popover > contents             { border-radius: 14px 18px 13px 17px; }
.sidebar-row                   { border-radius: 8px; }
listview                       { border-radius: 12px; }
notebook > header              { border-radius: 12px 12px 0 0; }
button { box-shadow: none; -gtk-icon-shadow: none; }
.suggested-action { background: @accent_bg_color; color: @accent_fg_color; border: none; }
.suggested-action:hover { background: shade(@accent_bg_color, 0.88); }
headerbar { padding: 8px 12px; min-height: 44px; }
row        { padding: 4px 8px; }
/* Same faint moss-green (#7fae86) bloom as the GTK3 panel — the one
 * deliberate nature accent, kept identical across GTK3/GTK4 so a mixed
 * Budgie+libadwaita desktop still reads as one coherent surface. */
window {
    background-image: radial-gradient(ellipse at 30% -30%,
        rgba(127, 174, 134, 0.04), transparent 65%);
}

/* KibaOS organic motion — same settle/fade/grow set as GTK3 (see
 * gtk-3.0/gtk.css for the full naming/rationale); GTK4 apps get the same
 * asymmetric feel. */
button, row, .sidebar-row, switch slider {
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button:hover, row:hover, .sidebar-row:hover {
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch slider { transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1); }
popover > contents {
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal */
}

/* Same extra polish pass as gtk-3.0/gtk.css (see that file for the full
 * rationale on each rule) — GTK4/libadwaita apps get the same treatment
 * as Budgie's own chrome instead of looking like a different OS. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* libadwaita toasts (AdwToast — the little "Undo" bar that slides up from
 * the bottom) as the same floating glass pill as everything else. */
.toast {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 999px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px 6px;
}
.toast button {
    border-radius: 999px;
}
GTK4CSS
mkdir -p /usr/share/glib-2.0/schemas
glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null||true
mkdir -p /etc/greetd
: <<'DEAD_SDDM_THEME_BLOCK'
SDDM_THEME_DIR="/usr/share/sddm/themes/kibaos"
mkdir -p "${SDDM_THEME_DIR}"
cp /usr/share/kibaos/wallpaper.jpg  "${SDDM_THEME_DIR}/background.png"  2>/dev/null || true
cp /usr/share/kibaos/logo-256.png   "${SDDM_THEME_DIR}/logo.png"        2>/dev/null || true

cat > "${SDDM_THEME_DIR}/metadata.desktop" << 'SDDMMETA'
[SddmGreeterTheme]
Name=KibaOS
Description=KibaOS frosted-glass greeter
Author=WolfTech Innovations
Copyright=2026, WolfTech Innovations
License=GPLv3
Type=sddm-theme
Version=1.0
Website=https://github.com/WolfTech-Innovations/Kiba
MainScript=Main.qml
Font=Nunito
QuickVersion=6
SDDMMETA

cat > "${SDDM_THEME_DIR}/Main.qml" << 'SDDMQML'
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// KibaOS greeter -- written into the image at ISO customize time inside
// the chroot. The layout adapts itself at runtime off Screen.width, so a
// single theme covers a 1920x1080 desktop panel as well as small or
// portrait panels (the isPhone branches below are just the compact layout).
Rectangle {
    id: root
    width: Screen.width  > 0 ? Screen.width  : 1920
    height: Screen.height > 0 ? Screen.height : 1080
    color: "#0d1b2a"
    focus: true

    // phoc's own config scales the DSI panel output 2x at the Wayland
    // protocol level (see phoc.ini's [output:DSI-1] scale=2) -- Qt's
    // Wayland QPA backend reads that wl_output scale itself and already
    // renders this file's logical pixels at the right physical density,
    // so nothing extra is needed here for HiDPI; this width/height check
    // is purely about aspect ratio/orientation, not pixel density.
    readonly property bool isPhone: width < 700
    readonly property int touchH: isPhone ? 56 : 44
    readonly property int fieldR: isPhone ? 18 : 14

    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // ── Background wallpaper, darkened so the glass card pops ──────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        color: "#0d1b2a"
        opacity: 0.42
    }

    // ── Clock ────────────────────────────────────────────────────────────
    // Desktop: small pill, top-right, matches the KibaOS panel style.
    // Phone: big lockscreen-style clock, top-center, clear of any status
    // bar / camera-cutout safe area -- Android/iOS lockscreen convention,
    // and it doubles as a landmark while your thumb finds the card below.
    Column {
        id: clockCol
        anchors {
            top: parent.top
            topMargin: isPhone ? 64 : 28
        }
        anchors.horizontalCenter: isPhone ? parent.horizontalCenter : undefined
        anchors.right: isPhone ? undefined : parent.right
        anchors.rightMargin: isPhone ? 0 : 28
        spacing: isPhone ? 4 : 0
        Text {
            id: clockTime
            text: Qt.formatTime(new Date(), "h:mm AP")
            color: "#ffffff"
            font.pixelSize: isPhone ? 56 : 18
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: Qt.formatDate(new Date(), "ddd, MMM d")
            color: "#aebccd"
            font.pixelSize: isPhone ? 16 : 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Timer { interval: 1000; running: true; repeat: true; onTriggered: clockTime.text = Qt.formatTime(new Date(), "h:mm AP") }
    }

    // ── Central frosted-glass login card ────────────────────────────────────
    // Desktop: fixed 360px, dead-centered, unchanged from before.
    // Phone: full-width (minus margins), anchored in the lower half
    // rather than dead-center -- that's within comfortable one-handed
    // thumb reach, and critically it leaves the *upper* half of the
    // screen clear for squeekboard to pop up underneath without ever
    // covering the password field it's currently focused on.
    Rectangle {
        id: card
        anchors {
            horizontalCenter: isPhone ? parent.horizontalCenter : undefined
            centerIn: isPhone ? undefined : parent
            bottom: isPhone ? parent.bottom : undefined
            bottomMargin: isPhone ? 96 : 0
        }
        width: isPhone ? parent.width - 48 : 360
        height: cardCol.implicitHeight + (isPhone ? 40 : 56)
        radius: isPhone ? 32 : 26
        color: "#101828"
        opacity: 0.001
        // emulated glass: just a solid translucent fill, no real blur.
        // KWin's own Blur effect is real and available in the actual
        // session, but the SDDM greeter renders on its own standalone
        // Qt Quick surface before any session (or its compositor) is
        // even running — see KWIN CONFIG notes for the full story on
        // why this greeter can't just borrow it — so this fake-glass
        // approach is doing all the work here now, not just backstopping
        // a spot where real blur wouldn't reach anyway.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(0.063, 0.094, 0.157, 0.72)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        ColumnLayout {
            id: cardCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: isPhone ? 24 : 28 }
            spacing: isPhone ? 16 : 14

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "logo.png"
                width: isPhone ? 56 : 64; height: isPhone ? 56 : 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: userModel.count > 0 ? userModel.data(userModel.index(userList.currentIndex, 0), 257) : "User"
                color: "#e8eef5"; font.pixelSize: isPhone ? 19 : 17; font.weight: Font.Medium
            }

            ListView {
                id: userList
                Layout.fillWidth: true
                height: 0; visible: false  // names shown via combo below instead
                model: userModel
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
            }

            ComboBox {
                id: userBox
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                model: userModel
                textRole: "name"
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
                font.pixelSize: isPhone ? 16 : 13
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                contentItem: Text { text: userBox.displayText; color: "#e8eef5"; font: userBox.font; padding: 10; verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                placeholderText: "Password"
                echoMode: TextInput.Password
                color: "#e8eef5"
                font.pixelSize: isPhone ? 16 : 13
                placeholderTextColor: "#8a99ad"
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                onAccepted: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                Keys.onReturnPressed: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
            }

            Button {
                id: loginButton
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                text: "Sign In"
                onClicked: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                background: Rectangle { radius: fieldR; color: "#0099cc" }
                contentItem: Text { text: loginButton.text; color: "#ffffff"; font.pixelSize: isPhone ? 16 : 13; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
            }

            // Session picker: only worth showing where there's actually
            // more than one to pick from. Desktop offers Budgie/etc
            // session choices; compact layouts hide it to keep the card
            // small and avoid accidental taps.
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: isPhone ? 0 : undefined
                visible: !isPhone
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: root.sessionIndex = currentIndex
                background: Rectangle { radius: fieldR; color: "transparent" }
                contentItem: Text { text: parent.displayText; color: "#aebccd"; font.pixelSize: 11; padding: 6; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ── Power row ────────────────────────────────────────────────────────
    // Desktop: small 44px pills, bottom-right, unchanged.
    // Phone: bigger 56px targets (comfortable thumb-tap size), moved to
    // top-right instead -- bottom-right on a phone sits right where the
    // login card's bottom edge and any on-screen-keyboard region already
    // are, so it's both more reachable and less likely to be covered.
    Row {
        anchors {
            top: isPhone ? parent.top : undefined
            bottom: isPhone ? undefined : parent.bottom
            right: parent.right
            margins: isPhone ? 24 : 28
        }
        spacing: isPhone ? 14 : 10
        Repeater {
            model: [
                { label: "⏻", visible: sddm.canPowerOff, action: function(){ sddm.powerOff() } },
                { label: "⟲", visible: sddm.canReboot,   action: function(){ sddm.reboot()   } }
            ]
            delegate: Rectangle {
                visible: modelData.visible
                width: touchH; height: touchH; radius: fieldR
                color: "#1c2433"; opacity: 0.78
                Text { anchors.centerIn: parent; text: modelData.label; color: "#e8eef5"; font.pixelSize: isPhone ? 22 : 18 }
                MouseArea { anchors.fill: parent; onClicked: modelData.action() }
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { passwordField.text = ""; passwordField.placeholderText = "Incorrect password"; }
    }

    Component.onCompleted: passwordField.forceActiveFocus()
}
SDDMQML
DEAD_SDDM_THEME_BLOCK
mkdir -p /usr/share/wayland-sessions
rm -rf /usr/share/wayland-sessions/budgie-desktop.desktop
SKEL="/etc/skel"
mkdir -p "$SKEL/.config/autostart"
cat >/usr/local/bin/kibaos-greetd-config <<'GREETDCFGSCRIPT'
#!/bin/bash
set -e
_user="${1:-}"
mkdir -p /etc/greetd
_tmp="$(mktemp /etc/greetd/.kibaos.toml.XXXXXX)"
{
printf '[terminal]\nvt = 1\n\n'
printf '[default_session]\n'
printf 'command = "/usr/lib/kibaos-greeter/kibaos-greeter-session"\n'
printf 'user = "greeter"\n'
if [ -n "$_user" ];then
_cmd="/usr/bin/kibaos-session-supervisor /usr/bin/chromiumos-ash-session"
printf '\n[initial_session]\ncommand = "%s"\nuser = "%s"\n' "$_cmd" "$_user"
fi
} >"$_tmp"
chmod 644 "$_tmp"
mv -f "$_tmp" /etc/greetd/kibaos.toml
GREETDCFGSCRIPT
chmod 755 /usr/local/bin/kibaos-greetd-config
/usr/local/bin/kibaos-greetd-config
mkdir -p /var/lib/AccountsService/users
cat >/var/lib/AccountsService/users/liveuser <<'LIVEUSERACCOUNTS'
[User]
Session=chromiumos-ash
XSession=chromiumos-ash
SystemAccount=false
LIVEUSERACCOUNTS
chmod 600 /var/lib/AccountsService/users/liveuser
chown root:root /var/lib/AccountsService/users/liveuser
grep -qx '/bin/bash' /etc/shells||echo '/bin/bash' >>/etc/shells
if [ -f /etc/pam.d/greetd ]&&[ -e /usr/lib/security/pam_gnome_keyring.so ]&&! grep -q pam_gnome_keyring /etc/pam.d/greetd;then
echo 'auth       optional     pam_gnome_keyring.so' >>/etc/pam.d/greetd
echo 'session    optional     pam_gnome_keyring.so auto_start' >>/etc/pam.d/greetd
fi
passwd -u liveuser 2>/dev/null||true
chage -I -1 -m 0 -M 99999 -E -1 liveuser 2>/dev/null||true
cat >/usr/local/bin/kibaos-live-autologin <<'LIVEAUTOLOGIN'
#!/bin/bash
[ -d /run/archiso ]||exit 0
id liveuser >/dev/null 2>&1||exit 0
if ! grep -qs '^user = "liveuser"' /etc/greetd/kibaos.toml;then
/usr/local/bin/kibaos-greetd-config liveuser
logger -t kibaos-live-autologin "greetd config was missing autologin; rewrote it"
fi
rm -f /run/greetd.run
mkdir -p /var/lib/AccountsService/users
if ! grep -qs '^Session=chromiumos-ash' /var/lib/AccountsService/users/liveuser;then
printf '[User]\nSession=chromiumos-ash\nXSession=chromiumos-ash\nSystemAccount=false\n' >/var/lib/AccountsService/users/liveuser
chmod 600 /var/lib/AccountsService/users/liveuser
fi
passwd -u liveuser >/dev/null 2>&1||true
exit 0
LIVEAUTOLOGIN
chmod +x /usr/local/bin/kibaos-live-autologin
cat >/etc/systemd/system/kibaos-live-autologin.service <<'LIVEAUTOLOGINSVC'
[Unit]
Description=Ensure greetd autologin for the KibaOS live user
Before=kibaos-greetd.service display-manager.service
After=local-fs.target systemd-sysusers.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-live-autologin

[Install]
WantedBy=graphical.target
LIVEAUTOLOGINSVC
systemctl enable kibaos-live-autologin.service
cat >/usr/local/bin/kibaos-wait-drm <<'WAITDRM'
#!/bin/bash
for _ in $(seq 1 40);do
for c in /sys/class/drm/card[0-9]*;do
[ -e "$c/device/driver" ]||continue
drv="$(basename "$(readlink -f "$c/device/driver")")"
case "$drv" in
simpledrm|simple-framebuffer|simplefb|efifb|vesafb);;
*)exit 0
esac
done
sleep 0.5
done
logger -t kibaos-wait-drm "no non-simpledrm GPU driver after 20s, starting greetd anyway"
exit 0
WAITDRM
chmod +x /usr/local/bin/kibaos-wait-drm
mkdir -p /etc/systemd/system/kibaos-greetd.service.d
cat >/etc/systemd/system/kibaos-greetd.service.d/10-kibaos-wait-drm.conf <<'GDMWAITDRM'
[Service]
ExecStartPre=/usr/local/bin/kibaos-wait-drm
TimeoutStartSec=90
GDMWAITDRM
cat >/usr/local/bin/kibaos-gpu-select <<'GPUSELECT'
#!/bin/bash
for d in /sys/bus/pci/devices/*;do
[ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ]||continue
case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*);;*)continue;esac
id=$(($(cat "$d/device")))
if [ "$id" -lt $((0x1e00)) ];then
logger -t kibaos-gpu-select "pre-Turing NVIDIA GPU $(cat "$d/device"): using nouveau"
modprobe nouveau||true
exit 0
fi
done
exit 0
GPUSELECT
chmod +x /usr/local/bin/kibaos-gpu-select
cat >/etc/systemd/system/kibaos-gpu-select.service <<'GPUSELECTSVC'
[Unit]
Description=Use nouveau for NVIDIA GPUs the open kernel modules do not support
After=systemd-udev-trigger.service
Before=kibaos-greetd.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-gpu-select

[Install]
WantedBy=graphical.target
GPUSELECTSVC
systemctl enable kibaos-gpu-select.service
for _f in /usr/share/wayland-sessions/chromiumos-ash.desktop /usr/bin/kibaos-session-supervisor /usr/lib/systemd/system/kibaos-greetd.service /usr/lib/kibaos-greeter/kibaos-greeter-session /usr/bin/weston;do
[ -e "$_f" ]||{
echo "ERROR: autologin prerequisite missing: $_f" >&2
exit 1
}
done
id greeter >/dev/null 2>&1||echo "WARNING: greeter user missing at build time (created by sysusers at boot)" >&2
if [ ! -f /etc/pam.d/greetd ];then
printf '#%PAM-1.0\nauth       required     pam_securetty.so\nauth       requisite    pam_nologin.so\nauth       include      system-local-login\naccount    include      system-local-login\nsession    include      system-local-login\n' >/etc/pam.d/greetd
fi
mkdir -p /var/lib/kibaos-greeter /var/cache/kibaos-greeter
chown greeter:greeter /var/lib/kibaos-greeter /var/cache/kibaos-greeter 2>/dev/null||true
cat >/usr/local/bin/kibaos-screenshot <<'SCREENSHOT'
#!/bin/bash
set -euo pipefail
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/Screenshot from $(date '+%Y-%m-%d %H-%M-%S').png"
if [ "${1:-}" = "region" ];then
GEOM=$(slurp)||exit 0
grim -g "$GEOM" "$FILE"
else
grim "$FILE"
fi
wl-copy <"$FILE"
notify-send -i "$FILE" "Screenshot saved" "Copied to clipboard · $(basename "$FILE")"
SCREENSHOT
chmod +x /usr/local/bin/kibaos-screenshot
cat >/usr/local/bin/kibaos-screenshot-ocr <<'SCREENSHOTOCR'
#!/bin/bash
set -euo pipefail
GEOM=$(slurp)||exit 0
TMP=$(mktemp --suffix=.png -t kibaos-ocr.XXXXXX)
trap 'rm -f "$TMP"' EXIT
grim -g "$GEOM" "$TMP"
TEXT=$(tesseract "$TMP" - 2>/dev/null|sed -e '$ { /^$/d }')
if [ -z "$TEXT" ];then
notify-send "Screenshot OCR" "No text found in that selection."
exit 0
fi
printf '%s' "$TEXT"|wl-copy
PREVIEW=$(printf '%s' "$TEXT"|head -c 120)
notify-send "Text copied to clipboard" "$PREVIEW$([ ${#TEXT} -gt 120 ]&&echo …)"
SCREENSHOTOCR
chmod +x /usr/local/bin/kibaos-screenshot-ocr
cat >/usr/local/bin/kibaos-apply-output-scale <<'OUTPUTSCALE'
#!/bin/bash
for _ in 1 2 3 4 5;do
wlr-randr >/tmp/.kiba-outputs 2>/dev/null&&[ -s /tmp/.kiba-outputs ]&&break
sleep 1
done
[ -s /tmp/.kiba-outputs ]||exit 0
current_name=""
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""
apply_scale(){
[ -n "$current_name" ]||return
scale=1
if [ -n "$current_mm_w" ]&&[ "$current_mm_w" -gt 0 ] 2>/dev/null;then
dpi=$((current_w*254/(current_mm_w * 10)))
if [ "$dpi" -ge 168 ];then
scale=2
fi
elif [ -n "$current_w" ]&&[ "$current_w" -ge 3000 ] 2>/dev/null;then
scale=2
fi
wlr-randr --output "$current_name" --scale "$scale" >/dev/null 2>&1
}
while IFS= read -r line;do
case "$line" in
[A-Za-z]*)apply_scale
current_name=$(printf '%s' "$line"|awk '{print $1}')
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""
;;
*"Physical size:"*)dims=$(printf '%s' "$line"|grep -oE '[0-9]+x[0-9]+')
current_mm_w=${dims%x*}
current_mm_h=${dims#*x}
;;
*"current"*)dims=$(printf '%s' "$line"|grep -oE '^[[:space:]]*[0-9]+x[0-9]+'|tr -d ' ')
current_w=${dims%x*}
current_h=${dims#*x}
esac
done </tmp/.kiba-outputs
apply_scale
rm -f /tmp/.kiba-outputs
OUTPUTSCALE
chmod +x /usr/local/bin/kibaos-apply-output-scale
OTA_PUBKEY_URL="https://raw.githubusercontent.com/WolfTech-Innovations/Kiba/main/ota/ota-public.asc"
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
mkdir -p /etc/kibaos /var/lib/kibaos-ota /var/log/kibaos
curl -fsSL --retry 3 "$OTA_PUBKEY_URL" -o /tmp/ota-public.asc 2>/dev/null&&gpg --no-default-keyring --keyring "$OTA_KEYRING" \
--import /tmp/ota-public.asc 2>/dev/null||true
rm -f /tmp/ota-public.asc
echo "0" >/etc/kibaos/patch-level
cat >/usr/local/bin/kibaos-ota <<'OTASCRIPT'
#!/usr/bin/env bash
set -euo pipefail
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
PATCH_LEVEL_FILE="/etc/kibaos/patch-level"
OTA_WORKDIR="/var/lib/kibaos-ota"
OTA_LOG="/var/log/kibaos/ota.log"
FREEZE_PID_FILE="/tmp/kibaos-fb-freeze.pid"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$OTA_LOG";}
fb_freeze(){
log "Freezing display with framebuffer snapshot..."
SNAP="/tmp/kibaos-ota-snap.png"
SNAP_RAW="/tmp/kibaos-ota-snap.raw"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
XDG_RUNTIME_DIR="/run/user/1000"
runuser -u liveuser -- env \
WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
grim "$SNAP" 2>/dev/null||true
if [ -f "$SNAP" ];then
FB_WIDTH=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null|cut -d',' -f1||echo 1920)
FB_HEIGHT=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null|cut -d',' -f2||echo 1080)
magick "$SNAP" -resize "${FB_WIDTH}x$FB_HEIGHT!" \
-depth 8 bgr:"$SNAP_RAW" 2>/dev/null||true
if [ -f "$SNAP_RAW" ]&&[ -w /dev/fb0 ];then
cat "$SNAP_RAW" >/dev/fb0 2>/dev/null||true
fi
fi
python3 - <<'UINPUT_WIGGLE'&
import struct, time, os, fcntl

EV_REL, REL_X, REL_Y = 0x02, 0x00, 0x01
EV_SYN, SYN_REPORT    = 0x00, 0x00

def emit(fd, typ, code, val):
    fd.write(struct.pack('llHHi', 0, 0, typ, code, val))

try:
    UI_SET_EVBIT  = 0x40045564
    UI_SET_RELBIT = 0x40045566
    UINPUT_DEV_SZ = 1452 + 4 * (64 + 64 + 48 + 48)
    UI_DEV_CREATE = 0x5501
    UI_DEV_DESTROY= 0x5502

    fd = open('/dev/uinput', 'wb', buffering=0)
    fcntl.ioctl(fd, UI_SET_EVBIT,  EV_REL)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    dev = struct.pack('80sHHIII', b'kibaos-cursor', 0, 0, 0, 0, 0)
    dev = dev.ljust(UINPUT_DEV_SZ, b'\x00')
    fd.write(dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    for _ in range(60):
        emit(fd, EV_REL, REL_X,  1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
        emit(fd, EV_REL, REL_X, -1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    fd.close()
except Exception:
    pass
UINPUT_WIGGLE
echo $! >"$FREEZE_PID_FILE"
log "Framebuffer freeze active (PID $(cat $FREEZE_PID_FILE))."
}
fb_unfreeze(){
if [ -f "$FREEZE_PID_FILE" ];then
kill "$(cat $FREEZE_PID_FILE)" 2>/dev/null||true
rm -f "$FREEZE_PID_FILE"
fi
rm -f /tmp/kibaos-ota-snap.png /tmp/kibaos-ota-snap.raw
log "Framebuffer freeze released."
}
apply_patch(){
log "Applying patch $LATEST..."
ROLLBACK_DIR="$OTA_WORKDIR/rollback-$CURRENT"
mkdir -p "$ROLLBACK_DIR"
while IFS= read -r line;do
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
SRC="$EXTRACT_DIR/$FILEPATH"
DST="/$FILEPATH"
[ -f "$SRC" ]||continue
if [ -f "$DST" ];then
BACKUP_PATH="$ROLLBACK_DIR/$FILEPATH"
mkdir -p "$(dirname $BACKUP_PATH)"
cp -a "$DST" "$BACKUP_PATH"
fi
mkdir -p "$(dirname $DST)"
cp -a "$SRC" "$DST.ota-tmp"
mv "$DST.ota-tmp" "$DST"
log "  Patched: $DST"
done <"$MANIFEST"
log "Patch applied."
}
rollback_patch(){
ROLLBACK_DIR="$OTA_WORKDIR/rollback-$CURRENT"
log "ROLLING BACK to patch level $CURRENT..."
if [ -d "$ROLLBACK_DIR" ];then
find "$ROLLBACK_DIR" -type f|while read -r BACKUP;do
FILEPATH="${BACKUP#$ROLLBACK_DIR/}"
DST="/$FILEPATH"
mkdir -p "$(dirname $DST)"
cp -a "$BACKUP" "$DST"
done
log "Rollback complete."
else
log "No rollback data found. Cannot roll back."
fi
}
restart_compositor(){
log "Restarting session..."
{
[ -d /run/archiso ]&&rm -f /run/greetd.run
systemctl restart kibaos-greetd 2>/dev/null
}||pkill -TERM weston 2>/dev/null||true
sleep 1
log "Session restarted."
}
restart_display_manager(){
log "Restarting greetd..."
[ -d /run/archiso ]&&rm -f /run/greetd.run
systemctl restart kibaos-greetd
for i in $(seq 1 20);do
[ -S "/run/user/1000/${WAYLAND_DISPLAY:-wayland-0}" ]&&break
sleep 0.5
done
log "greetd restarted."
}
run_post_hooks(){
log "Running post-patch hooks..."
grep -q 'usr/share/icons' "$MANIFEST"&&gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
grep -q 'usr/share/glib-2.0/schemas' "$MANIFEST"&&glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null||true
grep -q 'usr/share/mime' "$MANIFEST"&&update-mime-database /usr/share/mime 2>/dev/null||true
grep -q 'usr/lib/systemd' "$MANIFEST"&&systemctl daemon-reload 2>/dev/null||true
log "Post-patch hooks complete."
}
if [ "${1:-}" = "rollback" ];then
shift||true
REASON="cli:unspecified"
while [ $# -gt 0 ];do
case "${1:-}" in
--reason)REASON="${2:-$REASON}"
shift 2||break
;;
*)shift
esac
done
CURRENT=$(cat "$PATCH_LEVEL_FILE" 2>/dev/null||echo 0)
log "Manual rollback requested (reason: $REASON)"
if [ -d "$OTA_WORKDIR/rollback-$CURRENT" ];then
fb_freeze
rollback_patch
restart_compositor
restart_display_manager
fb_unfreeze
log "Manual rollback finished."
exit 0
else
log "No rollback data available for patch level $CURRENT. Nothing to roll back."
exit 1
fi
fi
CURRENT=$(cat "$PATCH_LEVEL_FILE" 2>/dev/null||echo 0)
log "Current patch level: $CURRENT"
LATEST=$(curl -fsSL --retry 3 --max-time 10 \
"$OTA_BASE/latest-patch-level" 2>/dev/null|tr -d '[:space:]')||{
log "Could not reach OTA server. Skipping."
exit 0
}
if ! [[ $LATEST =~ ^[0-9]+$ ]];then
log "Invalid patch level received: '$LATEST'. Skipping."
exit 0
fi
if [ "$LATEST" -le "$CURRENT" ];then
log "Already up to date (patch level $CURRENT)."
exit 0
fi
log "New patch available: $CURRENT → $LATEST"
DEV_ARCH="$(uname -m)"
PATCH_TAR="$OTA_WORKDIR/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz"
PATCH_SIG="$PATCH_TAR.asc"
MANIFEST="$OTA_WORKDIR/manifest-$LATEST-$DEV_ARCH.txt"
mkdir -p "$OTA_WORKDIR"
log "Downloading patch $LATEST ($DEV_ARCH)..."
curl -fsSL --retry 3 --max-time 120 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz" -o "$PATCH_TAR"||{
log "Download failed. Skipping."
exit 0
}
curl -fsSL --retry 3 --max-time 30 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz.asc" -o "$PATCH_SIG"||{
log "Signature download failed. Aborting for safety."
rm -f "$PATCH_TAR"
exit 1
}
curl -fsSL --retry 3 --max-time 30 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH-manifest.txt" -o "$MANIFEST"||{
log "Manifest download failed. Aborting."
rm -f "$PATCH_TAR" "$PATCH_SIG"
exit 1
}
log "Verifying signature..."
if ! gpg --no-default-keyring --keyring "$OTA_KEYRING" \
--verify "$PATCH_SIG" "$PATCH_TAR" 2>/dev/null;then
log "SIGNATURE VERIFICATION FAILED. Patch rejected. Possible tampering."
rm -f "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
exit 1
fi
log "Signature verified."
log "Verifying checksums..."
EXTRACT_DIR="$OTA_WORKDIR/patch-$LATEST"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar xzf "$PATCH_TAR" -C "$EXTRACT_DIR"
while IFS= read -r line;do
EXPECTED_HASH=$(echo "$line"|awk '{print $1}')
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
ACTUAL_HASH=$(sha256sum "$EXTRACT_DIR/$FILEPATH" 2>/dev/null|awk '{print $1}')
if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ];then
log "CHECKSUM MISMATCH for $FILEPATH. Aborting."
rm -rf "$EXTRACT_DIR" "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
exit 1
fi
done <"$MANIFEST"
log "All checksums verified."
NEEDS_DISPLAY_RESTART=false
NEEDS_COMPOSITOR_RESTART=false
while IFS= read -r line;do
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
case "$FILEPATH" in
etc/greetd*|usr/bin/greetd*|usr/bin/kibaos-greeter*|usr/lib/kibaos-greeter*)NEEDS_DISPLAY_RESTART=true
;;
usr/bin/weston*)NEEDS_COMPOSITOR_RESTART=true
esac
done <"$MANIFEST"
_active_user_info(){
loginctl list-sessions --no-legend 2>/dev/null|while read -r _sid _uid _user _rest;do
[ "$_user" = "greeter" ]&&continue
[ "$(loginctl show-session "$_sid" -p Class --value 2>/dev/null)" = "user" ]||continue
[ "$(loginctl show-session "$_sid" -p Active --value 2>/dev/null)" = "yes" ]||continue
echo "$_uid $_user"
break
done||true
}
as_desktop_user(){
local uid="" user="" sock=""
read -r uid user <<<"$(_active_user_info)"||true
[ -n "$uid" ]||return 1
sock=$(ls "/run/user/$uid"/wayland-* 2>/dev/null|grep -v '\.lock$'|head -n1||true)
runuser -u "$user" -- env \
XDG_RUNTIME_DIR="/run/user/$uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
WAYLAND_DISPLAY="$(basename "${sock:-wayland-0}")" \
GDK_BACKEND=wayland \
"$@"
}
ui_updating(){
as_desktop_user zenity --info --no-wrap --timeout=20 \
--title="KibaOS is updating" \
--text=$'<b>KibaOS is installing a small update.</b>\n\nYou can keep working \xe2\x80\x94 this won\'t interrupt anything.\nWe\'ll only ask you to restart if it\'s really needed.' > \
/dev/null 2>&1&
return 0
}
ui_notify(){
as_desktop_user notify-send -a "KibaOS" -i software-update-available "$1" "$2" >/dev/null 2>&1||true
}
ui_ask_restart(){
as_desktop_user zenity --question --no-wrap --timeout=300 \
--title="One quick restart needed" \
--ok-label="Restart now" --cancel-label="Later" \
--text=$'<b>This update needs the screen to restart to finish.</b>\n\nIt only takes a few seconds, but open apps will close,\nso please save your work first.\n\nChoose \xe2\x80\x9cLater\xe2\x80\x9d and nothing changes \xe2\x80\x94 the update will\nfinish by itself the next time you sign in.' > \
/dev/null 2>&1
}
do_session_restart(){
fb_freeze
if $NEEDS_COMPOSITOR_RESTART;then
restart_compositor
fi
if $NEEDS_DISPLAY_RESTART;then
restart_display_manager
fi
fb_unfreeze
}
ui_updating||true
if ! apply_patch;then
log "Patch application failed. Initiating rollback."
rollback_patch
fb_unfreeze
ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
exit 1
fi
if ! run_post_hooks;then
log "Post-patch hooks failed. Initiating rollback."
rollback_patch
fb_unfreeze
ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
exit 1
fi
echo "$LATEST" >"$PATCH_LEVEL_FILE"
if $NEEDS_DISPLAY_RESTART||$NEEDS_COMPOSITOR_RESTART;then
if [ -n "$(_active_user_info)" ];then
if ui_ask_restart;then
log "User chose to restart now."
do_session_restart
else
log "User chose Later (or didn't answer) -- deferring session restart."
mkdir -p "$OTA_WORKDIR"
touch "$OTA_WORKDIR/restart-deferred"
ui_notify "KibaOS update installed" "It'll finish by itself the next time you sign in. Nothing else to do."
fi
else
log "Nobody is signed in -- restarting the session now."
do_session_restart
fi
else
ui_notify "KibaOS is up to date" "The update finished. Nothing else to do."
fi
log "Successfully updated to patch level $LATEST."
rm -rf "$EXTRACT_DIR" "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
log "Done."
OTASCRIPT
chmod +x /usr/local/bin/kibaos-ota
cat >/etc/systemd/system/kibaos-ota.service <<'OTASVC'
[Unit]
Description=KibaOS OTA Live Patch Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-ota
StandardOutput=append:/var/log/kibaos/ota.log
StandardError=append:/var/log/kibaos/ota.log
OTASVC
cat >/etc/systemd/system/kibaos-ota.timer <<'OTATIMER'
[Unit]
Description=KibaOS OTA patch check every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=3min
Persistent=true

[Install]
WantedBy=timers.target
OTATIMER
systemctl enable kibaos-ota.timer
cat >/usr/local/bin/kibaos-firstboot-groups <<'FIRSTBOOTGROUPS'
#!/usr/bin/env bash
set -euo pipefail
MARKER="/etc/kibaos/pending-user-groups"
[ -f "$MARKER" ]||exit 0
while IFS=: read -r username groups;do
[ -n "$username" ]||continue
IFS=',' read -ra group_arr <<<"$groups"
add_groups=()
for g in "${group_arr[@]}";do
if getent group "$g" >/dev/null 2>&1;then
add_groups+=("$g")
else
echo "kibaos-firstboot-groups: '$g' still doesn't exist, leaving pending" >&2
fi
done
if [ "${#add_groups[@]}" -gt 0 ];then
joined=$(IFS=,
echo "${add_groups[*]}")
usermod -aG "$joined" "$username"&&echo "kibaos-firstboot-groups: added $username to $joined"||echo "kibaos-firstboot-groups: usermod failed for $username" >&2
fi
done <"$MARKER"
if ! grep -qE ':.*[a-zA-Z]' "$MARKER" 2>/dev/null||! awk -F: '{print $2}' "$MARKER"|tr ',' '\n'|while read -r g;do
[ -n "$g" ]&&! getent group "$g" >/dev/null 2>&1&&exit 1
done;then
:
else
rm -f "$MARKER"
fi
FIRSTBOOTGROUPS
chmod +x /usr/local/bin/kibaos-firstboot-groups
cat >/etc/systemd/system/kibaos-firstboot-groups.service <<'FIRSTBOOTSVC'
[Unit]
Description=KibaOS first-boot group catch-up
After=systemd-sysusers.service
Wants=systemd-sysusers.service
ConditionPathExists=/etc/kibaos/pending-user-groups

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-firstboot-groups
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
FIRSTBOOTSVC
systemctl enable kibaos-firstboot-groups.service
SKEL="/etc/skel"
mkdir -p \
"$SKEL/.config/gtk-3.0" \
"$SKEL/.config/gtk-4.0" \
"$SKEL/.config/autostart" \
"$SKEL/.config/fastfetch"
cat >"$SKEL/.config/gtk-3.0/settings.ini" <<'GTK3SKEL'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
gtk-button-images=1
gtk-menu-images=1
gtk-enable-animations=1
GTK3SKEL
cp /etc/gtk-3.0/gtk.css "$SKEL/.config/gtk-3.0/gtk.css"
cp /etc/gtk-4.0/gtk.css "$SKEL/.config/gtk-4.0/gtk.css"
glib-compile-schemas /usr/share/glib-2.0/schemas/
cat >/usr/local/bin/kibaos-first-login <<'FIRSTLOGIN'
#!/usr/bin/env bash
STAMP="$HOME/.config/.kibaos-configured"
[ -f "$STAMP" ]&&exit 0
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
gsettings set org.gnome.desktop.interface cursor-size 24
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface enable-animations true
gsettings set org.gnome.desktop.interface text-scaling-factor 1.0
gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-options 'zoom'
gsettings set org.gnome.desktop.background primary-color '#0d1b2a'
gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
gsettings set org.gnome.desktop.wm.preferences num-workspaces 4
gsettings set org.gnome.desktop.wm.preferences focus-mode 'click'
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
gsettings set org.gnome.desktop.peripherals.mouse natural-scroll false
gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'adaptive'
touch "$STAMP"
FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login
cat >"$SKEL/.config/autostart/kibaos-configure.desktop" <<'AUTOCFG'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOCFG
cat >"$SKEL/.config/autostart/kibaos-oem-finish.desktop" <<'OEMAUTOCFG'
[Desktop Entry]
Type=Application
Name=Finish Setting Up KibaOS
Exec=sh -c 'test -f /etc/kibaos/oem-pending && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
OEMAUTOCFG
cat >"$SKEL/.config/autostart/kibaos-install-launch.desktop" <<'LIVELAUNCH'
[Desktop Entry]
Type=Application
Name=KibaOS Installer
Exec=sh -c '[ "$(whoami)" = "liveuser" ] && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
LIVELAUNCH
mkdir -p /etc/systemd/zram-generator.conf.d
cat >/etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM
mkdir -p "$SKEL/.config"
mkdir -p "$SKEL/.config/fontconfig"
cat >"$SKEL/.config/fontconfig/fonts.conf" <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>
</fontconfig>
FONTCONF
cat >"$SKEL/.config/electron-flags.conf" <<'ELECTRONFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
--enable-wayland-ime
ELECTRONFLAGS
cat >"$SKEL/.config/chrome-flags.conf" <<'CHROMEFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHROMEFLAGS
cat >"$SKEL/.config/autostart/polkit-agent.desktop" <<'POLKIT'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-kde-authentication-agent-1
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
POLKIT
cat >"$SKEL/.bashrc" <<'BASHRC'
[[ $- != *i* ]] && return
PS1='\[\e[1;36m\][KibaOS]\[\e[0m\] \[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
alias install='io.kibaos.oobe'
alias update='sudo kiba update'
fastfetch 2>/dev/null || true
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export HISTFILE="$XDG_STATE_HOME/bash/history"
BASHRC
mkdir -p "$SKEL/.config/fastfetch"
cat >"$SKEL/.config/fastfetch/config.jsonc" <<'FFCONF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "source": "kibaos",
    "color": { "1": "cyan", "2": "white" },
    "padding": { "top": 1 }
  },
  "display": { "separator": "  ", "color": { "keys": "cyan" } },
  "modules": [
    { "type": "title",  "format": "{user-name-colored}@{host-name-colored}" },
    "separator",
    { "type": "os",     "key": "OS" },
    { "type": "kernel", "key": "Kernel" },
    { "type": "de",     "key": "Desktop" },
    { "type": "wm",     "key": "WM" },
    { "type": "shell",  "key": "Shell" },
    { "type": "cpu",    "key": "CPU" },
    { "type": "gpu",    "key": "GPU" },
    { "type": "memory", "key": "Memory" },
    { "type": "disk",   "key": "Disk" },
    "break",
    { "type": "colors", "paddingLeft": 0 }
  ]
}
FFCONF
cp -aT "$SKEL/" /home/liveuser/
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser
mkdir -p /usr/local/bin
echo 'kernel.sysrq = 0' >/etc/sysctl.d/50-kibaos-disable-sysrq.conf
grep -q '^NAutoVTs' /etc/systemd/logind.conf&&sed -i 's/^NAutoVTs=.*/NAutoVTs=1/' /etc/systemd/logind.conf||echo 'NAutoVTs=1' >>/etc/systemd/logind.conf
systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
getty@tty5.service getty@tty6.service
mkdir -p /home/liveuser/Desktop
for src_desktop in kibaos-install kibaos-about;do
cp "/usr/share/applications/$src_desktop.desktop" \
"/home/liveuser/Desktop/$src_desktop.desktop" 2>/dev/null||true
chmod +x "/home/liveuser/Desktop/$src_desktop.desktop" 2>/dev/null||true
done
cat >/etc/environment <<'ENV'
XDG_SESSION_TYPE=wayland
KWIN_FORCE_SW_CURSOR=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
CLUTTER_BACKEND=wayland
SDL_VIDEODRIVER=wayland
KIBAOS_VERSION=rolling
KIBAOS_VENDOR="Kiba Labs, LLC"
ENV
cat >/etc/issue <<'ISSUE'

  ██╗  ██╗██╗██████╗  █████╗  ██████╗ ███████╗
  ██║ ██╔╝██║██╔══██╗██╔══██╗██╔═══██╗██╔════╝
  █████╔╝ ██║██████╔╝███████║██║   ██║███████╗
  ██╔═██╗ ██║██╔══██╗██╔══██║██║   ██║╚════██║
  ██║  ██╗██║██████╔╝██║  ██║╚██████╔╝███████║
  ╚═╝  ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝

  KibaOS by Kiba Labs, LLC
  Live session: user=liveuser  password=live
  Install: click the desktop icon or run  install

ISSUE
cat >/etc/motd <<'MOTD'
Welcome to KibaOS
MOTD
mkdir -p /etc/systemd/
cat >/etc/systemd/timesyncd.conf <<'TIMESYNCD'
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com time.google.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=1024
TIMESYNCD
timedatectl set-local-rtc 0 2>/dev/null||true
systemctl enable systemd-timesyncd
systemctl enable kibaos-greetd
systemctl enable NetworkManager
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/dns.conf <<'NMDNS'
[main]
dns=none
NMDNS
cat >/usr/local/bin/kibaos-boot-dns <<'BOOTDNS'
#!/bin/bash
echo "nameserver 1.1.1.1" >/etc/resolv.conf
BOOTDNS
chmod +x /usr/local/bin/kibaos-boot-dns
cat >/etc/systemd/system/kibaos-boot-dns.service <<'BOOTDNSSVC'
[Unit]
Description=Pin /etc/resolv.conf to nameserver 1.1.1.1
DefaultDependencies=no
Before=sysinit.target network-pre.target NetworkManager.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-boot-dns
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
BOOTDNSSVC
systemctl enable kibaos-boot-dns.service
mkdir -p /usr/lib/kibaos/src
cat >/usr/lib/kibaos/src/kiba_tcpmask.c <<'TCPMASKC'
/* kiba-tcpmask: rewrite TTL + TCP window on outbound SYN/SYN-ACK packets
 * to mask the stock Linux TCP/IP fingerprint. See build.sh for the full
 * rationale on what's touched and what's deliberately left alone. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <linux/netfilter.h>
#include <libnetfilter_queue/libnetfilter_queue.h>

/* Windows 10/11's classic nmap/p0f-visible defaults. */
#define TARGET_TTL    128
#define TARGET_WINDOW 65535

static uint16_t in_cksum(const uint16_t *ptr, int nbytes) {
    long sum = 0;
    while (nbytes > 1) {
        sum += *ptr++;
        nbytes -= 2;
    }
    if (nbytes == 1) {
        uint16_t odd = 0;
        *((uint8_t *)&odd) = *(const uint8_t *)ptr;
        sum += odd;
    }
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    return (uint16_t)(~sum);
}

static uint16_t tcp_cksum(const struct iphdr *iph, const struct tcphdr *tcph, int tcp_len) {
    struct {
        uint32_t src;
        uint32_t dst;
        uint8_t  zero;
        uint8_t  proto;
        uint16_t len;
    } __attribute__((packed)) ps;

    ps.src   = iph->saddr;
    ps.dst   = iph->daddr;
    ps.zero  = 0;
    ps.proto = IPPROTO_TCP;
    ps.len   = htons((uint16_t)tcp_len);

    int total = (int)sizeof(ps) + tcp_len;
    uint8_t *buf = malloc((size_t)total);
    if (!buf) return 0;
    memcpy(buf, &ps, sizeof(ps));
    memcpy(buf + sizeof(ps), tcph, (size_t)tcp_len);
    uint16_t sum = in_cksum((const uint16_t *)buf, total);
    free(buf);
    return sum;
}

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data) {
    (void)nfmsg; (void)data;
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    uint32_t id = ph ? ntohl(ph->packet_id) : 0;

    unsigned char *pkt = NULL;
    int len = nfq_get_payload(nfa, &pkt);
    if (len < (int)sizeof(struct iphdr) || !pkt) {
        return nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
    }

    struct iphdr *iph = (struct iphdr *)pkt;
    int ip_hlen = iph->ihl * 4;

    if (iph->protocol == IPPROTO_TCP && len >= ip_hlen + (int)sizeof(struct tcphdr)) {
        struct tcphdr *tcph = (struct tcphdr *)(pkt + ip_hlen);
        int tcp_len = len - ip_hlen;

        if (tcph->syn) {
            iph->ttl    = TARGET_TTL;
            tcph->window = htons(TARGET_WINDOW);

            iph->check = 0;
            iph->check = in_cksum((const uint16_t *)iph, ip_hlen);

            tcph->check = 0;
            tcph->check = tcp_cksum(iph, tcph, tcp_len);
        }
    }

    return nfq_set_verdict(qh, id, NF_ACCEPT, (uint32_t)len, pkt);
}

int main(void) {
    struct nfq_handle *h = nfq_open();
    if (!h) { perror("nfq_open"); return 1; }

    nfq_unbind_pf(h, AF_INET);
    if (nfq_bind_pf(h, AF_INET) < 0) { perror("nfq_bind_pf"); return 1; }

    struct nfq_q_handle *qh = nfq_create_queue(h, 100, &cb, NULL);
    if (!qh) { perror("nfq_create_queue"); return 1; }

    if (nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
        perror("nfq_set_mode"); return 1;
    }

    int fd = nfq_fd(h);
    char buf[65536];
    int rv;
    while ((rv = (int)recv(fd, buf, sizeof(buf), 0)) >= 0) {
        nfq_handle_packet(h, buf, rv);
    }

    nfq_destroy_queue(qh);
    nfq_close(h);
    return 0;
}
TCPMASKC
gcc -O2 -Wall $(pkg-config --cflags libnetfilter_queue) \
-o /usr/local/bin/kiba-tcpmask /usr/lib/kibaos/src/kiba_tcpmask.c \
$(pkg-config --libs libnetfilter_queue)||{
echo "FATAL: kiba_tcpmask.c failed to compile" >&2
exit 1
}
mkdir -p /etc/nftables-kiba
cat >/etc/nftables-kiba/tcpmask.conf <<'TCPMASKNFT'
table inet kiba_tcpmask {
  chain output {
    type filter hook output priority mangle; policy accept;
    tcp flags syn queue num 100 bypass
  }
}
TCPMASKNFT
cat >/etc/systemd/system/kiba-tcpmask.service <<'TCPMASKSVC'
[Unit]
Description=KibaOS outbound TCP/IP fingerprint mask
After=network-pre.target
Before=network.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=simple
ExecStartPre=/usr/bin/nft -f /etc/nftables-kiba/tcpmask.conf
ExecStart=/usr/local/bin/kiba-tcpmask
ExecStopPost=-/usr/bin/nft delete table inet kiba_tcpmask
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
TCPMASKSVC
systemctl enable kiba-tcpmask.service
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser
systemctl mask systemd-oomd.service systemd-oomd.socket
systemctl enable earlyoom
systemctl enable irqbalance
mkdir -p /etc/tuned
echo "balanced" >/etc/tuned/active_profile
systemctl enable tuned
mkdir -p /var/lib/extensions /etc/extensions
systemctl enable systemd-sysext
systemctl enable fstrim.timer
cat >/etc/tmpfiles.d/kibaos.conf <<'TMPFILES'
e /tmp/kibaos-ocr.* - - - 1d
TMPFILES
systemctl enable systemd-tmpfiles-clean.timer
echo "=== Re-applying KibaOS boot animation (KibaLabsLLC/Assets Splash/install.sh) ==="
KIBA_PLY_DIR="/usr/share/plymouth/themes/kibaos"
KIBA_SPLASH_SRC="/tmp/kiba-assets-splash"
if [ ! -f "$KIBA_SPLASH_SRC/Splash/install.sh" ];then
rm -rf "$KIBA_SPLASH_SRC"
git clone --depth 1 https://github.com/KibaLabsLLC/Assets "$KIBA_SPLASH_SRC"
fi
mkdir -p /etc/plymouth
cat >/etc/plymouth/plymouthd.conf <<'PLYMOUTHD_FINAL'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD_FINAL
chmod +x "$KIBA_SPLASH_SRC/Splash/install.sh"
(cd "$KIBA_SPLASH_SRC/Splash"&&./install.sh)||echo "!! Splash install.sh reported a failure (usually the initramfs rebuild) -- checking theme files anyway" >&2
for _f in kibaos.plymouth kibaos.script background.png logo.png raccoon.png;do
[ -s "$KIBA_PLY_DIR/$_f" ]||{
echo "ERROR: boot animation asset $_f is missing -- cannot re-apply KibaOS boot animation" >&2
exit 1
}
done
plymouth-set-default-theme -R kibaos||echo "!! plymouth-set-default-theme -R failed" >&2
[ -s /usr/share/kibaos/plymouth-logo.png ]&&cp /usr/share/kibaos/plymouth-logo.png /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner;do
if [ -d "/usr/share/plymouth/themes/$_theme_dir" ]&&[ -s /usr/share/kibaos/plymouth-logo.png ];then
cp /usr/share/kibaos/plymouth-logo.png "/usr/share/plymouth/themes/$_theme_dir/watermark.png"
fi
done
[ "$(plymouth-set-default-theme)" = "kibaos" ]||{
echo "ERROR: default Plymouth theme is not kibaos after re-apply" >&2
exit 1
}
rm -rf "$KIBA_SPLASH_SRC"
echo "=== Boot animation: kibaos theme re-applied ==="
rm -rf /var/cache/pacman/pkg/*
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/doc/*
find /usr/share/locale -mindepth 1 -maxdepth 1 \
! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
-exec rm -rf {} + 2>/dev/null||true
find /usr -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null||true
find /usr -name '*.pyc' -delete 2>/dev/null||true
find /usr/lib -name '*.a' -delete 2>/dev/null||true
rm -rf /usr/include/* 2>/dev/null||true
find /usr/share/icons -name 'icon-theme.cache' -delete 2>/dev/null||true
rm -rf /var/lib/pacman/sync/* /tmp/* /var/tmp/* 2>/dev/null||true
chown -R 1000:1000 /home/liveuser
mkdir -p /home/liveuser/.config/autostart
install -d -m 755 -o 1000 -g 1000 /home/liveuser/.config/dconf
chown -R 1000:1000 /home/liveuser/.config
for _icon in /home/liveuser/Desktop/*.desktop;do
[ -f "$_icon" ]||continue
chmod 755 "$_icon" 2>/dev/null||true
chown 1000:1000 "$_icon" 2>/dev/null||true
runuser -u liveuser -- gio set "$_icon" metadata::trusted true 2>/dev/null||true
done
cat >/usr/local/bin/kibaos-trust-desktop-icons <<'TRUSTICONS'
#!/bin/sh
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null||echo "$HOME/Desktop")"
[ -d "$DESKTOP_DIR" ]||exit 0
for f in "$DESKTOP_DIR"/*.desktop;do
[ -f "$f" ]||continue
chmod +x "$f" 2>/dev/null||true
gio set "$f" metadata::trusted true 2>/dev/null||true
done
TRUSTICONS
chmod 755 /usr/local/bin/kibaos-trust-desktop-icons
cat >/home/liveuser/.config/autostart/kibaos-trust-desktop-icons.desktop <<'TRUSTAUTO'
[Desktop Entry]
Type=Application
Name=Trust Desktop Icons
Exec=/usr/local/bin/kibaos-trust-desktop-icons
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
TRUSTAUTO
chown 1000:1000 /home/liveuser/.config/autostart/kibaos-trust-desktop-icons.desktop
cat >/etc/resolv.conf <<'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF
if [ "$(uname -m)" = "aarch64" ];then
_kver="$(ls -1 /usr/lib/modules|head -n1)"
if [ -z "$_kver" ];then
echo "ERROR: no kernel module directory found under /usr/lib/modules" >&2
exit 1
fi
mkinitcpio -k "$_kver" -c /etc/mkinitcpio.conf.d/archiso.conf -g /boot/initramfs-linux.img
fi
pkill -x gvfsd-fuse 2>/dev/null||true
pkill -x gvfsd 2>/dev/null||true
pkill -x dbus-daemon 2>/dev/null||true
sleep 1
awk '$3 ~ /^fuse/ {print $2}' /proc/mounts|while read -r _m;do
fusermount3 -uz "$_m" 2>/dev/null||fusermount -uz "$_m" 2>/dev/null||umount -l "$_m" 2>/dev/null||true
done
rm -rf /root/.gvfs /home/*/.gvfs 2>/dev/null||true
rmdir /run/user/*/gvfs 2>/dev/null||true
echo "=== remaining fuse mounts (should be none): ==="
grep -E 'gvfs|fuse' /proc/mounts||true
rm -f /etc/machine-id
touch /etc/machine-id
echo "=== customize_airootfs.sh complete ==="
CUSTOMIZE
chmod +x "$AIROOTFS/root/customize_airootfs.sh"
cd "$WORKDIR"
rm -rf "$WORKDIR/work"
if [ "$KIBA_ARCH" = "aarch64" ];then
mkdir -p "$WORKDIR/work/pacman-gnupg"
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --init
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --populate archlinux
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --recv-keys \
68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --lsign-key \
68B3537F39A313B3E574D06777193F152BDBE6A6
fi
mkarchiso -v -w work -o out "$PROFILE/"
cd "$WORKDIR"
rm -rf iso_root kibaos.iso
mv work/iso iso_root
rm -f out/*.iso
for _f in iso_root/EFI/BOOT/BOOTx64.EFI \
work/efiboot.img;do
[ -f "$_f" ]||{
echo "ERROR: $_f is missing -- cannot build the UEFI ISO" >&2
exit 1
}
done
cp -f work/efiboot.img iso_root/EFI/BOOT/efiboot.img
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid KIBAOS \
-e EFI/BOOT/efiboot.img -no-emul-boot \
-efi-boot-part --efi-boot-image \
-o kibaos.iso iso_root/
if [ -f kibaos.iso ];then
mv kibaos.iso "$ISO.iso"
xorriso -indev "$ISO.iso" -report_el_torito plain -report_system_area plain 2>&1|tail -n 60||true
sha256sum "$ISO.iso" >"$ISO.iso.sha256"
echo "Build Complete!"
else
echo "ERROR: kibaos.iso not found after xorriso!"
exit 1
fi