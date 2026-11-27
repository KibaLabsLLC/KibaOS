#!/usr/bin/env python3
"""Converge GN evaluation in a patched Lumen checkout with the real gn.

ci/repair-pruned-gn.py fixes what fails to parse; this fixes what only fails
once GN evaluates the graph. It runs the Ash package's exact `gn gen` command
(chromiumos-ash/PKGBUILD) and after every failure applies one round of
ci/gn_edge_cut.py recovery: inert files the pruner deleted (import targets,
exec_script and read_file inputs) come back from the chromium mirror at the
pinned sha, while dep edges into build files the pruner deleted, refs to
targets the pruner dropped (gn's "Unresolved dependencies" pairs), and
duplicate source listings that collide into one object file are cut in the
referrer gn names; input refs nothing generates are cut and inputs whose
generators lack a dep path get those generators added as deps -- a tree that
must not load chrome at all converges by shedding every edge into the
pruned subtree instead of growing chrome back. Failures that are none of
those (undefined identifiers, emptied sources) are reported verbatim and
stop the loop: real gn is the referee, so what it rejects is never guessed
at.

The chromium mirror must be checked out at the ref passed via --ref and the
src tree must carry its sync'd dependency checkout (ci/resolve-deps.py), the
same shape the ash package builds from. Exit 0 when `gn gen` completes;
exit 1 with the full final log when it does not and no remaining error is a
missing file.
"""
import argparse
import os
import subprocess
import sys

from gn_edge_cut import MAX_ITERATIONS, recover

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

# Chromium's Clang modules build modularizes headers per target; on this pruned
# tree one lost header or dep edge turns a target into an empty module and its
# headers stop defining macros (the first abseil TU then fails on
# ABSL_NAMESPACE_BEGIN/ABSL_RAW_LOG). Build textually instead.
use_clang_modules = false
"""


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
        error_line = next((line for line in text.splitlines()
                           if line.startswith("ERROR at ")), "")
        if error_line:
            print("==> converge: %s" % error_line, flush=True)
        changed, actions = recover(root, args.out_dir, text,
                                   args.chromium, args.ref)
        for action in actions:
            print("==> converge: %s" % action, flush=True)
        if not changed:
            break

    print("==> converge: gn did not converge", flush=True)
    print(final_text, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
