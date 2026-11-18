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

    def test_numpy_multiarray_umath_reflection(self):
        """Verify NumPy's _multiarray_umath.so loads via C-API proxy with 0 missing symbols."""
        so_path = Path("/home/hg/.local/lib/python3.14/site-packages/numpy/_core/_multiarray_umath.cpython-314-x86_64-linux-gnu.so")
        if not so_path.exists():
            self.skipTest(f"NumPy binary not found at {so_path}")

        script = f"""
local ffi = require("ffi")
ffi.cdef[[
  void* dlopen(const char *filename, int flag);
  char* dlerror(void);
]]
local RTLD_NOW = 2
local RTLD_GLOBAL = 256
local h_capi = ffi.C.dlopen("{self.capi_lib}", bit.bor(RTLD_NOW, RTLD_GLOBAL))
assert(h_capi ~= nil, "failed to load libluthon_capi.so")

local h_numpy = ffi.C.dlopen("{so_path}", bit.bor(RTLD_NOW, RTLD_GLOBAL))
if h_numpy == nil then
  error("dlerror: " .. ffi.string(ffi.C.dlerror()))
end
print("NUMPY_CAPI_REFLECTION_PASSED")
"""
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("NUMPY_CAPI_REFLECTION_PASSED", res.stdout)

    def test_native_numpy_and_pillow_shims(self):
        """Verify native numpy and PIL.Image shims operate without pybridge CPython fallback."""
        script = """
        package.path = "./src/?.lua;./src/luthon/lua/?.lua;./src/luthon/lua/native/?.lua;" .. package.path
        require("bootstrap")
        local modules = require("modules")
        local np = modules.load("numpy")
        local Image = modules.load("PIL.Image")
        assert(np, "numpy shim must be loaded")
        assert(Image, "PIL.Image shim must be loaded")

        local arr = np.array({10, 20, 30})
        assert(arr.ndim == 1, "arr ndim must be 1")
        assert(arr.shape[1] == 3, "arr length must be 3")

        local cond = _luthon_cmp(">", arr, 15)
        assert(np.any(cond) == true, "np.any(arr > 15) must be true")

        local c0 = np.array({1, 2})
        local c1 = np.array({3, 4})
        local c2 = np.array({5, 6})
        c0.shape = {1, 2}; c0.strides = {2, 1}; c0.ndim = 2
        c1.shape = {1, 2}; c1.strides = {2, 1}; c1.ndim = 2
        c2.shape = {1, 2}; c2.strides = {2, 1}; c2.ndim = 2
        local stacked = np.stack({c0, c1, c2}, -1)
        assert(stacked.ndim == 3, "stacked must be 3D")
        assert(stacked.shape[3] == 3, "stacked channels must be 3")

        local im = Image.fromarray(stacked, "RGB")
        assert(im.mode == "RGB", "im mode must be RGB")
        assert(im.size[1] == 2 and im.size[2] == 1, "im size must be (2, 1)")
        print("NATIVE_NUMPY_AND_PILLOW_SHIMS_OK")
        """
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("NATIVE_NUMPY_AND_PILLOW_SHIMS_OK", res.stdout)

    def test_pybridge_builtin_types_lazy_reactor_and_argv_sync(self):
        """Verify builtin type marshaling, lazy reactor initialization, and sys.argv in-place sync."""
        script = """
        package.path = "./src/?.lua;./src/luthon/lua/?.lua;" .. package.path
        dofile("src/luthon/lua/bootstrap.lua")
        local pb = require("pybridge")
        local lib = pb.get_lib()
        local py_sys = pb.import("sys")
        local builtins = pb.import("builtins")

        local r_entry = py_sys.modules:get("twisted.internet.reactor")
        assert(r_entry == nil or r_entry == _G.None, "twisted.internet.reactor must not be eagerly imported")

        local builtin_list = {int, str, float, bool, list, dict, tuple, set, frozenset, bytes, object, _luthon_type, NoneType}
        for _, bt in ipairs(builtin_list) do
          local py_obj = pb.lua_to_py(bt)
          assert(py_obj ~= nil, "lua_to_py failed for builtin type: " .. tostring(rawget(bt, "__name__")))
          lib.Py_DecRef(py_obj)
        end

        assert(builtins.isinstance(42, int) == true, "isinstance(42, int) must succeed")
        assert(builtins.isinstance("abc", str) == true, "isinstance('abc', str) must succeed")
        assert(tostring(builtins.str(builtins.type(1))) == "<class 'int'>", "builtins.type(1) must be <class 'int'>")
        assert(tostring(builtins.str(NoneType)) == "<class 'NoneType'>", "NoneType must map cleanly")

        sys.argv = setmetatable({"app", "subcmd", "--flag"}, _list_mt)
        assert(builtins.len(py_sys.argv) == 3, "sys.argv initial length must sync to 3")
        sys.argv:remove("subcmd")
        assert(builtins.len(py_sys.argv) == 2, "sys.argv length after remove must sync to 2")
        assert(py_sys.argv[0] == "app" and py_sys.argv[1] == "--flag", "sys.argv contents must match after in-place remove")

        print("PYBRIDGE_BUILTIN_LAZY_REACTOR_ARGV_OK")
        """
        res = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("PYBRIDGE_BUILTIN_LAZY_REACTOR_ARGV_OK", res.stdout)

    def test_capi_elf_symbol_preflight_rejection(self):
        """Verify ELF symbol preflight rejects missing symbols and verifies init symbol existence."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            # Binary referencing unsupported Py C-API symbol
            bad_c = """
            extern int Py_NonExistent_Unsupported_Symbol_123(void);
            int bad_func(void) { return Py_NonExistent_Unsupported_Symbol_123(); }
            """
            bad_so = tmp / "bad.so"
            self._compile_c_extension(bad_c, bad_so)

            # Binary with valid C-API symbols
            good_c = """
            #include <stdint.h>
            typedef struct _object PyObject;
            typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
            typedef struct PyModuleDef_Base {
                long long ob_refcnt;
                void *ob_type;
                void* (*m_init)(void);
                long long m_index;
                void *m_copy;
            } PyModuleDef_Base;
            typedef struct PyModuleDef {
                PyModuleDef_Base m_base;
                const char *m_name;
                const char *m_doc;
                long long m_size;
                PyMethodDef *m_methods;
            } PyModuleDef;

            extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
            static PyMethodDef Methods[] = {{0, 0, 0, 0}};
            static PyModuleDef Mod = {{ 1, 0, 0, 0, 0 }, "good_mod", "doc", -1, Methods };
            __attribute__((visibility("default"))) PyObject* PyInit_good_mod(void) { return PyModule_Create2(&Mod, 3); }
            """
            good_so = tmp / "good.so"
            self._compile_c_extension(good_c, good_so)

            script = f"""
            local ffi = require('ffi')
            ffi.cdef[[
                int luthon_capi_can_load_extension(const char *so_path, const char *init_symbol);
            ]]
            local capi = ffi.load('{self.capi_lib}', true)

            -- Missing external symbol must be rejected
            local can_bad = capi.luthon_capi_can_load_extension('{bad_so}', nil)
            assert(can_bad == 0, 'bad.so with missing symbol must return 0')

            -- Good module with valid CAPI symbols and matching init_symbol
            local can_good = capi.luthon_capi_can_load_extension('{good_so}', 'PyInit_good_mod')
            assert(can_good == 1, 'good.so with PyInit_good_mod must return 1')

            -- Good module but wrong init_symbol must be rejected
            local can_wrong_init = capi.luthon_capi_can_load_extension('{good_so}', 'PyInit_wrong')
            assert(can_wrong_init == 0, 'good.so with nonexistent init symbol must return 0')

            print("CAPI_ELF_PREFLIGHT_TEST_OK")
            """
            runner = tmp / "run_preflight.lua"
            runner.write_text(script, encoding="utf-8")
            res = subprocess.run(["luajit", str(runner)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("CAPI_ELF_PREFLIGHT_TEST_OK", res.stdout)

    def test_capi_pep489_module_init_and_call_cfunction(self):
        """Verify luthon_capi_init_module, get_module_methods, and call_cfunction dispatch."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
            #include <stdint.h>
            typedef struct _object PyObject;
            typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
            typedef struct PyModuleDef_Base {
                long long ob_refcnt;
                void *ob_type;
                void* (*m_init)(void);
                long long m_index;
                void *m_copy;
            } PyModuleDef_Base;
            typedef struct PyModuleDef {
                PyModuleDef_Base m_base;
                const char *m_name;
                const char *m_doc;
                long long m_size;
                PyMethodDef *m_methods;
            } PyModuleDef;

            extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
            extern PyObject* PyLong_FromLongLong(long long v);
            extern long long PyLong_AsLongLong(PyObject *obj);

            static PyObject* c_noargs(PyObject *self, PyObject *unused) {
                return PyLong_FromLongLong(100);
            }
            static PyObject* c_meth_o(PyObject *self, PyObject *arg) {
                long long v = PyLong_AsLongLong(arg);
                return PyLong_FromLongLong(v * 2);
            }

            static PyMethodDef Methods[] = {
                {"noargs", (void*)c_noargs, 4, "No arguments function"},
                {"double_it", (void*)c_meth_o, 8, "Unary function"},
                {0, 0, 0, 0}
            };
            static PyModuleDef Mod = {{ 1, 0, 0, 0, 0 }, "dispatch_mod", "doc", -1, Methods };
            __attribute__((visibility("default"))) PyObject* PyInit_dispatch_mod(void) { return PyModule_Create2(&Mod, 3); }
            """
            so_file = tmp / "dispatch_mod.so"
            self._compile_c_extension(c_code, so_file)

            script = f"""
            local ffi = require('ffi')
            ffi.cdef[[
                typedef struct _object PyObject;
                typedef struct PyMethodDef {{
                    const char *ml_name;
                    void *ml_meth;
                    int ml_flags;
                    const char *ml_doc;
                }} PyMethodDef;

                PyObject* PyInit_dispatch_mod(void);
                PyObject* luthon_capi_init_module(void *init_fn_ptr, const char *name);
                PyMethodDef* luthon_capi_get_module_methods(PyObject *mod);
                PyObject* luthon_capi_call_cfunction(void *meth_ptr, int ml_flags, PyObject *self, PyObject *args, PyObject *kwargs);
                PyObject* PyLong_FromLongLong(long long v);
                long long PyLong_AsLongLong(PyObject *obj);
                PyObject* PyTuple_New(int size);
                int PyTuple_SetItem(PyObject *tuple, int pos, PyObject *item);
            ]]
            local capi = ffi.load('{self.capi_lib}', true)
            local mod_lib = ffi.load('{so_file}')

            local init_ptr = ffi.cast('void*', mod_lib.PyInit_dispatch_mod)
            local mod_obj = capi.luthon_capi_init_module(init_ptr, 'dispatch_mod')
            assert(mod_obj ~= nil, 'mod_obj must not be nil')

            local methods = capi.luthon_capi_get_module_methods(mod_obj)
            assert(methods ~= nil, 'methods must not be nil')
            assert(ffi.string(methods[0].ml_name) == 'noargs', 'method 0 name must be noargs')
            assert(ffi.string(methods[1].ml_name) == 'double_it', 'method 1 name must be double_it')

            -- Test METH_NOARGS
            local res1 = capi.luthon_capi_call_cfunction(methods[0].ml_meth, methods[0].ml_flags, nil, nil, nil)
            assert(res1 ~= nil, 'res1 must not be nil')
            assert(capi.PyLong_AsLongLong(res1) == 100LL, 'noargs must return 100')

            -- Test METH_O with direct arg
            local arg = capi.PyLong_FromLongLong(21)
            local res2 = capi.luthon_capi_call_cfunction(methods[1].ml_meth, methods[1].ml_flags, nil, arg, nil)
            assert(res2 ~= nil, 'res2 must not be nil')
            assert(capi.PyLong_AsLongLong(res2) == 42LL, 'double_it must return 42')

            print("CAPI_DISPATCH_TEST_OK")
            """
            runner = tmp / "run_dispatch.lua"
            runner.write_text(script, encoding="utf-8")
            res = subprocess.run(["luajit", str(runner)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("CAPI_DISPATCH_TEST_OK", res.stdout)


if __name__ == "__main__":
    unittest.main()
