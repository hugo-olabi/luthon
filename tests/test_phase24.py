"""Phase 24: SIMD Vectorized Numeric Arrays & OpenBLAS Integration Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_vectorized_array_elementwise_operations(tmp_path):
    """Verify element-wise vectorized arithmetic (+, *) on unboxed contiguous arrays."""
    py_code = """
import ffi

a = array("d", [1.0, 2.0, 3.0, 4.0])
# Array + scalar
b = a.add(10.0)
assert b[0] == 11.0
assert b[3] == 14.0

# Array * scalar
c = a.mul(2.0)
assert c[0] == 2.0
assert c[3] == 8.0

# Array + Array
d = a.add(c)
assert d[0] == 3.0
assert d[3] == 12.0

print("VECTOR_ARITH_OK")
"""
    py_file = tmp_path / "test_vec.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_vec.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "VECTOR_ARITH_OK" in res.stdout


def test_matrix_multiplication_operator(tmp_path):
    """Verify matrix creation, row/col dimensions, and @ (__matmul__) operator execution."""
    py_code = """
import ffi

# Create two 2x2 matrices:
# A = [[1, 2], [3, 4]]
# B = [[5, 6], [7, 8]]
m1 = matrix(2, 2, [1.0, 2.0, 3.0, 4.0])
m2 = matrix(2, 2, [5.0, 6.0, 7.0, 8.0])

# C = A @ B -> [[19, 22], [43, 50]]
m3 = m1 @ m2

assert m3.rows == 2
assert m3.cols == 2
assert m3[0] == 19.0
assert m3[1] == 22.0
assert m3[2] == 43.0
assert m3[3] == 50.0

print("MATMUL_OPERATOR_OK")
"""
    py_file = tmp_path / "test_matmul.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_matmul.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "MATMUL_OPERATOR_OK" in res.stdout
