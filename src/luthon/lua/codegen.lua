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
  ["Is"] = "is", ["IsNot"] = "isnot",
  ["is"] = "is", ["isnot"] = "isnot",
  ["in"] = "_luthon_in", ["notin"] = "_luthon_not_in",
  ["In"] = "_luthon_in", ["NotIn"] = "_luthon_not_in",
}

------------------------------------------------------------------------------
-- Code generator
------------------------------------------------------------------------------

local function _lua_op(op)
  return _OP_MAP[op:lower()] or op
end

local function _escape_for_quotes(s, q)
  return (s:gsub("(\\*)(" .. q .. ")", function(slashes, quote)
    if #slashes % 2 == 0 then
      return slashes .. "\\" .. quote
    else
      return slashes .. quote
    end
  end))
end

local function _emit(ins)
  local o = ins.op
  local args = ins.args or {}

  if o == "CONST" then
    local v = args[1]
    local is_raw = args[2] == true
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
      if (v:sub(1,3) == '"""' and v:sub(-3,-1) == '"""') or (v:sub(1,3) == "'''" and v:sub(-3,-1) == "'''") then
        local q = v:sub(1, 1)
        local unquoted = v:sub(4, -4)
        if is_raw then
          unquoted = unquoted:gsub("\\", "\\\\")
        end
        unquoted = unquoted:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "\\r")
        local escaped = _escape_for_quotes(unquoted, q)
        return ins.result .. " = " .. q .. escaped .. q
      elseif (v:sub(1,1) == '"' and v:sub(-1,-1) == '"') or (v:sub(1,1) == "'" and v:sub(-1,-1) == "'") then
        local q = v:sub(1, 1)
        local unquoted = v:sub(2, -2)
        if is_raw then
          unquoted = unquoted:gsub("\\", "\\\\")
        end
        unquoted = unquoted:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "\\r")
        local escaped = _escape_for_quotes(unquoted, q)
        return ins.result .. " = " .. q .. escaped .. q
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
    local raw_op = args[1] or ""
    local op_name = raw_op:lower()
    if op_name == "floordiv" then
      return ins.result .. " = math.floor(" .. l .. " / " .. r .. ")"
    elseif op_name == "band" then
      return ins.result .. " = bit.band(" .. l .. ", " .. r .. ")"
    elseif op_name == "bor" then
      return ins.result .. " = bit.bor(" .. l .. ", " .. r .. ")"
    elseif op_name == "bxor" then
      return ins.result .. " = bit.bxor(" .. l .. ", " .. r .. ")"
    elseif op_name == "<<" or op_name == "lshift" then
      return ins.result .. " = bit.lshift(" .. l .. ", " .. r .. ")"
    elseif op_name == ">>" or op_name == "rshift" then
      return ins.result .. " = bit.rshift(" .. l .. ", " .. r .. ")"
    elseif op_name == "matmul" or op_name == "@" then
      return ins.result .. " = " .. l .. ":matmul(" .. r .. ")"
    elseif op_name == "add" or op_name == "+" then
      return ins.result .. " = _luthon_add(" .. l .. ", " .. r .. ")"
    end
    local mapped = _lua_op(raw_op)
    return ins.result .. " = " .. l .. " " .. mapped .. " " .. r
  elseif o == "UNOP" then
    local op = (args[1] or ""):lower()
    if op == "neg" or op == "usub" or op == "-" then
      return ins.result .. " = -" .. args[2]
    elseif op == "pos" or op == "uadd" or op == "+" then
      return ins.result .. " = +" .. args[2]
    elseif op == "not" then
      return ins.result .. " = not " .. args[2]
    elseif op == "inv" or op == "invert" or op == "~" then
      return ins.result .. " = bit.bnot(" .. args[2] .. ")"
    end
    return ins.result .. " = " .. (args[2] or args[1])
  elseif o == "RETURN" then
    if args[1] then
      return "do return " .. args[1] .. " end"
    end
    return "do return end"
  elseif o == "TRY_RETURN" then
    local ret_val = args[1] or "nil"
    return "_luthon_ret_val = " .. ret_val .. "; _luthon_has_ret = true; do return end"
  elseif o == "TRY_UNWIND" then
    local depth = (args and args[1]) and tonumber(args[1]) or 0
    if depth > 0 then
      return "if _luthon_has_ret then do return end end"
    end
    return "if _luthon_has_ret then local _r = _luthon_ret_val; _luthon_ret_val = nil; _luthon_has_ret = false; return _r end"
  elseif o == "JUMP" then
    return "goto " .. args[1]
  elseif o == "BRANCH" then
    return "if _luthon_truthy(" .. args[1] .. ") then goto " .. args[2] .. " else goto " .. args[3] .. " end"
  elseif o == "BRANCH_NONE" then
    return "if " .. args[1] .. " == nil or " .. args[1] .. " == _G.None then goto " .. args[2] .. " end"
  elseif o == "BRANCH_TRUE" then
    return "if _luthon_truthy(" .. args[1] .. ") then goto " .. args[2] .. " end"
  elseif o == "BRANCH_FALSE" then
    return "if not _luthon_truthy(" .. args[1] .. ") then goto " .. args[2] .. " end"
  elseif o == "CMP" then
    local c = _CMP_MAP[args[1]] or args[1]
    if c == "_luthon_in" or c == "_luthon_not_in" then
      return ins.result .. " = " .. c .. "(" .. args[2] .. ", " .. args[3] .. ")"
    end
    return ins.result .. " = _luthon_cmp('" .. c .. "', " .. args[2] .. ", " .. args[3] .. ")"
  elseif o == "CALL" then
    local lua_args = {}
    for i = 2, #args do
      table.insert(lua_args, tostring(args[i]))
    end
    if ins.result then
      return ins.result .. " = " .. args[1] .. "(" .. table.concat(lua_args, ", ") .. ")"
    end
    return args[1] .. "(" .. table.concat(lua_args, ", ") .. ")"
  elseif o == "TRY_BEGIN" or o == "WITH_BEGIN" then
    local scoped = {}
    for _, a in ipairs(args or {}) do table.insert(scoped, tostring(a)) end
    if #scoped > 0 then
      if #scoped > 180 then
        local capped = {}
        for i = 1, 180 do table.insert(capped, scoped[i]) end
        scoped = capped
      end
      return "do\nlocal ok, err = pcall(function()\n  local " .. table.concat(scoped, ", ")
    end
    return "do\nlocal ok, err = pcall(function()"
  elseif o == "WITH_END" then
    local mgr = args[1]
    return "end)\nif not ok then\n  local _suppressed = _luthon_with_exit(" .. mgr .. ", err)\n  if not _suppressed then error(err, 0) end\nelse\n  _luthon_with_exit(" .. mgr .. ", nil)\nend\nend"
  elseif o == "END_TRY" then
    return "end)\nif not ok then\n    local _exc = type(err) == \"string\" and (err:match(\"^.-:%d+: (.*)$\") or err) or err\n    local _exc_matched = false"
  elseif o == "CATCH_BEGIN" then
    if #args > 0 and args[1] and args[1] ~= "" then
      return "    if not _exc_matched and _luthon_exc_match(_exc, " .. args[1] .. ") then\n        _exc_matched = true"
    end
    return "    if not _exc_matched then\n        _exc_matched = true"
  elseif o == "END_CATCH" then
    return "    end"
  elseif o == "END_ALL_CATCH" then
    return "    if not _exc_matched then error(err, 0) end"
  elseif o == "TRY_ELSE" then
    return "else\n    if not _luthon_has_ret then"
  elseif o == "END_TRY_ELSE" then
    return "    end"
  elseif o == "TRY_CLOSE" then
    return "end\nend"
  elseif o == "FINALLY_BEGIN" then
    return "end)"
  elseif o == "FINALLY_END" then
    return "if not ok then error(err, 0) end\nend"
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
      return ins.result .. " = setmetatable({" .. table.concat(args, ", ") .. "}, _list_mt)"
    end
    return ins.result .. " = setmetatable({}, _list_mt)"
  elseif o == "MAKE_TUPLE" then
    if #args > 0 then
      return ins.result .. " = setmetatable({" .. table.concat(args, ", ") .. "}, _tuple_mt)"
    end
    return ins.result .. " = setmetatable({}, _tuple_mt)"
  elseif o == "MAKE_DICT" then
    local lines = {ins.result .. " = setmetatable({}, _dict_mt)"}
    for _, it in ipairs(args) do
      local k, v = it[1], it[2]
      if k then
        table.insert(lines, ins.result .. "[" .. k .. "] = " .. v)
      end
    end
    return table.concat(lines, "\n")
  elseif o == "IMPORT" then
    if #args > 2 and args[3] and args[3] ~= "" then
      return args[1] .. " = _luthon_import(\"" .. args[2] .. "\", \"" .. args[3] .. "\")"
    end
    return args[1] .. " = _luthon_import(\"" .. args[2] .. "\")"
  elseif o == "IMPORT_FROM" then
    return args[1] .. " = _luthon_import_from(\"" .. args[2] .. "\", \"" .. args[3] .. "\")"
  elseif o == "MAKE_CLASS" then
    return ins.result .. " = " .. args[1]
  elseif o == "MAKE_SET" then
    return ins.result .. " = {}"
  elseif o == "MAKE_TABLE" then
    return ins.result .. " = {}"
  elseif o == "SUBSCR" then
    return ins.result .. " = __luthon_get(" .. args[1] .. ", " .. args[2] .. ")"
  elseif o == "SUBSCR_DIRECT" then
    local t = args[1]
    local idx = args[2]
    return ins.result .. " = ((rawget(" .. t .. ", '_buf') or rawget(" .. t .. ", '_py')) and " .. t .. "[" .. idx .. "] or " .. t .. "[" .. idx .. " + 1])"
  elseif o == "STORE_SUBSCR" then
    return "__luthon_set(" .. args[1] .. ", " .. args[2] .. ", " .. args[3] .. ")"
  elseif o == "STORE_SUBSCR_DIRECT" then
    local t = args[1]
    local idx = args[2]
    local val = args[3]
    return "if rawget(" .. t .. ", '_buf') or rawget(" .. t .. ", '_py') then " .. t .. "[" .. idx .. "] = " .. val .. " else " .. t .. "[" .. idx .. " + 1] = " .. val .. " end"
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

