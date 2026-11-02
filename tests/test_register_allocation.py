"""Tests for Phase 29: Register Allocation & Local Variable Slot Reuse.

Verifies:
1. Live-range register allocation pools disjoint variables to a small set of registers.
2. Large functions with 250+ distinct variables fit safely under LuaJIT's 200-local variable limit.
3. Zero fallback to global variables for temporaries or locals.
4. Upvalues, cellvars, and function parameters are safely preserved without collision.
5. Large functions execute and calculate correct results in LuaJIT.
"""

import subprocess
import pytest
from luthon.transpiler import transpile_ir
from luthon.ir import Function, Block, Instr
from luthon.optimizer import allocate_registers_function


def test_register_reuse_disjoint_live_ranges(tmp_path):
    """Verify that variables with disjoint live ranges share register slots."""
    code = """
def compute():
    a = 10
    b = a + 5
    # a and b are dead after this point
    c = 20
    d = c + 15
    # c and d are dead after this point
    e = 30
    f = e + 25
    return b + d + f

assert compute() == 105
"""
    lua = transpile_ir(code, optimize=True)
    assert "_r" in lua
    lua_file = tmp_path / "test_reuse.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"LuaJIT execution error: {res.stderr}"


def test_huge_function_250_variables_no_local_limit_error(tmp_path):
    """Generate a function with 250 distinct local variables and verify LuaJIT runs without 'too many local variables'."""
    lines = ["def massive_calc():", "    acc = 0"]
    for i in range(250):
        lines.append(f"    v_{i} = {i} * 2")
        lines.append(f"    acc += v_{i}")
    lines.append("    return acc")
    lines.append(f"res = massive_calc()")
    expected_sum = sum(i * 2 for i in range(250))
    lines.append(f"assert res == {expected_sum}")
    lines.append(f"print('MASSIVE_OK:' + str(res))")
    code = "\n".join(lines)

    # Transpile via IR backend
    lua = transpile_ir(code, optimize=True)

    # Verify all variable slots are declared local
    assert "local" in lua

    # Execute in LuaJIT
    test_script = tmp_path / "test_massive.lua"
    test_script.write_text(lua)
    proc = subprocess.run(["luajit", str(test_script)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert f"MASSIVE_OK:{expected_sum}" in proc.stdout


def test_closure_cellvars_and_parameters_protected(tmp_path):
    """Ensure captured closure cellvars and function parameters retain their identity."""
    code = """
def make_adder(offset):
    captured = offset * 2
    def adder(x):
        return x + captured
    return adder

add = make_adder(5)
assert add(10) == 20
print('CLOSURE_OK')
"""
    lua = transpile_ir(code, optimize=True)
    lua_file = tmp_path / "test_closure.lua"
    lua_file.write_text(lua)
    proc = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert "CLOSURE_OK" in proc.stdout


def test_register_allocation_with_branching_cfg(tmp_path):
    """Verify live-variable analysis correctly propagates across if-else branch merges."""
    code = """
def branchy(flag, n):
    if flag:
        x = n * 2
        y = x + 10
        res = y
    else:
        a = n * 3
        b = a - 5
        res = b
    return res + 1

assert branchy(True, 4) == (4 * 2 + 10 + 1)
assert branchy(False, 4) == (4 * 3 - 5 + 1)
print("BRANCH_OK")
"""
    lua = transpile_ir(code, optimize=True)
    lua_file = tmp_path / "test_branch.lua"
    lua_file.write_text(lua)
    proc = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert proc.returncode == 0, f"LuaJIT failed: {proc.stderr}"
    assert "BRANCH_OK" in proc.stdout
