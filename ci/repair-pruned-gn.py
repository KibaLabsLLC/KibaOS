#!/usr/bin/env python3
"""Repair GN files that the Lumen pruner broke by deleting value lines.

The Lumen source drop removes whole lines whose quoted strings reference
pruned paths (//chrome/*, vendored rust crate sources, toolchain stamps, ...).
Any such file that GN loads then fails to parse. This tool:

  1. parses every .gn/.gni file in the Lumen tree with a GN-compatible
     tokenizer/parser and collects syntax-broken files,
  2. repairs each broken file by re-adding the deleted lines:
       * gnrt-generated rust crate files: restore cargo_crate assignments
         aligned against the upstream chromium mirror at the pinned sha,
         falling back to values regenerated from the local vendored crates
         (crate_root, sources) or Cargo.toml (package metadata),
       * other files: difflib alignment against upstream; upstream-inserted
         lines are adopted only when every //... path they reference exists
         locally, so drifted content is never reverted,
  3. re-parses every repaired file and only emits syntax-valid repairs.

Repaired files are written to --out preserving relative paths; the caller
overlays them on the Lumen checkout and records the diff as a KibaOS patch.

Requires python3 (>= 3.8) and git.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

RUST_FILE_RE = re.compile(r"^third_party/rust/[^/]+/v[^/]+/BUILD\.gn$")
VENDOR_URL = "//third_party/rust/chromium_crates_io/vendor"


# ---------------------------------------------------------------------------
# GN parser (syntax check only; no evaluation)
# ---------------------------------------------------------------------------

class Tok:
    __slots__ = ("kind", "val", "line")

    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line


TOKEN_RE = re.compile(r'''
 (?P<ws>[ \t\r]+)
|(?P<comment>\#[^\n]*)
|(?P<nl>\n)
|(?P<str>"(?:[^"\\\n]|\\.)*")
|(?P<int>-?[0-9]+)
|(?P<ident>[A-Za-z_][A-Za-z0-9_]*)
|(?P<op>==|!=|<=|>=|\+=|-=|=|&&|\|\||!|<|>|\+|-|[{}()\[\],.])
''', re.X)

KEYWORDS = {"if", "else", "foreach"}

_BUILTIN_ARITY = {
    "read_file": (2, 2),
    "exec_script": (2, 4),
    "rebase_path": (1, 3),
    "string_replace": (3, 4),
    "string_join": (2, 2),
    "string_split": (1, 2),
    "string_escape_bash": (1, 1),
    "filter_include": (2, 2),
    "filter_exclude": (2, 2),
    "substring": (3, 3),
    "split_lines": (1, 2),
    "getenv": (1, 1),
    "defined": (1, 1),
    "import": (1, 1),
    "print": (1, None),
    "assert": (1, 2),
}


def tokenize(text):
    toks = []
    line = 1
    i = 0
    while i < len(text):
        m = TOKEN_RE.match(text, i)
        if not m:
            raise SyntaxError("line %d: bad char %r" % (line, text[i]))
        kind = m.lastgroup
        val = m.group()
        if kind == "nl":
            line += 1
        if kind not in ("ws", "comment", "nl"):
            if kind == "str":
                toks.append(Tok("str", val, line))
            elif kind == "int":
                toks.append(Tok("int", val, line))
            elif kind == "ident":
                toks.append(Tok("ident", val, line))
            else:
                toks.append(Tok("op", val, line))
        i = m.end()
    return toks


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else Tok("eof", "", 10**9)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def expect(self, val):
        t = self.peek()
        if not (t.kind == "op" and t.val == val):
            raise SyntaxError("line %d: expected %r, got %r" % (t.line, val, t.val))
        return self.next()

    def parse_file(self):
        while self.peek().kind != "eof":
            self.statement(top=True)

    def statement(self, top=False):
        t = self.peek()
        if t.kind == "ident":
            if t.val in KEYWORDS:
                return self.control()
            nxt = self.peek(1)
            if nxt.kind == "op" and nxt.val == "(":
                return self.call()
            return self.assign()
        raise SyntaxError("line %d: expected statement, got %r" % (t.line, t.val))

    def call(self):
        name = self.next()
        self.expect("(")
        n = [0]
        self.expr_list_until(")", n)
        self.expect(")")
        arity = _BUILTIN_ARITY.get(name.val)
        if arity:
            lo, hi = arity
            if n[0] < lo or (hi is not None and n[0] > hi):
                raise SyntaxError("line %d: %s called with %d args, expected %s"
                                  % (name.line, name.val, n[0], lo if lo == hi
                                     else "%d-%d" % (lo, hi)))
        if self.peek().kind == "op" and self.peek().val == "{":
            self.block()

    def control(self):
        t = self.next()
        if t.val == "if":
            self.expect("(")
            self.expr()
            self.expect(")")
            self.block()
            if self.peek().kind == "ident" and self.peek().val == "else":
                self.next()
                if self.peek().kind == "ident" and self.peek().val == "if":
                    self.control()
                else:
                    self.block()
        elif t.val == "foreach":
            self.expect("(")
            v = self.next()
            if v.kind != "ident":
                raise SyntaxError("line %d: bad foreach var" % v.line)
            self.expect(",")
            self.expr()
            self.expect(")")
            self.block()
        else:
            self.control()

    def block(self):
        self.expect("{")
        while not (self.peek().kind == "op" and self.peek().val == "}"):
            if self.peek().kind == "eof":
                raise SyntaxError("line %d: unexpected EOF in block" % self.peek().line)
            self.statement()
        self.expect("}")

    def assign(self):
        ident = self.next()
        self._lhs_accessors()
        t = self.peek()
        if not (t.kind == "op" and t.val in ("=", "+=", "-=")):
            raise SyntaxError("line %d: expected assignment operator, got %r"
                              % (t.line, t.val))
        self.next()
        self.expr()

    def _lhs_accessors(self):
        while True:
            if self.peek().kind == "op" and self.peek().val == ".":
                self.next()
                t = self.next()
                if t.kind != "ident":
                    raise SyntaxError("line %d: bad member name %r" % (t.line, t.val))
            elif self.peek().kind == "op" and self.peek().val == "[":
                self.next()
                self.expr()
                self.expect("]")
            else:
                return

    def expr(self):
        self.unary()
        while self.peek().kind == "op" and self.peek().val in (
                "==", "!=", "<=", ">=", "&&", "||", "+", "-", "<", ">"):
            self.next()
            self.unary()

    def unary(self):
        t = self.peek()
        if t.kind == "op" and t.val == "!":
            self.next()
            return self.unary()
        return self.primary()

    def primary(self):
        t = self.peek()
        if t.kind == "str" or t.kind == "int":
            self.next()
            self.accessors()
            return
        if t.kind == "ident":
            if t.val in KEYWORDS:
                self.control_no_block_needed()
                return
            nxt = self.peek(1)
            if nxt.kind == "op" and nxt.val == "(":
                self.call()
                self.accessors()
                return
            self.next()
            self.accessors()
            return
        if t.kind == "op" and t.val == "[":
            self.list()
            return
        if t.kind == "op" and t.val == "(":
            self.next()
            self.expr()
            self.expect(")")
            self.accessors()
            return
        if t.kind == "op" and t.val in ("+", "-"):
            self.next()
            self.unary()
            return
        if t.kind == "op" and t.val == "{":
            self.scope_literal()
            self.accessors()
            return
        raise SyntaxError("line %d: expected value, got %r" % (t.line, t.val))

    def scope_literal(self):
        self.expect("{")
        while not (self.peek().kind == "op" and self.peek().val == "}"):
            if self.peek().kind == "eof":
                raise SyntaxError("line %d: unexpected EOF in scope" % self.peek().line)
            self.statement()
        self.expect("}")

    def control_no_block_needed(self):
        t = self.next()
        if t.val == "if":
            self.expect("(")
            self.expr()
            self.expect(")")
            self.block()
            if self.peek().kind == "ident" and self.peek().val == "else":
                self.next()
                if self.peek().kind == "ident" and self.peek().val == "if":
                    self.control_no_block_needed()
                else:
                    self.block()
        else:
            self.block()

    def accessors(self):
        while True:
            if self.peek().kind == "op" and self.peek().val == ".":
                self.next()
                t = self.next()
                if t.kind != "ident":
                    raise SyntaxError("line %d: bad accessor %r" % (t.line, t.val))
            elif self.peek().kind == "op" and self.peek().val == "[":
                self.next()
                self.expr()
                self.expect("]")
            else:
                return

    def list(self):
        self.expect("[")
        while not (self.peek().kind == "op" and self.peek().val == "]"):
            if self.peek().kind == "eof":
                raise SyntaxError("line %d: unexpected EOF in list" % self.peek().line)
            if self.peek().kind == "op" and self.peek().val == ",":
                raise SyntaxError("line %d: stray comma in list" % self.peek().line)
            self.expr()
            if self.peek().kind == "op" and self.peek().val == ",":
                self.next()
            elif not (self.peek().kind == "op" and self.peek().val == "]"):
                t = self.peek()
                raise SyntaxError("line %d: expected , or ] in list, got %r"
                                  % (t.line, t.val))
        self.expect("]")

    def expr_list_until(self, closer, counter=None):
        while not (self.peek().kind == "op" and self.peek().val == closer):
            if self.peek().kind == "eof":
                raise SyntaxError("line %d: unexpected EOF in args" % self.peek().line)
            if self.peek().kind == "op" and self.peek().val == ",":
                raise SyntaxError("line %d: stray comma in args" % self.peek().line)
            self.expr()
            if counter is not None:
                counter[0] += 1
            if self.peek().kind == "op" and self.peek().val == ",":
                self.next()
            elif not (self.peek().kind == "op" and self.peek().val == closer):
                t = self.peek()
                raise SyntaxError("line %d: expected , or %s in args, got %r"
                                  % (t.line, closer, t.val))


def parses(text):
    try:
        Parser(tokenize(text)).parse_file()
        return True, None
    except SyntaxError as e:
        return False, str(e)


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

def scan_tree(root, overlay=None):
    """Parse every .gn/.gni under root; return {relpath: first error} for broken files."""
    broken = {}
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "out")]
        for f in files:
            if not (f.endswith(".gn") or f.endswith(".gni")):
                continue
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, root)
            if overlay and os.path.exists(os.path.join(overlay, rel)):
                p = os.path.join(overlay, rel)
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as e:
                broken[rel] = "unreadable: %s" % e
                continue
            ok, err = parses(text)
            if not ok:
                broken[rel] = err
    return broken


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def upstream_show(chromium, ref, relpath):
    proc = subprocess.run(
        ["git", "-C", chromium, "show", "%s:%s" % (ref, relpath)],
        capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def paths_exist(lumen, text):
    """True when every //... path referenced in text exists in the Lumen tree."""
    for p in re.findall(r'"(//[^"]+)"', text):
        if not os.path.exists(os.path.join(lumen, p[2:])):
            return False
    return True


