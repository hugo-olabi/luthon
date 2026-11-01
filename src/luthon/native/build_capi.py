"""Compile helper for Luthon's lightweight CPython C-API proxy library."""

import os
import shutil
import subprocess
import sys
from pathlib import Path


def get_capi_library_path() -> Path:
    """Returns the expected path of libluthon_capi.so."""
    native_dir = Path(__file__).parent.resolve()
    ext = ".dylib" if sys.platform == "darwin" else (".dll" if sys.platform == "win32" else ".so")
    return native_dir / f"libluthon_capi{ext}"


def compile_capi_proxy(force: bool = False) -> Path:
    """Compiles capi_proxy.c into libluthon_capi.so using system cc/gcc/clang."""
    native_dir = Path(__file__).parent.resolve()
    c_source = native_dir / "capi_proxy.c"
    lib_path = get_capi_library_path()

    if not force and lib_path.exists() and lib_path.stat().st_mtime >= c_source.stat().st_mtime:
        return lib_path

    cc = os.environ.get("CC") or shutil.which("gcc") or shutil.which("clang") or "cc"
    cmd = [
        cc,
        "-O3",
        "-fPIC",
        "-shared",
        "-Wall",
        "-Wextra",
        "-fvisibility=default",
        str(c_source),
        "-o",
        str(lib_path),
    ]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to compile libluthon_capi: {e.stderr}\nCommand: {' '.join(cmd)}")

    return lib_path


if __name__ == "__main__":
    out = compile_capi_proxy(force=True)
    print(f"[+] Compiled {out} ({out.stat().st_size} bytes)")
