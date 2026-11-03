"""Tests for Phase 33: Multi-Dimensional Buffer Protocol (PEP 3118) & GC Lifetime Sync."""

import unittest
import tempfile
import subprocess
from pathlib import Path

from luthon.native.build_capi import compile_capi_proxy


class TestPhase33BufferAndGC(unittest.TestCase):
    """Unit tests for Phase 33 buffer protocol and dual-ownership GC synchronization."""

    @classmethod
    def setUpClass(cls):
        cls.capi_path = compile_capi_proxy()
        cls.include_dir = Path(__file__).parent.parent / "src" / "luthon" / "native" / "include"

    def _compile_c_extension(self, c_code: str, out_path: Path):
        subprocess.run(
            ["gcc", "-O3", "-fPIC", "-shared", f"-I{self.include_dir}", "-o", str(out_path), "-x", "c", "-"],
            input=c_code,
            text=True,
            check=True,
        )

    def test_nd_buffer_protocol_and_format_parsing(self):
        """Test multi-dimensional shape, strides and format string itemsize in PEP 3118 buffer protocol."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = f"""
#include <stdint.h>
#include <stdlib.h>
#include "luthon_capi.h"

typedef struct {{
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    int buf_locks;
    double data[2][3];
    Py_ssize_t shape[2];
    Py_ssize_t strides[2];
}} Matrix2x3;

static int matrix_getbuffer(PyObject *self, Py_buffer *view, int flags) {{
    Matrix2x3 *m = (Matrix2x3 *)self;
    view->obj = self;
    view->buf = m->data;
    view->len = 2 * 3 * sizeof(double);
    view->readonly = 0;
    view->itemsize = sizeof(double);
    view->format = "d";
    view->ndim = 2;
    m->shape[0] = 2;
    m->shape[1] = 3;
    view->shape = m->shape;

    if (flags & PyBUF_STRIDES) {{
        m->strides[0] = 3 * sizeof(double);
        m->strides[1] = sizeof(double);
        view->strides = m->strides;
    }} else {{
        view->strides = NULL;
    }}
    view->suboffsets = NULL;
    view->internal = NULL;
    return 0;
}}

static PyBufferProcs Matrix_BufferProcs = {{
    .bf_getbuffer = matrix_getbuffer,
    .bf_releasebuffer = NULL
}};

static PyTypeObject Matrix_Type = {{
    .ob_refcnt = 1,
    .ob_type = &Base_Type,
    .tp_name = "Matrix2x3",
    .tp_basicsize = sizeof(Matrix2x3),
    .tp_as_buffer = &Matrix_BufferProcs
}};

__attribute__((visibility("default")))
PyObject* make_matrix(void) {{
    Matrix2x3 *m = (Matrix2x3 *)calloc(1, sizeof(Matrix2x3));
    m->ob_refcnt = 1;
    m->ob_type = &Matrix_Type;
    m->tag = PY_TAG_OPAQUE;
    m->data[0][0] = 1.0; m->data[0][1] = 2.0; m->data[0][2] = 3.0;
    m->data[1][0] = 4.0; m->data[1][1] = 5.0; m->data[1][2] = 6.0;
    return (PyObject *)m;
}}
"""
            so_file = tmp / "matrix.so"
            self._compile_c_extension(c_code, so_file)

            script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)
local ext = ffi.load("{so_file}")

ffi.cdef[[
  typedef struct _object PyObject;
  typedef long Py_ssize_t;
  typedef struct bufferinfo {{
      void *buf;
      PyObject *obj;
      Py_ssize_t len;
      Py_ssize_t itemsize;
      int readonly;
      int ndim;
      char *format;
      Py_ssize_t *shape;
      Py_ssize_t *strides;
      Py_ssize_t *suboffsets;
      void *internal;
  }} Py_buffer;

  PyObject* make_matrix(void);
  int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags);
  void PyBuffer_Release(Py_buffer *view);
  int PyBuffer_IsContiguous(const Py_buffer *view, char fort);
  Py_ssize_t PyBuffer_SizeFromFormat(const char *format);
]]

-- 1. Test PyBuffer_SizeFromFormat
assert(tonumber(capi.PyBuffer_SizeFromFormat("d")) == 8, "double size must be 8")
assert(tonumber(capi.PyBuffer_SizeFromFormat("f")) == 4, "float size must be 4")
assert(tonumber(capi.PyBuffer_SizeFromFormat("i")) == 4, "int size must be 4")
assert(tonumber(capi.PyBuffer_SizeFromFormat("h")) == 2, "short size must be 2")
assert(tonumber(capi.PyBuffer_SizeFromFormat("B")) == 1, "uchar size must be 1")

-- 2. Test ND Buffer Export
local m = ext.make_matrix()
local view = ffi.new("Py_buffer")
local PyBUF_STRIDES = 0x0018
local res = capi.PyObject_GetBuffer(m, view, PyBUF_STRIDES)
assert(res == 0, "PyObject_GetBuffer must return 0")
assert(view.ndim == 2, "ndim must be 2")
assert(view.len == 2 * 3 * 8, "len must be 48 bytes")
assert(view.itemsize == 8, "itemsize must be 8")
assert(view.shape[0] == 2 and view.shape[1] == 3, "shape must be (2, 3)")
assert(view.strides[0] == 24 and view.strides[1] == 8, "strides must be (24, 8)")
assert(ffi.string(view.format) == "d", "format must be 'd'")
assert(capi.PyBuffer_IsContiguous(view, 67) == 1, "must be C contiguous")

-- Inspect raw matrix elements via double pointer
local data_ptr = ffi.cast("double*", view.buf)
assert(data_ptr[0] == 1.0 and data_ptr[5] == 6.0, "matrix elements match")

capi.PyBuffer_Release(view)
print("ND_BUFFER_PROTOCOL_PASSED")
"""
            proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
            self.assertIn("ND_BUFFER_PROTOCOL_PASSED", proc.stdout)

    def test_buffer_locking_prevents_resize(self):
        """Test that active buffer exports increment buf_locks and prevent reallocation."""
        script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)

