#!/bin/bash
# Bootstrap the latest Project Lumen source for KibaOS Arch CI.
#
# Git:
#   Fetches and updates Project Lumen.
#
# ci/resolve-deps.py:
#   Resolves DEPS git dependencies (and cipd, if available) and runs
#   Chromium build hooks. No gclient involved.
#
# Source:
#   ${TARGET}/src
#
# Compatible with:
#   ci/verify-patch-series.sh
#   ci/build-chromeos-ash.sh
#   CHROME_SRC=${TARGET}/src

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: only used for cipd / vpython3 if hooks need them.
DEPOT_TOOLS="${KIBAOS_DEPOT_TOOLS:-}"

LUMEN_REPO="${KIBAOS_LUMEN_REPOSITORY:-https://github.com/KibaLabsLLC/Lumen.git}"
LUMEN_BRANCH="${KIBAOS_LUMEN_BRANCH:-main}"

TARGET="${KIBAOS_BOOTSTRAP_TARGET:-/mnt/build/kibaos-work/lumen-bootstrap}"
SRC_DIR="${TARGET}/src"

JOBS="${KIBAOS_BOOTSTRAP_JOBS:-8}"
LEAN_SYNC="${KIBAOS_LEAN_SYNC:-1}"
SYSTEM_TOOLS="${KIBAOS_SYSTEM_TOOLS:-1}"
RESTORE_ABSEIL="${KIBAOS_RESTORE_ABSEIL:-1}"

mode="plan"
verify_series=0
apply_series=0
skip_hooks=0

usage() {
  cat <<'EOF'
Usage: ci/bootstrap-chromium-src.sh [options]

Bootstraps the latest Project Lumen source for KibaOS CI.

Git fetches the latest commit from the configured Lumen branch.
ci/resolve-deps.py processes Lumen's DEPS file and executes build hooks.

Options:
  --target DIR     Checkout parent directory (holds src/).
  --run            Actually perform the bootstrap.
  --skip-hooks     Fetch dependencies but do not run DEPS hooks.
  --verify-series  Verify patches/SERIES against the fresh checkout.
  --apply-series   Apply patches/SERIES directly into the checkout.
  -h, --help       Show this help.

Environment:
  KIBAOS_DEPOT_TOOLS=/path/to/depot_tools   (optional; for cipd/vpython3)
  KIBAOS_LUMEN_REPOSITORY=https://github.com/KibaLabsLLC/Lumen.git
  KIBAOS_LUMEN_BRANCH=main
  KIBAOS_BOOTSTRAP_TARGET=/mnt/build/kibaos-work/lumen-bootstrap
  KIBAOS_BOOTSTRAP_JOBS=8
  KIBAOS_LEAN_SYNC=1
  KIBAOS_SYSTEM_TOOLS=1
  KIBAOS_RESTORE_ABSEIL=1

KIBAOS_LEAN_SYNC:
  1 = Skip optional dependencies when supported by DEPS.
  0 = Perform a full dependency sync.

KIBAOS_SYSTEM_TOOLS:
  1 = Use pacman's gn and ninja instead of the copies Chromium's DEPS
      downloads (ci/system-tools.sh); the clang toolchain stays Chromium's.
  0 = Download and use Chromium's toolchains.

KIBAOS_RESTORE_ABSEIL:
  1 = Put the pinned third_party/abseil-cpp back when the checkout has
      lost or emptied part of it (ci/restore-truncated-sources.py
      --restore-dir).
  0 = Leave the checkout's abseil-cpp as it is.

No revision is pinned. Every run fetches the latest branch HEAD.

Pruning must happen after the patch series is applied, as required
by the KibaOS package build.
EOF
}

need_value() {
  if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
    echo "Option $1 needs a value." >&2
    usage >&2
    exit 2
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target)
      need_value "$@"
      TARGET="$2"
      SRC_DIR="${TARGET}/src"
      shift 2
      ;;
    --run)
      mode="run"
      shift
      ;;
    --skip-hooks)
      skip_hooks=1
      shift
      ;;
    --verify-series)
      verify_series=1
      shift
      ;;
    --apply-series)
      apply_series=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Validate configuration.
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || {
  echo "KIBAOS_BOOTSTRAP_JOBS must be a positive integer: ${JOBS}" >&2
  exit 2
}

