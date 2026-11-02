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

local sys_modules = {}
M.sys_modules = sys_modules

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
  "/usr/lib64/python3.14/site-packages",
  "/usr/lib/python3.14/site-packages",
  "/usr/lib64/python3.14",
  "/usr/local/lib64/python3.14/site-packages",
  "/usr/local/lib/python3.14/site-packages",
  "/usr/local/lib/python3.13/dist-packages",
  "/usr/lib/python3/dist-packages",
  "/usr/lib/python3.13",
}

-- Add user site-packages (~/.local/lib/python3.14/site-packages and ~/.luthon/site-packages)
local home = os.getenv("HOME")
if home then
  table.insert(search_paths, home .. "/.local/lib/python3.14/site-packages")
  table.insert(search_paths, home .. "/.local/lib/python3.13/site-packages")
  table.insert(search_paths, home .. "/.luthon/site-packages")
end

-- Add active virtual environment if set
local luthon_env = os.getenv("LUTHON_ENV")
if luthon_env then
  table.insert(search_paths, 1, luthon_env .. "/lib/luthon/site-packages")
end

-- Add PYTHONPATH if set
local pythonpath = os.getenv("PYTHONPATH")
if pythonpath then
  for p in pythonpath:gmatch("([^:]+)") do
    table.insert(search_paths, p)
  end
end

function M.add_search_path(path)
  table.insert(search_paths, path)
end

function M.get_search_paths()
  return search_paths
end

------------------------------------------------------------------------------
-- Waterfall Resolution: Tier 1 & 2 - Lua Modules
------------------------------------------------------------------------------

function M.find_lua_module(name)
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
    for _, base in ipairs(search_paths) do
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

function M.find_py_module(name)
  local parts = {}
  for part in name:gmatch("([^%.]+)") do
    table.insert(parts, part)
  end

  local function try_find(part_list)
    for _, base in ipairs(search_paths) do
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
}

function M.find_native_shim(name)
  local path = native_shims[name]
  if path then
    local ok, mod = pcall(require, path)
    if ok and mod then return mod end
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
    ".so",
    ".cpython-313-x86_64-linux-gnu.so",
    ".cpython-314-x86_64-linux-gnu.so",
    ".cpython-312-x86_64-linux-gnu.so",
    ".cpython-311-x86_64-linux-gnu.so",
    ".pyd",
    ".dylib",
  }

  for _, base in ipairs(search_paths) do
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

local _capi_loaded = false
function M.load_binary_extension(name, path)
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi or not ffi then return nil end

  local capi_path = "src/luthon/native/libluthon_capi.so"
  local home = os.getenv("HOME") or ""
  local cand_paths = {
    "src/luthon/native/libluthon_capi.so",
    "../luthon/src/luthon/native/libluthon_capi.so",
    os.getenv("LUTHON_CAPI_LIB") or "",
    home .. "/Projects/luthon/src/luthon/native/libluthon_capi.so"
  }
  for _, cp in ipairs(cand_paths) do
    if cp ~= "" then
      local f = io.open(cp, "r")
      if f then f:close(); capi_path = cp; break end
    end
  end

  -- Ensure C-API proxy symbols are globally exposed
  if not _capi_loaded then
    pcall(function()
      ffi.cdef[[
        void* dlopen(const char* filename, int flags);
        typedef struct _object PyObject;
        typedef long Py_ssize_t;
        PyObject* PyLong_FromLongLong(long long v);
        long long PyLong_AsLongLong(PyObject *obj);
        PyObject* PyFloat_FromDouble(double v);
        double PyFloat_AsDouble(PyObject *obj);
        PyObject* PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size);
        const char* PyUnicode_AsUTF8AndSize(PyObject *unicode, Py_ssize_t *size);
        PyObject* PyTuple_New(Py_ssize_t len);
        int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);
        PyObject* PyTuple_GetItem(PyObject *p, Py_ssize_t pos);
        Py_ssize_t PyTuple_Size(PyObject *p);
        void Py_IncRef(PyObject *o);
        void Py_DecRef(PyObject *o);
        PyObject* PyErr_Occurred(void);
        void PyErr_Clear(void);

        typedef struct PyMethodDef {
            const char  *ml_name;
            void        *ml_meth;
            int          ml_flags;
            const char  *ml_doc;
        } PyMethodDef;

        typedef struct PyModuleDef {
            int          m_base;
            const char  *m_name;
            const char  *m_doc;
            long         m_size;
            PyMethodDef *m_methods;
        } PyModuleDef;

        typedef struct _py_mod_obj {
            long ob_refcnt;
            void *ob_type;
            int tag;
            int _pad;
            PyModuleDef *module_def;
        } _PyModObj;
      ]]
      ffi.C.dlopen(capi_path, 258)
    end)
    _capi_loaded = true
  end

  local ok_capi, capi = pcall(ffi.load, capi_path)
  if not ok_capi or not capi then return nil end

  local ok_ext, ext = pcall(ffi.load, path)
  if not ok_ext or not ext then return nil end

  -- Determine entry point: PyInit_<name>
  local parts = {}
  for p in name:gmatch("([^%.]+)") do table.insert(parts, p) end
  local short_name = parts[#parts]

  local init_fn_name = "PyInit_" .. short_name
  pcall(function()
    ffi.cdef(string.format("PyObject* %s(void);", init_fn_name))
  end)

  local has_init, init_fn = pcall(function() return ext[init_fn_name] end)
  if not has_init or not init_fn then return nil end

  local ok_run, mod_ptr = pcall(init_fn)
  if not ok_run or mod_ptr == nil then return nil end

  local typed_mod = ffi.cast("_PyModObj*", mod_ptr)
  local mod_def = typed_mod.module_def
  if mod_def == nil or mod_def.m_methods == nil then return nil end

  local mod_table = {
    __name__ = name,
    __file__ = path,
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

  local idx = 0
  while mod_def.m_methods[idx].ml_name ~= nil do
    local m = mod_def.m_methods[idx]
    local fn_name = ffi.string(m.ml_name)
    local fn_ptr = ffi.cast("PyObject* (*)(PyObject*, PyObject*)", m.ml_meth)

    mod_table[fn_name] = function(...)
      local total = select("#", ...)
      local args_tuple = capi.PyTuple_New(total)
      for i = 1, total do
        local py_val = _lua_to_py(select(i, ...))
        capi.PyTuple_SetItem(args_tuple, i - 1, py_val)
      end
      local res = fn_ptr(nil, args_tuple)
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
    end
  end)

  if not ok then
    loading[name] = nil
    error("module load error: " .. tostring(err), 2)
  end

  sys_modules[name] = ns
  loading[name] = nil

  return ns
end

------------------------------------------------------------------------------
-- Public load API (Waterfall Waterfall)
------------------------------------------------------------------------------

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
    local ok_driver, driver = pcall(require, "src/luthon/lua/luthon_lua")
    if ok_driver and driver and driver.transpile_file then
      local ok_transpile, lua_out = pcall(driver.transpile_file, py_path)
      if ok_transpile and lua_out then
        local ns = { __name__ = name, __file__ = py_path }
        setmetatable(ns, {__index = _G})
        local chunk = load(lua_out, py_path, "t", ns)
        if chunk then
          loading[name] = true
          local ok, res = pcall(chunk)
          loading[name] = nil
          if ok then
            if type(res) == "table" then
              for k, v in pairs(res) do ns[k] = v end
            end
            sys_modules[name] = ns
            return ns
          end
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
