#!/bin/bash
# Build chromiumos-ash from the pinned bootstrap checkout and current series.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHROME_SRC="${CHROME_SRC:-/mnt/build/kibaos-work/chromium-bootstrap/src}"
WORKDIR="${KIBAOS_WORKDIR:-/mnt/build/kibaos-work/current-package}"
PACKAGE_SRC="${WORKDIR}/chromiumos-ash"

for command in rsync makepkg; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Missing required command: ${command}" >&2
    exit 2
  }
done

if [[ "$(id -u)" != "$(stat -c '%u' "${CHROME_SRC}")" ]]; then
  echo "Run as the owner of ${CHROME_SRC}." >&2
  exit 2
fi

# abseil-cpp lives in the tree's git and every TU includes it: emptied or
# lost files there fail as undefined ABSL_* names much later. Put the pinned
# copy back first; the refresh below then re-applies the series on top.
if [[ -f "${SCRIPT_DIR}/restore-truncated-sources.py" ]]; then
  python3 "${SCRIPT_DIR}/restore-truncated-sources.py" --tree "${CHROME_SRC}" \
    --restore-dir third_party/abseil-cpp --apply || {
    echo "error: could not restore ${CHROME_SRC}/third_party/abseil-cpp" >&2
    exit 1
  }
fi

# The import behind the tree also took its include lines: every `#include
# "absl/..."` line from abseil-cpp and every quoted include from protobuf, so
# the headers it kept include nothing and the first abseil TU fails on
# ABSL_NAMESPACE_BEGIN while the first protobuf TU fails on `absl`. Restore them
# before the refresh applies the series.
if [[ -f "${SCRIPT_DIR}/restore-imported-includes.py" ]]; then
  python3 "${SCRIPT_DIR}/restore-imported-includes.py" --tree "${CHROME_SRC}" \
    --apply || {
    echo "error: could not restore the includes the import dropped in ${CHROME_SRC}" >&2
    exit 1
  }
fi

CHROME_SRC="${CHROME_SRC}" KIBAOS_WORKDIR="${WORKDIR}" \
  "${SCRIPT_DIR}/refresh-bootstrap-series.sh"

mkdir -p "${WORKDIR}" "${WORKDIR}/build" "${WORKDIR}/pkgdest" \
  "${WORKDIR}/srcdest" "${WORKDIR}/logdest"
rm -rf "${PACKAGE_SRC}"
rsync -a --exclude pkg --exclude src \
  "${REPO_ROOT}/chromiumos-ash/" "${PACKAGE_SRC}/"

export CHROME_SRC
# The PKGBUILD is rsynced away from ci/, so hand it the tool that puts the
# Files page into resources.pak, the recovery tool its gn gen loop needs, and
# the path to the shill-nm-adapter source its fail-closed network guard checks.
export KIBAOS_FILES_PAK_TOOL="${REPO_ROOT}/ci/build-files-pak.sh"
export KIBAOS_CI_DIR="${REPO_ROOT}/ci"
export KIBAOS_SHILL_ADAPTER_DIR="${REPO_ROOT}/shill-nm-adapter"
export BUILDDIR="${WORKDIR}/build"
export PKGDEST="${WORKDIR}/pkgdest"
export SRCDEST="${WORKDIR}/srcdest"
export LOGDEST="${WORKDIR}/logdest"
export PATH="${CHROME_SRC}/buildtools/linux64:${CHROME_SRC}/third_party/ninja:${PATH}"

cd "${PACKAGE_SRC}"
makepkg --force --noconfirm --clean --nodeps

package_file="$(find "${PKGDEST}" -maxdepth 1 -type f \
  -name 'chromiumos-ash-*.pkg.tar.*' ! -name '*.sig' -printf '%T@ %p\n' |
  sort -nr | head -1 | cut -d' ' -f2-)"
if [[ -z "${package_file}" ]]; then
  echo "Package build completed without an artifact in ${PKGDEST}." >&2
  exit 1
fi

if command -v pacman >/dev/null 2>&1; then
  pacman -Qip "${package_file}" >/dev/null
  pacman -Qlp "${package_file}" >/dev/null
fi

package_list="${WORKDIR}/package-files.txt"
bsdtar -tf "${package_file}" > "${package_list}"
for required_entry in \
    usr/bin/chromiumos-ash \
    usr/bin/chromiumos-ash-session \
    usr/bin/chromiumos-ash-session-child \
    usr/lib/chromiumos-ash/chrome \
    usr/lib/chromiumos-ash/chrome-sandbox \
    usr/lib/chromiumos-ash/kibaos-session-manager-shim.py; do
  if ! grep -Fxq "${required_entry}" "${package_list}"; then
    echo "Package is missing required entry: ${required_entry}" >&2
    exit 1
  fi
done

sha256sum "${package_file}"
printf 'Packaged Chrome SHA-256: '
bsdtar -xOf "${package_file}" usr/lib/chromiumos-ash/chrome | sha256sum
echo "Current chromiumos-ash package: ${package_file}"
