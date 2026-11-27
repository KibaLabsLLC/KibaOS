#!/usr/bin/env python3
"""Report and restore source files a bad checkout left truncated.

The build tree is a DEPS-synced Lumen checkout with the patch series applied on
top, so "a file differs from git" has three meanings and only one of them is
damage:

  * The patch series touched it. `git apply --index` stages those, so the
    path appears in patches/SERIES and is skipped.
  * The source pruner removed it. A missing file is a decision, not damage,
    so deletions are counted and left alone.
  * Something truncated it. A tracked file that still exists, is modified,
    and that neither the patch series nor the pruner accounts for is damage:
    a truncated cache restore, an interrupted copy, a stubbed vendored file.
    That is what this tool restores, from the file's own checkout.

A truncated file does not announce itself at the point of damage. It surfaces
much later as a compile error with missing declarations, which is how
`absl/base/internal/cycleclock.h` and `cycleclock.cc` failed after casts.cc
compiled: their own `#include` lines and declarations were gone, while
`config.h` reached the working TUs. Checking every checkout after a sync is
cheaper than reading a compiler log for the cause.

Nothing under chrome/ is ever restored. Lumen is the Ash and Aura shell with
browser behaviour delegated away, so the browser subtree is pruned on purpose;
a damaged file that happens to sit there is reported and left alone.

The patch series is required for the same reason: without it every file the
series edits reads as damage, and restoring those would revert the tree to
upstream. The tool refuses to run until it finds SERIES, or --no-patches says
the tree legitimately has none.

Checkouts are the tree itself plus every DEPS dependency checkout nested inside
it, since each carries its own .git and can be truncated independently.

Report only unless --apply is given: the build tree is expensive to recreate,
so the list is printed first and nothing is written before it is read.
"""
import argparse
import os
import subprocess
import sys

SKIP_DIRS = {".git", "out", "node_modules", ".cipd", ".cipd_bin",
             "__pycache__", ".git_cache"}
MAX_DEPTH = 8
PREFIX = "==> source-check: "


def run(args):
    return subprocess.run(args, capture_output=True)


def find_checkouts(root, max_depth):
    """Every directory at or below root that carries its own .git."""
    found = []
    stack = [(root, 0)]
    while stack:
        directory, depth = stack.pop()
        try:
            if os.path.exists(os.path.join(directory, ".git")):
                found.append(directory)
        except OSError:
            continue
        if depth >= max_depth:
            continue
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            if name in SKIP_DIRS or name.startswith("."):
                continue
            child = os.path.join(directory, name)
            if os.path.isdir(child) and not os.path.islink(child):
                stack.append((child, depth + 1))
    return sorted(found, key=lambda d: (d.count(os.sep), d))


def status_entries(checkout):
    """(xy, path) pairs for tracked paths that differ from HEAD."""
    proc = run(["git", "-C", checkout, "-c", "core.quotePath=false", "status",
                "--porcelain", "-z", "--untracked-files=no"])
    if proc.returncode != 0:
        return None
    fields = proc.stdout.split(b"\0")
    entries = []
    i = 0
    while i < len(fields):
        record = fields[i]
        i += 1
        if len(record) < 4:
            continue
        xy = record[:2].decode("utf-8", "replace")
        path = record[3:].decode("utf-8", "replace")
        # With -z, a rename or copy is followed by its original path as the
        # next NUL terminated field, which belongs to this entry.
        if "R" in xy or "C" in xy:
            i += 1
        entries.append((xy, path))
    return entries


