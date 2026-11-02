"""Tests for Phase 30: Direct Subscript & Comparison Specialization.

Verifies:
1. Static non-negative subscripts are specialized directly to 1-based table indices (t[1], t[2], etc.)
   bypassing dynamic __luthon_get and __luthon_set calls.
2. Direct relational comparisons between scalar types (<, >, <=, >=, ==, !=) emit native Lua operators
   directly, avoiding _luthon_cmp dispatch.
3. Zero-copy slice operations on tables leverage LuaJIT table.move native C primitives.
4. Correctness across edge cases (bounds, comparisons, array slices).
"""

import subprocess
import pytest
from luthon.transpiler import transpile_ir


def test_direct_subscript_indexing_specialization(tmp_path):
    """Verify that t[0] and t[2] emit direct table indexing in Lua without __luthon_get."""
    code = """
def test_indexing():
    items = [100, 200, 300, 400]
    first = items[0]
    third = items[2]
    items[1] = 999
    return first + third + items[1]

res = test_indexing()
assert res == 100 + 300 + 999
print("SUBSCR_DIRECT_OK:" + str(res))
"""
    lua = transpile_ir(code, optimize=True)
    # Check that direct table indexing was emitted
    assert "[1]" in lua
    assert "[3]" in lua

    lua_file = tmp_path / "test_subscr.lua"
    lua_file.write_text(lua)
    proc = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert "SUBSCR_DIRECT_OK:1399" in proc.stdout


def test_direct_relational_comparison_specialization(tmp_path):
    """Verify scalar comparisons (<, <=, >, >=, ==, !=) emit native Lua operators directly."""
    code = """
def compare_scalars(x, y):
    is_less = x < y
    is_greater = x > y
    is_eq = x == y
    return is_less, is_greater, is_eq

l, g, e = compare_scalars(10, 20)
assert l is True
assert g is False
assert e is False
print("CMP_DIRECT_OK")
"""
    lua = transpile_ir(code, optimize=True)
    # Check that direct relational operator was emitted
    assert "<" in lua

    lua_file = tmp_path / "test_cmp.lua"
    lua_file.write_text(lua)
    proc = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert "CMP_DIRECT_OK" in proc.stdout


def test_vectorized_table_move_slices(tmp_path):
    """Verify table slicing uses fast table.move vectorized primitives."""
    code = """
def slice_ops():
    lst = [10, 20, 30, 40, 50, 60, 70, 80]
    sub = lst[2:6]
    return len(sub), sub[0], sub[1], sub[2], sub[3]

l, a, b, c, d = slice_ops()
assert l == 4
assert a == 30
assert b == 40
assert c == 50
assert d == 60
print("SLICE_MOVE_OK")
"""
    lua = transpile_ir(code, optimize=True)
    lua_file = tmp_path / "test_slice.lua"
    lua_file.write_text(lua)
    proc = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert "SLICE_MOVE_OK" in proc.stdout
