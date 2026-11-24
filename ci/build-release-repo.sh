#!/bin/bash
# Build and atomically promote a coherent KibaOS release repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
target_repo="${REPO_DIR:-${REPO_ROOT}/private-repo}"
REPO_NAME="${REPO_NAME:-kibaos}"
release_channel="${KIBAOS_RELEASE_CHANNEL:-development}"
case "${release_channel}" in
  development|soak|candidate|public) ;;
  *)
    echo "KIBAOS_RELEASE_CHANNEL must be development, soak, candidate, or public" >&2
    exit 2
    ;;
esac

# A candidate/public repository is a trust boundary, not merely a newer
# development directory. Refuse to construct one unless the caller supplied
# the production signing identity, isolated public keyring, and detached
# package-signature path that the verifier will require later. Development
# fixtures retain an explicit unsigned channel for local testing.
if [[ "${release_channel}" == candidate || "${release_channel}" == public ]]; then
  [[ -n "${GPGKEY:-}" ]] || {
    echo "KIBAOS_RELEASE_CHANNEL=${release_channel} requires GPGKEY" >&2
    exit 2
  }
  [[ -r "${KIBAOS_REPO_KEYRING:-}" ]] || {
    echo "KIBAOS_RELEASE_CHANNEL=${release_channel} requires a readable KIBAOS_REPO_KEYRING" >&2
    exit 2
  }
  normalized_fingerprint="${KIBAOS_REPO_FINGERPRINT:-}"
  normalized_fingerprint="${normalized_fingerprint//[[:space:]]/}"
  normalized_fingerprint="${normalized_fingerprint^^}"
  [[ "${normalized_fingerprint}" =~ ^[0-9A-F]{40,64}$ ]] || {
    echo "KIBAOS_RELEASE_CHANNEL=${release_channel} requires a full KIBAOS_REPO_FINGERPRINT" >&2
    exit 2
  }
  [[ "${KIBAOS_SIGN_PACKAGES:-1}" == 1 ]] || {
    echo "KIBAOS_RELEASE_CHANNEL=${release_channel} requires detached package signatures" >&2
    exit 2
  }
  export KIBAOS_REQUIRE_SIGNATURES=1
fi
chromium_pkgver="$(awk -F= '$1 == "pkgver" { print $2; exit }' \
  "${REPO_ROOT}/chromiumos-ash/PKGBUILD")"
chromium_pkgrel="$(awk -F= '$1 == "pkgrel" { print $2; exit }' \
  "${REPO_ROOT}/chromiumos-ash/PKGBUILD")"
if [[ -z "${CHROMIUMOS_ASH_PACKAGE:-}" ]]; then
  package_dir="${KIBAOS_WORKDIR:-/mnt/build/kibaos-work}/current-package/pkgdest"
  package_name="chromiumos-ash-${chromium_pkgver}-${chromium_pkgrel}-x86_64.pkg.tar.*"
  mapfile -t package_candidates < <(find "${package_dir}" -maxdepth 1 -type f \
    -name "${package_name}" ! -name '*.sig' -printf '%p\n' | LC_ALL=C sort)
  if [[ "${#package_candidates[@]}" -ne 1 ]]; then
    echo "Expected exactly one Chromium package matching ${package_name}, found ${#package_candidates[@]}" >&2
    printf '  %s\n' "${package_candidates[@]}" >&2
    exit 2
  fi
  CHROMIUMOS_ASH_PACKAGE="${package_candidates[0]}"
fi
# kibaosfs is Rust and its PKGBUILD reads a Cargo workspace staged by
# ci/build-kibaosfs-package.sh rather than a tarball, so the generic makepkg
# loop cannot drive it. It arrives the same way the Chromium package does:
# built beforehand, named here, copied into the staging repository. Without
# this it was absent from every image, and chromiumos-ash lists it as the
# optional dependency the Files app reads the machine through.
if [[ -z "${KIBAOSFS_PACKAGE:-}" ]]; then
  kibaosfs_pkgver="$(awk -F= '$1 == "pkgver" { print $2; exit }' \
    "${REPO_ROOT}/kibaosfs/PKGBUILD")"
  kibaosfs_pkgrel="$(awk -F= '$1 == "pkgrel" { print $2; exit }' \
    "${REPO_ROOT}/kibaosfs/PKGBUILD")"
  kibaosfs_dir="${KIBAOS_KIBAOSFS_PKGDEST:-${KIBAOS_WORKDIR:-/mnt/build/kibaos-work}/kibaosfs-package/pkgdest}"
  kibaosfs_name="kibaosfs-${kibaosfs_pkgver}-${kibaosfs_pkgrel}-x86_64.pkg.tar.*"
  mapfile -t kibaosfs_candidates < <(find "${kibaosfs_dir}" -maxdepth 1 -type f \
    -name "${kibaosfs_name}" ! -name '*.sig' -printf '%p\n' | LC_ALL=C sort)
  if [[ "${#kibaosfs_candidates[@]}" -ne 1 ]]; then
    echo "Expected exactly one kibaosfs package matching ${kibaosfs_name}, found ${#kibaosfs_candidates[@]}" >&2
    printf '  %s\n' "${kibaosfs_candidates[@]}" >&2
    exit 2
  fi
  KIBAOSFS_PACKAGE="${kibaosfs_candidates[0]}"
