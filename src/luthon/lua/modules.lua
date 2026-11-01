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
  "/usr/local/lib/python3.13/dist-packages",
  "/usr/lib/python3/dist-packages",
  "/usr/lib/python3.13",
}

-- Add Luthon user site-packages (~/.luthon/site-packages)
local home = os.getenv("HOME")
if home then
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
