#!/bin/bash
# Build Lumen with the tools Arch already packages.
#
# Chromium's DEPS brings its own GN (cipd), Ninja (cipd) and a Clang/LLVM
# toolchain (GCS, well over a gigabyte) into every fresh checkout. On Arch
# those are pacman packages -- gn, ninja, clang, llvm, lld -- which the build
# root already installs (ci/bootstrap-arch-root.sh) and which the chromiumos-ash
# makedepends already name. This script links the installed packages into the
# checkout and records what it took from pacman, so ci/resolve-deps.py leaves
# those DEPS entries out and the GN builds pass the clang arguments the system
# toolchain needs.
#
# Usage:
#   ci/system-tools.sh --link SRC          use packages for everything it can
#   ci/system-tools.sh --resolver-args SRC print ci/resolve-deps.py arguments
#
# SRC is the Lumen source checkout, the directory that holds DEPS.
#
# State lives in SRC/out/.kibaos/, which Chromium's .gitignore covers: a file
# left in the worktree would show up in the patch-series tree check as drift.
#   system-tools.conf  one tool=packages line per substituted tool
#   system-tools.gn    matching gn arguments for the system clang
#
# Environment:
#   KIBAOS_SYSTEM_TOOLS=0            keep Chromium's downloaded toolchains
#   KIBAOS_PACMAN=0                  never install, use what is installed
#   KIBAOS_SYSTEM_BIN_DIR=/usr/bin   where the packages' binaries live
#   KIBAOS_PACMAN_BIN=pacman         the pacman command to use
#
# A tool is substituted only when its packages are installed (or can be
# installed) and its binaries are there; otherwise that tool keeps Chromium's
# copy and the build continues as before.
set -euo pipefail

SYS_BIN="${KIBAOS_SYSTEM_BIN_DIR:-/usr/bin}"
PACMAN="${KIBAOS_PACMAN_BIN:-pacman}"
STATE_REL="out/.kibaos"

# The tools Chromium's build runs out of clang_base_path/bin.
CLANG_BINS=(
  clang
  clang++
  ld.lld
  llvm-ar
  llvm-cov
  llvm-cxxfilt
  llvm-dwarfdump
  llvm-nm
  llvm-objcopy
  llvm-objdump
  llvm-profdata
  llvm-ranlib
  llvm-readelf
  llvm-readobj
  llvm-size
  llvm-strings
  llvm-strip
  llvm-symbolizer
)

# Without these the C/C++ toolchain is not usable at all.
CLANG_REQUIRED=(
  clang
  clang++
  llvm-ar
  llvm-nm
  llvm-strip
  ld.lld
)

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
    "${BASH_SOURCE[0]}"
}

have_package() {
  "${PACMAN}" -Qq "$1" >/dev/null 2>&1
}

install_packages() {
  local -a cmd=()
  local p

  if [[ "$(id -u)" -eq 0 ]]; then
    cmd=("${PACMAN}" -S --needed --noconfirm "$@")
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    cmd=(sudo -n "${PACMAN}" -S --needed --noconfirm "$@")
  else
    warn "not root and no passwordless sudo: cannot install $*"
    return 1
  fi

  log "installing from pacman: $*"
  if ! "${cmd[@]}" >/dev/null 2>&1; then
    warn "pacman could not install: $*"
    return 1
  fi
  for p in "$@"; do
    have_package "$p" || return 1
  done
}

