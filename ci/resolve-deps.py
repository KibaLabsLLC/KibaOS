#!/usr/bin/env python3
"""gclient-free DEPS resolver for the KibaOS Lumen bootstrap.

Reads <root>/src/DEPS (plus any recursedeps DEPS files), then:
  * fetches git, cipd and gcs dependencies,
  * writes gclient_gn_args_file (e.g. src/build/config/gclient_args.gni),
  * runs pre_deps_hooks and hooks.

The default target is the linux desktop build. Ash, Aura, the linux host
dependencies, and the ChromeOS-specific Chromium dependencies they need to
compile are kept, as is the ChromeOS GN configuration (cros_boards stays at
its empty DEPS default). What only a device build needs is skipped: the
cros_boards board SDKs, Simple Chrome and device SDK setup (including the
chromite CrOS SDK), and the Tast test hooks. Android, iOS, Windows and
macOS-only dependencies stay out unless --target-os asks for them.

Requires python3 (>= 3.8) and git. cipd is only needed if DEPS contains cipd
dependencies (it ships with depot_tools; gclient itself is never run).
"""
import argparse
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

OS_NAMES = ("android", "chromeos", "fuchsia", "ios", "linux", "mac", "win")
CPU_NAMES = ("arm", "arm64", "x86", "x64", "mips", "mips64", "ppc", "s390",
             "loong64", "riscv64")

DESKTOP_SKIP_DEP_PATHS = ("src/third_party/chromite",)
DESKTOP_SKIP_HOOKS = ("tast_control_cq_tests", "ensure_node_modules")

# A variable value that is a condition expression rather than a literal
# string (gclient's idiom, e.g. '"{cros_boards}" != ""').
COND_VALUE_RE = re.compile(r"==|!=|>=|<=|<|>|\band\b|\bor\b|\bnot\b")

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
URL_REV_RE = re.compile(r"^(.+)@(refs/[^@:]+|[^@:/]+)$")
VAR_RE = re.compile(r"\{([\w.\-]+)\}")
CIPD_VAR_RE = re.compile(r"\$\{\{(\w+)\}\}")

GCS_BASE = os.environ.get("KIBAOS_GCS_BASE",
                          "https://storage.googleapis.com").rstrip("/")
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_LFS_SKIP_SMUDGE="1")