fi
[[ -f "${KIBAOSFS_PACKAGE}" ]] || {
  echo "Missing prebuilt kibaosfs package: ${KIBAOSFS_PACKAGE}" >&2
  exit 2
}

staging="${target_repo}.staging.$$"
previous="${target_repo}.previous"

[[ "$(id -u)" -ne 0 ]] || {
  echo "Run build-release-repo.sh as an unprivileged build user." >&2
  exit 2
}
[[ -f "${CHROMIUMOS_ASH_PACKAGE}" ]] || {
  echo "Missing prebuilt Chromium package: ${CHROMIUMOS_ASH_PACKAGE}" >&2
  exit 2
}

cleanup() {
  rm -rf "${staging}"
}
trap cleanup EXIT
mkdir -p "${staging}"
cp -a "${CHROMIUMOS_ASH_PACKAGE}" "${staging}/"
cp -a "${KIBAOSFS_PACKAGE}" "${staging}/"

makepkg_config="${staging}/makepkg.conf"
sed -E 's/(^OPTIONS=.*[( ])debug([ )])+/\1!debug\2/' \
  /etc/makepkg.conf >"${makepkg_config}"
if grep -Eq '^OPTIONS=.*[( ]debug([ )])' "${makepkg_config}"; then
  echo "Failed to disable makepkg debug splitting." >&2
  exit 1
fi

export REPO_DIR="${staging}"
export REPO_NAME
export KIBAOS_PACKAGES="kibaos-account-helper kibaos-system-helper shill-nm-adapter kibaos-power kibaos-hardware kibaos-wallpapers kibaos-boot kibaos-host-bridge kibaos-login kibaos-greeter kibaos-ai kibaos-android kibaos-webapp-shortcuts kibaos kibaos-full"
export KIBAOS_NODEPS_PACKAGES="${KIBAOS_PACKAGES}"
export MAKEPKG_FLAGS="${MAKEPKG_FLAGS:---force --noconfirm --clean --config ${makepkg_config}}"
if [[ -n "${GPGKEY:-}" ]]; then
  : "${KIBAOS_REPO_KEYRING:?Set KIBAOS_REPO_KEYRING to an exported public repository key}"
  : "${KIBAOS_REPO_FINGERPRINT:?Set KIBAOS_REPO_FINGERPRINT to the full repository signing fingerprint}"
fi
"${SCRIPT_DIR}/build-private-repo.sh"
rm -f "${makepkg_config}"
# A version that is already published keeps its published bytes. The
# directory is a copy of the hosted repository (ci/release.sh fetch-published).
if [[ -n "${KIBAOS_PUBLISHED_REPO:-}" ]]; then
  [[ -n "${GPGKEY:-}" ]] || { echo "KIBAOS_PUBLISHED_REPO needs a signed build" >&2; exit 1; }
  "${SCRIPT_DIR}/reuse-published-packages.sh" "${staging}" "${KIBAOS_PUBLISHED_REPO}"
fi
REPO_DIR="${staging}" "${SCRIPT_DIR}/write-release-checksums.sh"
if [[ -n "${GPGKEY:-}" ]]; then
  export KIBAOS_REQUIRE_SIGNATURES=1
fi
# Metadata-only makepkg calls still validate PKGDEST permissions. Keep the
# verifier pointed at the writable staging area instead of a package source
# directory, which is commonly read-only for the unprivileged build user.
PKGDEST="${staging}" SRCDEST="${staging}" LOGDEST="${staging}" \
  "${SCRIPT_DIR}/verify-release-repo.sh"

rm -rf "${previous}"
if [[ -e "${target_repo}" ]]; then
  mv "${target_repo}" "${previous}"
fi
mv "${staging}" "${target_repo}"
trap - EXIT
echo "Promoted release repository: ${target_repo}"
