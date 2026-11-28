#!/usr/bin/env python3
"""Put back the abseil includes Lumen's source import removed.

`third_party/abseil-cpp` in the Lumen tree is not the copy Chromium builds.
The import behind the tree ("Source batch 1/3", 2026-11-25) dropped every
`#include "absl/..."` line from the vendored abseil sources. The files are
still there and still hold their licence, their system includes and their
code; they no longer include the abseil headers they use. Abseil's headers
are not self-contained by accident, so the first translation unit that
reaches a stripped one fails on `ABSL_NAMESPACE_BEGIN`, `ABSL_HAVE_ATTRIBUTE`
and `absl::call_once` at once, with the compiler pointing at a file that
looks perfectly intact:

  ../../third_party/abseil-cpp/absl/base/internal/thread_identity.cc:31:1:
  error: unknown type name 'ABSL_NAMESPACE_BEGIN'

Lumen is restoring those lines a dependency closure at a time (absl's
spinlock includes were one such commit), which is why the failure moves from
header to header as a build gets further: cycleclock, then spinlock, then
thread_identity, sysinfo and cpu_detect.

ci/abseil-includes.txt names every group of abseil includes Chromium has and
the tree does not, with the two context lines the group sits between there.
Adding them back is not the same as replacing the files -- the tree's abseil
is a different revision from any Chromium release, so a wholesale restore
would move code as well -- and it is not a patch series hunk either, because
Lumen is still restoring some of these lines itself and a hunk would collide
with it. A line is only added when it is absent, so this is safe to run on
every build: a file Lumen has already restored is left exactly as it is, and
a group whose file is gone is reported and skipped.

Each group goes back where it was, not to the top of the file. Placement is
not cosmetic: `absl/numeric/int128.h` includes `int128_have_intrinsic.inc`
inside the `#if` that decides the class's representation, and that `.inc`
supplies the class body; a copy at the top of the header would define the
name before the namespace exists. The header also tests the same macro at a
dozen earlier points, so the line above a group does not identify it -- the
line below does, together with the one above: the group goes before the
first line at or after the previous group whose following line matches and
whose nearest non-blank line above matches too, which is how two groups
around the same `#else` keep their order.

Only the quoted abseil includes are restored; the tests' gtest/gmock
includes went the same way, and nothing the build compiles needs them. The
`// IWYU pragma: export` comment some of those lines carried is not
reproduced: it is advice for a tool that is not in this build.

Report unless --apply is given, like ci/restore-truncated-sources.py: the
build tree is expensive to recreate, so the list comes first.
"""
import argparse
import os
import re
import sys

PREFIX = "==> abseil-includes: "
ABSEIL_DIR = "third_party/abseil-cpp"
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"')


def read_manifest(path):
    """(file, before, after, [include, ...]) groups, in the order they apply."""
    groups = []
    with open(path, encoding="utf-8") as fh:
        for number, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise ValueError("%s:%d: expected FILE<TAB>BEFORE<TAB>AFTER"
                                 "<TAB>INCLUDES" % (path, number))
            name, before, after, includes = parts
            groups.append((name.strip(), before.rstrip(), after.rstrip(),
                           includes.split()))
    return groups


def current_includes(lines):
    found = set()
    for line in lines:
        match = INCLUDE.match(line)
        if match:
            found.add(match.group(1))
    return found


def after_leading_comment(lines):
    """The index just past the licence block a file opens with."""
    number = 0
    while number < len(lines):
        text = lines[number].strip()
        if text and not text.startswith(("//", "/*", "*")) and \
                not text.endswith("*/"):
            break
        number += 1
    return number


def find_window(lines, before, after, start):
    """The lines a group belongs between, as (first, end), or None.

    The group sat between `before` and `after` in Chromium's copy. When
    `after` survives, the window opens after the nearest non-blank line above
    it that matches `before`, which is what tells two blocks around the same
    `#else` apart. When the whole include region was stripped there is no
    `after` left -- the next line after the group is a group member too -- so
    the window runs from `before` (or the start of the file) to the end.

    A window is what makes the two branches of one header work: compare.h
    includes `absl/meta/type_traits.h` on both sides of its `#else`, and a
    restore that asked "does this file already include it" would fill one
    branch and leave the other empty.
    """
    if after:
        for number in range(start, len(lines)):
            if lines[number].rstrip() != after:
                continue
            if not before:
                return start, number
            above = number - 1
            while above >= 0 and not lines[above].strip():
                above -= 1
            if above >= 0 and lines[above].rstrip() == before:
                return above + 1, number
        return None
    if before:
        for number in range(start, len(lines)):
            if lines[number].rstrip() == before:
                return number + 1, len(lines)
        return None
    return start, len(lines)