def next_nonblank(lines, i):
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    return i, (lines[i] if i < len(lines) else "")


# ---------------------------------------------------------------------------
# gnrt-generated rust crate repair
# ---------------------------------------------------------------------------

KEY_RE = re.compile(r"^  ([a-z_]+) =")
CONT_START = ('"', "[", "{")
DERIVABLE_KEYS = ("crate_root", "sources", "inputs",
                  "build_root", "build_sources", "build_script_inputs")
PKG_META_KEYS = {
    "cargo_pkg_description": "description",
    "cargo_pkg_repository": "repository",
    "cargo_pkg_authors": "authors",
}


def parse_crate_blocks(txt):
    """Split a gnrt BUILD.gn into ordered cargo_crate blocks: {key: [lines]}."""
    blocks = []
    cur = None
    key = None
    for line in txt.split("\n"):
        m = re.match(r'cargo_crate\("([^"]+)"\) \{', line)
        if m:
            cur = {}
            blocks.append(cur)
            key = None
            continue
        if cur is None:
            continue
        if line == "}":
            cur = None
            key = None
            continue
        m = KEY_RE.match(line)
        if m:
            key = m.group(1)
            cur[key] = [line]
            continue
        if key is not None and (not line or line.startswith(" ")):
            if line.strip():
                cur[key].append(line)
        else:
            key = None
    return blocks


