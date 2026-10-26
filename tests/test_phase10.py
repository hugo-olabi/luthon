"""Phase 10: C Extensions, Native FFI & Hybrid Python Bridge.

Tests:
1. Automated Python `cffi` translation: lower `cffi.FFI().cdef(...)` declarations directly to LuaJIT `ffi.cdef[[...]]`.
2. Direct native FFI wrappers for common C-API modules (`sqlite3` -> `libsqlite3.so`, `zlib` -> `libz.so`, `ssl`/`hashlib` -> `libcrypto.so`).
3. Lazy on-demand CPython bridge: load `libpython3.so` via LuaJIT FFI only when an unsupported binary C extension is imported.
4. Transparent Python object proxy: marshal basic types (int, float, str, bool, list, dict) across the LuaJIT <-> CPython FFI boundary.
5. Opaque pointer passing: hold `PyObject*` references in LuaJIT for complex objects without full serialization.
6. Fallback module loader: waterfall import resolution (Pure Lua -> Pure .py in site-packages -> Native FFI shim -> Lazy libpython).
"""

import ast
import subprocess
import pytest
from pathlib import Path
from luthon.ffi import FFIBinding, describe_library, cdef_function, translate_cffi


def test_automated_cffi_translation():
    python_cffi_code = """
import cffi
ffi = cffi.FFI()
ffi.cdef('''
    int add(int a, int b);
    double multiply(double x, double y);
''')
lib = ffi.dlopen("libmath.so")
"""
    lua_code = translate_cffi(python_cffi_code)
    assert "local ffi = require('ffi')" in lua_code
    assert "ffi.cdef[[" in lua_code
    assert "int add(int a, int b);" in lua_code
    assert "double multiply(double x, double y);" in lua_code
    assert "local C = ffi.load('libmath.so')" in lua_code


def test_native_ffi_zlib(tmp_path):
    lua_code = """
local zlib = require("src/luthon/lua/native/zlib")
local v = zlib.version()
print("ZLIB_VERSION:" .. v)
local crc = zlib.crc32("hello")
print("CRC32:" .. tostring(crc))
assert(crc == 907060870)

local compressed = zlib.compress("Luthon transpiler native zlib test string")
local decompressed = zlib.decompress(compressed)
assert(decompressed == "Luthon transpiler native zlib test string")
print("ZLIB_OK")
"""
    lua_file = tmp_path / "test_zlib.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "ZLIB_VERSION:" in res.stdout
    assert "CRC32:907060870" in res.stdout
    assert "ZLIB_OK" in res.stdout


def test_native_ffi_sqlite3(tmp_path):
    lua_code = """
local sqlite3 = require("src/luthon/lua/native/sqlite3")
local conn = sqlite3.connect(":memory:")
conn:execute("CREATE TABLE users (id INTEGER, name TEXT, balance REAL);")
conn:execute("INSERT INTO users VALUES (1, 'Alice', 105.50);")
conn:execute("INSERT INTO users VALUES (2, 'Bob', 42.00);")

local cur = conn:execute("SELECT id, name, balance FROM users ORDER BY id;")
local rows = cur:fetchall()
assert(#rows == 2)
assert(rows[1][1] == 1 and rows[1][2] == "Alice" and rows[1][3] == 105.50)
assert(rows[2][1] == 2 and rows[2][2] == "Bob" and rows[2][3] == 42.00)
conn:close()
print("SQLITE3_OK")
"""
    lua_file = tmp_path / "test_sqlite3.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "SQLITE3_OK" in res.stdout


def test_native_crypto_hashlib(tmp_path):
    lua_code = """
require("src/luthon/lua/bootstrap")
local h = hashlib.sha256("hello")
print("SHA256:" .. h:hexdigest())
assert(h:hexdigest() == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

local m = hashlib.md5("hello")
print("MD5:" .. m:hexdigest())
assert(m:hexdigest() == "5d41402abc4b2a76b9719d911017c592")
print("HASHLIB_OK")
"""
    lua_file = tmp_path / "test_hashlib.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "SHA256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" in res.stdout
    assert "MD5:5d41402abc4b2a76b9719d911017c592" in res.stdout
    assert "HASHLIB_OK" in res.stdout


def test_lazy_cpython_bridge_and_proxy(tmp_path):
    lua_code = """
local pybridge = require("src/luthon/lua/pybridge")
assert(pybridge.is_available(), "libpython3 should be available")

-- Test importing standard math module via CPython bridge
local math_mod = pybridge.import("math")
local sqrt_val = math_mod.sqrt(289)
print("SQRT_VAL:" .. tostring(sqrt_val))
assert(sqrt_val == 17)
print("PI_VAL:" .. tostring(math_mod.pi))

-- Test json module marshaling Lua tables <-> Python dicts/lists
local json_mod = pybridge.import("json")
local payload = {
  title = "Luthon Bridge",
  numbers = {10, 20, 30},
  enabled = true
}
local serialized = json_mod.dumps(payload)
print("SERIALIZED:" .. serialized)
assert(string.find(serialized, "Luthon Bridge") ~= nil)

local deserialized = json_mod.loads(serialized)
assert(deserialized.title == "Luthon Bridge")
print("BRIDGE_OK")
"""
    lua_file = tmp_path / "test_bridge.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "SQRT_VAL:17" in res.stdout
    assert "BRIDGE_OK" in res.stdout


def test_opaque_pointer_passing(tmp_path):
    lua_code = """
local pybridge = require("src/luthon/lua/pybridge")
local io_mod = pybridge.import("io")

-- Create a StringIO object in Python and hold it as an opaque PyObject* proxy
local buf = io_mod.StringIO()
buf.write("Hello from LuaJIT!")
buf.write(" Opaque PyObject pointer passing works.")

local content = buf.getvalue()
print("BUFFER_CONTENT:" .. content)
assert(content == "Hello from LuaJIT! Opaque PyObject pointer passing works.")
buf.close()
print("OPAQUE_OK")
"""
    lua_file = tmp_path / "test_opaque.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "OPAQUE_OK" in res.stdout


def test_waterfall_fallback_module_loader(tmp_path):
    lua_code = """
local modules = require("src/luthon/lua/modules")

-- 1. Native FFI shim: zlib
local zlib = modules.load("zlib")
assert(zlib ~= nil and zlib.crc32 ~= nil)
assert(zlib.crc32("abc") == 891568578)

-- 2. Native FFI shim: sqlite3
local sqlite3 = modules.load("sqlite3")
assert(sqlite3 ~= nil and sqlite3.connect ~= nil)

-- 3. Lazy CPython fallback: decimal
local decimal = modules.load("decimal")
assert(decimal ~= nil)
local d = decimal.Decimal("123.456")
print("DECIMAL:" .. tostring(d))
assert(tostring(d) == "123.456")

print("WATERFALL_OK")
"""
    lua_file = tmp_path / "test_waterfall.lua"
    lua_file.write_text(lua_code)
    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0
    assert "DECIMAL:123.456" in res.stdout
    assert "WATERFALL_OK" in res.stdout
