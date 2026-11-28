#!/usr/bin/env bash
# ci/restore-imported-includes.py: the include blocks Lumen's source import
# dropped go back exactly where Chromium has them -- same lines, same blank
# lines, inside the branch that needed them -- for every tree a manifest
# names, the manifests are generated from two trees rather than edited by
# hand, a block between two blank lines goes to the occurrence the repair
# finds rather than the one the baseline had, a file already restored is left
# alone, a second run writes nothing, and a block with nowhere to go stops the
# run instead of being guessed at.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="${repo_root}/ci/restore-imported-includes.py"
abseil_include='^\s*#\s*include\s+"absl/'
quoted_include='^\s*#\s*include\s+"'

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

baseline="${work}/baseline"
tree="${work}/tree"
abseil="third_party/abseil-cpp"
protobuf="third_party/protobuf/src"
manifest="${work}/manifest.json"
out="${work}/out"

fail() {
    echo "FAIL: $*" >&2
    if [[ -f "${out}" ]]; then
        sed 's/^/    /' "${out}" >&2
    fi
    exit 1
}

# Write a file with its blank lines exactly as given.
write() {
    local path=$1
    shift
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' "$@" >"${path}"
}

# Every file the build compiles needs, in Chromium's copy and, after the
# import's strip, in Lumen's -- the same lines minus the quoted abseil ones.
setup_pair() {
    local root=$1
    write "${root}/${abseil}/absl/base/internal/thread_identity.cc" \
        '// Licensed under the Apache License, Version 2.0.' \
        '' \
        '#include <atomic>' \
        '#include <memory>' \
        '' \
        '#include "absl/base/attributes.h"' \
        '#include "absl/base/config.h"' \
        '#include "absl/base/internal/thread_identity.h"' \
        '' \
        '#if ABSL_THREAD_IDENTITY_MODE != 1' \
        '#include <pthread.h>' \
        '#endif' \
        '' \
        'namespace absl {'
    write "${root}/${abseil}/absl/types/compare.h" \
        '#ifndef ABSL_TYPES_COMPARE_H_' \
        '#define ABSL_TYPES_COMPARE_H_' \
        '' \
        '#ifdef ABSL_USES_STD_ORDERING' \
        '' \
        '#include <type_traits>' \
        '' \
        '#include "absl/base/config.h"' \
        '' \
        '#else' \
        '' \
        '#include <type_traits>' \
        '' \
        '#include "absl/base/attributes.h"' \
        '#include "absl/meta/type_traits.h"' \
        '' \
        '#endif' \
        '' \
        'namespace absl {'
    write "${root}/${abseil}/absl/types/span.h" \
        '#ifndef ABSL_TYPES_SPAN_H_' \
        '#define ABSL_TYPES_SPAN_H_' \
        '' \
        '#include "absl/base/config.h"' \
        '' \
        'namespace absl {'
}

mkdir -p "${baseline}" "${tree}"
setup_pair "${baseline}"
setup_pair "${tree}"
# What the import did: drop every quoted abseil include, keep everything else
# where it was, blank lines included.
while IFS= read -r -d '' file; do
    rel="${file#"${tree}/"}"
    grep -v '^#include "absl/' "${baseline}/${rel}" >"${tree}/${rel}" || true
done < <(find "${tree}/${abseil}" -type f \( -name '*.h' -o -name '*.cc' \) \
    -print0)
# Lumen has restored this one itself, which is what the import's own fixes
# look like and what the repair must leave alone.
cp "${baseline}/${abseil}/absl/types/span.h" \
    "${tree}/${abseil}/absl/types/span.h"

echo "==> --generate records the dropped blocks, deterministically"
python3 "${tool}" --generate --baseline "${baseline}" --tree "${tree}" \
    --dir "${abseil}" --include-pattern "${abseil_include}" \
    --manifest "${manifest}" >"${out}" 2>&1 ||
    fail "--generate failed"
