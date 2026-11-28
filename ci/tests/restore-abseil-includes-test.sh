#!/usr/bin/env bash
# ci/restore-abseil-includes.py: the include groups Lumen's source import
# dropped go back exactly where Chromium has them -- inside the branch that
# needed them, never above the code -- a file already restored is left alone,
# and a manifest that names a path outside the tree is refused.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="${repo_root}/ci/restore-abseil-includes.py"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

tree="${work}/tree"
abseil="${tree}/third_party/abseil-cpp"
manifest="${work}/manifest.txt"
out="${work}/out"

fail() {
    echo "FAIL: $*" >&2
    if [[ -f "${out}" ]]; then
        sed 's/^/    /' "${out}" >&2
    fi
    exit 1
}

mkdir -p "${abseil}/absl/base/internal" "${abseil}/absl/types"

# A source whose own header and two dependencies were stripped: the line above
# each group survives, which is what places them.
cat >"${abseil}/absl/base/internal/thread_identity.cc" <<'EOF'
// Licensed under the Apache License, Version 2.0.

#include <atomic>
#include <memory>

#if ABSL_THREAD_IDENTITY_MODE != 1
#include <pthread.h>
#endif

namespace absl {
EOF

# The same include is needed on both sides of the `#else`: one group belongs
# above it, the other below. A restore that only asked "does this file already
# include absl/meta/type_traits.h" would fill one branch and leave the other.
cat >"${abseil}/absl/types/compare.h" <<'EOF'
#ifndef ABSL_TYPES_COMPARE_H_
#define ABSL_TYPES_COMPARE_H_

#ifdef ABSL_USES_STD_ORDERING

#include <type_traits>

#else

#include <type_traits>

#endif

namespace absl {
EOF

# Already whole: Lumen restored this one itself.
cat >"${abseil}/absl/types/span.h" <<'EOF'
#ifndef ABSL_TYPES_SPAN_H_
#define ABSL_TYPES_SPAN_H_

#include "absl/base/config.h"

namespace absl {
EOF

printf '%s\t%s\t%s\t%s\n' \
    absl/base/internal/thread_identity.cc \
    '// Licensed under the Apache License, Version 2.0.' \
    '#include <atomic>' \
    'absl/base/internal/thread_identity.h' \
    absl/base/internal/thread_identity.cc \
    '#include <memory>' \
    '#if ABSL_THREAD_IDENTITY_MODE != 1' \
    'absl/base/config.h absl/base/attributes.h' \
    absl/types/compare.h \
    '#define ABSL_TYPES_COMPARE_H_' \
    '#ifdef ABSL_USES_STD_ORDERING' \
    'absl/base/config.h' \
    absl/types/compare.h \
    '#include <type_traits>' \
    '#else' \
    'absl/meta/type_traits.h' \
    absl/types/compare.h \
    '#include <type_traits>' \
    '#endif' \
    'absl/base/attributes.h absl/meta/type_traits.h' \
    absl/types/span.h \
    '#define ABSL_TYPES_SPAN_H_' \
    'namespace absl {' \
    'absl/base/config.h' \
    >"${manifest}"

cp "${abseil}/absl/base/internal/thread_identity.cc" "${work}/before.cc"

echo "==> report mode names what is missing and writes nothing"
status=0
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" >"${out}" 2>&1 ||
    status=$?
[[ ${status} -eq 1 ]] || fail "report mode exited ${status}, expected 1"
grep -q 'missing 3: absl/base/internal/thread_identity.cc' "${out}" ||
    fail "report does not count the source's three includes"
grep -q 'missing 4: absl/types/compare.h' "${out}" ||
    fail "report does not count the header's four includes"
if grep -q 'absl/types/span.h' "${out}"; then
    fail "a file that already has its includes was reported"
fi
cmp -s "${work}/before.cc" "${abseil}/absl/base/internal/thread_identity.cc" ||
    fail "report mode changed the source"

echo "==> --apply puts each group before the line below it in Chromium"
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" --apply \
    >"${out}" 2>&1 || fail "--apply failed"
cat >"${work}/expected.cc" <<'EOF'
// Licensed under the Apache License, Version 2.0.

#include "absl/base/internal/thread_identity.h"
#include <atomic>
#include <memory>

#include "absl/base/config.h"
#include "absl/base/attributes.h"
#if ABSL_THREAD_IDENTITY_MODE != 1
#include <pthread.h>
#endif

namespace absl {
EOF
diff -u "${work}/expected.cc" \
    "${abseil}/absl/base/internal/thread_identity.cc" ||
    fail "the source's includes are not where Chromium has them"

echo "==> both sides of an #else get the include they need"
grep -q 'absl/meta/type_traits.h' <<<"$(sed -n '/#ifdef ABSL_USES_STD_ORDERING/,/#else/p' \
    "${abseil}/absl/types/compare.h")" ||
    fail "the include before #else was not restored"
grep -q 'absl/meta/type_traits.h' <<<"$(sed -n '/#else/,/#endif/p' \
    "${abseil}/absl/types/compare.h")" ||
    fail "the include after #else was not restored"
sed -n '1,12p' "${abseil}/absl/types/compare.h" | grep -q 'absl/base/attributes.h' &&
    fail "an include from below #else was hoisted above it"
grep -q 'absl/base/config.h' "${abseil}/absl/types/span.h" ||
    fail "an already restored header was changed"
[[ "$(grep -c '^#include' "${abseil}/absl/types/span.h")" == 1 ]] ||
    fail "an already restored header gained an include"

echo "==> a second --apply changes nothing"
cp "${abseil}/absl/base/internal/thread_identity.cc" "${work}/first.cc"
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" --apply \
    >"${out}" 2>&1 || fail "the second --apply failed"
grep -q 'already there' "${out}" || fail "the second --apply did not report a whole tree"
cmp -s "${work}/first.cc" "${abseil}/absl/base/internal/thread_identity.cc" ||
    fail "the second --apply changed the source"

echo "==> a manifest entry whose file is gone is skipped, not fatal"
printf '%s\t%s\t%s\t%s\n' \
    absl/base/pruned.cc '#include <memory>' 'namespace absl {' 'absl/base/config.h' \
    >"${work}/gone.txt"
python3 "${tool}" --tree "${tree}" --manifest "${work}/gone.txt" --apply \
    >"${out}" 2>&1 || fail "an absent file made the restore fail"
grep -q 'every abseil include in the manifest is already there' "${out}" ||
    fail "an absent file was not reported as skipped"

echo "==> a malformed manifest is refused"
printf 'absl/types/span.h only-two-fields\n' >"${work}/bad.txt"
status=0
python3 "${tool}" --tree "${tree}" --manifest "${work}/bad.txt" >"${out}" 2>&1 ||
    status=$?
[[ ${status} -eq 2 ]] || fail "a malformed manifest exited ${status}, expected 2"

echo "==> a path outside the tree is refused"
for bad in /absolute/path ../escape; do
    printf '%s\t%s\t%s\t%s\n' "${bad}" '#include <memory>' 'namespace absl {' \
        'absl/base/config.h' >"${work}/escape.txt"
    status=0
    python3 "${tool}" --tree "${tree}" --manifest "${work}/escape.txt" \
        >"${out}" 2>&1 || status=$?
    [[ ${status} -eq 2 ]] || fail "'${bad}' exited ${status}, expected 2"
done

echo "==> all abseil include cases passed"
