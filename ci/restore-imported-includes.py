#!/usr/bin/env python3
"""Put back the includes Lumen's source import removed.

`third_party/abseil-cpp` in the Lumen tree is not the copy Chromium builds.
The import behind the tree ("Source batch 1/3", 2026-11-25) dropped every
`#include "absl/..."` line from the vendored abseil sources. The files are
still there and still hold their licence, their system includes, their blank
lines and their code; they no longer include the abseil headers they use.
Abseil's headers are not self-contained by accident, so the first translation
unit that reaches a stripped one fails on `ABSL_NAMESPACE_BEGIN`,
`ABSL_HAVE_ATTRIBUTE` and `absl::call_once` at once, with the compiler
pointing at a file that looks perfectly intact:

  ../../third_party/abseil-cpp/absl/base/internal/thread_identity.cc:31:1:
  error: unknown type name 'ABSL_NAMESPACE_BEGIN'

Lumen is restoring those lines a dependency closure at a time (absl's
spinlock includes were one such commit), which is why the failure moves from
header to header as a build gets further: cycleclock, then spinlock, then
thread_identity, sysinfo and cpu_detect.

"Source batch 2/3" did the same to `third_party/protobuf`: every quoted
include line is gone, the rest of each file is where it was. That strips
both the protobuf headers a file needs and the absl ones underneath them, so
the first protobuf TU fails on its own types:

  ../../third_party/protobuf/src/google/protobuf/any_lite.cc:25:24:
  error: use of undeclared identifier 'absl'

Each manifest names one directory of the tree, the include lines that
directory lost, and every block with the two lines it sat between. One run
restores them all. Restoring a block where it was is what makes the result
exact, and being exact is the point:

  * `absl/numeric/int128.h` includes `int128_have_intrinsic.inc` inside the
    `#if` that decides the class's representation, and that `.inc` supplies
    the class body. A block put at the top of the header defines the name
    before the namespace exists.
  * The blank lines around an include block are part of it. A block inserted
    one line off still compiles, and leaves every later build comparing a
    tree that no longer matches Chromium's copy for no reason at all.

Because the import removed whole blocks between two surviving lines, a block
can go back with no judgement at all: `--generate` records the line above it,
the line below it, and which occurrence of that pair the block belongs to,
and the restore looks for exactly that pair. The occurrence is counted in the
tree as the repair finds it, not in the baseline: taking an include out from
between two blank lines leaves those blank lines adjacent, so the pair the
block sits between can occur more often in the damaged file than in the copy
it came from, and counting in the baseline would send the block to the wrong
one. Nothing is inferred from the text of the includes, so a file Lumen has
already restored itself is left as it is, and a second run has nothing to do.

When the pair is gone -- Lumen restored part of the block, or edited around
it -- the tool takes the first rule that applies, in this fixed order:

  1. Every line of the block is already in the file, in order: nothing to do.
     This is what a repaired file looks like, so a second run writes nothing.
  2. The pair is there: the block goes between it, exactly as recorded.
  3. The pair's last occurrence after the previous block: the missing lines
     go there.
  4. The block opened the file: it goes at the top.
  5. The line above the block is there: the missing lines go right after it.
  6. There is no such rule: the block is named and the run fails.

That order is the whole "choice system": the same tree always produces the
same tree, nothing is skipped silently, and a block that cannot be placed
stops the build with its name instead of leaving a header that compiles
wrong. Applying is verified rather than assumed: each written file is read
back, the restore is run over it again and must find nothing, and every
include the manifest names for it must be present.

`--generate` rebuilds one manifest from two trees, deterministically, so it
is never hand-edited: pass Chromium's copy of the directory as the baseline
and Lumen's as the tree. Only the include lines the manifest's pattern names
are recorded, which is what keeps the revision Lumen carries (Chromium's
copy minus these blocks, plus a few unrelated deltas) out of the repair:
anything else the import took with them is a difference between the two
trees, not damage, and stays gone.

Report unless --apply is given, like ci/restore-truncated-sources.py: the
build tree is expensive to recreate, so the list comes first.
"""
import argparse
import difflib
import json
import os
import re
import subprocess
import sys

PREFIX = "==> imported-includes: "
MANIFEST_SUFFIX = "-includes.json"


def default_manifests():
    """Every manifest beside this script, in a stable order."""
    here = os.path.dirname(os.path.abspath(__file__))
    names = sorted(name for name in os.listdir(here)
                   if name.endswith(MANIFEST_SUFFIX))
    return [os.path.join(here, name) for name in names]


def read_lines(path):
    """The file's lines with their own line endings, so a rewrite is exact."""
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.readlines()


