"""Test Phase 7 bootstrap pipeline: pure-Lua transpiler vs CPython."""

import subprocess
from pathlib import Path


def test_pure_lua_bootstrap_transpile_and_run(tmp_path):
    prog = """
def is_even(n):
    return n % 2 == 0

def square(n):
    return n * n

def sum_even_squares(limit):
    total = 0
    for i in range(limit):
        if is_even(i):
            total += square(i)
    return total

print("Result:", sum_even_squares(10))
"""
    py_file = tmp_path / "test_prog.py"
    py_file.write_text(prog)

    lua_file = tmp_path / "test_prog.lua"

    # Transpile via pure-Lua pipeline
    cmd_transpile = ["luajit", "src/luthon/lua/luthon_lua.lua", str(py_file), str(lua_file)]
    res = subprocess.run(cmd_transpile, capture_output=True, text=True)
    assert res.returncode == 0, f"Transpile failed: {res.stderr}"
    assert lua_file.exists()

    # Execute under LuaJIT
    cmd_run = ["luajit", str(lua_file)]
    run_res = subprocess.run(cmd_run, capture_output=True, text=True)
    assert run_res.returncode == 0, f"Execution failed: {run_res.stderr}"
    assert run_res.stdout.strip() == "Result:\t120" or run_res.stdout.strip() == "Result: 120"


def test_pure_lua_fib(tmp_path):
    fib_py = Path("bench/parser_test.py")
    lua_file = tmp_path / "fib.lua"

    res = subprocess.run(["luajit", "src/luthon/lua/luthon_lua.lua", str(fib_py), str(lua_file)],
                         capture_output=True, text=True)
    assert res.returncode == 0, f"Transpile failed: {res.stderr}"

    run_res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert run_res.returncode == 0, f"Execution failed: {run_res.stderr}"
    assert run_res.stdout.strip() == "55"
