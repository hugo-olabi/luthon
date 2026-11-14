"""Comprehensive Test Suite for Phase 40: Extended Ecosystem C-API Coverage.

Tests dynamic heap types (PyType_FromSpec, PyType_FromSpecWithBases),
PEP 489 multi-phase module initialization, PyCapsule_Import inter-module table sharing,
extended slot protocols (nb_matrix_multiply, mp_ass_subscript, tp_as_async, tp_finalize),
and standalone binary compilation and execution of synthetic scientific C-extensions.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
from pathlib import Path

import pytest

from luthon.native.build_capi import compile_capi_proxy, get_capi_library_path
from luthon.reflect import BinaryReflector


@pytest.fixture(scope="module")
def native_capi_so():
    return compile_capi_proxy()


def _get_isolated_env():
    env = os.environ.copy()
    env["LUA_PATH"] = "./?.lua;./src/luthon/lua/?.lua;;"
    env["LUA_CPATH"] = "./?.so;src/luthon/native/?.so;;"
    return env


def test_dynamic_heap_type_from_spec(native_capi_so):
    """Test dynamic heap type creation via PyType_FromSpec with slots and arithmetic dispatch."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct _typeobject PyTypeObject;

      typedef struct {{
        int slot;
        void *pfunc;
      }} PyType_Slot;

      typedef struct {{
        const char *name;
        int basicsize;
        int itemsize;
        unsigned int flags;
        PyType_Slot *slots;
      }} PyType_Spec;

      typedef struct {{
        long ob_refcnt;
        PyTypeObject *ob_type;
        int tag;
        int buf_locks;
        double val;
      }} MyTensorObject;

      typedef PyObject* (*ternaryfunc)(PyObject *self, PyObject *args, PyObject *kwargs);
      typedef PyObject* (*binaryfunc)(PyObject *v1, PyObject *v2);

      PyObject* PyType_FromSpec(PyType_Spec *spec);
      PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs);
      PyObject* PyNumber_Add(PyObject *o1, PyObject *o2);
      PyObject* PyNumber_MatrixMultiply(PyObject *o1, PyObject *o2);
      unsigned long PyType_GetFlags(PyTypeObject *type);
      void Py_DecRef(PyObject *o);
      PyObject* alloc_pyobject(int tag, PyTypeObject *type);
      const char* PyUnicode_AsUTF8(PyObject *o);
      PyObject* PyObject_GetAttrString(PyObject *o, const char *name);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local tensor_new = ffi.cast("void*", ffi.cast("ternaryfunc", function(type_obj, args, kwargs)
      local t = ffi.cast("MyTensorObject*", lib.alloc_pyobject(10, ffi.cast("PyTypeObject*", type_obj)))
      t.val = 42.0
      return ffi.cast("PyObject*", t)
    end))

    local tensor_add = ffi.cast("void*", ffi.cast("binaryfunc", function(v1, v2)
      local t1 = ffi.cast("MyTensorObject*", v1)
      local t2 = ffi.cast("MyTensorObject*", v2)
      local res = ffi.cast("MyTensorObject*", lib.alloc_pyobject(10, t1.ob_type))
      res.val = t1.val + t2.val
      return ffi.cast("PyObject*", res)
    end))

    local tensor_matmul = ffi.cast("void*", ffi.cast("binaryfunc", function(v1, v2)
      local t1 = ffi.cast("MyTensorObject*", v1)
      local t2 = ffi.cast("MyTensorObject*", v2)
      local res = ffi.cast("MyTensorObject*", lib.alloc_pyobject(10, t1.ob_type))
      res.val = t1.val * t2.val
      return ffi.cast("PyObject*", res)
    end))

    local slots = ffi.new("PyType_Slot[4]", {{
      {{ slot = 63, pfunc = tensor_new }},    -- Py_tp_new = 63
      {{ slot = 7,  pfunc = tensor_add }},    -- Py_nb_add = 7
      {{ slot = 73, pfunc = tensor_matmul }}, -- Py_nb_matrix_multiply = 73
      {{ slot = 0,  pfunc = nil }}
    }})

    local spec = ffi.new("PyType_Spec", {{
      name = "SyntheticTensor",
      basicsize = ffi.sizeof("MyTensorObject"),
      itemsize = 0,
      flags = 0,
      slots = slots
    }})

    local tensor_type = lib.PyType_FromSpec(spec)
    assert(tensor_type ~= nil, "PyType_FromSpec returned nil")

    local type_ptr = ffi.cast("PyTypeObject*", tensor_type)
    local flags = lib.PyType_GetFlags(type_ptr)
    local Py_TPFLAGS_HEAPTYPE = 512 -- (1 << 9)
    assert(bit.band(flags, Py_TPFLAGS_HEAPTYPE) ~= 0, "Missing Py_TPFLAGS_HEAPTYPE flag")

    -- Check doc and name resolution on type object
    local name_obj = lib.PyObject_GetAttrString(tensor_type, "__name__")
    assert(name_obj ~= nil)
    local name_str = ffi.string(lib.PyUnicode_AsUTF8(name_obj))
    assert(name_str == "SyntheticTensor", "expected SyntheticTensor, got " .. name_str)

    -- Instantiate object
    local inst1 = lib.PyObject_Call(tensor_type, nil, nil)
    assert(inst1 ~= nil, "PyObject_Call failed to instantiate tensor")
    local t1 = ffi.cast("MyTensorObject*", inst1)
    assert(t1.val == 42.0)

    local inst2 = lib.PyObject_Call(tensor_type, nil, nil)
    local t2 = ffi.cast("MyTensorObject*", inst2)
    t2.val = 10.0

    -- Test nb_add
    local add_res = lib.PyNumber_Add(inst1, inst2)
    assert(add_res ~= nil, "PyNumber_Add failed on dynamic heap type")
    local t_add = ffi.cast("MyTensorObject*", add_res)
    assert(t_add.val == 52.0, "Expected 52.0, got " .. t_add.val)

    -- Test nb_matrix_multiply (@ operator)
    local matmul_res = lib.PyNumber_MatrixMultiply(inst1, inst2)
    assert(matmul_res ~= nil, "PyNumber_MatrixMultiply failed on dynamic heap type")
    local t_mm = ffi.cast("MyTensorObject*", matmul_res)
    assert(t_mm.val == 420.0, "Expected 420.0, got " .. t_mm.val)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_dynamic_heap_type_inheritance_and_basetype(native_capi_so):
    """Test PyType_FromSpecWithBases supporting single/multiple base inheritance and PyType_IsSubtype."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct _typeobject PyTypeObject;

      typedef struct {{
        int slot;
        void *pfunc;
      }} PyType_Slot;

      typedef struct {{
        const char *name;
        int basicsize;
        int itemsize;
        unsigned int flags;
        PyType_Slot *slots;
      }} PyType_Spec;

      typedef PyObject* (*ternaryfunc)(PyObject *self, PyObject *args, PyObject *kwargs);
      typedef PyObject* (*binaryfunc)(PyObject *v1, PyObject *v2);

      PyObject* PyType_FromSpec(PyType_Spec *spec);
      PyObject* PyType_FromSpecWithBases(PyType_Spec *spec, PyObject *bases);
      int PyType_IsSubtype(PyTypeObject *a, PyTypeObject *b);
      PyObject* PyTuple_New(long size);
      int PyTuple_SetItem(PyObject *t, long idx, PyObject *item);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local Py_TPFLAGS_BASETYPE = 1024 -- (1 << 10)
    local base_slots = ffi.new("PyType_Slot[1]", {{{{ slot = 0, pfunc = nil }}}})
    local base_spec = ffi.new("PyType_Spec", {{
      name = "BaseTensor",
      basicsize = 64,
      itemsize = 0,
      flags = Py_TPFLAGS_BASETYPE,
      slots = base_slots
    }})

    local base_type = lib.PyType_FromSpec(base_spec)
    assert(base_type ~= nil)

    -- Derive DerivedTensor from BaseTensor
    local derived_slots = ffi.new("PyType_Slot[1]", {{{{ slot = 0, pfunc = nil }}}})
    local derived_spec = ffi.new("PyType_Spec", {{
      name = "DerivedTensor",
      basicsize = 64,
      itemsize = 0,
      flags = 0,
      slots = derived_slots
    }})

    local derived_type = lib.PyType_FromSpecWithBases(derived_spec, base_type)
    assert(derived_type ~= nil)

    local is_sub = lib.PyType_IsSubtype(ffi.cast("PyTypeObject*", derived_type), ffi.cast("PyTypeObject*", base_type))
    assert(is_sub == 1, "Expected DerivedTensor to be subtype of BaseTensor")
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_extended_mapping_multidim_subscript(native_capi_so):
    """Test mp_ass_subscript and mp_subscript supporting multidimensional slice assignments (e.g. tensor[1, 2] = val)."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct _typeobject PyTypeObject;

      typedef struct {{
        int slot;
        void *pfunc;
      }} PyType_Slot;

      typedef struct {{
        const char *name;
        int basicsize;
        int itemsize;
        unsigned int flags;
        PyType_Slot *slots;
      }} PyType_Spec;

      typedef struct {{
        long ob_refcnt;
        PyTypeObject *ob_type;
        int tag;
        int buf_locks;
        double grid[16];
      }} MatrixObject;

      typedef PyObject* (*ternaryfunc)(PyObject *self, PyObject *args, PyObject *kwargs);
      typedef PyObject* (*binaryfunc)(PyObject *v1, PyObject *v2);
      typedef int (*objobjargproc)(PyObject *self, PyObject *key, PyObject *val);

      PyObject* PyType_FromSpec(PyType_Spec *spec);
      PyObject* alloc_pyobject(int tag, PyTypeObject *type);
      PyObject* PyObject_GetItem(PyObject *o, PyObject *key);
      int PyObject_SetItem(PyObject *o, PyObject *key, PyObject *val);
      PyObject* PyTuple_New(long size);
      PyObject* PyTuple_GetItem(PyObject *o, long idx);
      int PyTuple_SetItem(PyObject *t, long idx, PyObject *item);
      PyObject* PyLong_FromLong(long v);
      PyObject* PyFloat_FromDouble(double v);
      double PyFloat_AsDouble(PyObject *o);
      long PyLong_AsLong(PyObject *o);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local mat_get = ffi.cast("void*", ffi.cast("binaryfunc", function(obj, key)
      local mat = ffi.cast("MatrixObject*", obj)
      -- Key is tuple (r, c)
      local r_obj = lib.PyTuple_GetItem(key, 0)
      local c_obj = lib.PyTuple_GetItem(key, 1)
      local r = lib.PyLong_AsLong(r_obj)
      local c = lib.PyLong_AsLong(c_obj)
      local val = mat.grid[r * 4 + c]
      return lib.PyFloat_FromDouble(val)
    end))

    local mat_set = ffi.cast("void*", ffi.cast("objobjargproc", function(obj, key, val)
      local mat = ffi.cast("MatrixObject*", obj)
      local r_obj = lib.PyTuple_GetItem(key, 0)
      local c_obj = lib.PyTuple_GetItem(key, 1)
      local r = lib.PyLong_AsLong(r_obj)
      local c = lib.PyLong_AsLong(c_obj)
      mat.grid[r * 4 + c] = lib.PyFloat_AsDouble(val)
      return 0
    end))

    local slots = ffi.new("PyType_Slot[3]", {{
      {{ slot = 5, pfunc = mat_get }}, -- Py_mp_subscript = 5
      {{ slot = 3, pfunc = mat_set }}, -- Py_mp_ass_subscript = 3
      {{ slot = 0, pfunc = nil }}
    }})

    local spec = ffi.new("PyType_Spec", {{
      name = "Matrix4x4",
      basicsize = ffi.sizeof("MatrixObject"),
      itemsize = 0,
      flags = 0,
      slots = slots
    }})

    local mat_type = lib.PyType_FromSpec(spec)
    local mat_obj = ffi.cast("MatrixObject*", lib.alloc_pyobject(10, ffi.cast("PyTypeObject*", mat_type)))

    -- Set mat[1, 2] = 99.5
    local key = lib.PyTuple_New(2)
    lib.PyTuple_SetItem(key, 0, lib.PyLong_FromLong(1))
    lib.PyTuple_SetItem(key, 1, lib.PyLong_FromLong(2))

    local val_to_set = lib.PyFloat_FromDouble(99.5)
    local set_ret = lib.PyObject_SetItem(ffi.cast("PyObject*", mat_obj), key, val_to_set)
    assert(set_ret == 0, "PyObject_SetItem returned failure")
    assert(mat_obj.grid[1 * 4 + 2] == 99.5, "Memory was not updated")

    -- Get mat[1, 2]
    local get_res = lib.PyObject_GetItem(ffi.cast("PyObject*", mat_obj), key)
    assert(get_res ~= nil)
    local got_val = lib.PyFloat_AsDouble(get_res)
    assert(got_val == 99.5, "Expected 99.5, got " .. got_val)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_tp_finalize_cleanup_hook(native_capi_so):
    """Test that tp_finalize is called prior to object deallocation."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct _typeobject PyTypeObject;

      typedef struct {{
        int slot;
        void *pfunc;
      }} PyType_Slot;

      typedef struct {{
        const char *name;
        int basicsize;
        int itemsize;
        unsigned int flags;
        PyType_Slot *slots;
      }} PyType_Spec;

      typedef PyObject* (*ternaryfunc)(PyObject *self, PyObject *args, PyObject *kwargs);
      typedef PyObject* (*binaryfunc)(PyObject *v1, PyObject *v2);
      typedef void (*destructor)(PyObject *self);

      PyObject* PyType_FromSpec(PyType_Spec *spec);
      PyObject* alloc_pyobject(int tag, PyTypeObject *type);
      void Py_DecRef(PyObject *o);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local finalized_count = 0
    local finalize_cb = ffi.cast("void*", ffi.cast("destructor", function(obj)
      finalized_count = finalized_count + 1
    end))

    local slots = ffi.new("PyType_Slot[2]", {{
      {{ slot = 78, pfunc = finalize_cb }}, -- Py_tp_finalize = 78
      {{ slot = 0, pfunc = nil }}
    }})

    local spec = ffi.new("PyType_Spec", {{
      name = "CppResourceHolder",
      basicsize = 64,
      itemsize = 0,
      flags = 0,
      slots = slots
    }})

    local res_type = lib.PyType_FromSpec(spec)
    local obj = lib.alloc_pyobject(10, ffi.cast("PyTypeObject*", res_type))
    assert(finalized_count == 0)

    -- DecRef to 0 triggers dealloc -> tp_finalize
    lib.Py_DecRef(obj)
    assert(finalized_count == 1, "tp_finalize was not invoked on deallocation")
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_pep489_multiphase_module_initialization(native_capi_so):
    """Verify PEP 489 multi-phase module initialization via Py_mod_create, Py_mod_exec, and PyModule_ExecDef."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct PyMethodDef PyMethodDef;

      typedef struct PyModuleDef_Slot {{
        int slot;
        void *value;
      }} PyModuleDef_Slot;

      typedef struct PyModuleDef_Base {{
        long ob_refcnt;
        void *ob_type;
        void* (*m_init)(void);
        long m_index;
        void* m_copy;
      }} PyModuleDef_Base;

      typedef struct PyModuleDef {{
        PyModuleDef_Base m_base;
        const char *m_name;
        const char *m_doc;
        long m_size;
        PyMethodDef *m_methods;
        PyModuleDef_Slot *m_slots;
        void *m_traverse;
        void *m_clear;
        void *m_free;
      }} PyModuleDef;

      typedef int (*inquiry)(PyObject *self);

      PyObject* PyModuleDef_Init(PyModuleDef *def);
      PyObject* PyModule_FromDefAndSpec(PyModuleDef *def, PyObject *spec);
      int PyModule_ExecDef(PyObject *module, PyModuleDef *def);
      PyObject* PyModule_GetDict(PyObject *mod);
      int PyModule_AddIntConstant(PyObject *mod, const char *name, long value);
      PyObject* PyDict_GetItemString(PyObject *dp, const char *key);
      long PyLong_AsLong(PyObject *o);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local executed_state = 0
    local mod_exec = ffi.cast("void*", ffi.cast("inquiry", function(mod)
      executed_state = 1
      lib.PyModule_AddIntConstant(mod, "PROTOCOL_VERSION", 489)
      return 0
    end))

    local slots = ffi.new("PyModuleDef_Slot[2]", {{
      {{ slot = 2, value = mod_exec }}, -- Py_mod_exec = 2
      {{ slot = 0, value = nil }}
    }})

    local mdef = ffi.new("PyModuleDef", {{
      m_name = "multiphase_pkg",
      m_doc = "PEP 489 Multi-Phase Test Module",
      m_size = 0,
      m_methods = nil,
      m_slots = slots
    }})

    -- PyModuleDef_Init on multi-phase returns mdef pointer
    local init_ret = lib.PyModuleDef_Init(mdef)
    assert(init_ret ~= nil)

    -- Loader creates module and executes PEP 489 slots
    local mod = lib.PyModule_FromDefAndSpec(mdef, nil)
    assert(mod ~= nil, "PyModule_FromDefAndSpec returned nil")

    local exec_ret = lib.PyModule_ExecDef(mod, mdef)
    assert(exec_ret == 0, "PyModule_ExecDef failed")
    assert(executed_state == 1, "Py_mod_exec callback was not run")

    -- Verify module dict has the constant inserted during Py_mod_exec
    local dict = lib.PyModule_GetDict(mod)
    assert(dict ~= nil)
    local c_val = lib.PyDict_GetItemString(dict, "PROTOCOL_VERSION")
    assert(c_val ~= nil)
    local ver = lib.PyLong_AsLong(c_val)
    assert(tonumber(ver) == 489, "Expected 489, got " .. tostring(ver))
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_capsule_table_sharing_and_import(native_capi_so):
    """Verify PyCapsule_Register and PyCapsule_Import sharing cross-module C function tables (e.g. SciPy Cython BLAS)."""
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef void (*PyCapsule_Destructor)(PyObject *);

      typedef struct {{
        double (*ddot)(int n, const double *x, const double *y);
        void (*daxpy)(int n, double a, const double *x, double *y);
      }} ScipyBlasTable;

      PyObject* PyCapsule_New(void *ptr, const char *name, PyCapsule_Destructor destr);
      int PyCapsule_Register(const char *name, void *pointer);
      void* PyCapsule_Import(const char *name, int no_block);
      void* PyCapsule_GetPointer(PyObject *op, const char *name);
    ]]
    local lib = ffi.load('{native_capi_so}')

    local ddot_cb = ffi.cast("double (*)(int, const double*, const double*)", function(n, x, y)
      local sum = 0.0
      for i = 0, n - 1 do sum = sum + x[i] * y[i] end
      return sum
    end)

    local blas_table = ffi.new("ScipyBlasTable", {{
      ddot = ddot_cb,
      daxpy = nil
    }})

    -- Register capsule under canonical SciPy Cython BLAS path
    local cap = lib.PyCapsule_New(blas_table, "scipy.linalg.cython_blas._BLAS_TABLE", nil)
    assert(cap ~= nil)

    -- Retrieve pointer from another module context via PyCapsule_Import
    local imported_ptr = lib.PyCapsule_Import("scipy.linalg.cython_blas._BLAS_TABLE", 0)
    assert(imported_ptr ~= nil, "PyCapsule_Import returned NULL")

    local table_ptr = ffi.cast("ScipyBlasTable*", imported_ptr)
    local x = ffi.new("double[3]", {{1.0, 2.0, 3.0}})
    local y = ffi.new("double[3]", {{4.0, 5.0, 6.0}})
    local dot_res = table_ptr.ddot(3, x, y)
    assert(dot_res == 32.0, "Expected dot product 32.0, got " .. dot_res)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"