def vendor_dir_for(lumen, lines, upto):
    vendor = os.path.join(lumen, VENDOR_URL[2:])
    block_start = 0
    for j in range(upto, -1, -1):
        if re.match(r'cargo_crate\("', lines[j]):
            block_start = j
            break
    block_end = len(lines)
    for j in range(upto, len(lines)):
        if lines[j] == "}":
            block_end = j
            break
    name = epoch = None
    for j in range(block_start, block_end):
        m = re.match(r'\s*cargo_pkg_name = "(.*?)"', lines[j])
        if m:
            name = m.group(1)
            break
    for j in range(block_start, block_end):
        m = re.match(r'\s*epoch = "(.*?)"', lines[j])
        if m:
            epoch = m.group(1)
            break
    if not name:
        return None
    fallback = None
    for d in sorted(os.listdir(vendor)):
        if "-v" not in d:
            continue
        stem, suf = d.rsplit("-v", 1)
        if stem.replace("_", "-") == name.replace("_", "-"):
            if epoch is None or suf == epoch.replace(".", "_"):
                return d
            if fallback is None:
                fallback = d
    return fallback


def walk_vendor_src(vendor, vdir):
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(vendor, vdir, "src")):
        dirnames.sort()
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1] == ".rs":
                rel = os.path.relpath(os.path.join(dirpath, fn), vendor)
                out.append("%s/%s" % (VENDOR_URL, rel.replace(os.sep, "/")))
    return sorted(out)


