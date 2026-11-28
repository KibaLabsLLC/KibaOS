#!/usr/bin/env python3
"""Put back the abseil includes Lumen's source import removed.

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

ci/abseil-includes.json names every block of abseil includes Chromium has and
the tree lost, with the two lines the block sat between. Restoring a block
where it was is what makes the result exact, and being exact is the point:

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
and the restore looks for exactly that pair. Nothing is inferred from the
text of the includes, so a file Lumen has already restored itself is left as
it is, and a second run has nothing to do.

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

`--generate` rebuilds the manifest from two trees, deterministically, so it
is never hand-edited: pass Chromium's `third_party/abseil-cpp` as the
baseline and Lumen's as the tree. Only quoted absl includes are recorded,
which is what keeps the abseil revision Lumen carries (Chromium main minus
these blocks, plus a few unrelated deltas) out of the repair: anything else
the import took with them is a difference between the two trees, not damage,
and stays gone.

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

PREFIX = "==> abseil-includes: "
ABSEIL_DIR = "third_party/abseil-cpp"
ABSEIL_INCLUDE = re.compile(r'^\s*#\s*include\s+"absl/')
DEFAULT_MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "abseil-includes.json")


def read_lines(path):
    """The file's lines with their own line endings, so a rewrite is exact."""
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.readlines()