ffi.cdef[[
  typedef struct _object PyObject;
  typedef long Py_ssize_t;
  typedef struct bufferinfo {{
      void *buf;
      PyObject *obj;
      Py_ssize_t len;
      Py_ssize_t itemsize;
      int readonly;
      int ndim;
      char *format;
      Py_ssize_t *shape;
      Py_ssize_t *strides;
      Py_ssize_t *suboffsets;
      void *internal;
  }} Py_buffer;

  PyObject* PyBytes_FromStringAndSize(const char *s, Py_ssize_t size);
  int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags);
  void PyBuffer_Release(Py_buffer *view);
  int _PyBytes_Resize(PyObject **pv, Py_ssize_t newsize);
  PyObject* PyErr_Occurred(void);
  void PyErr_Clear(void);
]]

local b = capi.PyBytes_FromStringAndSize("buffer_data", 11)
local view = ffi.new("Py_buffer")
local ret = capi.PyObject_GetBuffer(b, view, 0)
assert(ret == 0, "PyObject_GetBuffer succeeded")

-- Attempt to resize while buffer view is active -> must fail with BufferError
local b_ptr = ffi.new("PyObject*[1]", b)
local resize_res = capi._PyBytes_Resize(b_ptr, 100)
assert(resize_res == -1, "Resize must fail while buffer is locked")
assert(capi.PyErr_Occurred() ~= nil, "PyErr_Occurred must be set")
capi.PyErr_Clear()

-- Release buffer view -> resize must succeed
capi.PyBuffer_Release(view)
local resize_ok = capi._PyBytes_Resize(b_ptr, 20)
assert(resize_ok == 0, "Resize must succeed after buffer is released")
print("BUFFER_LOCKING_PASSED")
"""
        proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("BUFFER_LOCKING_PASSED", proc.stdout)

    def test_dual_ownership_gc_registry(self):
        """Test central pointer registry linking LuaJIT FFI cdata wrappers to CPython refcounts."""
        script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)

ffi.cdef[[
  typedef struct _object {{
      long ob_refcnt;
      void *ob_type;
      int tag;
      int buf_locks;
  }} PyObject;

  PyObject* PyLong_FromLongLong(long long v);
  void luthon_gc_register(void *cdata_ptr, PyObject *py_obj, int is_owned);
  void luthon_gc_unregister(void *cdata_ptr);
  PyObject* luthon_gc_lookup(void *cdata_ptr);
  void luthon_gc_dec_ref(PyObject *py_obj);
]]

local py_obj = capi.PyLong_FromLongLong(1024)
local initial_ref = py_obj.ob_refcnt

-- Simulate wrapping an external C structure pointer with owned reference
local dummy_cdata = ffi.cast("void*", 0x12345678)
capi.luthon_gc_register(dummy_cdata, py_obj, 1)

-- Refcount should have been incremented for owned reference
assert(py_obj.ob_refcnt == initial_ref + 1, "Refcount incremented for owned wrapper")

-- Lookup by cdata pointer
local found = capi.luthon_gc_lookup(dummy_cdata)
assert(found == py_obj, "Found object in GC registry")

-- Unregister (e.g. wrapper collected or explicitly freed)
capi.luthon_gc_unregister(dummy_cdata)
assert(py_obj.ob_refcnt == initial_ref, "Refcount restored on unregister")
assert(capi.luthon_gc_lookup(dummy_cdata) == nil, "Object no longer in registry")

print("DUAL_OWNERSHIP_GC_PASSED")
"""
        proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("DUAL_OWNERSHIP_GC_PASSED", proc.stdout)


if __name__ == "__main__":
    unittest.main()