def restore(lines, groups):
    """Insert each group's missing includes into `lines`; (inserted, unplaced).

    The same work runs for the report and for --apply, so what is counted is
    exactly what is written -- two groups around one `#else` are two lines
    added, not one deduped include.
    """
    inserted = []
    unplaced = []
    cursor = 0
    for before, after, includes in groups:
        window = find_window(lines, before, after, cursor)
        if window is None:
            if not cursor:
                # Nothing placed yet, so an unmatched context would put the
                # group below the code that needs it. Say so; after a group
                # has been placed the fallback is the line right below it,
                # which is where a second group belongs anyway.
                unplaced.append(after or before)
            index = cursor or after_leading_comment(lines)
            present = current_includes(lines)
        else:
            index, end = window
            present = current_includes(lines[index:end])
            if not present and all(not line.strip()
                                   for line in lines[index:end]):
                # An empty window of blank lines is the gap between the
                # include blocks; fill it from below, so the group keeps the
                # blank line Chromium has above it.
                index = end
        missing = [include for include in includes
                   if include not in present]
        if not missing:
            continue
        lines[index:index] = ['#include "%s"\n' % include
                              for include in missing]
        cursor = index + len(missing)
        inserted.extend(missing)
    return inserted, unplaced


def main():
    ap = argparse.ArgumentParser(
        description="Put back the abseil includes the Lumen source import "
                    "removed, as named by ci/abseil-includes.txt")
    ap.add_argument("--tree", default=".",
                    help="Chromium/Lumen source root (default: .)")
    ap.add_argument("--abseil", default=ABSEIL_DIR,
                    help="abseil directory inside the tree (default: %s)"
                         % ABSEIL_DIR)
    ap.add_argument("--manifest",
                    help="include manifest (default: beside this script)")
    ap.add_argument("--apply", action="store_true",
                    help="write the includes instead of only listing them")
    args = ap.parse_args()

    manifest = args.manifest
    if not manifest:
        manifest = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "abseil-includes.txt")
    tree = os.path.abspath(args.tree)
    if not os.path.isdir(tree):
        print("error: no such tree: %s" % tree, file=sys.stderr)
        return 2
    try:
        groups = read_manifest(manifest)
    except (OSError, ValueError) as error:
        print("error: cannot read %s: %s" % (manifest, error), file=sys.stderr)
        return 2

    by_file = {}
    absent = 0
    for name, before, after, includes in groups:
        if os.path.isabs(name) or ".." in name.split("/"):
            print("error: manifest names a path outside the tree: %s" % name,
                  file=sys.stderr)
            return 2
        if not os.path.isfile(os.path.join(tree, args.abseil, name)):
            absent += 1
            continue
        by_file.setdefault(name, []).append((before, after, includes))

    pending = []
    for name in sorted(by_file):
        full = os.path.join(tree, args.abseil, name)
        with open(full, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
        inserted, unplaced = restore(list(lines), by_file[name])
        if inserted:
            pending.append((name, lines, inserted, unplaced))

    restored = sum(len(inserted) for _, _, inserted, _ in pending)
    if not pending:
        print(PREFIX + "every abseil include in the manifest is already "
                       "there (%d file(s) listed, %d group(s) not in this tree)"
              % (len(by_file), absent))
        return 0
    for name, _, inserted, _ in pending:
        print(PREFIX + "missing %d: %s" % (len(inserted), name))
        for include in inserted:
            print(PREFIX + '  #include "%s"' % include)
    if not args.apply:
        print(PREFIX + "%d include line(s) missing from %d file(s); rerun "
                       "with --apply to restore them" % (restored, len(pending)))
        return 1

    failed = 0
    unplaced = []
    for name, lines, _, file_unplaced in pending:
        restore(lines, by_file[name])
        unplaced.extend("%s (%s)" % (name, line) for line in file_unplaced)
        try:
            with open(os.path.join(tree, args.abseil, name), "w",
                      encoding="utf-8") as fh:
                fh.writelines(lines)
        except OSError as error:
            failed += 1
            print("error: could not write %s: %s" % (name, error),
                  file=sys.stderr)
    for line in unplaced:
        print(PREFIX + "no context line in this tree; group placed after the "
                       "leading comment: %s" % line)
    if failed:
        print(PREFIX + "%d file(s) could not be written" % failed,
              file=sys.stderr)
        return 1
    print(PREFIX + "restored %d include line(s) in %d file(s)%s"
          % (restored, len(pending),
             "; %d manifest group(s) are not in this tree" % absent
             if absent else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
