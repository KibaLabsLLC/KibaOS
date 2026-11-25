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
            # Lumen builds target the amd64-generic ChromeOS board. Include
            # this even when the DEPS file does not list it explicitly.
            if "cros_boards" not in gn_args:
                gn_args.append("cros_boards")
            write_gn_args(out, gn_args, vars_)
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
                    help="target OS (repeatable); default: chromeos")
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