def load_manifest(path):
    """The manifest's directory, include pattern and blocks, validated."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("%s is not an object" % path)
    directory = data.get("directory")
    if not isinstance(directory, str) or not directory:
        raise ValueError("%s has no \"directory\"" % path)
    if os.path.isabs(directory) or ".." in directory.split("/"):
        raise ValueError("%s names a directory outside the tree: %s"
                         % (path, directory))
    pattern = data.get("include")
    if not isinstance(pattern, str) or not pattern:
        raise ValueError("%s has no \"include\" pattern" % path)
    try:
        re.compile(pattern)
    except re.error as error:
        raise ValueError("%s has an unusable include pattern: %s"
                         % (path, error))
    files = data.get("files")
    if not isinstance(files, dict):
        raise ValueError("%s has no \"files\" object" % path)
    for name, hunks in files.items():
        if not isinstance(hunks, list):
            raise ValueError("%s: %s is not a list" % (path, name))
        for hunk in hunks:
            if set(hunk) != {"after", "before", "n", "add"}:
                raise ValueError("%s: %s has a block without after, before, "
                                 "n and add" % (path, name))
            if not isinstance(hunk["n"], int) or hunk["n"] < 1:
                raise ValueError("%s: %s has a block with a bad n"
                                 % (path, name))
            if not isinstance(hunk["add"], list) or not hunk["add"]:
                raise ValueError("%s: %s has a block with no lines"
                                 % (path, name))
    return {
        "baseline": data.get("baseline", ""),
        "directory": directory,
        "include": pattern,
        "files": files,
    }


def occurrences(lines, after, before):
    """Indexes of the lines `after` that are followed by `before`.

    An empty `after` is the top of the file, before anything can follow it.
    An empty `before` is the end of the file, so only the last line can be the
    one above a block that closes the file.
    """
    if after == "":
        return [-1]
    found = []
    for index, line in enumerate(lines):
        if line != after:
            continue
        if before == "":
            if index == len(lines) - 1:
                found.append(index)
        elif index + 1 < len(lines) and lines[index + 1] == before:
            found.append(index)
    return found


def present_in_order(lines, wanted, start):
    """True when every line of `wanted` is at or after `start`, in order."""
    position = start
    for line in wanted:
        while position < len(lines) and lines[position] != line:
            position += 1
        if position >= len(lines):
            return False
        position += 1
    return True


def place(lines, hunks, start=0):
    """Insert each block's lines into `lines`; (inserted, unresolved).

    The rules are the ordered list in the module docstring, applied per block
    in the order the manifest records them. The same work runs for the report
    and for --apply, so what is counted is exactly what is written.
    """
    inserted = []
    unresolved = []
    cursor = start
    for hunk in hunks:
        after = hunk["after"]
        before = hunk["before"]
        add = hunk["add"]
        # 1: everything the block holds is already in the file, in order. A
        # repair leaves the file in this state, and an include that a header
        # already carries from another branch counts too: the preprocessor
        # reads a file's includes once, so a second copy changes nothing.
        if present_in_order(lines, add, cursor):
            continue
        spots = occurrences(lines, after, before)
        missing = None
        spot = None
        # 2: the occurrence of the pair the manifest records. It is counted in
        # the file as the block finds it, with the blocks before it already
        # back, so it is an index into the whole file and not into what is
        # left after the cursor.
        if len(spots) >= hunk["n"]:
            spot = spots[hunk["n"] - 1]
            if lines[spot + 1:spot + 1 + len(add)] == add:
                continue
        else:
            later = [spot for spot in spots if spot >= cursor - 1]
            # 3: that pair's last occurrence after the previous block.
            if later:
                spot = later[-1]
                missing = [line for line in add if line not in lines]
            # 4: the top of the file, which is always there.
            elif after == "":
                spot = -1
                missing = [line for line in add if line not in lines]
            else:
                # 5: the line above the block, wherever it still is.
                for index, line in enumerate(lines):
                    if index >= cursor and line == after:
                        spot = index
                        break
                if spot is None:
                    unresolved.append(describe(hunk))
                    continue
                missing = [line for line in add if line not in lines]
        if missing is None:
            missing = add
        if not missing:
            continue
        lines[spot + 1:spot + 1] = missing
        cursor = spot + len(missing)
        inserted.extend(missing)
    return inserted, unresolved


def describe(hunk):
    first = hunk["add"][0].strip()
    return "%s (after %r)" % (first, hunk["after"].strip()[:60])


def include_matcher(manifest):
    return re.compile(manifest["include"])


def includes_in(lines, include):
    return {line.strip() for line in lines if include.match(line)}


def expected_includes(hunks, include):
    return {line.strip() for hunk in hunks for line in hunk["add"]
            if include.match(line)}


def baseline_note(baseline_dir, ref, directory):
    """What the blocks were recorded against, without this machine's paths."""
    if ref:
        return ref
    proc = subprocess.run(["git", "-C", baseline_dir, "rev-parse", "HEAD"],
                          capture_output=True)
    if proc.returncode == 0:
        return "%s at %s" % (directory,
                             proc.stdout.decode("utf-8").strip()[:12])
    return "%s from an unversioned baseline" % directory