function M.generate(module, skip_prelude, sourcemap)
  local out = {
    "local _bit_band, _bit_bor, _bit_bxor, _bit_lshift, _bit_rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift",
    "local _math_floor, _math_abs, _math_min, _math_max = math.floor, math.abs, math.min, math.max",
    "local _table_insert, _table_concat, _string_sub = table.insert, table.concat, string.sub",
  }
  if not skip_prelude then
    table.insert(out, 1, M.prelude())
  end

  -- Collect function names for upvalue propagation
  local fnames = {}
  for _, fn in ipairs(module.functions or {}) do
    table.insert(fnames, fn.name)
  end

  -- Hoist class tables
  local classes = {}
  for _, fn in ipairs(module.functions or {}) do
    local dot = fn.name:find("%.")
    if dot then
      local cls_name = fn.name:sub(1, dot - 1)
      classes[cls_name] = true
    end
    for _, b in ipairs(fn.blocks or {}) do
      for _, ins in ipairs(b.instrs or {}) do
        if ins.op == "MAKE_CLASS" and ins.args[1] then
          classes[ins.args[1]] = true
        end
      end
    end
  end
  for c in pairs(classes) do
    table.insert(out, c .. " = " .. c .. " or {}")
  end

  local builtins = {
    "len","range","print","list","round","math","os","sys","json","random","re",
    "str","int","float","abs","min","max","sum","sorted","reversed","enumerate","repr",
    "zip","map","filter","any","all","bool","datetime","collections","itertools",
    "functools","pathlib","string","base64","io","struct","hashlib","typing",
    "site","tempfile","open","dataclasses","subprocess","ast","bit","array","matrix","ffi","__name__","isinstance",
    "super","getattr","hasattr","setattr","delattr","iter","tuple","globals","locals",
    "dict","bytes","type","set","frozenset","_luthon_type","callable","issubclass","table",
    "Exception", "BaseException", "ValueError", "TypeError", "AssertionError",
    "NameError", "KeyError", "IndexError", "AttributeError", "RuntimeError",
    "StopIteration", "ZeroDivisionError", "FileNotFoundError", "IOError", "OSError",
    "True", "False", "None", "_luthon_add"
  }
  local builtins_set = {}
  for _, b in ipairs(builtins) do builtins_set[b] = true end

  local fn_map = {}
  for _, fn in ipairs(module.functions or {}) do
    fn_map[fn.name] = fn
  end

  -- Hoist module-level and cross-function locals that are captured as upvalues
  local all_upvalues = {}
  for _, fn in ipairs(module.functions or {}) do
    if not fn.is_nested then
      for _, uv in ipairs(fn.upvalues or {}) do
        all_upvalues[uv] = true
      end
    end
  end
  local hoisted_set = {}
  local hoisted = {}
  for uv in pairs(all_upvalues) do
    if not builtins_set[uv] and not classes[uv] then
      table.insert(hoisted, uv)
      hoisted_set[uv] = true
    end
  end
  table.sort(hoisted)
  if #hoisted > 0 then
    table.insert(out, "local " .. table.concat(hoisted, ", "))
  end

  local function emit_func_lines(fn, indent, is_anon, anon_res)
    if is_anon then
      table.insert(out, indent .. anon_res .. " = function(" .. table.concat(fn.params, ", ") .. ")")
    else
      local dot = fn.name:find("%.")
      if dot then
        local prefix = fn.name:sub(1, dot - 1)
        local meth = fn.name:sub(dot + 1)
        local kw = {["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,["until"]=true,["while"]=true}
        if kw[meth] then
          table.insert(out, indent .. prefix .. "[\"" .. meth .. "\"] = function(" .. table.concat(fn.params, ", ") .. ")")
        else
          table.insert(out, indent .. prefix .. "." .. meth .. " = function(" .. table.concat(fn.params, ", ") .. ")")
        end
      elseif fn.name == "main" and fn.is_entry_point then
        -- Module entry point: use a distinct name to avoid recursion with user-defined main()
        table.insert(out, indent .. "local function _luthon_module_entry(" .. table.concat(fn.params, ", ") .. ")")
      elseif fn.name == "main" then
        table.insert(out, indent .. "local function " .. fn.name .. "(" .. table.concat(fn.params, ", ") .. ")")
      else
        table.insert(out, indent .. "function " .. fn.name .. "(" .. table.concat(fn.params, ", ") .. ")")
      end
    end
    if fn.upvalues and #fn.upvalues > 0 then
      table.insert(out, indent .. "  -- upvalues: " .. table.concat(fn.upvalues, ", "))
    end

    -- Emit locals (excluding builtins and function names)
    local locs = {}
    if fn.name == "main" then
      locs = {}
    else
      for _, l in ipairs(fn.locals or {}) do
        local is_builtin = builtins_set[l] or false
        local is_fn = false
        for _, f in ipairs(fnames) do if f == l then is_fn = true break end end
        local is_class = classes[l] or false
        local is_uv = false
        for _, uv in ipairs(fn.upvalues or {}) do if uv == l then is_uv = true break end end
        local is_param = false
        for _, p in ipairs(fn.params or {}) do if p == l then is_param = true break end end
        if not is_builtin and not is_fn and not is_class and not is_uv and not hoisted_set[l] and not is_param then
          table.insert(locs, l)
        end
      end
    end
    -- Find tmps that belong exclusively to a try or with block using LCA
    local try_stack = {}
    local tmp_paths = {}
    local outside_tmps = {}

    for _, b in ipairs(fn.blocks or {}) do
      for _, ins in ipairs(b.instrs or {}) do
        if ins.op == "TRY_BEGIN" or ins.op == "WITH_BEGIN" then
          table.insert(try_stack, ins)
        elseif ins.op == "END_TRY" or ins.op == "FINALLY_BEGIN" or ins.op == "WITH_END" then
          if #try_stack > 0 then table.remove(try_stack) end
        else
          local ins_tmps = {}
          if ins.result and (ins.result:sub(1, 2) == "_t" or ins.result:sub(1, 2) == "_r") then
            ins_tmps[ins.result] = true
          end
          if ins.op == "STORE" and type(ins.args[1]) == "string" and (ins.args[1]:sub(1, 2) == "_t" or ins.args[1]:sub(1, 2) == "_r") then
            ins_tmps[ins.args[1]] = true
          end
          for _, a in ipairs(ins.args or {}) do
            if type(a) == "string" and (a:sub(1, 2) == "_t" or a:sub(1, 2) == "_r") then
              ins_tmps[a] = true
            end
          end
          if #try_stack == 0 then
            for t in pairs(ins_tmps) do outside_tmps[t] = true end
          else
            local path = {}
            for i = 1, #try_stack do path[i] = try_stack[i] end
            for t in pairs(ins_tmps) do
              tmp_paths[t] = tmp_paths[t] or {}
              table.insert(tmp_paths[t], path)
            end
          end
        end
      end
    end

    local block_locals = {}
    for t, paths in pairs(tmp_paths) do
      if not outside_tmps[t] then
        local lca = paths[1]
        for pi = 2, #paths do
          local p = paths[pi]
          local new_lca = {}
          local min_len = math.min(#lca, #p)
          for k = 1, min_len do
            if lca[k] == p[k] then
              table.insert(new_lca, lca[k])
            else
              break
            end
          end
          lca = new_lca
          if #lca == 0 then break end
        end
        if #lca > 0 then
          local target_ins = lca[#lca]
          block_locals[target_ins] = block_locals[target_ins] or {}
          table.insert(block_locals[target_ins], t)
        else
          outside_tmps[t] = true
        end
      end
    end

    local try_exclusive_all = {}
    for _, b in ipairs(fn.blocks or {}) do
      for _, ins in ipairs(b.instrs or {}) do
        if ins.op == "TRY_BEGIN" or ins.op == "WITH_BEGIN" then
          local tmps_for_ins = block_locals[ins] or {}
          table.sort(tmps_for_ins)
          if #tmps_for_ins > 180 then
            local capped = {}
            for i = 1, 180 do table.insert(capped, tmps_for_ins[i]) end
            tmps_for_ins = capped
          end
          ins.args = tmps_for_ins
          for _, t in ipairs(tmps_for_ins) do try_exclusive_all[t] = true end
        end
      end
    end

    local tmps = {}
    for _, t in ipairs(fn.tmps or {}) do
      local found = false
      for _, l in ipairs(locs) do if l == t then found = true break end end
      for _, p in ipairs(fn.params or {}) do if p == t then found = true break end end
      if try_exclusive_all[t] then found = true end
      if not found then table.insert(tmps, t) end
    end

    local allvars = {}
    for _, l in ipairs(locs) do table.insert(allvars, l) end
    for _, t in ipairs(tmps) do table.insert(allvars, t) end
    if #allvars > 0 then
      local max_declared = math.min(#allvars, 180)
      for chunk_start = 1, max_declared, 80 do
        local chunk = {}
        for i = chunk_start, math.min(chunk_start + 79, max_declared) do
          table.insert(chunk, allvars[i])
        end
        table.insert(out, indent .. "  local " .. table.concat(chunk, ", "))
      end
    end

    -- Emit blocks
    for _, b in ipairs(fn.blocks or {}) do
      table.insert(out, indent .. "  ::" .. b.label .. "::")
      for _, ins in ipairs(b.instrs or {}) do
        if ins.op == "MAKE_FUNCTION" and ins.args and fn_map[ins.args[1]] and fn_map[ins.args[1]].is_nested then
          local child_fn = fn_map[ins.args[1]]
          emit_func_lines(child_fn, indent .. "  ", true, ins.result)
        else
          if sourcemap and ins.lineno and ins.lineno > 0 then
            local src_file = sourcemap.file or (sourcemap.sources and sourcemap.sources[1] or "")
            sourcemap:add(#out + 1, #indent + 2, ins.lineno, ins.col_offset or 0, src_file)
          end
          table.insert(out, indent .. "  " .. _emit(ins))
        end
      end
    end
    table.insert(out, indent .. "end")
  end

  -- Emit functions
  for _, fn in ipairs(module.functions or {}) do
    if not fn.is_nested then
      emit_func_lines(fn, "", false, nil)
    end
  end

  -- Set up class metatables for __call (constructor emulation)
  for c in pairs(classes) do
    table.insert(out, c .. ".__index = " .. c)
    table.insert(out, c .. ".__name__ = '" .. c .. "'")
    table.insert(out, c .. ".__name = '" .. c .. "'")
    local mt_setup = c .. ".__instance_mt = {__index = function(inst, k) " ..
      "if k == '__class__' then return rawget(inst, '__class__') end; " ..
      "local ga = rawget(inst, '__getattribute__') or (rawget(inst, '__class__') and inst.__class__.__getattribute__); " ..
      "if type(ga) == 'function' then return ga(inst, k) end; " ..
      "local v = rawget(inst, k); if v ~= nil then return v end; " ..
      "local cv = " .. c .. "[k]; " ..
      "if type(cv) == 'table' and type(cv.__get__) == 'function' then return cv:__get__(inst, " .. c .. ") end; " ..
      "if type(cv) == 'function' then " ..
      "return (_G._luthon_bind_method and _G._luthon_bind_method(cv, inst)) or function(...) if select(1, ...) == inst then return cv(...) else return cv(inst, ...) end end end; " ..
      "if cv ~= nil then return cv end; " ..
      "local py = rawget(inst, '_py'); if py ~= nil then local ok, res = pcall(function() return py[k] end); if ok and res ~= nil then return res end end; " ..
      "local g = rawget(inst, '__getattr__') or (rawget(inst, '__class__') and inst.__class__.__getattr__); " ..
      "if type(g) == 'function' then return g(inst, k) end; " ..
      "return nil end, " ..
      "__newindex = function(inst, k, v) " ..
      "local sa = rawget(inst, '__setattr__') or (rawget(inst, '__class__') and inst.__class__.__setattr__); " ..
      "if type(sa) == 'function' then sa(inst, k, v) else rawset(inst, k, v) end; " ..
      "local py = rawget(inst, '_py'); if py ~= nil then pcall(function() py[k] = v end) end end, " ..
      "__tostring = function(inst) " ..
      "local s = inst.__str__; if type(s) == 'function' then return s(inst) end; " ..
      "local r = inst.__repr__; if type(r) == 'function' then return r(inst) end; " ..
      "local cls = rawget(inst, '__class__'); " ..
      "local name = cls and (cls.__name__ or rawget(cls, '__name__')) or '" .. c .. "'; " ..
      "return '<' .. tostring(name) .. ' object>' end, " ..
      "__eq = function(a, b) " ..
      "local eq = type(a) == 'table' and a.__eq__; " ..
      "if type(eq) == 'function' then return eq(a, b) end; " ..
      "return rawequal(a, b) end}"
    table.insert(out, mt_setup)
    local call_body = "local self; if (rawget(" .. c .. ", '__new__') and not (type(" .. c .. ".__new__) == 'table' and rawget(" .. c .. ".__new__, '_py'))) or (" .. c .. ".__new__ and not (type(" .. c .. ".__new__) == 'table' and rawget(" .. c .. ".__new__, '_py')) and " .. c .. ".__new__ ~= (rawget(_G, 'object') and _G.object.__new__)) then self = " .. c .. ".__new__(" .. c .. ", ...) else self = setmetatable({__class__ = " .. c .. "}, " .. c .. ".__instance_mt) end; if type(self) == 'table' and " .. c .. ".__init__ then " .. c .. ".__init__(self, ...) end; return self"
    local cls_mt = "{__index = function(t, k) local b = rawget(t, '__base__'); return b and b[k] end, __call = function(cls, ...) " .. call_body .. " end}"
    table.insert(out, "setmetatable(" .. c .. ", " .. cls_mt .. ")")
  end

  -- Runtime helpers for exceptions, asserts and context managers.
  if not skip_prelude then
    table.insert(out, "function _luthon_exc_match(exc, cls)")
    table.insert(out, "  if cls == nil then return false end")
    table.insert(out, "  if type(cls) == \"table\" and (rawget(cls, \"__is_tuple\") or (cls[1] and rawget(cls, \"__class__\") == nil)) then")
    table.insert(out, "    for i = 1, #cls do if _luthon_exc_match(exc, cls[i]) then return true end end")
    table.insert(out, "    return false")
    table.insert(out, "  end")
    table.insert(out, "  local tname = type(cls) == \"string\" and cls or (cls.__name or cls.__name__ or cls.__type or tostring(cls))")
    table.insert(out, "  if tname == \"Exception\" or tname == \"BaseException\" or cls == Exception or cls == BaseException then return true end")
    table.insert(out, "  if type(exc) ~= \"table\" then")
    table.insert(out, "    local str_exc = tostring(exc)")
    table.insert(out, "    if str_exc:find(tname, 1, true) then return true end")
    table.insert(out, "    if (tname == \"ImportError\" or cls == ImportError) and str_exc:find(\"ModuleNotFoundError\", 1, true) then return true end")
    table.insert(out, "    if (tname == \"OSError\" or cls == OSError) and (str_exc:find(\"IOError\", 1, true) or str_exc:find(\"FileNotFoundError\", 1, true)) then return true end")
    table.insert(out, "    return false")
    table.insert(out, "  end")
    table.insert(out, "  if exc.__type == tname or exc.__name == tname or exc.__name__ == tname then return true end")
    table.insert(out, "  local exc_cls = exc.__class__ or exc")
    table.insert(out, "  if type(cls) == \"table\" and issubclass and issubclass(exc_cls, cls) then return true end")
    table.insert(out, "  local curr = exc_cls")
    table.insert(out, "  while type(curr) == \"table\" do")
    table.insert(out, "    if curr == cls or curr.__name == tname or curr.__type == tname or curr.__name__ == tname then return true end")
    table.insert(out, "    curr = rawget(curr, \"__base__\")")
    table.insert(out, "  end")
    table.insert(out, "  return false")
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
  table.insert(out, "local _entry_ok, _entry_err = xpcall(_luthon_module_entry, debug.traceback)")
  table.insert(out, "if not _entry_ok then")
  table.insert(out, "  if type(_entry_err) == 'table' and (_entry_err.__type == 'SystemExit' or (_entry_err.__class__ and _entry_err.__class__.__name__ == 'SystemExit')) then")
  table.insert(out, "    local _code = _entry_err.code or (_entry_err.args and _entry_err.args[1]) or 0")
  table.insert(out, "    if type(_code) == 'string' then io.stderr:write(_code .. '\\n'); os.exit(1) else os.exit(tonumber(_code) or 0) end")
  table.insert(out, "  elseif tostring(_entry_err):find('SystemExit:%s*0') or tostring(_entry_err):find('SystemExit:%s*nil') then")
  table.insert(out, "    os.exit(0)")
  table.insert(out, "  elseif tostring(_entry_err):find('SystemExit:%s*(%d+)') then")
  table.insert(out, "    local _c = tonumber(tostring(_entry_err):match('SystemExit:%s*(%d+)'))")
  table.insert(out, "    os.exit(_c or 0)")
  table.insert(out, "  else")
  table.insert(out, "    error(_entry_err, 0)")
  table.insert(out, "  end")
  table.insert(out, "end")

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
