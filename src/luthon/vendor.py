"""Luthon Package Vendor & Transpiler Tool.

Takes Python library source code, packages, or wheels and transpiles them
ahead-of-time (AOT) into standalone pure Lua modules stored in a repository
or project site-packages directory. This enables running third-party Python
libraries under LuaJIT without dependency on external CPython runtimes.
"""

from __future__ import annotations

import io
import os
import re
import shutil
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


@dataclass
class TranspileStats:
    total_files: int = 0
    succeeded_files: int = 0
    failed_files: int = 0
    total_bytes_py: int = 0
    total_bytes_lua: int = 0
    errors: Dict[str, str] = field(default_factory=dict)


class PackageVendor:
    """Converts Python packages and modules into precompiled Lua libraries."""

    def __init__(
        self,
        target_dir: Optional[Path] = None,
        optimize: bool = True,
        sourcemap: bool = False,
    ):
        if target_dir is None:
            # Default to repo vendor dir: src/luthon/vendor or project ./vendor
            base_src = Path(__file__).parent
            self.target_dir = base_src / "vendor"
        else:
            self.target_dir = Path(target_dir)

        self.optimize = optimize
        self.sourcemap = sourcemap
        self.target_dir.mkdir(parents=True, exist_ok=True)

    def vendor_from_source(
        self,
        source_path: Path,
        package_name: Optional[str] = None,
        clean: bool = False,
    ) -> TranspileStats:
        """Transpiles a local Python file or directory tree into the vendor target."""
        source_path = Path(source_path).resolve()
        if not source_path.exists():
            raise FileNotFoundError(f"Source path not found: {source_path}")

        stats = TranspileStats()

        if source_path.is_file():
            if source_path.suffix == ".whl" or (source_path.suffix == ".zip"):
                return self.vendor_from_wheel(source_path, clean=clean)
            elif source_path.suffix == ".py":
                pkg_name = package_name or source_path.stem
                dest_lua = self.target_dir / f"{pkg_name}.lua"
                self._transpile_single_file(source_path, dest_lua, stats)
                return stats
            else:
                raise ValueError(f"Unsupported file type: {source_path}")

        # Directory source (e.g., package folder)
        pkg_name = package_name or source_path.name
        dest_pkg_dir = self.target_dir / pkg_name

        if clean and dest_pkg_dir.exists():
            shutil.rmtree(dest_pkg_dir)
        dest_pkg_dir.mkdir(parents=True, exist_ok=True)

        for root, dirs, files in os.walk(source_path):
            # Skip hidden, test, and cache directories
            dirs[:] = [
                d
                for d in dirs
                if not d.startswith(".")
                and d != "__pycache__"
                and not d.endswith(".egg-info")
            ]

            rel_root = Path(root).relative_to(source_path)
            target_sub = dest_pkg_dir / rel_root
            target_sub.mkdir(parents=True, exist_ok=True)

            for f in files:
                if f.endswith(".py"):
                    src_f = Path(root) / f
                    stem = Path(f).stem
                    # __init__.py -> __init__.lua (plus init.lua alias)
                    out_name = "__init__.lua" if stem == "__init__" else f"{stem}.lua"
                    dest_f = target_sub / out_name

                    # Compute python package name for relative import resolution
                    rel_parts = list(rel_root.parts) if rel_root.parts else []
                    if stem == "__init__":
                        current_pkg = ".".join([pkg_name] + rel_parts)
                    else:
                        current_pkg = ".".join([pkg_name] + rel_parts)
                    ok = self._transpile_single_file(src_f, dest_f, stats, package=current_pkg)
                    if ok and stem == "__init__":
                        # Provide init.lua alias for standard Lua package.path conventions
                        init_alias = target_sub / "init.lua"
                        try:
                            init_alias.write_text(dest_f.read_text(encoding="utf-8"), encoding="utf-8")
                        except Exception:
                            pass

        self._generate_package_manifest(dest_pkg_dir, pkg_name, stats)
        return stats

    def vendor_from_wheel(self, wheel_path: Path, clean: bool = False) -> TranspileStats:
        """Extracts and transpiles a .whl file into the vendor directory."""
        wheel_path = Path(wheel_path).resolve()
        stats = TranspileStats()

        with zipfile.ZipFile(wheel_path, "r") as zf:
            # Detect top-level packages inside wheel
            top_level_items: Set[str] = set()
            for name in zf.namelist():
                parts = name.split("/")
                if parts[0] and not parts[0].endswith(".dist-info") and not parts[0].endswith(".data"):
                    top_level_items.add(parts[0])

            # Extract pure python files to a temporary location
            import tempfile

            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_path = Path(tmp_dir)
                zf.extractall(tmp_path)

                for item in top_level_items:
                    item_path = tmp_path / item
                    if item_path.is_dir():
                        pkg_stats = self.vendor_from_source(item_path, package_name=item, clean=clean)
                        self._merge_stats(stats, pkg_stats)
                    elif item_path.is_file() and item_path.suffix == ".py":
                        pkg_stats = self.vendor_from_source(item_path, package_name=item_path.stem, clean=clean)
                        self._merge_stats(stats, pkg_stats)

        return stats

    def _transpile_single_file(
        self,
        src_py: Path,
        dest_lua: Path,
        stats: TranspileStats,
        package: str = "",
    ) -> bool:
        """Transpiles a single Python file to Lua using Luthon IR pipeline."""
        from .transpiler import transpile_ir

        stats.total_files += 1
        try:
            code = src_py.read_text(encoding="utf-8", errors="replace")
            stats.total_bytes_py += len(code.encode("utf-8"))

            lua_output = transpile_ir(
                code,
                optimize=self.optimize,
                sourcemap=self.sourcemap,
                filename=str(src_py),
                package=package,
            )

            # Ensure parent directory exists
            dest_lua.parent.mkdir(parents=True, exist_ok=True)
            dest_lua.write_text(lua_output, encoding="utf-8")

            stats.succeeded_files += 1
            stats.total_bytes_lua += len(lua_output.encode("utf-8"))
            return True
        except Exception as e:
            stats.failed_files += 1
            stats.errors[str(src_py)] = str(e)
            return False

    def _generate_package_manifest(
        self,
        pkg_dir: Path,
        pkg_name: str,
        stats: TranspileStats,
    ) -> None:
        """Writes a metadata manifest inside the converted Lua package."""
        manifest = {
            "name": pkg_name,
            "transpiled_files": stats.succeeded_files,
            "failed_files": stats.failed_files,
            "total_bytes_py": stats.total_bytes_py,
            "total_bytes_lua": stats.total_bytes_lua,
            "errors": stats.errors,
        }
        import json

        (pkg_dir / "luthon_pkg.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    def _merge_stats(self, target: TranspileStats, source: TranspileStats) -> None:
        target.total_files += source.total_files
        target.succeeded_files += source.succeeded_files
        target.failed_files += source.failed_files
        target.total_bytes_py += source.total_bytes_py
        target.total_bytes_lua += source.total_bytes_lua
        target.errors.update(source.errors)
