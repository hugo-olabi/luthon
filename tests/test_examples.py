"""Integration tests verifying all advanced examples in examples/ run correctly under Luthon."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file


EXAMPLES_DIR = Path("examples")


def test_example_1_six_compatibility(tmp_path):
    py_file = EXAMPLES_DIR / "01_six_compat.py"
    lua_file = tmp_path / "ex1.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_1_SIX_OK" in res.stdout


def test_example_2_packaging_versions(tmp_path):
    py_file = EXAMPLES_DIR / "02_packaging_versions.py"
    lua_file = tmp_path / "ex2.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_2_PACKAGING_OK" in res.stdout


def test_example_3_quant_finance_black_scholes(tmp_path):
    py_file = EXAMPLES_DIR / "03_quant_finance_black_scholes.py"
    lua_file = tmp_path / "ex3.lua"
    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_3_QUANT_FINANCE_OK" in res.stdout


def test_example_4_game_physics_simulation(tmp_path):
    py_file = EXAMPLES_DIR / "04_game_physics_simulation.py"
    lua_file = tmp_path / "ex4.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_4_GAME_PHYSICS_OK" in res.stdout


def test_example_5_matrix_math_transformations(tmp_path):
    py_file = EXAMPLES_DIR / "05_matrix_math_transformations.py"
    lua_file = tmp_path / "ex5.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_5_MATRIX_MATMUL_OK" in res.stdout
