"""Phase 22: PyPerformance Benchmarking Suite, Profiler & Speedup Dashboard."""

from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Union
from .cli import compile_file


@dataclass
class BenchmarkResult:
    name: str
    cpython_steady_sec: float
    luthon_steady_sec: float
    steady_speedup: float
    cpython_wall_sec: float
    luthon_wall_sec: float
    wall_speedup: float
    verified: bool
    python_version: str = ""
    verification_detail: str = ""

    @property
    def cpython_time_sec(self) -> float:
        return self.cpython_steady_sec

    @property
    def luthon_time_sec(self) -> float:
        return self.luthon_steady_sec

    @property
    def speedup(self) -> float:
        return self.steady_speedup


class BenchmarkRunner:
    """Automates running, timing, and comparing workloads across CPython and Luthon (LuaJIT)."""

    def __init__(self, work_dir: Optional[Path] = None, python_executable: Optional[str] = None):
        self.work_dir = work_dir or Path("/tmp/luthon_benchmarks")
        self.work_dir.mkdir(parents=True, exist_ok=True)
        if python_executable:
            self.python_executable = python_executable
        else:
            venv_py = Path(__file__).resolve().parent.parent.parent / ".venv" / "bin" / "python"
            if venv_py.is_file():
                self.python_executable = str(venv_py)
            else:
                self.python_executable = sys.executable

        self.python_version = self._detect_python_version(self.python_executable)
        self.results: List[BenchmarkResult] = []

    @staticmethod
    def _detect_python_version(executable: str) -> str:
        try:
            ver = subprocess.run([executable, "--version"], capture_output=True, text=True, check=True)
            return (ver.stdout or ver.stderr).strip()
        except Exception:
            return "CPython"

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

        # Time the selected interpreters; alternate order to reduce ordering bias.
        cp_steady_times: List[float] = []
        cp_wall_times: List[float] = []
        cp_stdout = ""
        lua_steady_times: List[float] = []
        lua_wall_times: List[float] = []
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
                elapsed_wall = time.perf_counter() - t0
                if result.returncode:
                    raise RuntimeError(f"{runtime} run failed for {name}: {result.stderr}")

                # Parse steady-state time if reported from within process
                steady_val: Optional[float] = None
                for line in result.stdout.splitlines():
                    if line.startswith("BENCH_STEADY_SEC:"):
                        try:
                            steady_val = float(line.split(":", 1)[1].strip())
                        except ValueError:
                            pass

                if runtime == "python":
                    cp_wall_times.append(elapsed_wall)
                    cp_steady_times.append(steady_val if steady_val is not None else elapsed_wall)
                    cp_stdout = result.stdout
                else:
                    lua_wall_times.append(elapsed_wall)
                    lua_steady_times.append(steady_val if steady_val is not None else elapsed_wall)
                    lua_stdout = result.stdout

        avg_cp_steady = statistics.median(cp_steady_times)
        avg_lua_steady = statistics.median(lua_steady_times)
        steady_speedup = avg_cp_steady / max(1e-9, avg_lua_steady)

        avg_cp_wall = statistics.median(cp_wall_times)
        avg_lua_wall = statistics.median(lua_wall_times)
        wall_speedup = avg_cp_wall / max(1e-9, avg_lua_wall)

        # Verify output equivalence
        cp_verify = None
        for line in cp_stdout.splitlines():
            if line.startswith("BENCH_VERIFY:"):
                cp_verify = line.split(":", 1)[1].strip()
        lua_verify = None
        for line in lua_stdout.splitlines():
            if line.startswith("BENCH_VERIFY:"):
                lua_verify = line.split(":", 1)[1].strip()

        if cp_verify is not None and lua_verify is not None:
            verified = (cp_verify == lua_verify)
            detail = f"verify_token={cp_verify[:20]}"
        else:
            norm_cp = " ".join(cp_stdout.strip().lower().split())
            norm_lua = " ".join(lua_stdout.strip().lower().split())
            verified = (norm_cp == norm_lua)
            detail = "stdout_normalized"

        res = BenchmarkResult(
            name=name,
            cpython_steady_sec=avg_cp_steady,
            luthon_steady_sec=avg_lua_steady,
            steady_speedup=steady_speedup,
            cpython_wall_sec=avg_cp_wall,
            luthon_wall_sec=avg_lua_wall,
            wall_speedup=wall_speedup,
            verified=verified,
            python_version=self.python_version,
            verification_detail=detail,
        )
        self.results.append(res)
        return res

    def generate_report(self) -> str:
        """Generates a structured text dashboard of benchmark comparisons."""
        lines = [
            f"Baseline: {self.python_version} ({self.python_executable})",
            "Metrics: In-process steady state (untimed warmups + steady loop) and full process wall clock.",
            "=" * 104,
            "                                     Luthon Performance Dashboard",
            "=" * 104,
            f"{'Benchmark':<28} | {'CPython (s)':<12} | {'Luthon (s)':<12} | {'Steady Speedup':<14} | {'Wall Speedup':<12} | {'Status'}",
            "-" * 104,
        ]
        for r in self.results:
            status = "Verified" if r.verified else "Mismatch"
            lines.append(
                f"{r.name:<28} | {r.cpython_steady_sec:<12.5f} | {r.luthon_steady_sec:<12.5f} | {r.steady_speedup:<13.2f}x | {r.wall_speedup:<11.2f}x | {status}"
            )
        lines.append("=" * 104)
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


