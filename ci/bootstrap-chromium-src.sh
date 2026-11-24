#!/bin/bash
# Bootstrap a pinned Chromium source checkout for KibaOS Arch CI, so package
# builds do not depend on a pre-synced developer CHROME_SRC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEPOT_TOOLS="${KIBAOS_DEPOT_TOOLS:-${REPO_ROOT}/depot_tools_fresh}"
TARGET="${KIBAOS_BOOTSTRAP_TARGET:-/mnt/build/kibaos-work/chromium-bootstrap}"
REVISION="${KIBAOS_CHROMIUM_REVISION:-}"
JOBS="${KIBAOS_BOOTSTRAP_JOBS:-8}"
# Skip optional dependency downloads this build never uses. Set to 0 to sync
# everything the DEPS file would normally fetch.
LEAN_SYNC="${KIBAOS_LEAN_SYNC:-1}"
mode="plan"

usage() {
  cat <<'EOF'
Usage: ci/bootstrap-chromium-src.sh [options]

Creates a self-contained, pinned Chromium checkout that reproduces the
source state KibaOS builds from, without relying on the developer's
pre-synced chromium_dev/src. The result can be fed to
ci/verify-patch-series.sh and build-chromeos-ash.sh via CHROME_SRC.

Options:
  --revision SHA   Chromium src revision to pin. Default: HEAD of
                   chromium_dev/src when present, otherwise pins/chromium.sha.
  --target DIR     Checkout parent directory (holds .gclient and src/).
                   Default: /mnt/build/kibaos-work/chromium-bootstrap
  --run            Actually perform the sync. Without this flag the script
                   prints the plan and exits (safe dry run).
  --verify-series  After sync, run ci/verify-patch-series.sh against the
                   fresh checkout to prove the patch series applies to it
                   (uses a scratch worktree; the checkout stays pristine).
  --apply-series   After sync, apply patches/SERIES directly into the
                   checkout so it is ready for CHROME_SRC=<target>/src
                   makepkg / build-chromeos-ash.sh.
  -h, --help       Show this help.

Environment:
  KIBAOS_DEPOT_TOOLS=/path/to/depot_tools
  KIBAOS_BOOTSTRAP_TARGET=/mnt/build/kibaos-work/chromium-bootstrap
  KIBAOS_CHROMIUM_REVISION=<sha>
  KIBAOS_BOOTSTRAP_JOBS=8
  KIBAOS_LEAN_SYNC=1   Skip Telemetry deps, PGO profiles and NaCl (default).
                       Set 0 to sync everything. The PGO profiles are only
                       used by official builds; turn this off before building
                       with is_official_build = true.

Pruning the tree (ios, android_webview, ...) is not done here. It must run
after the patch series is applied, so the PKGBUILD does it at build time.
EOF
}

# The gclient custom_vars written below. Names come from Chromium's DEPS file;
# check_lean_vars() warns after the sync if one is missing from this revision.
LEAN_VARS=(
  checkout_telemetry_dependencies
  checkout_pgo_profiles
  checkout_nacl
)

verify_series=0
apply_series=0
need_value() {
  if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
    echo "Option $1 needs a value." >&2
    usage >&2
    exit 2
  fi
}
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --revision)
      need_value "$@"; REVISION="$2"; shift 2 ;;
    --target)
      need_value "$@"; TARGET="$2"; shift 2 ;;
    --run)
      mode="run"; shift ;;
    --verify-series)
      verify_series=1; shift ;;
    --apply-series)
      apply_series=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || {
  echo "KIBAOS_BOOTSTRAP_JOBS must be a positive integer: ${JOBS}" >&2
  exit 2
}
[[ "${LEAN_SYNC}" == "0" || "${LEAN_SYNC}" == "1" ]] || {
  echo "KIBAOS_LEAN_SYNC must be 0 or 1: ${LEAN_SYNC}" >&2
  exit 2
}

if [[ -z "${REVISION}" ]]; then
  if [[ -d "${REPO_ROOT}/chromium_dev/src/.git" ]]; then
    REVISION="$(git -C "${REPO_ROOT}/chromium_dev/src" rev-parse HEAD)"
  elif [[ -r "${REPO_ROOT}/pins/chromium.sha" ]]; then
    REVISION="$(tr -d '[:space:]' < "${REPO_ROOT}/pins/chromium.sha")"
  else
    echo "No --revision given, no chromium_dev/src, and no pins/chromium.sha." >&2
    exit 2
  fi
