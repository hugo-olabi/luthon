"""Luthon Package Manager (luthon-pip / lpip).

Handles downloading wheels from PyPI, unpacking them into Luthon's site-packages,
AOT compiling .py files into .lua for instant LuaJIT execution, parsing dependencies,
and managing virtual environments.
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


def get_default_site_packages() -> Path:
    """Returns the default Luthon site-packages directory."""
    # Check for active virtual environment first
    env_dir = os.environ.get("LUTHON_ENV")
    if env_dir:
        return Path(env_dir) / "lib" / "luthon" / "site-packages"
    if Path("./.luthon_env").is_dir():
        return Path("./.luthon_env") / "lib" / "luthon" / "site-packages"
    return Path.home() / ".luthon" / "site-packages"


class PipInstaller:
    """Manages package installation, dependency resolution, and AOT compilation."""

    def __init__(self, target_dir: Optional[Path] = None):
        self.target_dir = target_dir or get_default_site_packages()
        self.target_dir.mkdir(parents=True, exist_ok=True)

    def fetch_metadata(self, package_name: str) -> dict:
        """Fetch package information and download links from PyPI."""
        url = f"https://pypi.org/pypi/{package_name}/json"
        req = urllib.request.Request(url, headers={"User-Agent": "luthon-pip/0.1.0"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            raise RuntimeError(f"Failed to fetch metadata for '{package_name}' from PyPI: {e}")

    def find_best_wheel(self, info: dict) -> Tuple[str, str]:
        """Selects the best wheel (preferring pure-Python universal wheels)."""
        urls = info.get("urls", [])
        # 1. Pure Python universal wheel: py3-none-any.whl or py2.py3-none-any.whl
        for item in urls:
            fn = item.get("filename", "")
            if fn.endswith("-py3-none-any.whl") or fn.endswith("-py2.py3-none-any.whl"):
                return item["url"], fn
        # 2. Any .whl
        for item in urls:
            fn = item.get("filename", "")
            if fn.endswith(".whl"):
                return item["url"], fn
        raise RuntimeError(f"No suitable .whl file found for {info.get('info', {}).get('name')}")

    def parse_requirements(self, dist_info_dir: Path) -> List[str]:
        """Parses Requires-Dist from METADATA inside .dist-info."""
        metadata_file = dist_info_dir / "METADATA"
        if not metadata_file.exists():
            return []

        requires = []
        with open(metadata_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("Requires-Dist:"):
                    req_str = line.split(":", 1)[1].strip()
                    # Strip environment markers (e.g., ; extra == '...')
                    if ";" in req_str:
                        req_part, marker = req_str.split(";", 1)
                        if "extra ==" in marker:
                            continue  # Skip optional extras
                        req_str = req_part.strip()
                    # Extract base package name
                    match = re.match(r"^([A-Za-z0-9_\-\.]+)", req_str)
                    if match:
                        requires.append(match.group(1))
        return requires

    def install(
        self,
        package_name: str,
        aot_compile: bool = True,
        install_deps: bool = True,
        visited: Optional[Set[str]] = None,
    ) -> bool:
        """Downloads, unpacks, and compiles a package and its dependencies."""
        if visited is None:
            visited = set()

        pkg_canonical = re.sub(r"[-_.]+", "-", package_name).lower()
        if pkg_canonical in visited:
            return True
        visited.add(pkg_canonical)

        print(f"[*] Fetching metadata for {package_name}...")
        meta = self.fetch_metadata(package_name)
        wheel_url, wheel_filename = self.find_best_wheel(meta)

        print(f"[*] Downloading {wheel_filename}...")
        req = urllib.request.Request(wheel_url, headers={"User-Agent": "luthon-pip/0.1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            wheel_bytes = resp.read()

        print(f"[*] Extracting into {self.target_dir}...")
        with zipfile.ZipFile(io.BytesIO(wheel_bytes)) as zf:
            zf.extractall(self.target_dir)

        # Find .dist-info directory
        version = meta.get("info", {}).get("version", "unknown")
        dist_info_name = f"{package_name.replace('-', '_')}-{version}.dist-info"
        dist_info_dir = self.target_dir / dist_info_name
        if not dist_info_dir.exists():
            for d in self.target_dir.glob("*.dist-info"):
                if d.name.lower().startswith(pkg_canonical):
                    dist_info_dir = d
                    break

        # AOT Pre-compilation
        if aot_compile:
            self.aot_compile_directory(self.target_dir)

        # Recursively install dependencies
        if install_deps and dist_info_dir.exists():
            deps = self.parse_requirements(dist_info_dir)
            for dep in deps:
                try:
                    self.install(dep, aot_compile=aot_compile, install_deps=True, visited=visited)
                except Exception as e:
                    print(f"[-] Warning: Failed to install dependency '{dep}': {e}")

        print(f"[+] Successfully installed {package_name}=={version}!")
        return True

    def aot_compile_directory(self, directory: Path) -> int:
        """Pre-compiles .py files into .lua modules via Luthon IR pipeline."""
        from .transpiler import transpile_ir

        compiled_count = 0
        for py_path in directory.rglob("*.py"):
            lua_path = py_path.with_suffix(".lua")
            if lua_path.exists() and lua_path.stat().st_mtime >= py_path.stat().st_mtime:
                continue
            try:
                code = py_path.read_text(encoding="utf-8", errors="replace")
                lua_out = transpile_ir(code, optimize=True)
                lua_path.write_text(lua_out, encoding="utf-8")
                compiled_count += 1
            except Exception:
                # Some files may be dynamic or data files
                pass
        return compiled_count

    def list_installed(self) -> List[Tuple[str, str]]:
        """Lists all installed packages and their versions."""
        installed = []
        for dist_info in self.target_dir.glob("*.dist-info"):
            metadata_file = dist_info / "METADATA"
            name = None
            version = None
            if metadata_file.exists():
                with open(metadata_file, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        if line.startswith("Name:"):
                            name = line.split(":", 1)[1].strip()
                        elif line.startswith("Version:"):
                            version = line.split(":", 1)[1].strip()
                        if name and version:
                            break
            if name and version:
                installed.append((name, version))
            else:
                m = re.match(r"^([A-Za-z0-9_\-\.]+)-([0-9A-Za-z\.]+)\.dist-info$", dist_info.name)
                if m:
                    installed.append((m.group(1), m.group(2)))
        return sorted(installed, key=lambda x: x[0].lower())

    def uninstall(self, package_name: str) -> bool:
        """Uninstalls a package by reading RECORD inside .dist-info."""
        pkg_canonical = re.sub(r"[-_.]+", "-", package_name).lower()
        target_dist = None
        for d in self.target_dir.glob("*.dist-info"):
            if re.sub(r"[-_.]+", "-", d.name.split("-")[0]).lower() == pkg_canonical:
                target_dist = d
                break

        if not target_dist:
            print(f"[-] Package '{package_name}' not found in {self.target_dir}")
            return False

        record_file = target_dist / "RECORD"
        if record_file.exists():
            with open(record_file, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    file_rel = line.split(",", 1)[0].strip()
                    file_path = self.target_dir / file_rel
                    if file_path.is_file():
                        file_path.unlink()
                        # Also delete corresponding AOT .lua file if exists
                        lua_file = file_path.with_suffix(".lua")
                        if lua_file.is_file():
                            lua_file.unlink()

        shutil.rmtree(target_dist, ignore_errors=True)
        print(f"[+] Successfully uninstalled {package_name}!")
        return True


def create_venv(env_path: Path):
    """Creates a local isolated Luthon virtual environment."""
    site_packages = env_path / "lib" / "luthon" / "site-packages"
    bin_dir = env_path / "bin"
    site_packages.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Write activation script
    activate_sh = bin_dir / "activate"
    activate_content = f"""# Luthon virtual environment activation script
export LUTHON_ENV="{env_path.resolve()}"
export PATH="{bin_dir.resolve()}:$PATH"
export PYTHONPATH="{site_packages.resolve()}:$PYTHONPATH"
echo "Activated Luthon virtual environment at {env_path}"
"""
    activate_sh.write_text(activate_content)
    activate_sh.chmod(0o755)

    # Symlink luthon executable into bin
    luthon_bin = shutil.which("luthon") or sys.executable
    venv_luthon = bin_dir / "luthon"
    if not venv_luthon.exists():
        try:
            venv_luthon.symlink_to(luthon_bin)
        except OSError:
            pass

    print(f"[+] Created Luthon virtual environment at {env_path}")
    print(f"    Site packages: {site_packages}")
    print(f"    Activate with: source {activate_sh}")
