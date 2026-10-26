#!/usr/bin/env luajit
-- luthon_lua.lua — Luthon self-hosting driver
-- Reads a .py file, transpiles to Lua via the Lua pipeline, outputs .lua
--
-- Usage: luajit luthon_lua.lua input.py [output.lua]

local parser = require("src/luthon/lua/parser")
local semantic = require("src/luthon/lua/semantic")
local ir = require("src/luthon/lua/ir")
local codegen = require("src/luthon/lua/codegen")

local M = {}

function M.transpile_file(source_path)
  local f = io.open(source_path, "r")
  if not f then return nil end
  local source = f:read("*a")
  f:close()

  local tree = parser.parse(source)
  local scope = semantic.analyze(source)
  local lowerer = ir.IRLowerer.new()
  local module = lowerer:lower_module(tree, scope)
  local lua = codegen.generate(module, true)

  local bootstrap_path = "src/luthon/lua/bootstrap.lua"
  local bootstrap_f = io.open(bootstrap_path, "r")
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