def derive_from_vendor(lumen, key, vdir):
    vendor = os.path.join(lumen, VENDOR_URL[2:])
    out = []
    if key == "crate_root":
        root = os.path.join(vdir, "src/lib.rs")
        if not os.path.exists(os.path.join(vendor, root)):
            found = None
            for dp, _dns, fns in os.walk(os.path.join(vendor, vdir, "src")):
                for fn in sorted(fns):
                    if fn == "lib.rs":
                        found = os.path.relpath(os.path.join(dp, fn), vendor)
            if not found:
                raise RuntimeError("no lib.rs in %s" % vdir)
            root = found
        out = ['      "%s/%s"' % (VENDOR_URL, root.replace(os.sep, "/"))]
    elif key == "sources":
        entries = walk_vendor_src(vendor, vdir)
        if not entries:
            raise RuntimeError("no .rs sources in %s" % vdir)
        out = ['    "%s",' % e for e in entries]
    elif key == "inputs":
        out = ["  ]"]
    elif key == "build_root":
        if not os.path.exists(os.path.join(vendor, vdir, "build.rs")):
            raise RuntimeError("no build.rs in %s" % vdir)
        out = ['  build_root =',
               '      "%s/%s/build.rs"' % (VENDOR_URL, vdir)]
    elif key == "build_sources":
        if not os.path.exists(os.path.join(vendor, vdir, "build.rs")):
            raise RuntimeError("no build.rs in %s" % vdir)
        out = ['  build_sources = [ "%s/%s/build.rs" ]' % (VENDOR_URL, vdir)]
    elif key == "build_script_inputs":
        if not os.path.exists(os.path.join(vendor, vdir, "build.rs")):
            raise RuntimeError("no build.rs in %s" % vdir)
        out = ['  build_script_inputs = [ "%s/%s/src/../build.rs" ]'
               % (VENDOR_URL, vdir)]
    else:
        raise RuntimeError("no derivation for key %s" % key)
    return out


