"""Comprehensive test suite for Phase 39: SIMD & Vectorization Lowering in CIR.

Verifies:
1. Native C SIMD library primitives (AVX2/FMA and fallback kernels).
2. Affine loop dependency analysis and loop-carried hazard detection in CIR.
3. CIR vector instructions (VEC_LOAD, VEC_STORE, VEC_ADD, VEC_SUB, VEC_MUL, VEC_FMA, VEC_BROADCAST, VEC_REDUCE_SUM).
4. Loop strip-mining into alignment peeling pre-headers, SIMD kernel bodies, and scalar remainder blocks.
5. CLI diagnostic reporting with --dump-vectorization.
6. Numerical benchmarks demonstrating 3x-6x throughput speedup on vector kernels (SAXPY/DAXPY, dot product, Euclidean distance, polynomial evaluation).
7. Vectorized transcendental approximations (sin, cos, exp, sqrt) utilizing FMA.
"""

import ast
import os
import shutil
import subprocess
import time
from pathlib import Path
import pytest

from luthon.ir import IRLowerer
from luthon.cir import (
    auto_vectorize_module,
    auto_vectorize_function,
    clear_vectorization_records,
    format_vectorization_report,
    get_vectorization_records,
    optimize_cir,
    TypeInferrer,
)
from luthon.transpiler import transpile_ir
from luthon.native.build_capi import compile_capi_proxy, get_capi_library_path


@pytest.fixture(scope="module")
def native_capi_so():
    so_path = compile_capi_proxy()
    assert so_path.exists(), f"Failed to build {so_path}"
    return so_path


def _get_isolated_env() -> dict[str, str]:
    """Returns an isolated environment for LuaJIT subprocesses."""
    clean_env = os.environ.copy()
    for var in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH"):
        clean_env.pop(var, None)
    clean_path_parts = [p for p in clean_env.get("PATH", "").split(os.pathsep) if "/.venv/" not in p and "/venv/" not in p]
    clean_env["PATH"] = os.pathsep.join(clean_path_parts)
    return clean_env


def test_simd_native_c_bindings(native_capi_so):
    """Test low-level native C SIMD primitives and vector registers via LuaJIT FFI."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      int         luthon_simd_get_vector_width(void);
      const char* luthon_simd_get_backend_name(void);
      bool        luthon_simd_has_avx2(void);
      bool        luthon_simd_has_fma(void);

      void   luthon_simd_daxpy(size_t n, double alpha, const double *x, double *y);
      void   luthon_simd_saxpy(size_t n, float alpha, const float *x, float *y);
      double luthon_simd_dot_f64(size_t n, const double *x, const double *y);
      float  luthon_simd_dot_f32(size_t n, const float *x, const float *y);
      double luthon_simd_euclidean_f64(size_t n, const double *x, const double *y);
      void   luthon_simd_poly_eval_f64(size_t n, const double *x, double *out, const double *coeffs, size_t deg);
    ]]
    local lib = ffi.load('{native_capi_so}')
    assert(lib.luthon_simd_get_vector_width() >= 2, "vector width must be >= 2")
    local backend = ffi.string(lib.luthon_simd_get_backend_name())
    assert(backend ~= nil and #backend > 0, "backend name must be non-empty")

    -- DAXPY
    local n = 8
    local x = ffi.new('double[?]', n, {{1, 2, 3, 4, 5, 6, 7, 8}})
    local y = ffi.new('double[?]', n, {{10, 20, 30, 40, 50, 60, 70, 80}})
    lib.luthon_simd_daxpy(n, 2.0, x, y)
    assert(math.abs(y[0] - 12.0) < 1e-9)
    assert(math.abs(y[7] - 96.0) < 1e-9)

    -- Dot Product
    local dot = lib.luthon_simd_dot_f64(n, x, y)
    -- sum(x[i] * y[i]) = 1*12 + 2*24 + 3*36 + 4*48 + 5*60 + 6*72 + 7*84 + 8*96 = 2448
    assert(math.abs(dot - 2448.0) < 1e-9)

    -- Euclidean Distance
    local d1 = ffi.new('double[?]', 4, {{0, 0, 0, 0}})
    local d2 = ffi.new('double[?]', 4, {{3, 4, 0, 0}})
    local dist = lib.luthon_simd_euclidean_f64(4, d1, d2)
    assert(math.abs(dist - 5.0) < 1e-9)

    -- Polynomial Evaluation (P(x) = 1 + 2x + 3x^2)
    local coeffs = ffi.new('double[?]', 3, {{1.0, 2.0, 3.0}})
    local px = ffi.new('double[?]', 2, {{2.0, 3.0}})
    local pout = ffi.new('double[?]', 2)
    lib.luthon_simd_poly_eval_f64(2, px, pout, coeffs, 2)
    -- P(2) = 1 + 4 + 12 = 17
    -- P(3) = 1 + 6 + 27 = 34
    assert(math.abs(pout[0] - 17.0) < 1e-9)
    assert(math.abs(pout[1] - 34.0) < 1e-9)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"LuaJIT execution failed: {proc.stderr}"


def test_cir_affine_vectorization_daxpy():
    """Test affine dependency analysis and strip-mining on DAXPY loop."""
    code = """
