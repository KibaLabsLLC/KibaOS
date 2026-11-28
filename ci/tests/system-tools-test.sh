#!/usr/bin/env bash
# Check that ci/system-tools.sh takes a tool from pacman only when the package
# and its binaries are really there, and that the DEPS-side and GN-side answers
# match what it substituted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${SCRIPT_DIR}/system-tools.sh"

fail() {
  echo "system-tools test: $1" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kibaos-system-tools-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# A pacman that reports the packages listed in FAKE_PACMAN_INSTALLED as
# installed, and whose installs are never reached in these cases.
mkdir -p "${tmp}/bin"
cat >"${tmp}/pacman" <<'EOF'
#!/bin/sh
case "$1" in
  -Qq) grep -Fxq "$2" "${FAKE_PACMAN_INSTALLED}" ;;
  -S) exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "${tmp}/pacman"

fake_bin() {
  printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/$1"
  chmod +x "${tmp}/bin/$1"
}

src="${tmp}/src"
mkdir -p "${src}"
: >"${src}/DEPS"
# The tree's .gn names its interpreter and its flags, which recent GN writes as
# a list; the packaged GN has to be new enough to read that.
cat >"${src}/.gn" <<'EOF'
buildconfig = "//build/config/BUILDCONFIG.gn"
script_executable = [
  "//third_party/cpython3/host/bin/python3",
  "-ES",
]
EOF

# run_link [NAME=VALUE ...] -- runs the helper with the fake pacman and bin dir;
# extra assignments are handed to env and reach the script as its environment.
run_link() {
  env FAKE_PACMAN_INSTALLED="${tmp}/installed" \
    KIBAOS_SYSTEM_BIN_DIR="${tmp}/bin" \
    KIBAOS_PACMAN_BIN="${tmp}/pacman" \
    "$@" "${TOOLS}" --link "${src}"
}

# A: every package installed and every binary present.
printf 'gn\nninja\nclang\nllvm\nlld\n' >"${tmp}/installed"
for bin in gn ninja clang clang++ llvm-ar llvm-nm llvm-strip ld.lld \
  llvm-objcopy llvm-symbolizer; do
  fake_bin "${bin}"
done

run_link >"${tmp}/link-a.log" 2>&1 || {
  cat "${tmp}/link-a.log" >&2
  fail "link failed with every package installed"
}

[[ -L "${src}/buildtools/linux64/gn" ]] || fail "gn was not linked"
[[ -L "${src}/third_party/ninja/ninja" ]] || fail "ninja was not linked"
[[ -L "${src}/third_party/llvm-build/Release+Asserts/bin/clang++" ]] ||
  fail "clang++ was not linked"

state="${src}/out/.kibaos"
[[ -f "${state}/system-tools.conf" ]] || fail "state was not written under out/"
grep -Fxq 'clang=clang llvm lld' "${state}/system-tools.conf" ||
  fail "clang was not recorded"
grep -Fxq "clang_base_path = \"${tmp}\"" "${state}/system-tools.gn" ||
  fail "system clang_base_path was not written"
grep -Fxq 'clang_use_chrome_plugins = false' "${state}/system-tools.gn" ||
  fail "Chromium's clang plugins were not turned off"
grep -Fxq 'use_alloc_token = false' "${state}/system-tools.gn" ||
  fail "the alloc-token sanitizer was not turned off"

FAKE_PACMAN_INSTALLED="${tmp}/installed" \
  KIBAOS_SYSTEM_BIN_DIR="${tmp}/bin" \
  KIBAOS_PACMAN_BIN="${tmp}/pacman" \
  "${TOOLS}" --resolver-args "${src}" >"${tmp}/resolver-a"

grep -Fxq 'src/buildtools/linux64' "${tmp}/resolver-a" ||
  fail "the resolver is not told to skip GN"
grep -Fxq 'src/third_party/ninja' "${tmp}/resolver-a" ||
  fail "the resolver is not told to skip Ninja"
grep -Fxq 'src/third_party/llvm-build/Release+Asserts' "${tmp}/resolver-a" ||
  fail "the resolver is not told to skip the Clang toolchain"

# B: only gn and ninja are packaged; clang keeps Chromium's download, and the
# run still succeeds so the bootstrap can carry on.
rm -rf "${src}/buildtools" "${src}/third_party/ninja" \
  "${src}/third_party/llvm-build" "${src}/out"
printf 'gn\nninja\n' >"${tmp}/installed"
rm -f "${tmp}/bin/clang" "${tmp}/bin/clang++" "${tmp}/bin/llvm-ar" \
  "${tmp}/bin/llvm-nm" "${tmp}/bin/llvm-strip" "${tmp}/bin/ld.lld"

run_link KIBAOS_PACMAN=0 >"${tmp}/link-b.log" 2>&1 || {
  cat "${tmp}/link-b.log" >&2
  fail "link failed when only some tools are available"
}

[[ -L "${src}/buildtools/linux64/gn" ]] || fail "gn was not linked in the partial case"
[[ -L "${src}/third_party/ninja/ninja" ]] ||
  fail "ninja was not linked in the partial case"
[[ ! -e "${src}/third_party/llvm-build" ]] ||
  fail "a clang toolchain was linked without clang"