def test_synthetic_scientific_extension_compilation_and_reflection(native_capi_so, tmp_path):
    """Compile and reflect a standalone C extension using PEP 489, dynamic types, and capsule tables."""
    src_code = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "luthon_capi.h"

/* Fast BLAS kernel exported via Capsule */
static double c_euclidean_norm(int n, const double *data) {
    double s = 0.0;
    for (int i = 0; i < n; i++) {
        s += data[i] * data[i];
    }
    return s;
}

typedef struct {
    double (*norm)(int n, const double *data);
} SyntheticBlasAPI;

static SyntheticBlasAPI g_blas_api = {
    .norm = c_euclidean_norm
};

/* Module method */
static PyObject* py_compute_norm(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *seq = NULL;
    if (!PyArg_ParseTuple(args, "O", &seq)) return NULL;
    Py_ssize_t n = PySequence_Size(seq);
    double *buf = (double *)malloc(sizeof(double) * n);
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *elem = PySequence_GetItem(seq, i);
        buf[i] = PyFloat_AsDouble(elem);
        Py_DecRef(elem);
    }
    double res = c_euclidean_norm((int)n, buf);
    free(buf);
    return PyFloat_FromDouble(res);
}

static PyMethodDef module_methods[] = {
    {"compute_norm", (void*)py_compute_norm, METH_VARARGS, "Compute euclidean sum of squares."},
    {NULL, NULL, 0, NULL}
};