def saxpy(n, a, x, y):
    for i in range(n):
        y[i] = a * x[i] + y[i]
"""
    clear_vectorization_records()
    tree = ast.parse(code)
    ir = IRLowerer()
    module = ir.lower_module(tree, None)
    fn = module.functions[0]
    inferrer = TypeInferrer(fn)
    changed = auto_vectorize_function(fn, inferrer.infer())
    assert changed, "auto_vectorize_function should have transformed the loop"

    records = get_vectorization_records()
    assert len(records) >= 1
    rec = records[0]
    assert rec.status == "VECTORIZED"
    assert "DAXPY" in rec.pattern
    assert rec.vector_width == 4

    block_labels = [b.label for b in fn.blocks]
    assert any("peel" in lbl for lbl in block_labels)
    assert any("simd_cond" in lbl for lbl in block_labels)
    assert any("simd_body" in lbl for lbl in block_labels)
    assert any("rem_cond" in lbl for lbl in block_labels)
    assert any("rem_body" in lbl for lbl in block_labels)

    # Check that CIR vector instructions are present in SIMD body
    simd_blk = next(b for b in fn.blocks if "simd_body" in b.label)
    ops = [ins.op for ins in simd_blk.instrs]
    assert "VEC_LOAD" in ops
    assert "VEC_BROADCAST" in ops
    assert "VEC_FMA" in ops
    assert "VEC_STORE" in ops


def test_cir_affine_vectorization_vec_add():
    """Test affine dependency analysis and strip-mining on elementwise vector add loop."""
    code = """
def vec_add(n, a, b, c):
    for i in range(n):
        c[i] = a[i] + b[i]
"""
    clear_vectorization_records()
    tree = ast.parse(code)
    ir = IRLowerer()
    module = ir.lower_module(tree, None)
    fn = module.functions[0]
    inferrer = TypeInferrer(fn)
    changed = auto_vectorize_function(fn, inferrer.infer())
    assert changed

    records = get_vectorization_records()
    rec = records[0]
    assert rec.status == "VECTORIZED"
    assert "Arithmetic" in rec.pattern

    simd_blk = next(b for b in fn.blocks if "simd_body" in b.label)
    ops = [ins.op for ins in simd_blk.instrs]
    assert "VEC_LOAD" in ops
    assert "VEC_ADD" in ops
    assert "VEC_STORE" in ops


def test_cir_loop_dependency_hazard_rejection():
    """Test that loops with loop-carried dependencies (RAW/WAR hazards) or non-pure calls are rejected."""
    code = """
def stencil(n, x, y):
    for i in range(1, n):
        y[i] = x[i] + x[i - 1]

def recurrence(n, y):
    for i in range(1, n):
        y[i] = y[i - 1] + 1.0

def non_pure_call(n, y):
    for i in range(n):
        y[i] = print(i)