[[ "${LEAN_SYNC}" == "0" || "${LEAN_SYNC}" == "1" ]] || {
  echo "KIBAOS_LEAN_SYNC must be 0 or 1: ${LEAN_SYNC}" >&2
  exit 2
}

command -v git >/dev/null 2>&1 || {
  echo "git is required." >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required." >&2
  exit 2
}

RESOLVER="${SCRIPT_DIR}/resolve-deps.py"
[[ -f "${RESOLVER}" ]] || {
  echo "Missing ${RESOLVER}." >&2
  exit 2
}

# Resolve the latest commit on the Lumen branch.
resolve_lumen_revision() {
  local revision

  revision="$(
    git ls-remote "${LUMEN_REPO}" "refs/heads/${LUMEN_BRANCH}" |
      awk 'NR == 1 { print $1 }'
  )"

  [[ "${revision}" =~ ^[0-9a-fA-F]{40}$ ]] || {
    echo "Could not resolve Lumen branch: ${LUMEN_BRANCH}" >&2
    return 1
  }

  printf '%s\n' "${revision}"
}

# Optional Chromium DEPS variables.
LEAN_VARS=(
  checkout_telemetry_dependencies
  checkout_pgo_profiles
  checkout_nacl
  checkout_android
)

# CIPD dep path prefixes to skip entirely in lean mode.
# ANGLE restricted traces require CIPD auth and are not needed for the build.
LEAN_SKIP_DEP_PATHS=(
  "src/third_party/angle/src/tests/restricted_traces"
)

resolver_args=()

# Skip any hook that invokes chromite/bin/cros (not present for linux builds).
resolver_args+=(--skip-hook-action "chromite/bin/cros")

# Skip any hook whose action directly references the chrome/ directory, and
# skip named hooks known to scan the chrome/ tree (Lumen is a shell delegate;
# src/chrome does not exist in this build).
resolver_args+=(--skip-hook-action "chrome/")
resolver_args+=(--skip-hook-name "Generate location tags for tests")

if [[ "${LEAN_SYNC}" == "1" ]]; then
  for var in "${LEAN_VARS[@]}"; do
    resolver_args+=(--var "${var}=False")
  done
  for skip_path in "${LEAN_SKIP_DEP_PATHS[@]}"; do
    resolver_args+=(--skip-dep-path "${skip_path}")
  done
  lean_note="skipping ${LEAN_VARS[*]}"
else
  lean_note="full dependency sync"
fi

echo "Project Lumen bootstrap plan:"
echo "  repository:  ${LUMEN_REPO}"
echo "  branch:      ${LUMEN_BRANCH}"
echo "  resolver:    ${RESOLVER}"
echo "  target:      ${TARGET}"
echo "  source:      ${SRC_DIR}"
echo "  jobs:        ${JOBS}"
echo "  lean sync:   ${lean_note}"
if [[ "${SYSTEM_TOOLS}" == "1" ]]; then
  echo "  tools:       pacman packages where the build root has them"
else
  echo "  tools:       Chromium's downloaded toolchains"
fi
echo "  revision:    latest branch HEAD"
echo
echo "  steps:"
echo "    1. Resolve latest Lumen commit using Git"
echo "    2. Fetch and check out Lumen"
echo "    3. Resolve DEPS and fetch dependencies (resolve-deps.py)"
if [[ "${skip_hooks}" == "1" ]]; then
  echo "    4. Run DEPS hooks (skipped)"
else
  echo "    4. Run DEPS hooks"
fi

step=5

if [[ "${verify_series}" == "1" ]]; then
  echo "    ${step}. Verify patches/SERIES"
  step=$((step + 1))
fi

if [[ "${apply_series}" == "1" ]]; then
  echo "    ${step}. Apply patches/SERIES"
fi

if [[ "${mode}" != "run" ]]; then
  echo
  echo "Dry run only. Re-run with --run to execute."
  exit 0
fi