static int exec_synthetic(PyObject *module) {
    /* Export capsule */
    PyObject *cap = PyCapsule_New(&g_blas_api, "synthetic_scipy._BLAS", NULL);
    PyModule_AddObject(module, "_BLAS", cap);
    PyModule_AddIntConstant(module, "VERSION_ID", 2026);
    return 0;
}

static PyModuleDef_Slot module_slots[] = {
    {Py_mod_exec, (void*)exec_synthetic},
    {0, NULL}
};

static PyModuleDef synthetic_module = {
    .m_base = {1, NULL, NULL, 0, NULL},
    .m_name = "synthetic_scipy",
    .m_doc = "Synthetic Scientific Library",
    .m_size = 0,
    .m_methods = module_methods,
    .m_slots = module_slots
};

EXPORT PyObject* PyInit_synthetic_scipy(void) {
    return PyModuleDef_Init(&synthetic_module);
}
"""
    c_file = tmp_path / "synthetic_scipy.c"
    so_file = tmp_path / "synthetic_scipy.so"
    c_file.write_text(src_code)

    native_inc = Path(__file__).parent.parent / "src" / "luthon" / "native" / "include"
    cmd = [
        "gcc", "-O2", "-fPIC", "-shared",
        f"-I{native_inc}",
        str(c_file),
        "-o", str(so_file)
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, f"Compilation failed: {res.stderr}"

    # Reflect module binary
    reflector = BinaryReflector(capi_path=native_capi_so)
    meta = reflector.reflect_binary(so_file, module_name="synthetic_scipy")
    assert meta.name == "synthetic_scipy"
    method_names = [m.name for m in meta.methods]
    assert "compute_norm" in method_names

    # Test execution in LuaJIT
    test_lua = f"""
    local ffi = require('ffi')
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef struct {{
        double (*norm)(int n, const double *data);
      }} SyntheticBlasAPI;

      PyObject* PyInit_synthetic_scipy(void);
      PyObject* PyModule_FromDefAndSpec(void *def, PyObject *spec);
      int PyModule_ExecDef(PyObject *module, void *def);
      void* PyCapsule_Import(const char *name, int no_block);
      PyObject* PyFloat_FromDouble(double v);
      PyObject* PyTuple_New(long n);
      int PyTuple_SetItem(PyObject *t, long idx, PyObject *item);
      PyObject* PyObject_CallFunction(PyObject *callable, const char *format, ...);
      PyObject* PyObject_GetAttrString(PyObject *o, const char *name);
      double PyFloat_AsDouble(PyObject *o);
      PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs);
    ]]
    local capi = ffi.load('{native_capi_so}', true)
    local ext = ffi.load('{so_file}')

    local raw_def = ext.PyInit_synthetic_scipy()
    assert(raw_def ~= nil)

    local mod = capi.PyModule_FromDefAndSpec(raw_def, nil)
    local ok = capi.PyModule_ExecDef(mod, raw_def)
    assert(ok == 0)

    -- Import capsule exported by the module during Py_mod_exec
    local blas_ptr = capi.PyCapsule_Import("synthetic_scipy._BLAS", 0)
    assert(blas_ptr ~= nil, "Could not import synthetic_scipy._BLAS capsule")
    local blas = ffi.cast("SyntheticBlasAPI*", blas_ptr)
    local data = ffi.new("double[3]", {{3.0, 4.0, 0.0}})
    local norm = blas.norm(3, data)
    assert(norm == 25.0, "Expected norm 25.0, got " .. norm)

    -- Call module method compute_norm
    local fn_obj = capi.PyObject_GetAttrString(mod, "compute_norm")
    assert(fn_obj ~= nil)

    local tuple = capi.PyTuple_New(3)
    capi.PyTuple_SetItem(tuple, 0, capi.PyFloat_FromDouble(1.0))
    capi.PyTuple_SetItem(tuple, 1, capi.PyFloat_FromDouble(2.0))
    capi.PyTuple_SetItem(tuple, 2, capi.PyFloat_FromDouble(3.0))

    local args = capi.PyTuple_New(1)
    capi.PyTuple_SetItem(args, 0, tuple)

    local res_obj = capi.PyObject_Call(fn_obj, args, nil)
    assert(res_obj ~= nil)
    local res_val = capi.PyFloat_AsDouble(res_obj)
    assert(res_val == 14.0, "Expected 14.0 (1+4+9), got " .. res_val)
    """
    proc = subprocess.run(["luajit", "-e", test_lua], capture_output=True, text=True, env=_get_isolated_env())
    assert proc.returncode == 0, f"Lua execution failed: {proc.stderr}\nSTDOUT: {proc.stdout}"
