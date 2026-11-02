"""Tests for Luthon C-API Proxy & Binary Reflection Engine."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from luthon.native.build_capi import compile_capi_proxy, get_capi_library_path
from luthon.reflect import BinaryReflector
from luthon.cli import main as cli_main


class TestCAPIProxyAndReflection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ensure libluthon_capi.so is compiled
        cls.capi_lib = compile_capi_proxy()
        assert cls.capi_lib.exists(), f"Failed to build {cls.capi_lib}"

    def _compile_c_extension(self, c_code: str, output_so: Path) -> Path:
        cc = os.environ.get("CC") or shutil.which("gcc") or shutil.which("clang") or "cc"
        c_file = output_so.with_suffix(".c")
        c_file.write_text(c_code, encoding="utf-8")
        cmd = [cc, "-O3", "-shared", "-fPIC", str(c_file), "-o", str(output_so)]
        subprocess.run(cmd, check=True)
        return output_so

    def test_capi_proxy_compilation(self):
        """Verify libluthon_capi.so builds cleanly and exports core symbols."""
        self.assertTrue(self.capi_lib.exists())
        self.assertGreater(self.capi_lib.stat().st_size, 1000)

    def test_binary_reflection_and_execution(self):
        """Test reflecting a C-extension binary and executing it via LuaJIT FFI trampoline."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
#include <stdint.h>
typedef struct _object PyObject;
typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
typedef struct PyModuleDef { int m_base; const char *m_name; const char *m_doc; long m_size; PyMethodDef *m_methods; } PyModuleDef;
extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
extern PyObject* PyLong_FromLongLong(long long v);
extern int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);

static PyObject* c_add(PyObject *self, PyObject *args) {
    long long a, b;
    if (!PyArg_ParseTuple(args, "LL", &a, &b)) return 0;
    return PyLong_FromLongLong(a + b);
}

static PyObject* c_multiply(PyObject *self, PyObject *args) {
    long long a, b;
    if (!PyArg_ParseTuple(args, "LL", &a, &b)) return 0;
    return PyLong_FromLongLong(a * b);
}

static PyMethodDef Methods[] = {
    {"add", (void*)c_add, 1, "Add two numbers"},
    {"multiply", (void*)c_multiply, 1, "Multiply two numbers"},
    {0, 0, 0, 0}
};
static PyModuleDef Mod = { 0, "fast_math", "Native fast math extension", -1, Methods };
__attribute__((visibility("default"))) PyObject* PyInit_fast_math(void) { return PyModule_Create2(&Mod, 3); }
"""
            so_file = tmp / "fast_math.so"
            self._compile_c_extension(c_code, so_file)

            reflector = BinaryReflector()
            meta = reflector.reflect_binary(so_file, module_name="fast_math")

            self.assertEqual(meta.name, "fast_math")
            self.assertEqual(len(meta.methods), 2)
            method_names = [m.name for m in meta.methods]
            self.assertIn("add", method_names)
            self.assertIn("multiply", method_names)

            lua_trampoline = reflector.generate_lua_trampoline(meta)
            lua_file = tmp / "fast_math.lua"
            lua_file.write_text(lua_trampoline, encoding="utf-8")

            # Execute via LuaJIT without CPython
            runner = tmp / "run_test.lua"
            runner.write_text(f"""
package.path = "{tmp}/?.lua;" .. package.path
local math_ext = require("fast_math")
assert(type(math_ext) == "table", "math_ext must be a table")
assert(math_ext.add(15, 27) == 42, "add(15, 27) must equal 42")
assert(math_ext.multiply(6, 7) == 42, "multiply(6, 7) must equal 42")
print("CAPI_PROXY_AND_REFLECTION_PASSED")
""")
            res = subprocess.run(["luajit", str(runner)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("CAPI_PROXY_AND_REFLECTION_PASSED", res.stdout)

    def test_reflect_cli(self):
        """Test invoking `luthon reflect` via CLI."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
#include <stdint.h>
typedef struct _object PyObject;
typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
typedef struct PyModuleDef { int m_base; const char *m_name; const char *m_doc; long m_size; PyMethodDef *m_methods; } PyModuleDef;
extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
extern PyObject* PyLong_FromLongLong(long long v);
extern int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);

static PyObject* compute(PyObject *self, PyObject *args) {
    long long x;
    if (!PyArg_ParseTuple(args, "L", &x)) return 0;
    return PyLong_FromLongLong(x * 10);
}