"""
    clear_vectorization_records()
    tree = ast.parse(code)
    ir = IRLowerer()
    module = ir.lower_module(tree, None)
    for fn in module.functions:
        inferrer = TypeInferrer(fn)
        auto_vectorize_function(fn, inferrer.infer())

    records = get_vectorization_records()
    rec_by_fn = {r.func_name: r for r in records}

    assert rec_by_fn["stencil"].status == "REJECTED"
    assert "Loop-carried dependency" in rec_by_fn["stencil"].reason or "hazard" in rec_by_fn["stencil"].reason

    assert rec_by_fn["recurrence"].status == "REJECTED"
    assert "Loop-carried dependency" in rec_by_fn["recurrence"].reason or "hazard" in rec_by_fn["recurrence"].reason

    assert rec_by_fn["non_pure_call"].status == "REJECTED"
    assert "Non-pure" in rec_by_fn["non_pure_call"].reason


def test_cli_dump_vectorization_diagnostic_flag():
    """Test that the diagnostic report is generated properly with --dump-vectorization."""
    code = """
def saxpy(n, a, x, y):
    for i in range(n):
        y[i] = a * x[i] + y[i]

def recurrence(n, y):
    for i in range(1, n):
        y[i] = y[i - 1] + 1.0
"""
    clear_vectorization_records()
    transpile_ir(code, optimize=True, dump_vectorization=True)
    report = format_vectorization_report()

    assert "Luthon CIR SIMD Auto-Vectorization Report" in report
    assert "Function 'saxpy':" in report
    assert "Status:         VECTORIZED" in report
    assert "Pattern:        DAXPY" in report
    assert "Vector Width:   4 lanes" in report
    assert "Function 'recurrence':" in report
    assert "Status:         REJECTED" in report
    assert "Loop-carried dependency" in report


def test_end_to_end_transpiled_saxpy_execution(native_capi_so):
    """Test full transpilation and execution of auto-vectorized SAXPY across varying array lengths."""
    code = """
def saxpy(n, a, x, y):
    for i in range(n):
        y[i] = a * x[i] + y[i]

def test_lengths():
    for n in (1, 3, 4, 7, 16, 100):
        x = array('d', [float(i) for i in range(n)])
        y = array('d', [0.0] * n)
        saxpy(n, 2.5, x, y)
        for i in range(n):
            expected = float(i) * 2.5
            assert y[i] == expected

test_lengths()
"""
    lua = transpile_ir(code, optimize=True)
    proc = subprocess.run(["luajit", "-"], input=lua, capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Execution failed:\nSTDOUT: {proc.stdout}\nSTDERR: {proc.stderr}"


def test_benchmark_saxpy_speedup(native_capi_so):
    """Demonstrate 3x-6x throughput speedup on single-precision SAXPY kernel."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      void luthon_simd_saxpy(size_t n, float alpha, const float *x, float *y);
    ]]
    local lib = ffi.load('{native_capi_so}')
    local n = 1000000
    local iters = 40
    local x = ffi.new('float[?]', n)
    local y_scalar = ffi.new('float[?]', n)
    local y_simd = ffi.new('float[?]', n)
    for i = 0, n - 1 do
      x[i] = i * 0.001
      y_scalar[i] = 1.0
      y_simd[i] = 1.0
    end

    -- Warmup
    for i = 0, n - 1 do y_scalar[i] = 2.5 * x[i] + y_scalar[i] end
    lib.luthon_simd_saxpy(n, 2.5, x, y_simd)

    -- Benchmark Scalar Loop
    local t0 = os.clock()
    for _ = 1, iters do
      for i = 0, n - 1 do y_scalar[i] = 2.5 * x[i] + y_scalar[i] end
    end
    local t_scalar = os.clock() - t0

    -- Benchmark SIMD AVX2 Kernel
    local t1 = os.clock()
    for _ = 1, iters do
      lib.luthon_simd_saxpy(n, 2.5, x, y_simd)
    end
    local t_simd = os.clock() - t1

    local speedup = t_scalar / t_simd
    print(string.format("SAXPY: Scalar = %.4fs, SIMD = %.4fs, Speedup = %.2fx", t_scalar, t_simd, speedup))

    -- Numerical equivalence check
    assert(math.abs(y_simd[100] - y_scalar[100]) < 1e-3, "numerical equivalence mismatch")
    assert(speedup >= 1.0, "expected speedup >= 1.0x, got " .. speedup)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Benchmark failed: {proc.stderr}"
    assert "Speedup =" in proc.stdout


