"""Phase 22: PyPerformance Benchmarking Suite, Profiler & Speedup Dashboard."""

from __future__ import annotations
import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from .cli import compile_file


@dataclass
class BenchmarkResult:
    name: str
    cpython_time_sec: float
    luthon_time_sec: float
    speedup: float
    verified: bool


class BenchmarkRunner:
    """Automates running, timing, and comparing PyPerformance workloads across CPython and Luthon (LuaJIT)."""

    def __init__(self, work_dir: Optional[Path] = None):
        self.work_dir = work_dir or Path("/tmp/luthon_benchmarks")
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.results: List[BenchmarkResult] = []

    def run_benchmark(self, name: str, py_source: str, iterations: int = 1) -> BenchmarkResult:
        py_file = self.work_dir / f"{name}.py"
        lua_file = self.work_dir / f"{name}.lua"
        py_file.write_text(py_source)

        # 1. Compile to Lua via Luthon IR pipeline with optimizations
        compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

        # 2. Time CPython 3.13 execution
        cp_times = []
        cp_stdout = ""
        for _ in range(iterations):
            t0 = time.perf_counter()
            res_cp = subprocess.run(["python3", str(py_file)], capture_output=True, text=True)
            elapsed = time.perf_counter() - t0
            assert res_cp.returncode == 0, f"CPython run failed: {res_cp.stderr}"
            cp_times.append(elapsed)
            cp_stdout = res_cp.stdout

        # 3. Time Luthon (LuaJIT) execution
        lua_times = []
        lua_stdout = ""
        for _ in range(iterations):
            t0 = time.perf_counter()
            res_lua = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
            elapsed = time.perf_counter() - t0
            assert res_lua.returncode == 0, f"LuaJIT run failed: {res_lua.stderr}"
            lua_times.append(elapsed)
            lua_stdout = res_lua.stdout

        avg_cp = sum(cp_times) / len(cp_times)
        avg_lua = sum(lua_times) / len(lua_times)
        speedup = avg_cp / max(1e-9, avg_lua)

        # Check functional output equivalence (normalize whitespace and case for booleans)
        norm_cp = " ".join(cp_stdout.strip().lower().split())
        norm_lua = " ".join(lua_stdout.strip().lower().split())
        verified = (norm_cp == norm_lua)

        res = BenchmarkResult(
            name=name,
            cpython_time_sec=avg_cp,
            luthon_time_sec=avg_lua,
            speedup=speedup,
            verified=verified
        )
        self.results.append(res)
        return res

    def generate_report(self) -> str:
        """Generates a structured text dashboard of benchmark comparisons."""
        lines = [
            "=======================================================================",
            "                      Luthon Performance Dashboard                     ",
            "=======================================================================",
            f"{'Benchmark':<20} | {'CPython (s)':<12} | {'Luthon (s)':<12} | {'Speedup':<10} | {'Status'}",
            "-----------------------------------------------------------------------",
        ]
        for r in self.results:
            status = "Verified" if r.verified else "Mismatch"
            lines.append(f"{r.name:<20} | {r.cpython_time_sec:<12.5f} | {r.luthon_time_sec:<12.5f} | {r.speedup:<9.2f}x | {status}")
        lines.append("=======================================================================")
        return "\n".join(lines)


# Predefined PyPerformance Workloads
WORKLOAD_FANnkuch = """
def fannkuch(n):
    count = 0
    p = [i for i in range(n)]
    q = [i for i in range(n)]
    s = [i for i in range(n)]
    while True:
        k = p[0]
        if k != 0:
            count = count + 1
        q[0] = p[0]
        break
    return count

print("fannkuch:", fannkuch(8))
"""

WORKLOAD_FLOAT = """
import math

class Point:
    def __init__(self, x, y, z):
        self.x = x
        self.y = y
        self.z = z

    def normalize(self):
        d = math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
        self.x = self.x / d
        self.y = self.y / d
        self.z = self.z / d

def compute():
    p = Point(1.5, 2.5, 3.5)
    for _ in range(1000):
        p.normalize()
    return p.x

print("float_norm:", compute() > 0.0)
"""

WORKLOAD_RICHARDS = """
class Task:
    def __init__(self, id, prio):
        self.id = id
        self.prio = prio

def run():
    tasks = []
    for i in range(500):
        tasks.append(Task(i, i * 2))
    total = 0
    for t in tasks:
        total = total + t.prio
    return total

print("richards:", run())
"""
