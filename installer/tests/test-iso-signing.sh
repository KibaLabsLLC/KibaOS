#!/usr/bin/env bash
# Build an image with the key a build makes for itself, then check the result
# the way a stranger would: from the image, its signature and the key published
# beside it, with an empty keyring and nothing else from this machine.
set -Eeuo pipefail
trap 'case $- in *e*) printf "%s: line %s gave up: %s\n" "${0##*/}" "$LINENO" "$BASH_COMMAND" >&2 ;; esac' ERR

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

install -d -m 0755 "$TMP/repo" "$TMP/package"
while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'pkgname = %s\npkgver = 1.0-1\narch = any\n' "$name" >"$TMP/package/.PKGINFO"
  bsdtar -cf "$TMP/repo/${name}-1.0-1-any.pkg.tar.zst" -C "$TMP/package" .PKGINFO
done <"$ROOT/installer/expected-packages.txt"

# Assembling the image needs a network, an Arch root and an hour. Everything
# this test is about happens after that finishes, so the assembler is a stand-in
# that writes the one file the rest of the script looks for.
install -d "$TMP/bin"
cat >"$TMP/bin/mkarchiso" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
out=
while (( $# )); do
  case $1 in
    -o) out=${2:?}; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $out ]] || { echo 'stub mkarchiso: no output directory' >&2; exit 1; }
printf 'KibaOS fixture image\n' >"$out/kibaos-fixture-x86_64.iso"
STUB
chmod 0755 "$TMP/bin/mkarchiso"

build() {
  local work=$1
  PATH="$TMP/bin:$PATH" \
    KIBAOS_ARCH_SNAPSHOT=2026/07/12 \
    KIBAOS_REPO_DIR="$TMP/repo" \
    KIBAOS_ALLOW_UNSIGNED=1 \
    KIBAOS_LIVE_WL=0 \
    KIBAOS_INSTALLER_WORK_ROOT="$work" \
    "$ROOT/installer/build-iso.sh" >"$work.out" 2>&1 || {
    printf '%s\n' 'build-iso.sh failed:' >&2
    cat "$work.out" >&2
    exit 1
  }
}

fingerprint_of() {
  awk -F= '$1 == "iso_signing_fingerprint" {print $2; exit}' "$1.build-info"
}

build "$TMP/work"
iso=$TMP/work/output/kibaos-fixture-x86_64.iso
for sidecar in .sha256 .sbom.spdx.json .sbom.spdx.json.sig .sig .build-info .signing-key.gpg; do
  [[ -s $iso$sidecar ]] || { echo "missing sidecar: $sidecar" >&2; exit 1; }
done
fingerprint=$(fingerprint_of "$iso")
[[ $fingerprint =~ ^[0-9A-F]{40,64}$ ]] || {
  echo "build-info carries no usable signing fingerprint: $fingerprint" >&2
  exit 1
}
grep -qx "iso_signing_key=$(basename "$iso").signing-key.gpg" "$iso.build-info" || {
  echo 'build-info does not name the published signing key' >&2
  exit 1
}
# The private half belongs to the build that made it.
[[ ! -e $TMP/work/iso-signing-keyring && ! -e $TMP/work/iso-signing-key.params ]] || {
  echo 'the build left its private signing key behind' >&2
  exit 1
}

# The build runs the publication gate itself, and it says so.
grep -Fq 'ISO artifact verification: PASS' "$TMP/work.out" || {
  echo 'build-iso.sh did not verify its own artifacts' >&2
  exit 1
}

# A verifier with no keyring of its own still reaches a verdict.
install -d -m 0700 "$TMP/empty-gnupg"
GNUPGHOME="$TMP/empty-gnupg" "$ROOT/ci/verify-iso-artifacts.sh" "$iso" --require-signature

# Each build signs with its own key, not with one kept between builds.
build "$TMP/work-second"
second_iso=$TMP/work-second/output/kibaos-fixture-x86_64.iso
second_fingerprint=$(fingerprint_of "$second_iso")
[[ $second_fingerprint =~ ^[0-9A-F]{40,64}$ ]]
[[ $second_fingerprint != "$fingerprint" ]] || {
  echo 'two builds signed with the same key' >&2
  exit 1
}
GNUPGHOME="$TMP/empty-gnupg" "$ROOT/ci/verify-iso-artifacts.sh" "$second_iso" --require-signature

# A copy of the published artifact as a stranger would receive it. The gate
# fixtures cover what can be wrong with one of these; this covers that the
# build produced one that survives the same treatment.
copy_artifacts() {
  local dest=$1
  install -d "$dest"
  for sidecar in '' .sha256 .sig .sbom.spdx.json .sbom.spdx.json.sig .build-info .signing-key.gpg; do
    cp "$iso$sidecar" "$dest/$(basename "$iso")$sidecar"
  done
}

# A changed image no longer matches what was signed.
copy_artifacts "$TMP/changed-iso"
changed_iso=$TMP/changed-iso/$(basename "$iso")
printf '%s\n' 'changed after signing' >>"$changed_iso"
if GNUPGHOME="$TMP/empty-gnupg" "$ROOT/ci/verify-iso-artifacts.sh" "$changed_iso" \
    --require-signature >"$TMP/changed-iso.out" 2>&1; then
  echo 'a changed image unexpectedly passed verification' >&2
  exit 1
fi
grep -Fq 'ISO checksum mismatch' "$TMP/changed-iso.out"

# A changed SBOM with its digest put back must still fail on the signature.
copy_artifacts "$TMP/changed-sbom"
changed_sbom=$TMP/changed-sbom/$(basename "$iso")
printf ' ' >>"$changed_sbom.sbom.spdx.json"
sed -i "s/^sbom_sha256=.*/sbom_sha256=$(sha256sum "$changed_sbom.sbom.spdx.json" | awk '{print $1}')/" \
  "$changed_sbom.build-info"
if GNUPGHOME="$TMP/empty-gnupg" "$ROOT/ci/verify-iso-artifacts.sh" "$changed_sbom" \
    --require-signature >"$TMP/changed-sbom.out" 2>&1; then
  echo 'a changed SBOM unexpectedly passed verification' >&2
  exit 1
fi
grep -Fq 'invalid SBOM signature' "$TMP/changed-sbom.out"

echo 'ISO signing test: PASS'
