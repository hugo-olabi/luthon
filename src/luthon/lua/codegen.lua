--[[
  Luthon IR -> Lua codegen
  ======================
  Converts Luthon IR (produced by src/luthon/lua/ir.lua) to Lua source code.
]]

local M = {}

------------------------------------------------------------------------------
-- Operator mappings (IR op -> Lua op string)
------------------------------------------------------------------------------

local _OP_MAP = {
  ["add"] = "+", ["sub"] = "-", ["mul"] = "*", ["div"] = "/",
  ["mod"] = "%", ["pow"] = "^",
  ["lt"] = "<", ["le"] = "<=", ["gt"] = ">", ["ge"] = ">=",
  ["eq"] = "==", ["ne"] = "~=",
  ["Lt"] = "<", ["LtE"] = "<=", ["Gt"] = ">", ["GtE"] = ">=",
  ["Eq"] = "==", ["NotEq"] = "~=",
}

local _CMP_MAP = {
  ["eq"] = "==", ["ne"] = "~=", ["lt"] = "<", ["le"] = "<=",
  ["gt"] = ">", ["ge"] = ">=",
  ["Lt"] = "<", ["LtE"] = "<=", ["Gt"] = ">", ["GtE"] = ">=",
  ["Eq"] = "==", ["Neq"] = "~=",
}

------------------------------------------------------------------------------
-- Code generator
------------------------------------------------------------------------------

local function _lua_op(op)
  return _OP_MAP[op:lower()] or op
end

local function _emit(ins)
  local o = ins.op
  local args = ins.args or {}

  if o == "CONST" then
    local v = args[1]
    if v == true then
      return ins.result .. " = true"
    end
    if v == false then
      return ins.result .. " = false"
    end
    if v == nil then
      return ins.result .. " = nil"
    end
    return ins.result .. " = " .. tostring(v)
  elseif o == "LOAD" then
    return ins.result .. " = " .. args[1]
  elseif o == "STORE" then
    return args[1] .. " = " .. args[2]
  elseif o == "BINOP" then
    local l = args[2] or "nil"
    local r = args[3] or "nil"
    local mapped = _lua_op(args[1])
    return ins.result .. " = " .. l .. " " .. mapped .. " " .. r
  elseif o == "UNOP" then
    if args[1] == "neg" then
      return ins.result .. " = -" .. args[2]
    end
    return ins.result .. " = " .. args[1]
  elseif o == "RETURN" then
    if args[1] then
      return "return " .. args[1]
    end
    return "return"
  elseif o == "JUMP" then
    return "goto " .. args[1]
  elseif o == "BRANCH" then
    return "if " .. args[1] .. " then goto " .. args[2] .. " else goto " .. args[3] .. " end"
  elseif o == "BRANCH_NONE" then
    return "if " .. args[1] .. " == nil then goto " .. args[2] .. " end"
  elseif o == "CMP" then
    local c = _CMP_MAP[args[1]] or args[1]
    return ins.result .. " = (" .. args[2] .. " " .. c .. " " .. args[3] .. ")"
  elseif o == "CALL" then
    local lua_args = {}
    for i = 2, #args do
      table.insert(lua_args, tostring(args[i]))
    end
    return ins.result .. " = " .. args[1] .. "(" .. table.concat(lua_args, ", ") .. ")"
  elseif o == "DO" then
    return "do"
  elseif o == "END" then
    return "end"
  elseif o == "CELL_GET" then
    return ins.result .. " = " .. args[1] .. ".value"
  elseif o == "CELL_SET" then
    return args[1] .. ".value = " .. args[2]
  elseif o == "MAKE_CELL" then
    return ins.result .. " = {value = " .. args[1] .. "}"
  elseif o == "MAKE_FUNCTION" then
    return ins.result .. " = " .. args[1]
  elseif o == "MAKE_LIST" then
    if #args > 0 then
      return ins.result .. " = {" .. table.concat(args, ", ") .. "}"
    end
    return ins.result .. " = {}"
  elseif o == "MAKE_TUPLE" then
    return ins.result .. " = {" .. table.concat(args, ", ") .. "}"
  elseif o == "MAKE_DICT" then
    return ins.result .. " = {}"
  elseif o == "LIST_APPEND" then
    return args[1] .. "[#" .. args[1] .. "+1] = " .. args[2]
  elseif o == "NEXT" then
    return ins.result .. " = " .. args[1] .. "()"
  elseif o == "SELECT" then
    return ins.result .. " = (" .. args[1] .. " and " .. args[2] .. " or " .. args[3] .. ")"
  elseif o == "NOP" then
    return "-- " .. ins.op
  else
    return "-- " .. (ins.op or "?")
  end
