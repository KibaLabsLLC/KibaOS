#!/bin/bash
# Build Lumen with the tools Arch already packages.
#
# Chromium's DEPS brings its own GN (cipd), Ninja (cipd) and a Clang/LLVM
# toolchain (GCS, well over a gigabyte) into every fresh checkout. On Arch
# those are pacman packages -- gn, ninja, clang, llvm, lld, compiler-rt -- which
# the build root already installs (ci/bootstrap-arch-root.sh) and which the
# chromiumos-ash makedepends already name. This script links the installed
# packages into the checkout and records what it took from pacman, so
# ci/resolve-deps.py leaves those DEPS entries out and the GN builds pass the
# clang arguments the system toolchain needs.
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
#   system-tools.gn    matching gn arguments for the system clang
#
# The clang substitution also completes SRC/third_party/llvm-build/Release+Asserts,
# Chromium's default clang_base_path: the binaries are linked there, and
# provide_clang_toolchain() adds the per-target compiler-rt directory and the
# cr_build_revision file the build reads from that path. Keeping the toolchain
# where Chromium expects it means no absolute path is baked into the checkout,
# so the same tree configures inside the Arch root as on the host.
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

clang_complete() {
  local bin

  for bin in "${CLANG_REQUIRED[@]}"; do
    [[ -x "${SYS_BIN}/${bin}" ]] || return 1
  done
  # A stale or wrong binary at that path would fail much later, one TU at a
  # time; ask it who it is now.
  "${SYS_BIN}/clang++" --version >/dev/null 2>&1
}

# Chromium reads its clang toolchain from //third_party/llvm-build/Release+Asserts
# (clang_base_path's default): bin/ holds the tools, cr_build_revision the
# revision //tools/clang/scripts/update.py expects, and lib/clang/<version>
# holds the builtin headers and the runtimes, compiler-rt in a per-target
# directory, lib/<triple>/libclang_rt.builtins.a.
# Arch packages the binaries, the builtin headers and a flat compiler-rt
# (lib/linux/...) but no revision file. Each piece left out fails the build
# late in Ninja: the archive is what the Rust standard library links
# (obj/build/rust/libcxx_cppdeps_lib.a), and the headers are what a compilable
# builtin like stddef.h is (gen/v8/metagen/layouts.json).
CLANG_BASE_REL="third_party/llvm-build/Release+Asserts"

clang_triple() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64-unknown-linux-gnu\n' ;;
    aarch64 | arm64) printf 'aarch64-unknown-linux-gnu\n' ;;
    *) return 1 ;;
  esac
}

clang_resource_dir() {
  local dir

  dir="$("$1" -print-resource-dir 2>/dev/null)" || return 1
  [[ -n "${dir}" && -d "${dir}" ]] || return 1
  printf '%s\n' "${dir}"
}

# The version directory the tree's GN expects, from build/toolchain/toolchain.gni.
tree_clang_version() {
  local version

  version="$(sed -nE \
    's/^[[:space:]]*clang_version[[:space:]]*=[[:space:]]*"([0-9]+)".*/\1/p' \
    "$1/build/toolchain/toolchain.gni" 2>/dev/null | head -n 1 || true)"
  [[ -n "${version}" ]] || return 1
  printf '%s\n' "${version}"
}

# The revision GN asserts cr_build_revision holds, from the tree's own
# tools/clang/scripts/update.py.
tree_clang_revision() {
  local py="$1/tools/clang/scripts/update.py"
  local revision sub

  [[ -r "${py}" ]] || return 1
  revision="$(sed -nE \
    "s/^[[:space:]]*CLANG_REVISION[[:space:]]*=[[:space:]]*'([^']+)'.*/\1/p" \
    "${py}" 2>/dev/null | head -n 1 || true)"
  sub="$(sed -nE \
    's/^[[:space:]]*CLANG_SUB_REVISION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
    "${py}" 2>/dev/null | head -n 1 || true)"
  [[ -n "${revision}" && -n "${sub}" ]] || return 1
  printf '%s-%s\n' "${revision}" "${sub}"
}

