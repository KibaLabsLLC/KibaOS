#!/bin/bash
# Build the kibaosfs package from the workspace in this tree.
#
# The PKGBUILD reads the Cargo workspace from ${srcdir}/kibaosfs-src rather
# than from a tarball, so this script is the one supported way to drive it:
# it copies kibaosfs/workspace there, fetches what Cargo.lock pins, and runs
# makepkg. Everything lands under KIBAOS_WORKDIR, by default a folder beside
# the other package builds under /mnt/build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${KIBAOS_WORKDIR:-/mnt/build/kibaos-work/kibaosfs-package}"
PACKAGE_SRC="${WORKDIR}/kibaosfs"

for command in rsync makepkg cargo; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Missing required command: ${command}" >&2
    exit 2
  }
done

mkdir -p "${WORKDIR}" "${WORKDIR}/build" "${WORKDIR}/pkgdest" \
  "${WORKDIR}/srcdest" "${WORKDIR}/logdest"
rm -rf "${PACKAGE_SRC}"
rsync -a --exclude pkg --exclude src --exclude workspace \
  "${REPO_ROOT}/kibaosfs/" "${PACKAGE_SRC}/"
# The workspace goes where the PKGBUILD's prepare() looks for it. A target
# directory that came along from a developer's tree would be a stale build
# with the right name, so it stays behind.
mkdir -p "${PACKAGE_SRC}/src"
rsync -a --exclude target --exclude target-dev --exclude '*.before-*' \
  "${REPO_ROOT}/kibaosfs/workspace/" "${PACKAGE_SRC}/src/kibaosfs-src/"

# makepkg builds in BUILDDIR, so ${srcdir} is under there and not beside the
# PKGBUILD. The workspace was copied next to the PKGBUILD, which is the copy
# the build has to read, so name it rather than leaving the PKGBUILD to guess
# a path that BUILDDIR has already moved.
export KIBAOSFS_SRC="${PACKAGE_SRC}/src/kibaosfs-src"
export BUILDDIR="${WORKDIR}/build"
export PKGDEST="${WORKDIR}/pkgdest"
export SRCDEST="${WORKDIR}/srcdest"
export LOGDEST="${WORKDIR}/logdest"

cd "${PACKAGE_SRC}"
makepkg --force --noconfirm --nodeps

package_file="$(find "${PKGDEST}" -maxdepth 1 -type f \
  -name 'kibaosfs-*.pkg.tar.*' ! -name 'kibaosfs-debug-*' ! -name '*.sig' -printf '%T@ %p\n' |
  sort -nr | head -1 | cut -d' ' -f2-)"
if [[ -z "${package_file}" ]]; then
  echo "makepkg finished but no kibaosfs package is in ${PKGDEST}" >&2
  exit 1
fi
echo "built ${package_file}"
