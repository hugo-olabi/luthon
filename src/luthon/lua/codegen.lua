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
  ["concat"] = "..",
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
  ["Is"] = "==", ["IsNot"] = "~=",
  ["is"] = "==", ["isnot"] = "~=",
  ["In"] = "_luthon_in", ["NotIn"] = "_luthon_not_in",
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
    if type(v) == "string" then
      -- If already quoted (starts and ends with matching quotes)
      if (v:sub(1,1) == '"' and v:sub(-1,-1) == '"') or (v:sub(1,1) == "'" and v:sub(-1,-1) == "'") then
        local unquoted = v:sub(2, -2)
        local escaped = unquoted:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return ins.result .. " = \"" .. escaped .. "\""
      end
      local escaped = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
      return ins.result .. " = \"" .. escaped .. "\""
    end
    return ins.result .. " = " .. tostring(v)
  elseif o == "LOAD" then
    return ins.result .. " = " .. args[1]
  elseif o == "STORE" then
    return args[1] .. " = " .. args[2]
  elseif o == "GET_ATTR" then
    return ins.result .. " = " .. args[1] .. "." .. args[2]
  elseif o == "SET_ATTR" then
    return args[1] .. "." .. args[2] .. " = " .. args[3]
  elseif o == "GET_ITEM" then
    return ins.result .. " = " .. args[1] .. "[" .. args[2] .. "]"
  elseif o == "SET_ITEM" then
    return args[1] .. "[" .. args[2] .. "] = " .. args[3]
  elseif o == "BINOP" then
    local l = args[2] or "nil"
    local r = args[3] or "nil"
    local op_name = (args[1] or ""):lower()
    if op_name == "floordiv" then
      return ins.result .. " = math.floor(" .. l .. " / " .. r .. ")"
    end
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
  elseif o == "BRANCH_TRUE" then
    return "if " .. args[1] .. " then goto " .. args[2] .. " end"
  elseif o == "BRANCH_FALSE" then
    return "if not " .. args[1] .. " then goto " .. args[2] .. " end"
  elseif o == "CMP" then
    local c = _CMP_MAP[args[1]] or args[1]
    if c == "_luthon_in" or c == "_luthon_not_in" then
      return ins.result .. " = " .. c .. "(" .. args[2] .. ", " .. args[3] .. ")"
    end
    return ins.result .. " = (" .. args[2] .. " " .. c .. " " .. args[3] .. ")"
  elseif o == "CALL" then
    local lua_args = {}
    for i = 2, #args do
      table.insert(lua_args, tostring(args[i]))
    end
    return ins.result .. " = " .. args[1] .. "(" .. table.concat(lua_args, ", ") .. ")"
  elseif o == "TRY_BEGIN" then
    return "local ok, err = pcall(function()"
  elseif o == "END_TRY" then
    return "end)\nif not ok then\n    local _exc = err\n    local _exc_matched = false"
  elseif o == "END_CATCH" then
    return "    _exc_matched = true"
  elseif o == "END_ALL_CATCH" then
    return "    if not _exc_matched then error(tostring(_exc)) end\nend"
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
    local lines = {ins.result .. " = {}"}
    for _, it in ipairs(args) do
      local k, v = it[1], it[2]
      if k then
        table.insert(lines, ins.result .. "[" .. k .. "] = " .. v)
      end
    end
    return table.concat(lines, "\n")
  elseif o == "MAKE_SET" then
    return ins.result .. " = {}"
  elseif o == "MAKE_TABLE" then
    return ins.result .. " = {}"
  elseif o == "STORE_SUBSCR" then
    return args[1] .. "[" .. args[2] .. "] = " .. args[3]
  elseif o == "SET_ADD" then
    return args[1] .. "[#" .. args[1] .. "+1] = " .. args[2]
  elseif o == "DICT_SET" then
    return args[1] .. "[" .. args[2] .. "] = " .. args[3]
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

