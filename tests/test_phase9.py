"""Phase 9 tests: Advanced Architecture & JIT Specialization.

Tests:
1. Negative indexing on lists and strings.
2. Prototype-based class inheritance and method lookup.
3. Default parameter values in IR functions.
4. Exception lowering (try/except/finally, raise, assert) in CPython IR pipeline.
5. Register allocation on functions with many temporaries.
6. Pure-Lua VLQ source map generation.
"""

import ast
import subprocess
import pytest
from pathlib import Path
from luthon.transpiler import transpile_ir
from luthon.ir import IRLowerer
from luthon.codegen import generate
from luthon.optimizer import optimize, allocate_registers_function


def test_negative_indexing(tmp_path):
    code = """
nums = [10, 20, 30, 40]
print(nums[-1], nums[-2], nums[-4])
text = "luthon"
print(text[-1], text[-2])
"""
    lua = transpile_ir(code)
    lua_file = tmp_path / "test_neg.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    lines = res.stdout.strip().splitlines()
    assert lines[0] == "40\t30\t10" or lines[0] == "40 30 10"
    assert lines[1] == "n\to" or lines[1] == "n o"


def test_prototype_class_inheritance(tmp_path):
    code = """
class Calculator:
    def __init__(self, base):
        self.base = base
    def add(self, x):
        return self.base + x

calc = Calculator(100)
print(calc.add(25))
"""
    lua = transpile_ir(code)
    assert "__instance_mt" in lua
    assert "__index = Calculator" in lua
    lua_file = tmp_path / "test_proto.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert res.stdout.strip() == "125"


def test_default_parameter_values(tmp_path):
    code = """
def greet(name, prefix="Hello", suffix="!"):
    print(prefix, name, suffix)

greet("World")
greet("Alice", "Hi")
greet("Bob", "Hey", "?")
"""
    lua = transpile_ir(code)
    lua_file = tmp_path / "test_defaults.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    lines = res.stdout.strip().splitlines()
    assert "Hello" in lines[0] and "World" in lines[0] and "!" in lines[0]
    assert "Hi" in lines[1] and "Alice" in lines[1] and "!" in lines[1]
    assert "Hey" in lines[2] and "Bob" in lines[2] and "?" in lines[2]


def test_try_except_finally_and_raise(tmp_path):
    code = """
def divide(a, b):
    if b == 0:
        raise ValueError("division by zero")
    return a // b

try:
    print(divide(10, 2))
    print(divide(5, 0))
except ValueError as e:
    print("caught error")
finally:
    print("done")
"""
    lua = transpile_ir(code)
    lua_file = tmp_path / "test_try.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    lines = res.stdout.strip().splitlines()
    assert lines[0] == "5"
    assert lines[1] == "caught error"
    assert lines[2] == "done"


def test_assert_lowering(tmp_path):
    code = """
assert 10 > 5, "ten is greater"
try:
    assert 2 == 3, "math failed"
except:
    print("assertion caught")
"""
    lua = transpile_ir(code)
    lua_file = tmp_path / "test_assert.lua"
    lua_file.write_text(lua)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "assertion caught" in res.stdout


def test_register_allocation_reduces_locals():
    # Construct code with many sequential operations
    lines = ["def big_func():", "    x = 0"]
    for i in range(100):
        lines.append(f"    x = x + {i}")
    lines.append("    return x")
    code = "\n".join(lines)

    tree = ast.parse(code)
    mod = IRLowerer().lower_module(tree)
    fn = mod.functions[0]
    initial_tmps_count = len(fn.tmps)
    assert initial_tmps_count > 100

    allocate_registers_function(fn)
    # Register allocation should reduce temporaries drastically (to < 10 virtual registers)
    assert len(fn.tmps) < 15
    for t in fn.tmps:
        assert t.startswith("_r")


def test_pure_lua_sourcemap():
    cmd = ["luajit", "-e", """
local sm_mod = require("src/luthon/lua/sourcemap")
local sm = sm_mod.new("test.py")
assert(sm:_vlq(0) == "A")
assert(sm:_vlq(1) == "C")
assert(sm:_vlq(-1) == "D")
sm:add(1, 2, 10, 5, "test.py")
local d = sm:to_dict()
assert(d.version == 3)
assert(d.file == "test.py")
assert(#d.mappings > 0)
print("OK")
"""]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0
    assert "OK" in res.stdout
