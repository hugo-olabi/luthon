"""Phase 26: High-Throughput Asset & Serialization Performance Tests."""

import json
import base64
import os
import subprocess
from pathlib import Path
import pytest

from luthon.benchmarks import (
    BenchmarkRunner,
    WORKLOAD_JSON,
    WORKLOAD_BASE64,
)
from luthon.cli import run_file, compile_file


def test_base64_ffi_decoding_and_encoding_parity(tmp_path):
    """Verify FFI Base64 decoder against CPython base64 module across edge cases."""
    test_cases = [
        b"",
        b"a",
        b"ab",
        b"abc",
        b"Hello, Luthon high-throughput Phase 26 serialization!",
        b"\x00\x01\x02\x03\x04\xfe\xff",
        b"Binary\x00with\x00nulls\x00and\xffhigh\xfebytes",
        b"Chunk" * 1000,
    ]

    for i, raw in enumerate(test_cases):
        b64_str = base64.b64encode(raw).decode("ascii")
        py_code = f"""
import base64

raw_b64 = {repr(b64_str)}
decoded = base64.b64decode(raw_b64)
encoded = base64.b64encode(decoded)
if isinstance(encoded, bytes):
    encoded = encoded.decode("ascii")
print("LEN:", len(decoded))
print("RE_ENC:", encoded == raw_b64)
"""
        py_file = tmp_path / f"test_b64_{i}.py"
        lua_file = tmp_path / f"test_b64_{i}.lua"
        py_file.write_text(py_code)

        compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

        env = os.environ.copy()
        pkg_src = str(Path(__file__).parent.parent / "src")
        extra_paths = f"{pkg_src}/?.lua;{pkg_src}/?/init.lua;{pkg_src}/luthon/lua/?.lua"
        env["LUA_PATH"] = f"{extra_paths};;"

        res_lua = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=env)
        assert res_lua.returncode == 0, f"Lua failed: {res_lua.stderr}"

        res_py = subprocess.run(["python3", str(py_file)], capture_output=True, text=True)
        assert res_py.returncode == 0

        norm_lua = " ".join(res_lua.stdout.strip().lower().split())
        norm_py = " ".join(res_py.stdout.strip().lower().split())
        assert norm_lua == norm_py


def test_json_ffi_decoding_parity(tmp_path):
    """Verify FFI cJSON / fast JSON parser against CPython json module."""
    data = {
        "integer": 42,
        "negative": -1337,
        "float": 3.14159265,
        "scientific": 1.25e-4,
        "string": "Hello \"world\"\n\t\r\\escaped",
        "boolean_true": True,
        "boolean_false": False,
        "null_val": None,
        "nested_object": {"a": 1, "b": [1, 2, 3]},
        "array_of_objects": [{"id": i, "name": f"item_{i}"} for i in range(10)],
    }
    json_str = json.dumps(data)

    py_code = f"""
import json

raw_json = {repr(json_str)}
obj = json.loads(raw_json)
print("INT:", obj["integer"])
print("FLOAT:", round(obj["float"], 4))
print("BOOL:", obj["boolean_true"], obj["boolean_false"])
print("NESTED:", obj["nested_object"]["a"])
print("ARR_LEN:", len(obj["array_of_objects"]))
print("ARR_ITEM:", obj["array_of_objects"][5]["name"])
"""
    py_file = tmp_path / "test_json.py"
    lua_file = tmp_path / "test_json.lua"
    py_file.write_text(py_code)

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    env = os.environ.copy()
    pkg_src = str(Path(__file__).parent.parent / "src")
    extra_paths = f"{pkg_src}/?.lua;{pkg_src}/?/init.lua;{pkg_src}/luthon/lua/?.lua"
    env["LUA_PATH"] = f"{extra_paths};;"

    res_lua = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=env)
    assert res_lua.returncode == 0, f"Lua failed: {res_lua.stderr}"

    res_py = subprocess.run(["python3", str(py_file)], capture_output=True, text=True)
    assert res_py.returncode == 0

    norm_lua = " ".join(res_lua.stdout.strip().lower().split())
    norm_py = " ".join(res_py.stdout.strip().lower().split())
    assert norm_lua == norm_py


def test_phase26_benchmark_runner(tmp_path):
    """Verify BenchmarkRunner executes WORKLOAD_JSON and WORKLOAD_BASE64 with verified outputs."""
    runner = BenchmarkRunner(work_dir=tmp_path / "benchmarks")

    r_json = runner.run_benchmark("json_workload", WORKLOAD_JSON, iterations=1)
    assert r_json.verified is True
    assert r_json.luthon_time_sec > 0.0

    r_b64 = runner.run_benchmark("base64_workload", WORKLOAD_BASE64, iterations=1)
    assert r_b64.verified is True
    assert r_b64.luthon_time_sec > 0.0

    report = runner.generate_report()
    assert "Luthon Performance Dashboard" in report
    assert "json_workload" in report
    assert "base64_workload" in report


def test_direct_jit_cli_flag(tmp_path):
    """Verify --direct / --jit execution mode runs cached artifacts directly."""
    py_code = """
total = sum([i * 2 for i in range(50)])
print("DIRECT_OK:", total)
"""
    py_file = tmp_path / "test_direct.py"
    py_file.write_text(py_code)

    # 1. First run populates the compilation cache
    ret1 = run_file(py_file, use_ir=True, cache_dir=str(tmp_path / ".cache"))
    assert ret1 == 0

    # 2. Second run with direct_jit=True executes directly from cache
    ret2 = run_file(py_file, use_ir=True, direct_jit=True, cache_dir=str(tmp_path / ".cache"))
    assert ret2 == 0
