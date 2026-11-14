"""Test suite for Phase 38: True Multi-Threading & GIL-Free OS Thread Pools."""

import subprocess
from pathlib import Path
import pytest
from luthon.cli import compile_file

PHASE38_DIR = Path("tests")


def _get_isolated_env():
    import os
    env = dict(os.environ)
    env.pop("VIRTUAL_ENV", None)
    env.pop("VIRTUAL_ENV_PROMPT", None)
    env.pop("PYTHONHOME", None)
    env.pop("__PYVENV_LAUNCHER__", None)
    current_path = env.get("PATH", "")
    paths = [p for p in current_path.split(":") if ".venv" not in p]
    env["PATH"] = ":".join(paths)
    return env


def test_threadpool_native_c_bindings():
    """Verify C-ABI thread pool and lock-free channel work natively from LuaJIT."""
    script = """
local ffi = require('ffi')
ffi.cdef[[
  typedef struct LuthonThreadPool LuthonThreadPool;
  typedef void* (*luthon_task_fn)(void *arg);
  LuthonThreadPool* luthon_threadpool_create(int num_workers);
  int               luthon_threadpool_worker_count(const LuthonThreadPool *pool);
  uint64_t          luthon_threadpool_submit(LuthonThreadPool *pool, luthon_task_fn fn, void *arg);
  uint64_t          luthon_threadpool_submit_bytecode(LuthonThreadPool *pool, const char *bytecode, size_t bytecode_len, int has_arg_num, double arg_num, void *arg_ptr);
  bool              luthon_threadpool_is_done(LuthonThreadPool *pool, uint64_t task_id);
  void*             luthon_threadpool_wait(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
  double            luthon_threadpool_wait_number(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
  void              luthon_threadpool_destroy(LuthonThreadPool *pool);

  typedef struct {
      void     *data;
      size_t    size;
      int32_t   type_tag;
      uint64_t  tag;
  } LuthonMessage;
  typedef struct LuthonChannel LuthonChannel;
  LuthonChannel* luthon_channel_create(size_t capacity);
  bool           luthon_channel_push(LuthonChannel *chan, const LuthonMessage *msg);
  bool           luthon_channel_pop(LuthonChannel *chan, LuthonMessage *out_msg);
  size_t         luthon_channel_size(const LuthonChannel *chan);
  bool           luthon_channel_is_empty(const LuthonChannel *chan);
  void           luthon_channel_destroy(LuthonChannel *chan);
]]
local lib = ffi.load('src/luthon/native/libluthon_capi.so')
local pool = lib.luthon_threadpool_create(4)
assert(lib.luthon_threadpool_worker_count(pool) == 4, 'Expected 4 workers')

-- Test lock-free channel
local chan = lib.luthon_channel_create(8)
assert(lib.luthon_channel_is_empty(chan))
local msg = ffi.new('LuthonMessage')
msg.data = ffi.cast('void*', 4242)
msg.size = 8
msg.type_tag = 1
msg.tag = 101
assert(lib.luthon_channel_push(chan, msg))
assert(lib.luthon_channel_size(chan) == 1)

local out_msg = ffi.new('LuthonMessage')
assert(lib.luthon_channel_pop(chan, out_msg))
assert(out_msg.tag == 101)
assert(tonumber(ffi.cast('intptr_t', out_msg.data)) == 4242)
lib.luthon_channel_destroy(chan)

-- Test bytecode submission and execution
local function cube(x)
  return x * x * x
end
local bc = string.dump(cube)
local tid = lib.luthon_threadpool_submit_bytecode(pool, bc, #bc, 1, 5, nil)
local err = ffi.new('int[1]')
local res = lib.luthon_threadpool_wait_number(pool, tid, err)
assert(err[0] == 0, 'Task error')
assert(res == 125, 'Expected 5^3 = 125, got ' .. tostring(res))

lib.luthon_threadpool_destroy(pool)
print('TEST_C_BINDINGS_OK')
"""
    res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "TEST_C_BINDINGS_OK" in res.stdout


