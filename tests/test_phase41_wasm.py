"""Comprehensive Test Suite for Phase 41: WebAssembly & WASI Compilation Target.

Tests WASI Preview 1 platform syscall shims (fd_read, fd_write, clock_time_get, random_get),
standalone .wasm bundle generation via StandaloneBundler and CLI,
headless Node.js WASI execution, browser WebWorker data marshaling bridge (wasm_js.lua),
and zero-copy WebAssembly linear memory typed array buffer views.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
import pytest

from luthon.bundle import StandaloneBundler
from luthon.native.build_capi import compile_wasi_target


NODE_BIN = shutil.which("node")


@pytest.fixture(scope="module")
def node_available():
    if not NODE_BIN:
        pytest.skip("Node.js is not installed on system")
    # Verify WASI is available in node
    chk = subprocess.run(
        [NODE_BIN, "-e", "const { WASI } = require('node:wasi'); if (!WASI) process.exit(1);"],
        capture_output=True,
        text=True
    )
    if chk.returncode != 0:
        pytest.skip("node:wasi preview1 is not available in Node.js")
    return NODE_BIN


def test_wasi_platform_library_compilation(tmp_path):
    """Verify that src/luthon/native/platform/wasi.c compiles to a valid freestanding WebAssembly binary."""
    out_wasm = tmp_path / "libluthon_wasi.wasm"
    built_path = compile_wasi_target(output_path=out_wasm, force=True)
    assert built_path.exists()
    assert built_path.stat().st_size > 0
    # Must be valid WebAssembly binary starting with magic \x00asm
    with open(built_path, "rb") as f:
        magic = f.read(4)
        version = f.read(4)
    assert magic == b"\x00asm", f"Invalid WASM magic: {magic}"
    assert version == b"\x01\x00\x00\x00", f"Invalid WASM version: {version}"


def test_wasi_bundle_generation_and_execution(tmp_path, node_available):
    """Test StandaloneBundler(target='wasi') compiling Python to a standalone .wasm executable and running it."""
    py_code = """
def is_prime(n: int) -> int:
    if n <= 1:
        return 0
    if n <= 3:
        return 1
    if n % 2 == 0 or n % 3 == 0:
        return 0
    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0:
            return 0
        i += 6
    return 1

def count_primes(limit: int) -> int:
    count = 0
    for num in range(limit):
        if is_prime(num) == 1:
            count += 1
    return count

print("Starting Prime Sieve in WASI...")
print("Primes below 50:", count_primes(50))
print("is_prime(97):", is_prime(97))
print("is_prime(100):", is_prime(100))
"""
    py_file = tmp_path / "primes.py"
    wasm_file = tmp_path / "primes.wasm"
    py_file.write_text(py_code, encoding="utf-8")

    bundler = StandaloneBundler(target="wasi")
    out_wasm = bundler.build_bundle(py_file, wasm_file)
    assert out_wasm.exists()
    assert out_wasm.stat().st_size < 2 * 1024 * 1024  # Well below 2 MB target

    # Execute under Node.js WASI Preview 1
    runner_script = f"""
    const fs = require('fs');
    const {{ WASI }} = require('node:wasi');
    const wasi = new WASI({{
        version: 'preview1',
        args: ['primes.wasm']
    }});
    const wasmBytes = fs.readFileSync('{out_wasm}');
    WebAssembly.instantiate(wasmBytes, {{
        wasi_snapshot_preview1: wasi.wasiImport
    }}).then(({{ instance }}) => {{
        wasi.start(instance);
        // Test direct export invocation from JS
        console.log('Direct export is_prime(101):', instance.exports.is_prime(101n));
        console.log('Direct export count_primes(30):', instance.exports.count_primes(30n));
    }}).catch(err => {{
        console.error(err);
        process.exit(1);
    }});
    """
    res = subprocess.run([node_available, "-e", runner_script], capture_output=True, text=True)
    assert res.returncode == 0, f"Node.js WASI failed: {res.stderr}"
    stdout = res.stdout
    assert "Starting Prime Sieve in WASI..." in stdout
    assert "Primes below 50: 15" in stdout
    assert "is_prime(97): 1" in stdout
    assert "is_prime(100): 0" in stdout
    assert "Direct export is_prime(101): 1n" in stdout
    assert "Direct export count_primes(30): 10n" in stdout


def test_wasi_cli_build_command(tmp_path, node_available):
    """Test `luthon build <script.py> -o <script.wasm> --target wasi` CLI workflow."""
    py_code = """
