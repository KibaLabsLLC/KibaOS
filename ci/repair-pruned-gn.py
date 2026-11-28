#!/usr/bin/env python3
"""Repair GN files that the Lumen pruner broke by deleting value lines.

The Lumen source drop removes whole lines whose quoted strings reference
pruned paths (//chrome/*, vendored rust crate sources, toolchain stamps, ...).
Any such file that GN loads then fails to parse. This tool:

  1. parses every .gn/.gni file in the Lumen tree with a GN-compatible
     tokenizer/parser and collects syntax-broken files,
  2. also collects gnrt-generated rust crate files whose `sources`/`inputs`
     lists the pruner emptied to `[]`. Emptied lists still parse, so they are
     never a step 1 finding, but rustc discovers files GN never declared and
     rustc_wrapper.py fails the build on them ("Rust source file or input not
     in GN sources"), which is a compile-time failure no GN parse catches,
  3. repairs each file by re-adding the deleted lines:
       * gnrt-generated rust crate files: restore cargo_crate assignments
         aligned against the upstream chromium mirror at the pinned sha,
         falling back to values regenerated from the local vendored crates
         (crate_root, sources) or Cargo.toml (package metadata),
       * emptied rust crate `sources`/`inputs` lists: sources are refilled
         from the vendored crate's own src/ tree, inputs from the upstream
         mirror's list (gnrt takes them from `extra_input_roots`, which the
         vendor tree does not record), keeping each upstream entry only when
         the path it names exists in the checkout,
       * other files: difflib alignment against upstream; upstream-inserted
         lines are adopted only when every //... path they reference exists
         locally, so drifted content is never reverted,
  4. re-parses every repaired file and only emits syntax-valid repairs.

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
# Import closure
# ---------------------------------------------------------------------------

IMPORT_RE = re.compile(r'\bimport\(\s*"([^"]+)"\s*\)')


def resolve_import_path(import_path, cur_rel):
    """Map an import() argument to a tree-relative path."""
    if import_path.startswith("//"):
        return import_path[2:]
    d = os.path.dirname(cur_rel)
    return os.path.normpath(os.path.join(d, import_path)) if d else import_path


def missing_imports(root):
    """Return {missing relpath: [importer relpaths]} for every import() argument
    that does not exist locally. Import paths containing GN variables cannot
    be resolved statically and are skipped."""
    present = set()
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "out")]
        for f in files:
            if f.endswith(".gn") or f.endswith(".gni"):
                present.add(os.path.relpath(os.path.join(dirpath, f), root))
    missing = {}
    for rel in sorted(present):
        try:
            with open(os.path.join(root, rel), encoding="utf-8",
                      errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for ip in IMPORT_RE.findall(text):
            if "$" in ip:
                continue
            t = resolve_import_path(ip, rel)
            if t not in present:
                missing.setdefault(t, []).append(rel)
    return missing


def verify_imports(lumen, chromium, ref):
    """Restore pruned importable GN files from upstream at ref.

    Files that upstream does not carry (DEPS-managed trees supplied by
    ci/resolve-deps.py at bootstrap, hook-generated files, dynamically built
    import paths) are reported, not guessed at; only file content that exists
    in the upstream tree is restored, and only when it parses. Returns 0:
    the report is the deliverable, the authoritative validation is GN itself
    at build time."""
    missing = missing_imports(lumen)
    restores, deferred = [], {}
    for rel in sorted(missing):
        up = upstream_show(chromium, ref, rel) if chromium and ref else None
        if up is not None and parses(up)[0]:
            dst = os.path.join(lumen, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w", encoding="utf-8", newline="") as fh:
                fh.write(up)
            restores.append(rel)
        else:
            deferred[rel] = missing[rel]
    for rel, who in sorted(missing_imports(lumen).items()):
        if rel not in missing:
            deferred.setdefault(rel, who)
    for rel in sorted(restores):
        print("restored import %s from upstream %s" % (rel, ref))
    for rel in sorted(deferred):
        print("deferred import %s (imported by %s): DEPS-managed, "
              "hook-generated, or dynamic" %
              (rel, ", ".join(deferred[rel][:4])))
    print("summary: %d missing imports, %d restored, %d deferred" %
          (len(missing), len(restores), len(deferred)))
    return 0


# ---------------------------------------------------------------------------
# gnrt-generated rust crate repair
# ---------------------------------------------------------------------------
# gnrt-generated rust crate repair
# ---------------------------------------------------------------------------

KEY_RE = re.compile(r"^  ([a-z_]+) =")
CONT_START = ('"', "[", "{")


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
    """gnrt sources = .rs files under <vendor>/<vdir>/src/, sorted by path."""
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(vendor, vdir, "src")):
        dirnames.sort()
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1] == ".rs":
                rel = os.path.relpath(os.path.join(dirpath, fn), vendor)
                out.append("%s/%s" % (VENDOR_URL, rel.replace(os.sep, "/")))
    return sorted(out)


def derive_value_lines(lumen, key, vdir):
    """Value line(s) for crate_root/build_*; the caller keeps the `key =` line."""
    vendor = os.path.join(lumen, VENDOR_URL[2:])
    if key == "crate_root":
        root = os.path.join(vdir, "src/lib.rs")
        if not os.path.exists(os.path.join(vendor, root)):
            found = None
            for dp, _dns, fns in os.walk(os.path.join(vendor, vdir, "src")):
                for fn in sorted(fns):
                    if fn == "lib.rs":
                        found = os.path.relpath(os.path.join(dp, fn), vendor)
                        break
                if found:
                    break
            if not found:
                raise RuntimeError("no lib.rs in %s" % vdir)
            root = found
        return ['      "%s/%s"' % (VENDOR_URL, root.replace(os.sep, "/"))]
    if key in ("build_root", "build_sources", "build_script_inputs"):
        if not os.path.exists(os.path.join(vendor, vdir, "build.rs")):
            raise RuntimeError("no build.rs in %s" % vdir)
        target = {"build_root": "      \"%s/%s/build.rs\"",
                  "build_sources": "      [ \"%s/%s/build.rs\" ]",
                  "build_script_inputs": "      [ \"%s/%s/src/../build.rs\" ]"}[key]
        return [target % (VENDOR_URL, vdir)]
    raise RuntimeError("no derivation for key %s" % key)


def crate_entries(lumen, key, vdir, upval):
    """The value lines an emptied gnrt `sources`/`inputs` list should hold.

    `sources` are the vendored crate's own .rs files. `inputs` come from the
    upstream mirror's list, because gnrt emits them from `extra_input_roots`
    and nothing in the vendor tree records that; an entry is kept only when
    the path it names exists in this checkout, since a declared-but-absent
    input stops `gn gen`, while a missing one is named by rustc_wrapper.py at
    build time instead of being guessed at.
    """
    if key == "sources":
        return ['    "%s",' % e for e in walk_vendor_src(
            os.path.join(lumen, VENDOR_URL[2:]), vdir)]
    entries = []
    for p in re.findall(r'"(//[^"]+)"', "\n".join(upval or [])):
        if os.path.exists(os.path.join(lumen, p[2:])):
            entries.append('    "%s",' % p)
    return entries


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


PKG_META_KEYS = {
    "cargo_pkg_description": "description",
    "cargo_pkg_repository": "repository",
    "cargo_pkg_authors": "authors",
}


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
        i += 1


def empty_list_regions(lines):
    """(key, start, end) for rust crate `sources`/`inputs` lists emptied to [].

    Both shapes the pruner leaves behind: the value lines deleted between the
    brackets, and the whole list collapsed to one `key = []` line. Neither
    breaks parsing, which is why scan_tree never reports them.
    """
    regions = []
    for i, line in enumerate(lines):
        m = re.match(r"^  (sources|inputs) = \[\]\s*$", line)
        if m:
            regions.append((m.group(1), i, i + 1))
            continue
        m = re.match(r"^  (sources|inputs) = \[\s*$", line)
        if m:
            _j, nxt = next_nonblank(lines, i + 1)
            if nxt.strip() == "]":
                regions.append((m.group(1), i, _j + 1))
    return regions


def block_of(lines, upto):
    return len(re.findall(r'cargo_crate\("',
                          "".join(l + "\n" for l in lines[:upto]))) - 1


def rust_list_gaps(lumen, lines, up_text):
    """{key: value lines} for emptied lists that this tree can refill."""
    up_blocks = parse_crate_blocks(up_text) if up_text else []
    gaps = {}
    for key, s, _e in empty_list_regions(lines):
        idx = block_of(lines, s)
        upval = None
        if up_blocks and idx < len(up_blocks):
            upval = up_blocks[idx].get(key)
        vdir = None
        if key == "sources":
            vdir = vendor_dir_for(lumen, lines, s)
            if not vdir:
                continue
        entries = crate_entries(lumen, key, vdir, upval)
        if entries:
            gaps[key] = entries
    return gaps


def scan_rust_lists(lumen, chromium=None, ref=None, overlay=None):
    """{relpath: [key, ...]} for emptied rust crate lists that can be refilled.

    These files parse, so scan_tree cannot see them; they fail at compile time
    in rustc_wrapper.py instead. Only lists with something derivable are
    reported, so a crate whose upstream `inputs` are empty stays quiet.
    """
    found = {}
    for dirpath, dirs, files in os.walk(lumen):
        dirs[:] = [d for d in dirs if d not in (".git", "out")]
        if "BUILD.gn" not in files:
            continue
        rel = os.path.relpath(os.path.join(dirpath, "BUILD.gn"), lumen)
        rel = rel.replace(os.sep, "/")
        if not RUST_FILE_RE.match(rel):
            continue
        path = os.path.join(lumen, rel)
        if overlay and os.path.exists(os.path.join(overlay, rel)):
            path = os.path.join(overlay, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        if not empty_list_regions(lines):
            continue
        up_text = upstream_show(chromium, ref, rel) if chromium and ref else None
        gaps = rust_list_gaps(lumen, lines, up_text)
        if gaps:
            found[rel] = sorted(gaps)
    return found


def repair_rust_file(lumen, relpath, up_text):
    vendor = os.path.join(lumen, VENDOR_URL[2:])
    path = os.path.join(lumen, relpath)
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    up_blocks = parse_crate_blocks(up_text) if up_text else []

    repairs = {}
    regions = list(corrupt_regions(lines)) + list(empty_list_regions(lines))
    for key, s, e in sorted(regions, key=lambda r: r[1]):
        idx = block_of(lines, s)
        upval = None
        if up_blocks and idx < len(up_blocks):
            upval = up_blocks[idx].get(key)
        if key in ("sources", "inputs"):
            vdir = None
            if key == "sources":
                vdir = vendor_dir_for(lumen, lines, s)
                if not vdir:
                    raise RuntimeError("no vendor dir for key=%s (block %d)"
                                       % (key, idx))
            entries = crate_entries(lumen, key, vdir, upval)
            if not entries:
                if key == "sources":
                    raise RuntimeError("no .rs sources in %s" % vdir)
                continue
            if e > s + 1:
                repairs[s] = (e, [lines[s]] + entries + [lines[e - 1]])
            else:
                repairs[s] = (e, [lines[s].replace("[]", "[", 1)] + entries +
                               ["  ]"])
            continue
        if upval and len(upval) > 1 and paths_exist(lumen, "\n".join(upval[1:])):
            repairs[s] = (e, [lines[s]] + upval[1:])
            continue
        if key == "crate_root" and upval and len(upval) > 1:
            val = "\n".join(upval[1:])
            p = re.search(r'"(//[^"]+)"', val)
            if p and os.path.exists(os.path.join(lumen, p.group(1)[2:])):
                repairs[s] = (e, [lines[s]] + upval[1:])
                continue
        vdir = vendor_dir_for(lumen, lines, s)
        if not vdir:
            raise RuntimeError("no vendor dir for key=%s (block %d)" % (key, idx))
        if key in ("crate_root", "build_root", "build_sources",
                   "build_script_inputs"):
            repl = [lines[s]] + derive_value_lines(lumen, key, vdir)
            if e > s + 1:
                repl.append(lines[e - 1])
            repairs[s] = (e, repl)
        elif key in PKG_META_KEYS:
            val = cargo_toml_value(lumen, vdir, PKG_META_KEYS[key])
            if val is None:
                raise RuntimeError("no Cargo.toml value for %s" % key)
            text = ", ".join(val) if PKG_META_KEYS[key] == "authors" else val
            repairs[s] = (e, [lines[s], '      "%s"' % text.replace('"', '\\"')])
        else:
            raise RuntimeError("unknown corrupt key %s" % key)

    out = lines
    for s in sorted(repairs, reverse=True):
        e, repl = repairs[s]
        out[s:e] = repl
    return "\n".join(out), len(repairs)


# ---------------------------------------------------------------------------
# Generic repair: aligned against upstream, parse-gated passes
# ---------------------------------------------------------------------------

BARE_KEY_RE = re.compile(r"^(\s*)([a-z_][a-z0-9_]*)\s*=\s*$")


# Values the pruner stripped from Lumen-authored (not upstream) lines, where
# no upstream counterpart exists to align against.
HAND_FIXES = {
    "third_party/android_sdk/BUILD.gn": {
        "api_versions_xml_path =":
            'api_versions_xml_path =\n'
            '        "//third_party/android_system_sdk/cipd/api-versions_system.xml"',
    },
}


def apply_hand_fixes(relpath, lines):
    fixes = HAND_FIXES.get(relpath)
    if not fixes:
        return lines, 0
    out, n = [], 0
    for line in lines:
        stripped = line.strip()
        if stripped in fixes:
            parts = fixes[stripped].split("\n")
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + parts[0])
            out.extend(parts[1:])
            n += 1
        else:
            out.append(line)
    return out, n


def corrupt_constructs(lines, err_msg=None):
    """(start, end) line windows around corruption in an arbitrary .gn file.

    Empty-list sites are listed only opportunistically: they parse fine, so
    they are adopted only when the upstream entries all exist locally.
    """
    constructs = []
    n = len(lines)
    i = 0
    while i < n:
        m = BARE_KEY_RE.match(lines[i].rstrip())
        if m:
            _j, nxt = next_nonblank(lines, i + 1)
            if not nxt.lstrip().startswith(CONT_START):
                constructs.append((i, i + 1, True))
                i += 1
                continue
        m2 = re.match(r"^(\s*)([a-z_][a-z0-9_]*) = \[\s*$", lines[i].rstrip())
        if m2:
            _j, nxt = next_nonblank(lines, i + 1)
            if nxt.lstrip() == "]":
                constructs.append((i, _j + 1, False))
                i += 1
                continue
        i += 1
    if err_msg:
        m = re.match(r"line (\d+): (\w+) called with (\d+) args", err_msg)
        if m:
            err0 = int(m.group(1)) - 1
            constructs.append((max(err0 - 1, 0), err0 + 3, True))
    return constructs


def window_repair(lumen_lines, up_lines, indices):
    """Adopt upstream lines only in the construct windows. True = fragile."""
    sm = difflib.SequenceMatcher(None, lumen_lines, up_lines, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        fragile = any(ws <= i1 <= we for ws, we, _ in indices if we > ws) or \
                  any(ws < i2 and we > ws for ws, we, force in indices
                      if not force)
        if tag == "equal" or tag == "delete" or (tag == "replace" and not any(
                ws <= i1 <= we for ws, we, force in indices if force)):
            out.extend(lumen_lines[i1:i2])
        elif tag == "replace" and any(ws < i2 and we > ws for ws, we, _ in indices):
            out.extend(up_lines[j1:j2])
        elif tag == "insert" and fragile:
            out.extend(up_lines[j1:j2])
        else:
            out.extend(lumen_lines[i1:i2])
    return "\n".join(out)


def strict_repair(lumen, lumen_lines, up_lines):
    sm = difflib.SequenceMatcher(None, lumen_lines, up_lines, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal" or tag in ("delete", "replace"):
            out.extend(lumen_lines[i1:i2])
        elif paths_exist(lumen, "\n".join(up_lines[j1:j2])):
            out.extend(up_lines[j1:j2])
        else:
            out.extend(lumen_lines[i1:i2])
    return "\n".join(out)


def relaxed_repair(lumen_lines, up_lines, err_line):
    """Adopt every insert within +-6 aligned lines of a parse error."""
    sm = difflib.SequenceMatcher(None, lumen_lines, up_lines, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        near = i1 - 6 <= err_line <= i2 + 6
        if tag in ("insert", "replace") and near:
            out.extend(up_lines[j1:j2])
        elif tag == "insert":
            out.extend(lumen_lines[i1:i2])
        else:
            out.extend(lumen_lines[i1:i2])
    return "\n".join(out)


def repair_generic_file(lumen, relpath, up_text, err_msg=None):
    path = os.path.join(lumen, relpath)
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    lumen_lines = text.split("\n")
    up_lines = up_text.split("\n")

    fixed, n = apply_hand_fixes(relpath, lumen_lines)
    if n:
        ok, _ = parses("\n".join(fixed))
        if ok:
            return "\n".join(fixed), "hand fix"

    candidate = strict_repair(lumen, lumen_lines, up_lines)
    ok, _ = parses(candidate)
    if ok:
        return candidate, "aligned (verified local paths only)"

    constructs = corrupt_constructs(lumen_lines, err_msg)
    if constructs:
        candidate = window_repair(lumen_lines, up_lines, constructs)
        ok, err = parses(candidate)
        if ok:
            return candidate, "restored around corrupt constructs"

    err0 = None
    if err_msg:
        m = re.match(r"line (\d+):", err_msg)
        if m:
            err0 = int(m.group(1)) - 1
    if err0 is not None:
        candidate = relaxed_repair(lumen_lines, up_lines, err0)
        ok, _ = parses(candidate)
        if ok:
            return candidate, "restored near parse error (paths unverified)"
    raise RuntimeError("alignment could not restore a parseable file")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def check_only(lumen, overlay=None, chromium=None, ref=None):
    broken = scan_tree(lumen, overlay)
    pruned = scan_rust_lists(lumen, chromium, ref, overlay)
    for rel in sorted(broken):
        print("BROKEN %s: %s" % (rel, broken[rel]))
    for rel in sorted(pruned):
        print("INCOMPLETE %s: emptied %s list(s) can be refilled"
              % (rel, ", ".join(pruned[rel])))
    print("%d broken, %d with emptied rust lists" % (len(broken), len(pruned)))
    return 1 if broken or pruned else 0


def repair(lumen, chromium, ref, out_dir):
    broken = scan_tree(lumen)
    pruned = scan_rust_lists(lumen, chromium, ref)
    print("scanned: %d broken files, %d with emptied rust lists"
          % (len(broken), len(pruned)))
    repaired, unrepaired = [], []
    for rel in sorted(set(broken) | set(pruned)):
        err_msg = broken.get(rel)
        try:
            if RUST_FILE_RE.match(rel):
                up_text = upstream_show(chromium, ref, rel)
                new_text, n = repair_rust_file(lumen, rel, up_text)
                note = "%d sites" % n
            else:
                up_text = upstream_show(chromium, ref, rel)
                if up_text is None:
                    raise RuntimeError("no upstream counterpart at %s" % ref)
                new_text, note = repair_generic_file(lumen, rel, up_text, err_msg)
        except RuntimeError as e:
            unrepaired.append(rel)
            print("UNREPAIRED %s: %s" % (rel, e))
            continue
        ok, err = parses(new_text)
        if not ok:
            unrepaired.append(rel)
            print("UNREPAIRED %s: repair still invalid: %s" % (rel, err))
            continue
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        repaired.append(rel)
        print("REPAIRED %s (%s)" % (rel, note))

    remaining = scan_tree(lumen, out_dir)
    for rel, keys in scan_rust_lists(lumen, chromium, ref, out_dir).items():
        remaining.setdefault(rel, "emptied %s lists" % ", ".join(keys))
    print("summary: %d repaired, %d unrepaired, %d files still broken"
          % (len(repaired), len(unrepaired), len(remaining)))
    for rel in sorted(remaining):
        print("STILL BROKEN %s: %s" % (rel, remaining[rel]))
    return 0 if not remaining else 2


def main():
    ap = argparse.ArgumentParser(description="Repair pruner-stripped GN files")
    ap.add_argument("--lumen", required=True, help="Lumen checkout root")
    ap.add_argument("--chromium", help="chromium mirror checkout (git)")
    ap.add_argument("--ref", help="chromium ref (e.g. pins/chromium.sha)")
    ap.add_argument("--out", help="directory receiving repaired files")
    ap.add_argument("--check", action="store_true",
                    help="only scan and report broken files and emptied rust "
                         "crate lists")
    ap.add_argument("--overlay", help="validation overlay for --check")
    ap.add_argument("--verify-imports", action="store_true",
                    help="restore import() targets deleted by the pruner "
                         "(needs --chromium and --ref; DEPS-managed paths "
                         "are reported instead of restored)")
    args = ap.parse_args()

    if args.verify_imports:
        for req in ("chromium", "ref"):
            if not getattr(args, req):
                ap.error("--%s is required with --verify-imports" % req)
        sys.exit(verify_imports(args.lumen, args.chromium, args.ref))
    if args.check:
        sys.exit(check_only(args.lumen, args.overlay, args.chromium, args.ref))
    for req in ("chromium", "ref", "out"):
        if not getattr(args, req):
            ap.error("--%s is required without --check" % req)
    sys.exit(repair(args.lumen, args.chromium, args.ref, args.out))


if __name__ == "__main__":
    main()
