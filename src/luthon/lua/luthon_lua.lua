#!/usr/bin/env luajit
-- luthon_lua.lua — Luthon self-hosting driver
-- Reads a .py file, transpiles to Lua via the Lua pipeline, outputs .lua
--
-- Usage: luajit luthon_lua.lua input.py [output.lua]

local parser = require("src/luthon/lua/parser")
local semantic = require("src/luthon/lua/semantic")
local ir = require("src/luthon/lua/ir")
local codegen = require("src/luthon/lua/codegen")

local source_path = arg[1]
local output_path = arg[2]

if not source_path then
  io.stderr:write("Usage: luajit luthon_lua.lua input.py [output.lua]\n")
  os.exit(1)
end

-- Read Python source
local f = io.open(source_path, "r")
if not f then
  io.stderr:write("Cannot open file: " .. source_path .. "\n")
  os.exit(1)
end
local source = f:read("*a")
f:close()

-- Run the Lua pipeline: parse -> semantic -> IR -> codegen
local tree = parser.parse(source)
local scope = semantic.analyze(source)
local lowerer = ir.IRLowerer.new()
local module = lowerer:lower_module(tree, scope)
local lua = codegen.generate(module, true) -- skip prelude; bootstrap.lua provides it

-- Read bootstrap.lua and prepend it
local bootstrap_path = "src/luthon/lua/bootstrap.lua"
local bootstrap_f = io.open(bootstrap_path, "r")
if not bootstrap_f then
  io.stderr:write("Cannot open bootstrap: " .. bootstrap_path .. "\n")
  os.exit(1)
end
local bootstrap = bootstrap_f:read("*a")
bootstrap_f:close()

local output = bootstrap .. "\n" .. lua .. "\n"

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
