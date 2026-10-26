"""Module system (Phase 2 scaffolding).

Resolves import statements to files on disk and caches loaded modules.
"""

import os
from typing import Dict, Optional


class ModuleLoader:
    def __init__(self, search_paths=None):
        import sys, site
        paths = list(search_paths or ["."])
        try:
            paths += site.getsitepackages()
        except Exception:
            pass
        try:
            paths.append(site.getusersitepackages())
        except Exception:
            pass
        # also PYTHONPATH
        for pth in os.environ.get("PYTHONPATH", "").split(os.pathsep):
            if pth:
                paths.append(pth)
        from .pip import get_default_site_packages
        luthon_site = str(get_default_site_packages())
        if luthon_site not in paths:
            paths.append(luthon_site)
        self.search_paths = paths
        self.cache: Dict[str, object] = {}
        self._deps: Dict[str, tuple] = {}

    def find(self, name: str) -> Optional[str]:
        parts = name.split(".")
        for base in self.search_paths:
            # package dir with __init__.py
            pkg_dir = os.path.join(base, *parts)
            init = os.path.join(pkg_dir, "__init__.py")
            if os.path.isfile(init):
                return init
            # module file
            cand = os.path.join(base, *parts[:-1], parts[-1] + ".py") if len(parts) > 1 else os.path.join(base, parts[0] + ".py")
            if os.path.isfile(cand):
                return cand
        return None

    def load(self, name: str):
        if name in self.cache:
            return self.cache[name]

    def loaded_deps(self):
        return dict(self._deps)
        path = self.find(name)
        if path is None:
            raise ImportError(f"module not found: {name}")
        source = open(path).read()
        # execute via transpiler into a fresh namespace
        from .transpiler import transpile
        code = transpile(source)
        ns = {"__name__": name, "__file__": path}
        exec(compile(code, path, "exec"), ns)
        self.cache[name] = ns
        try:
            import hashlib
            h = hashlib.sha256(open(path,"rb").read()).hexdigest()
            self._deps[name] = (path, h)
        except OSError:
            pass
        return ns