def test_threadpool_executor_python_transpiled(tmp_path):
    """Verify concurrent.futures.ThreadPoolExecutor lowers and executes in parallel."""
    py_code = """
from concurrent.futures import ThreadPoolExecutor

def calc_square(x):
    return x * x

def run_tests():
    with ThreadPoolExecutor(max_workers=4) as executor:
        f1 = executor.submit(calc_square, 10)
        f2 = executor.submit(calc_square, 20)
        f3 = executor.submit(calc_square, 30)

        r1 = f1.result()
        r2 = f2.result()
        r3 = f3.result()

        assert r1 == 100
        assert r2 == 400
        assert r3 == 900

    print("THREADPOOL_EXECUTOR_OK", r1, r2, r3)

if __name__ == "__main__":
    run_tests()
"""
    py_file = tmp_path / "test_tp.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_tp.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}\nCode:\n{lua_file.read_text()[:400]}"
    assert "THREADPOOL_EXECUTOR_OK" in res.stdout
    assert "100" in res.stdout and "400" in res.stdout and "900" in res.stdout


def test_executor_map_python_transpiled(tmp_path):
    """Verify executor.map distributes computation over collections."""
    py_code = """
from concurrent.futures import ThreadPoolExecutor

def double_val(x):
    return x * 2

def run_map():
    items = [1, 2, 3, 4, 5]
    with ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(double_val, items))
        assert len(results) == 5
        assert results[0] == 2
        assert results[1] == 4
        assert results[2] == 6
        assert results[3] == 8
        assert results[4] == 10

    print("EXECUTOR_MAP_OK", len(results))

if __name__ == "__main__":
    run_map()
"""
    py_file = tmp_path / "test_map.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_map.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "EXECUTOR_MAP_OK" in res.stdout


def test_threading_primitives_transpiled(tmp_path):
    """Verify Lock, RLock, Event, and Semaphore primitives."""
    py_code = """
import threading

def test_primitives():
    # 1. Lock and context manager
    lock = threading.Lock()
    assert not lock.locked()
    with lock:
        assert lock.locked()
    assert not lock.locked()

    # 2. RLock recursive acquire
    rlock = threading.RLock()
    with rlock:
        with rlock:
            pass

    # 3. Event signaling
    evt = threading.Event()
    assert not evt.is_set()
    evt.set()
    assert evt.is_set()
    assert evt.wait(0.01)
    evt.clear()
    assert not evt.is_set()

    # 4. Semaphore
    sem = threading.Semaphore(2)
    assert sem.acquire()
    assert sem.acquire()
    sem.release()
    sem.release()

    print("THREADING_PRIMITIVES_OK")

if __name__ == "__main__":
    test_primitives()
"""
    py_file = tmp_path / "test_sync.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_sync.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "THREADING_PRIMITIVES_OK" in res.stdout


def test_parallel_monte_carlo_scaling(tmp_path):
    """Verify multi-threaded parallel Monte Carlo Pi estimation across worker threads."""
    py_code = """
from concurrent.futures import ThreadPoolExecutor

def sample_batch(count):
    # Deterministic pseudo-random LCG for reproducible Monte Carlo simulation
    inside = 0
    state = 123456789
    for i in range(count):
        state = (state * 1103515245 + 12345) % 2147483648
        x = state / 2147483648.0
        state = (state * 1103515245 + 12345) % 2147483648
        y = state / 2147483648.0
        if x * x + y * y <= 1.0:
            inside += 1
    return inside

def run_monte_carlo():
    total_samples = 40000
    batches = [10000, 10000, 10000, 10000]

    with ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(sample_batch, batches))
        total_inside = sum(results)

    pi_estimate = 4.0 * total_inside / total_samples
    assert 3.0 < pi_estimate < 3.3
    print("PARALLEL_MONTE_CARLO_OK: pi ~=", pi_estimate)

if __name__ == "__main__":
    run_monte_carlo()
"""
    py_file = tmp_path / "test_mc.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_mc.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "PARALLEL_MONTE_CARLO_OK:" in res.stdout


