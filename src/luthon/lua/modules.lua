--[[
  Luthon Module System (pure Lua)
  =================================
  Module system for Luthon's Lua runtime. Provides sys.modules cache,
  module resolution, package __init__.lua execution, and circular import
  handling.

  Mirrors the Python ModuleLoader in src/luthon/modules.py but adapted
  for Lua's module system and Luthon's transpiled Lua output.
--]]

local M = {}

------------------------------------------------------------------------------
-- sys.modules cache
------------------------------------------------------------------------------

-- sys.modules is the Lua equivalent of Python's sys.modules: a registry of
-- all loaded modules keyed by module name. Each entry is the module's
-- namespace table (its global environment).
local sys_modules = {}

-- _MODULES is exposed as sys.modules in the Lua runtime
M.sys_modules = sys_modules

-- Loading state for circular import detection. A module currently being
-- loaded is marked as true; once fully loaded, replaced with the module table.
local loading = {}

------------------------------------------------------------------------------
-- Module search paths
------------------------------------------------------------------------------

-- Default search paths: current directory first, then common Lua package paths
local search_paths = {".", "./lua", "./src/luthon/lua"}

-- Allow callers to add search paths
function M.add_search_path(path)
  table.insert(search_paths, path)
end

function M.get_search_paths()
  return search_paths
end

------------------------------------------------------------------------------
-- Module resolution
------------------------------------------------------------------------------

-- Resolve a module name to a file path.
-- name: dotted module name like "foo.bar.baz"
-- Returns the file path if found, or nil if not found.
function M.find_module(name)
  local parts = {}
  for part in name:gmatch("([^%.]+)") do
    table.insert(parts, part)
  end

  for _, base in ipairs(search_paths) do
    -- Try package directory with __init__.lua
    local pkg_dir = base .. "/" .. table.concat(parts, "/")
    local init_path = pkg_dir .. "/__init__.lua"
    local f = io.open(init_path, "r")
    if f then
      f:close()
      return init_path
    end

    -- Try module file: module.py -> module.lua
    local cand = base .. "/" .. table.concat(parts, "/") .. ".lua"
    local f2 = io.open(cand, "r")
    if f2 then
      f2:close()
      return cand
    end
  end

  return nil
end

------------------------------------------------------------------------------
-- Module execution
------------------------------------------------------------------------------

-- Load and execute a module from a file path.
-- Returns the module's namespace table.
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

  -- Create a fresh namespace table for the module
  local ns = {
    __name__ = name,
    __file__ = path,
  }

  -- Mark as loading to handle circular imports
  loading[name] = true

local ok, err = pcall(function()
    -- Compile and execute the Lua source in the module's namespace
    local chunk, compile_err = load(source, path, "t", ns)
    if not chunk then
      error("compile error in " .. name .. ": " .. tostring(compile_err), 2)
    end
    local result = chunk()
    -- If the chunk returned a table, merge it into our namespace
    if type(result) == "table" then
      for k, v in pairs(result) do
        ns[k] = v
      end
    end
    -- print("DEBUG: chunk returned type=" .. type(result))
  end)

  if not ok then
    loading[name] = nil
    error("module load error: " .. tostring(err), 2)
  end

  -- Mark as fully loaded
  sys_modules[name] = ns
  loading[name] = nil

  return ns
end

------------------------------------------------------------------------------
-- Public load API
------------------------------------------------------------------------------

-- Load a module by name, returning its namespace table.
-- Handles circular imports by returning the partial module if already loading.
function M.load(name)
  -- Already loaded
  if sys_modules[name] then
    return sys_modules[name]
  end

  -- Currently loading (circular import): return partial module if exists
  if loading[name] then
    return sys_modules[name] or nil
  end

  -- Find the module file
  local path = M.find_module(name)
  if not path then
    error("module not found: " .. name, 2)
  end

  -- Load and execute
  return M.load_module_file(name, path)
end

------------------------------------------------------------------------------
-- Import statement helpers
------------------------------------------------------------------------------

-- Resolve an import name, handling relative imports.
-- name: the import name as written in source
-- current_module: the __name__ of the importing module
-- Returns the resolved absolute module name
function M.resolve_name(name, current_module)
  -- Relative import: starts with '.'
  if name:sub(1, 1) == "." then
    -- Count leading dots
    local dots = 0
    local i = 1
    while i <= #name and name:sub(i, i) == "." do
      dots = dots + 1
      i = i + 1
    end

    -- Get the parent package path
    local parts = {}
    if current_module and current_module ~= "__main__" then
      for part in current_module:gmatch("([^%.]+)") do
        table.insert(parts, part)
      end
    end

    -- Go up (dots - 1) levels
    local levels_up = dots - 1
    if levels_up > #parts then
      error("attempted relative import beyond top-level package", 2)
    end

    for i = 1, levels_up do
      table.remove(parts)
    end

    -- Append the remaining name (without leading dots)
    local remainder = name:sub(i)
    if remainder and #remainder > 0 then
      for part in remainder:gmatch("([^%.]+)") do
        table.insert(parts, part)
      end
    end

    return table.concat(parts, ".")
  end

  -- Absolute import: return as-is
  return name
end

-- Import a module by name, with optional resolution context
function M.import(name, current_module)
  local resolved = M.resolve_name(name, current_module)
  return M.load(resolved)
end

return M
