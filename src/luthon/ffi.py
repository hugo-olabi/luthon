"""C FFI binding generator and Python cffi translator for LuaJIT.

Generates LuaJIT `ffi.cdef` declarations and loader code from:
1. Python descriptions of C functions/structs.
2. Automated Python `cffi` AST and code translation (`cffi.FFI().cdef(...)`).
"""

from __future__ import annotations

import ast
import ctypes
import re
from typing import Optional, List, Tuple


class FFIBinding:
    def __init__(self, lib_path: str, declarations: str) -> None:
        self.lib_path = lib_path
        self.declarations = declarations

    def to_lua(self) -> str:
        return (
            "local ffi = require('ffi')\n"
            f"ffi.cdef[[\n{self.declarations.strip()}\n]]\n"
            f"local C = ffi.load('{self.lib_path}')\n"
            "return C\n"
        )


def cdef_function(name: str, restype: str, argtypes: list[str]) -> str:
    args = ", ".join(argtypes)
    return f"{restype} {name}({args});"


def load_library(path: str) -> ctypes.CDLL:
    return ctypes.CDLL(path)


def describe_library(path: str, functions: list[tuple[str, str, list[str]]]) -> FFIBinding:
    decls = "\n".join(cdef_function(n, r, a) for n, r, a in functions)
    return FFIBinding(path, decls)


def lua_ffi_stub(lib_name: str = "mylib") -> str:
    return (
        "local ffi = require('ffi')\n"
        "-- declare C functions here, e.g.:\n"
        "-- ffi.cdef[[ int add(int a, int b); ]]\n"
        f"local C = ffi.load('{lib_name}')\n"
        "return C\n"
    )


class CFFITranslator:
    """Translates Python code using `cffi` into equivalent LuaJIT FFI code."""

    def __init__(self) -> None:
        self.cdefs: list[str] = []
        self.libs: list[tuple[str, Optional[str]]] = []  # (var_name, lib_path)

    def translate_source(self, python_code: str) -> str:
        """Parses Python source and generates LuaJIT FFI declarations."""
        tree = ast.parse(python_code)
        return self.translate_ast(tree)

    def translate_ast(self, tree: ast.AST) -> str:
        self.cdefs.clear()
        self.libs.clear()

        # Traverse AST searching for cdef and dlopen calls
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                # Check for ffi.cdef(...) or FFI().cdef(...)
                if isinstance(node.func, ast.Attribute) and node.func.attr == "cdef":
                    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                        self.cdefs.append(node.args[0].value.strip())
                # Check for ffi.dlopen(...)
                elif isinstance(node.func, ast.Attribute) and node.func.attr == "dlopen":
                    lib_path = None
                    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                        lib_path = node.args[0].value
                    self.libs.append(("C", lib_path))

        lines = ["local ffi = require('ffi')"]
        if self.cdefs:
            combined_cdef = "\n".join(self.cdefs)
            lines.append(f"ffi.cdef[[\n{combined_cdef}\n]]")

        if self.libs:
            for var_name, lib_path in self.libs:
                if lib_path:
                    lines.append(f"local {var_name} = ffi.load('{lib_path}')")
                else:
                    lines.append(f"local {var_name} = ffi.C")
        else:
            lines.append("local C = ffi.C")

        return "\n".join(lines) + "\n"


def translate_cffi(python_code: str) -> str:
    """Helper function to translate Python cffi code to LuaJIT FFI Lua code."""
    return CFFITranslator().translate_source(python_code)
