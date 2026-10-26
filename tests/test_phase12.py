"""Phase 12: Pipeline Parity and Full Source Self-Compilation Tests."""

import glob
import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_in_and_not_in_operators(tmp_path):
    py_code = """
s = "hello world"
print("world in s:", "world" in s)
print("mars not in s:", "mars" not in s)

lst = [10, 20, 30]
print("20 in lst:", 20 in lst)
print("40 not in lst:", 40 not in lst)

st = {"apple", "banana"}
print("apple in st:", "apple" in st)
print("pear not in st:", "pear" not in st)

d = {"k1": 1, "k2": 2}
print("k1 in d:", "k1" in d)
print("k3 not in d:", "k3" not in d)
"""
    py_file = tmp_path / "test_in.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_in.lua"

    # Transpile via Python IR pipeline
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "world in s:\ttrue" in res.stdout or "world in s: true" in res.stdout
    assert "mars not in s:\ttrue" in res.stdout or "mars not in s: true" in res.stdout
    assert "20 in lst:\ttrue" in res.stdout or "20 in lst: true" in res.stdout
    assert "apple in st:\ttrue" in res.stdout or "apple in st: true" in res.stdout
    assert "k1 in d:\ttrue" in res.stdout or "k1 in d: true" in res.stdout


def test_bitwise_operators(tmp_path):
    py_code = """
a = 12   # 1100
b = 10   # 1010
print("band:", a & b)    # 8 (1000)
print("bor:", a | b)     # 14 (1110)
print("bxor:", a ^ b)    # 6 (0110)
print("lshift:", a << 1) # 24
print("rshift:", a >> 1) # 6
"""
    py_file = tmp_path / "test_bit.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_bit.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "band:\t8" in res.stdout or "band: 8" in res.stdout
    assert "bor:\t14" in res.stdout or "bor: 14" in res.stdout
    assert "bxor:\t6" in res.stdout or "bxor: 6" in res.stdout
    assert "lshift:\t24" in res.stdout or "lshift: 24" in res.stdout
    assert "rshift:\t6" in res.stdout or "rshift: 6" in res.stdout


def test_try_except_with_early_return(tmp_path):
    py_code = """
def safe_parse(v):
    try:
        raise ValueError("failed")
    except ValueError as e:
        return 999
    return 0

print("res:", safe_parse("err"))
"""
    py_file = tmp_path / "test_try_return.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_try_return.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "res:\t999" in res.stdout or "res: 999" in res.stdout


def test_pure_lua_raw_strings_and_tuple_unpacking(tmp_path):
    lua_test = tmp_path / "test_parser.lua"
    lua_test.write_text("""
local parser = require("src/luthon/lua/parser")

-- Raw string with special regex chars
local ast1 = parser.parse("match = re.match(r\\"^([A-Za-z0-9_\\\\-\\\\.]+)\\", s)\\n")
assert(ast1._type == "Module")

-- Multi-target unpacking assignment
local ast2 = parser.parse("a, b, c = 1, 2, 3\\n")
assert(ast2._type == "Module")
local assign = ast2.body[1]
assert(assign._type == "Assign")
assert(assign.targets[1]._type == "Tuple")
assert(#assign.targets[1].elts == 3)
assert(assign.value._type == "Tuple")
assert(#assign.value.elts == 3)

print("PARSER_PASS")
""")
    res = subprocess.run(["luajit", str(lua_test)], capture_output=True, text=True)
    assert res.returncode == 0, f"Parser test failed: {res.stderr}"
    assert "PARSER_PASS" in res.stdout


def test_all_source_files_transpile_without_syntax_errors():
    """Verify that every .py file in src/luthon compiles to valid Lua in both pipelines."""
    py_files = sorted(glob.glob("src/luthon/*.py"))
    assert len(py_files) >= 14

    for f in py_files:
        # 1. Python IR pipeline
        res_cp = subprocess.run(
            ["python3", "-m", "luthon.main", "transpile", "--ir", "--no-cache", f, "-o", "/tmp/p12_test_cp.lua"],
            capture_output=True, text=True, env={"PYTHONPATH": "src"}
        )
        assert res_cp.returncode == 0, f"Python transpile failed for {f}: {res_cp.stderr}"
        res_chk_cp = subprocess.run(["luajit", "-bl", "/tmp/p12_test_cp.lua"], capture_output=True, text=True)
        assert res_chk_cp.returncode == 0, f"Lua syntax error in {f} (CPython pipeline): {res_chk_cp.stderr}"

        # 2. Pure Lua pipeline
        res_lua = subprocess.run(
            ["luajit", "src/luthon/lua/luthon_lua.lua", f, "/tmp/p12_test_lua.lua"],
            capture_output=True, text=True
        )
        assert res_lua.returncode == 0, f"Pure-Lua transpile failed for {f}: {res_lua.stderr}"
        res_chk_lua = subprocess.run(["luajit", "-bl", "/tmp/p12_test_lua.lua"], capture_output=True, text=True)
        assert res_chk_lua.returncode == 0, f"Lua syntax error in {f} (pure-Lua pipeline): {res_chk_lua.stderr}"
