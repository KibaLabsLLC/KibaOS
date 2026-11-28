#!/usr/bin/env bash
# ci/restore-truncated-sources.py --restore-dir: one named directory comes
# back whole (emptied and deleted files), the series' hunks under it stay
# applied, and files outside it are left alone.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="${repo_root}/ci/restore-truncated-sources.py"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

tree="${work}/tree"
patches="${work}/patches"
empty_patches="${work}/no-patches"
out="${work}/out"
dir="third_party/abseil-cpp"

fail() {
    echo "FAIL: $*" >&2
    if [[ -f "${out}" ]]; then
        sed 's/^/    /' "${out}" >&2
    fi
    exit 1
}

rm -rf "${tree}"
mkdir -p "${tree}/${dir}/absl/base" "${tree}/other" "${patches}" "${empty_patches}"

git -C "${tree}" init -q
git -C "${tree}" config user.email test@example.invalid
git -C "${tree}" config user.name test
git -C "${tree}" config commit.gpgsign false

cat >"${tree}/${dir}/BUILD.gn" <<'EOF'
visibility = [ "//third_party/abseil-cpp/*" ]
EOF
cat >"${tree}/${dir}/absl/base/config.h" <<'EOF'
#ifndef ABSL_BASE_CONFIG_H_
#define ABSL_BASE_CONFIG_H_
#define ABSL_NAMESPACE_BEGIN namespace absl {
#endif
EOF
cat >"${tree}/${dir}/absl/base/attributes.h" <<'EOF'
#define ABSL_HAVE_ATTRIBUTE(x) 1
EOF
printf 'base\n' >"${tree}/other/file.txt"
git -C "${tree}" add -A
git -C "${tree}" commit -qm base

# The series edits one file under the directory and one outside it, so the
# fixture also shows that only the directory's hunks come back.
sed -i 's|^visibility = .*|visibility = [ "//*" ]|' "${tree}/${dir}/BUILD.gn"
printf 'series\n' >>"${tree}/other/file.txt"
git -C "${tree}" diff >"${patches}/0001-series.patch"
git -C "${tree}" checkout -q -- .
printf '0001-series.patch\n' >"${patches}/SERIES"
git -C "${tree}" apply "${patches}/0001-series.patch"

echo "==> report mode names emptied and deleted files without changing them"
: >"${tree}/${dir}/absl/base/config.h"
rm -f "${tree}/${dir}/absl/base/attributes.h"
printf 'edited\n' >"${tree}/other/file.txt"

status=0
python3 "${tool}" --tree "${tree}" --patches "${patches}" \
    --restore-dir "${dir}" >"${out}" 2>&1 || status=$?
[[ ${status} -eq 1 ]] || fail "report mode exited ${status}, expected 1"
grep -q "would restore: .*config.h (empty)" "${out}" ||
    fail "report does not name the emptied header"
grep -q "would restore: .*attributes.h (missing)" "${out}" ||
    fail "report does not name the deleted header"
[[ ! -s "${tree}/${dir}/absl/base/config.h" ]] ||
    fail "report mode changed the emptied header"
[[ ! -e "${tree}/${dir}/absl/base/attributes.h" ]] ||
    fail "report mode brought the deleted header back"

echo "==> --apply restores both and keeps the series' hunks under the directory"
printf 'junk\n' >"${tree}/${dir}/absl/intruder.h"
python3 "${tool}" --tree "${tree}" --patches "${patches}" \
    --restore-dir "${dir}" --apply >"${out}" 2>&1 ||
    fail "--apply failed"
grep -q 'define ABSL_NAMESPACE_BEGIN' "${tree}/${dir}/absl/base/config.h" ||
    fail "the emptied header did not come back"
[[ -s "${tree}/${dir}/absl/base/attributes.h" ]] ||
    fail "the deleted header did not come back"
grep -q 'visibility = \[ "//\*" \]' "${tree}/${dir}/BUILD.gn" ||
    fail "the series' hunk under the directory was not re-applied"
grep -qx 'edited' "${tree}/other/file.txt" ||
    fail "a file outside the directory was touched"

echo "==> untracked files under the directory are left alone"
[[ -s "${tree}/${dir}/absl/intruder.h" ]] ||
    fail "an untracked file under the directory was removed"

echo "==> the directory ends as HEAD plus exactly the series' files"
git -C "${tree}" status --porcelain --untracked-files=all -- "${dir}" \
    >"${work}/status"
printf ' M %s/BUILD.gn\n?? %s/absl/intruder.h\n' "${dir}" "${dir}" \
    >"${work}/expected"
diff -u "${work}/expected" "${work}/status" ||
    fail "unexpected files differ under the directory"

echo "==> a second --apply is idempotent"
python3 "${tool}" --tree "${tree}" --patches "${patches}" \
    --restore-dir "${dir}" --apply >"${out}" 2>&1 ||
    fail "the second --apply failed"
[[ -s "${tree}/${dir}/absl/base/attributes.h" ]] ||
    fail "the second --apply lost the restored header"
grep -q 'visibility = \[ "//\*" \]' "${tree}/${dir}/BUILD.gn" ||
    fail "the second --apply lost the series' hunk"

echo "==> a directory that is not in HEAD is a no-op"
python3 "${tool}" --tree "${tree}" --patches "${patches}" \
    --restore-dir no/such/dir >"${out}" 2>&1 ||
    fail "an absent directory was not a no-op"
grep -q 'is not in HEAD' "${out}" || fail "absent directory was not reported"

echo "==> without a series it refuses instead of reverting the series' hunks"
status=0
python3 "${tool}" --tree "${tree}" --patches "${empty_patches}" \
    --restore-dir "${dir}" --apply >"${out}" 2>&1 || status=$?
[[ ${status} -eq 2 ]] || fail "missing series exited ${status}, expected 2"
grep -q 'no patch series found' "${out}" ||
    fail "missing series was not reported"
grep -q 'visibility = \[ "//\*" \]' "${tree}/${dir}/BUILD.gn" ||
    fail "a refused run still reverted the series' hunk"

echo "==> a path outside the tree is refused"
for bad in /absolute/path ../escape; do
    status=0
    python3 "${tool}" --tree "${tree}" --patches "${patches}" \
        --restore-dir "${bad}" >"${out}" 2>&1 || status=$?
    [[ ${status} -eq 2 ]] || fail "'${bad}' exited ${status}, expected 2"
done

echo "==> all restore-dir cases passed"
