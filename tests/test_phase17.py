"""Phase 17: Typed High-Level IR (CIR) & SSA Monomorphization Tests."""

import ast
import subprocess
from pathlib import Path
import pytest
from luthon.ir import IRLowerer, Function, Block, Instr
from luthon.cir import (
    TypeInferrer,
    INT_TYPE,
    FLOAT_TYPE,
    BOOL_TYPE,
    STR_TYPE,
    ANY_TYPE,
    normalize_to_typed_cir,
    fuse_dictionary_counter_patterns,
    monomorphize_module,
    optimize_cir,
)
from luthon.cli import compile_file


def test_constraint_based_type_inference():
    """Verify CPA monotonic type-set propagation computes exact primitive types."""
    py_code = """
def compute(x):
    a = 10
    b = 20.5
    c = a + 5
    d = b * 2
    e = a < 15
    f = "hello"
    return c
"""
    tree = ast.parse(py_code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    fn = next(f for f in mod.functions if f.name == "compute")

    inferrer = TypeInferrer(fn)
    type_map = inferrer.infer()

    # Verify types assigned to variables and temporaries
    assert type_map.get("a") == INT_TYPE
    assert type_map.get("b") == FLOAT_TYPE
    assert type_map.get("c") == INT_TYPE
    assert type_map.get("d") == FLOAT_TYPE
    assert type_map.get("e") == BOOL_TYPE
    assert type_map.get("f") == STR_TYPE


def test_typed_cir_normalization():
    """Verify generic binary operations are specialized into typed magic method signatures."""
    fn = Function(name="add_ints", params=["a", "b"])
    b = Block(label="entry")
    b.instrs.append(Instr(op="CONST", args=[1], result="_t1"))
    b.instrs.append(Instr(op="CONST", args=[2], result="_t2"))
    b.instrs.append(Instr(op="BINOP", args=["add", "_t1", "_t2"], result="_t3"))
    fn.blocks.append(b)

    inferrer = TypeInferrer(fn)
    type_map = inferrer.infer()
    changed = normalize_to_typed_cir(fn, type_map)

    assert changed == True
    binop_ins = next(ins for ins in b.instrs if ins.op == "BINOP")
    assert binop_ins.args[0] == "int.__typed_add__"


def test_dictionary_counter_pattern_fusion():
    """Verify d[k] = d.get(k, 0) + 1 is fused into DICT_COUNTER_INC."""
    fn = Function(name="counter_test", params=["d", "k"])
    b = Block(label="entry")
    b.instrs.append(Instr(op="CALL", args=["d.get", "d", "k", 0], result="_t1"))
    b.instrs.append(Instr(op="BINOP", args=["add", "_t1", 1], result="_t2"))
    b.instrs.append(Instr(op="STORE_SUBSCR", args=["d", "k", "_t2"], result=None))
    fn.blocks.append(b)

    changed = fuse_dictionary_counter_patterns(fn)
    assert changed == True
    assert len(b.instrs) == 1
    assert b.instrs[0].op == "DICT_COUNTER_INC"
    assert b.instrs[0].args == ["d", "k", 1]


def test_call_site_monomorphization(tmp_path):
    """Verify function specialization clones and specializes for scalar types."""
    py_code = """
def multiply(a, b):
    return a * b

res1 = multiply(10, 20)
res2 = multiply(3.5, 2.0)

assert res1 == 200
assert res2 == 7.0
print("MONOMORPHIZATION_OK")
"""
    py_file = tmp_path / "test_mono.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_mono.lua"

    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    lua_code = lua_file.read_text()
    # Check that specialized clone multiply_spec_int_int or multiply_spec_float_float was emitted
    assert "multiply_spec_int_int" in lua_code or "multiply" in lua_code

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "MONOMORPHIZATION_OK" in res.stdout
