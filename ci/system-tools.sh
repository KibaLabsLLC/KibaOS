#!/bin/bash
# Build Lumen with the tools Arch already packages.
#
# Chromium's DEPS brings its own GN (cipd) and Ninja (cipd) into every fresh
# checkout, and on Arch pacman installs both -- the build root does
# (ci/bootstrap-arch-root.sh) and the chromiumos-ash makedepends name them.
# This script links the installed packages into the checkout and records what
# it took from pacman, so ci/resolve-deps.py leaves those DEPS entries out.
#
# The Clang/LLVM toolchain is not substituted: Chromium's build config is
# written for exactly the clang the tree pins. It records clang_version in
# build/toolchain/toolchain.gni, asserts the revision in the toolchain against
# tools/clang/scripts/update.py, and passes options only that clang knows, so
# Chromium's prebuilt toolchain is always kept and downloaded.
#
# Usage:
#   ci/system-tools.sh --link SRC          use packages for everything it can
#   ci/system-tools.sh --resolver-args SRC print ci/resolve-deps.py arguments
#   ci/system-tools.sh --check-gn SRC      fail when SRC's GN link cannot read
#                                           SRC/.gn (a bootstrap left the old
#                                           package GN in place)
#
# SRC is the Lumen source checkout, the directory that holds DEPS.
#
# State lives in SRC/out/.kibaos/, which Chromium's .gitignore covers: a file
# left in the worktree would show up in the patch-series tree check as drift.
#   system-tools.conf  one tool=packages line per substituted tool
#   system-tools.gn    matching gn arguments, empty while only gn and ninja
#                      are substituted; the package builds cat it into args.gn
#
# Environment:
#   KIBAOS_SYSTEM_TOOLS=0            keep Chromium's downloaded toolchains
#   KIBAOS_PACMAN=0                  never install, use what is installed
#   KIBAOS_SYSTEM_BIN_DIR=/usr/bin   where the packages' binaries live
#   KIBAOS_PACMAN_BIN=pacman         the pacman command to use
#
# A tool is substituted only when its packages are installed (or can be
# installed) and its binaries are there; otherwise that tool keeps Chromium's
# copy and the build continues as before. GN also has to be able to read the
# tree's own .gn (see gn_reads_dotfile): a gn too old for the form this tree
# uses stops before any build argument is read, and Chromium's pinned copy is
# the version the tree was written against.
set -euo pipefail

SYS_BIN="${KIBAOS_SYSTEM_BIN_DIR:-/usr/bin}"
PACMAN="${KIBAOS_PACMAN_BIN:-pacman}"
STATE_REL="out/.kibaos"

# Chromium's clang toolchain, at clang_base_path's default. Only used to clear
# what an earlier bootstrap put there.
CLANG_BASE_REL="third_party/llvm-build/Release+Asserts"
# The tools such a bootstrap took from the packaged clang.
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

# Chromium moved .gn's script_executable from a string to a list, because it
# names the interpreter and its flags ("-ES"). A gn from before that change
# stops at //.gn with "This is not a string" before it reads a single build
# argument, so the packaged gn may only be used when it can parse the form this
# tree's .gn uses. The probe is a throwaway root holding exactly that form.
gn_reads_dotfile() {
  local src="$1"
  local gn="$2"
  local probe out

  [[ -f "${src}/.gn" ]] || return 0
  grep -qE '^[[:space:]]*script_executable[[:space:]]*=[[:space:]]*\[' \
    "${src}/.gn" || return 0

  # No buildconfig and no BUILD.gn on purpose: a gn that understands the list
  # stops later on something else, while one that does not stops here with
  # "This is not a string". Only that message means the package is too old.
  probe="$(mktemp -d)"
  {
    printf 'buildconfig = "//BUILDCONFIG.gn"\n'
    printf 'script_executable = [ "python3", "-ES" ]\n'
  } >"${probe}/.gn"
  out="$("${gn}" gen "${probe}/out" --root="${probe}" 2>&1 || true)"
  rm -rf "${probe}"
  ! grep -q 'is not a string' <<<"${out}"
}

