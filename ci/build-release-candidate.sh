#!/bin/bash
# Build the pinned Chromium package and a coherent Arch-native KibaOS repo.
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || {
  echo "build-release-candidate.sh must run as root." >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${KIBAOS_WORKDIR:-/mnt/build/kibaos-work}"
ARCHROOT="${ARCHROOT:-${WORKDIR}/archroot}"
CHROME_SRC="${CHROME_SRC:-${WORKDIR}/chromium-bootstrap/src}"
OUTPUT_REPO="${REPO_DIR:-${WORKDIR}/private-repo}"
REUSE_CHROMIUM=0

if [[ "${1:-}" == "--reuse-chromium" ]]; then
  REUSE_CHROMIUM=1
  shift
fi
[[ "$#" -eq 0 ]] || {
  echo "Usage: $0 [--reuse-chromium]" >&2
  exit 2
}

for command in rsync runuser stat; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Missing required command: ${command}" >&2
    exit 2
  }
done
[[ -d "${ARCHROOT}" && -d "${CHROME_SRC}" ]] || {
  echo "Missing Arch root or pinned Chromium checkout." >&2
  exit 2
}

chrome_owner="$(stat -c '%U' "${CHROME_SRC}")"
package_workdir="${WORKDIR}/current-package"
pkgver="$(awk -F= '$1 == "pkgver" { print $2; exit }' "${REPO_ROOT}/chromiumos-ash/PKGBUILD")"
pkgrel="$(awk -F= '$1 == "pkgrel" { print $2; exit }' "${REPO_ROOT}/chromiumos-ash/PKGBUILD")"

find_chromium_package() {
  local package_dir="$1"
  local package_name="chromiumos-ash-${pkgver}-${pkgrel}-x86_64.pkg.tar.*"
  local -a candidates=()
  mapfile -t candidates < <(find "${package_dir}" -maxdepth 1 -type f \
    -name "${package_name}" ! -name '*.sig' -printf '%p\n' | LC_ALL=C sort)
  if [[ "${#candidates[@]}" -ne 1 ]]; then
    echo "Expected exactly one Chromium package matching ${package_name}, found ${#candidates[@]}" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
  fi
  printf '%s\n' "${candidates[0]}"
}

if [[ "${REUSE_CHROMIUM}" == 0 ]]; then
  runuser -u "${chrome_owner}" -- env \
    CHROME_SRC="${CHROME_SRC}" KIBAOS_WORKDIR="${package_workdir}" \
    nice -n "${KIBAOS_BUILD_NICE:-10}" \
    "${SCRIPT_DIR}/build-current-chromiumos-ash-package.sh"
fi
chrome_package="$(find_chromium_package "${package_workdir}/pkgdest")"
kibaosfs_pkgdest="${KIBAOS_KIBAOSFS_PKGDEST:-${WORKDIR}/kibaosfs-package/pkgdest}"
# Named by the version the PKGBUILD is on, not by a wildcard. Earlier builds
# stay in the same PKGDEST, so a wildcard finds every kibaosfs ever built here
# and refuses rather than picking the current one.
kibaosfs_pkgver="$(awk -F= '$1 == "pkgver" { print $2; exit }' "${REPO_ROOT}/kibaosfs/PKGBUILD")"
kibaosfs_pkgrel="$(awk -F= '$1 == "pkgrel" { print $2; exit }' "${REPO_ROOT}/kibaosfs/PKGBUILD")"
mapfile -t kibaosfs_found < <(find "${kibaosfs_pkgdest}" -maxdepth 1 -type f \
  -name "kibaosfs-${kibaosfs_pkgver}-${kibaosfs_pkgrel}-x86_64.pkg.tar.*" ! -name '*.sig' \
  -printf '%p\n' | LC_ALL=C sort)
if [[ "${#kibaosfs_found[@]}" -ne 1 ]]; then
  echo "Expected exactly one kibaosfs-${kibaosfs_pkgver}-${kibaosfs_pkgrel} package in ${kibaosfs_pkgdest}, found ${#kibaosfs_found[@]}" >&2
  echo "Build it with ci/build-kibaosfs-package.sh, which is the only way its PKGBUILD can be driven." >&2
  printf '  %s\n' "${kibaosfs_found[@]}" >&2
  exit 1