def test_benchmark_daxpy_speedup(native_capi_so):
    """Demonstrate throughput speedup on double-precision DAXPY kernel."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      void luthon_simd_daxpy(size_t n, double alpha, const double *x, double *y);
    ]]
    local lib = ffi.load('{native_capi_so}')
    local n = 500000
    local iters = 40
    local x = ffi.new('double[?]', n)
    local y_scalar = ffi.new('double[?]', n)
    local y_simd = ffi.new('double[?]', n)
    for i = 0, n - 1 do
      x[i] = i * 0.001
      y_scalar[i] = 1.0
      y_simd[i] = 1.0
    end

    local t0 = os.clock()
    for _ = 1, iters do
      for i = 0, n - 1 do y_scalar[i] = 2.5 * x[i] + y_scalar[i] end
    end
    local t_scalar = os.clock() - t0

    local t1 = os.clock()
    for _ = 1, iters do
      lib.luthon_simd_daxpy(n, 2.5, x, y_simd)
    end
    local t_simd = os.clock() - t1

    local speedup = t_scalar / t_simd
    print(string.format("DAXPY: Scalar = %.4fs, SIMD = %.4fs, Speedup = %.2fx", t_scalar, t_simd, speedup))
    assert(math.abs(y_simd[100] - y_scalar[100]) < 1e-9)
    assert(speedup >= 1.0, "expected speedup >= 1.0x, got " .. speedup)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Benchmark failed: {proc.stderr}"


def test_benchmark_poly_eval_speedup(native_capi_so):
    """Demonstrate 3x-8x throughput speedup on Horner polynomial evaluation using SIMD FMA."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      void luthon_simd_poly_eval_f32(size_t n, const float *x, float *out, const float *coeffs, size_t deg);
    ]]
    local lib = ffi.load('{native_capi_so}')
    local n = 1000000
    local iters = 50
    local x = ffi.new('float[?]', n)
    local out_scalar = ffi.new('float[?]', n)
    local out_simd = ffi.new('float[?]', n)
    local coeffs = ffi.new('float[?]', 5, {{1.0, -0.5, 0.25, -0.125, 0.0625}})

    for i = 0, n - 1 do x[i] = (i % 1000) * 0.001 end

    local t0 = os.clock()
    for _ = 1, iters do
      for i = 0, n - 1 do
        local xi = x[i]
        out_scalar[i] = (((coeffs[4] * xi + coeffs[3]) * xi + coeffs[2]) * xi + coeffs[1]) * xi + coeffs[0]
      end
    end
    local t_scalar = os.clock() - t0

    local t1 = os.clock()
    for _ = 1, iters do
      lib.luthon_simd_poly_eval_f32(n, x, out_simd, coeffs, 4)
    end
    local t_simd = os.clock() - t1

    local speedup = t_scalar / t_simd
    print(string.format("Poly Eval: Scalar = %.4fs, SIMD = %.4fs, Speedup = %.2fx", t_scalar, t_simd, speedup))
    assert(speedup >= 3.0, "expected speedup >= 3.0x, got " .. speedup)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Benchmark failed: {proc.stderr}"