grep -q 'wrote 3 block(s) in 2 file(s)' "${out}" ||
    fail "the two stripped files did not produce three blocks"
python3 "${tool}" --generate --baseline "${baseline}" --tree "${tree}" \
    --dir "${abseil}" --include-pattern "${abseil_include}" \
    --manifest "${work}/again.json" >"${out}" 2>&1 ||
    fail "the second --generate failed"
cmp -s "${manifest}" "${work}/again.json" ||
    fail "the generated manifest is not deterministic"
# parse: only the two stripped files, and span.h (restored by Lumen already)
# is not in it.
if ! python3 - "${manifest}" "${abseil}" "${abseil_include}" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["directory"] == sys.argv[2], data["directory"]
assert data["include"] == sys.argv[3], data["include"]
assert set(data["files"]) == {"absl/base/internal/thread_identity.cc",
                              "absl/types/compare.h"}, sorted(data["files"])
EOF
then
    fail "the manifest does not describe its own repair"
fi

echo "==> report mode names what is missing and writes nothing"
cp "${tree}/${abseil}/absl/types/compare.h" "${work}/before.h"
status=0
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" >"${out}" 2>&1 ||
    status=$?
[[ ${status} -eq 1 ]] || fail "report mode exited ${status}, expected 1"
grep -q "${abseil}: missing 3: absl/base/internal/thread_identity.cc" "${out}" ||
    fail "report does not name the tree and count the source's three includes"
grep -q "${abseil}: missing 3: absl/types/compare.h" "${out}" ||
    fail "report does not count the header's three includes"
if grep -q 'absl/types/span.h' "${out}"; then
    fail "a file that already has its includes was reported"
fi
cmp -s "${work}/before.h" "${tree}/${abseil}/absl/types/compare.h" ||
    fail "report mode changed the header"

echo "==> --apply reproduces Chromium's copy exactly, blank lines included"
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" --apply \
    >"${out}" 2>&1 || fail "--apply failed"
grep -q 'restored 6 include line(s) in 2 file(s)' "${out}" ||
    fail "the repair does not report six lines in two files"
diff -r "${baseline}/${abseil}" "${tree}/${abseil}" ||
    fail "the repaired tree is not Chromium's copy"

echo "==> both sides of an #else get the include they need"
sed -n '/#ifdef ABSL_USES_STD_ORDERING/,/#else/p' \
    "${tree}/${abseil}/absl/types/compare.h" |
    grep -q 'absl/base/config.h' ||
    fail "the include before #else was not restored"
sed -n '/#else/,/#endif/p' "${tree}/${abseil}/absl/types/compare.h" |
    grep -q 'absl/meta/type_traits.h' ||
    fail "the include after #else was not restored"

echo "==> a second --apply changes nothing"
cp "${tree}/${abseil}/absl/types/compare.h" "${work}/first.h"
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" --apply \
    >"${out}" 2>&1 || fail "the second --apply failed"
grep -q 'already there' "${out}" ||
    fail "the second --apply did not report a whole tree"
cmp -s "${work}/first.h" "${tree}/${abseil}/absl/types/compare.h" ||
    fail "the second --apply changed the header"

echo "==> every manifest's tree is repaired in the same run"
write "${baseline}/${protobuf}/google/protobuf/any_lite.cc" \
    '// Protocol Buffers' \
    '' \
    '#include <string>' \
    '' \
    '#include "absl/strings/string_view.h"' \
    '#include "google/protobuf/any.h"' \
    '#include "google/protobuf/message_lite.h"' \
    '' \
    'namespace google {'
write "${tree}/${protobuf}/google/protobuf/any_lite.cc" \
    '// Protocol Buffers' \
    '' \
    '#include <string>' \
    '' \
    '' \
    'namespace google {'
python3 "${tool}" --generate --baseline "${baseline}" --tree "${tree}" \
    --dir "${protobuf}" --include-pattern "${quoted_include}" \
    --manifest "${work}/protobuf.json" >"${out}" 2>&1 ||
    fail "--generate failed for the second tree"