end

------------------------------------------------------------------------------
-- Module codegen
------------------------------------------------------------------------------

function M.generate(module)
  local out = {}

  -- Collect function names for upvalue propagation
  local fnames = {}
  for _, fn in ipairs(module.functions or {}) do
    table.insert(fnames, fn.name)
  end

  -- Propagate upvalue names into enclosing locals for Lua capture
  for _, fn in ipairs(module.functions or {}) do
    for _, child in ipairs(module.functions or {}) do
      if child ~= fn then
        for _, uv in ipairs(child.upvalues or {}) do
          local found = false
          for _, loc in ipairs(fn.locals or {}) do
            if loc == uv then found = true break end
          end
          if not found then
            table.insert(fn.locals, uv)
          end
        end
      end
    end
  end

  -- Hoist class tables for dotted method names
  local classes = {}
  for _, fn in ipairs(module.functions or {}) do
    local dot = fn.name:find("%.")
    if dot then
      local cls_name = fn.name:sub(1, dot - 1)
      classes[cls_name] = true
    end
  end
  for c in pairs(classes) do
    table.insert(out, c .. " = " .. c .. " or {}")
  end

  -- Emit functions
  for _, fn in ipairs(module.functions or {}) do
    local dot = fn.name:find("%.")
    if dot then
      local prefix = fn.name:sub(1, dot - 1)
      local meth = fn.name:sub(dot + 1)
      table.insert(out, prefix .. "." .. meth .. " = function(" .. table.concat(fn.params, ", ") .. ")")
    else
      table.insert(out, "local function " .. fn.name .. "(" .. table.concat(fn.params, ", ") .. ")")
    end

    -- Emit locals (excluding builtins and function names)
    local builtins = {
      "len","range","print","list","round","math","os","sys","json","random","re",
      "str","int","float","abs","min","max","sum","sorted","reversed","enumerate",
      "zip","map","filter","any","all","bool","datetime","collections","itertools",
      "functools","pathlib","string","base64","io","struct","hashlib","typing",
      "site","tempfile","open","dataclasses","subprocess"
    }
    local locs = {}
    for _, l in ipairs(fn.locals or {}) do
      local is_builtin = false
      for _, b in ipairs(builtins) do if b == l then is_builtin = true break end end
      local is_fn = false
      for _, f in ipairs(fnames) do if f == l then is_fn = true break end end
      local is_class = false
      for c in pairs(classes) do if c == l then is_class = true break end end
      if not is_builtin and not is_fn and not is_class then
        table.insert(locs, l)
      end
    end
    local tmps = {}
    for _, t in ipairs(fn.tmps or {}) do
      local found = false
      for _, l in ipairs(locs) do if l == t then found = true break end end
      if not found then table.insert(tmps, t) end
    end

    if #locs > 0 then
      table.insert(out, "  local " .. table.concat(locs, ", "))
    elseif #tmps > 0 and #locs + #tmps <= 150 then
      table.insert(out, "  local " .. table.concat(tmps, ", "))
    end

    -- Emit blocks
    for _, b in ipairs(fn.blocks or {}) do
      table.insert(out, "  ::" .. b.label .. "::")
      for _, ins in ipairs(b.instrs or {}) do
        table.insert(out, "  " .. _emit(ins))
      end
    end
    table.insert(out, "end")
  end

  -- Set up class metatables for __call (constructor emulation)
  for c in pairs(classes) do
    table.insert(out, "setmetatable(" .. c .. ", {__call = function(cls, ...) local self = {}; for k,v in pairs(cls) do self[k]=v end; cls.__init__(self, ...); return self end})")
  end

  return table.concat(out, "\n") .. "\n"
end

return M