def cargo_toml_value(lumen, vdir, key):
    cargo = os.path.join(lumen, VENDOR_URL[2:], vdir, "Cargo.toml")
    if not os.path.exists(cargo):
        return None
    in_pkg = False
    pending_list = None
    out = None
    with open(cargo, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if pending_list is not None:
                if "]" in line:
                    pending_list += re.findall(r'"([^"]*)"', line.split("]")[0])
                    out = pending_list
                    pending_list = None
                else:
                    pending_list += re.findall(r'"([^"]*)"', line)
                continue
            if line.strip().startswith("["):
                in_pkg = line.strip() == "[package]"
                continue
            if not in_pkg:
                continue
            m = re.match(r'%s = "(.*)"\s*$' % key, line)
            if m:
                out = m.group(1)
                continue
            m = re.match(r'%s = \[(.*)\]\s*$' % key, line)
            if m:
                out = re.findall(r'"([^"]*)"', m.group(1))
                continue
            m = re.match(r'%s = \[\s*$' % key, line)
            if m:
                pending_list = []
    return out


def corrupt_regions(lines):
    """(key, start, end) assignments whose value line(s) the pruner deleted."""
    n = len(lines)
    i = 0
    while i < n:
        m = re.match(r"^  ([a-z_]+) =\s*$", lines[i])
        if m:
            _j, nxt = next_nonblank(lines, i + 1)
            if not nxt.lstrip().startswith(CONT_START):
                yield (m.group(1), i, i + 1)
                i += 1
                continue
        m2 = re.match(r"^  (sources|inputs) = \[\s*$", lines[i].rstrip())
        if m2:
            _j, nxt = next_nonblank(lines, i + 1)
            if nxt.lstrip() == "]":
                yield (m2.group(1), i, _j + 1)
                i += 1
                continue
        i += 1


def repair_rust_file(lumen, relpath, up_text):
    """Return (new_text, repairs) or raise RuntimeError with a reason."""
    vendor = os.path.join(lumen, VENDOR_URL[2:])
    path = os.path.join(lumen, relpath)
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    up_blocks = parse_crate_blocks(up_text) if up_text else []

    repairs = {}
    for key, s, e in corrupt_regions(lines):
        block_idx = len(re.findall(r'cargo_crate\("',
                                   "".join(l + "\n" for l in lines[:s]))) - 1
        upval = None
        if up_blocks and block_idx < len(up_blocks):
            upval = up_blocks[block_idx].get(key)
        if upval and len(upval) > 1 and paths_exist(lumen, "\n".join(upval[1:])):
            repairs[s] = (e, [lines[s]] + upval[1:])
            continue
        vdir = vendor_dir_for(lumen, lines, s)
        if not vdir:
            raise RuntimeError("no vendor dir for key=%s (block %d)" % (key, block_idx))
        if key in DERIVABLE_KEYS:
            repairs[s] = (e, derive_from_vendor(lumen, key, vdir))
        elif key in PKG_META_KEYS:
            val = cargo_toml_value(lumen, vdir, PKG_META_KEYS[key])
            if val is None:
                raise RuntimeError("no Cargo.toml value for %s" % key)
            text = ", ".join(val) if PKG_META_KEYS[key] == "authors" else val
            repairs[s] = (e, ['      "%s"' % text.replace('"', '\\"')])
        else:
            raise RuntimeError("unknown corrupt key %s" % key)

    ends = dict((s, e) for s, (e, _r) in repairs.items())
    out = lines
    for s in sorted(repairs, reverse=True):
        e, repl = repairs[s]
        out[s:e] = repl
    return "\n".join(out), len(repairs)


# ---------------------------------------------------------------------------
# Generic (non-rust) repair: alignment against upstream
# ---------------------------------------------------------------------------

def repair_generic_file(lumen, relpath, up_text):
    path = os.path.join(lumen, relpath)
    with open(path, encoding="utf-8", errors="replace") as fh:
        lumen_lines = fh.read().split("\n")
    up_lines = up_text.split("\n")
    sm = difflib.SequenceMatcher(None, lumen_lines, up_lines, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            out.extend(lumen_lines[i1:i2])
        elif tag == "insert":
            candidate = up_lines[j1:j2]
            if paths_exist(lumen, "\n".join(candidate)):
                out.extend(candidate)
        else:
            out.extend(lumen_lines[i1:i2])
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def check_only(lumen):
    broken = scan_tree(lumen)
    for rel in sorted(broken):
        print("BROKEN %s: %s" % (rel, broken[rel]))
    print("%d broken" % len(broken))
    return 1 if broken else 0


def repair(lumen, chromium, ref, out_dir):
    broken = scan_tree(lumen)
    print("scanned: %d broken files" % len(broken))
    os.makedirs(out_dir, exist_ok=True)
    repaired, unrepaired = [], []
    for rel in sorted(broken):
        try:
            if RUST_FILE_RE.match(rel):
                up_text = upstream_show(chromium, ref, rel)
                new_text, n = repair_rust_file(lumen, rel, up_text)
            else:
                up_text = upstream_show(chromium, ref, rel)
                if up_text is None:
                    raise RuntimeError("no upstream counterpart at %s" % ref)
                n = 0
                new_text = repair_generic_file(lumen, rel, up_text)
        except RuntimeError as e:
            unrepaired.append((rel, str(e)))
            print("UNREPAIRED %s: %s" % (rel, e))
            continue
        ok, err = parses(new_text)
        if not ok:
            unrepaired.append((rel, "repair still invalid: %s" % err))
            print("UNREPAIRED %s: repair still invalid: %s" % (rel, err))
            continue
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        repaired.append((rel, n))
        print("REPAIRED %s (%s)" % (rel, "%d sites" % n if n else "aligned"))

    remaining = scan_tree(lumen, overlay=out_dir)
    print("summary: %d repaired, %d unrepaired, %d files still broken"
          % (len(repaired), len(unrepaired), len(remaining)))
    for rel in sorted(remaining):
        print("STILL BROKEN %s: %s" % (rel, remaining[rel]))
    return 0 if not remaining else 2


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--lumen", required=True, help="Lumen checkout root")
    ap.add_argument("--chromium", help="chromium mirror checkout (git)")
    ap.add_argument("--ref", help="chromium ref (e.g. pins/chromium.sha)")
    ap.add_argument("--out", help="directory receiving repaired files")
    ap.add_argument("--check", action="store_true",
                    help="only scan and report broken files")
    args = ap.parse_args()

    if args.check:
        sys.exit(check_only(args.lumen))
    for req in ("chromium", "ref", "out"):
        if not getattr(args, req):
            ap.error("--%s is required without --check" % req)
    sys.exit(repair(args.lumen, args.chromium, args.ref, args.out))


if __name__ == "__main__":
    main()
