"""Phase 21: Real-Time Systems, Zero-GC Freelists & Domain Benchmarks Tests."""

import subprocess
import time
from pathlib import Path
import pytest
from luthon.cli import compile_file


def test_zerogc_preallocated_memory_freelist(tmp_path):
    """Verify zero-GC freelist acquisition, mutation, recycling and capacity limits."""
    lua_code = """
local ffi = require("ffi")
local pool = require("src/luthon/lua/freelist")

ffi.cdef[[
  typedef struct {
    int64_t timestamp;
    double price;
    int32_t qty;
  } MarketTick;
]]

local fl = pool.create_freelist("MarketTick", 100)
assert(fl:capacity() == 100)
assert(fl:allocated() == 0)

-- Acquire 5 ticks
local ticks = {}
for i = 1, 5 do
  local tick, idx = fl:acquire()
  tick.timestamp = i * 1000
  tick.price = 150.25 + i
  tick.qty = i * 10
  table.insert(ticks, {tick, idx})
end

assert(fl:allocated() == 5)
assert(ticks[1][1].price == 151.25)
assert(ticks[5][1].qty == 50)

-- Release back to pool
for i = 1, 5 do
  fl:release(ticks[i][2])
end
assert(fl:allocated() == 0)

-- Re-acquire (should reuse same buffer positions without GC allocations)
local tick_reused, idx_reused = fl:acquire()
assert(idx_reused == ticks[5][2])
fl:release(idx_reused)

print("ZERO_GC_FREELIST_OK")
"""
    lua_file = tmp_path / "test_freelist.lua"
    lua_file.write_text(lua_code)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "ZERO_GC_FREELIST_OK" in res.stdout


def test_clbg_spectral_norm_benchmark(tmp_path):
    """Computer Language Benchmarks Game: Spectral-Norm algorithm execution."""
    py_code = """
def eval_A(i, j):
    return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1)

def eval_A_times_u(N, u, Au):
    for i in range(N):
        Au[i] = 0.0
        for j in range(N):
            Au[i] = Au[i] + eval_A(i, j) * u[j]

N = 100
u = [1.0 for _ in range(N)]
v = [0.0 for _ in range(N)]

eval_A_times_u(N, u, v)
assert v[0] > 0.0
assert v[99] > 0.0
print("SPECTRAL_NORM_OK")
"""
    py_file = tmp_path / "spectral_norm.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "spectral_norm.lua"

    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    t0 = time.time()
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    t_elapsed = time.time() - t0

    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "SPECTRAL_NORM_OK" in res.stdout
    assert t_elapsed < 2.0  # Runs in milliseconds under LuaJIT


def test_clbg_nbody_benchmark(tmp_path):
    """Computer Language Benchmarks Game: N-body gravitational simulation step."""
    py_code = """
import math

class Body:
    def __init__(self, x, y, z, vx, vy, vz, mass):
        self.x = x
        self.y = y
        self.z = z
        self.vx = vx
        self.vy = vy
        self.vz = vz
        self.mass = mass

sun = Body(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)
jupiter = Body(4.84, -1.16, -0.10, 0.001, 0.007, -0.0001, 0.00095)

dx = sun.x - jupiter.x
dy = sun.y - jupiter.y
dz = sun.z - jupiter.z
dist = math.sqrt(dx * dx + dy * dy + dz * dz)
assert dist > 4.0
print("NBODY_OK")
"""
    py_file = tmp_path / "nbody.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "nbody.lua"

    compile_file(py_file, use_ir=True, optimize=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "NBODY_OK" in res.stdout
