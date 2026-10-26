"""Phase 13: High-Performance JIT Optimization & NYI Elimination Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_runtime_helpers_trace_friendly_iterations(tmp_path):
    """Verify that runtime helpers like sum, map, filter, any, all, _luthon_in run trace-friendly."""
    py_code = """
nums = [i for i in range(1000)]
s = sum(nums)
assert s == 499500

doubled = map(lambda x: x * 2, nums)
assert len(doubled) == 1000

evens = filter(lambda x: x % 2 == 0, nums)
assert len(evens) == 500

assert any([False, False, True]) == True
assert all([True, True, True]) == True
assert all([True, False, True]) == False

assert 500 in nums
assert 1500 not in nums

print("TRACE_HELPERS_OK")
"""
    py_file = tmp_path / "test_jit_helpers.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_jit_helpers.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    # Run with LuaJIT trace dump or check execution
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "TRACE_HELPERS_OK" in res.stdout


def test_file_level_local_aliasing(tmp_path):
    """Verify that generated Lua contains file-level local aliases for primitives."""
    py_code = """
def bit_ops(x, y):
    return (x & y) | (x ^ y)

def math_ops(a, b):
    return min(a, b) + max(a, b)
"""
    py_file = tmp_path / "test_aliases.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_aliases.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    content = lua_file.read_text()
    assert "local _bit_band, _bit_bor, _bit_bxor" in content
    assert "local _math_floor, _math_abs, _math_min, _math_max" in content
    assert "local _table_insert, _table_concat, _string_sub" in content


def test_register_allocation_temporary_pooling(tmp_path):
    """Verify that register allocation in optimizer collapses temporaries into pooled registers."""
    from luthon.ir import Function, Block, Instr
    from luthon.optimizer import allocate_registers_function

    fn = Function(name="compute", params=["a", "b"])
    b = Block(label="entry")
    # Emit 10 non-overlapping temporary operations
    tmps = []
    for i in range(1, 11):
        t = f"_t{i}"
        tmps.append(t)
        b.instrs.append(Instr(op="CONST", args=[i], result=t))
        b.instrs.append(Instr(op="STORE", args=["x", t]))
    fn.blocks.append(b)
    fn.tmps = tmps

    allocate_registers_function(fn)
    # Because each temporary is killed immediately by the STORE, colors should be heavily reused!
    assert len(fn.tmps) <= 2
    assert all(t.startswith("_r") for t in fn.tmps)
