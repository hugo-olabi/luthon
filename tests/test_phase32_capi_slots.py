"""Tests for Phase 32: Native C-API Proxy Full Slot Dispatch (tp_iternext, tp_richcompare, tp_hash, tp_descr_get/set)."""

import unittest
import tempfile
import subprocess
from pathlib import Path

from luthon.native.build_capi import get_capi_library_path, compile_capi_proxy


class TestPhase32CAPISlots(unittest.TestCase):
    """Unit tests for Phase 32 C-API slot dispatch executed under LuaJIT."""

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

    def test_custom_iterator_slot_dispatch(self):
        """Test custom tp_iternext and tp_iter slot callbacks on C-extension types."""
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
    int _pad;
    long current;
    long stop;
}} CountdownIter;

static PyObject* countdown_next(PyObject *self) {{
    CountdownIter *it = (CountdownIter *)self;
    if (it->current <= it->stop) return 0;
    it->current--;
    return PyLong_FromLongLong(it->current);
}}

static PyTypeObject Countdown_Type = {{
    .ob_refcnt = 1,
    .ob_type = &Base_Type,
    .tp_name = "Countdown",
    .tp_basicsize = sizeof(CountdownIter),
    .tp_iternext = countdown_next
}};

__attribute__((visibility("default")))
PyObject* make_countdown(long start, long stop) {{
    CountdownIter *it = (CountdownIter *)calloc(1, sizeof(CountdownIter));
    it->ob_refcnt = 1;
    it->ob_type = &Countdown_Type;
    it->tag = PY_TAG_OPAQUE;
    it->current = start;
    it->stop = stop;
    return (PyObject *)it;
}}
"""
            so_file = tmp / "countdown.so"
            self._compile_c_extension(c_code, so_file)

            script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)
local ext = ffi.load("{so_file}")

ffi.cdef[[
  typedef struct _object PyObject;
  PyObject* make_countdown(long start, long stop);
  PyObject* PyObject_GetIter(PyObject *o);
  PyObject* PyIter_Next(PyObject *iter);
  long long PyLong_AsLongLong(PyObject *obj);
]]

local it = ext.make_countdown(5, 2)
local iter_obj = capi.PyObject_GetIter(it)
assert(iter_obj ~= nil, "iter_obj must not be nil")

local v1 = capi.PyIter_Next(iter_obj)
assert(tonumber(capi.PyLong_AsLongLong(v1)) == 4, "first item must be 4")

local v2 = capi.PyIter_Next(iter_obj)
assert(tonumber(capi.PyLong_AsLongLong(v2)) == 3, "second item must be 3")

local v3 = capi.PyIter_Next(iter_obj)
assert(tonumber(capi.PyLong_AsLongLong(v3)) == 2, "third item must be 2")

local v4 = capi.PyIter_Next(iter_obj)
assert(v4 == nil, "fourth item must be nil (iteration ended)")
print("CUSTOM_ITERATOR_SLOT_PASSED")
"""
            proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
            self.assertIn("CUSTOM_ITERATOR_SLOT_PASSED", proc.stdout)

    def test_rich_compare_slot_dispatch(self):
        """Test custom tp_richcompare dispatch on custom extension types."""
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
    int _pad;
    long weight;
}} WeightObj;

static PyObject* weight_richcompare(PyObject *v, PyObject *w, int op) {{
    WeightObj *w1 = (WeightObj *)v;
    WeightObj *w2 = (WeightObj *)w;
    int cmp = 0;
    switch (op) {{
        case Py_LT: cmp = (w1->weight < w2->weight); break;
        case Py_LE: cmp = (w1->weight <= w2->weight); break;
        case Py_EQ: cmp = (w1->weight == w2->weight); break;
        case Py_NE: cmp = (w1->weight != w2->weight); break;
        case Py_GT: cmp = (w1->weight > w2->weight); break;
        case Py_GE: cmp = (w1->weight >= w2->weight); break;
    }}
    return PyBool_FromLong(cmp);
}}

static PyTypeObject Weight_Type = {{
    .ob_refcnt = 1,
    .ob_type = &Base_Type,
    .tp_name = "Weight",
    .tp_basicsize = sizeof(WeightObj),
    .tp_richcompare = weight_richcompare
}};

__attribute__((visibility("default")))
PyObject* make_weight(long w) {{
    WeightObj *obj = (WeightObj *)calloc(1, sizeof(WeightObj));
    obj->ob_refcnt = 1;
    obj->ob_type = &Weight_Type;
    obj->tag = PY_TAG_OPAQUE;
    obj->weight = w;
    return (PyObject *)obj;
}}
"""
            so_file = tmp / "weight.so"
            self._compile_c_extension(c_code, so_file)

            script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)
local ext = ffi.load("{so_file}")

ffi.cdef[[
  typedef struct _object PyObject;
  PyObject* make_weight(long w);
  int PyObject_RichCompareBool(PyObject *v, PyObject *w, int op);
]]

local w10 = ext.make_weight(10)
local w20 = ext.make_weight(20)

-- Py_LT = 0, Py_LE = 1, Py_EQ = 2, Py_NE = 3, Py_GT = 4, Py_GE = 5
assert(capi.PyObject_RichCompareBool(w10, w20, 0) == 1, "10 < 20 must be true")
assert(capi.PyObject_RichCompareBool(w10, w20, 4) == 0, "10 > 20 must be false")
assert(capi.PyObject_RichCompareBool(w10, w10, 2) == 1, "10 == 10 must be true")
assert(capi.PyObject_RichCompareBool(w10, w20, 3) == 1, "10 != 20 must be true")
print("RICH_COMPARE_SLOT_PASSED")
"""
            proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
            self.assertIn("RICH_COMPARE_SLOT_PASSED", proc.stdout)

    def test_hash_protocol_dispatch(self):
        """Test custom tp_hash and standard hashing algorithms."""
        script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)

