"""Phase 22: PyPerformance Benchmarking Suite, Profiler & Speedup Dashboard."""

from __future__ import annotations
import json
import os
import argparse
import statistics
import subprocess
import sys
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

    def __init__(self, work_dir: Optional[Path] = None, python_executable: str = sys.executable):
        self.work_dir = work_dir or Path("/tmp/luthon_benchmarks")
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.python_executable = python_executable
        self.results: List[BenchmarkResult] = []

    def run_benchmark(
        self, name: str, py_source: str, iterations: int = 7, warmups: int = 1
    ) -> BenchmarkResult:
        if iterations < 1 or warmups < 0:
            raise ValueError("iterations must be positive and warmups cannot be negative")
        py_file = self.work_dir / f"{name}.py"
        lua_file = self.work_dir / f"{name}.lua"
        py_file.write_text(py_source)

        # 1. Compile to Lua via Luthon IR pipeline with optimizations
        compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

        # Share the same Lua module path in warmups and measured runs.
        env = os.environ.copy()
        pkg_src = str(Path(__file__).parent.parent)
        current_lua_path = env.get("LUA_PATH", ";;")
        extra_paths = f"{pkg_src}/?.lua;{pkg_src}/?/init.lua;{pkg_src}/luthon/lua/?.lua"
        env["LUA_PATH"] = f"{extra_paths};{current_lua_path}" if current_lua_path != ";;" else f"{extra_paths};;"

        # Warmups reduce one-time filesystem and runtime initialization effects.
        for _ in range(warmups):
            for command, command_env in (([self.python_executable, str(py_file)], None), (["luajit", str(lua_file)], env)):
                result = subprocess.run(command, capture_output=True, text=True, env=command_env)
                if result.returncode:
                    raise RuntimeError(f"Warmup failed for {name}: {result.stderr}")

        # Time the selected interpreter; alternate order to reduce ordering bias.
        cp_times = []
        cp_stdout = ""
        lua_times = []
        lua_stdout = ""
        for i in range(iterations):
            commands = [
                ("python", [self.python_executable, str(py_file)], None),
                ("lua", ["luajit", str(lua_file)], env),
            ]
            if i % 2:
                commands.reverse()
            for runtime, command, command_env in commands:
                t0 = time.perf_counter()
                result = subprocess.run(command, capture_output=True, text=True, env=command_env)
                elapsed = time.perf_counter() - t0
                if result.returncode:
                    raise RuntimeError(f"{runtime} run failed for {name}: {result.stderr}")
                if runtime == "python":
                    cp_times.append(elapsed)
                    cp_stdout = result.stdout
                else:
                    lua_times.append(elapsed)
                    lua_stdout = result.stdout

        avg_cp = statistics.median(cp_times)
        avg_lua = statistics.median(lua_times)
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
            f"Baseline interpreter: {self.python_executable}",
            "Times are medians; process startup is included.",
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

WORKLOAD_JSON = """
import json

def run():
    items = []
    for i in range(2000):
        items.append({
            "id": i,
            "name": "asset_" + str(i),
            "score": i * 1.5,
            "active": True if (i % 2 == 0) else False,
            "tags": ["mesh", "texture", "lod" + str(i % 4)]
        })
    s = json.dumps(items)
    parsed = json.loads(s)
    total_score = 0.0
    for item in parsed:
        total_score = total_score + item["score"]
    return int(total_score)

print("json_benchmark:", run())
"""

WORKLOAD_BASE64 = """
import base64

def run():
    raw = ("LuthonHighPerformanceAssetPipelineSerializationBufferPayload_Chunk" * 50).encode("utf-8")
    encoded = base64.b64encode(raw)
    for _ in range(500):
        decoded = base64.b64decode(encoded)
    return len(decoded)

print("base64_benchmark:", run())
"""


def deluge_bencode_workload(deluge_root: Path, repetitions: int = 1000) -> str:
    """Build a benchmark from Deluge's source without modifying that checkout."""
    source_path = deluge_root / "deluge" / "bencode.py"
    if not source_path.is_file():
        raise FileNotFoundError(f"Deluge bencode module not found: {source_path}")
    source = source_path.read_text()
    return source + f'''\n\n_payload = {{b"announce": b"https://tracker.example/announce", b"info": {{b"length": 1048576, b"name": b"luthon-benchmark", b"piece length": 16384, b"pieces": b"x" * 1600}}, b"peers": [{{b"ip": b"127.0.0.1", b"port": 6881}} for _ in range(20)]}}
_encoded = bencode(_payload)
_decoded = None
for _ in range({int(repetitions)}):
    _decoded = bdecode(_encoded)
    _encoded = bencode(_decoded)
print("deluge_bencode:", len(_encoded), len(_decoded[b"peers"]), _decoded[b"info"][b"length"])
'''


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare Luthon/LuaJIT with a chosen CPython on Deluge bencode.")
    parser.add_argument("--deluge-root", type=Path, required=True, help="Deluge checkout root (read only)")
    parser.add_argument("--python", default=sys.executable, help="CPython executable used as the baseline")
    parser.add_argument("--iterations", type=int, default=7, help="Measured process runs; report uses the median")
    parser.add_argument("--warmups", type=int, default=1, help="Unreported warmup process runs")
    parser.add_argument("--repetitions", type=int, default=1000, help="Encode/decode cycles inside each process")
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/luthon_benchmarks"))
    args = parser.parse_args()

    version = subprocess.run([args.python, "--version"], capture_output=True, text=True, check=True)
    print(f"Baseline: {(version.stdout or version.stderr).strip()} ({args.python})")
    runner = BenchmarkRunner(args.work_dir, python_executable=args.python)
    result = runner.run_benchmark(
        "deluge_bencode", deluge_bencode_workload(args.deluge_root, args.repetitions),
        iterations=args.iterations, warmups=args.warmups,
    )
    print(runner.generate_report())
    if not result.verified:
        raise SystemExit("Benchmark outputs differ between CPython and Luthon")


if __name__ == "__main__":
    main()