# True when every named package is installed, installing the missing ones from
# pacman first when that is allowed.
use_packages() {
  local -a missing=()
  local p

  command -v "${PACMAN}" >/dev/null 2>&1 || return 1
  for p in "$@"; do
    have_package "$p" || missing+=("$p")
  done
  (( ${#missing[@]} == 0 )) && return 0
  [[ "${KIBAOS_PACMAN:-1}" == "1" ]] || return 1
  install_packages "${missing[@]}"
}

link_tree() {
  local src="$1"
  local rel="$2"
  local bin="$3"
  local dest="${src}/${rel}"

  mkdir -p "$(dirname "${dest}")"
  if [[ -d "${dest}" && ! -L "${dest}" ]]; then
    warn "${rel} is a directory; leaving it alone"
    return 1
  fi
  ln -sfn "${bin}" "${dest}"
}

clang_complete() {
  local bin

  for bin in "${CLANG_REQUIRED[@]}"; do
    [[ -x "${SYS_BIN}/${bin}" ]] || return 1
  done
  # A stale or wrong binary at that path would fail much later, one TU at a
  # time; ask it who it is now.
  "${SYS_BIN}/clang++" --version >/dev/null 2>&1
}

link_tools() {
  local src="$1"
  local state="${src}/${STATE_REL}"
  local conf="${state}/system-tools.conf"
  local gn_args="${state}/system-tools.gn"
  local bin

  mkdir -p "${state}"
  : >"${conf}"
  : >"${gn_args}"

  if [[ "${KIBAOS_SYSTEM_TOOLS:-1}" != "1" ]]; then
    log "KIBAOS_SYSTEM_TOOLS=0: keeping Chromium's downloaded toolchains"
    return 0
  fi

  if ! command -v "${PACMAN}" >/dev/null 2>&1; then
    warn "pacman is not available: keeping Chromium's downloaded toolchains"
    return 0
  fi

  if use_packages gn && [[ -x "${SYS_BIN}/gn" ]]; then
    if link_tree "${src}" buildtools/linux64/gn "${SYS_BIN}/gn"; then
      printf 'gn=gn\n' >>"${conf}"
      log "gn: ${SYS_BIN}/gn"
    fi
  else
    warn "gn: keeping Chromium's prebuilt GN"
  fi

  if use_packages ninja && [[ -x "${SYS_BIN}/ninja" ]]; then
    if link_tree "${src}" third_party/ninja/ninja "${SYS_BIN}/ninja"; then
      printf 'ninja=ninja\n' >>"${conf}"
      log "ninja: ${SYS_BIN}/ninja"
    fi
  else
    warn "ninja: keeping Chromium's prebuilt Ninja"
  fi

  if use_packages clang llvm lld && clang_complete; then
    for bin in "${CLANG_BINS[@]}"; do
      [[ -x "${SYS_BIN}/${bin}" ]] || continue
      link_tree "${src}" \
        "third_party/llvm-build/Release+Asserts/bin/${bin}" \
        "${SYS_BIN}/${bin}" ||
        warn "clang: could not link ${bin}"
    done
    printf 'clang=clang llvm lld\n' >>"${conf}"
    # Chromium's own clang carries the coding-guideline plugins and the
    # alloc-token sanitizer build in; another clang has neither. Naming the
    # toolchain keeps GN's revision checks out of the way too: those assert
    # that //third_party/llvm-build matches tools/clang/scripts/update.py,
    # which is exactly the copy this build does not use.
    cat >>"${gn_args}" <<EOF
# Arch's clang, llvm and lld replace Chromium's prebuilt toolchain
# (ci/system-tools.sh); the prebuilt one is not downloaded.
clang_base_path = "${SYS_BIN%/bin}"
clang_use_chrome_plugins = false
use_alloc_token = false
EOF
    log "clang: ${SYS_BIN}/clang++ with llvm and lld"
  else
    local -a missing=()
    for bin in "${CLANG_REQUIRED[@]}"; do
      [[ -x "${SYS_BIN}/${bin}" ]] || missing+=("${bin}")
    done
    if (( ${#missing[@]} )); then
      warn "clang: missing ${missing[*]} in ${SYS_BIN}"
    fi
    warn "clang: keeping Chromium's prebuilt toolchain"
  fi
}

resolver_args() {
  local src="$1"
  local conf="${src}/${STATE_REL}/system-tools.conf"
  local line

  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line; do
    case "${line%%=*}" in
      gn)
        printf '%s\n' '--skip-dep-path' 'src/buildtools/linux64'
        ;;
      ninja)
        printf '%s\n' '--skip-dep-path' 'src/third_party/ninja'
        ;;
      clang)
        printf '%s\n' '--skip-dep-path' \
          'src/third_party/llvm-build/Release+Asserts'
        ;;
    esac
  done <"${conf}"
}

mode=""
src=""

while (( $# )); do
  case "$1" in
    --link | --resolver-args)
      mode="$1"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      src="$1"
      shift
      ;;
  esac
done

if [[ -z "${mode}" || -z "${src}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${src}/DEPS" ]]; then
  echo "error: ${src} is not a Lumen checkout (no DEPS)" >&2
  exit 2
fi

case "${mode}" in
  --link) link_tools "${src}" ;;
  --resolver-args) resolver_args "${src}" ;;
esac
