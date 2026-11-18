#!/usr/bin/env luajit
-- luthon_lua.lua — Luthon self-hosting driver
-- Reads a .py file, transpiles to Lua via the Lua pipeline, outputs .lua
--
-- Usage: luajit luthon_lua.lua input.py [output.lua]

local _src_info = debug.getinfo(1, "S")
local _src_path = _src_info and _src_info.source and _src_info.source:match("^@?(.*)$") or ""
local _script_dir = _src_path:match("^(.*)/[^/]+$") or "src/luthon/lua"

local function _require_lua_mod(name)
  for _, candidate in ipairs({"src/luthon/lua/" .. name, "luthon.lua." .. name, name}) do
    local ok, mod = pcall(require, candidate)
    if ok and mod then
      return mod
    end
  end
  local f, err = loadfile(_script_dir .. "/" .. name .. ".lua")
  if f then
    return f()
  end
  error("luthon_lua: failed to load module '" .. name .. "': " .. tostring(err))
end

local parser = _require_lua_mod("parser")
local semantic = _require_lua_mod("semantic")
local ir = _require_lua_mod("ir")
local codegen = _require_lua_mod("codegen")

local M = {}

function M.transpile_file(source_path, package, omit_bootstrap)
  local f = io.open(source_path, "r")
  if not f then return nil end
  local source = f:read("*a")
  f:close()

  local tree = parser.parse(source)
  local scope = semantic.analyze(tree)
  local lowerer = ir.IRLowerer.new(package)
  local module = lowerer:lower_module(tree, scope)
  if omit_bootstrap then
    local lua = codegen.generate(module, true)
    return lua .. "\n"
  end

  local lua = codegen.generate(module, true)
  local bootstrap_f = io.open(_script_dir .. "/bootstrap.lua", "r") or io.open("src/luthon/lua/bootstrap.lua", "r")
  local bootstrap = ""
  if bootstrap_f then
    bootstrap = bootstrap_f:read("*a")
    bootstrap_f:close()
  end

  return bootstrap .. "\n" .. lua .. "\n"
end

-- If executed directly as CLI script:
if arg and arg[0] and (arg[0]:match("luthon_lua%.lua$") or arg[0] == "src/luthon/lua/luthon_lua.lua") then
  local source_path = arg[1]
  local output_path = arg[2]

  if not source_path then
    io.stderr:write("Usage: luajit luthon_lua.lua input.py [output.lua]\n")
    os.exit(1)
  end

  local output = M.transpile_file(source_path)
  if not output then
    io.stderr:write("Cannot read file: " .. source_path .. "\n")
    os.exit(1)
  end

  -- Write output
  if output_path then
    local out = io.open(output_path, "w")
    if not out then
      io.stderr:write("Cannot write to: " .. output_path .. "\n")
      os.exit(1)
    end
    out:write(output)
    out:close()
  else
    io.write(output)
  end
end

return M
