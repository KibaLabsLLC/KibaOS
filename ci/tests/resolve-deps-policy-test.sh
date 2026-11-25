#!/usr/bin/env bash
# The dep resolver implements the linux desktop target decision table.
#
# Kept: Ash and Aura are compiled from source and their resources come with
# the checkout; the ChromeOS-specific Chromium dependencies stay in (Ash
# needs them to compile), the linux host dependencies stay in, and the
# ChromeOS GN configuration from DEPS is still written (with cros_boards at
# its empty DEPS default, since desktop builds need no board SDK).
#
# Skipped inside the resolver: the chromite CrOS SDK behind Simple Chrome,
# the Simple Chrome setup that hangs off cros_boards, and the Tast test
# hooks. Platform-exclusive dependencies stay out when their checkout
# variable is off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-deps.py"

fail() {
  echo "resolve-deps policy test: $1" >&2
  exit 1
}

run_resolver() {
  local root="$1" extra=("${@:2}")
  python3 "${RESOLVER}" --root "${root}" --jobs 4 "${extra[@]}"
}

# One local git remote serves every dependency in the fixture.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/kibaos-resolver-policy-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

seed="${tmp}/seed"
git init -q "${seed}"
git -C "${seed}" config user.name "KibaOS CI Test"
git -C "${seed}" config user.email ci-test@kibaos.invalid
git -C "${seed}" config commit.gpgsign false
printf 'dependency payload\n' > "${seed}/payload.txt"
git -C "${seed}" add .
git -C "${seed}" commit -qm payload
git -C "${seed}" branch -m main
git clone -q --bare "${seed}" "${tmp}/remote.git"

root="${tmp}/root"
mkdir -p "${root}/src"

cat > "${root}/src/DEPS" <<EOF
vars = {
  'source': '${tmp}/remote.git',
  'cros_boards': Str(''),
  'checkout_simplechrome': '"{cros_boards}" != ""',
}
deps = {
  'src/ash-dep': {
      'url': Var('source') + '@main',
      'condition': 'checkout_chromeos',
  },
  'src/third_party/chromite': {
      'url': Var('source') + '@main',
      'condition': 'checkout_chromeos',
  },
  'src/simplechrome-dep': {
      'url': Var('source') + '@main',
      'condition': 'checkout_simplechrome',
  },
  'src/host-dep': {
      'url': Var('source') + '@main',
      'condition': 'checkout_linux',
  },
  'src/android-only-dep': {
      'url': Var('source') + '@main',
      'condition': 'checkout_android',
  },
}
gclient_gn_args_file = 'src/build/config/gclient_args.gni'
gclient_gn_args = [
  'cros_boards',
]
hooks = [
  {
    'name': 'tast_control',
    'pattern': '.',
    'action': ['touch', 'src/tast-ran'],
  },
  {
    'name': 'tast_control_cq_tests',
    'pattern': '.',
    'condition': 'checkout_simplechrome',
    'action': ['touch', 'src/tast-cq-ran'],
  },
  {
    'name': 'simplechrome-hook',
    'pattern': '.',
    'condition': 'checkout_simplechrome',
    'action': ['touch', 'src/simplechrome-ran'],
  },
  {
    'name': 'desktop-kept-hook',
    'pattern': '.',
    'action': ['touch', 'src/kept-ran'],
  },
]
EOF

run_resolver "${root}" > "${tmp}/resolver.log"

# Keep: the ChromeOS-specific dependencies Ash needs.
[[ -f "${root}/src/ash-dep/payload.txt" ]] \
  || fail "ChromeOS-only dependency was not kept"
# Keep: the linux host dependencies.
[[ -f "${root}/src/host-dep/payload.txt" ]] \
  || fail "linux host dependency was not kept"
# Keep: the ChromeOS GN configuration, with no board SDK.
[[ -f "${root}/src/build/config/gclient_args.gni" ]] \
  || fail "gclient_args.gni was not written"
grep -Fx 'cros_boards = ""' "${root}/src/build/config/gclient_args.gni" \
  || fail "cros_boards should stay at the empty DEPS default"

# Skip: device SDK tooling and everything behind cros_boards.
[[ ! -d "${root}/src/third_party/chromite" ]] \
  || fail "chromite (device SDK setup) should be skipped"
[[ ! -d "${root}/src/simplechrome-dep" ]] \
  || fail "Simple Chrome dependency should be skipped (no cros_boards)"
grep -F "skip  src/third_party/chromite" "${tmp}/resolver.log" >/dev/null \
  || fail "the chromite skip is not logged"

# Skip: the Tast test hooks.
[[ ! -e "${root}/src/tast-ran" ]] || fail "tast_control hook should be skipped"
[[ ! -e "${root}/src/tast-cq-ran" ]] \
  || fail "tast_control_cq_tests hook should be skipped"
[[ ! -e "${root}/src/simplechrome-ran" ]] \
  || fail "Simple Chrome hook should be skipped (no cros_boards)"

# Keep: ordinary desktop hooks still run.
[[ -e "${root}/src/kept-ran" ]] || fail "desktop hooks were not run"

# Skip: a genuinely platform-exclusive dependency with its checkout off.
[[ ! -d "${root}/src/android-only-dep" ]] \
  || fail "android-only dependency should be skipped"

# A board passed explicitly opts back into the device setup.
device="${tmp}/device"
mkdir -p "${device}/src"
cp "${root}/src/DEPS" "${device}/src/DEPS"
run_resolver "${device}" --var cros_boards=amd64-generic \
  > "${tmp}/device.log"
[[ -f "${device}/src/third_party/chromite/payload.txt" ]] \
  || fail "an explicit cros_boards should restore chromite"
[[ -e "${device}/src/simplechrome-dep/payload.txt" ]] \
  || fail "an explicit cros_boards should restore Simple Chrome deps"
grep -Fx 'cros_boards = "amd64-generic"' \
  "${device}/src/build/config/gclient_args.gni" \
  || fail "the explicit board should reach the GN args"

echo "resolve-deps policy test passed"