static PyMethodDef Methods[] = {
    {"compute", (void*)compute, 1, "Compute tenfold"},
    {0, 0, 0, 0}
};
static PyModuleDef Mod = { 0, "simple_ext", "Simple ext", -1, Methods };
__attribute__((visibility("default"))) PyObject* PyInit_simple_ext(void) { return PyModule_Create2(&Mod, 3); }
"""
            so_file = tmp / "simple_ext.so"
            self._compile_c_extension(c_code, so_file)

            out_lua = tmp / "simple_ext.lua"
            ret = cli_main(["reflect", str(so_file), "-o", str(out_lua)])
            self.assertEqual(ret, 0)
            self.assertTrue(out_lua.exists())
            content = out_lua.read_text(encoding="utf-8")
            self.assertIn("compute", content)

    def test_pybridge_fallback_nyi_generation(self):
        """Verify that fallback PyBridge access generates a <filename>.luthon-nyi file."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            py_file = tmp / "dummy_script.py"
            py_file.write_text("""
import decimal
x = decimal.Decimal(42)
""", encoding="utf-8")

            # Execute via Luthon CLI run
            ret = cli_main(["run", str(py_file)])
            self.assertEqual(ret, 0)

            # Check that dummy_script.py.luthon-nyi was generated
            nyi_file = tmp / "dummy_script.py.luthon-nyi"
            self.assertTrue(nyi_file.exists(), f"Expected NYI file {nyi_file} was not generated")
            report = nyi_file.read_text(encoding="utf-8")
            self.assertIn("Luthon Fallback NYI Feature Report", report)
            self.assertIn("decimal", report)

    def test_modular_capi_compilation_and_static_archive(self):
        """Verify modular C native compilation outputs shared (.so) and static (.a) libraries."""
        so_lib = get_capi_library_path()
        a_lib = so_lib.with_suffix(".a")
        self.assertTrue(so_lib.exists(), f"Missing shared library: {so_lib}")
        self.assertTrue(a_lib.exists(), f"Missing static library: {a_lib}")
        self.assertGreater(so_lib.stat().st_size, 5000)
        self.assertGreater(a_lib.stat().st_size, 5000)

    def test_type_slots_and_richcompare(self):
        """Verify PyType_Ready slot inheritance and PyObject_RichCompareBool execution."""
        script = f"""
local ffi = require("ffi")
ffi.cdef[[
  typedef struct _object PyObject;
  typedef struct _typeobject PyTypeObject;
  PyObject* PyLong_FromLongLong(long long v);
  int PyObject_RichCompareBool(PyObject *v, PyObject *w, int op);
  int PyType_Ready(PyTypeObject *type);
  void Py_DecRef(PyObject *o);
]]
local capi = ffi.load("{self.capi_lib}")
local a = capi.PyLong_FromLongLong(42)
local b = capi.PyLong_FromLongLong(100)
assert(capi.PyObject_RichCompareBool(a, b, 0) == 1, "42 < 100 must be true (Py_LT=0)")
assert(capi.PyObject_RichCompareBool(a, b, 2) == 0, "42 == 100 must be false (Py_EQ=2)")
assert(capi.PyObject_RichCompareBool(a, a, 2) == 1, "42 == 42 must be true (Py_EQ=2)")
capi.Py_DecRef(a)
capi.Py_DecRef(b)
print("TYPE_SLOTS_AND_RICHCOMPARE_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("TYPE_SLOTS_AND_RICHCOMPARE_PASSED", res.stdout)

    def test_slice_and_multidimensional_indexing(self):
        """Verify PySlice_New and PyObject_GetItem slice indexing on tuples."""
        script = f"""
local ffi = require("ffi")
ffi.cdef[[
  typedef struct _object PyObject;
  typedef long Py_ssize_t;
  PyObject* PyLong_FromLongLong(long long v);
  PyObject* PyTuple_New(Py_ssize_t len);
  int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);
  PyObject* PySlice_New(PyObject *start, PyObject *stop, PyObject *step);
  PyObject* PyObject_GetItem(PyObject *o, PyObject *key);
  Py_ssize_t PyTuple_Size(PyObject *p);
  long long PyLong_AsLongLong(PyObject *o);
  PyObject* PyTuple_GetItem(PyObject *p, Py_ssize_t pos);
  void Py_DecRef(PyObject *o);
]]
local capi = ffi.load("{self.capi_lib}")
local tup = capi.PyTuple_New(5)
for i = 0, 4 do
  capi.PyTuple_SetItem(tup, i, capi.PyLong_FromLongLong(i * 10))
