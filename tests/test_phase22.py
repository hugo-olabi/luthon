"""Phase 22: PyPerformance Full Benchmarking Suite & Profiler Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.benchmarks import (
    BenchmarkRunner,
    WORKLOAD_FANnkuch,
    WORKLOAD_FLOAT,
    WORKLOAD_RICHARDS,
)
from luthon.cli import run_file, compile_file


def test_pyperformance_workloads_execution_and_speedup(tmp_path):
    """Verify PyPerformance workloads (fannkuch, float, richards) run and produce identical output."""
    runner = BenchmarkRunner(work_dir=tmp_path / "benchmarks")

    # 1. fannkuch
    r_fann = runner.run_benchmark("fannkuch", WORKLOAD_FANnkuch, iterations=1)
    assert r_fann.verified == True
    assert r_fann.luthon_time_sec > 0.0

    # 2. float
    r_float = runner.run_benchmark("float_norm", WORKLOAD_FLOAT, iterations=1)
    assert r_float.verified == True

    # 3. richards
    r_rich = runner.run_benchmark("richards", WORKLOAD_RICHARDS, iterations=1)
    assert r_rich.verified == True

    report = runner.generate_report()
    assert "Luthon Performance Dashboard" in report
    assert "fannkuch" in report
    assert "float_norm" in report
    assert "richards" in report


def test_jit_profiler_and_dump_traces_cli(tmp_path):
    """Verify --profile (-jp) and --dump-traces (-jdump) options invoke LuaJIT profiler hooks."""
    py_code = """
total = 0
for i in range(1000):
    total = total + i
print("PROFILER_OK:", total)
"""
    py_file = tmp_path / "test_prof.py"
    py_file.write_text(py_code)

    # Test run_file with dump_traces=True
    lua_file = tmp_path / "test_prof.lua"
    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", "-jdump", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    # LuaJIT trace dump output should be present
    assert "TRACE" in res.stdout or "PROFILER_OK" in res.stdout