fi
[[ "${REVISION}" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "Chromium revision must be a 40-character commit SHA: ${REVISION}" >&2
  exit 2
}

if [[ ! -x "${DEPOT_TOOLS}/gclient" ]]; then
  echo "depot_tools not found at ${DEPOT_TOOLS} (set KIBAOS_DEPOT_TOOLS)." >&2
  exit 2
fi

if [[ "${LEAN_SYNC}" == "1" ]]; then
  lean_note="skipping ${LEAN_VARS[*]}"
else
  lean_note="full sync (KIBAOS_LEAN_SYNC=0)"
fi

echo "Bootstrap plan:"
echo "  depot_tools:   ${DEPOT_TOOLS}"
echo "  target dir:    ${TARGET}"
echo "  src revision:  ${REVISION}"
echo "  jobs:          ${JOBS}"
echo "  lean sync:     ${lean_note}"
echo "  steps:"
echo "    1. mkdir -p ${TARGET}"
echo "    2. write ${TARGET}/.gclient (solution \"src\", target_os [\"chromeos\"])"
echo "    3. gclient sync --revision src@${REVISION} --no-history --shallow \\"
echo "         --nohooks -j${JOBS}"
echo "    4. gclient runhooks (fetches clang, gn, sysroot, node, etc.)"
step=5
if [[ "${verify_series}" == "1" ]]; then
  echo "    ${step}. CHROME_SRC=${TARGET}/src ci/verify-patch-series.sh"
  step=$((step + 1))
fi
if [[ "${apply_series}" == "1" ]]; then
  echo "    ${step}. git apply patches/SERIES into ${TARGET}/src (ready for makepkg)"
fi

if [[ "${mode}" != "run" ]]; then
  echo
  echo "Dry run only. Re-run with --run to execute."
  exit 0
fi

export PATH="${DEPOT_TOOLS}:${PATH}"
export DEPOT_TOOLS_UPDATE=0
# Some Googlesource mirrors advertise Git LFS but reject its batch endpoint.
# Chromium's target-specific hooks fetch required prebuilts separately.
export GIT_LFS_SKIP_SMUDGE=1

custom_vars=""
if [[ "${LEAN_SYNC}" == "1" ]]; then
  for var in "${LEAN_VARS[@]}"; do
    custom_vars+="      \"${var}\": False,"$'\n'
  done
fi

mkdir -p "${TARGET}"
{
  cat <<'EOF'
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
EOF
  if [[ -n "${custom_vars}" ]]; then
    printf '    "custom_vars": {\n%s    },\n' "${custom_vars}"
  else
    printf '    "custom_vars": {},\n'
  fi
  cat <<'EOF'
  },
]
target_os = ["chromeos"]
EOF
} > "${TARGET}/.gclient"

# A custom var gclient does not know is ignored, which would silently undo the
# saving. Say so once the DEPS file is on disk.
check_lean_vars() {
  local deps="${TARGET}/src/DEPS" var
  [[ "${LEAN_SYNC}" == "1" && -r "${deps}" ]] || return 0
  for var in "${LEAN_VARS[@]}"; do
    if ! grep -q "${var}" "${deps}"; then
      echo "warning: ${var} is not in this revision's DEPS; it has no effect" >&2
    fi
  done
}

cd "${TARGET}"
echo "==> gclient sync (this downloads tens of GB; expect hours)"
gclient sync --revision "src@${REVISION}" --no-history --shallow \
  --nohooks -j"${JOBS}"
check_lean_vars
echo "==> gclient runhooks"
gclient runhooks -j"${JOBS}"

echo "==> synced $(git -C "${TARGET}/src" rev-parse HEAD)"

if [[ "${verify_series}" == "1" ]]; then
  echo "==> verifying patch series against the fresh checkout"
  CHROME_SRC="${TARGET}/src" "${SCRIPT_DIR}/verify-patch-series.sh" \
    --base-ref "${REVISION}"
fi

if [[ "${apply_series}" == "1" ]]; then
  echo "==> applying patch series into the checkout"
  while IFS= read -r patch_name; do
    [[ -z "${patch_name}" || "${patch_name}" == \#* ]] && continue
    echo "  applying ${patch_name}"
    git -C "${TARGET}/src" apply --whitespace=error-all \
      "${REPO_ROOT}/patches/${patch_name}"
  done < "${REPO_ROOT}/patches/SERIES"
  echo "==> series applied; checkout is ready for CHROME_SRC=${TARGET}/src"
fi

echo "Bootstrap complete: ${TARGET}/src"