STRUCT_VERIFY_CODE = """
def verify_bdecode_structure(v):
    if type(v) == dict:
        parts = []
        for k in sorted(v.keys()):
            parts.append(k + b"=" + verify_bdecode_structure(v[k]))
        return b"{" + b",".join(parts) + b"}"
    elif type(v) == list:
        parts = []
        for item in v:
            parts.append(verify_bdecode_structure(item))
        return b"[" + b",".join(parts) + b"]"
    elif type(v) == int:
        return str(v).encode("ascii")
    else:
        return b"\"" + hashlib.sha256(v).hexdigest()[:16].encode("ascii") + b"\""
"""


def _load_bencode_module_source(target_root: Path) -> str:
    """Load bencode module source without modifying external checkout."""
    candidates = [
        target_root / "deluge" / "bencode.py",
        target_root / "bencode.py",
    ]
    for c in candidates:
        if c.is_file():
            return c.read_text()
    raise FileNotFoundError(f"bencode module not found under: {target_root}")


def _resolve_payload_bytes_or_file(target_root: Path, payload_spec: str) -> Tuple[str, str]:
    """Resolves payload to either a python code snippet that reads it or sets raw bytes."""
    if payload_spec == "synthetic":
        setup = (
            '_payload = {b"announce": b"https://tracker.example/announce", '
            'b"info": {b"length": 1048576, b"name": b"luthon-benchmark", b"piece length": 16384, '
            'b"pieces": b"x" * 1600}, '
            'b"peers": [{b"ip": b"127.0.0.1", b"port": 6881} for _ in range(20)]}\n'
            '_raw = bencode(_payload)'
        )
        return setup, "synthetic_tracker"

    # Check named files in target tests data directory
    test_data_dir = target_root / "deluge" / "tests" / "data"
    named_map = {
        "test": "test.torrent",
        "test.torrent": "test.torrent",
        "dir6": "dir_with_6_files.torrent",
        "dir_with_6_files.torrent": "dir_with_6_files.torrent",
        "ubuntu": "ubuntu-9.04-desktop-i386.iso.torrent",
        "ubuntu.torrent": "ubuntu-9.04-desktop-i386.iso.torrent",
        "ubuntu-9.04-desktop-i386.iso.torrent": "ubuntu-9.04-desktop-i386.iso.torrent",
        "unicode": "unicode_filenames.torrent",
        "unicode_filenames.torrent": "unicode_filenames.torrent",
    }
    torrent_filename = named_map.get(payload_spec, payload_spec)
    file_path = test_data_dir / torrent_filename if not Path(torrent_filename).is_file() else Path(torrent_filename)
    if not file_path.is_file():
        raise FileNotFoundError(f"Payload torrent file not found: {file_path}")

    resolved_path = str(file_path.resolve())
    setup = f'with open({repr(resolved_path)}, "rb") as _f:\n    _raw = _f.read()'
    return setup, file_path.stem


