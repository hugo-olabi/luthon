"""Binary Reflection Engine & FFI Trampoline Generator.

Inspects precompiled Python C-extensions (.so, .pyd, .dll), calls their
PyInit_<name> entry point via ctypes/FFI against Luthon's C-API proxy,
extracts the PyMethodDef function table, and synthesizes pure LuaJIT FFI
bindings so they execute at native speed without CPython.
"""

from __future__ import annotations

import ctypes
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .native.build_capi import compile_capi_proxy, get_capi_library_path


@dataclass
class MethodSignature:
    name: str
    flags: int
    doc: str = ""
    is_varargs: bool = True
    is_keywords: bool = False
    is_noargs: bool = False
    is_onearg: bool = False


@dataclass
class ModuleMetadata:
    name: str
    doc: str = ""
    methods: List[MethodSignature] = field(default_factory=list)
    binary_path: str = ""


# C structure definitions matching capi_proxy.c
class PyMethodDef(ctypes.Structure):
    _fields_ = [
        ("ml_name", ctypes.c_char_p),
        ("ml_meth", ctypes.c_void_p),
        ("ml_flags", ctypes.c_int),
        ("ml_doc", ctypes.c_char_p),
    ]


class PyModuleDef(ctypes.Structure):
    _fields_ = [
        ("m_base", ctypes.c_int),
        ("m_name", ctypes.c_char_p),
        ("m_doc", ctypes.c_char_p),
        ("m_size", ctypes.c_ssize_t),
        ("m_methods", ctypes.POINTER(PyMethodDef)),
    ]


# PyMethodDef flags from Python C-API
METH_VARARGS = 0x0001
METH_KEYWORDS = 0x0002
METH_NOARGS = 0x0004
METH_O = 0x0008