fi
kibaosfs_package="${kibaosfs_found[0]}"
[[ -f "${chrome_package}" ]] || {
  echo "Missing current Chromium package: ${chrome_package}" >&2
  exit 1
}

arch_source="${ARCHROOT}/build/kibaos"
arch_input="${ARCHROOT}/build/kibaos-input"
arch_output="${ARCHROOT}/build/kibaos-output"
arch_build_uid="$(stat -c '%u' "${ARCHROOT}/home/aurabuild")"
arch_build_gid="$(stat -c '%g' "${ARCHROOT}/home/aurabuild")"
install -d -m 755 "${arch_source}" "${arch_input}"
install -d -o "${arch_build_uid}" -g "${arch_build_gid}" -m 755 \
  "${arch_output}"
# The photographs are ignored inside the package directory, so they are not
# in the checkout the way the other sources are. Put them there before the
# tree is copied into the build root, or kibaos-wallpapers builds without the
# thing it exists to ship.
"${SCRIPT_DIR}/stage-wallpapers.sh"

rsync -a --delete --exclude pkg --exclude src --exclude __pycache__ \
  "${REPO_ROOT}/kibaos-account-helper" \
  "${REPO_ROOT}/kibaos-system-helper" \
  "${REPO_ROOT}/kibaos-power" \
  "${REPO_ROOT}/kibaos-hardware" \
  "${REPO_ROOT}/kibaos-wallpapers" \
  "${REPO_ROOT}/kibaos-boot" \
  "${REPO_ROOT}/kibaos-host-bridge" \
  "${REPO_ROOT}/kibaos-login" \
  "${REPO_ROOT}/shill-nm-adapter" \
  "${REPO_ROOT}/kibaos-ai" \
  "${REPO_ROOT}/kibaos-android" \
  "${REPO_ROOT}/kibaos-greeter" \
  "${REPO_ROOT}/kibaos-webapp-shortcuts" \
  "${REPO_ROOT}/kibaos" \
  "${REPO_ROOT}/kibaos-full" \
  "${REPO_ROOT}/kibaosfs" \
  "${REPO_ROOT}/chromiumos-ash" \
  "${REPO_ROOT}/ci" \
  "${REPO_ROOT}/installer" \
  "${arch_source}/"
install -m 644 "${chrome_package}" "${arch_input}/"
install -m 644 "${kibaosfs_package}" "${arch_input}/"
chown -R "${arch_build_uid}:${arch_build_gid}" \
  "${arch_source}" "${arch_input}" "${arch_output}"
rm -rf "${arch_output}/kibaos" "${arch_output}/kibaos.previous"

"${SCRIPT_DIR}/run-in-arch-root.sh" /usr/bin/runuser -u aurabuild -- \
  /usr/bin/bash -lc \
  "cd /build/kibaos && KIBAOS_WALLPAPER_DIR=/build/kibaos/kibaos-wallpapers KIBAOS_RELEASE_CHANNEL=candidate REPO_DIR=/build/kibaos-output/kibaos CHROMIUMOS_ASH_PACKAGE=/build/kibaos-input/$(basename "${chrome_package}") KIBAOSFS_PACKAGE=/build/kibaos-input/$(basename "${kibaosfs_package}") ci/build-release-repo.sh"

host_staging="${OUTPUT_REPO}.staging.$$"
host_previous="${OUTPUT_REPO}.previous"
trap 'rm -rf "${host_staging}"' EXIT
rsync -a "${arch_output}/kibaos/" "${host_staging}/"
rm -rf "${host_previous}"
if [[ -e "${OUTPUT_REPO}" ]]; then
  mv "${OUTPUT_REPO}" "${host_previous}"
fi
mv "${host_staging}" "${OUTPUT_REPO}"
trap - EXIT

KIBAOS_SOURCE_MANIFEST="${WORKDIR}/source-manifest.md" \
  CHROME_SRC="${CHROME_SRC}" "${SCRIPT_DIR}/write-source-manifest.sh"
echo "Release candidate ready: ${OUTPUT_REPO}"