function M.generate(module, skip_prelude)
  local out = {}
  if not skip_prelude then
    table.insert(out, M.prelude())
  end

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
    elseif fn.name == "main" and fn.is_entry_point then
      -- Module entry point: use a distinct name to avoid recursion with user-defined main()
      table.insert(out, "local function _luthon_module_entry(" .. table.concat(fn.params, ", ") .. ")")
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

  -- Runtime helpers for exceptions, asserts and context managers.
  if not skip_prelude then
    table.insert(out, "function _luthon_exc_match(exc, cls)")
    table.insert(out, "  if type(exc) ~= \"table\" then")
    table.insert(out, "    if cls == \"Exception\" or cls == \"BaseException\" or cls == Exception or cls == BaseException then return true end")
    table.insert(out, "    return false")
    table.insert(out, "  end")
    table.insert(out, "  local tname = type(cls) == \"string\" and cls or (cls.__name or cls.__type or tostring(cls))")
    table.insert(out, "  if tname == \"Exception\" or tname == \"BaseException\" then return true end")
    table.insert(out, "  return exc.__type == tname or exc.__name == tname")
    table.insert(out, "end")
    table.insert(out, "")
    table.insert(out, "function _luthon_assert_fail(test, msg)")
    table.insert(out, "  if not test then error({__type = \"AssertionError\", __msg = tostring(msg or \"\")}) end")
    table.insert(out, "  return true")
    table.insert(out, "end")
    table.insert(out, "")
    table.insert(out, "function _luthon_with_enter(ctx) return ctx.__enter__(ctx) end")
    table.insert(out, "function _luthon_with_exit(ctx) return ctx.__exit__(ctx, nil, nil, nil) end")
    table.insert(out, "")
    -- Exception classes that are both matchable by `except` and constructable via `raise X(...)`.
    for _, cls in ipairs({
      "Exception", "BaseException", "ValueError", "TypeError", "AssertionError",
      "NameError", "KeyError", "IndexError", "AttributeError", "RuntimeError",
      "StopIteration", "ZeroDivisionError", "FileNotFoundError", "IOError", "OSError"
    }) do
      table.insert(out, cls .. " = {__name = \"" .. cls .. "\", __type = \"" .. cls .. "\"}")
      table.insert(out, "setmetatable(" .. cls .. ", {__call = function(c, m) return {__name = c.__name, __type = c.__type, __msg = tostring(m or \"\")} end})")
    end
    table.insert(out, "")
  end

  -- Run module-level code
  table.insert(out, "_luthon_module_entry()")

  return table.concat(out, "\n") .. "\n"
end

------------------------------------------------------------------------------
-- Builtin prelude (shared by every generated module)
------------------------------------------------------------------------------

function M.prelude()
  local lines = {}
  table.insert(lines, "function range(a, b, step)")
  table.insert(lines, "  if b == nil then a, b = 0, a; step = 1 end")
  table.insert(lines, "  if step == nil then step = 1 end")
  table.insert(lines, "  local r = {}")
  table.insert(lines, "  if step > 0 then for i = a, b - 1, step do r[#r+1] = i end")
  table.insert(lines, "  else for i = a, b + 1, step do r[#r+1] = i end end")
  table.insert(lines, "  return r")
  table.insert(lines, "end")
  table.insert(lines, "function len(t) return #t end")
  table.insert(lines, "function list(t) local r = {} for i,v in ipairs(t or {}) do r[i]=v end return r end")
  table.insert(lines, "function sum(t) local s = 0 for _,v in ipairs(t or {}) do s = s + v end return s end")
  table.insert(lines, "function iter(t)")
  table.insert(lines, "  local i = 0")
  table.insert(lines, "  return function()")
  table.insert(lines, "    i = i + 1")
  table.insert(lines, "    if t[i] ~= nil then return t[i] end")
  table.insert(lines, "    return nil")
  table.insert(lines, "  end")
  table.insert(lines, "end")
  return table.concat(lines, "\n") .. "\n"
end

return M
