"""Tests for Phase 37: Autonomous C Header & DWARF Reflection (reflect.py)."""

import unittest
import tempfile
import subprocess
from pathlib import Path

from luthon.reflect import BinaryReflector, DWARFInspector


class TestPhase37DWARFReflection(unittest.TestCase):
    """Unit tests for DWARF inspection, automated FFI CDEF generation, and binary execution."""

    def test_dwarf_inspection_and_cdef_generation(self):
        """Test extracting function prototypes and generating ffi.cdef from DWARF debuginfo."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
#include <stdint.h>
typedef struct _object PyObject;
typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
typedef struct PyModuleDef { int m_base; int _pad; const char *m_name; const char *m_doc; long m_size; PyMethodDef *m_methods; } PyModuleDef;
extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
extern PyObject* PyLong_FromLongLong(long long v);
extern int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);

PyObject* fast_sum(PyObject *self, PyObject *args) {
    long long a, b;
    if (!PyArg_ParseTuple(args, "LL", &a, &b)) return 0;
    return PyLong_FromLongLong(a + b);
}

PyObject* vector_scale(PyObject *self, PyObject *args) {
    long long x, scale;
    if (!PyArg_ParseTuple(args, "LL", &x, &scale)) return 0;
    return PyLong_FromLongLong(x * scale);
}

static PyMethodDef Methods[] = {
    {"fast_sum", (void*)fast_sum, 1, "Sum two numbers"},
    {"vector_scale", (void*)vector_scale, 1, "Scale a vector"},
    {0, 0, 0, 0}
};
static PyModuleDef Mod = { 0, 0, "dwarf_math", "DWARF reflected math", -1, Methods };
__attribute__((visibility("default"))) PyObject* PyInit_dwarf_math(void) { return PyModule_Create2(&Mod, 3); }
"""
            so_file = tmp / "dwarf_math.so"
            subprocess.run(
                ["gcc", "-g", "-O2", "-fPIC", "-shared", "-o", str(so_file), "-x", "c", "-"],
                input=c_code,
                text=True,
                check=True,
            )

            inspector = DWARFInspector()
            cdef = inspector.generate_cdef(so_file, ["fast_sum", "vector_scale"])
            self.assertIn("fast_sum", cdef)
            self.assertIn("vector_scale", cdef)

    def test_end_to_end_dwarf_reflected_binary_execution(self):
        """Verify full binary reflection with DWARF CDEF generation executes natively under LuaJIT."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = """
#include <stdint.h>
typedef struct _object PyObject;
typedef struct PyMethodDef { const char *ml_name; void *ml_meth; int ml_flags; const char *ml_doc; } PyMethodDef;
typedef struct PyModuleDef { int m_base; int _pad; const char *m_name; const char *m_doc; long m_size; PyMethodDef *m_methods; } PyModuleDef;
extern PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
extern PyObject* PyLong_FromLongLong(long long v);
extern int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);

PyObject* multiply_cubed(PyObject *self, PyObject *args) {
    long long a, b;
    if (!PyArg_ParseTuple(args, "LL", &a, &b)) return 0;
    long long prod = a * b;
    return PyLong_FromLongLong(prod * prod * prod);
}

static PyMethodDef Methods[] = {
    {"multiply_cubed", (void*)multiply_cubed, 1, "Cube of product"},
    {0, 0, 0, 0}
};
static PyModuleDef Mod = { 0, 0, "cube_math", "Cube math extension", -1, Methods };
__attribute__((visibility("default"))) PyObject* PyInit_cube_math(void) { return PyModule_Create2(&Mod, 3); }
"""
            so_file = tmp / "cube_math.so"
            subprocess.run(
                ["gcc", "-g", "-O2", "-fPIC", "-shared", "-o", str(so_file), "-x", "c", "-"],
                input=c_code,
                text=True,
                check=True,
            )

            reflector = BinaryReflector()
            meta = reflector.reflect_binary(so_file, module_name="cube_math")
            self.assertEqual(meta.name, "cube_math")
            self.assertTrue(any(m.name == "multiply_cubed" for m in meta.methods))

            lua_trampoline = reflector.generate_lua_trampoline(meta)
            self.assertIn("multiply_cubed", lua_trampoline)

            lua_file = tmp / "cube_math.lua"
            lua_file.write_text(lua_trampoline, encoding="utf-8")

            runner = tmp / "run_test.lua"
            runner.write_text(f"""
package.path = "{tmp}/?.lua;" .. package.path
local cube = require("cube_math")
assert(type(cube) == "table", "cube module must be table")
-- 2 * 3 = 6, 6^3 = 216
local res = cube.multiply_cubed(2, 3)
assert(res == 216, "multiply_cubed(2, 3) must equal 216")
print("DWARF_REFLECTION_EXECUTION_PASSED")
""")
            res = subprocess.run(["luajit", str(runner)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("DWARF_REFLECTION_EXECUTION_PASSED", res.stdout)


if __name__ == "__main__":
    unittest.main()
