"""Phase 15: Python Language Parity (Generators, Methods & Context Managers) Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_generator_function_and_yield_from(tmp_path):
    py_code = """
def sub_gen(n):
    for i in range(n):
        yield i

def main_gen():
    yield from sub_gen(3)
    yield 100

res = []
for val in main_gen():
    res.append(val)

assert len(res) == 4
assert res[0] == 0
assert res[1] == 1
assert res[2] == 2
assert res[3] == 100
print("GENERATOR_PARITY_OK")
"""
    py_file = tmp_path / "test_generators.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_generators.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "GENERATOR_PARITY_OK" in res.stdout


def test_dict_methods_and_string_methods(tmp_path):
    py_code = """
# Dict methods parity
d = {"a": 1, "b": 2}
assert d.get("a") == 1
assert d.get("missing", 99) == 99

assert d.setdefault("c", 30) == 30
assert d.setdefault("c", 40) == 30
assert d.get("c") == 30

# String methods parity
s = "luthon_transpiler.py"
assert s.startswith("luthon_")
assert s.endswith(".py")
parts = s.split("_")
assert len(parts) == 2
assert parts[0] == "luthon"

fmt = "value: {}".format("42")
assert fmt == "value: 42"

print("METHODS_PARITY_OK")
"""
    py_file = tmp_path / "test_methods.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_methods.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "METHODS_PARITY_OK" in res.stdout


def test_custom_context_manager_protocol(tmp_path):
    py_code = """
state = {"entered": False, "exited": False}

class ManagedResource:
    def __init__(self, name):
        self.name = name

    def __enter__(self):
        state["entered"] = True
        return self.name

    def __exit__(self):
        state["exited"] = True

with ManagedResource("test_res") as r:
    assert r == "test_res"
    assert state["entered"] == True
    assert state["exited"] == False

assert state["exited"] == True
print("CONTEXT_PROTOCOL_OK")
"""
    py_file = tmp_path / "test_context.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_context.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "CONTEXT_PROTOCOL_OK" in res.stdout
