"""Integration tests verifying all advanced examples in examples/ run correctly under Luthon."""

import os
from pathlib import Path
import subprocess
import pytest
from luthon.cli import compile_file


EXAMPLES_DIR = Path("examples")


def _get_isolated_env() -> dict[str, str]:
    """Return an execution environment isolated from active virtual environments.

    Inherited virtualenv variables (such as VIRTUAL_ENV, PYTHONHOME,
    __PYVENV_LAUNCHER__, and virtualenv bin/ directories in PATH) cause CPython
    initialization in pybridge.lua to search the virtualenv prefix instead of the
    host Python prefix. Stripping these variables ensures CPython initializes with
    host system site-packages.
    """
    env = os.environ.copy()
    virtual_env = env.pop("VIRTUAL_ENV", None)
    env.pop("VIRTUAL_ENV_PROMPT", None)
    env.pop("PYTHONHOME", None)
    env.pop("__PYVENV_LAUNCHER__", None)

    paths = env.get("PATH", "").split(os.pathsep)
    clean_paths: list[str] = []
    for p in paths:
        if not p:
            continue
        try:
            p_obj = Path(p).resolve()
            if virtual_env:
                v_obj = Path(virtual_env).resolve()
                if p_obj == v_obj or p_obj == (v_obj / "bin") or v_obj in p_obj.parents:
                    continue
            if (p_obj / "pyvenv.cfg").is_file() or (p_obj.parent / "pyvenv.cfg").is_file():
                continue
            if (p_obj / "activate").is_file() and ((p_obj / "python").exists() or (p_obj / "python3").exists()):
                continue
        except OSError:
            pass
        clean_paths.append(p)

    env["PATH"] = os.pathsep.join(clean_paths)
    return env


def test_example_1_six_compatibility(tmp_path):
    py_file = EXAMPLES_DIR / "01_six_compat.py"
    lua_file = tmp_path / "ex1.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(
        ["luajit", str(lua_file)],
        capture_output=True,
        text=True,
        env=_get_isolated_env(),
    )
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_1_SIX_OK" in res.stdout


def test_example_2_packaging_versions(tmp_path):
    py_file = EXAMPLES_DIR / "02_packaging_versions.py"
    lua_file = tmp_path / "ex2.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(
        ["luajit", str(lua_file)],
        capture_output=True,
        text=True,
        env=_get_isolated_env(),
    )
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_2_PACKAGING_OK" in res.stdout


def test_example_3_quant_finance_black_scholes(tmp_path):
    py_file = EXAMPLES_DIR / "03_quant_finance_black_scholes.py"
    lua_file = tmp_path / "ex3.lua"
    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(
        ["luajit", str(lua_file)],
        capture_output=True,
        text=True,
        env=_get_isolated_env(),
    )
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_3_QUANT_FINANCE_OK" in res.stdout


def test_example_4_game_physics_simulation(tmp_path):
    py_file = EXAMPLES_DIR / "04_game_physics_simulation.py"
    lua_file = tmp_path / "ex4.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(
        ["luajit", str(lua_file)],
        capture_output=True,
        text=True,
        env=_get_isolated_env(),
    )
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_4_GAME_PHYSICS_OK" in res.stdout


def test_example_5_matrix_math_transformations(tmp_path):
    py_file = EXAMPLES_DIR / "05_matrix_math_transformations.py"
    lua_file = tmp_path / "ex5.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(
        ["luajit", str(lua_file)],
        capture_output=True,
        text=True,
        env=_get_isolated_env(),
    )
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXAMPLE_5_MATRIX_MATMUL_OK" in res.stdout
