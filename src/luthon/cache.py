"""Persistent compilation cache for Luthon."""

import hashlib
import json
import os
from pathlib import Path

LUTHON_VERSION = "0.1.0"

_CACHED_COMPILER_HASH = None


def _compiler_hash():
    """Hash all source files in the luthon package to automatically invalidate cache on compiler changes."""
    global _CACHED_COMPILER_HASH
    if _CACHED_COMPILER_HASH is not None:
        return _CACHED_COMPILER_HASH
    pkg_dir = Path(__file__).parent
    h = hashlib.sha256()
    try:
        for p in sorted(pkg_dir.rglob("*.py")):
            h.update(p.read_bytes())
        for p in sorted(pkg_dir.rglob("*.lua")):
            h.update(p.read_bytes())
        _CACHED_COMPILER_HASH = h.hexdigest()[:16]
    except Exception:
        _CACHED_COMPILER_HASH = LUTHON_VERSION
    return _CACHED_COMPILER_HASH


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
        if meta.get("version") != LUTHON_VERSION or meta.get("compiler_hash") != _compiler_hash():
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
            "compiler_hash": _compiler_hash(),
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

    def get_cached_output_path(self, path):
        """Returns the Path to output.lua if cache entry is valid, else None."""
        entry = self._entry_dir(path)
        meta_path = entry / "meta.json"
        out_path = entry / "output.lua"
        if not meta_path.exists() or not out_path.exists():
            return None
        try:
            meta = json.loads(meta_path.read_text())
        except (json.JSONDecodeError, OSError):
            return None
        if meta.get("version") != LUTHON_VERSION or meta.get("compiler_hash") != _compiler_hash():
            return None
        try:
            st = os.stat(path)
        except OSError:
            return None
        stat_match = (meta.get("mtime") == getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)) and meta.get("size") == st.st_size)
        if stat_match:
            try:
                ch = _content_hash(path)
            except OSError:
                return None
            if ch == meta.get("content_hash"):
                return out_path
            return None
        try:
            ch = _content_hash(path)
        except OSError:
            return None
        if ch == meta.get("content_hash"):
            return out_path
        return None

    def invalidate(self, path):
        import shutil
        entry = self._entry_dir(path)
        if entry.exists():
            shutil.rmtree(entry)
