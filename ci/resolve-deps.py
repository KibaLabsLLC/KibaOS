#!/usr/bin/env python3
"""Minimal gclient-free DEPS resolver: git deps, optional cipd, hooks."""
import argparse, os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor


class Env(dict):
    def __missing__(self, key):
        return False  # unknown checkout_* names evaluate to False


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--root", required=True)   # holds src/
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--var", action="append", default=[])
    p.add_argument("--skip-hooks", action="store_true")
    return p.parse_args()


def load_deps(path, overrides):
    harvest = {}
    ns = {"Var": lambda n: "", "Str": lambda s: s}
    exec(open(path).read(), ns)
    harvest.update(ns.get("vars", {}))
    harvest.update(overrides)

    ns = {"Var": lambda n: harvest[n], "Str": lambda s: s}
    exec(open(path).read(), ns)
    base = dict(
        host_os="linux", host_cpu="x64", checkout_linux=True,
        checkout_chromeos=True, checkout_x64=True, True=True,
        False=False, None=None,
    )
    cond_env = Env({**base, **harvest})
    return ns, harvest, cond_env


def cond_ok(cond, env):
    return True if not cond else bool(eval(cond, {}, env))


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL)


def fetch_git(root, path, url, rev):
    d = os.path.join(root, path)
    os.makedirs(d, exist_ok=True)
    if not os.path.isdir(os.path.join(d, ".git")):
        git("init", "-q", cwd=d)
        git("remote", "add", "origin", url, cwd=d)
    else:
        git("remote", "set-url", "origin", url, cwd=d)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=d,
                          capture_output=True, text=True).stdout.strip()
    if head == rev:
        return
    try:
        git("fetch", "-q", "--depth=1", "origin", rev, cwd=d)
        git("checkout", "-q", "--detach", "--force", "FETCH_HEAD", cwd=d)
    except subprocess.CalledProcessError:
        git("fetch", "-q", "origin", cwd=d)
        git("checkout", "-q", "--detach", "--force", rev, cwd=d)


def fetch_cipd(root, path, packages):
    lines = "".join(f"{p['package']} {p['version']}\n" for p in packages)
    subprocess.run(["cipd", "ensure", "-root", os.path.join(root, path),
                    "-ensure-file", "-"], input=lines, text=True, check=True)


def main():
    a = parse_args()
    root = os.path.abspath(a.root)
    overrides = {}
    for kv in a.var:
        k, v = kv.split("=", 1)
        overrides[k] = {"True": True, "False": False}.get(v, v)

    top_deps = os.path.join(root, "src", "DEPS")
    queue = [(top_deps, "")]
    seen, hooks, skipped = set(), [], []
    top_ns = top_env = None
    have_cipd = shutil.which("cipd") is not None

    while queue:
        deps_file, prefix = queue.pop(0)
        ns, vars_, env = load_deps(deps_file, overrides)
        if top_ns is None:
            top_ns, top_env = ns, env
        rel = bool(ns.get("use_relative_paths"))
        base = prefix if rel else ""

        tasks, nxt = [], []
        for key, spec in ns.get("deps", {}).items():
            if isinstance(spec, str):
                spec = {"url": spec, "dep_type": "git"}
            if not cond_ok(spec.get("condition"), env):
                continue
            path = os.path.join(base, key) if base else key
            if path in seen:
                continue
            seen.add(path)
            kind = spec.get("dep_type", "git")
            if kind == "git":
                url, _, rev = spec["url"].format(**vars_).rpartition("@")
                if not url:
                    url, rev = rev, "HEAD"
                tasks.append(("git", path, url, rev))
            elif kind == "cipd" and have_cipd:
                tasks.append(("cipd", path, spec["packages"]))
            else:
                skipped.append(f"{kind}: {path}")

        def run(t):
            print(f"  {t[0]}: {t[1]}", flush=True)
            if t[0] == "git":
                fetch_git(root, t[1], t[2], t[3])
            else:
                fetch_cipd(root, t[1], t[2])

        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            list(ex.map(run, tasks))

        for h in ns.get("hooks", []):
            if cond_ok(h.get("condition"), env):
                cwd = os.path.join(root, prefix) if rel else root
                hooks.append((h.get("name", "hook"), h["action"], cwd))

        for entry in ns.get("recursedeps", []):
            name, fname = (entry, "DEPS") if isinstance(entry, str) else entry
            f = os.path.join(root, name, fname)
            if os.path.isfile(f):
                queue.append((f, name))

    # Equivalent of gclient's gclient_gn_args_file.
    gn_file = top_ns.get("gclient_gn_args_file")
    if gn_file:
        out = os.path.join(root, gn_file)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w") as f:
            f.write("# Generated by resolve-deps.py\n")
            for name in top_ns.get("gclient_gn_args", []):
                v = top_env[name]
                if isinstance(v, bool):
                    v = "true" if v else "false"
                elif isinstance(v, str):
                    v = '"%s"' % v
                f.write(f"{name} = {v}\n")

    if skipped:
        print("warning: skipped (need cipd/gcs support):", file=sys.stderr)
        for s in skipped:
            print("  " + s, file=sys.stderr)

    if not a.skip_hooks:
        for name, action, cwd in hooks:
            print(f"==> hook: {name}", flush=True)
            subprocess.run(action, cwd=cwd, check=True)


if __name__ == "__main__":
    main()