def generate(baseline_dir, tree_dir, directory, include, ref=""):
    """The manifest for `tree_dir` as a damaged copy of `baseline_dir`.

    Every run of lines the tree lost that held an include the pattern names
    becomes one block, anchored by the unchanged lines on either side of the
    run, so the block goes back where the run was. A run that also lost
    something else records only its includes: the rest is a difference
    between the two trees (a BUILD.gn entry, a symbol list, a revision
    change) and putting it back would be a guess.
    """
    base_root = os.path.join(baseline_dir, directory)
    tree_root = os.path.join(tree_dir, directory)
    files = {}
    for dirpath, dirnames, filenames in os.walk(base_root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, base_root)
            other = os.path.join(tree_root, rel)
            if not os.path.isfile(other):
                continue
            base_lines = read_lines(full)
            tree_lines = read_lines(other)
            if base_lines == tree_lines:
                continue
            matcher = difflib.SequenceMatcher(None, base_lines, tree_lines,
                                              autojunk=False)
            hunks = []
            # The tree as each block will find it: every block before this one
            # is back, so the occurrence counted below is the one the restore
            # will pick, not the baseline's.
            placed = list(tree_lines)
            inserted = 0
            for tag, i1, i2, j1, _ in matcher.get_opcodes():
                if tag != "delete":
                    continue
                # Only the includes of a removed run are this import's damage.
                # Anything else it took with them is a difference between the
                # two trees that is not ours to undo, so it stays gone and the
                # block records the includes alone.
                removed = [line for line in base_lines[i1:i2]
                           if include.match(line)]
                if not removed:
                    continue
                after = base_lines[i1 - 1] if i1 else ""
                before = base_lines[i2] if i2 < len(base_lines) else ""
                anchor = j1 - 1 + inserted
                n = 1 + sum(1 for spot in occurrences(placed, after, before)
                            if spot < anchor)
                placed[anchor + 1:anchor + 1] = removed
                inserted += len(removed)
                hunks.append({
                    "after": after,
                    "before": before,
                    "n": n,
                    "add": removed,
                })
            if hunks:
                files[rel] = hunks
    return {
        "baseline": baseline_note(baseline_dir, ref, directory),
        "directory": directory,
        "include": include.pattern,
        "files": files,
    }


def write_manifest(path, manifest):
    """One block per line, so a regenerated manifest diffs by block."""
    out = ["{",
           '  "baseline": %s,' % json.dumps(manifest["baseline"]),
           '  "directory": %s,' % json.dumps(manifest["directory"]),
           '  "include": %s,' % json.dumps(manifest["include"]),
           '  "files": {']
    names = sorted(manifest["files"])
    for number, name in enumerate(names):
        out.append("    %s: [" % json.dumps(name))
        hunks = manifest["files"][name]
        for index, hunk in enumerate(hunks):
            line = "      " + json.dumps(hunk, ensure_ascii=False)
            out.append(line + ("," if index + 1 < len(hunks) else ""))
        out.append("    ]" + ("," if number + 1 < len(names) else ""))
    out += ["  }", "}"]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out) + "\n")


