--[[
  Luthon Module System (pure Lua) with Waterfall Fallback Loader
  =============================================================
  Waterfall import resolution:
    1. Builtin / sys.modules cache
    2. Pure Lua module (.lua files in search paths)
    3. Pure Python source (.py files in site-packages / search paths, transpiled on the fly)
    4. Native FFI shim (e.g. zlib, sqlite3 in src/luthon/lua/native/)
    5. Lazy on-demand CPython bridge (libpython3 via pybridge.lua)
--]]

local M = {}

------------------------------------------------------------------------------
-- sys.modules cache
------------------------------------------------------------------------------

local sys_modules = _G._luthon_sys_modules or {}
M.sys_modules = sys_modules
_G._luthon_sys_modules = sys_modules
_G._luthon_modules = M

local loading = {}

------------------------------------------------------------------------------
-- Search paths
------------------------------------------------------------------------------

local search_paths = {
  ".",
  "./lua",
  "./src/luthon/lua",
  "./src/luthon/vendor",
  "./vendor",
  "./src/luthon/lua/native",
  "./.luthon_env/lib/luthon/site-packages",
  "/usr/lib64/python3.15/site-packages",
  "/usr/lib/python3.15/site-packages",
  "/usr/lib64/python3.14/site-packages",
  "/usr/lib/python3.14/site-packages",
  "/usr/lib64/python3.14",
  "/usr/local/lib64/python3.15/site-packages",
  "/usr/local/lib/python3.15/site-packages",
  "/usr/local/lib64/python3.14/site-packages",
  "/usr/local/lib/python3.14/site-packages",
  "/usr/local/lib/python3.13/dist-packages",
  "/usr/lib/python3/dist-packages",
  "/usr/lib/python3.13",
}

-- Add user site-packages (~/.local/lib/python3.15/site-packages and ~/.luthon/site-packages)
local home = os.getenv("HOME")
if home then
  table.insert(search_paths, home .. "/.local/lib/python3.15/site-packages")
  table.insert(search_paths, home .. "/.local/lib/python3.14/site-packages")
  table.insert(search_paths, home .. "/.local/lib/python3.13/site-packages")
  table.insert(search_paths, home .. "/.luthon/site-packages")
end

-- Add active virtual environment if set
local venv = os.getenv("VIRTUAL_ENV") or os.getenv("LUTHON_ENV")
if venv then
  table.insert(search_paths, 1, venv .. "/lib/luthon/site-packages")
  for _, py_ver in ipairs({"3.16", "3.15", "3.14", "3.13", "3.12", "3.11", "3.10", "3.9"}) do
    table.insert(search_paths, 1, venv .. "/lib/python" .. py_ver .. "/site-packages")
  end
end
for _, py_ver in ipairs({"3.16", "3.15", "3.14", "3.13", "3.12", "3.11", "3.10", "3.9"}) do
  table.insert(search_paths, "./.venv/lib/python" .. py_ver .. "/site-packages")
  table.insert(search_paths, "/usr/lib64/python" .. py_ver .. "/lib-dynload")
  table.insert(search_paths, "/usr/lib/python" .. py_ver .. "/lib-dynload")
end

-- Add PYTHONPATH if set
local pythonpath = os.getenv("PYTHONPATH")
if pythonpath then
  for p in pythonpath:gmatch("([^:]+)") do
    table.insert(search_paths, p)
    table.insert(search_paths, p .. "/luthon/lua/native")
    table.insert(search_paths, p .. "/luthon/lua")
  end
end

-- Add paths from package.path (excluding host system Lua library roots to avoid colliding with Python stdlib names like 're')
if package and package.path then
  for p in package.path:gmatch("([^;]+)") do
    local base = p:match("^(.-)/%?[^/]*$")
    if base and base ~= "" and base ~= "." and not base:match("^/usr/share/lua") and not base:match("^/usr/lib.*/lua") and not base:match("^/usr/local/share/lua") then
      table.insert(search_paths, base)
    end
  end
end

function M.add_search_path(path)
  table.insert(search_paths, path)
end

function M.get_search_paths()
  local all = {}
  local seen = {}
  if _G.sys and _G.sys.path and type(_G.sys.path) == "table" then
    for _, p in ipairs(_G.sys.path) do
      if type(p) == "string" and not seen[p] then
        table.insert(all, p)
        seen[p] = true
      end
    end
  end
  for _, p in ipairs(search_paths) do
    if type(p) == "string" and not seen[p] then
      table.insert(all, p)
      seen[p] = true
    end
  end
  return all
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 1 & 2 - Lua Modules
------------------------------------------------------------------------------

