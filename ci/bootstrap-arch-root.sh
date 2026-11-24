#!/bin/bash
# Bootstrap an Arch validation root on the current host.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "bootstrap-arch-root.sh must run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${KIBAOS_WORKDIR:-/mnt/build/kibaos-work}"
ARCHROOT="${ARCHROOT:-${WORKDIR}/archroot}"
PACMAN_CONF="${PACMAN_CONF:-${WORKDIR}/arch-pacman.conf}"
PACMAN_DB="${PACMAN_DB:-${WORKDIR}/pacman-db}"
PACMAN_CACHE="${PACMAN_CACHE:-${WORKDIR}/pacman-cache}"

PACKAGES=(
  base
  base-devel
  bubblewrap
  git
  devtools
  namcap
  pacman-contrib
  sudo
  rsync
  bash
  util-linux
  python
  shellcheck
  shfmt
  polkit
  networkmanager
  bluez
  bluez-utils
  brightnessctl
  greetd
  greetd-tuigreet
  pipewire
  pipewire-alsa
  pipewire-pulse
  upower
  udisks2
  wireplumber
  xdg-utils
  python-dbus
  python-gobject
  #: kibaos-greeter's checkdepends are python and weston, but its tests
  #: import the drawing and widget layers too, and without these its
  #: check() reports the chart and the rows as unchecked rather than
  #: failing, which is a gate that passes by not looking.
  python-cairo
  gtk4
  libadwaita
  glib2
  pkgconf
  ninja
  clang
  lld
  gn
  bison
  flex
  gperf
  nodejs
  python-pip
  patch
  dbus-glib
  weston
  seatd
  xorg-xwayland
  libglvnd
  wayland
  libxkbcommon
  libx11
  libxcb
  libxcomposite
  libxdamage
  libxext
  libxfixes
  libxi
  libxrandr
  libxrender
  libxss
  libxtst
  pango
  cairo
  nss
  nspr
  alsa-lib
  minizip
  libevent
  libdrm
  mesa
  hwdata
  harfbuzz
  freetype2
  libpng
  libjpeg-turbo
)

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need pacman
need pacman-key
need pacstrap
need arch-chroot

install -d -m 755 "${WORKDIR}" "${ARCHROOT}" "${PACMAN_DB}" "${PACMAN_CACHE}"
install -d -m 755 /etc/pacman.d

if [[ ! -f /etc/pacman.d/gnupg/pubring.gpg ]]; then
  pacman-key --init
fi
pacman-key --populate archlinux

cat >"${PACMAN_CONF}" <<EOF
[options]
Architecture = x86_64
DBPath = ${PACMAN_DB}/
CacheDir = ${PACMAN_CACHE}/
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Required
ParallelDownloads = 5
CheckSpace

[core]
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
EOF

pacman --config "${PACMAN_CONF}" -Sy --noconfirm
pacstrap -c -C "${PACMAN_CONF}" "${ARCHROOT}" "${PACKAGES[@]}"
chown root:root "${ARCHROOT}"

arch-chroot "${ARCHROOT}" /usr/bin/bash -lc \
  'id aurabuild >/dev/null 2>&1 || useradd -m -s /bin/bash aurabuild'

install -d -m 755 "${ARCHROOT}/build/kibaos"
rsync -a --delete --exclude __pycache__ \
  "${REPO_ROOT}/kibaos-account-helper" \
  "${REPO_ROOT}/kibaos-system-helper" \
  "${REPO_ROOT}/kibaos-power" \
  "${REPO_ROOT}/kibaos-hardware" \
  "${REPO_ROOT}/kibaos-host-bridge" \
  "${REPO_ROOT}/kibaos-login" \
  "${REPO_ROOT}/kibaos" \
  "${REPO_ROOT}/kibaos-ai" \
  "${REPO_ROOT}/kibaos-full" \
  "${REPO_ROOT}/kibaos-greeter" \
  "${REPO_ROOT}/kibaos-webapp-shortcuts" \
  "${REPO_ROOT}/shill-nm-adapter" \
  "${REPO_ROOT}/chromiumos-ash" \
  "${REPO_ROOT}/installer" \
  "${REPO_ROOT}/ci" \
  "${ARCHROOT}/build/kibaos/"
chown -R 1000:1000 "${ARCHROOT}/build/kibaos"

echo "Arch validation root ready: ${ARCHROOT}"
echo "Run: arch-chroot ${ARCHROOT} /usr/bin/runuser -u aurabuild -- /usr/bin/bash -lc 'cd /build/kibaos && ci/arch-package-smoke.sh'"
