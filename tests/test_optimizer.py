"""Phase 8: Optimization tests (temporary locals reduction, constant folding, dead code elimination)."""

import ast
import subprocess
import pytest
from luthon.ir import IRLowerer
from luthon.codegen import generate
from luthon.optimizer import optimize, constant_fold_function, copy_propagate_function, eliminate_dead_code_function
from luthon.transpiler import transpile_ir


def test_optimizer_basic():
    code = "x = 2 + 3\n"
    tree = ast.parse(code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    optimize(mod)
    lua = generate(mod)
    assert "x" in lua


def test_constant_folding():
    code = """
def calc():
    a = 10 + 20
    b = 3 * 7
    c = 100 // 5
    d = 7 % 3
    e = 1 << 4
    return a + b + c + d + e
"""
    tree = ast.parse(code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    optimize(mod)
    fn = next(f for f in mod.functions if f.name == "calc")
    # In block instrs, constant arithmetic should be folded
    # Check that 10 + 20 -> 30, 3 * 7 -> 21, etc.
    const_vals = [ins.args[0] for b in fn.blocks for ins in b.instrs if ins.op == "CONST"]
    assert 30 in const_vals
    assert 21 in const_vals
    assert 20 in const_vals
    assert 1 in const_vals
    assert 16 in const_vals


def test_dead_code_elimination_after_return():
    code = """
def f(x):
    if x > 0:
        return 1
        y = 2 + 3
        print(y)
    return 0
"""
    tree = ast.parse(code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    optimize(mod)
    fn = next(f for f in mod.functions if f.name == "f")
    # All instructions after return in any block should be removed
    for block in fn.blocks:
        seen_ret = False
        for ins in block.instrs:
            assert not seen_ret, f"Found instruction after RETURN in block {block.label}"
            if ins.op == "RETURN":
                seen_ret = True


def test_temporary_locals_reduction():
    code = """
def compute():
    x = 10
    y = x
    z = y
    return z
"""
    tree = ast.parse(code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    before_tmps_len = len(mod.functions[0].tmps) if mod.functions else 0
    optimize(mod)
    fn = next(f for f in mod.functions if f.name == "compute")
    # Unused pure temporaries are pruned from fn.tmps
    assert len(fn.tmps) <= before_tmps_len


def test_optimized_code_execution(tmp_path):
    code = """
def run():
    total = 0
    for i in range(10):
        step = 2 * 3
        total = total + step
    print(total)
run()
"""
    lua_code = transpile_ir(code, optimize=True)
    lua_file = tmp_path / "opt_test.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua execution failed: {res.stderr}"
    assert res.stdout.strip() == "60"