def patch_paths(patch_dir):
    """Paths the patch series edits, so their modifications are expected."""
    if not patch_dir or not os.path.isdir(patch_dir):
        return set()
    series = os.path.join(patch_dir, "SERIES")
    names = []
    if os.path.isfile(series):
        with open(series, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    names.append(line)
    if not names:
        names = sorted(n for n in os.listdir(patch_dir) if n.endswith(".patch"))
    touched = set()
    for name in names:
        path = os.path.join(patch_dir, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("+++ b/") or line.startswith("--- a/"):
                    rel = line[6:].split("\t")[0].strip()
                    if rel and rel != "/dev/null":
                        touched.add(rel)
    return touched


def under_chrome(rel):
    parts = rel.split("/")
    return bool(parts) and parts[0] == "chrome"


def scan(tree, patched, max_depth):
    """Classify what differs from HEAD in every checkout under the tree."""
    damaged, pruned, chrome, patched_hits, added, other = [], 0, [], [], 0, []
    checkouts = find_checkouts(tree, max_depth)
    if not checkouts:
        return None
    for checkout in checkouts:
        entries = status_entries(checkout)
        if entries is None:
            other.append("not a readable git checkout: %s" % checkout)
            continue
        for xy, rel in entries:
            shown = rel if os.path.abspath(checkout) == os.path.abspath(tree) \
                else os.path.relpath(os.path.join(checkout, rel), tree)
            if under_chrome(shown) or under_chrome(rel):
                # Never restored: the browser subtree is pruned on purpose.
                chrome.append(shown)
                continue
            if "D" in xy:
                pruned += 1
                continue
            if "A" in xy:
                added += 1
                continue
            if rel in patched:
                patched_hits.append(shown)
                continue
            full = os.path.join(checkout, rel)
            if not os.path.isfile(full):
                other.append("differs but is not a regular file: %s" % shown)
                continue
            damaged.append((checkout, rel, shown))
    return checkouts, damaged, pruned, chrome, patched_hits, added, other


def restore(checkout, rel):
    proc = run(["git", "-C", checkout, "checkout", "HEAD", "--", rel])
    return proc.returncode == 0, proc.stderr.decode("utf-8", "replace").strip()


def main():
    ap = argparse.ArgumentParser(
        description="Report truncated source files in the synced build tree "
                    "and restore them from their own checkout")
    ap.add_argument("--tree", default=".",
                    help="synced and patched source root (default: .)")
    ap.add_argument("--patches",
                    help="patch series directory (default: <this repo>/patches)")
    ap.add_argument("--apply", action="store_true",
                    help="restore the damaged files instead of only listing them")
    ap.add_argument("--max-depth", type=int, default=MAX_DEPTH,
                    help="how deep to look for dependency checkouts (%d)"
                         % MAX_DEPTH)
    ap.add_argument("--quiet-chrome", action="store_true",
                    help="do not list modified files under chrome/")
    ap.add_argument("--no-patches", action="store_true",
                    help="the tree carries no patch series, so every "
                         "modified file is damage")
    args = ap.parse_args()

    tree = os.path.abspath(args.tree)
    if not os.path.isdir(tree):
        print("error: no such tree: %s" % tree, file=sys.stderr)
        return 2
    patches = args.patches
    if not patches:
        here = os.path.dirname(os.path.abspath(__file__))
        patches = os.path.join(os.path.dirname(here), "patches")
    patched = patch_paths(patches)
    if not patched and not args.no_patches:
        # Without the series every file it edits reads as damage, and --apply
        # would revert the tree to Lumen's upstream state. Refuse instead of
        # guessing: a wrong answer here costs a full rebuild and the patches.
        print("error: no patch series found at %s, refusing to run: every "
              "file the series edits would look damaged. Pass --patches DIR, "
              "or --no-patches for a tree that carries no series." % patches,
              file=sys.stderr)
        return 2

    scanned = scan(tree, patched, args.max_depth)
    if scanned is None:
        print(PREFIX + "no git checkouts under %s, nothing to check" % tree,
              file=sys.stderr)
        return 1
    checkouts, damaged, pruned, chrome, patched_hits, added, other = scanned

    print(PREFIX + "%d checkout(s), %d damaged, %d patched, %d pruned, "
          "%d added, %d under chrome/"
          % (len(checkouts), len(damaged), len(patched_hits), pruned, added,
             len(chrome)))

    if chrome and not args.quiet_chrome:
        for shown in chrome:
            print(PREFIX + "under chrome/, never restored: %s" % shown)
    for line in other:
        print(PREFIX + line)
    for _, _, shown in damaged:
        print(PREFIX + "damaged: %s" % shown)

    if not damaged:
        if other:
            return 1
        if chrome:
            print(PREFIX + "nothing restorable; %d damaged file(s) under "
                           "chrome/ belong to the pruned subtree and stay as "
                           "they are" % len(chrome))
        else:
            print(PREFIX + "every tracked file still holds what its checkout "
                           "says")
        return 0
    if not args.apply:
        print(PREFIX + "report only; rerun with --apply to restore these "
                       "from their own checkout")
        return 1

    failed = 0
    for checkout, rel, shown in damaged:
        ok, err = restore(checkout, rel)
        if ok:
            print(PREFIX + "restored: %s" % shown)
        else:
            failed += 1
            print(PREFIX + "could not restore %s: %s" % (shown, err),
                  file=sys.stderr)
    if failed:
        print(PREFIX + "%d file(s) could not be restored" % failed,
              file=sys.stderr)
        return 1
    print(PREFIX + "restored %d file(s)" % len(damaged))
    return 0


if __name__ == "__main__":
    sys.exit(main())