python3 "${tool}" --tree "${tree}" --manifest "${manifest}" \
    --manifest "${work}/protobuf.json" --apply >"${out}" 2>&1 ||
    fail "the two-manifest --apply failed"
grep -q "${protobuf}: missing 3: google/protobuf/any_lite.cc" "${out}" ||
    fail "the second tree's includes were not reported"
diff -r "${baseline}/${protobuf}" "${tree}/${protobuf}" ||
    fail "the second tree was not put back"

echo "==> a block between two blank lines goes to the occurrence the repair sees"
write "${baseline}/${abseil}/absl/base/blank_anchor.h" \
    '#include "absl/one.h"' \
    '' \
    '#include "absl/two.h"' \
    '' \
    '#include "absl/three.h"' \
    '' \
    '' \
    '' \
    '// Must be included last.' \
    '#include "absl/port.h"' \
    '' \
    'namespace absl {'
write "${tree}/${abseil}/absl/base/blank_anchor.h" \
    '' \
    '' \
    '' \
    '' \
    '' \
    '// Must be included last.' \
    '' \
    'namespace absl {'
python3 "${tool}" --generate --baseline "${baseline}" --tree "${tree}" \
    --dir "${abseil}" --include-pattern "${abseil_include}" \
    --manifest "${work}/blank.json" >"${out}" 2>&1 ||
    fail "--generate failed on the blank anchor"
python3 "${tool}" --tree "${tree}" --manifest "${work}/blank.json" --apply \
    >"${out}" 2>&1 || fail "the blank anchor repair failed"
diff "${baseline}/${abseil}/absl/base/blank_anchor.h" \
    "${tree}/${abseil}/absl/base/blank_anchor.h" ||
    fail "the block landed at the wrong blank line pair"

echo "==> the line above still places a block whose pair is gone"
write "${tree}/${abseil}/absl/base/fallback.h" \
    '#ifndef ABSL_BASE_FALLBACK_H_' \
    '#define ABSL_BASE_FALLBACK_H_' \
    '' \
    '#include <stddef.h>' \
    '' \
    '#endif'
cat >"${work}/fallback.json" <<EOF
{
  "directory": "${abseil}",
  "include": "^\\\\s*#\\\\s*include\\\\s+\"absl/",
  "files": {
    "absl/base/fallback.h": [
      {"after": "#include <stddef.h>\\n", "before": "#include <vector>\\n", "n": 1,
       "add": ["#include \"absl/base/config.h\"\\n"]}
    ]
  }
}
EOF
python3 "${tool}" --tree "${tree}" --manifest "${work}/fallback.json" \
    --apply >"${out}" 2>&1 || fail "the fallback placement failed"
sed -n '4,6p' "${tree}/${abseil}/absl/base/fallback.h" |
    grep -qx '#include "absl/base/config.h"' ||
    fail "the block was not placed after the line above it"

echo "==> a block with nowhere to go fails instead of being guessed at"
write "${tree}/${abseil}/absl/base/lost.h" \
    '#ifndef ABSL_BASE_LOST_H_' \
    '#define ABSL_BASE_LOST_H_' \
    '' \
    '#endif'
cp "${tree}/${abseil}/absl/base/lost.h" "${work}/lost.h"
cat >"${work}/lost.json" <<EOF
{
  "directory": "${abseil}",
  "include": "^\\\\s*#\\\\s*include\\\\s+\"absl/",
  "files": {
    "absl/base/lost.h": [
      {"after": "#include <stddef.h>\\n", "before": "#endif\\n", "n": 1,
       "add": ["#include \"absl/base/config.h\"\\n"]}
    ]
  }
}
EOF
status=0
python3 "${tool}" --tree "${tree}" --manifest "${work}/lost.json" --apply \
    >"${out}" 2>&1 || status=$?