function M.is_pure_mode()
  return os.getenv("LUTHON_PURE") == "1" or _G.__LUTHON_PURE__ == true
end

function M.find_lua_module(name)
  local pure = M.is_pure_mode()
  local parts = {}
  for part in name:gmatch("([^%.]+)") do
    table.insert(parts, part)
  end

  local alt_parts = nil
  if parts[1] == "luthon" and #parts > 1 then
    alt_parts = {}
    for i = 2, #parts do table.insert(alt_parts, parts[i]) end
  end

  local function try_find(part_list)
    for _, base in ipairs(M.get_search_paths()) do
      if pure and (base:match("/native$") or base:match("/native/")) then
        -- Skip native shim directories in pure mode
      else
        -- Package directory with __init__.lua
        local pkg_dir = base .. "/" .. table.concat(part_list, "/")
        local init_path = pkg_dir .. "/__init__.lua"
        local f = io.open(init_path, "r")
        if f then f:close(); return init_path end

        -- Module file: module.lua
        local cand = base .. "/" .. table.concat(part_list, "/") .. ".lua"
        local f2 = io.open(cand, "r")
        if f2 then f2:close(); return cand end
      end
    end
    return nil
  end

  local res = try_find(parts)
  if res then return res end
  if alt_parts then return try_find(alt_parts) end
  return nil
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 3 - Pure Python Source (.py)
------------------------------------------------------------------------------

local _CPYTHON_FRAMEWORKS = {
  ["gi"] = true,
  ["twisted"] = true,
  ["zope"] = true,
  ["pkg_resources"] = true,
  ["setuptools"] = true,
  ["_distutils_hack"] = true,
  ["pytest"] = true,
  ["_pytest"] = true,
  ["dbus"] = true,
  ["cairo"] = true,
  ["cryptography"] = true,
}

function M.find_py_module(name)
  local parts = {}
  for part in name:gmatch("([^%.]+)") do
    table.insert(parts, part)
  end

  local top_mod = parts[1]
  if _CPYTHON_FRAMEWORKS[top_mod] then
    return nil
  end

  local function try_find(part_list)
    for _, base in ipairs(M.get_search_paths()) do
      -- Allow site-packages for pure-Python packages, but skip CPython stdlib roots
      local is_stdlib_root = (base:match("^/usr/lib/python%d") or base:match("^/usr/lib64/python%d")) and not base:find("/site%-packages") and not base:find("/dist%-packages")
      if not is_stdlib_root then
        -- Package directory with __init__.py
        local pkg_dir = base .. "/" .. table.concat(part_list, "/")
        local init_path = pkg_dir .. "/__init__.py"
        local f = io.open(init_path, "r")
        if f then f:close(); return init_path end

        -- Module file: module.py
        local cand = base .. "/" .. table.concat(part_list, "/") .. ".py"
        local f2 = io.open(cand, "r")
        if f2 then f2:close(); return cand end
      end
    end
    return nil
  end

  return try_find(parts)
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 4 - Native FFI Shims
------------------------------------------------------------------------------

local native_shims = {
  zlib = "src/luthon/lua/native/zlib",
  sqlite3 = "src/luthon/lua/native/sqlite3",
  numpy = "src/luthon/lua/native/numpy",
  ["PIL.Image"] = "src/luthon/lua/native/PIL/Image",
  ["PIL.ImageOps"] = "src/luthon/lua/native/PIL/ImageOps",
  ["PIL"] = "src/luthon/lua/native/PIL/init",
  requests = "src/luthon/lua/native/requests",
  websockets = "src/luthon/lua/native/websockets",
  pytest = "src/luthon/lua/native/pytest",
  pytest_twisted = "src/luthon/lua/native/pytest_twisted",
}

function M.find_native_shim(name)
  if M.is_pure_mode() then return nil end
  local rel = native_shims[name]
  if not rel then return nil end

  local home = os.getenv("HOME") or ""
  local cand_bases = {
    ".",
    "src/luthon/lua",
    home .. "/Projects/luthon",
    home .. "/Projects/luthon/.claude/worktrees/native-shims",
  }

  -- Try direct require first
  local ok, mod = pcall(require, rel)
  if ok and mod then return mod end

  for _, base in ipairs(cand_bases) do
    local fpath = base .. "/" .. rel .. ".lua"
    local f = io.open(fpath, "r")
    if f then
      f:close()
      local chunk = loadfile(fpath)
      if chunk then
        local ok2, res = pcall(chunk)
        if ok2 and res then return res end
      end
    end
  end

  return nil
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 4.5 - Binary C-Extension Reflection (Zero CPython)
------------------------------------------------------------------------------

