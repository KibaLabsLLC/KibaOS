#!/usr/bin/env python3
"""Recover a pruned Lumen tree from the files a failed `gn gen` cannot load.

Shared by ci/converge-gn.py and the chromiumos-ash package build: both run
gn with --root-target=//lumen over the patched, DEPS-synced checkout, and
both must converge without ever growing the pruned browser subtree back.

Files deleted by the source pruner fall into two classes:

  * Inert files (import() targets, exec_script and read_file inputs) are
    restored from the chromium mirror at the pinned sha when one is
    available.
  * Build files (BUILD.gn) are never restored: a missing BUILD.gn means the
    pruner dropped its targets, so the dep edge that requests it is cut from
    the referrer gn names (ERROR at //path:line:col). An import target no
    mirror can provide gets its import line cut too.
  * Targets the pruner dropped while keeping their referrers surface as gn
    "Unresolved dependencies" pairs; the referrer's dep token for each such
    target is cut (absolute "//path:name", dir-only "//path" and relative
    ":name" spellings).

Everything else in the gn log is left alone: real gn is the referee, so what
it rejects is never guessed at.
"""
import argparse
import os
import re
import subprocess
import sys

MISSING_FILE_RE = re.compile(
    r"FileNotFoundError: \[Errno 2\] No such file or directory: '([^']+)'")
UNABLE_BLOCK_RE = re.compile(
    r'^ERROR at //(\S+):(\d+):(\d+): Unable to load "([^"]+)"', re.M)
UNRESOLVED_HEADER_RE = re.compile(
    r'^ERROR Unresolved dependencies\.\n', re.M)

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


def unresolved_pairs(text):
    """(referrer label, needed label) pairs from Unresolved dependencies."""
    m = UNRESOLVED_HEADER_RE.search(text)
    if not m:
        return []
    rest = text[m.end():]
    nxt = re.search(r'^ERROR ', rest, re.M)
    if nxt:
        rest = rest[:nxt.start()]
    pairs, referrer = [], None
    for line in rest.splitlines():
        if line.startswith("  needs "):
            if referrer:
                pairs.append((referrer, line.strip()[6:]))
        elif line.startswith("//"):
            referrer = line.strip()
        elif not line.strip():
            referrer = None
    out, seen = [], set()
    for pair in pairs:
        if pair not in seen:
            seen.add(pair)
            out.append(pair)
    return out


def label_parts(label):
    """Split a toolchain-qualified label into (build-dir path, target name)."""
    label = label.split("(", 1)[0]
    if ":" in label:
        path, name = label.split(":", 1)
    else:
        path, name = label, label.rsplit("/", 1)[-1]
    if path.startswith("//"):
        path = path[2:]
    return path, name


def dep_tokens(ref_path, needed_path, needed_name):
    """Quoted-in-source spellings that reference the needed label."""
    toks = ["//%s:%s" % (needed_path, needed_name)]
    if ref_path == needed_path:
        toks.append(":%s" % needed_name)
    if needed_name == needed_path.rsplit("/", 1)[-1]:
        toks.append("//%s" % needed_path)
    return toks


def cut_unresolved(root, text):
    """Cut refs to targets gn could not resolve; returns drop strings."""
    drops = []
    for referrer, needed in unresolved_pairs(text):
        ref_path, _ = label_parts(referrer)
        needed_path, needed_name = label_parts(needed)
        rel = "%s/BUILD.gn" % ref_path
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        toks = dep_tokens(ref_path, needed_path, needed_name)
        changed, blank = False, []
        for i, line in enumerate(lines):
            for tok in toks:
                while '"%s"' % tok in line:
                    new = drop_token(line, '"%s"' % tok)
                    if new is None:
                        break
                    line = new
                    changed = True
                    drops.append('%s:%d "%s"' % (rel, i + 1, tok))
            lines[i] = line
            if not line.strip():
                blank.append(i)
        if changed:
            for i in reversed(blank):
                del lines[i]
            with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
                fh.writelines(lines)
    return drops


def cut_edges(root, out_dir, text, chromium=None, ref=None):
    """Handle the build files gn cannot load.

    A missing BUILD.gn gets its requesting edge cut in the referrer; a
    missing import target is restored from upstream when a mirror is given
    and has it, and its import line is dropped otherwise. Returns
    (dropped, import_rels) where dropped entries are
    "file:line <token or import note>" strings.
    """
    drops, import_rels = [], []
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
            if chromium and ref and up_show(chromium, ref, rel) is not None:
                if rel not in import_rels:
                    import_rels.append(rel)
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
            drops.append('%s:%s %s' % (ref_rel, line_no, token))
        if not new.strip():
            del lines[idx]
        else:
            lines[idx] = new
        with open(os.path.join(root, ref_rel), "w", encoding="utf-8") as fh:
            fh.writelines(lines)
    return drops, import_rels


def recover(root, out_dir, text, chromium=None, ref=None):
    """Apply one recovery round from a gn gen failure log.

    Returns (changed, actions): changed is True when the tree was modified
    and the caller should re-run gn; actions are human-readable strings.
    """
    drops, import_rels = cut_edges(root, out_dir, text, chromium, ref)
    unresolved = cut_unresolved(root, text)
    actions = ["dropped %s" % d for d in drops + unresolved]
    rels = missing_inputs(root, out_dir, text) + import_rels
    if chromium and ref:
        restorable, missing_upstream = restore(root, chromium, ref, rels)
    else:
        restorable, missing_upstream = [], sorted(set(rels))
    for r in restorable:
        actions.append("restored %s from upstream %s" % (r, ref))
    for m in missing_upstream:
        actions.append("not in upstream, cannot restore: %s" % m)
    return bool(drops or unresolved or restorable), actions


def main():
    ap = argparse.ArgumentParser(
        description="Cut the edges a failed gn gen blames for pruned files")
    ap.add_argument("--lumen", required=True, help="src root (patched tree)")
    ap.add_argument("--out-dir", default="out/Ash",
                    help="build dir, relative to the src root (absolute ok)")
    ap.add_argument("--chromium", help="chromium mirror checkout; enables "
                                       "restoring inert files")
    ap.add_argument("--ref", help="chromium ref (pins sha); needs --chromium")
    ap.add_argument("--log-file", help="file holding the gn output "
                                       "(default: stdin)")
    args = ap.parse_args()
    if args.ref and not args.chromium:
        print("error: --ref needs --chromium", file=sys.stderr)
        return 2
    if args.log_file:
        with open(args.log_file, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()
    root = os.path.abspath(args.lumen)
    out_dir = args.out_dir
    if os.path.isabs(out_dir):
        out_dir = os.path.relpath(out_dir, root)
    changed, actions = recover(root, out_dir, text, args.chromium, args.ref)
    for action in actions:
        print("==> gn-edge-cut: %s" % action, flush=True)
    if not changed:
        print("==> gn-edge-cut: nothing to recover", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
