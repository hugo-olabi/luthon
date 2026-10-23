"""C FFI binding generator for LuaJIT.

Generates LuaJIT `ffi.cdef` declarations and loader code from a small
description of C functions/structs, plus a Python-side helper to register
shared libraries.
"""

from __future__ import annotations

import ctypes
import os


class FFIBinding:
    def __init__(self, lib_path: str, declarations: str) -> None:
        self.lib_path = lib_path
        self.declarations = declarations

    def to_lua(self) -> str:
        return (
            "local ffi = require('ffi')\n"
            f"ffi.cdef[[\n{self.declarations}\n]]\n"
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
