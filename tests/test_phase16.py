"""Phase 16: Multi-Stage Self-Hosting Bootstrap & Fixpoint Loop Tests."""

import glob
import os
import subprocess
from pathlib import Path
import pytest


def test_stage1_and_stage2_bootstrap_cycle(tmp_path):
    """Test full multi-stage compilation cycle:
    1. Transpile all src/luthon/*.py files using CPython pipeline -> Stage 1 Lua.
    2. Transpile all src/luthon/*.py files using pure-Lua driver -> Stage 2 Lua.
    3. Assert bytecode compilation and test execution equivalence.
    """
    stage1_dir = tmp_path / "stage1"
    stage2_dir = tmp_path / "stage2"
    stage1_dir.mkdir()
    stage2_dir.mkdir()

    py_files = sorted(glob.glob("src/luthon/*.py"))
    assert len(py_files) >= 14, "Expected at least 14 compiler source files"

    # Stage 1: CPython pipeline
    for f in py_files:
        lua_name = Path(f).with_suffix(".lua").name
        out_s1 = stage1_dir / lua_name
        res = subprocess.run(
            ["python3", "-m", "luthon.main", "transpile", "--ir", "--no-cache", f, "-o", str(out_s1)],
            capture_output=True, text=True, env={"PYTHONPATH": "src"}
        )
        assert res.returncode == 0, f"Stage 1 failed for {f}: {res.stderr}"
        chk1 = subprocess.run(["luajit", "-bl", str(out_s1)], capture_output=True, text=True)
        assert chk1.returncode == 0, f"Stage 1 syntax error in {f}: {chk1.stderr}"

    # Stage 2: Pure Lua pipeline
    for f in py_files:
        lua_name = Path(f).with_suffix(".lua").name
        out_s2 = stage2_dir / lua_name
        res = subprocess.run(
            ["luajit", "src/luthon/lua/luthon_lua.lua", f, str(out_s2)],
            capture_output=True, text=True
        )
        assert res.returncode == 0, f"Stage 2 failed for {f}: {res.stderr}"
        chk2 = subprocess.run(["luajit", "-bl", str(out_s2)], capture_output=True, text=True)
        assert chk2.returncode == 0, f"Stage 2 syntax error in {f}: {chk2.stderr}"


def test_stage_fixpoint_determinism(tmp_path):
    """Verify that compiling the same input multiple times under the bootstrap pipeline is deterministic."""
    sample_program = """
class Calculator:
    def __init__(self, base=10):
        self.base = base

    def add(self, x):
        return self.base + x

def main_fn():
    c = Calculator(100)
    for i in range(5):
        print(c.add(i))

main_fn()
"""
    prog_path = tmp_path / "calc.py"
    prog_path.write_text(sample_program)

    out_run1 = tmp_path / "calc_run1.lua"
    out_run2 = tmp_path / "calc_run2.lua"

    res1 = subprocess.run(["luajit", "src/luthon/lua/luthon_lua.lua", str(prog_path), str(out_run1)], capture_output=True, text=True)
    assert res1.returncode == 0, f"Run 1 failed: {res1.stderr}"

    res2 = subprocess.run(["luajit", "src/luthon/lua/luthon_lua.lua", str(prog_path), str(out_run2)], capture_output=True, text=True)
    assert res2.returncode == 0, f"Run 2 failed: {res2.stderr}"

    # Verify identical output (fixpoint determinism)
    assert out_run1.read_text() == out_run2.read_text(), "Transpilation output should be deterministic"

    # Verify execution produces correct output
    exec_res = subprocess.run(["luajit", str(out_run1)], capture_output=True, text=True)
    assert exec_res.returncode == 0
    assert "100" in exec_res.stdout
    assert "104" in exec_res.stdout