[[ ! -s "${src}/out/.kibaos/system-tools.gn" ]] ||
  fail "clang GN arguments were written without clang"

KIBAOS_PACMAN=0 \
  FAKE_PACMAN_INSTALLED="${tmp}/installed" \
  KIBAOS_SYSTEM_BIN_DIR="${tmp}/bin" \
  KIBAOS_PACMAN_BIN="${tmp}/pacman" \
  "${TOOLS}" --resolver-args "${src}" >"${tmp}/resolver-b"

grep -Fxq 'src/buildtools/linux64' "${tmp}/resolver-b" ||
  fail "the partial case does not skip GN"
if grep -Fxq 'src/third_party/llvm-build/Release+Asserts' "${tmp}/resolver-b"; then
  fail "the partial case skips a clang toolchain it did not substitute"
fi

# C: switched off, nothing is substituted or skipped.
rm -rf "${src}/buildtools" "${src}/third_party/ninja" "${src}/out"
run_link KIBAOS_SYSTEM_TOOLS=0 >"${tmp}/link-c.log" 2>&1 ||
  fail "link failed when system tools are disabled"

[[ ! -e "${src}/buildtools" ]] || fail "gn was linked while switched off"
[[ ! -s "${src}/out/.kibaos/system-tools.conf" ]] ||
  fail "state was recorded while switched off"
[[ ! -s "${src}/out/.kibaos/system-tools.gn" ]] ||
  fail "GN arguments were written while switched off"

FAKE_PACMAN_INSTALLED="${tmp}/installed" \
  KIBAOS_SYSTEM_BIN_DIR="${tmp}/bin" \
  KIBAOS_PACMAN_BIN="${tmp}/pacman" \
  "${TOOLS}" --resolver-args "${src}" >"${tmp}/resolver-c"
[[ ! -s "${tmp}/resolver-c" ]] || fail "the resolver arguments are not empty while switched off"

# D: a gn that fails for an unrelated reason is still usable; only the list
# form it cannot parse makes the package too old.
rm -rf "${src}/buildtools" "${src}/out"
printf 'gn\n' >"${tmp}/installed"
cat >"${tmp}/bin/gn" <<'EOF'
#!/bin/sh
echo 'ERROR: No buildconfig file.' >&2
exit 1
EOF
chmod +x "${tmp}/bin/gn"

run_link KIBAOS_PACMAN=0 >"${tmp}/link-d0.log" 2>&1 || {
  cat "${tmp}/link-d0.log" >&2
  fail "link failed when the packaged gn fails for its own reasons"
}
[[ -L "${src}/buildtools/linux64/gn" ]] ||
  fail "a gn that fails for an unrelated reason was dropped"

# E: the packaged GN is older than the tree's list-form .gn, so GN keeps
# Chromium's copy and the resolver still fetches it.
rm -rf "${src}/buildtools" "${src}/third_party/ninja" "${src}/out"
printf 'gn\nninja\n' >"${tmp}/installed"
cat >"${tmp}/bin/gn" <<'EOF'
#!/bin/sh
root=
for arg in "$@"; do
  case "${arg}" in
    --root=*) root="${arg#--root=}" ;;
  esac
done
if [ -n "${root}" ] && grep -q 'script_executable = \[' "${root}/.gn"; then
  echo 'ERROR at //.gn:18:21: This is not a string.' >&2
  exit 1
fi
exit 0
EOF
chmod +x "${tmp}/bin/gn"

# A link left by an earlier run must not survive the fallback, or the
# resolver's download would find the old gn in its place.
mkdir -p "${src}/buildtools/linux64"
ln -sfn "${tmp}/bin/gn" "${src}/buildtools/linux64/gn"

run_link KIBAOS_PACMAN=0 >"${tmp}/link-d.log" 2>&1 || {
  cat "${tmp}/link-d.log" >&2
  fail "link failed when the packaged gn cannot read the tree's .gn"
}

if [[ -L "${src}/buildtools/linux64/gn" ]]; then
  fail "a gn that cannot read the tree's .gn was linked anyway"
fi
grep -q 'cannot read the list-form script_executable' "${tmp}/link-d.log" ||
  fail "the old gn was left out without saying why"
[[ -L "${src}/third_party/ninja/ninja" ]] ||
  fail "ninja was dropped along with gn"
if grep -Fxq 'gn=gn' "${src}/out/.kibaos/system-tools.conf"; then
  fail "an unusable gn was recorded as substituted"
fi

KIBAOS_PACMAN=0 \
  FAKE_PACMAN_INSTALLED="${tmp}/installed" \
  KIBAOS_SYSTEM_BIN_DIR="${tmp}/bin" \
  KIBAOS_PACMAN_BIN="${tmp}/pacman" \
  "${TOOLS}" --resolver-args "${src}" >"${tmp}/resolver-d"

if grep -Fxq 'src/buildtools/linux64' "${tmp}/resolver-d"; then
  fail "the resolver skips a GN that was not substituted"
fi
grep -Fxq 'src/third_party/ninja' "${tmp}/resolver-d" ||
  fail "the resolver stopped skipping Ninja"

echo "system-tools test passed"
