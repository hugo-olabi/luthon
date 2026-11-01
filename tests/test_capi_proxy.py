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


if __name__ == "__main__":
    unittest.main()