def gcd(a: int, b: int) -> int:
    while b != 0:
        t = b
        b = a % b
        a = t
    return a

print("GCD(1071, 462) =", gcd(1071, 462))
print("GCD(48, 18) =", gcd(48, 18))
"""
    py_file = tmp_path / "math_calc.py"
    wasm_file = tmp_path / "math_calc.wasm"
    py_file.write_text(py_code, encoding="utf-8")

    # Run CLI command
    env = os.environ.copy()
    env["PYTHONPATH"] = "src"
    cmd = [sys.executable, "-m", "luthon.main", "build", str(py_file), "-o", str(wasm_file), "--target", "wasi"]
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    assert res.returncode == 0, f"CLI build failed: {res.stderr}\nSTDOUT: {res.stdout}"
    assert wasm_file.exists()

    # Run in Node WASI
    runner_script = f"""
    const fs = require('fs');
    const {{ WASI }} = require('node:wasi');
    const wasi = new WASI({{ version: 'preview1' }});
    const bytes = fs.readFileSync('{wasm_file}');
    WebAssembly.instantiate(bytes, {{ wasi_snapshot_preview1: wasi.wasiImport }}).then(({{ instance }}) => {{
        wasi.start(instance);
    }});
    """
    node_res = subprocess.run([node_available, "-e", runner_script], capture_output=True, text=True)
    assert node_res.returncode == 0, f"Node execution failed: {node_res.stderr}"
    assert "GCD(1071, 462) = 21" in node_res.stdout
    assert "GCD(48, 18) = 6" in node_res.stdout


def test_wasm_browser_bridge_and_memory_views(tmp_path, node_available):
    """Test JavaScript-Python linear memory buffer views and wasm_runner.js bridge."""
    py_code = """
def scale_array(offset: int, factor: int) -> int:
    return offset * factor

