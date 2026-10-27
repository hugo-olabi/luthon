"""Phase 23: Standalone Embedded Executable Packaging (Luthon Static Bundle) Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.bundle import StandaloneBundler


def test_standalone_bundle_creation_and_execution(tmp_path):
    """Verify that a Python program can be packaged into a standalone executable bundle."""
    py_code = """
import sys

def fib(n):
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)

name = sys.argv[1] if len(sys.argv) > 1 else "World"
print(f"Hello, {name}! fib(6) = {fib(6)}")
"""
    py_file = tmp_path / "app.py"
    py_file.write_text(py_code)

    exe_file = tmp_path / "app_bundle.bin"
    bundler = StandaloneBundler(optimize=True)
    out_path = bundler.build_bundle(py_file, exe_file)

    assert out_path.is_file()
    assert out_path.stat().st_mode & 0o111 != 0  # Check executable permissions
    assert out_path.stat().st_size < 1_000_000   # Check bundle footprint is compact (<1 MB)

    # Run the standalone executable directly without calling python or luajit
    res = subprocess.run([str(exe_file), "LuthonUser"], capture_output=True, text=True)
    assert res.returncode == 0, f"Execution failed: {res.stderr}"
    assert "Hello, LuthonUser! fib(6) = 8" in res.stdout


def test_standalone_cli_build_command(tmp_path):
    """Verify `luthon build <file.py> -o <binary>` command line invocation."""
    py_code = "print('STANDALONE_CLI_OK')"
    py_file = tmp_path / "cli_app.py"
    py_file.write_text(py_code)

    exe_file = tmp_path / "cli_binary"

    res_build = subprocess.run(
        ["python3", "-m", "luthon.main", "build", str(py_file), "-o", str(exe_file)],
        capture_output=True, text=True, env={"PYTHONPATH": "src"}
    )
    assert res_build.returncode == 0, f"Build command failed: {res_build.stderr}"
    assert exe_file.is_file()

    res_exec = subprocess.run([str(exe_file)], capture_output=True, text=True)
    assert res_exec.returncode == 0
    assert "STANDALONE_CLI_OK" in res_exec.stdout
