"""Phase 20: Native HPy Universal ABI & Zero-Copy CData Buffers Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.pip import PipInstaller


def test_hpy_handle_management_and_ownership(tmp_path):
    """Verify HPy handle creation, object resolution, duplication and closure."""
    lua_code = """
local hpy = require("src/luthon/lua/hpy")

-- Create HPy handle
local py_obj = {name = "sample_record", val = 42}
local h = hpy.HPy_FromPyObject(py_obj)
assert(h._i ~= nil)

-- Resolve handle back to object
local resolved = hpy.HPy_ToPyObject(h)
assert(resolved.name == "sample_record")
assert(resolved.val == 42)

-- Duplicate handle
local h2 = hpy.HPy_Dup(h)
assert(h2._i ~= h._i)
assert(hpy.HPy_ToPyObject(h2).val == 42)

-- Close original handle
hpy.HPy_Close(h)
assert(hpy.HPy_ToPyObject(h) == nil)

-- Duplicate remains valid (handle ownership rules)
assert(hpy.HPy_ToPyObject(h2).val == 42)
hpy.HPy_Close(h2)
assert(hpy.HPy_ToPyObject(h2) == nil)

print("HPY_HANDLES_OK")
"""
    lua_file = tmp_path / "test_hpy.lua"
    lua_file.write_text(lua_code)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "HPY_HANDLES_OK" in res.stdout


def test_zerocopy_numpy_cdata_wrapping(tmp_path):
    """Verify PyArray_SimpleNewFromData wraps FFI buffer without copying."""
    lua_code = """
local ffi = require("ffi")
local hpy = require("src/luthon/lua/hpy")

-- Allocate contiguous C buffer
local buf = ffi.new("double[4]", {10.0, 20.0, 30.0, 40.0})

-- Wrap with PyArray_SimpleNewFromData
local ndarray = hpy.PyArray_SimpleNewFromData(1, {4}, "float64", buf)
assert(ndarray.ndim == 1)
assert(ndarray.shape[1] == 4)
assert(ndarray:get(0) == 10.0)
assert(ndarray:get(3) == 40.0)

-- Mutate through ndarray and check that underlying C buffer changes (zero-copy)
ndarray:set(1, 99.5)
assert(buf[1] == 99.5)

-- Mutate buffer and check ndarray
buf[2] = 77.25
assert(ndarray:get(2) == 77.25)

local lst = ndarray:tolist()
assert(#lst == 4)
assert(lst[2] == 99.5)

print("ZERO_COPY_NUMPY_OK")
"""
    lua_file = tmp_path / "test_numpy.lua"
    lua_file.write_text(lua_code)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "ZERO_COPY_NUMPY_OK" in res.stdout


def test_hpy_wheel_selection_preference():
    """Verify luthon-pip prioritizes HPy Universal wheels when available."""
    installer = PipInstaller()
    info = {
        "info": {"name": "ujson-hpy"},
        "urls": [
            {"filename": "ujson_hpy-1.0.0-py3-none-any.whl", "url": "https://example.com/py3.whl"},
            {"filename": "ujson_hpy-1.0.0-cp310-cp310-hpy_universal.whl", "url": "https://example.com/hpy.whl"},
        ]
    }
    best_url, best_fn = installer.find_best_wheel(info)
    assert "hpy" in best_fn
    assert best_url == "https://example.com/hpy.whl"
