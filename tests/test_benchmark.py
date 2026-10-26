"""Phase 8: Performance benchmark (self-transpilation speed under LuaJIT vs CPython)."""

import time
import subprocess
import pytest


def test_benchmark_self_transpile():
    target = "src/luthon/transpiler.py"

    # CPython benchmark
    t0 = time.time()
    res_cp = subprocess.run(
        ["python3", "-m", "luthon.main", "transpile", "--ir", target, "-o", "/tmp/bench_cp.lua"],
        capture_output=True, text=True, env={"PYTHONPATH": "src"}
    )
    t_cp = time.time() - t0
    assert res_cp.returncode == 0

    # LuaJIT benchmark
    t0 = time.time()
    res_lua = subprocess.run(
        ["luajit", "src/luthon/lua/luthon_lua.lua", target, "/tmp/bench_lua.lua"],
        capture_output=True, text=True
    )
    t_lua = time.time() - t0
    assert res_lua.returncode == 0

    print(f"\n[Benchmark] CPython pipeline: {t_cp:.4f}s | LuaJIT pure-Lua pipeline: {t_lua:.4f}s")