def production_bencode_decode_workload(
    target_root: Path, payload_spec: str = "synthetic", repetitions: int = 1000, in_process_warmups: int = 10
) -> Tuple[str, str]:
    """Generates an isolated decode benchmark verifying full decoded structure."""
    source = _load_bencode_module_source(target_root)
    setup_code, label = _resolve_payload_bytes_or_file(target_root, payload_spec)
    workload = source + f"""

import hashlib
import time

{STRUCT_VERIFY_CODE}

{setup_code}

for _ in range({in_process_warmups}):
    _d = bdecode(_raw)

_t0 = time.perf_counter()
for _ in range({repetitions}):
    _d = bdecode(_raw)
_t1 = time.perf_counter()

_steady = _t1 - _t0
_digest = hashlib.sha256(verify_bdecode_structure(_d)).hexdigest()

print(f"BENCH_STEADY_SEC:{{_steady:.8f}}")
print(f"BENCH_VERIFY:{{_digest}}")
"""
    return workload, f"bencode_decode_{label}"


def production_bencode_encode_workload(
    target_root: Path, payload_spec: str = "synthetic", repetitions: int = 1000, in_process_warmups: int = 10
) -> Tuple[str, str]:
    """Generates an isolated encode benchmark verifying byte-exact SHA256 checksum."""
    source = _load_bencode_module_source(target_root)
    setup_code, label = _resolve_payload_bytes_or_file(target_root, payload_spec)
    workload = source + f"""

import hashlib
import time

{setup_code}
_decoded = bdecode(_raw)

for _ in range({in_process_warmups}):
    _e = bencode(_decoded)

_t0 = time.perf_counter()
for _ in range({repetitions}):
    _e = bencode(_decoded)
_t1 = time.perf_counter()

_steady = _t1 - _t0
_hash = hashlib.sha256(_e).hexdigest()

print(f"BENCH_STEADY_SEC:{{_steady:.8f}}")
print(f"BENCH_VERIFY:{{_hash}}")
"""
    return workload, f"bencode_encode_{label}"


def production_bencode_roundtrip_workload(
    target_root: Path, payload_spec: str = "synthetic", repetitions: int = 1000, in_process_warmups: int = 10
) -> Tuple[str, str]:
    """Generates a combined round-trip benchmark verifying both decode structure and encode bytes."""
    source = _load_bencode_module_source(target_root)
    setup_code, label = _resolve_payload_bytes_or_file(target_root, payload_spec)
    workload = source + f"""

import hashlib
import time

{STRUCT_VERIFY_CODE}

{setup_code}

for _ in range({in_process_warmups}):
    _d = bdecode(_raw)
    _e = bencode(_d)

_t0 = time.perf_counter()
for _ in range({repetitions}):
    _d = bdecode(_raw)
    _e = bencode(_d)
_t1 = time.perf_counter()

_steady = _t1 - _t0
_digest = hashlib.sha256(verify_bdecode_structure(_d)).hexdigest()
_hash = hashlib.sha256(_e).hexdigest()

print(f"BENCH_STEADY_SEC:{{_steady:.8f}}")
print(f"BENCH_VERIFY:{{_digest}}:{{_hash}}")
"""
    return workload, f"bencode_roundtrip_{label}"


def deluge_bencode_workload(deluge_root: Path, repetitions: int = 1000) -> str:
    """Backward compatibility adapter for roundtrip benchmark."""
    src, _ = production_bencode_roundtrip_workload(
        target_root=deluge_root,
        payload_spec="synthetic",
        repetitions=repetitions,
        in_process_warmups=10,
    )
    return src