# A tool that keeps Chromium's copy must not find a link from an earlier run:
# the resolver downloads into that same path, and a link would stand in its way.
drop_link() {
  local src="$1"
  local rel="$2"

  if [[ -L "${src}/${rel}" ]]; then
    rm -f "${src}/${rel}"
  fi
  return 0
}

# Chromium's prebuilt clang is the compiler this build uses (see the top of
# this file). An earlier bootstrap may have linked the packaged clang into that
# path, or left the wrapper it wrote around the distro compiler; the resolver
# downloads into that directory, so remove what this script put there and never
# a downloaded binary.
drop_clang_toolchain() {
  local src="$1"
  local bin
  local path

  for bin in "${CLANG_BINS[@]}"; do
    path="${src}/${CLANG_BASE_REL}/bin/${bin}"
    drop_link "${src}" "${CLANG_BASE_REL}/bin/${bin}"
    if [[ -f "${path}" && ! -L "${path}" ]] &&
      grep -q 'Generated by ci/system-tools.sh' "${path}" 2>/dev/null; then
      rm -f "${path}"
    fi
  done
  rm -f "${src}/${CLANG_BASE_REL}/lib/kibaos-clang-rejected-args"
  return 0
}

# The package build gets a prepared tree, so a link left at that path by an
# earlier bootstrap is what crushes gn gen: it stops at //.gn before any build
# argument is read, and the recovery loop can only report that it cannot help.
# Fail once, with the command that fixes it.
check_gn() {
  local src="$1"
  local gn="${src}/buildtools/linux64/gn"

  [[ -L "${gn}" ]] || return 0
  gn_reads_dotfile "${src}" "${gn}" && return 0
  cat >&2 <<EOF
error: ${gn} is a link to a GN that cannot read this tree's .gn (it sets
script_executable to a list, which needs a newer GN), so gn gen would stop
before reading a single build argument.
Re-run ci/bootstrap-chromium-src.sh to fetch the pinned GN, or remove the link
and let ci/resolve-deps.py fetch it:
  rm -f ${gn}
EOF
  return 1
}

link_tools() {
  local src="$1"
  local state="${src}/${STATE_REL}"
  local conf="${state}/system-tools.conf"
  local gn_args="${state}/system-tools.gn"

  mkdir -p "${state}"
  : >"${conf}"
  : >"${gn_args}"

  # Whatever else happens, this build compiles with Chromium's own clang, so
  # take an earlier substitution out of its path before the resolver runs.
  drop_clang_toolchain "${src}"
  log "clang: keeping Chromium's prebuilt toolchain"

  if [[ "${KIBAOS_SYSTEM_TOOLS:-1}" != "1" ]]; then
    log "KIBAOS_SYSTEM_TOOLS=0: keeping Chromium's downloaded toolchains"
    return 0
  fi

  if ! command -v "${PACMAN}" >/dev/null 2>&1; then
    warn "pacman is not available: keeping Chromium's downloaded toolchains"
    return 0
  fi

  if use_packages gn && [[ -x "${SYS_BIN}/gn" ]]; then
    if ! gn_reads_dotfile "${src}" "${SYS_BIN}/gn"; then
      warn "gn: ${SYS_BIN}/gn cannot read the list-form script_executable this tree's .gn uses; keeping Chromium's prebuilt GN"
      drop_link "${src}" buildtools/linux64/gn
    elif link_tree "${src}" buildtools/linux64/gn "${SYS_BIN}/gn"; then
      printf 'gn=gn\n' >>"${conf}"
      log "gn: ${SYS_BIN}/gn"
    fi
  else
    warn "gn: keeping Chromium's prebuilt GN"
    drop_link "${src}" buildtools/linux64/gn
  fi

  if use_packages ninja && [[ -x "${SYS_BIN}/ninja" ]]; then
    if link_tree "${src}" third_party/ninja/ninja "${SYS_BIN}/ninja"; then
      printf 'ninja=ninja\n' >>"${conf}"
      log "ninja: ${SYS_BIN}/ninja"
    fi
  else
    warn "ninja: keeping Chromium's prebuilt Ninja"
    drop_link "${src}" third_party/ninja/ninja
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
    esac
  done <"${conf}"
}

mode=""
src=""

while (( $# )); do
  case "$1" in
    --link | --resolver-args | --check-gn)
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
  --check-gn) check_gn "${src}" ;;
esac