# Environment.
if [[ -n "${DEPOT_TOOLS}" && -d "${DEPOT_TOOLS}" ]]; then
  export PATH="${DEPOT_TOOLS}:${PATH}"
fi
export DEPOT_TOOLS_UPDATE=0
export GIT_LFS_SKIP_SMUDGE=1

mkdir -p "${TARGET}"

# Resolve the branch HEAD immediately before fetching.
echo "==> Resolving latest Project Lumen commit"

REVISION="$(resolve_lumen_revision)"

echo "==> Latest Lumen commit: ${REVISION}"

# Fetch Lumen using Git.
if [[ -d "${SRC_DIR}/.git" ]]; then
  echo "==> Updating existing Lumen checkout"

  git -C "${SRC_DIR}" remote set-url origin "${LUMEN_REPO}"
  git -C "${SRC_DIR}" fetch --depth=1 origin "${REVISION}"
else
  if [[ -d "${SRC_DIR}" ]] &&
     [[ -n "$(find "${SRC_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Error: ${SRC_DIR} exists but is not a Git checkout." >&2
    echo "Move or remove it before bootstrapping." >&2
    exit 2
  fi

  echo "==> Initializing Lumen Git checkout"

  mkdir -p "${SRC_DIR}"
  git -C "${SRC_DIR}" init
  git -C "${SRC_DIR}" remote add origin "${LUMEN_REPO}"
  git -C "${SRC_DIR}" fetch --depth=1 origin "${REVISION}"
fi

echo "==> Checking out latest Lumen source"

git -C "${SRC_DIR}" checkout --detach --force FETCH_HEAD

ACTUAL_REVISION="$(git -C "${SRC_DIR}" rev-parse HEAD)"

if [[ "${ACTUAL_REVISION}" != "${REVISION}" ]]; then
  echo "Error: Lumen checkout does not match fetched revision." >&2
  exit 1
fi

if [[ ! -f "${SRC_DIR}/DEPS" ]]; then
  echo "Error: Lumen has no DEPS file." >&2
  echo "Cannot resolve dependencies." >&2
  exit 1
fi

echo "==> Lumen checked out at ${ACTUAL_REVISION}"

# abseil-cpp is vendored in Lumen's git tree and nearly every TU includes it.
# A file that was emptied or lost there does not report itself as missing: the
# header includes fine and declares nothing, so the first abseil TU fails on
# ABSL_NAMESPACE_BEGIN with no clue where it went. Put the pinned copy back
# before the series is applied on top of it.
if [[ "${RESTORE_ABSEIL}" == "1" ]]; then
  ABSEIL_RESTORE="${SCRIPT_DIR}/restore-truncated-sources.py"

  if [[ -f "${ABSEIL_RESTORE}" ]]; then
    echo "==> Checking the vendored abseil-cpp"
    python3 "${ABSEIL_RESTORE}" --tree "${SRC_DIR}" \
      --restore-dir third_party/abseil-cpp --apply ||
      echo "warning: abseil-cpp could not be restored; the build will fail on its headers" >&2
  else
    echo "warning: ${ABSEIL_RESTORE} is missing; abseil-cpp damage stays as it is" >&2
  fi
fi

# Use the build root's own GN, Ninja and Clang instead of the prebuilt copies
# Chromium's DEPS downloads. The helper links them into the checkout and names
# the DEPS entries to leave out; it falls back to the downloads, one tool at a
# time, when the packages are not there.
if [[ "${SYSTEM_TOOLS}" == "1" ]]; then
  echo "==> Preferring Arch packages for build tools"

  SYSTEM_TOOLS_SCRIPT="${SCRIPT_DIR}/system-tools.sh"

  if [[ -x "${SYSTEM_TOOLS_SCRIPT}" ]]; then
    "${SYSTEM_TOOLS_SCRIPT}" --link "${SRC_DIR}" ||
      echo "warning: system tool setup failed; Chromium's downloads stay in use" >&2

    while IFS= read -r resolver_arg; do
      resolver_args+=("${resolver_arg}")
    done < <("${SYSTEM_TOOLS_SCRIPT}" --resolver-args "${SRC_DIR}")
  else
    echo "warning: ${SYSTEM_TOOLS_SCRIPT} is missing; Chromium's toolchains stay in use" >&2
  fi
fi

# Warn about lean-sync variables this DEPS revision does not define.
check_lean_vars() {
  local deps="${SRC_DIR}/DEPS"
  local var

  [[ "${LEAN_SYNC}" == "1" && -r "${deps}" ]] || return 0

  for var in "${LEAN_VARS[@]}"; do
    if ! grep -q "${var}" "${deps}"; then
      echo "warning: ${var} is not in this revision's DEPS; it has no effect" >&2
    fi
  done
}

check_lean_vars

# Resolve DEPS, fetch dependencies, write gclient_args.gni, run hooks.
echo "==> Syncing Lumen dependencies"

resolver_cmd=(python3 "${RESOLVER}" --root "${TARGET}" --jobs "${JOBS}")
if [[ "${skip_hooks}" == "1" ]]; then
  resolver_cmd+=(--skip-hooks)
fi
resolver_cmd+=("${resolver_args[@]}")

"${resolver_cmd[@]}"

# Ensure the Lumen source was not changed by dependency synchronization.
FINAL_REVISION="$(git -C "${SRC_DIR}" rev-parse HEAD)"

if [[ "${FINAL_REVISION}" != "${REVISION}" ]]; then
  echo "Error: Lumen source revision changed during dependency sync." >&2
  echo "Expected: ${REVISION}" >&2
  echo "Actual:   ${FINAL_REVISION}" >&2
  exit 1
fi

echo "==> Dependencies and hooks completed"

# A truncated dependency file is silent until something includes it, and then
# it reads as a compile error about a missing declaration rather than a bad
# copy. Check every checkout now that the sync has finished: the tool restores
# only files that still exist and are modified outside chrome/ and the patch
# series, so a pruned file stays pruned and a patched one stays patched.
echo "==> Checking dependency sources"

if ! python3 "${REPO_ROOT}/ci/restore-truncated-sources.py" \
    --tree "${SRC_DIR}" --apply --quiet-chrome; then
  echo "warning: the source check above found damage it could not repair" >&2
  echo "         (see its ==> source-check: lines; a build now may fail on it)" >&2
fi

# Verify patches against the fetched source.
if [[ "${verify_series}" == "1" ]]; then
  echo "==> Verifying patch series"

  CHROME_SRC="${SRC_DIR}" \
    "${SCRIPT_DIR}/verify-patch-series.sh"
fi

# Apply patches directly to the source.
if [[ "${apply_series}" == "1" ]]; then
  echo "==> Applying patch series"

  while IFS= read -r patch_name; do
    [[ -z "${patch_name}" || "${patch_name}" == \#* ]] && continue

    patch_file="${REPO_ROOT}/patches/${patch_name}"

    if [[ ! -f "${patch_file}" ]]; then
      echo "Missing patch: ${patch_file}" >&2
      exit 1
    fi

    echo "  applying ${patch_name}"

    git -C "${SRC_DIR}" apply --whitespace=error-all "${patch_file}"
  done < "${REPO_ROOT}/patches/SERIES"

  echo "==> Patch series applied"
fi

# The import behind the tree also dropped every `#include "absl/..."` line from
# third_party/abseil-cpp, so the headers it kept include nothing and the first
# abseil TU fails on ABSL_NAMESPACE_BEGIN. Last, after the source check above:
# that check restores any modified file it does not recognise, and these files
# are modified on purpose.
echo "==> Restoring the abseil includes the source import dropped"

if ! python3 "${SCRIPT_DIR}/restore-abseil-includes.py" \
    --tree "${SRC_DIR}" --apply; then
  echo "warning: the abseil includes could not be restored (see ==> abseil-includes:" >&2
  echo "         above); a build now fails on its headers" >&2
fi

echo
echo "========================================"
echo " Project Lumen bootstrap complete"
echo "========================================"
echo " Source:   ${SRC_DIR}"
echo " Revision: ${FINAL_REVISION}"
echo
echo "Use with:"
echo "  CHROME_SRC=${SRC_DIR}"