def run_luajit_profile(work_dir: Path, name: str) -> None:
    """Runs LuaJIT profiler and trace inspection on the generated benchmark Lua file."""
    lua_file = work_dir / f"{name}.lua"
    if not lua_file.is_file():
        print(f"Cannot profile: {lua_file} not found.")
        return

    print("\n" + "=" * 80)
    print(f"LuaJIT Profiler Analysis (-jp=v): {name}")
    print("=" * 80)
    p_res = subprocess.run(["luajit", "-jp=v", str(lua_file)], capture_output=True, text=True)
    print((p_res.stderr or p_res.stdout).strip() or "No samples collected.")

    print("\n" + "=" * 80)
    print(f"LuaJIT Trace Log Summary (-jv): {name}")
    print("=" * 80)
    v_res = subprocess.run(["luajit", "-jv", str(lua_file)], capture_output=True, text=True)
    lines = (v_res.stderr or v_res.stdout).splitlines()
    for l in lines[:40]:
        print(l)
    if len(lines) > 40:
        print(f"... [{len(lines) - 40} additional trace events]")
    print("=" * 80 + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare Luthon/LuaJIT with CPython on real-world production bencode workloads."
    )
    parser.add_argument(
        "--deluge-root",
        "--target-root",
        "--production-root",
        dest="target_root",
        type=Path,
        required=True,
        help="Production codebase checkout root (read only)",
    )
    parser.add_argument(
        "--python",
        default=None,
        help="CPython executable baseline (defaults to .venv/bin/python or sys.executable)",
    )
    parser.add_argument(
        "--compare-pythons",
        action="store_true",
        help="Run benchmarks against both Python 3.12 (.venv/bin/python) and Python 3.15 (/usr/bin/python3)",
    )
    parser.add_argument(
        "--operation",
        choices=["all", "decode", "encode", "roundtrip"],
        default="all",
        help="Specific bencode operation to measure (default: all)",
    )
    parser.add_argument(
        "--payload",
        default="synthetic",
        help="Workload payload: synthetic, test, dir6, ubuntu, unicode, all, or path to .torrent file",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=7,
        help="Measured process runs; report uses the median across processes (default: 7)",
    )
    parser.add_argument(
        "--warmups",
        type=int,
        default=1,
        help="Unreported warmup process runs (default: 1)",
    )
    parser.add_argument(
        "--in-process-warmups",
        type=int,
        default=10,
        help="Untimed warmup cycles inside each process to settle JIT traces (default: 10)",
    )
    parser.add_argument(
        "--repetitions",
        type=int,
        default=1000,
        help="Timed iterations inside each process (default: 1000)",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path("/tmp/luthon_benchmarks"),
    )
    parser.add_argument(
        "--profile",
        action="store_true",
        help="Run LuaJIT profiler (-jp=v) and trace monitor (-jv) on the benchmark",
    )
    args = parser.parse_args()

    python_executables: List[str] = []
    if args.compare_pythons:
        v312 = Path(__file__).resolve().parent.parent.parent / ".venv" / "bin" / "python"
        if v312.is_file():
            python_executables.append(str(v312))
        sys_py = "/usr/bin/python3"
        if Path(sys_py).is_file() and sys_py not in python_executables:
            python_executables.append(sys_py)
    elif args.python:
        python_executables.append(args.python)
    else:
        v312 = Path(__file__).resolve().parent.parent.parent / ".venv" / "bin" / "python"
        if v312.is_file():
            python_executables.append(str(v312))
        else:
            python_executables.append(sys.executable)

    # Determine payloads to run
    if args.payload == "all":
        payloads = ["synthetic", "test.torrent", "dir_with_6_files.torrent", "ubuntu-9.04-desktop-i386.iso.torrent"]
    else:
        payloads = [args.payload]

    # Determine operations to run
    if args.operation == "all":
        ops = ["decode", "encode", "roundtrip"]
    else:
        ops = [args.operation]

    # Generate workloads
    workloads: List[Tuple[str, str]] = []
    for p in payloads:
        for op in ops:
            if op == "decode":
                wl, name = production_bencode_decode_workload(
                    args.target_root, p, repetitions=args.repetitions, in_process_warmups=args.in_process_warmups
                )
            elif op == "encode":
                wl, name = production_bencode_encode_workload(
                    args.target_root, p, repetitions=args.repetitions, in_process_warmups=args.in_process_warmups
                )
            else:
                wl, name = production_bencode_roundtrip_workload(
                    args.target_root, p, repetitions=args.repetitions, in_process_warmups=args.in_process_warmups
                )
            workloads.append((name, wl))

    # Run for each Python baseline
    for py_exec in python_executables:
        runner = BenchmarkRunner(args.work_dir, python_executable=py_exec)
        print(f"\nRunning benchmark suite against {runner.python_version} ({py_exec})...")
        for name, wl in workloads:
            res = runner.run_benchmark(
                name,
                wl,
                iterations=args.iterations,
                warmups=args.warmups,
            )
            print(
                f"  {name:<32} -> Steady: {res.steady_speedup:.2f}x (CPython: {res.cpython_steady_sec:.5f}s, Luthon: {res.luthon_steady_sec:.5f}s) [{'Verified' if res.verified else 'MISMATCH'}]"
            )
            if not res.verified:
                raise SystemExit(f"Verification failed for {name}: outputs differ!")

        print("\n" + runner.generate_report())

        if args.profile and workloads:
            run_luajit_profile(args.work_dir, workloads[0][0])


if __name__ == "__main__":
    main()