end
local s_start = capi.PyLong_FromLongLong(1)
local s_stop = capi.PyLong_FromLongLong(4)
local s_step = capi.PyLong_FromLongLong(1)
local slice_obj = capi.PySlice_New(s_start, s_stop, s_step)

local sub_tup = capi.PyObject_GetItem(tup, slice_obj)
assert(sub_tup ~= nil, "sub_tup must not be nil")
assert(tonumber(capi.PyTuple_Size(sub_tup)) == 3, "sliced tuple length must be 3")
assert(tonumber(capi.PyLong_AsLongLong(capi.PyTuple_GetItem(sub_tup, 0))) == 10)
assert(tonumber(capi.PyLong_AsLongLong(capi.PyTuple_GetItem(sub_tup, 1))) == 20)
assert(tonumber(capi.PyLong_AsLongLong(capi.PyTuple_GetItem(sub_tup, 2))) == 30)

capi.Py_DecRef(s_start)
capi.Py_DecRef(s_stop)
capi.Py_DecRef(s_step)
capi.Py_DecRef(slice_obj)
capi.Py_DecRef(sub_tup)
capi.Py_DecRef(tup)
print("SLICE_AND_INDEXING_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("SLICE_AND_INDEXING_PASSED", res.stdout)

    def test_native_stream_bytesio(self):
        """Verify native io.BytesIO stream wrapping and buffer protocol."""
        script = """
local bootstrap = loadfile("src/luthon/lua/bootstrap.lua")()
local bio = io.BytesIO("LuthonNativeBufferStream")
assert(bio:read(6) == "Luthon")
assert(bio:read(6) == "Native")
assert(bio:tell() == 12)
bio:seek(0, "set")
assert(bio:read() == "LuthonNativeBufferStream")
bio:seek(0, "set")
bio:write("ZeroPy")
assert(bio:getvalue() == "ZeroPyNativeBufferStream")
print("NATIVE_STREAM_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("NATIVE_STREAM_PASSED", res.stdout)

    def test_tier_4_5_automatic_binary_resolution(self):
        """Verify Tier 4.5 automatically discovers and executes compiled C extensions via modules.lua."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
#include <stdint.h>
typedef struct _object PyObject;
typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
typedef struct PyModuleDef { int m_base; const char *m_name; const char *m_doc; long m_size; PyMethodDef *m_methods; } PyModuleDef;
extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
extern PyObject* PyLong_FromLongLong(long long v);
extern int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);

static PyObject* square(PyObject *self, PyObject *args) {
    long long x;
    if (!PyArg_ParseTuple(args, "L", &x)) return 0;
    return PyLong_FromLongLong(x * x);
}

static PyMethodDef Methods[] = {
    {"square", (void*)square, 1, "Square a number"},
    {0, 0, 0, 0}
};
static PyModuleDef Mod = { 0, "auto_ext", "Auto binary ext", -1, Methods };
__attribute__((visibility("default"))) PyObject* PyInit_auto_ext(void) { return PyModule_Create2(&Mod, 3); }
"""
            so_file = tmp / "auto_ext.so"
            self._compile_c_extension(c_code, so_file)

            runner = tmp / "test_runner.lua"
            runner.write_text(f"""
local mm = require("src/luthon/lua/modules")
mm.add_search_path("{tmp}")
local auto_mod = mm.load("auto_ext")
assert(type(auto_mod) == "table", "auto_mod must be a table")
assert(type(auto_mod.square) == "function", "square must be a function")
assert(auto_mod.square(9) == 81, "square(9) must be 81")
print("TIER_4_5_AUTO_RESOLUTION_PASSED")
""", encoding="utf-8")
            res = subprocess.run(["luajit", str(runner)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("TIER_4_5_AUTO_RESOLUTION_PASSED", res.stdout)

    def test_native_image_codecs_and_swizzling(self):
        """Verify pure LuaJIT FFI PNG encoding/decoding and texture channel packing."""
        script = """