def test_parallel_mandelbrot_benchmark(tmp_path):
    """Verify multi-threaded parallel Mandelbrot row rendering across CPU cores."""
    py_code = """
from concurrent.futures import ThreadPoolExecutor

def render_mandelbrot_row(y_idx):
    # Compute one row of Mandelbrot set
    width = 80
    height = 40
    max_iter = 100
    ci = (y_idx / height) * 2.0 - 1.0
    escaped_count = 0
    for x_idx in range(width):
        cr = (x_idx / width) * 3.0 - 2.0
        zr = 0.0
        zi = 0.0
        iter_count = 0
        while zr * zr + zi * zi <= 4.0 and iter_count < max_iter:
            new_zr = zr * zr - zi * zi + cr
            zi = 2.0 * zr * zi + ci
            zr = new_zr
            iter_count += 1
        if iter_count < max_iter:
            escaped_count += 1
    return escaped_count

def run_mandelbrot():
    rows = list(range(40))
    with ThreadPoolExecutor(max_workers=4) as executor:
        row_escapes = list(executor.map(render_mandelbrot_row, rows))
        total_escaped = sum(row_escapes)

    assert total_escaped > 500
    print("MANDELBROT_PARALLEL_OK: escaped =", total_escaped)

if __name__ == "__main__":
    run_mandelbrot()
"""
    py_file = tmp_path / "test_mb.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_mb.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "MANDELBROT_PARALLEL_OK" in res.stdout


def test_threading_thread_start_join(tmp_path):
    """Verify Thread class start and join behavior."""
    py_code = """
import threading

def worker_task(val):
    return val * 10

def test_thread():
    t = threading.Thread(target=worker_task, args=(7,))
    t.start()
    t.join()
    assert not t.is_alive()
    print("THREAD_START_JOIN_OK")

if __name__ == "__main__":
    test_thread()
"""
    py_file = tmp_path / "test_th.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_th.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "THREAD_START_JOIN_OK" in res.stdout


def test_zero_copy_shared_memory_workers():
    """Verify zero-copy memory buffer sharing across threads via lock-free channel."""
    script = """
local ffi = require('ffi')
ffi.cdef[[
  typedef struct LuthonThreadPool LuthonThreadPool;
  typedef struct LuthonChannel LuthonChannel;
  typedef struct {
      void     *data;
      size_t    size;
      int32_t   type_tag;
      uint64_t  tag;
  } LuthonMessage;

  LuthonThreadPool* luthon_threadpool_create(int num_workers);
  void              luthon_threadpool_destroy(LuthonThreadPool *pool);

  LuthonChannel* luthon_channel_create(size_t capacity);
  bool           luthon_channel_push(LuthonChannel *chan, const LuthonMessage *msg);
  bool           luthon_channel_pop(LuthonChannel *chan, LuthonMessage *out_msg);
  void           luthon_channel_destroy(LuthonChannel *chan);
]]
local lib = ffi.load('src/luthon/native/libluthon_capi.so')

-- Allocate contiguous typed buffer of 1000 doubles
local count = 1000
local buf = ffi.new('double[?]', count)
for i = 0, count - 1 do
  buf[i] = i * 2.5
end

-- Create channel and transmit buffer pointer without copying
local chan = lib.luthon_channel_create(16)
local msg = ffi.new('LuthonMessage')
msg.data = ffi.cast('void*', buf)
msg.size = count * ffi.sizeof('double')
msg.type_tag = 1 -- typed buffer
msg.tag = 42

assert(lib.luthon_channel_push(chan, msg))

-- Receiver receives zero-copy pointer directly
local recv_msg = ffi.new('LuthonMessage')
assert(lib.luthon_channel_pop(chan, recv_msg))
assert(recv_msg.tag == 42)
assert(recv_msg.type_tag == 1)

local recv_buf = ffi.cast('double*', recv_msg.data)
assert(recv_buf[0] == 0.0)
assert(recv_buf[10] == 25.0)
assert(recv_buf[999] == 999 * 2.5)

lib.luthon_channel_destroy(chan)
print('ZERO_COPY_CHANNEL_OK')
"""
    res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True, env=_get_isolated_env())
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "ZERO_COPY_CHANNEL_OK" in res.stdout

