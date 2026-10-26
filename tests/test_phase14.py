"""Phase 14: Numeric Acceleration & Unboxed FFI Memory Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_ffi_array_and_numeric_acceleration(tmp_path):
    """Verify FFI array creation, indexing, slicing, appending, and C-runtime math bindings."""
    py_code = """
import ffi

# Test FFI C bindings
assert ffi.C.sqrt(9.0) == 3.0
assert ffi.C.sin(0.0) == 0.0

# Test unboxed FFI array module
arr = array("d", [1.0, 2.0, 3.0, 4.0])
assert len(arr) == 4
assert arr[0] == 1.0
assert arr[-1] == 4.0

arr.append(5.0)
assert len(arr) == 5
assert arr[4] == 5.0

sub = arr.slice(1, 4)
assert len(sub) == 3
assert sub[0] == 2.0
assert sub[2] == 4.0

lst = arr.tolist()
assert len(lst) == 5
assert lst[0] == 1.0
assert lst[4] == 5.0

print("FFI_NUMERIC_ACCEL_OK")
"""
    py_file = tmp_path / "test_numeric.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_numeric.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "FFI_NUMERIC_ACCEL_OK" in res.stdout
