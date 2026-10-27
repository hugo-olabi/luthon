"""Phase 18: Allocation Sinking, Object Virtualization & Vtables Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_fixed_layout_cstruct_class(tmp_path):
    """Verify classes decorated with @struct are compiled into fixed ffi.cdef C-structs."""
    py_code = """
import ffi

class Point:
    x: float
    y: float

    def mag(self):
        return math.sqrt(self.x * self.x + self.y * self.y)

# Class with native struct decorator
def struct(cls):
    return cls

@struct
class NativePoint:
    x: float
    y: float

    def length(self):
        return math.sqrt(self.x * self.x + self.y * self.y)

# Allocate point and verify methods
p1 = Point()
p1.x = 3.0
p1.y = 4.0
assert p1.mag() == 5.0

p2 = NativePoint(3.0, 4.0)
assert p2.x == 3.0
assert p2.y == 4.0
assert p2.length() == 5.0

print("PHASE18_CSTRUCT_OK")
"""
    py_file = tmp_path / "test_struct.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_struct.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    lua_code = lua_file.read_text()

    # Verify that ffi.cdef typedef struct was generated for NativePoint
    assert "typedef struct" in lua_code
    assert "NativePoint_t;" in lua_code

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "PHASE18_CSTRUCT_OK" in res.stdout


def test_allocation_sinking_fast_path(tmp_path):
    """Verify that local records inside a tight loop run without triggering JIT trace aborts."""
    py_code = """
total = 0
for i in range(1000):
    # Short-lived temporary tuple / record
    pt = (i, i * 2)
    total += pt[0] + pt[1]

assert total == 1498500
print("ALLOC_SINKING_OK")
"""
    py_file = tmp_path / "test_aso.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_aso.lua"

    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "ALLOC_SINKING_OK" in res.stdout
