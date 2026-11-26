#!/usr/bin/env python3
"""Converge GN evaluation in a patched Lumen checkout with the real gn.

ci/repair-pruned-gn.py fixes what fails to parse; this fixes what only fails
once GN evaluates the graph. It runs the Ash package's exact `gn gen` command
(chromiumos-ash/PKGBUILD), and for every failure class that is a missing file
-- imports, exec_script and read_file inputs deleted by the source pruner --
restores the file from the chromium mirror at the pinned sha and retries.

Failures that are not missing files (undefined identifiers, emptied sources,
unresolved labels) are reported verbatim and stop the loop: real gn is the
referee, so what it rejects is never guessed at.

The chromium mirror must be checked out at the ref passed via --ref and the
src tree must carry its sync'd dependency checkout (ci/resolve-deps.py), the
same shape the ash package builds from. Exit 0 when `gn gen` completes;
exit 1 with the full final log when it does not and no remaining error is a
missing file.
"""
import argparse
import os
import re
import subprocess
import sys

GN_ARGS = """\
target_os = "chromeos"
target_cpu = "x64"
is_debug = false
is_component_build = false
is_official_build = false
is_chrome_branded = false
is_chromeos_device = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
treat_warnings_as_errors = false
use_sysroot = true
use_ozone = true
ozone_platform_wayland = true
use_system_minigbm = true
enable_rust = true
use_official_google_api_keys = false
dcheck_always_on = false
"""

UNABLE_RE = re.compile(r'Unable to load "([^"]+)"')
MISSING_FILE_RE = re.compile(
    r"FileNotFoundError: \[Errno 2\] No such file or directory: '([^']+)'")

MAX_ITERATIONS = 8


def up_show(chromium, ref, relpath):
    proc = subprocess.run(
        ["git", "-C", chromium, "show", "%s:%s" % (ref, relpath)],
        capture_output=True)
    return proc.stdout if proc.returncode == 0 else None


def candidates(root, out_dir, raw):
    """Tree-relative candidates for a path gn complained about."""
    cands = []
    p = raw
    if os.path.isabs(p):
        cands.append(os.path.relpath(p, root))
    else:
        cands.append(os.path.normpath(p))
        cands.append(os.path.relpath(os.path.normpath(
            os.path.join(out_dir, p)), root))
        cands.append(os.path.relpath(os.path.normpath(
            os.path.join(root, out_dir, p)), root))
    out = []
    for c in cands:
        if not c.startswith("..") and c not in out:
            out.append(c)
    return out


def fixable_paths(root, out_dir, text):
    """Missing files gn reported that we can name within the source tree."""
    found = []
    for raw in UNABLE_RE.findall(text) + MISSING_FILE_RE.findall(text):
        found.extend(candidates(root, out_dir, raw))
    return found


def restore(root, chromium, ref, rels):
    restorable, missing_upstream = [], {}
    for rel in rels:
        if os.path.exists(os.path.join(root, rel)):
            continue
        up = up_show(chromium, ref, rel)
        if up is None:
            missing_upstream.setdefault(rel, None)
            continue
        dst = os.path.join(root, rel)
        parent = os.path.dirname(dst)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(up)
        restorable.append(rel)
    return restorable, sorted(missing_upstream)


def main():
    ap = argparse.ArgumentParser(description="Converge gn gen on Lumen")
    ap.add_argument("--lumen", required=True, help="src root (patched tree)")
    ap.add_argument("--gn", required=True, help="path to the gn binary")
    ap.add_argument("--out-dir", default="out/Ash",
                    help="build dir, relative to the src root")
    ap.add_argument("--chromium", required=True,
                    help="chromium mirror checkout")
    ap.add_argument("--ref", required=True, help="chromium ref (pins sha)")
    ap.add_argument("--max-iterations", type=int, default=MAX_ITERATIONS)
    args = ap.parse_args()

    root = os.path.abspath(args.lumen)
    out_dir = os.path.join(root, args.out_dir)
    cmd = [os.path.abspath(args.gn), "gen", args.out_dir,
           "--root-target=//lumen", "--args=" + GN_ARGS]

    final_text = ""
    for i in range(1, args.max_iterations + 1):
        print("==> converge: gn gen attempt %d/%d" % (i, args.max_iterations),
              flush=True)
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
        text = proc.stdout + proc.stderr
        final_text = text
        if proc.returncode == 0:
            print("==> gn gen converged", flush=True)
            return 0
        rels = []
        for cand in fixable_paths(root, args.out_dir, text):
            full = os.path.join(root, cand)
            if not os.path.exists(full) and cand not in rels:
                rels.append(cand)
        if not rels:
            break
        restorable, upstream_missing = restore(
            root, args.chromium, args.ref, rels)
        for r in restorable:
            print("==> converge: restored %s from upstream %s"
                  % (r, args.ref), flush=True)
        for m in upstream_missing:
            print("==> converge: not in upstream, cannot restore: %s" % m,
                  flush=True)
        if not restorable:
            break

    print("==> converge: gn did not converge", flush=True)
    print(final_text, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