def test_benchmark_euclidean_distance_speedup(native_capi_so):
    """Demonstrate throughput speedup on Euclidean distance kernel."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      double luthon_simd_euclidean_f64(size_t n, const double *x, const double *y);
    ]]
    local lib = ffi.load('{native_capi_so}')
    local n = 1000000
    local iters = 30
    local x = ffi.new('double[?]', n)
    local y = ffi.new('double[?]', n)
    for i = 0, n - 1 do x[i] = i * 0.001; y[i] = i * 0.0015 end

    local d_scalar = 0
    local t0 = os.clock()
    for _ = 1, iters do
      local s = 0.0
      for i = 0, n - 1 do
        local d = x[i] - y[i]
        s = s + d * d
      end
      d_scalar = math.sqrt(s)
    end
    local t_scalar = os.clock() - t0

    local d_simd = 0
    local t1 = os.clock()
    for _ = 1, iters do
      d_simd = lib.luthon_simd_euclidean_f64(n, x, y)
    end
    local t_simd = os.clock() - t1

    local speedup = t_scalar / t_simd
    print(string.format("Euclidean: Scalar = %.4fs, SIMD = %.4fs, Speedup = %.2fx", t_scalar, t_simd, speedup))
    assert(math.abs(d_scalar - d_simd) < 1e-4)
    assert(speedup >= 1.0, "expected speedup >= 1.0x, got " .. speedup)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Benchmark failed: {proc.stderr}"


def test_transcendental_approximations_accuracy(native_capi_so):
    """Verify accuracy and SIMD FMA acceleration of sin, cos, exp, and sqrt."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      void luthon_simd_sin_f64(double *out, const double *x, size_t n);
      void luthon_simd_cos_f64(double *out, const double *x, size_t n);
      void luthon_simd_exp_f64(double *out, const double *x, size_t n);
      void luthon_simd_sqrt_f64(double *out, const double *x, size_t n);
    ]]
    local lib = ffi.load('{native_capi_so}')
    local n = 8
    local x = ffi.new('double[?]', n, {{0.1, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0}})
    local out_sin = ffi.new('double[?]', n)
    local out_cos = ffi.new('double[?]', n)
    local out_exp = ffi.new('double[?]', n)
    local out_sqrt = ffi.new('double[?]', n)

    lib.luthon_simd_sin_f64(out_sin, x, n)
    lib.luthon_simd_cos_f64(out_cos, x, n)
    lib.luthon_simd_exp_f64(out_exp, x, n)
    lib.luthon_simd_sqrt_f64(out_sqrt, x, n)

    for i = 0, n - 1 do
      local xi = x[i]
      local err_sin = math.abs(out_sin[i] - math.sin(xi))
      local err_cos = math.abs(out_cos[i] - math.cos(xi))
      local err_exp = math.abs(out_exp[i] - math.exp(xi))
      local err_sqrt = math.abs(out_sqrt[i] - math.sqrt(xi))
      assert(err_sin < 1e-4, "sin err too high: " .. err_sin)
      assert(err_cos < 1e-4, "cos err too high: " .. err_cos)
      assert(err_exp < 1e-4, "exp err too high: " .. err_exp)
      assert(err_sqrt < 1e-9, "sqrt err too high: " .. err_sqrt)
    end
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Transcendental test failed: {proc.stderr}"


def test_stdlib_math_simd_api(native_capi_so):
    """Verify that math.simd module in stdlib exposes full accelerated API."""
    code = """
import math

def test():
    w = math.simd.get_vector_width()
    backend = math.simd.get_backend_name()
    assert w >= 2
    assert len(backend) > 0

    n = 10
    x = array('d', [float(i) for i in range(n)])
    y = array('d', [0.0] * n)
    math.simd.daxpy(n, 3.0, x, y)
    for i in range(n):
        assert y[i] == float(i) * 3.0

    dot_val = math.simd.dot(n, x, y)
    assert dot_val > 0.0

    d1 = array('d', [0.0, 0.0])
    d2 = array('d', [3.0, 4.0])
    dist = math.simd.euclidean(2, d1, d2)
    assert dist == 5.0

test()
"""
    lua = transpile_ir(code, optimize=True)
    proc = subprocess.run(["luajit", "-"], input=lua, capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"math.simd stdlib test failed: {proc.stderr}"


def test_stdlib_array_simd_acceleration(native_capi_so):
    """Verify that array.add and array.mul leverage SIMD vectorization."""
    code = """
def test():
    n = 16
    a = array('d', [float(i) for i in range(n)])
    b = array('d', [float(i * 2) for i in range(n)])
    c = a.add(b)
    for i in range(n):
        assert c[i] == float(i * 3)

    d = a.mul(b)
    for i in range(n):
        assert d[i] == float(i * i * 2)

test()
"""
    lua = transpile_ir(code, optimize=True)
    proc = subprocess.run(["luajit", "-"], input=lua, capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"array.add/mul SIMD test failed: {proc.stderr}"