local codecs = require("src/luthon/lua/native/codecs")
if codecs.has_png then
  local ffi = require("ffi")
  local pixels = ffi.new("uint8_t[16*4]")
  for i = 0, 15 do
    pixels[i*4 + 0] = 128
    pixels[i*4 + 1] = 64
    pixels[i*4 + 2] = 32
    pixels[i*4 + 3] = 255
  end
  local png = codecs.encode_png(4, 4, 4, pixels)
  assert(#png > 0)
  local dec = codecs.decode_png(png)
  assert(dec.width == 4 and dec.height == 4 and dec.channels == 4)
  assert(dec.data[0] == 128 and dec.data[1] == 64 and dec.data[2] == 32)
end
print("IMAGE_CODECS_TEST_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("IMAGE_CODECS_TEST_PASSED", res.stdout)

    def test_capsule_protocol(self):
        """Verify PyCapsule_New, PyCapsule_GetPointer, and PyCapsule_SetContext round-trip."""
        script = f"""
local ffi = require("ffi")
ffi.cdef[[
  typedef struct _object PyObject;
  typedef void (*PyCapsule_Destructor)(PyObject *);
  PyObject* PyCapsule_New(void *pointer, const char *name, PyCapsule_Destructor destructor);
  int PyCapsule_IsValid(PyObject *op, const char *name);
  void* PyCapsule_GetPointer(PyObject *op, const char *name);
  void* PyCapsule_GetContext(PyObject *op);
  int PyCapsule_SetContext(PyObject *op, void *context);
  void Py_DecRef(PyObject *o);
]]
local capi = ffi.load("{self.capi_lib}")
local dummy_ptr = ffi.cast("void*", 0x12345678)
local cap = capi.PyCapsule_New(dummy_ptr, "test._C_API", nil)
assert(cap ~= nil, "capsule must not be nil")
assert(capi.PyCapsule_IsValid(cap, "test._C_API") == 1, "capsule must be valid")
assert(capi.PyCapsule_IsValid(cap, "wrong.name") == 0, "wrong name must be invalid")
local retrieved = capi.PyCapsule_GetPointer(cap, "test._C_API")
assert(retrieved == dummy_ptr, "retrieved pointer must match dummy_ptr")

local ctx = ffi.cast("void*", 0x9999)
assert(capi.PyCapsule_SetContext(cap, ctx) == 0)
assert(capi.PyCapsule_GetContext(cap) == ctx)

capi.Py_DecRef(cap)
print("CAPSULE_PROTOCOL_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("CAPSULE_PROTOCOL_PASSED", res.stdout)

    def test_heap_object_allocation_and_lifetime(self):
        """Verify _PyObject_New allocates custom tp_basicsize and _Py_Dealloc runs."""
        script = f"""
local ffi = require("ffi")
ffi.cdef[[
  typedef struct _object PyObject;
  typedef struct _typeobject {{
      long ob_refcnt;
      void *ob_type;
      const char *tp_name;
      long tp_basicsize;
      long tp_itemsize;
      void (*tp_dealloc)(PyObject *);
  }} PyTypeObject;
  PyObject* _PyObject_New(PyTypeObject *tp);
  void _Py_Dealloc(PyObject *op);
  void Py_DecRef(PyObject *op);
]]
local capi = ffi.load("{self.capi_lib}")
local custom_type = ffi.new("PyTypeObject")
custom_type.tp_name = "CustomImagingType"
custom_type.tp_basicsize = 128
local dealloc_called = false
custom_type.tp_dealloc = ffi.cast("void(*)(PyObject*)", function(op)
    dealloc_called = true
end)

local obj = capi._PyObject_New(custom_type)
assert(obj ~= nil, "obj must not be nil")
capi.Py_DecRef(obj)
assert(dealloc_called == true, "tp_dealloc must be invoked on Py_DecRef")
print("HEAP_OBJECT_LIFETIME_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("HEAP_OBJECT_LIFETIME_PASSED", res.stdout)

    def test_pillow_imaging_reflection_inplace(self):
        """Verify Pillow's native _imaging.so loads and reflects all methods with 0 missing ABI symbols."""
        so_path = Path("/usr/lib64/python3.14/site-packages/PIL/_imaging.cpython-314-x86_64-linux-gnu.so")
        if not so_path.exists():
            self.skipTest(f"PIL _imaging.so not found at {so_path}")

        reflector = BinaryReflector()
        meta = reflector.reflect_binary(so_path)
        self.assertEqual(meta.name, "_imaging")
        self.assertGreaterEqual(len(meta.methods), 50)
        method_names = {m.name for m in meta.methods}
        self.assertIn("alpha_composite", method_names)
        self.assertIn("blend", method_names)
        self.assertIn("convert", method_names)
        self.assertIn("new", method_names)
        self.assertIn("clear_cache", method_names)


if __name__ == "__main__":
    unittest.main()
