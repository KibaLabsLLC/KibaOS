#!/usr/bin/env python3
"""Converge GN evaluation in a patched Lumen checkout with the real gn.

ci/repair-pruned-gn.py fixes what fails to parse; this fixes what only fails
once GN evaluates the graph. It runs the Ash package's exact `gn gen` command
(chromiumos-ash/PKGBUILD). Files deleted by the source pruner fall into two
classes:

  * Inert files (import() targets, exec_script and read_file inputs) are
    restored from the chromium mirror at the pinned sha and the attempt is
    retried.
  * Build files (BUILD.gn) are never restored: a missing BUILD.gn means the
    pruner dropped its targets, so the dep edge that requests it is cut from
    the referrer gn names (ERROR at //path:line:col) and the attempt is
    retried. A tree that must not load chrome at all converges by shedding
    every edge into the pruned subtree instead of growing chrome back.

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

MISSING_FILE_RE = re.compile(
    r"FileNotFoundError: \[Errno 2\] No such file or directory: '([^']+)'")
UNABLE_BLOCK_RE = re.compile(
    r'^ERROR at //(\S+):(\d+):(\d+): Unable to load "([^"]+)"', re.M)

MAX_ITERATIONS = 1000


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


def missing_inputs(root, out_dir, text):
    """Tree-relative exec_script/read_file inputs gn reported as missing."""
    rels = []
    for raw in MISSING_FILE_RE.findall(text):
        for cand in candidates(root, out_dir, raw):
            full = os.path.join(root, cand)
            if not os.path.exists(full) and cand not in rels:
                rels.append(cand)
    return rels


def quoted_token(line, col):
    """The quoted string in `line` that 1-based column `col` points at."""
    for m in re.finditer(r'"[^"\n]*"', line):
        if m.start() + 1 <= col <= m.end():
            return m.group(0)
    m = re.search(r'"[^"\n]*"', line)
    return m.group(0) if m else None


def drop_token(line, token):
    """Remove `token` from `line`, keeping a gn list literal well-formed."""
    i = line.find(token)
    if i < 0:
        return None
    j = i + len(token)
    k = j
    while k < len(line) and line[k] in " \t":
        k += 1
    if k < len(line) and line[k] == ",":
        k += 1
        if k < len(line) and line[k] == " ":
            k += 1
        return line[:i] + line[k:]
    m = i - 1
    while m >= 0 and line[m] in " \t":
        m -= 1
    if m >= 0 and line[m] == ",":
        return line[:m] + line[j:]
    return line[:i] + line[j:]


def drop_import(line):
    start = line.find("import(")
    if start < 0:
        return None
    end = line.find(")", start)
    if end < 0:
        return None
    return line[:start] + line[end + 1:]


def cut_edges(root, chromium, ref, out_dir, text):
    """Handle the files gn cannot load.

    A missing BUILD.gn gets its requesting edge cut in the referrer; a
    missing import target is restored from upstream when it exists there and
    its import line is dropped when it does not. Returns (dropped, restores,
    unrestorable) where dropped entries are "file:line token" strings.
    """
    drops, restores = [], []
    seen = set()
    for ref_rel, line_no, col_no, raw in UNABLE_BLOCK_RE.findall(text):
        cands = candidates(root, out_dir, raw)
        rel = cands[0] if cands else None
        if rel is None or (ref_rel, line_no) in seen:
            continue
        seen.add((ref_rel, line_no))
        if os.path.exists(os.path.join(root, rel)):
            continue
        try:
            with open(os.path.join(root, ref_rel), encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        idx = int(line_no) - 1
        if idx >= len(lines):
            continue
        line = lines[idx]
        if "import(" in line:
            if up_show(chromium, ref, rel) is not None:
                if rel not in restores:
                    restores.append(rel)
                continue
            new = drop_import(line)
            if new is None:
                continue
            drops.append("%s:%s import of %s" % (ref_rel, line_no, rel))
        else:
            token = quoted_token(line, int(col_no))
            if token is None:
                continue
            new = drop_token(line, token)
            if new is None:
                continue
            drops.append("%s:%s %s" % (ref_rel, line_no, token))
        if not new.strip():
            del lines[idx]
        else:
            lines[idx] = new
        with open(os.path.join(root, ref_rel), "w", encoding="utf-8") as fh:
            fh.writelines(lines)
    return drops, restores


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
        error_line = next((line for line in text.splitlines()
                           if line.startswith("ERROR at ")), "")
        if error_line:
            print("==> converge: %s" % error_line, flush=True)
        drops, import_rels = cut_edges(
            root, args.chromium, args.ref, args.out_dir, text)
        for d in drops:
            print("==> converge: dropped %s" % d, flush=True)
        restorable, upstream_missing = restore(
            root, args.chromium, args.ref,
            missing_inputs(root, args.out_dir, text) + import_rels)
        for r in restorable:
            print("==> converge: restored %s from upstream %s"
                  % (r, args.ref), flush=True)
        for m in upstream_missing:
            print("==> converge: not in upstream, cannot restore: %s" % m,
                  flush=True)
        if not drops and not restorable:
            break

    print("==> converge: gn did not converge", flush=True)
    print(final_text, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