def load_manifest(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
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
    return files


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
        spots = [spot for spot in occurrences(lines, after, before)
                 if spot >= cursor - 1]
        missing = None
        spot = None
        # 2: the pair of lines the block sat between, exactly where it was.
        if len(spots) >= hunk["n"]:
            spot = spots[hunk["n"] - 1]
            if lines[spot + 1:spot + 1 + len(add)] == add:
                continue
        # 3: that pair's last occurrence after the previous block.
        elif spots:
            spot = spots[-1]
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


def includes_in(lines):
    return {line.strip() for line in lines if ABSEIL_INCLUDE.match(line)}


def expected_includes(hunks):
    return {line.strip() for hunk in hunks for line in hunk["add"]
            if ABSEIL_INCLUDE.match(line)}


def baseline_note(baseline_dir, ref):
    """What the blocks were recorded against, without this machine's paths."""
    if ref:
        return ref
    proc = subprocess.run(["git", "-C", baseline_dir, "rev-parse", "HEAD"],
                          capture_output=True)
    if proc.returncode == 0:
        return "%s at %s" % (ABSEIL_DIR,
                             proc.stdout.decode("utf-8").strip()[:12])
    return "%s from an unversioned baseline" % ABSEIL_DIR


def generate(baseline_dir, tree_dir, abseil, ref=""):
    """The manifest for `tree_dir` as a damaged copy of `baseline_dir`.

    Every run of lines the tree lost that held a quoted absl include becomes
    one block, anchored by the unchanged lines on either side of the run, so
    the block goes back where the run was. A run that also lost something
    else records only its includes: the rest is a difference between the two
    trees (a BUILD.gn entry, a symbol list, an abseil revision change) and
    putting it back would be a guess.
    """
    base_root = os.path.join(baseline_dir, abseil)
    tree_root = os.path.join(tree_dir, abseil)
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
            for tag, i1, i2, _, _ in matcher.get_opcodes():
                if tag != "delete":
                    continue
                # Only the quoted absl includes of a removed run are this
                # import's damage. Anything else it took with them is a
                # difference between the two trees that is not ours to undo,
                # so it stays gone and the block records the includes alone.
                removed = [line for line in base_lines[i1:i2]
                           if ABSEIL_INCLUDE.match(line)]
                if not removed:
                    continue
                after = base_lines[i1 - 1] if i1 else ""
                before = base_lines[i2] if i2 < len(base_lines) else ""
                hunks.append({
                    "after": after,
                    "before": before,
                    "n": 1 + len(occurrences(base_lines[:i1], after, before)),
                    "add": removed,
                })
            if hunks:
                files[rel] = hunks
    return {
        "baseline": baseline_note(baseline_dir, ref),
        "files": files,
    }


def write_manifest(path, manifest):
    """One block per line, so a regenerated manifest diffs by block."""
    out = ["{",
           '  "baseline": %s,' % json.dumps(manifest["baseline"]),
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


def main():
    ap = argparse.ArgumentParser(
        description="Put back the abseil includes the Lumen source import "
                    "removed, as named by ci/abseil-includes.json")
    ap.add_argument("--tree", default=".",
                    help="Chromium/Lumen source root (default: .)")
    ap.add_argument("--abseil", default=ABSEIL_DIR,
                    help="abseil directory inside the tree (default: %s)"
                         % ABSEIL_DIR)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST,
                    help="include manifest (default: %s)" % DEFAULT_MANIFEST)
    ap.add_argument("--apply", action="store_true",
                    help="write the includes instead of only listing them")
    ap.add_argument("--generate", action="store_true",
                    help="rebuild the manifest from --baseline and --tree")
    ap.add_argument("--baseline", metavar="DIR",
                    help="the undamaged tree --generate compares against")
    ap.add_argument("--baseline-ref", metavar="TEXT", default="",
                    help="what --baseline was, recorded in the manifest "
                         "(default: its git revision, or unversioned)")
    args = ap.parse_args()

    tree = os.path.abspath(args.tree)
    if not os.path.isdir(tree):
        print("error: no such tree: %s" % tree, file=sys.stderr)
        return 2
    if args.generate:
        if not args.baseline:
            print("error: --generate needs --baseline DIR", file=sys.stderr)
            return 2
        baseline = os.path.abspath(args.baseline)
        if not os.path.isdir(os.path.join(baseline, args.abseil)):
            print("error: no %s under %s" % (args.abseil, baseline),
                  file=sys.stderr)
            return 2
        manifest = generate(baseline, tree, args.abseil, args.baseline_ref)
        write_manifest(args.manifest, manifest)
        blocks = sum(len(hunks) for hunks in manifest["files"].values())
        print(PREFIX + "wrote %d block(s) in %d file(s) to %s"
              % (blocks, len(manifest["files"]), args.manifest))
        return 0

    try:
        files = load_manifest(args.manifest)
    except (OSError, ValueError) as error:
        print("error: cannot read %s: %s" % (args.manifest, error),
              file=sys.stderr)
        return 2

    absent = 0
    for name in files:
        if os.path.isabs(name) or ".." in name.split("/"):
            print("error: manifest names a path outside the tree: %s" % name,
                  file=sys.stderr)
            return 2
    pending = []
    for name in sorted(files):
        full = os.path.join(tree, args.abseil, name)
        if not os.path.isfile(full):
            absent += 1
            continue
        lines = read_lines(full)
        inserted, unresolved = place(lines, files[name])
        if inserted or unresolved:
            pending.append((name, lines, inserted, unresolved))

    restored = sum(len(inserted) for _, _, inserted, _ in pending)
    if not pending:
        print(PREFIX + "every abseil include in the manifest is already "
                       "there (%d file(s) listed, %d not in this tree)"
              % (len(files), absent))
        return 0
    for name, _, inserted, unresolved in pending:
        print(PREFIX + "missing %d: %s" % (len(inserted), name))
        for line in inserted:
            print(PREFIX + "  " + line.rstrip())
        for line in unresolved:
            print(PREFIX + "  cannot place " + line)
    if not args.apply:
        print(PREFIX + "%d include line(s) missing from %d file(s); rerun "
                       "with --apply to restore them" % (restored, len(pending)))
        return 1

    failed = 0
    unresolved = 0
    lost = 0
    for name, lines, _, unplaced in pending:
        path = os.path.join(tree, args.abseil, name)
        try:
            with open(path, "w", encoding="utf-8", errors="replace",
                      newline="") as fh:
                fh.writelines(lines)
        except OSError as error:
            failed += 1
            print("error: could not write %s: %s" % (name, error),
                  file=sys.stderr)
            continue
        # Verify the write instead of trusting it: the restore, run over the
        # file as it now is, must have nothing left to do, and every include
        # the manifest names must be in the file.
        written = read_lines(path)
        again, still = place(list(written), files[name])
        if again or still:
            failed += 1
            print("error: %s still needs repair after it was written: %s"
                  % (name, ", ".join(again + still)), file=sys.stderr)
            continue
        missing = expected_includes(files[name]) - includes_in(written)
        if missing:
            lost += 1
            print("error: %s is missing %d include(s) after the repair"
                  % (name, len(missing)), file=sys.stderr)
        unresolved += len(unplaced)
        for line in unplaced:
            print(PREFIX + "cannot place " + line + " in " + name,
                  file=sys.stderr)
    if failed or lost or unresolved:
        print(PREFIX + "repair incomplete: %d file(s) not written, %d "
                       "missing includes, %d block(s) without a home; the "
                       "build would fail on these headers"
              % (failed, lost, unresolved), file=sys.stderr)
        return 1
    print(PREFIX + "restored %d include line(s) in %d file(s)%s"
          % (restored, len(pending),
             "; %d manifest file(s) are not in this tree" % absent
             if absent else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