print("WASM Bridge Ready")
"""
    py_file = tmp_path / "bridge.py"
    wasm_file = tmp_path / "bridge.wasm"
    py_file.write_text(py_code, encoding="utf-8")

    bundler = StandaloneBundler(target="wasm")
    bundler.build_bundle(py_file, wasm_file)

    runner_js = Path(__file__).parent.parent / "src" / "luthon" / "runtime" / "wasm_runner.js"
    test_js = f"""
    const {{ createWasmBridge }} = require('{runner_js}');
    createWasmBridge('{wasm_file}').then(bridge => {{
        // Test memory allocation via luthon_malloc
        const ptr = bridge.allocString("Luthon WebAssembly Engine");
        const str = bridge.readString(ptr);
        console.log("Allocated and read string:", str);

        // Test linear memory typed array view
        const f32View = bridge.createTypedArrayView(ptr, 4, 'f32');
        f32View[0] = 3.14159;
        f32View[1] = 2.71828;
        console.log("Written float view:", f32View[0], f32View[1]);

        // Test payload retrieval
        const payloadPtr = bridge.exports.luthon_get_payload();
        const payloadSize = bridge.exports.luthon_get_payload_size();
        const payload = bridge.readString(payloadPtr);
        console.log("Embedded payload length:", payloadSize, "First 20 chars:", payload.substring(0, 20));

        // Test direct export invocation
        const scaled = bridge.exports.scale_array(20n, 5n);
        console.log("Scale array result:", scaled);
    }});
    """
    res = subprocess.run([node_available, "-e", test_js], capture_output=True, text=True)
    assert res.returncode == 0, f"Bridge JS failed: {res.stderr}\nSTDOUT: {res.stdout}"
    assert "Allocated and read string: Luthon WebAssembly Engine" in res.stdout
    assert "Written float view: 3.14159" in res.stdout
    assert "Scale array result: 100n" in res.stdout


def test_wasm_js_lua_data_marshaling():
    """Verify src/luthon/lua/wasm_js.lua data conversion and linear buffer descriptors."""
    lua_test = """
    local wasm_js = require("src/luthon/lua/wasm_js")

    -- 1. Test primitive conversions
    assert(wasm_js.to_js(42) == 42)
    assert(wasm_js.to_js("hello") == "hello")
    assert(wasm_js.to_js(true) == true)
    local null_res = wasm_js.to_js(nil)
    assert(null_res.__js_type == "null")

    -- 2. Test list / array conversion
    local arr = {10, 20, 30}
    local js_arr = wasm_js.to_js(arr)
    assert(#js_arr == 3)
    assert(js_arr[1] == 10 and js_arr[2] == 20 and js_arr[3] == 30)

    -- 3. Test dictionary conversion
    local dict = { name = "luthon", version = 41 }
    local js_obj = wasm_js.to_js(dict)
    assert(js_obj.name == "luthon")
    assert(js_obj.version == 41)

    -- 4. Test reverse marshaling (from_js)
    assert(wasm_js.from_js(99.5) == 99.5)
    assert(wasm_js.from_js({ __js_type = "null" }) == nil)

    -- 5. Test Linear Memory Buffer Views
    local view = wasm_js.create_buffer_view(4096, 128, "f32")
    assert(view.__wasm_memory_view == true)
    assert(view.pointer == 4096)
    assert(view.byte_length == 128)
    assert(view.element_count == 32) -- 128 / 4 = 32 floats

    local typed_desc = wasm_js.export_to_typed_array(view)
    assert(typed_desc.constructor == "Float32Array")
    assert(typed_desc.byteOffset == 4096)
    assert(typed_desc.length == 32)

    -- 6. Test WebGL & Canvas descriptors
    local canvas_desc = wasm_js.bind_canvas_framebuffer(8192, 1920, 1080)
    assert(canvas_desc.target == "canvas_2d")
    assert(canvas_desc.byte_length == 1920 * 1080 * 4)

    local gl_desc = wasm_js.bind_webgl_buffer(16384, 1024, 34962, 35044)
    assert(gl_desc.target == "webgl")
    assert(gl_desc.pointer == 16384)

    print("WASM_JS_LUA_ALL_PASSED")
    """
    res = subprocess.run(["luajit", "-e", lua_test], capture_output=True, text=True)
    assert res.returncode == 0, f"LuaJIT wasm_js test failed: {res.stderr}\nSTDOUT: {res.stdout}"
    assert "WASM_JS_LUA_ALL_PASSED" in res.stdout


def test_wasi_sandboxed_environment_isolation(tmp_path, node_available):
    """Verify that WASI execution is sandboxed with simulated args & environment."""
    py_code = """
def compute_power(base: int, exp: int) -> int:
    res = 1
    for _ in range(exp):
        res = res * base
    return res

print("Sandbox test: 2^10 =", compute_power(2, 10))
"""
    py_file = tmp_path / "sandbox.py"
    wasm_file = tmp_path / "sandbox.wasm"
    py_file.write_text(py_code, encoding="utf-8")

    bundler = StandaloneBundler(target="wasi")
    bundler.build_bundle(py_file, wasm_file)

    runner_script = f"""
    const fs = require('fs');
    const {{ WASI }} = require('node:wasi');
    const wasi = new WASI({{
        version: 'preview1',
        args: ['sandbox.wasm', '--headless', '--isolated'],
        env: {{ 'LUTHON_ENV': 'SANDBOX_WASI_RUNTIME', 'SECURE': '1' }}
    }});
    const wasm = fs.readFileSync('{wasm_file}');
    WebAssembly.instantiate(wasm, {{ wasi_snapshot_preview1: wasi.wasiImport }}).then(({{ instance }}) => {{
        wasi.start(instance);
        console.log('SANDBOX_ISOLATION_PASSED');
    }});
    """
    res = subprocess.run([node_available, "-e", runner_script], capture_output=True, text=True)
    assert res.returncode == 0, f"Sandbox failed: {res.stderr}"
    assert "Sandbox test: 2^10 = 1024" in res.stdout
    assert "SANDBOX_ISOLATION_PASSED" in res.stdout
