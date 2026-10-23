"""Persistent compilation cache for Luthon."""

import hashlib
import json
import os
from pathlib import Path

LUTHON_VERSION = "0.1.0"


def _path_hash(path):
    return hashlib.sha256(str(path).encode()).hexdigest()[:16]


def _content_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


class CompilationCache:
    def __init__(self, cache_dir=None):
        self.cache_dir = Path(cache_dir) if cache_dir else Path(".luthon_cache")
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _entry_dir(self, path):
        return self.cache_dir / _path_hash(path)

    def lookup(self, path, deps=None):
        deps = deps or {}
        entry = self._entry_dir(path)
        meta_path = entry / "meta.json"
        out_path = entry / "output.lua"
        if not meta_path.exists() or not out_path.exists():
            return None
        try:
            meta = json.loads(meta_path.read_text())
        except (json.JSONDecodeError, OSError):
            return None
        if meta.get("version") != LUTHON_VERSION:
            return None
        # fast check: stat
        try:
            st = os.stat(path)
        except OSError:
            return None
        stat_match = (meta.get("mtime") == getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)) and meta.get("size") == st.st_size)
        if stat_match:
            # verify content hash for correctness
            try:
                ch = _content_hash(path)
            except OSError:
                return None
            if ch == meta.get("content_hash"):
                # check deps
                for name, dh in (meta.get("deps") or {}).items():
                    pass
                try:
                    return out_path.read_text()
                except OSError:
                    return None
            return None
        # correctness check: content hash
        try:
            ch = _content_hash(path)
        except OSError:
            return None
        if ch != meta.get("content_hash"):
            return None
        # check deps
        for name, (dpath, dhash) in (deps or {}).items():
            try:
                if _content_hash(dpath) != dhash:
                    return None
            except OSError:
                return None
        try:
            return out_path.read_text()
        except OSError:
            return None

    def store(self, path, lua, deps=None):
        deps = deps or {}
        entry = self._entry_dir(path)
        entry.mkdir(parents=True, exist_ok=True)
        try:
            st = os.stat(path)
        except OSError:
            return
        meta = {
            "version": LUTHON_VERSION,
            "mtime": getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)),
            "size": st.st_size,
            "content_hash": _content_hash(path),
            "deps": {k: v[1] for k, v in (deps or {}).items()},
        }
        meta_path = entry / "meta.json"
        out_path = entry / "output.lua"
        tmp_meta = entry / "meta.json.tmp"
        tmp_out = entry / "output.lua.tmp"
        tmp_out.write_text(lua)
        tmp_meta.write_text(json.dumps(meta))
        os.replace(tmp_out, out_path)
        os.replace(tmp_meta, meta_path)

    def invalidate(self, path):
        import shutil
        entry = self._entry_dir(path)
        if entry.exists():
            shutil.rmtree(entry)