def restore_manifest(tree, manifest, apply_restore):
    """Report or restore one manifest's includes; the process exit status."""
    directory = manifest["directory"]
    include = include_matcher(manifest)
    files = manifest["files"]

    def say(text):
        print(PREFIX + directory + ": " + text)

    def fail(text):
        print("error: " + directory + ": " + text, file=sys.stderr)

    absent = 0
    pending = []
    for name in sorted(files):
        if os.path.isabs(name) or ".." in name.split("/"):
            fail("the manifest names a path outside the tree: %s" % name)
            return 2
        full = os.path.join(tree, directory, name)
        if not os.path.isfile(full):
            absent += 1
            continue
        lines = read_lines(full)
        inserted, unresolved = place(lines, files[name])
        if inserted or unresolved:
            pending.append((name, lines, inserted, unresolved))

    restored = sum(len(inserted) for _, _, inserted, _ in pending)
    if not pending:
        say("every include in the manifest is already there (%d file(s) "
            "listed, %d not in this tree)" % (len(files), absent))
        return 0
    for name, _, inserted, unresolved in pending:
        say("missing %d: %s" % (len(inserted), name))
        for line in inserted:
            say("  " + line.rstrip())
        for line in unresolved:
            say("  cannot place " + line)
    if not apply_restore:
        say("%d include line(s) missing from %d file(s); rerun with --apply "
            "to restore them" % (restored, len(pending)))
        return 1

    failed = 0
    unresolved = 0
    lost = 0
    for name, lines, _, unplaced in pending:
        path = os.path.join(tree, directory, name)
        try:
            with open(path, "w", encoding="utf-8", errors="replace",
                      newline="") as fh:
                fh.writelines(lines)
        except OSError as error:
            failed += 1
            fail("could not write %s: %s" % (name, error))
            continue
        # Verify the write instead of trusting it: the restore, run over the
        # file as it now is, must have nothing left to do, and every include
        # the manifest names must be in the file.
        written = read_lines(path)
        again, still = place(list(written), files[name])
        if again or still:
            failed += 1
            fail("%s still needs repair after it was written: %s"
                 % (name, ", ".join(again + still)))
            continue
        missing = expected_includes(files[name], include) - includes_in(
            written, include)
        if missing:
            lost += 1
            fail("%s is missing %d include(s) after the repair"
                 % (name, len(missing)))
        unresolved += len(unplaced)
        for line in unplaced:
            fail("cannot place " + line + " in " + name)
    if failed or lost or unresolved:
        fail("repair incomplete: %d file(s) not written, %d missing includes, "
             "%d block(s) without a home; the build would fail on these "
             "headers" % (failed, lost, unresolved))
        return 1
    say("restored %d include line(s) in %d file(s)%s"
        % (restored, len(pending),
           "; %d manifest file(s) are not in this tree" % absent
           if absent else ""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Put back the includes the Lumen source import removed, "
                    "as named by the manifests beside this script")
    ap.add_argument("--tree", default=".",
                    help="Chromium/Lumen source root (default: .)")
    ap.add_argument("--manifest", action="append", metavar="FILE",
                    help="a manifest to restore (repeatable; default: every "
                         "*%s beside this script)" % MANIFEST_SUFFIX)
    ap.add_argument("--apply", action="store_true",
                    help="write the includes instead of only listing them")
    ap.add_argument("--generate", action="store_true",
                    help="rebuild one manifest from --baseline and --tree")
    ap.add_argument("--baseline", metavar="DIR",
                    help="the undamaged tree --generate compares against")
    ap.add_argument("--baseline-ref", metavar="TEXT", default="",
                    help="what --baseline was, recorded in the manifest "
                         "(default: its git revision, or unversioned)")
    ap.add_argument("--dir", metavar="PATH",
                    help="tree-relative directory --generate records")
    ap.add_argument("--include-pattern", metavar="REGEX",
                    help="the include lines --generate records and the "
                         "repair owns")
    args = ap.parse_args()

    tree = os.path.abspath(args.tree)
    if not os.path.isdir(tree):
        print("error: no such tree: %s" % tree, file=sys.stderr)
        return 2

    if args.generate:
        if not args.baseline:
            print("error: --generate needs --baseline DIR", file=sys.stderr)
            return 2
        if not args.dir:
            print("error: --generate needs --dir PATH", file=sys.stderr)
            return 2
        if not args.include_pattern:
            print("error: --generate needs --include-pattern REGEX",
                  file=sys.stderr)
            return 2
        if not args.manifest or len(args.manifest) != 1:
            print("error: --generate writes exactly one --manifest FILE",
                  file=sys.stderr)
            return 2
        try:
            include = re.compile(args.include_pattern)
        except re.error as error:
            print("error: --include-pattern is not usable: %s" % error,
                  file=sys.stderr)
            return 2
        baseline = os.path.abspath(args.baseline)
        if not os.path.isdir(os.path.join(baseline, args.dir)):
            print("error: no %s under %s" % (args.dir, baseline),
                  file=sys.stderr)
            return 2
        manifest = generate(baseline, tree, args.dir, include,
                            args.baseline_ref)
        write_manifest(args.manifest[0], manifest)
        blocks = sum(len(hunks) for hunks in manifest["files"].values())
        print(PREFIX + "%s: wrote %d block(s) in %d file(s) to %s"
              % (args.dir, blocks, len(manifest["files"]),
                 args.manifest[0]))
        return 0

    paths = args.manifest or default_manifests()
    if not paths:
        print("error: no *%s found; nothing to restore" % MANIFEST_SUFFIX,
              file=sys.stderr)
        return 2
    status = 0
    for path in paths:
        try:
            manifest = load_manifest(path)
        except (OSError, ValueError) as error:
            print("error: cannot read %s: %s" % (path, error),
                  file=sys.stderr)
            return 2
        status = max(status, restore_manifest(tree, manifest, args.apply))
    return status


if __name__ == "__main__":
    sys.exit(main())