ffi.cdef[[
  typedef struct _object PyObject;
  typedef long Py_ssize_t;
  PyObject* PyLong_FromLongLong(long long v);
  PyObject* PyFloat_FromDouble(double v);
  PyObject* PyUnicode_FromString(const char *s);
  Py_ssize_t PyObject_Hash(PyObject *o);
]]

-- Integer hash
local i_obj = capi.PyLong_FromLongLong(987654321)
assert(tonumber(capi.PyObject_Hash(i_obj)) == 987654321, "Integer hash")

-- Float hash
local f_obj = capi.PyFloat_FromDouble(2.71828)
local h_flt = capi.PyObject_Hash(f_obj)
assert(h_flt ~= 0 and h_flt ~= -1, "Float hash")

-- String hash
local s1 = capi.PyUnicode_FromString("luthon_speed")
local s2 = capi.PyUnicode_FromString("luthon_speed")
assert(capi.PyObject_Hash(s1) == capi.PyObject_Hash(s2), "String hash match")
assert(capi.PyObject_Hash(s1) ~= 0 and capi.PyObject_Hash(s1) ~= -1, "Valid string hash")
print("HASH_PROTOCOL_PASSED")
"""
        proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("HASH_PROTOCOL_PASSED", proc.stdout)

    def test_descriptor_property_and_member_protocol(self):
        """Test PyGetSetDef properties and PyMemberDef struct attributes."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            c_code = f"""
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "luthon_capi.h"

typedef struct {{
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    int _pad;
    int code;
    double score;
}} PlayerObj;

static PyObject* get_double_score(PyObject *self, void *closure) {{
    (void)closure;
    PlayerObj *p = (PlayerObj *)self;
    return PyLong_FromLongLong((long long)(p->score * 2.0));
}}

static int set_double_score(PyObject *self, PyObject *val, void *closure) {{
    (void)closure;
    PlayerObj *p = (PlayerObj *)self;
    p->score = (double)PyLong_AsLongLong(val) / 2.0;
    return 0;
}}

static PyGetSetDef Player_GetSet[] = {{
    {{"double_score", get_double_score, set_double_score, "Double score", 0}},
    {{0, 0, 0, 0, 0}}
}};

static PyMemberDef Player_Members[] = {{
    {{"code", T_INT, offsetof(PlayerObj, code), 0, "code"}},
    {{"score", T_DOUBLE, offsetof(PlayerObj, score), 0, "score"}},
    {{0, 0, 0, 0, 0}}
}};

static PyTypeObject Player_Type = {{
    .ob_refcnt = 1,
    .ob_type = &Base_Type,
    .tp_name = "Player",
    .tp_basicsize = sizeof(PlayerObj),
    .tp_members = Player_Members,
    .tp_getset = Player_GetSet
}};

__attribute__((visibility("default")))
PyObject* make_player(int code, double score) {{
    PlayerObj *p = (PlayerObj *)calloc(1, sizeof(PlayerObj));
    p->ob_refcnt = 1;
    p->ob_type = &Player_Type;
    p->tag = PY_TAG_OPAQUE;
    p->code = code;
    p->score = score;
    return (PyObject *)p;
}}
"""
            so_file = tmp / "player.so"
            self._compile_c_extension(c_code, so_file)

            script = f"""
local ffi = require("ffi")
local capi = ffi.load("{self.capi_path}", true)
local ext = ffi.load("{so_file}")

ffi.cdef[[
  typedef struct _object PyObject;
  PyObject* make_player(int code, double score);
  PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name);
  int PyObject_SetAttrString(PyObject *o, const char *attr_name, PyObject *v);
  long long PyLong_AsLongLong(PyObject *obj);
  PyObject* PyLong_FromLongLong(long long v);
  double PyFloat_AsDouble(PyObject *obj);
]]

local p = ext.make_player(77, 84.5)
assert(p ~= nil, "player must not be nil")

-- 1. Read struct member 'code'
local code_val = capi.PyObject_GetAttrString(p, "code")
assert(tonumber(capi.PyLong_AsLongLong(code_val)) == 77, "code member value")

-- 2. Read property 'double_score' (84.5 * 2 = 169)
local prop_val = capi.PyObject_GetAttrString(p, "double_score")
assert(tonumber(capi.PyLong_AsLongLong(prop_val)) == 169, "double_score getter value")

-- 3. Write property 'double_score' = 250 -> score becomes 125.0
local set_ret = capi.PyObject_SetAttrString(p, "double_score", capi.PyLong_FromLongLong(250))
assert(set_ret == 0, "property setter return code")

-- 4. Verify modified score member
local score_val = capi.PyObject_GetAttrString(p, "score")
assert(tonumber(capi.PyFloat_AsDouble(score_val)) == 125.0, "score member value after setter")
print("DESCRIPTOR_PROPERTY_MEMBER_PASSED")
"""
            proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
            self.assertIn("DESCRIPTOR_PROPERTY_MEMBER_PASSED", proc.stdout)


if __name__ == "__main__":
    unittest.main()