class ResolveError(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print("warning: " + msg, file=sys.stderr, flush=True)


def die(msg):
    print("error: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


# --------------------------------------------------------------------------
# Host / variable handling
# --------------------------------------------------------------------------

def host_os():
    return {"linux": "linux", "darwin": "mac", "windows": "win"}.get(
        platform.system().lower(), platform.system().lower())


def host_cpu():
    return {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64",
            "arm64": "arm64", "i386": "x86", "i686": "x86"}.get(
        platform.machine().lower(), platform.machine().lower())


def builtin_vars(target_os, target_cpu):
    """The variables gclient provides to DEPS files and conditions."""
    v = {"host_os": host_os(), "host_cpu": host_cpu(),
         "target_os": list(target_os), "target_cpu": list(target_cpu)}
    for n in OS_NAMES:
        v["checkout_" + n] = n in target_os
    for n in CPU_NAMES:
        v["checkout_" + n] = n in target_cpu
    return v


def parse_value(text):
    low = text.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def parse_overrides(items):
    out = {}
    for item in items:
        key, sep, value = item.partition("=")
        if not sep or not key:
            die("--var needs NAME=VALUE, got %r" % item)
        out[key] = parse_value(value)
    return out


def sub_vars(text, vars_):
    """Expand {name} placeholders (what Var('name') evaluates to)."""
    def repl(m):
        name = m.group(1)
        if name in vars_ and not isinstance(vars_[name], (list, dict)):
            return str(vars_[name])
        return m.group(0)

    for _ in range(10):
        new = VAR_RE.sub(repl, text)
        if new == text:
            break
        text = new
    return text


class Scope(dict):
    """Condition namespace: unknown names are False, and are recorded.

    A variable whose value is a condition expression is evaluated
    recursively (gclient does the same), so derived variables such as
    checkout_simplechrome resolve to a boolean instead of a truthy string.
    """

    def __init__(self, data, missing, resolver, resolving):
        super().__init__(data)
        self._missing = missing
        self._resolver = resolver
        self._resolving = resolving

    def __missing__(self, key):
        self._missing.add(key)
        return False

    def __getitem__(self, key):
        value = super().__getitem__(key)
        if isinstance(value, str) and COND_VALUE_RE.search(value):
            if key in self._resolving:
                raise ResolveError("cyclic variable reference: %s" % key)
            return self._resolver.cond(
                sub_vars(value, self), self,
                self._resolving | frozenset((key,)))
        return value


def load_deps_file(path):
    # Var() returns a placeholder; it is expanded once the effective
    # variables (DEPS vars + parent + builtins + overrides) are known.
    ns = {"Var": lambda name: "{%s}" % name, "Str": lambda s: s}
    try:
        with open(path, encoding="utf-8") as f:
            code = compile(f.read(), path, "exec")
        exec(code, ns)
    except Exception as e:  # noqa: BLE001
        raise ResolveError("cannot evaluate %s: %s" % (path, e))
    return ns


# --------------------------------------------------------------------------
# Fetchers
# --------------------------------------------------------------------------

def git(args, cwd, retries=1):
    last = None
    for attempt in range(retries):
        if attempt:
            time.sleep(3 * attempt)
        proc = subprocess.run(["git"] + args, cwd=cwd, env=GIT_ENV,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True)
        if proc.returncode == 0:
            return proc.stdout.strip()
        last = proc
    raise ResolveError("git %s failed (exit %d): %s" % (
        " ".join(args), last.returncode, last.stderr.strip()[-600:]))


def split_git_url(spec):
    m = URL_REV_RE.match(spec)
    if m:
        return m.group(1), m.group(2)
    return spec, "HEAD"


def fetch_git(root, path, url, rev):
    dest = os.path.join(root, path)
    os.makedirs(dest, exist_ok=True)
    if os.path.isdir(os.path.join(dest, ".git")):
        try:
            git(["remote", "set-url", "origin", url], dest)
        except ResolveError:
            git(["remote", "add", "origin", url], dest)
        if SHA_RE.match(rev):
            try:
                if git(["rev-parse", "--verify", "-q", "HEAD"], dest) == rev:
                    return
            except ResolveError:
                pass
    else:
        git(["init", "-q"], dest)
        git(["remote", "add", "origin", url], dest)
    try:
        git(["fetch", "-q", "--no-tags", "--depth=1", "origin", rev], dest,
            retries=3)
        git(["checkout", "-q", "--detach", "--force", "FETCH_HEAD"], dest)
    except ResolveError:
        # Server refused a shallow fetch of that revision: fall back.
        git(["fetch", "-q", "--tags", "origin",
             "+refs/heads/*:refs/remotes/origin/*"], dest, retries=3)
        git(["checkout", "-q", "--detach", "--force", rev], dest)
    if SHA_RE.match(rev):
        head = git(["rev-parse", "HEAD"], dest)
        if head != rev:
            raise ResolveError("checked out %s, wanted %s" % (head, rev))


def fetch_cipd(root, path, packages, cipd):
    dest = os.path.join(root, path)
    os.makedirs(dest, exist_ok=True)
    ensure = "".join("%s %s\n" % (p["package"], p["version"])
                     for p in packages)
    proc = subprocess.run([cipd, "ensure", "-root", dest,
                           "-ensure-file", "-"],
                          input=ensure, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        raise ResolveError("cipd ensure failed (exit %d): %s" % (
            proc.returncode, proc.stdout.strip()[-600:]))


def download(url, dest, sha256, size):
    last = None
    for attempt in range(3):
        if attempt:
            time.sleep(3 * attempt)
        try:
            digest, total = hashlib.sha256(), 0
            with urllib.request.urlopen(url, timeout=120) as resp, \
                    open(dest, "wb") as out:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    digest.update(chunk)
                    out.write(chunk)
                    total += len(chunk)
            if size and total != int(size):
                raise ResolveError("size %d != expected %s" % (total, size))
            if sha256 and digest.hexdigest() != sha256:
                raise ResolveError("sha256 %s != expected %s" % (
                    digest.hexdigest(), sha256))
            return
        except Exception as e:  # noqa: BLE001
            last = e
    raise ResolveError("download of %s failed: %s" % (url, last))


def extract_tar(archive, dest):
    with tarfile.open(archive, "r:*") as tar:
        try:
            tar.extractall(dest, filter="tar")
        except TypeError:  # Python without extraction filters
            tar.extractall(dest)


def fetch_gcs(root, path, bucket, objects):
    dest = os.path.join(root, path)
    os.makedirs(dest, exist_ok=True)
    stamp = os.path.join(dest, ".kibaos-gcs-stamp")
    want = "\n".join(sorted("%s %s" % (o["object_name"], o.get("sha256sum", ""))
                            for o in objects))
    try:
        with open(stamp, encoding="utf-8") as f:
            if f.read() == want:
                return
    except OSError:
        pass
    for obj in objects:
        url = "%s/%s/%s" % (GCS_BASE, bucket,
                            urllib.parse.quote(obj["object_name"]))
        if obj.get("generation"):
            url += "?generation=%s" % obj["generation"]
        fd, tmp = tempfile.mkstemp(prefix=".gcs-", dir=dest)
        os.close(fd)
        try:
            download(url, tmp, obj.get("sha256sum"), obj.get("size_bytes"))
            if obj.get("output_file"):
                os.replace(tmp, os.path.join(dest, obj["output_file"]))
            elif tarfile.is_tarfile(tmp):
                extract_tar(tmp, dest)
            else:
                os.replace(tmp, os.path.join(
                    dest, os.path.basename(obj["object_name"])))
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    with open(stamp, "w", encoding="utf-8") as f:
        f.write(want)


# --------------------------------------------------------------------------
# gclient_gn_args_file
# --------------------------------------------------------------------------

def gn_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(gn_value(x) for x in v) + "]"
    s = str(v).replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
    return '"%s"' % s


def write_gn_args(path, names, vars_, resolver):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ["# Generated from 'DEPS' by ci/resolve-deps.py"]
    # A DEPS variable can hold a condition expression instead of a literal
    # (gclient's idiom, e.g. checkout_openxr). Evaluating the value through
    # the same scope DEPS conditions use turns those into real booleans;
    # quoting them would make GN's && on gclient_args.gni fail with "Type is
    # string instead".
    scope = Scope(vars_, resolver.missing, resolver, frozenset())
    for name in names:
        if name not in vars_:
            warn("gclient_gn_args lists %r but no such variable exists; "
                 "leaving it at its GN default" % name)
            continue
        value = scope[name]
        if isinstance(value, str):
            value = sub_vars(value, vars_)
        lines.append("%s = %s" % (name, gn_value(value)))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# Resolver
# --------------------------------------------------------------------------

class Resolver:
    def __init__(self, args):
        self.root = os.path.abspath(args.root)
        self.jobs = args.jobs
        self.skip_hooks = args.skip_hooks
        self.desktop_target = "linux" in (args.target_os or ["linux"])
        target_os = set(args.target_os or ["linux"])
        if self.desktop_target:
            # Ash and Aura need the ChromeOS-specific Chromium dependencies
            # to compile, so the desktop target checks those out too. The
            # build itself still targets linux.
            target_os.add("chromeos")
        target_cpu = args.target_cpu or [host_cpu()]
        self.base_vars = builtin_vars(sorted(target_os | {host_os()}),
                                      target_cpu)
        self.overrides = parse_overrides(args.var)
        # cros_boards stays at its DEPS default: the board SDKs and the
        # Simple Chrome setup that hang off it are not needed for the
        # desktop build. Pass --var cros_boards=<board> for a device build.
        self.cipd = args.cipd or shutil.which("cipd")
        self.skip_dep_paths = tuple(
            os.path.normpath(p) for p in (args.skip_dep_path or []))
        self.skip_hook_names = set(args.skip_hook_name or [])
        if self.desktop_target:
            self.skip_hook_names.update(DESKTOP_SKIP_HOOKS)
            if not self.overrides.get("cros_boards"):
                self.skip_dep_paths += tuple(
                    os.path.normpath(p) for p in DESKTOP_SKIP_DEP_PATHS)
        self.skip_hook_actions = list(args.skip_hook_action or [])
        self.claimed = {}       # path -> DEPS file that declared it
        self.recursed = set()   # (path, deps filename) already processed
        self.hooks = []         # (name, argv, cwd)
        self.missing = set()    # condition names that were undefined

    # ---- helpers ---------------------------------------------------------

    def effective_vars(self, ns, parent_vars):
        # gclient precedence, lowest first: DEPS vars, parent, builtins,
        # command-line overrides.
        v = dict(ns.get("vars", {}))
        v.update(parent_vars)
        v.update(self.base_vars)
        v.update(self.overrides)
        return v

    def cond(self, expr, vars_, resolving=frozenset()):
        if not expr:
            return True
        try:
            return bool(eval(sub_vars(expr, vars_), {"__builtins__": {}},
                             Scope(vars_, self.missing, self, resolving)))
        except ResolveError:
            raise
        except Exception as e:  # noqa: BLE001
            raise ResolveError("cannot evaluate condition %r: %s" % (expr, e))

    def hook_env(self):
        env = dict(os.environ, DEPOT_TOOLS_UPDATE="0")
        depot = os.path.join(self.root, "src", "third_party", "depot_tools")
        if os.path.isdir(depot):
            env["PATH"] = env.get("PATH", "") + os.pathsep + depot
        return env

    def make_hook(self, hook, vars_, cwd):
        action = [sub_vars(a, vars_) if isinstance(a, str) else a
                  for a in hook["action"]]
        if action and action[0] == "python3":
            action[0] = sys.executable
        return (hook.get("name") or os.path.basename(str(action[0])),
                action, cwd)

    def run_hook(self, hook):
        name, action, cwd = hook
        if name in self.skip_hook_names:
            log("==> hook: %s (skipped)" % name)
            return
        if self.skip_hook_actions:
            action_str = " ".join(str(a) for a in action)
            for pattern in self.skip_hook_actions:
                if pattern in action_str:
                    log("==> hook: %s (skipped, action matches %r)" % (name, pattern))
                    return
        log("==> hook: %s" % name)
        try:
            proc = subprocess.run(action, cwd=cwd, env=self.hook_env())
        except OSError as e:
            raise ResolveError("hook %s could not start: %s" % (name, e))
        if proc.returncode != 0:
            raise ResolveError("hook %s failed (exit %d): %s" % (
                name, proc.returncode, " ".join(map(str, action))))

    def run_task(self, task):
        kind, path = task[0], task[1]
        if kind == "git":
            log("  git   %s @ %s" % (path, task[3][:12]))
            fetch_git(self.root, path, task[2], task[3])
        elif kind == "cipd":
            log("  cipd  %s" % path)
            fetch_cipd(self.root, path, task[2], self.cipd)
        else:
            log("  gcs   %s" % path)
            fetch_gcs(self.root, path, task[2], task[3])

    def run_tasks(self, tasks):
        # Shallowest paths first, so a parent checkout never races a
        # dependency nested inside it.
        levels = {}
        for t in tasks:
            levels.setdefault(t[1].count("/"), []).append(t)
        errors = []
        for depth in sorted(levels):
            with ThreadPoolExecutor(max_workers=self.jobs) as pool:
                futures = {pool.submit(self.run_task, t): t
                           for t in levels[depth]}
                for fut in as_completed(futures):
                    try:
                        fut.result()
                    except Exception as e:  # noqa: BLE001
                        errors.append("%s: %s" % (futures[fut][1], e))
            if errors:
                break
        if errors:
            raise ResolveError("dependency sync failed:\n  " +
                               "\n  ".join(errors))

    # ---- main walk ------------------------------------------------------

    def process(self, deps_file, prefix, parent_vars):
        log("==> DEPS: %s" % os.path.relpath(deps_file, self.root))
        ns = load_deps_file(deps_file)
        vars_ = self.effective_vars(ns, parent_vars)
        rel = bool(ns.get("use_relative_paths"))
        base = prefix if rel else ""

        def full(key):
            p = os.path.normpath(os.path.join(base, key))
            if p.startswith("..") or os.path.isabs(p):
                raise ResolveError("dependency path escapes root: %s" % key)
            return p

        if not self.skip_hooks:
            for h in ns.get("pre_deps_hooks", []):
                if self.cond(h.get("condition"), vars_):
                    self.run_hook(self.make_hook(h, vars_, self.root))

        tasks, active = [], set()
        for key, spec in ns.get("deps", {}).items():
            if spec is None:
                continue
            if isinstance(spec, str):
                spec = {"url": spec}
            if not self.cond(spec.get("condition"), vars_):
                continue
            path = full(key)
            active.add(path)
            if any(path == sp or path.startswith(sp + os.sep)
                   for sp in self.skip_dep_paths):
                log("  skip  %s" % path)
                continue
            if path in self.claimed:
                continue  # an ancestor DEPS already owns this path
            self.claimed[path] = deps_file
            kind = spec.get("dep_type", "git")
            if kind == "git":
                if not spec.get("url"):
                    raise ResolveError("git dep %s has no url" % key)
                url, rev = split_git_url(sub_vars(spec["url"], vars_))
                tasks.append(("git", path, url, rev))
            elif kind == "cipd":
                pkgs = [{"package": CIPD_VAR_RE.sub(
                             r"${\1}", sub_vars(p["package"], vars_)),
                         "version": sub_vars(p["version"], vars_)}
                        for p in spec["packages"]]
                tasks.append(("cipd", path, pkgs))
            elif kind == "gcs":
                objs = [o for o in spec["objects"]
                        if self.cond(o.get("condition"), vars_)]
                if objs:
                    tasks.append(("gcs", path, sub_vars(spec["bucket"], vars_),
                                  objs))
            else:
                raise ResolveError("unknown dep_type %r for %s" % (kind, key))

        if any(t[0] == "cipd" for t in tasks) and not self.cipd:
            names = ", ".join(t[1] for t in tasks if t[0] == "cipd")
            raise ResolveError(
                "DEPS has cipd dependencies (%s) but no cipd binary was "
                "found. Put depot_tools on PATH (KIBAOS_DEPOT_TOOLS) or "
                "pass --cipd." % names)

        self.run_tasks(tasks)

        gn_file = ns.get("gclient_gn_args_file")
        if gn_file:
            out = os.path.join(self.root, gn_file)
            gn_args = list(ns.get("gclient_gn_args", []))
            write_gn_args(out, gn_args, vars_, self)
            log("  wrote %s" % gn_file)

        hooks_cwd = (os.path.join(self.root, prefix)
                     if rel and ns.get("use_relative_hooks") else self.root)
        for h in ns.get("hooks", []):
            if self.cond(h.get("condition"), vars_):
                self.hooks.append(self.make_hook(h, vars_, hooks_cwd))

        children = []
        for entry in ns.get("recursedeps", []):
            if isinstance(entry, str):
                name, fname = entry, "DEPS"
            else:
                name, fname = entry[0], entry[1]
            path = full(name)
            if path not in active or (path, fname) in self.recursed:
                continue
            child = os.path.join(self.root, path, fname)
            if os.path.isfile(child):
                self.recursed.add((path, fname))
                children.append((child, path, vars_))
        return children

    def run(self):
        top = os.path.join(self.root, "src", "DEPS")
        if not os.path.isfile(top):
            raise ResolveError("%s not found" % top)
        if self.desktop_target:
            log("==> linux desktop target: keeping Ash, Aura and the "
                "ChromeOS Chromium dependencies; skipping board SDKs, "
                "Simple Chrome/device SDK setup and Tast hooks")
        queue = [(top, "src", {})]
        while queue:
            deps_file, prefix, parent_vars = queue.pop(0)
            queue.extend(self.process(deps_file, prefix, parent_vars))

        if self.missing:
            warn("conditions used undefined variables (treated as False): " +
                 ", ".join(sorted(self.missing)))

        if self.skip_hooks:
            log("==> hooks skipped")
            return
        for hook in self.hooks:
            self.run_hook(hook)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", required=True,
                    help="directory that holds src/ (the checkout parent)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--var", action="append", default=[],
                    metavar="NAME=VALUE", help="override a DEPS variable")
    ap.add_argument("--target-os", action="append", default=None,
                    help="target OS (repeatable); default: linux, which "
                         "also checks out the ChromeOS-specific Chromium "
                         "dependencies the desktop build needs")
    ap.add_argument("--target-cpu", action="append", default=None,
                    help="target CPU (repeatable); default: host CPU")
    ap.add_argument("--cipd", help="path to the cipd binary")
    ap.add_argument("--skip-hooks", action="store_true")
    ap.add_argument("--skip-dep-path", action="append", default=None,
                    metavar="PATH_PREFIX",
                    help="skip any dep whose path starts with this prefix "
                         "(repeatable; relative to root)")
    ap.add_argument("--skip-hook-name", action="append", default=None,
                    metavar="HOOK_NAME",
                    help="skip the named hook entirely (repeatable)")
    ap.add_argument("--skip-hook-action", action="append", default=None,
                    metavar="SUBSTRING",
                    help="skip any hook whose action contains this substring "
                         "(repeatable)")
    args = ap.parse_args()
    if args.jobs < 1:
        die("--jobs must be >= 1")
    try:
        Resolver(args).run()
    except ResolveError as e:
        die(str(e))


if __name__ == "__main__":
    main()