# Fill in lib/clang/<version> of the tree's toolchain from the installed
# clang's resource directory: the builtin headers (the include directory GN
# passes to the compiler) and compiler-rt. Arch's compiler-rt is flat,
# lib/linux/libclang_rt.<name>-<arch>.a, so the architecture suffix is dropped
# while copying to the per-target layout Chromium asks for.
install_clang_runtimes() {
  local resource_dir="$1"
  local dest="$2"
  local triple="$3"
  local arch="${triple%%-*}"
  local libdir="${dest}/lib/${triple}"
  local src name stem ext

  if [[ -d "${resource_dir}/include" ]]; then
    # rm first so headers from an older clang do not linger beside new ones.
    rm -rf "${dest}/include" || return 1
    mkdir -p "${dest}" || return 1
    cp -R "${resource_dir}/include" "${dest}/include" || return 1
  else
    warn "clang: ${resource_dir} has no builtin include directory"
    return 1
  fi

  mkdir -p "${libdir}" || return 1
  if [[ -d "${resource_dir}/lib/${triple}" ]]; then
    cp -R "${resource_dir}/lib/${triple}/." "${libdir}/" || return 1
  fi
  for src in "${resource_dir}"/lib/linux/libclang_rt.*-"${arch}".a \
    "${resource_dir}"/lib/linux/clang_rt.*-"${arch}".o; do
    [[ -f "${src}" ]] || continue
    name="$(basename "${src}")"
    ext="${name##*.}"
    stem="${name%.*}"
    name="${stem%-"${arch}"}.${ext}"
    # Copies, not links: the same checkout is configured again inside the
    # Arch build root, whose /usr may carry a different clang than the one
    # that bootstrapped it. rm first so a link left by an older run is
    # replaced instead of written through.
    rm -f "${libdir}/${name}" || return 1
    cp "${src}" "${libdir}/${name}" || return 1
  done
  [[ -f "${libdir}/libclang_rt.builtins.a" ]] || {
    warn "clang: ${resource_dir} has no compiler-rt builtins archive for ${triple}"
    return 1
  }
}

# Complete that toolchain directory so the installed clang works from it.
provide_clang_toolchain() {
  local src="$1"
  local base="${src}/${CLANG_BASE_REL}"
  local triple version revision resource_dir

  triple="$(clang_triple)" || {
    warn "clang: no Chromium runtime triple for $(uname -m)"
    return 1
  }
  version="$(tree_clang_version "${src}")" || {
    warn "clang: cannot read clang_version from build/toolchain/toolchain.gni"
    return 1
  }
  revision="$(tree_clang_revision "${src}")" || {
    warn "clang: cannot read the clang revision from tools/clang/scripts/update.py"
    return 1
  }
  resource_dir="$(clang_resource_dir "${SYS_BIN}/clang")" || {
    warn "clang: ${SYS_BIN}/clang reports no resource directory"
    return 1
  }

  install_clang_runtimes "${resource_dir}" "${base}/lib/clang/${version}" \
    "${triple}" || return 1

  mkdir -p "${base}" || return 1
  printf '%s\n' "${revision}" >"${base}/cr_build_revision" || return 1
  log "clang runtime: ${resource_dir} for ${triple} in ${version}"
  return 0
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

  # compiler-rt is what the Rust standard library links, so the package is
  # part of the requirement: install (or find) it before anything is copied
  # into the toolchain directory, and substitute nothing if it is not there.
  local have_compiler_rt=0
  if use_packages compiler-rt; then
    have_compiler_rt=1
  else
    warn "clang: compiler-rt is missing and cannot be installed; the Rust std build needs its libclang_rt.builtins.a"
  fi

  if use_packages clang llvm lld && clang_complete &&
    (( have_compiler_rt )) && provide_clang_toolchain "${src}"; then
    for bin in "${CLANG_BINS[@]}"; do
      [[ -x "${SYS_BIN}/${bin}" ]] || continue
      link_tree "${src}" \
        "${CLANG_BASE_REL}/bin/${bin}" \
        "${SYS_BIN}/${bin}" ||
        warn "clang: could not link ${bin}"
    done
    printf 'clang=clang llvm lld compiler-rt\n' >>"${conf}"
    # Chromium's own clang carries the coding-guideline plugins and the
    # alloc-token sanitizer build in; another clang has neither. The toolchain
    # stays at its default path, which provide_clang_toolchain() has just
    # completed, so the revision checks GN runs for that path read the
    # cr_build_revision written there too.
    cat >>"${gn_args}" <<EOF
# Arch's clang, llvm, lld and compiler-rt replace Chromium's prebuilt
# toolchain (ci/system-tools.sh); the prebuilt one is not downloaded.
clang_use_chrome_plugins = false
use_alloc_token = false
EOF
    log "clang: ${SYS_BIN}/clang++ with llvm, lld and compiler-rt"
  else
    local -a missing=()
    for bin in "${CLANG_REQUIRED[@]}"; do
      [[ -x "${SYS_BIN}/${bin}" ]] || missing+=("${bin}")
    done
    if (( ${#missing[@]} )); then
      warn "clang: missing ${missing[*]} in ${SYS_BIN}"
    fi
    warn "clang: keeping Chromium's prebuilt toolchain"
    for bin in "${CLANG_BINS[@]}"; do
      drop_link "${src}" "${CLANG_BASE_REL}/bin/${bin}"
    done
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