function M.find_binary_module(name)
  local parts = {}
  for part in name:gmatch("([^%.]+)") do
    table.insert(parts, part)
  end

  local mod_stem = parts[#parts]
  local rel_dir = #parts > 1 and table.concat(parts, "/", 1, #parts - 1) or ""

  local suffixes = {
    ".abi3.so",
    ".so",
    ".cpython-315-x86_64-linux-gnu.so",
    ".cpython-316-x86_64-linux-gnu.so",
    ".cpython-314-x86_64-linux-gnu.so",
    ".cpython-313-x86_64-linux-gnu.so",
    ".cpython-312-x86_64-linux-gnu.so",
    ".cpython-311-x86_64-linux-gnu.so",
    ".pyd",
    ".dylib",
  }

  for _, base in ipairs(M.get_search_paths()) do
    local base_dir = rel_dir ~= "" and (base .. "/" .. rel_dir) or base
    for _, sfx in ipairs(suffixes) do
      local cand = base_dir .. "/" .. mod_stem .. sfx
      local f = io.open(cand, "r")
      if f then
        f:close()
        return cand
      end
    end
  end
  return nil
end

function M.load_binary_extension(name, path)
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi or not ffi then return nil end

  local capi_path = "src/luthon/native/libluthon_capi.so"
  local cand_paths = {
    os.getenv("LUTHON_CAPI_LIB") or "",
    _G.__LUTHON_CAPI_LIB__ or "",
    "src/luthon/native/libluthon_capi.so",
    "../luthon/src/luthon/native/libluthon_capi.so",
    (os.getenv("HOME") or "") .. "/Projects/luthon/src/luthon/native/libluthon_capi.so",
    "./libluthon_capi.so",
    "libluthon_capi.so",
  }
  for _, cp in ipairs(cand_paths) do
    if cp ~= "" then
      local f = io.open(cp, "r")
      if f then f:close(); capi_path = cp; break end
    end
  end

  local pb = _G._luthon_pybridge
  local has_cpython = pb and pb.get_lib and (pb.get_lib() ~= nil)
  local ok_capi, capi = nil, nil
  if not has_cpython then
    ok_capi, capi = pcall(ffi.load, capi_path, true)
  end
  if not ok_capi or not capi then
    ok_capi, capi = pcall(ffi.load, capi_path)
    if not ok_capi or not capi then return nil end
  end

  pcall(function()
    ffi.cdef[[
      typedef struct _object PyObject;
      typedef long Py_ssize_t;

      int luthon_capi_can_load_extension(const char *so_path, const char *init_symbol);
      PyObject* luthon_capi_init_module(void *init_fn_ptr, const char *name);
      PyObject* luthon_capi_call_cfunction(void *meth_ptr, int ml_flags, PyObject *self, PyObject *args, PyObject *kwargs);

      typedef struct PyMethodDef {
          const char  *ml_name;
          void        *ml_meth;
          int          ml_flags;
          const char  *ml_doc;
      } PyMethodDef;

      PyMethodDef* luthon_capi_get_module_methods(PyObject *mod);
      PyObject* PyModule_GetDict(PyObject *mod);
      Py_ssize_t PyDict_Size(PyObject *mp);
      int PyDict_Next(PyObject *mp, Py_ssize_t *pos, PyObject **key, PyObject **value);
      const char* PyUnicode_AsUTF8(PyObject *unicode);
      const char* PyUnicode_AsUTF8AndSize(PyObject *unicode, Py_ssize_t *size);
      PyObject* PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size);
      PyObject* PyLong_FromLongLong(long long v);
      long long PyLong_AsLongLong(PyObject *obj);
      PyObject* PyFloat_FromDouble(double v);
      double PyFloat_AsDouble(PyObject *obj);
      PyObject* PyTuple_New(Py_ssize_t len);
      int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);
      void Py_IncRef(PyObject *o);
      void Py_DecRef(PyObject *o);
      PyObject* PyErr_Occurred(void);
      void PyErr_Clear(void);
    ]]
  end)

  local parts = {}
  for p in name:gmatch("([^%.]+)") do table.insert(parts, p) end
  local short_name = parts[#parts]
  local init_fn_name = "PyInit_" .. short_name

  -- Preflight validation: inspect ELF undefined symbols
  local can_load = 0
  pcall(function()
    can_load = capi.luthon_capi_can_load_extension(path, init_fn_name)
  end)
  if can_load ~= 1 then
    return nil
  end

  local ok_ext, ext = pcall(ffi.load, path)
  if not ok_ext or not ext then return nil end

  pcall(function()
    ffi.cdef(string.format("void* %s(void);", init_fn_name))
  end)

  local has_init, init_fn = pcall(function() return ext[init_fn_name] end)
  if not has_init or not init_fn then return nil end

  local ok_init, mod_ptr = pcall(function()
    return capi.luthon_capi_init_module(ffi.cast("void*", init_fn), name)
  end)
  if not ok_init or mod_ptr == nil then return nil end

  local mod_table = {
    __name__ = name,
    __file__ = path,
    _capi_mod = mod_ptr,
  }

  local function _py_to_lua(py_obj)
    if py_obj == nil then return nil end
    local i = capi.PyLong_AsLongLong(py_obj)
    local f = capi.PyFloat_AsDouble(py_obj)
    if f ~= 0.0 and i == 0 then return tonumber(f) end
    if i ~= 0 then return tonumber(i) end
    local sz = ffi.new("Py_ssize_t[1]")
    local s = capi.PyUnicode_AsUTF8AndSize(py_obj, sz)
    if s ~= nil and sz[0] > 0 then return ffi.string(s, sz[0]) end
    return py_obj
  end

  local function _lua_to_py(val)
    if val == nil then return nil end
    local t = type(val)
    if t == "number" then
      if math.floor(val) == val then
        return capi.PyLong_FromLongLong(val)
      else
        return capi.PyFloat_FromDouble(val)
      end
    elseif t == "string" then
      return capi.PyUnicode_FromStringAndSize(val, #val)
    end
    return nil
  end

  -- Export methods via luthon_capi_call_cfunction
  local methods = capi.luthon_capi_get_module_methods(mod_ptr)
  if methods ~= nil then
    local idx = 0
    while methods[idx].ml_name ~= nil do
      local m = methods[idx]
      local fn_name = ffi.string(m.ml_name)
      local meth_ptr = m.ml_meth
      local ml_flags = m.ml_flags

      mod_table[fn_name] = function(...)
        local total = select("#", ...)
        local args_tuple = capi.PyTuple_New(total)
        for i = 1, total do
          local py_val = _lua_to_py(select(i, ...))
          capi.PyTuple_SetItem(args_tuple, i - 1, py_val)
        end
        local res = capi.luthon_capi_call_cfunction(meth_ptr, ml_flags, nil, args_tuple, nil)
        capi.Py_DecRef(args_tuple)
        if res == nil then
          if capi.PyErr_Occurred() ~= nil then
            capi.PyErr_Clear()
            error(name .. "." .. fn_name .. "() execution failed in C extension", 2)
          end
        end
        local ret = _py_to_lua(res)
        capi.Py_DecRef(res)
        return ret
      end

      idx = idx + 1
    end
  end

  -- Export dictionary constants and values
  local mod_dict = capi.PyModule_GetDict(mod_ptr)
  if mod_dict ~= nil then
    local pos = ffi.new("Py_ssize_t[1]", 0)
    local pkey = ffi.new("PyObject*[1]")
    local pval = ffi.new("PyObject*[1]")
    while capi.PyDict_Next(mod_dict, pos, pkey, pval) == 1 do
      local k_str = ffi.string(capi.PyUnicode_AsUTF8(pkey[0]))
      if not mod_table[k_str] then
        local lua_val = _py_to_lua(pval[0])
        if lua_val ~= nil then
          mod_table[k_str] = lua_val
        end
      end
    end
  end

  return mod_table
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 5 - Lazy CPython Bridge
------------------------------------------------------------------------------

local pybridge_module = nil
function M.load_via_cpython(name)
  if not pybridge_module then
    local ok, pb = pcall(require, "luthon.lua.pybridge")
    if not ok or not pb then
      ok, pb = pcall(require, "src/luthon/lua/pybridge")
    end
    if not ok or not pb then
      ok, pb = pcall(require, "pybridge")
    end
    if ok and pb and pb.is_available() then
      pybridge_module = pb
    end
  end
  if pybridge_module then
    local ok, mod = pcall(pybridge_module.import, name)
    if ok and mod then
      return mod
    end
  end
  return nil
end

------------------------------------------------------------------------------
-- Module execution
------------------------------------------------------------------------------

function M.load_module_file(name, path)
  local source = nil
  local f = io.open(path, "r")
  if f then
    source = f:read("*a")
    f:close()
  end
  if not source then
    error("module not found: " .. name .. " (" .. path .. ")", 2)
  end

  local ns = {
    __name__ = name,
    __file__ = path,
  }
  setmetatable(ns, {__index = _G})

  loading[name] = true

  local ok, err = pcall(function()
    local chunk, compile_err = load(source, path, "t", ns)
    if not chunk then
      error("compile error in " .. name .. ": " .. tostring(compile_err), 2)
    end
    local result = chunk()
    if type(result) == "table" then
      for k, v in pairs(result) do
        ns[k] = v
      end
      local mt = getmetatable(result)
      if mt then
        setmetatable(ns, {
          __index = function(t, k)
            if _G[k] ~= nil then return _G[k] end
            if mt.__index then
              if type(mt.__index) == "function" then
                local v = mt.__index(result, k)
                if v ~= nil then return v end
              elseif type(mt.__index) == "table" then
                local v = mt.__index[k]
                if v ~= nil then return v end
              end
            end
            return nil
          end
        })
      end
    end
  end)

  if not ok then
    loading[name] = nil
    if path and (path:find("/site%-packages") or path:find("/dist%-packages")) and not M.is_pure_mode() then
      local cpy = M.load_via_cpython(name)
      if cpy then
        sys_modules[name] = cpy
        return cpy
      end
    end
    error("module load error: " .. tostring(err), 2)
  end

  sys_modules[name] = ns
  loading[name] = nil

  return ns
end

------------------------------------------------------------------------------
-- Public load API (Waterfall Waterfall)
------------------------------------------------------------------------------

local transpile_cache = {}
local _cache_dir_created = false

local function get_file_stat(path)
  local ok_ffi, ffi = pcall(require, "ffi")
  if ok_ffi and ffi and ffi.C and ffi.C.stat then
    local sbuf = _G._LUTHON_STAT_BUF
    if not sbuf then
      pcall(function() sbuf = ffi.new("stat_t") end)
    end
    if sbuf then
      local rc = ffi.C.stat(path, sbuf)
      if rc == 0 then
        local mtime = tonumber(sbuf.st_mtime) + tonumber(sbuf.st_mtime_nsec) / 1e9
        local size = tonumber(sbuf.st_size)
        return mtime, size
      end
    end
  end
  return nil, nil
end

local function get_module_cache_info(py_path)
  if os.getenv("LUTHON_NO_CACHE") == "1" then return nil end
  local base_cache = os.getenv("LUTHON_CACHE_DIR")
  if not base_cache or base_cache == "" then
    base_cache = ".luthon_cache"
  end
  local mod_cache_dir = base_cache .. "/modules"

  local h1, h2 = 5381, 52711
  for i = 1, #py_path do
    local b = string.byte(py_path, i)
    h1 = (h1 * 33 + b) % 4294967291
    h2 = (h2 * 37 + b) % 4294967291
  end
  local hash_str = string.format("%08x%08x", h1, h2)
  local cache_path = mod_cache_dir .. "/" .. hash_str .. ".lua"
  return cache_path, mod_cache_dir
end

function M.find_module(name)
  return M.find_lua_module(name)
end

function M.load(name)
  -- 1. Already loaded in cache
  if sys_modules[name] then
    return sys_modules[name]
  end

  if loading[name] then
    return sys_modules[name] or nil
  end

  if _MODULES and _MODULES[name] then
    sys_modules[name] = _MODULES[name]
    return _MODULES[name]
  end

  if name == "os.path" and _G.os and _G.os.path then
    sys_modules[name] = _G.os.path
    return _G.os.path
  end

  -- 2. Pure Lua module
  local lua_path = M.find_lua_module(name)
  if lua_path then
    return M.load_module_file(name, lua_path)
  end

  -- 3. Native FFI shim (zlib, sqlite3)
  local shim = M.find_native_shim(name)
  if shim then
    sys_modules[name] = shim
    return shim
  end

  -- 4. Pure Python source file (transpile on the fly if parser available)
  local py_path = M.find_py_module(name)
  if py_path then
    local driver = nil
    for _, mod_candidate in ipairs({"src/luthon/lua/luthon_lua", "luthon.lua.luthon_lua", "luthon_lua"}) do
      local ok_driver, d = pcall(require, mod_candidate)
      if ok_driver and d and d.transpile_file then
        driver = d
        break
      end
    end
    if driver and driver.transpile_file then
      local pkg = py_path:match("__init__%.py$") and name or (name:match("^(.*)%.[^%.]+$") or "")
      local lua_out = transpile_cache[py_path]
      if not lua_out then
        local cache_path, mod_cache_dir = get_module_cache_info(py_path)
        local src_mtime, src_size = get_file_stat(py_path)
        if cache_path and src_mtime and src_size then
          local f = io.open(cache_path, "r")
          if f then
            local header = f:read("*l")
            if header then
              local c_mtime, c_size = header:match("^%-%- LUTHON_MODULE_CACHE:mtime=([%d%.]+):size=(%d+)")
              if c_size and tonumber(c_size) == src_size and c_mtime and math.abs(tonumber(c_mtime) - src_mtime) < 0.001 then
                lua_out = f:read("*a")
              end
            end
            f:close()
          end
        end

        if not lua_out then
          local ok_transpile, out = pcall(driver.transpile_file, py_path, pkg, true)
          if ok_transpile and out then
            lua_out = out
            transpile_cache[py_path] = out
            if cache_path and src_mtime and src_size then
              if not _cache_dir_created then
                pcall(function() os.execute("mkdir -p '" .. mod_cache_dir .. "' 2>/dev/null") end)
                _cache_dir_created = true
              end
              local f_out = io.open(cache_path, "w")
              if f_out then
                f_out:write(string.format("-- LUTHON_MODULE_CACHE:mtime=%.6f:size=%d\n", src_mtime, src_size))
                f_out:write(out)
                f_out:close()
              end
            end
          end
        else
          transpile_cache[py_path] = lua_out
        end
      end
      if lua_out then
        local ns = { __name__ = name, __package__ = pkg, __file__ = py_path }
        setmetatable(ns, {__index = _G})
        sys_modules[name] = ns
        local chunk, chunk_err = load(lua_out, "@" .. name, "t", ns)
        if chunk then
          loading[name] = true
          local ok, res = xpcall(chunk, debug.traceback)
          loading[name] = nil
          if ok then
            if type(res) == "table" then
              for k, v in pairs(res) do ns[k] = v end
            end
            return ns
          else
            sys_modules[name] = nil
            if py_path:find("/site%-packages") or py_path:find("/dist%-packages") then
              local py_mod = M.load_via_cpython(name)
              if py_mod then
                sys_modules[name] = py_mod
                return py_mod
              end
            end
            error("Error executing transpiled module '" .. name .. "' (" .. tostring(py_path) .. "): " .. tostring(res), 2)
          end
        else
          sys_modules[name] = nil
          if py_path:find("/site%-packages") or py_path:find("/dist%-packages") then
            local py_mod = M.load_via_cpython(name)
            if py_mod then
              sys_modules[name] = py_mod
              return py_mod
            end
          end
          error("Syntax error in transpiled module '" .. name .. "': " .. tostring(chunk_err), 2)
        end
      end
    end
  end

  -- 4.5. Binary C-extension via reflection & capi_proxy (Zero CPython Fallback)
  local bin_path = M.find_binary_module(name)
  if bin_path then
    loading[name] = true
    local mod = M.load_binary_extension(name, bin_path)
    loading[name] = nil
    if mod then
      sys_modules[name] = mod
      return mod
    end
  end

  -- 5. Lazy on-demand CPython bridge
  local py_mod = M.load_via_cpython(name)
  if py_mod then
    sys_modules[name] = py_mod
    return py_mod
  end

  error("module not found: " .. name, 2)
end

------------------------------------------------------------------------------
-- Import statement helpers
------------------------------------------------------------------------------

function M.resolve_name(name, current_module)
  if name:sub(1, 1) == "." then
    local dots = 0
    local i = 1
    while i <= #name and name:sub(i, i) == "." do
      dots = dots + 1
      i = i + 1
    end

    local parts = {}
    if current_module and current_module ~= "__main__" then
      for part in current_module:gmatch("([^%.]+)") do
        table.insert(parts, part)
      end
    end

    local levels_up = dots - 1
    if levels_up > #parts then
      error("attempted relative import beyond top-level package", 2)
    end

    for _ = 1, levels_up do
      table.remove(parts)
    end

    local remainder = name:sub(i)
    if remainder and #remainder > 0 then
      for part in remainder:gmatch("([^%.]+)") do
        table.insert(parts, part)
      end
    end

    return table.concat(parts, ".")
  end

  return name
end

function M.import(name, current_module)
  local resolved = M.resolve_name(name, current_module)
  return M.load(resolved)
end

return M