class BinaryReflector:
    """Reflects compiled Python C-extension binaries (.so, .pyd) using Luthon's C-API proxy."""

    def __init__(self, capi_path: Optional[Path] = None):
        self.capi_path = capi_path or compile_capi_proxy()

    def reflect_binary(self, binary_path: Path, module_name: Optional[str] = None) -> ModuleMetadata:
        """Inspects a binary, calls PyInit_<name> and harvests the PyMethodDef array using LuaJIT FFI."""
        import json
        import subprocess

        binary_path = Path(binary_path).resolve()
        if not binary_path.exists():
            raise FileNotFoundError(f"Binary file not found: {binary_path}")

        # Derive module name from filename (e.g., _imaging.cpython-314-x86_64-linux-gnu.so -> _imaging)
        if not module_name:
            stem = binary_path.name
            stem = re.sub(r"\.(cpython|pypy)-[^\.]+", "", stem)
            stem = stem.split(".")[0]
            module_name = stem

        script = f'''
        local ffi = require("ffi")
        ffi.cdef[[
          void* dlopen(const char* filename, int flags);
          typedef struct _object PyObject;
          typedef struct PyMethodDef {{
              const char  *ml_name;
              void        *ml_meth;
              int          ml_flags;
              const char  *ml_doc;
          }} PyMethodDef;
          typedef struct PyModuleDef {{
              int          m_base;
              const char  *m_name;
              const char  *m_doc;
              long         m_size;
              PyMethodDef *m_methods;
          }} PyModuleDef;
          typedef struct _object {{
              long ob_refcnt;
              void *ob_type;
              int tag;
              int _pad;
              PyModuleDef *module_def;
          }} MyPyObject;

          PyObject* PyInit_{module_name}(void);
        ]]

        ffi.C.dlopen("{self.capi_path}", 258)
        local ext = ffi.load("{binary_path}")
        local ok, mod_ptr = pcall(function() return ffi.cast("MyPyObject*", ext.PyInit_{module_name}()) end)
        if not ok or mod_ptr == nil or mod_ptr.module_def == nil then
            print(string.format('{{"name": "%s", "doc": "", "methods": []}}', "{module_name}"))
            return
        end
        local mod_def = mod_ptr.module_def

        local methods = {{}}
        if mod_def.m_methods ~= nil then
          local i = 0
          while mod_def.m_methods[i].ml_name ~= nil do
            local m = mod_def.m_methods[i]
            table.insert(methods, {{
              name = ffi.string(m.ml_name),
              flags = tonumber(m.ml_flags),
              doc = m.ml_doc ~= nil and ffi.string(m.ml_doc) or ""
            }})
            i = i + 1
          end
        end

        local parts = {{}}
        for _, m in ipairs(methods) do
          table.insert(parts, string.format('{{"name": "%s", "flags": %d, "doc": "%s"}}', m.name, m.flags, m.doc:gsub('"', '\\\\"')))
        end
        local m_name = mod_def.m_name ~= nil and ffi.string(mod_def.m_name) or "{module_name}"
        local m_doc = mod_def.m_doc ~= nil and ffi.string(mod_def.m_doc) or ""
        print(string.format('{{"name": "%s", "doc": "%s", "methods": [%s]}}',
          m_name,
          m_doc:gsub('"', '\\\\"'),
          table.concat(parts, ",")
        ))
        '''

        proc = subprocess.run(["luajit", "-e", script], capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"LuaJIT binary reflection failed for {binary_path}: {proc.stderr}")

        try:
            data = json.loads(proc.stdout.strip())
        except Exception as e:
            raise RuntimeError(f"Failed to parse reflected metadata for {binary_path}: {e}\nOutput: {proc.stdout}")

        meta = ModuleMetadata(
            name=data.get("name", module_name),
            doc=data.get("doc", ""),
            binary_path=str(binary_path),
        )
        for m in data.get("methods", []):
            flags = m.get("flags", 1)
            sig = MethodSignature(
                name=m.get("name", ""),
                flags=flags,
                doc=m.get("doc", ""),
                is_varargs=bool(flags & METH_VARARGS),
                is_keywords=bool(flags & METH_KEYWORDS),
                is_noargs=bool(flags & METH_NOARGS),
                is_onearg=bool(flags & METH_O),
            )
            meta.methods.append(sig)

        return meta

    def generate_lua_trampoline(self, meta: ModuleMetadata) -> str:
        """Generates a high-performance pure LuaJIT FFI wrapper module for the reflected binary."""
        lines = [
            f"--[[",
            f"  Auto-generated LuaJIT FFI binding for {meta.name}",
            f"  Binary: {Path(meta.binary_path).name}",
            f"--]]",
            "",
            'local ffi = require("ffi")',
            "",
            "ffi.cdef[[",
            "  void* dlopen(const char* filename, int flags);",
            "  typedef struct _object PyObject;",
            "  typedef long Py_ssize_t;",
            "",
            "  PyObject* PyLong_FromLongLong(long long v);",
            "  long long PyLong_AsLongLong(PyObject *obj);",
            "  PyObject* PyFloat_FromDouble(double v);",
            "  double PyFloat_AsDouble(PyObject *obj);",
            "  PyObject* PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size);",
            "  const char* PyUnicode_AsUTF8AndSize(PyObject *unicode, Py_ssize_t *size);",
            "  PyObject* PyTuple_New(Py_ssize_t len);",
            "  int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);",
            "  PyObject* PyTuple_GetItem(PyObject *p, Py_ssize_t pos);",
            "  Py_ssize_t PyTuple_Size(PyObject *p);",
            "  void Py_IncRef(PyObject *o);",
            "  void Py_DecRef(PyObject *o);",
            "  PyObject* PyErr_Occurred(void);",
            "  void PyErr_Clear(void);",
            f"  PyObject* PyInit_{meta.name}(void);",
            "]]",
            "",
            "-- Load Luthon C-API Proxy with RTLD_NOW | RTLD_GLOBAL (258) to satisfy C-extension dependencies",
            f'pcall(function() ffi.C.dlopen("{self.capi_path}", 258) end)',
            f'local capi = ffi.load("{self.capi_path}")',
            "",
            "-- Load precompiled extension shared library",
            f'local ext = ffi.load("{meta.binary_path}")',
            "",
            f"local _mod_ptr = ext.PyInit_{meta.name}()",
            f"if _mod_ptr == nil then error('Failed to initialize binary module {meta.name}', 2) end",
            "",
            "ffi.cdef[[",
            "  typedef struct PyMethodDef {",
            "      const char  *ml_name;",
            "      void        *ml_meth;",
            "      int          ml_flags;",
            "      const char  *ml_doc;",
            "  } PyMethodDef;",
            "  typedef struct PyModuleDef {",
            "      int          m_base;",
            "      const char  *m_name;",
            "      const char  *m_doc;",
            "      long         m_size;",
            "      PyMethodDef *m_methods;",
            "  } PyModuleDef;",
            "  typedef struct _py_mod_obj {",
            "      long ob_refcnt;",
            "      void *ob_type;",
            "      int tag;",
            "      int _pad;",
            "      PyModuleDef *module_def;",
            "  } _PyModObj;",
            "]]",
            "",
            "local _typed_mod = ffi.cast('_PyModObj*', _mod_ptr)",
            "local _mod_def = _typed_mod.module_def",
            "local _methods_map = {}",
            "if _mod_def ~= nil and _mod_def.m_methods ~= nil then",
            "  local idx = 0",
            "  while _mod_def.m_methods[idx].ml_name ~= nil do",
            "    local name = ffi.string(_mod_def.m_methods[idx].ml_name)",
            "    local fn_ptr = ffi.cast('PyObject* (*)(PyObject*, PyObject*)', _mod_def.m_methods[idx].ml_meth)",
            "    _methods_map[name] = fn_ptr",
            "    idx = idx + 1",
            "  end",
            "end",
            "",
            "local function _py_to_lua(py_obj)",
            "  if py_obj == nil then return nil end",
            "  -- Convert integer",
            "  local i = capi.PyLong_AsLongLong(py_obj)",
            "  local f = capi.PyFloat_AsDouble(py_obj)",
            "  if f ~= 0.0 and i == 0 then return tonumber(f) end",
            "  if i ~= 0 then return tonumber(i) end",
            "  local sz = ffi.new('Py_ssize_t[1]')",
            "  local s = capi.PyUnicode_AsUTF8AndSize(py_obj, sz)",
            "  if s ~= nil and sz[0] > 0 then return ffi.string(s, sz[0]) end",
            "  return py_obj",
            "end",
            "",
            "local function _lua_to_py(val)",
            "  if val == nil then return nil end",
            '  local t = type(val)',
            '  if t == "number" then',
            "    if math.floor(val) == val then",
            "      return capi.PyLong_FromLongLong(val)",
            "    else",
            "      return capi.PyFloat_FromDouble(val)",
            "    end",
            '  elseif t == "string" then',
            "    return capi.PyUnicode_FromStringAndSize(val, #val)",
            "  end",
            "  return nil",
            "end",
            "",
            f"local {meta.name} = {{}}",
            "",
        ]

        # Register functions
        for m in meta.methods:
            lines.extend([
                f"-- Method: {m.name} (flags=0x{m.flags:04x})",
                f"{meta.name}.{m.name} = function(...)",
                f"  local fn_ptr = _methods_map['{m.name}']",
                f"  if fn_ptr == nil then",
                f"    error('{meta.name}.{m.name} method pointer not found', 2)",
                f"  end",
                f"  local total = select('#', ...)",
                f"  local args_tuple = capi.PyTuple_New(total)",
                f"  for i = 1, total do",
                f"    local py_val = _lua_to_py(select(i, ...))",
                f"    capi.PyTuple_SetItem(args_tuple, i - 1, py_val)",
                f"  end",
                f"  local res = fn_ptr(nil, args_tuple)",
                f"  capi.Py_DecRef(args_tuple)",
                f"  if res == nil then",
                f"    if capi.PyErr_Occurred() ~= nil then",
                f"      capi.PyErr_Clear()",
                f"      error('{meta.name}.{m.name}() execution failed in C extension', 2)",
                f"    end",
                f"  end",
                f"  local ret = _py_to_lua(res)",
                f"  capi.Py_DecRef(res)",
                f"  return ret",
                f"end",
                "",
            ])

        lines.extend([
            f"return {meta.name}",
            "",
        ])

        return "\n".join(lines)