[[ ${status} -eq 1 ]] || fail "an unplaceable block exited ${status}, expected 1"
grep -q 'cannot place' "${out}" || fail "an unplaceable block was not named"
cmp -s "${work}/lost.h" "${tree}/${abseil}/absl/base/lost.h" ||
    fail "an unplaceable block still changed the header"

echo "==> a file the import also took other lines from keeps only its includes"
mkdir -p "${work}/mixed/base/${abseil}/absl/base/internal" \
    "${work}/mixed/tree/${abseil}/absl/base/internal"
write "${work}/mixed/base/${abseil}/absl/base/internal/cycleclock.cc" \
    '// Licensed under the Apache License, Version 2.0.' \
    '' \
    '#include <sys/types.h>' \
    '#include "absl/base/config.h"' \
    '#include "absl/base/internal/cycleclock.h"' \
    '' \
    'namespace absl {'
write "${work}/mixed/tree/${abseil}/absl/base/internal/cycleclock.cc" \
    '// Licensed under the Apache License, Version 2.0.' \
    '' \
    '#include "absl/base/internal/cycleclock.h"' \
    '' \
    'namespace absl {'
python3 "${tool}" --generate --baseline "${work}/mixed/base" \
    --tree "${work}/mixed/tree" --dir "${abseil}" \
    --include-pattern "${abseil_include}" \
    --manifest "${work}/mixed.json" >"${out}" 2>&1 ||
    fail "--generate failed on the mixed file"
python3 "${tool}" --tree "${work}/mixed/tree" --manifest "${work}/mixed.json" \
    --apply >"${out}" 2>&1 || fail "the mixed file was not repaired"
grep -qx '#include "absl/base/config.h"' \
    "${work}/mixed/tree/${abseil}/absl/base/internal/cycleclock.cc" ||
    fail "the include the import dropped was not restored"
if grep -q 'sys/types.h' \
    "${work}/mixed/tree/${abseil}/absl/base/internal/cycleclock.cc"; then
    fail "a line the import took that is not an abseil include was added"
fi

echo "==> a manifest entry whose file is gone is skipped, not fatal"
python3 - "${manifest}" "${work}/gone.json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["files"] = {"absl/base/pruned.h": data["files"].popitem()[1]}
json.dump(data, open(sys.argv[2], "w"))
EOF
python3 "${tool}" --tree "${tree}" --manifest "${work}/gone.json" --apply \
    >"${out}" 2>&1 || fail "an absent file made the restore fail"
grep -q '1 not in this tree' "${out}" ||
    fail "an absent file was not reported as skipped"

echo "==> a malformed manifest is refused"
printf '{"files": {"absl/types/span.h": [{"after": 1}]}}\n' >"${work}/bad.json"
status=0
python3 "${tool}" --tree "${tree}" --manifest "${work}/bad.json" \
    >"${out}" 2>&1 || status=$?
[[ ${status} -eq 2 ]] || fail "a malformed manifest exited ${status}, expected 2"

echo "==> a directory or path outside the tree is refused"
for bad in /absolute/path ../escape; do
    printf '{"directory": "%s", "include": "x", "files": {}}\n' "${bad}" \
        >"${work}/escape.json"
    status=0
    python3 "${tool}" --tree "${tree}" --manifest "${work}/escape.json" \
        >"${out}" 2>&1 || status=$?
    [[ ${status} -eq 2 ]] || fail "directory '${bad}' exited ${status}, expected 2"
    printf '{"directory": "%s", "include": "x", "files": {"%s": []}}\n' \
        "${abseil}" "${bad}" >"${work}/escape.json"
    status=0
    python3 "${tool}" --tree "${tree}" --manifest "${work}/escape.json" \
        >"${out}" 2>&1 || status=$?
    [[ ${status} -eq 2 ]] || fail "file '${bad}' exited ${status}, expected 2"
done

echo "==> all imported include cases passed"
