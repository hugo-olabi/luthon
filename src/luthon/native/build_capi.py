"""Compile helper for Luthon's lightweight modular CPython C-API proxy library."""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List


def get_capi_library_path() -> Path:
    """Returns the expected path of libluthon_capi.so / .dylib / .dll."""
    native_dir = Path(__file__).parent.resolve()
    ext = ".dylib" if sys.platform == "darwin" else (".dll" if sys.platform == "win32" else ".so")
    return native_dir / f"libluthon_capi{ext}"


def get_capi_static_library_path() -> Path:
    """Returns the expected path of libluthon_capi.a."""
    native_dir = Path(__file__).parent.resolve()
    return native_dir / "libluthon_capi.a"


def get_source_files() -> List[Path]:
    """Collects all modular C source files under src/luthon/native/."""
    native_dir = Path(__file__).parent.resolve()
    sources = []
    for sub in ["core", "protocols", "io", "modules"]:
        sub_dir = native_dir / sub
        if sub_dir.exists():
            sources.extend(sorted(sub_dir.glob("*.c")))
    if not sources:
        # Fallback to single file if modular directory not populated
        legacy = native_dir / "capi_proxy.c"
        if legacy.exists():
            sources.append(legacy)
    return sources


def compile_capi_proxy(force: bool = False) -> Path:
    """Compiles modular C translation units into libluthon_capi.so and libluthon_capi.a."""
    native_dir = Path(__file__).parent.resolve()
    include_dir = native_dir / "include"
    build_dir = native_dir / "build"
    build_dir.mkdir(parents=True, exist_ok=True)

    lib_path = get_capi_library_path()
    static_lib_path = get_capi_static_library_path()
    sources = get_source_files()

    if not sources:
        raise RuntimeError(f"No C source files found in {native_dir}")

    # Check timestamps for incremental rebuild
    if not force and lib_path.exists():
        newest_src_mtime = max(s.stat().st_mtime for s in sources)
        newest_hdr_mtime = max((h.stat().st_mtime for h in include_dir.glob("*.h")), default=0)
        max_input_mtime = max(newest_src_mtime, newest_hdr_mtime)
        if lib_path.stat().st_mtime >= max_input_mtime:
            return lib_path

    cc = os.environ.get("CC") or shutil.which("gcc") or shutil.which("clang") or "cc"
    ar = os.environ.get("AR") or shutil.which("ar") or "ar"

    cflags = [
        "-O3",
        "-fPIC",
        "-Wall",
        "-Wextra",
        f"-I{include_dir}",
        "-fvisibility=default",
    ]

    obj_files = []
    # 1. Compile each translation unit to .o
    for src in sources:
        rel_name = src.stem + ".o"
        obj = build_dir / rel_name
        obj_files.append(obj)

        if not force and obj.exists() and obj.stat().st_mtime >= src.stat().st_mtime:
            continue

        cmd = [cc] + cflags + ["-c", str(src), "-o", str(obj)]
        try:
            subprocess.run(cmd, capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to compile {src}: {e.stderr}\nCommand: {' '.join(cmd)}")

    # 2. Link shared library libluthon_capi.so
    link_cmd = [cc, "-shared", "-fPIC"] + [str(o) for o in obj_files] + ["-o", str(lib_path)]
    try:
        subprocess.run(link_cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to link {lib_path}: {e.stderr}\nCommand: {' '.join(link_cmd)}")

    # 3. Create static archive libluthon_capi.a
    ar_cmd = [ar, "rcs", str(static_lib_path)] + [str(o) for o in obj_files]
    try:
        subprocess.run(ar_cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        pass  # Non-fatal if ar fails

    return lib_path


if __name__ == "__main__":
    out = compile_capi_proxy(force=True)
    print(f"[+] Compiled modular C library {out} ({out.stat().st_size} bytes)")
