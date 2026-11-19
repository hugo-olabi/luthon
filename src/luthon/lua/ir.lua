--[[
  Luthon IR (instruction-level lowering) in Lua
  ===============================================
  Lowers a Python AST (produced by src/luthon/lua/parser.lua) to an IR
  of basic blocks with instructions. Conditionals/loops become branch
  + label blocks.
]]

local M = {}

------------------------------------------------------------------------------
-- IR data model
------------------------------------------------------------------------------

local Instr = {}
Instr.__index = Instr
function Instr.new(op, args, result, src_line, src_col)
  local self = setmetatable({}, Instr)
  self.op = op
  self.args = args or {}
  self.result = result
  self.src_line = src_line or 0
  self.lineno = self.src_line
  self.src_col = src_col or 0
  self.col_offset = self.src_col
  return self
end

local Block = {}
Block.__index = Block
function Block.new(label)
  local self = setmetatable({}, Block)
  self.label = label
  self.instrs = {}
  return self
end

local Function = {}
Function.__index = Function
function Function.new(name, params)
  local self = setmetatable({}, Function)
  self.name = name
  self.params = params or {}
  self.blocks = {}
  self.locals = {}
  self.tmps = {}
  self.freevars = {}
  self.cellvars = {}
  self.upvalues = {}
  self.is_entry_point = false
  return self
end

local Module = {}
Module.__index = Module
function Module.new(name)
  local self = setmetatable({}, Module)
  self.name = name
  self.functions = {}
  self.globals = {}
  self.instrs = {}
  self.blocks = {}
  return self
end

local LUA_RESERVED_KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local function _safe_var(name)
  if type(name) == "string" and LUA_RESERVED_KEYWORDS[name] then
    return "_py_" .. name
  end
  return name
end

local function _has_yield(n, is_root, seen)
  if not n or type(n) ~= "table" then return false end
  seen = seen or {}
  if seen[n] then return false end
  seen[n] = true

  if n._type == "Yield" or n._type == "YieldFrom" then return true end
  if not is_root and (n._type == "FunctionDef" or n._type == "AsyncFunctionDef") then
    return false
  end
  for k, v in pairs(n) do
    if k ~= "_scope" and k ~= "parent" and type(v) == "table" then
      if _has_yield(v, false, seen) then return true end
    end
  end
  return false
end

------------------------------------------------------------------------------
-- Operator mappings (Python AST op -> Lua IR op string)
------------------------------------------------------------------------------

local BINOP_MAP = {
  ["+"] = "add", ["-"] = "sub", ["*"] = "mul", ["/"] = "div",
  ["%"] = "mod", ["**"] = "pow", ["//"] = "floordiv",
  ["<"] = "lt", ["<="] = "le", [">"] = "gt", [">="] = "ge",
  ["=="] = "eq", ["!="] = "ne",
  -- Parser emits capitalized AST operator type names; accept those too.
  ["Add"] = "add", ["Sub"] = "sub", ["Mult"] = "mul", ["Div"] = "div",
  ["FloorDiv"] = "floordiv", ["Mod"] = "mod", ["Pow"] = "pow",
  ["LShift"] = "<<", ["RShift"] = ">>",
  ["BitAnd"] = "band", ["BitOr"] = "bor", ["BitXor"] = "bxor", ["MatMult"] = "matmul",
  ["LShiftE"] = "LShift", ["RShiftE"] = "RShift",
}

local BUILTIN_MODULES = {
  ["math"] = true, ["os"] = true, ["sys"] = true, ["json"] = true,
  ["random"] = true, ["re"] = true, ["string"] = true, ["hashlib"] = true,
  ["base64"] = true, ["struct"] = true, ["io"] = true, ["collections"] = true,
  ["itertools"] = true, ["functools"] = true, ["pathlib"] = true,
  ["datetime"] = true, ["typing"] = true, ["site"] = true,
  ["tempfile"] = true, ["subprocess"] = true, ["ast"] = true, ["bit"] = true, ["ffi"] = true,
  ["types"] = true, ["socket"] = true, ["asyncio"] = true, ["http"] = true, ["urllib"] = true,
}

local UNARY_OP_MAP = {
  ["USub"] = "neg", ["UAdd"] = "pos", ["Not"] = "not", ["Invert"] = "inv",
}

local CMPOP_MAP = {
  ["=="] = "eq", ["!="] = "ne", ["<"] = "lt", ["<="] = "le",
  [">"] = "gt", [">="] = "ge",
  ["Eq"] = "eq", ["NotEq"] = "ne", ["Lt"] = "lt", ["LtE"] = "le",
  ["Gt"] = "gt", ["GtE"] = "ge",
  ["Is"] = "is", ["IsNot"] = "isnot", ["In"] = "in", ["NotIn"] = "notin",
}

local CMPOP_MAP = {
  ["Eq"] = "eq", ["NotEq"] = "ne", ["Lt"] = "lt", ["LtE"] = "le",
  ["Gt"] = "gt", ["GtE"] = "ge", ["Is"] = "eq", ["IsNot"] = "ne",
}

------------------------------------------------------------------------------
-- IRLowerer
------------------------------------------------------------------------------

local IRLowerer = {}
IRLowerer.__index = IRLowerer

function IRLowerer.new(package)
  local self = setmetatable({}, IRLowerer)
  self._tmp = 0
  self.package = package or ""
  self._imported_modules = {}
  self.module = Module.new("<module>")
  self._cur_fn = nil
  self._cur_block = nil
  self._label_counter = 0
  self._break_stack = {}
  self._continue_stack = {}
  self._try_depth = 0
  self._fn_counter = {}
  return self
end

function IRLowerer:_new_tmp()
  self._tmp = self._tmp + 1
  local t = "_t" .. self._tmp
  if self._cur_fn then
    table.insert(self._cur_fn.tmps, t)
  end
  return t
end

function IRLowerer:_new_label(prefix)
  prefix = prefix or "L"
  self._label_counter = self._label_counter + 1
  return prefix .. self._label_counter
end

function IRLowerer:_emit(op, args, result, src_line, src_col)
  local line = src_line or (self._cur_node and self._cur_node.lineno) or 0
  local col = src_col or (self._cur_node and self._cur_node.col_offset) or 0
  local ins = Instr.new(op, args or {}, result, line, col)
  table.insert(self._cur_block.instrs, ins)
  return ins
end

function IRLowerer:_new_block(label)
  local b = Block.new(label)
  table.insert(self._cur_fn.blocks, b)
  return b
end

------------------------------------------------------------------------------
-- Module lowering
------------------------------------------------------------------------------

function IRLowerer:lower_module(node, scope)
  -- module-level instructions go into a synthetic function "main"
  local fn = Function.new("main")
  fn.is_entry_point = true
  self._cur_fn = fn
  local b = Block.new("entry")
  table.insert(fn.blocks, b)
  self._cur_block = b
  for _, stmt in ipairs(node.body or {}) do
    self:lower_stmt(stmt)
  end
  table.insert(self.module.functions, fn)
  if scope then
    fn.locals = {}
    for k in pairs(scope.locals or {}) do table.insert(fn.locals, k) end
    table.sort(fn.locals)
    self.module.globals = {}
    for k in pairs(scope.locals or {}) do table.insert(self.module.globals, k) end
    table.sort(self.module.globals)
  end
  return self.module
end

------------------------------------------------------------------------------
-- Statement lowering
------------------------------------------------------------------------------

function IRLowerer:lower_stmt(node)
  local prev_node = self._cur_node
  if node and node.lineno and node.lineno > 0 then
    self._cur_node = node
  end
  self:_lower_stmt_impl(node)
  self._cur_node = prev_node
end

local function _is_cell_or_free(fn, name)
  if not fn then return false end
  for _, v in ipairs(fn.cellvars or {}) do if v == name then return true end end
  for _, v in ipairs(fn.freevars or {}) do if v == name then return true end end
  return false
end

function IRLowerer:_lower_target(tgt, val_tmp)
  if tgt._type == "Tuple" or tgt._type == "List" then
    local star_idx = nil
    for idx, e in ipairs(tgt.elts or {}) do
      if e._type == "Starred" then star_idx = idx; break end
    end
    if not star_idx then
      for i, e in ipairs(tgt.elts or {}) do
        local elem_tmp = self:_new_tmp()
        self:_emit("SUBSCR_DIRECT", {val_tmp, tostring(i - 1)}, elem_tmp)
        self:_lower_target(e, elem_tmp)
      end
    else
      local elts = tgt.elts or {}
      local num_trail = #elts - star_idx
      for i = 1, star_idx - 1 do
        local elem_tmp = self:_new_tmp()
        self:_emit("SUBSCR_DIRECT", {val_tmp, tostring(i - 1)}, elem_tmp)
        self:_lower_target(elts[i], elem_tmp)
      end
      for j = 1, num_trail do
        local idx_tmp = self:_new_tmp()
        self:_emit("CONST", {-j}, idx_tmp)
        local elem_tmp = self:_new_tmp()
        self:_emit("SUBSCR", {val_tmp, idx_tmp}, elem_tmp)
        self:_lower_target(elts[#elts - j + 1], elem_tmp)
      end
      local star_elem = elts[star_idx]
      local slice_tmp = self:_new_tmp()
      if num_trail > 0 then
        self:_emit("CALL", {"_luthon_slice", val_tmp, tostring(star_idx - 1), tostring(-num_trail)}, slice_tmp)
      else
        self:_emit("CALL", {"_luthon_slice", val_tmp, tostring(star_idx - 1)}, slice_tmp)
      end
      self:_lower_target(star_elem.value, slice_tmp)
    end
  elseif tgt._type == "Starred" then
    self:_lower_target(tgt.value, val_tmp)
  elseif tgt._type == "Name" then
    local safe_name = _safe_var(tgt.id)
    if _is_cell_or_free(self._cur_fn, tgt.id) then
      self:_emit("CELL_SET", {safe_name, val_tmp})
    else
      self:_emit("STORE", {safe_name, val_tmp})
    end
  elseif tgt._type == "Subscript" then
    local base = self:lower_expr(tgt.value)
    local sl = self:lower_expr(tgt.slice)
    self:_emit("STORE_SUBSCR", {base, sl, val_tmp})
  elseif tgt._type == "Attribute" then
    local obj = self:lower_expr(tgt.value)
    if LUA_RESERVED_KEYWORDS[tgt.attr] then
      self:_emit("STORE_SUBSCR", {obj, "\"" .. tgt.attr .. "\"", val_tmp})
    else
      self:_emit("SET_ATTR", {obj, tgt.attr, val_tmp})
    end
  end
end

function IRLowerer:_lower_stmt_impl(node)
  local t = node._type
  if t == "Expr" then
    self:lower_expr(node.value)
  elseif t == "Assign" then
    local tgts = node.targets or {}
    if #tgts == 1 and (tgts[1]._type == "Tuple" or tgts[1]._type == "List")
       and (node.value and (node.value._type == "Tuple" or node.value._type == "List"))
       and #(tgts[1].elts or {}) == #(node.value.elts or {}) then
      local tgt_elts = tgts[1].elts or {}
      local val_elts = node.value.elts or {}
      local has_star = false
      for _, e in ipairs(tgt_elts) do if e._type == "Starred" then has_star = true; break end end
      if not has_star then
        for _, e in ipairs(val_elts) do if e._type == "Starred" then has_star = true; break end end
      end
      if not has_star then
        local rhs_tmps = {}
        for _, e in ipairs(val_elts) do
          table.insert(rhs_tmps, self:lower_expr(e))
        end
        for i, tgt_elt in ipairs(tgt_elts) do
          self:_lower_target(tgt_elt, rhs_tmps[i])
        end
        return
      end
    end
    local val = self:lower_expr(node.value)
    for _, tgt in ipairs(tgts) do
      self:_lower_target(tgt, val)
    end
  elseif t == "Delete" then
    -- del target -> set to nil (or delete attribute/item)
    for _, tgt in ipairs(node.targets or {}) do
      local nil_tmp = self:_new_tmp()
      self:_emit("CONST", {nil}, nil_tmp)
      if tgt._type == "Name" then
        self:_emit("STORE", {_safe_var(tgt.id), nil_tmp})
      elseif tgt._type == "Attribute" then
        local obj = self:lower_expr(tgt.value)
        if LUA_RESERVED_KEYWORDS[tgt.attr] then
          self:_emit("STORE_SUBSCR", {obj, "\"" .. tgt.attr .. "\"", nil_tmp})
        else
          self:_emit("SET_ATTR", {obj, tgt.attr, nil_tmp})
        end
      elseif tgt._type == "Subscript" then
        local base = self:lower_expr(tgt.value)
        local sl = self:lower_expr(tgt.slice)
        self:_emit("STORE_SUBSCR", {base, sl, nil_tmp})
      end
    end
  elseif t == "AugAssign" then
    local lhs = self:lower_expr(node.target)
    local rhs = self:lower_expr(node.value)
    local res = self:_new_tmp()
    self:_emit("BINOP", {self:_binop(node.op), lhs, rhs}, res)
    local target_t = node.target._type or node.target.type
    if target_t == "Name" then
      self:_emit("STORE", {node.target.id, res})
    elseif target_t == "Attribute" then
      local val = self:lower_expr(node.target.value)
      self:_emit("SET_ATTR", {val, node.target.attr, res})
    elseif target_t == "Subscript" then
      local val = self:lower_expr(node.target.value)
      local idx = self:lower_expr(node.target.slice)
      self:_emit("STORE_SUBSCR", {val, idx, res})
    end
  elseif t == "Return" then
    local val = nil
    if node.value then val = self:lower_expr(node.value) end
    if self._try_depth > 0 then
      if val then
        self:_emit("TRY_RETURN", {val})
      else
        self:_emit("TRY_RETURN", {})
      end
    else
      if val then
        self:_emit("RETURN", {val})
      else
        self:_emit("RETURN", {})
      end
    end
  elseif t == "Assert" then
    -- assert condition [, msg] -> _luthon_assert_fail(condition, msg)
    local cond = self:lower_expr(node.test)
    local msg_tmp = nil
    if node.msg then
      msg_tmp = self:lower_expr(node.msg)
    else
      msg_tmp = self:_new_tmp()
      self:_emit("CONST", {nil}, msg_tmp)
    end
    self:_emit("CALL", {"_luthon_assert_fail", cond, msg_tmp}, self:_new_tmp())
  elseif t == "If" then
    local cond = self:lower_expr(node.test)
    local then_lbl = self:_new_label("then")
    local else_lbl = self:_new_label("else")
    local end_lbl = self:_new_label("endif")
    self:_emit("BRANCH", {cond, then_lbl, else_lbl})
    -- then
    self._cur_block = self:_new_block(then_lbl)
    self:_emit("DO", {})
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    if not node.body or node.body[#node.body]._type ~= "Return" then
      self:_emit("JUMP", {end_lbl})
    end
    self:_emit("END", {})
    -- else
    self._cur_block = self:_new_block(else_lbl)
    self:_emit("DO", {})
    for _, s in ipairs(node.orelse or {}) do self:lower_stmt(s) end
    if not node.orelse or #node.orelse == 0 or node.orelse[#node.orelse]._type ~= "Return" then
      self:_emit("JUMP", {end_lbl})
    end
    self:_emit("END", {})
    self._cur_block = self:_new_block(end_lbl)
  elseif t == "While" then
    local cond_lbl = self:_new_label("whilecond")
    local body_lbl = self:_new_label("whilebody")
    local end_lbl = self:_new_label("whileend")
    table.insert(self._break_stack, end_lbl)
    table.insert(self._continue_stack, cond_lbl)
    self:_emit("JUMP", {cond_lbl})
    self._cur_block = self:_new_block(cond_lbl)
    local cond = self:lower_expr(node.test)
    self:_emit("BRANCH", {cond, body_lbl, end_lbl})
    self._cur_block = self:_new_block(body_lbl)
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    self:_emit("JUMP", {cond_lbl})
    if #self._break_stack > 0 then table.remove(self._break_stack) end
    if #self._continue_stack > 0 then table.remove(self._continue_stack) end
    self._cur_block = self:_new_block(end_lbl)
  elseif t == "For" then
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(node.iter)}, iter_tmp)
    local cond_lbl = self:_new_label("forcond")
    local body_lbl = self:_new_label("forbody")
    local end_lbl = self:_new_label("forend")
    table.insert(self._break_stack, end_lbl)
    table.insert(self._continue_stack, cond_lbl)
    self:_emit("JUMP", {cond_lbl})
    self._cur_block = self:_new_block(cond_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    self:_emit("BRANCH_NONE", {nxt, end_lbl})
    if node.target._type == "Name" then
      self:_emit("STORE", {_safe_var(node.target.id), nxt})
    elseif node.target._type == "Tuple" or node.target._type == "List" then
      for i, t in ipairs(node.target.elts or {}) do
        if t._type == "Name" then
          local idx_tmp = self:_new_tmp()
          self:_emit("CONST", {i - 1}, idx_tmp)
          local elem_tmp = self:_new_tmp()
          self:_emit("SUBSCR", {nxt, idx_tmp}, elem_tmp)
          self:_emit("STORE", {_safe_var(t.id), elem_tmp})
        end
      end
    end
    self:_emit("JUMP", {body_lbl})
    self._cur_block = self:_new_block(body_lbl)
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    self:_emit("JUMP", {cond_lbl})
    if #self._break_stack > 0 then table.remove(self._break_stack) end
    if #self._continue_stack > 0 then table.remove(self._continue_stack) end
    self._cur_block = self:_new_block(end_lbl)
  elseif t == "FunctionDef" or t == "AsyncFunctionDef" then
    local fn_sym = node.name
    local count = (self._fn_counter[node.name] or 0) + 1
    self._fn_counter[node.name] = count
    local unique_fn_name = (count == 1) and node.name or (node.name .. "_" .. tostring(count))
    local is_nested = (self._cur_fn ~= nil and not self._cur_fn.is_entry_point)
    local fn = Function.new(unique_fn_name, {})
    fn.is_nested = is_nested
    for _, a in ipairs(node.args and node.args.args or {}) do table.insert(fn.params, _safe_var(a.arg)) end
    if node.args and (node.args.vararg or node.args.kwarg) then
      table.insert(fn.params, "...")
    end
    -- upvalues and locals from semantic scope if available
    local sc = node._scope
    if sc then
      fn.locals = {}
      for k in pairs(sc.locals or {}) do table.insert(fn.locals, _safe_var(k)) end
      table.sort(fn.locals)
      fn.freevars = {}
      for k in pairs(sc.freevars or {}) do table.insert(fn.freevars, _safe_var(k)) end
      table.sort(fn.freevars)
      fn.cellvars = {}
      for k in pairs(sc.cellvars or {}) do table.insert(fn.cellvars, _safe_var(k)) end
      table.sort(fn.cellvars)
      fn.upvalues = {}
      for _, fv in ipairs(fn.freevars) do table.insert(fn.upvalues, fv) end
    end
    local prev_fn = self._cur_fn
    local prev_block = self._cur_block
    local prev_try_depth = self._try_depth
    self._try_depth = 0
    self._cur_fn = fn
    local b = Block.new("entry")
    table.insert(fn.blocks, b)
    self._cur_block = b
    -- initialize cell boxes for captured variables
    for _, cv in ipairs(fn.cellvars or {}) do
      local cell = self:_new_tmp()
      self:_emit("MAKE_CELL", {cv}, cell)
      self:_emit("STORE", {cv, cell})
    end
    -- If vararg is present, pack into a table
    if node.args and node.args.vararg then
      local vararg_name = node.args.vararg.arg
      local t_dots = self:_new_tmp()
      self:_emit("CALL", {"_tuple_pack", "..."}, t_dots)
      self:_emit("STORE", {vararg_name, t_dots})
    end
    -- If kwarg is present, initialize table
    if node.args and node.args.kwarg then
      local kwarg_name = node.args.kwarg.arg
      local t_kw = self:_new_tmp()
      self:_emit("CALL", {"_luthon_extract_kwargs", "..."}, t_kw)
      self:_emit("STORE", {kwarg_name, t_kw})
    end
    -- Unpack default parameter values
    local args_list = node.args and node.args.args or {}
    local defaults = node.args and node.args.defaults or {}
    if #defaults > 0 then
      local offset = #args_list - #defaults
      for i, default in ipairs(defaults) do
        local param_name = args_list[offset + i].arg
        local def_tmp = self:lower_expr(default)
        self:_emit("DEFAULT_ARG", {param_name, def_tmp})
      end
    end
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    if not node.body or node.body[#node.body]._type ~= "Return" then
      self:_emit("RETURN", {})
    end

    local is_gen = _has_yield(node, true)
    local is_async = (t == "AsyncFunctionDef")
    local fn_ref = fn.name

    if is_gen or is_async then
      local wrapper_type = is_gen and "make_generator" or "make_coroutine"
      local impl_name = fn.name .. "_impl"
      fn.name = impl_name
      fn.is_nested = is_nested
      table.insert(self.module.functions, fn)

      local wrapper_params = {}
      for _, a in ipairs(node.args and node.args.args or {}) do table.insert(wrapper_params, _safe_var(a.arg)) end
      if node.args and (node.args.vararg or node.args.kwarg) then
        table.insert(wrapper_params, "...")
      end
      local wrapper_fn = Function.new(unique_fn_name, wrapper_params)
      wrapper_fn.is_nested = is_nested
      if sc then
        wrapper_fn.freevars = {}
        for k in pairs(sc.freevars or {}) do table.insert(wrapper_fn.freevars, _safe_var(k)) end
        table.sort(wrapper_fn.freevars)
        wrapper_fn.cellvars = {}
        for k in pairs(sc.cellvars or {}) do table.insert(wrapper_fn.cellvars, _safe_var(k)) end
        table.sort(wrapper_fn.cellvars)
        wrapper_fn.upvalues = {}
        for _, fv in ipairs(wrapper_fn.freevars) do table.insert(wrapper_fn.upvalues, fv) end
      end
      local wrapper_block = Block.new("entry")
      table.insert(wrapper_fn.blocks, wrapper_block)
      self._cur_fn = wrapper_fn
      self._cur_block = wrapper_block

      local res_tmp = self:_new_tmp()
      local call_args = {wrapper_type, impl_name}
      for _, p in ipairs(wrapper_params) do table.insert(call_args, p) end
      self:_emit("CALL", call_args, res_tmp)
      self:_emit("RETURN", {res_tmp})
      table.insert(self.module.functions, wrapper_fn)

      self._cur_fn = prev_fn
      self._cur_block = prev_block
      fn_ref = unique_fn_name
    else
      table.insert(self.module.functions, fn)
      self._cur_fn = prev_fn
      self._cur_block = prev_block
      fn_ref = fn.name
    end
    self._try_depth = prev_try_depth

    if is_nested then
      local fn_tmp = self:_new_tmp()
      self:_emit("MAKE_FUNCTION", {fn_ref}, fn_tmp)
      self:_emit("STORE", {fn_sym, fn_tmp})
      fn_ref = fn_tmp
    else
      self:_emit("STORE", {fn_sym, fn_ref})
    end
    local clean_params = {}
    for _, p in ipairs(fn.params) do
      if p ~= "..." then table.insert(clean_params, '"' .. p .. '"') end
    end
    if #clean_params > 0 then
      local param_tuple = self:_new_tmp()
      self:_emit("MAKE_TUPLE", clean_params, param_tuple)
      self:_emit("CALL", {"_luthon_reg_fn", fn_ref, param_tuple})
    end
    -- Apply decorators (innermost first)
    for i = #(node.decorator_list or {}), 1, -1 do
      local dec = node.decorator_list[i]
      local dec_tmp = self:lower_expr(dec)
      local fn_tmp = self:_new_tmp()
      self:_emit("LOAD", {fn_sym}, fn_tmp)
      local result_tmp = self:_new_tmp()
      self:_emit("CALL", {dec_tmp, fn_tmp}, result_tmp)
      self:_emit("STORE", {fn_sym, result_tmp})
    end
  elseif t == "Import" then
    for _, alias in ipairs(node.names or {}) do
      local name = alias.asname or alias.name:match("([^%.]+)")
      self._imported_modules[name] = true
      self._imported_modules[alias.name] = true
      if alias.asname then
        self:_emit("IMPORT", {name, alias.name})
      else
        self:_emit("IMPORT", {name, name, alias.name})
      end
    end
  elseif t == "ImportFrom" then
    local mod = node.module or ""
    local level = node.level or 0
    if level > 0 and self.package and self.package ~= "" then
      local pkg_parts = {}
      for p in self.package:gmatch("([^%.]+)") do table.insert(pkg_parts, p) end
      if level <= #pkg_parts then
        local base = {}
        for i = 1, #pkg_parts - (level - 1) do table.insert(base, pkg_parts[i]) end
        if mod ~= "" then table.insert(base, mod) end
        mod = table.concat(base, ".")
      elseif mod ~= "" then
        mod = self.package .. "." .. mod
      end
    elseif level > 0 and (mod == "" or not mod) then
      mod = self.package or ""
    end
    for _, alias in ipairs(node.names or {}) do
      local name = alias.asname or alias.name
      self._imported_modules[name] = true
      self:_emit("IMPORT_FROM", {name, mod, alias.name})
    end
  elseif t == "Try" then
    local handlers = node.handlers or {}
    local orelse = node.orelse or {}
    local finalbody = node.finalbody or {}
    if #finalbody > 0 and (#handlers > 0 or #orelse > 0) then
      local inner = {
        _type = "Try",
        body = node.body,
        handlers = handlers,
        orelse = orelse,
        finalbody = {}
      }
      local outer = {
        _type = "Try",
        body = {inner},
        handlers = {},
        orelse = {},
        finalbody = finalbody
      }
      self:lower_stmt(outer)
      return
    end

    if #finalbody > 0 then
      local try_label = self:_new_label("try")
      local try_block = self:_new_block(try_label)
      self._cur_block = try_block
      self:_emit("TRY_BEGIN", {}, self:_new_tmp())
      self._try_depth = self._try_depth + 1
      for _, s in ipairs(node.body or {}) do
        self:lower_stmt(s)
      end
      self._try_depth = self._try_depth - 1
      self:_emit("FINALLY_BEGIN", {}, self:_new_tmp())
      local finally_label = self:_new_label("finally")
      self._cur_block = self:_new_block(finally_label)
      for _, s in ipairs(finalbody) do
        self:lower_stmt(s)
      end
      self:_emit("FINALLY_END", {}, self:_new_tmp())
      local end_label = self:_new_label("end_try")
      self._cur_block = self:_new_block(end_label)
      self:_emit("TRY_UNWIND", {tostring(self._try_depth)})
      return
    end

    local try_label = self:_new_label("try")
    local try_block = self:_new_block(try_label)
    self._cur_block = try_block
    self:_emit("TRY_BEGIN", {}, self:_new_tmp())
    self._try_depth = self._try_depth + 1
    for _, s in ipairs(node.body or {}) do
      self:lower_stmt(s)
    end
    self._try_depth = self._try_depth - 1
    self:_emit("END_TRY", {}, self:_new_tmp())
    for _, h in ipairs(handlers) do
      local handler_lbl = self:_new_label("except")
      self._cur_block = self:_new_block(handler_lbl)
      if h.type then
        local type_tmp = self:lower_expr(h.type)
        self:_emit("CATCH_BEGIN", {type_tmp}, self:_new_tmp())
      else
        self:_emit("CATCH_BEGIN", {}, self:_new_tmp())
      end
      if h.name then
        self:_emit("STORE", {h.name, "_exc"})
      end
      local prev_exc = self._active_exc
      self._active_exc = "_exc"
      for _, s in ipairs(h.body or {}) do
        self:lower_stmt(s)
      end
      self._active_exc = prev_exc
      self:_emit("END_CATCH", {}, self:_new_tmp())
    end
    self:_emit("END_ALL_CATCH", {}, self:_new_tmp())
    if #orelse > 0 then
      self:_emit("TRY_ELSE", {}, self:_new_tmp())
      for _, s in ipairs(orelse) do
        self:lower_stmt(s)
      end
      self:_emit("END_TRY_ELSE", {}, self:_new_tmp())
    end
    self:_emit("TRY_CLOSE", {}, self:_new_tmp())
    local end_label = self:_new_label("end_try")
    self._cur_block = self:_new_block(end_label)
    self:_emit("TRY_UNWIND", {tostring(self._try_depth)})
  elseif t == "Pass" then
    -- no-op
  elseif t == "AnnAssign" then
    -- Annotated assignment: no runtime code needed (type declarations)
    -- If there's a value, lower it as a regular assignment
    if node.value then
      local val = self:lower_expr(node.value)
      if node.target._type == "Name" then
        self:_emit("STORE", {node.target.id, val})
      end
    end
  elseif t == "ClassDef" then
    -- Check for @dataclass decorator
    local is_dataclass = false
    for _, dec in ipairs(node.decorator_list or {}) do
      if dec._type == "Name" and dec.id == "dataclass" then
        is_dataclass = true
      elseif dec._type == "Attribute" and dec.attr == "dataclass" then
        is_dataclass = true
      elseif dec._type == "Call" then
        local df = dec.func
        if df._type == "Name" and df.id == "dataclass" then
          is_dataclass = true
        elseif df._type == "Attribute" and df.attr == "dataclass" then
          is_dataclass = true
        end
      end
    end

    -- Collect fields from annotated assignments
    local fields = {}
    for _, stmt in ipairs(node.body or {}) do
      if stmt._type == "AnnAssign" and stmt.target._type == "Name" then
        local field_name = stmt.target.id
        local default_tmp = nil
        local has_default = false
        if stmt.value then
          default_tmp = self:lower_expr(stmt.value)
          has_default = true
        end
        table.insert(fields, {name = field_name, default_tmp = default_tmp, has_default = has_default})
      end
    end

    -- create class table
    local cls = self:_new_tmp()
    self:_emit("MAKE_CLASS", {node.name}, cls)

    -- Set base class if inheritance is used
    if node.bases and #node.bases > 0 then
      local base_tmp = self:lower_expr(node.bases[1])
      self:_emit("SET_ATTR", {node.name, "__base__", base_tmp})
    end

    -- Set __name__ and __dataclass_fields__ on class
    local name_tmp = self:_new_tmp()
    self:_emit("CONST", {node.name}, name_tmp)
    self:_emit("SET_ATTR", {node.name, "__name__", name_tmp})
    if is_dataclass and #fields > 0 then
      local fields_list = {}
      for _, f in ipairs(fields) do table.insert(fields_list, f.name) end
      local fields_tmp = self:_new_tmp()
      self:_emit("MAKE_LIST", fields_list, fields_tmp)
      self:_emit("SET_ATTR", {node.name, "__dataclass_fields__", fields_tmp})
    end

    -- lower existing methods and track which dunder methods exist
    local has_init = false
    local has_repr = false
    local has_eq = false
    local prev_cur_class = self._cur_class
    self._cur_class = node.name
    local method_counts = {}
    for _, stmt in ipairs(node.body or {}) do
      if stmt._type == "FunctionDef" or stmt._type == "AsyncFunctionDef" then
        method_counts[stmt.name] = (method_counts[stmt.name] or 0) + 1
        local count = method_counts[stmt.name]
        local fn_subname = (count == 1) and stmt.name or (stmt.name .. "_" .. count)
        if stmt.name == "__init__" then has_init = true end
        if stmt.name == "__repr__" then has_repr = true end
        if stmt.name == "__eq__" then has_eq = true end
        local prev_method_first_arg = self._cur_method_first_arg
        self._cur_method_first_arg = stmt.args and stmt.args.args and stmt.args.args[1] and stmt.args.args[1].arg
        local fn = Function.new(node.name .. "." .. fn_subname, {})
        for _, a in ipairs(stmt.args and stmt.args.args or {}) do table.insert(fn.params, _safe_var(a.arg)) end
        if stmt.args and (stmt.args.vararg or stmt.args.kwarg) then
          table.insert(fn.params, "...")
        end
        local sc = stmt._scope
        if sc then
          fn.locals = {}
          for k in pairs(sc.locals or {}) do table.insert(fn.locals, _safe_var(k)) end
          table.sort(fn.locals)
          fn.freevars = {}
          for k in pairs(sc.freevars or {}) do table.insert(fn.freevars, _safe_var(k)) end
          table.sort(fn.freevars)
          fn.cellvars = {}
          for k in pairs(sc.cellvars or {}) do table.insert(fn.cellvars, _safe_var(k)) end
          table.sort(fn.cellvars)
          fn.upvalues = {}
          for _, fv in ipairs(fn.freevars) do table.insert(fn.upvalues, fv) end
        end
        local prev_fn = self._cur_fn
        local prev_block = self._cur_block
        local prev_try_depth = self._try_depth
        self._try_depth = 0
        self._cur_fn = fn
        local b = Block.new("entry")
        table.insert(fn.blocks, b)
        self._cur_block = b
        -- initialize cell boxes for captured variables
        for _, cv in ipairs(fn.cellvars or {}) do
          local cell = self:_new_tmp()
          self:_emit("MAKE_CELL", {cv}, cell)
          self:_emit("STORE", {cv, cell})
        end
        -- If vararg is present, pack into a table
        if stmt.args and stmt.args.vararg then
          local vararg_name = stmt.args.vararg.arg
          local t_dots = self:_new_tmp()
          self:_emit("CALL", {"_tuple_pack", "..."}, t_dots)
          self:_emit("STORE", {vararg_name, t_dots})
        end
        -- If kwarg is present, initialize table
        if stmt.args and stmt.args.kwarg then
          local kwarg_name = stmt.args.kwarg.arg
          local t_kw = self:_new_tmp()
          self:_emit("CALL", {"_luthon_extract_kwargs", "..."}, t_kw)
          self:_emit("STORE", {kwarg_name, t_kw})
        end
        -- Unpack default parameter values
        local args_list = stmt.args and stmt.args.args or {}
        local defaults = stmt.args and stmt.args.defaults or {}
        if #defaults > 0 then
          local offset = #args_list - #defaults
          for i, default in ipairs(defaults) do
            local param_name = args_list[offset + i].arg
            local def_tmp = self:lower_expr(default)
            self:_emit("DEFAULT_ARG", {param_name, def_tmp})
          end
        end
        for _, s2 in ipairs(stmt.body or {}) do self:lower_stmt(s2) end
        if not stmt.body or stmt.body[#stmt.body]._type ~= "Return" then
          self:_emit("RETURN", {})
        end

        local is_gen = _has_yield(stmt, true)
        local is_async = (stmt._type == "AsyncFunctionDef")
        if is_gen or is_async then
          local wrapper_type = is_gen and "make_generator" or "make_coroutine"
          local impl_name = node.name .. "." .. fn_subname .. "_impl"
          fn.name = impl_name
          table.insert(self.module.functions, fn)

          local wrapper_params = {}
          for _, p in ipairs(fn.params) do table.insert(wrapper_params, p) end
          local wrapper_fn = Function.new(node.name .. "." .. fn_subname, wrapper_params)
          if sc then
            wrapper_fn.freevars = {}
            for k in pairs(sc.freevars or {}) do table.insert(wrapper_fn.freevars, _safe_var(k)) end
            table.sort(wrapper_fn.freevars)
            wrapper_fn.cellvars = {}
            for k in pairs(sc.cellvars or {}) do table.insert(wrapper_fn.cellvars, _safe_var(k)) end
            table.sort(wrapper_fn.cellvars)
            wrapper_fn.upvalues = {}
            for _, fv in ipairs(wrapper_fn.freevars) do table.insert(wrapper_fn.upvalues, fv) end
          end
          local wrapper_block = Block.new("entry")
          table.insert(wrapper_fn.blocks, wrapper_block)
          self._cur_fn = wrapper_fn
          self._cur_block = wrapper_block

          local res_tmp = self:_new_tmp()
          local call_args = {wrapper_type, impl_name}
          for _, p in ipairs(wrapper_params) do table.insert(call_args, p) end
          self:_emit("CALL", call_args, res_tmp)
          self:_emit("RETURN", {res_tmp})
          table.insert(self.module.functions, wrapper_fn)

          self._cur_fn = prev_fn
          self._cur_block = prev_block
        else
          table.insert(self.module.functions, fn)
          self._cur_fn = prev_fn
          self._cur_block = prev_block
        end
        self._try_depth = prev_try_depth
        self._cur_method_first_arg = prev_method_first_arg

        local clean_params = {}
        for _, p in ipairs(fn.params) do
          if p ~= "..." then table.insert(clean_params, '"' .. p .. '"') end
        end
        if #clean_params > 0 then
          local param_tuple = self:_new_tmp()
          self:_emit("MAKE_TUPLE", clean_params, param_tuple)
          self:_emit("CALL", {"_luthon_reg_fn", node.name .. "." .. fn_subname, param_tuple})
        end
        if stmt.name == "__init__" then
          local init_params = {}
          for i = 2, #clean_params do table.insert(init_params, clean_params[i]) end
          if #init_params > 0 then
            local cls_param_tuple = self:_new_tmp()
            self:_emit("MAKE_TUPLE", init_params, cls_param_tuple)
            self:_emit("CALL", {"_luthon_reg_fn", node.name, cls_param_tuple})
          end
        end

        -- Apply decorators on class method (innermost first)
        local dec_list = stmt.decorator_list or {}
        if #dec_list > 0 then
          for i = #dec_list, 1, -1 do
            local dec = dec_list[i]
            if dec._type == "Name" and dec.id == "property" then
              local prop_tmp = self:_new_tmp()
              local prop_ref = node.name .. "." .. fn_subname
              self:_emit("CALL", {"property", prop_ref}, prop_tmp)
              self:_emit("SET_ATTR", {node.name, stmt.name, prop_tmp})
            elseif dec._type == "Attribute" and dec.value and dec.value._type == "Name" and (dec.attr == "setter" or dec.attr == "deleter" or dec.attr == "getter") then
              local base_prop = self:_new_tmp()
              if LUA_RESERVED_KEYWORDS[dec.value.id] then
                self:_emit("SUBSCR", {node.name, "\"" .. dec.value.id .. "\""}, base_prop)
              else
                self:_emit("GET_ATTR", {node.name, dec.value.id}, base_prop)
              end
              local dec_fn = self:_new_tmp()
              self:_emit("GET_ATTR", {base_prop, dec.attr}, dec_fn)
              local m_tmp = self:_new_tmp()
              if LUA_RESERVED_KEYWORDS[fn_subname] then
                self:_emit("SUBSCR", {node.name, "\"" .. fn_subname .. "\""}, m_tmp)
              else
                self:_emit("GET_ATTR", {node.name, fn_subname}, m_tmp)
              end
              local res_tmp = self:_new_tmp()
              self:_emit("CALL", {dec_fn, m_tmp}, res_tmp)
              if LUA_RESERVED_KEYWORDS[stmt.name] then
                self:_emit("STORE_SUBSCR", {node.name, "\"" .. stmt.name .. "\"", res_tmp})
              else
                self:_emit("SET_ATTR", {node.name, stmt.name, res_tmp})
              end
            else
              local dec_tmp = self:lower_expr(dec)
              local m_tmp = self:_new_tmp()
              if LUA_RESERVED_KEYWORDS[fn_subname] then
                self:_emit("SUBSCR", {node.name, "\"" .. fn_subname .. "\""}, m_tmp)
              else
                self:_emit("GET_ATTR", {node.name, fn_subname}, m_tmp)
              end
              local res_tmp = self:_new_tmp()
              self:_emit("CALL", {dec_tmp, m_tmp}, res_tmp)
              if LUA_RESERVED_KEYWORDS[stmt.name] then
                self:_emit("STORE_SUBSCR", {node.name, "\"" .. stmt.name .. "\"", res_tmp})
              else
                self:_emit("SET_ATTR", {node.name, stmt.name, res_tmp})
              end
            end
          end
        elseif count > 1 then
          local m_tmp = self:_new_tmp()
          if LUA_RESERVED_KEYWORDS[fn_subname] then
            self:_emit("SUBSCR", {node.name, "\"" .. fn_subname .. "\""}, m_tmp)
          else
            self:_emit("GET_ATTR", {node.name, fn_subname}, m_tmp)
          end
          if LUA_RESERVED_KEYWORDS[stmt.name] then
            self:_emit("STORE_SUBSCR", {node.name, "\"" .. stmt.name .. "\"", m_tmp})
          else
            self:_emit("SET_ATTR", {node.name, stmt.name, m_tmp})
          end
        end
      end
    end
    self._cur_class = prev_cur_class

    -- Auto-generate __init__ if dataclass and not defined
    if is_dataclass and not has_init and #fields > 0 then
      local params = {"self"}
      for _, f in ipairs(fields) do table.insert(params, f.name) end
      local fn = Function.new(node.name .. ".__init__", params)
      local prev_fn = self._cur_fn
      local prev_block = self._cur_block
      self._cur_fn = fn
      local b = Block.new("entry")
      table.insert(fn.blocks, b)
      self._cur_block = b
      for _, f in ipairs(fields) do
        self:_emit("SET_ATTR", {"self", f.name, f.name})
      end
      self:_emit("RETURN", {})
      table.insert(self.module.functions, fn)
      self._cur_fn = prev_fn
      self._cur_block = prev_block
    end

    -- Auto-generate __repr__ if dataclass and not defined
    if is_dataclass and not has_repr then
      local fn = Function.new(node.name .. ".__repr__", {"self"})
      local prev_fn = self._cur_fn
      local prev_block = self._cur_block
      self._cur_fn = fn
      local b = Block.new("entry")
      table.insert(fn.blocks, b)
      self._cur_block = b
      local fields_tmp = self:_new_tmp()
      self:_emit("GET_ATTR", {node.name, "__dataclass_fields__"}, fields_tmp)
      local repr_tmp = self:_new_tmp()
      self:_emit("CALL", {"dataclasses_repr", "self", fields_tmp}, repr_tmp)
      self:_emit("RETURN", {repr_tmp})
      table.insert(self.module.functions, fn)
      self._cur_fn = prev_fn
      self._cur_block = prev_block
    end

    -- Auto-generate __eq__ if dataclass and not defined
    if is_dataclass and not has_eq and #fields > 0 then
      local fn = Function.new(node.name .. ".__eq__", {"self", "other"})
      local prev_fn = self._cur_fn
      local prev_block = self._cur_block
      self._cur_fn = fn
      local b = Block.new("entry")
      table.insert(fn.blocks, b)
      self._cur_block = b
      local fields_tmp = self:_new_tmp()
      self:_emit("GET_ATTR", {node.name, "__dataclass_fields__"}, fields_tmp)
      local eq_tmp = self:_new_tmp()
      self:_emit("CALL", {"dataclasses_eq", "self", "other", fields_tmp}, eq_tmp)
      self:_emit("RETURN", {eq_tmp})
      table.insert(self.module.functions, fn)
      self._cur_fn = prev_fn
      self._cur_block = prev_block
    end

    self:_emit("STORE", {node.name, cls})
  elseif t == "Break" then
    if #self._break_stack > 0 then
      self:_emit("JUMP", {self._break_stack[#self._break_stack]})
    end
  elseif t == "Continue" then
    if #self._continue_stack > 0 then
      self:_emit("JUMP", {self._continue_stack[#self._continue_stack]})
    end
  elseif t == "Global" then
    -- global statement: no runtime code needed in Lua (all module-level vars are global)
  elseif t == "Nonlocal" then
    -- nonlocal statement: handled via cell variables at closure creation time
  elseif t == "Raise" then
    if node.exc then
      local exc_tmp = self:lower_expr(node.exc)
      self:_emit("CALL", {"error", exc_tmp}, self:_new_tmp())
    else
      local active_exc = self._active_exc
      if active_exc then
        self:_emit("CALL", {"error", active_exc}, self:_new_tmp())
      else
        self:_emit("CALL", {"error", "\"RuntimeError\""}, self:_new_tmp())
      end
    end
  elseif t == "With" then
    local mgrs = {}
    for _, item in ipairs(node.items or {}) do
      local ctx_tmp = self:lower_expr(item.context_expr)
      local mgr_tmp = self:_new_tmp()
      self:_emit("LOAD", {ctx_tmp}, mgr_tmp)
      local enter_ret = self:_new_tmp()
      self:_emit("CALL", {"_luthon_with_enter", mgr_tmp}, enter_ret)
      if item.optional_vars then
        self:_lower_target(item.optional_vars, enter_ret)
      end
      table.insert(mgrs, mgr_tmp)
      self:_emit("WITH_BEGIN", {})
    end

    self._try_depth = self._try_depth + #mgrs
    for _, s in ipairs(node.body or {}) do
      self:lower_stmt(s)
    end
    self._try_depth = self._try_depth - #mgrs

    for i = #mgrs, 1, -1 do
      self:_emit("WITH_END", {mgrs[i]})
    end
    self:_emit("TRY_UNWIND", {tostring(self._try_depth)})
  elseif t == "Yield" then
    local val_tmp = node.value and self:lower_expr(node.value) or nil
    local args = {"coroutine.yield"}
    if val_tmp then table.insert(args, val_tmp) end
    self:_emit("CALL", args, self:_new_tmp())
  elseif t == "YieldFrom" then
    local it_tmp = self:lower_expr(node.value)
    local iter_fn = self:_new_tmp()
    self:_emit("LOAD", {"iter"}, iter_fn)
    local nxt_iter = self:_new_tmp()
    self:_emit("CALL", {iter_fn, it_tmp}, nxt_iter)
    local loop_lbl = self:_new_label("yfrom_loop")
    local body_lbl = self:_new_label("yfrom_body")
    local end_lbl = self:_new_label("yfrom_end")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local val = self:_new_tmp()
    self:_emit("NEXT", {nxt_iter}, val)
    self:_emit("BRANCH_NONE", {val, end_lbl})
    self._cur_block = self:_new_block(body_lbl)
    self:_emit("CALL", {"coroutine.yield", val}, self:_new_tmp())
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(end_lbl)
  elseif t == "Delete" then
    for _, trg in ipairs(node.targets or {}) do
      if trg._type == "Subscript" then
        local t_tmp = self:lower_expr(trg.value)
        local idx_tmp = self:lower_expr(trg.slice)
        self:_emit("CALL", {"__luthon_delitem", t_tmp, idx_tmp}, self:_new_tmp())
      elseif trg._type == "Attribute" then
        local t_tmp = self:lower_expr(trg.value)
        self:_emit("SET_ATTR", {t_tmp, trg.attr, "nil"})
      elseif trg._type == "Name" then
        self:_emit("STORE", {_safe_var(trg.id), "nil"})
      end
    end
  else
    -- fallback: record unsupported
    self:_emit("NOP", {type(node).__name__ or type(node)})
  end
end

------------------------------------------------------------------------------
-- Comprehension lowering helper
------------------------------------------------------------------------------

function IRLowerer:_lower_comprehension_generators(generators, emit_element_fn, end_label)
  local function lower_at(idx, outer_loop_lbl)
    local gen = generators[idx]
    local is_last = (idx == #generators)
    local loop_lbl = self:_new_label("comp_loop")
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(gen.iter)}, iter_tmp)
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    local exit_target = (idx == 1) and end_label or outer_loop_lbl
    self:_emit("BRANCH_NONE", {nxt, exit_target})
    self:_lower_target(gen.target, nxt)
    if gen.ifs then
      for _, if_expr in ipairs(gen.ifs) do
        local chk_lbl = self:_new_label("comp_if")
        local cond = self:lower_expr(if_expr)
        self:_emit("BRANCH", {cond, chk_lbl, loop_lbl})
        self._cur_block = self:_new_block(chk_lbl)
      end
    end
    if is_last then
      emit_element_fn()
      self:_emit("JUMP", {loop_lbl})
    else
      lower_at(idx + 1, loop_lbl)
    end
  end

  lower_at(1, end_label)
end

------------------------------------------------------------------------------
-- Expression lowering
------------------------------------------------------------------------------

function IRLowerer:lower_expr(node)
  if node == nil then return nil end
  local prev_node = self._cur_node
  if node and node.lineno and node.lineno > 0 then
    self._cur_node = node
  end
  local res = self:_lower_expr_impl(node)
  self._cur_node = prev_node
  return res
end

function IRLowerer:_lower_expr_impl(node)
  if node == nil then return nil end
  local t = node._type

  if t == "Constant" then
    local res = self:_new_tmp()
    local v = node.value
    if type(v) == "string" then
      -- bytes -> string handled by caller; here just pass through
    end
    if v == true then
      self:_emit("CONST", {true}, res)
    elseif v == false then
      self:_emit("CONST", {false}, res)
    elseif v == nil then
      self:_emit("CONST", {nil}, res)
    else
      self:_emit("CONST", {v, node.is_raw == true}, res)
    end
    return res
  elseif t == "Subscript" then
    local v = self:lower_expr(node.value)
    if node.slice._type == "Slice" then
      local lower_tmp = node.slice.lower and self:lower_expr(node.slice.lower) or "nil"
      local upper_tmp = node.slice.upper and self:lower_expr(node.slice.upper) or "nil"
      local step_tmp = node.slice.step and self:lower_expr(node.slice.step) or "nil"
      local res = self:_new_tmp()
      self:_emit("CALL", {"_luthon_slice", v, lower_tmp, upper_tmp, step_tmp}, res)
      return res
    else
      local sl = self:lower_expr(node.slice)
      local res = self:_new_tmp()
      self:_emit("SUBSCR", {v, sl}, res)
      return res
    end
  elseif t == "Attribute" then
    local obj = self:lower_expr(node.value)
    local res = self:_new_tmp()
    if LUA_RESERVED_KEYWORDS[node.attr] then
      self:_emit("SUBSCR", {obj, "\"" .. node.attr .. "\""}, res)
    else
      self:_emit("GET_ATTR", {obj, node.attr}, res)
    end
    return res
  elseif t == "Name" then
    if node.id == "True" then
      local res = self:_new_tmp()
      self:_emit("CONST", {true}, res)
      return res
    elseif node.id == "False" then
      local res = self:_new_tmp()
      self:_emit("CONST", {false}, res)
      return res
    elseif node.id == "None" then
      local res = self:_new_tmp()
      self:_emit("CONST", {nil}, res)
      return res
    end
    local safe_name = _safe_var(node.id)
    if _is_cell_or_free(self._cur_fn, node.id) then
      local res = self:_new_tmp()
      self:_emit("CELL_GET", {safe_name}, res)
      return res
    end
    local res = self:_new_tmp()
    local name = safe_name
    if node.id == "type" and (not self._cur_fn or ((not self._cur_fn.params or not self._cur_fn.params[node.id]) and (not self._cur_fn.locals or not self._cur_fn.locals[node.id]))) then
      name = "_luthon_type"
    end
    self:_emit("LOAD", {name}, res)
    return res
  elseif t == "BinOp" and node.left._type == "List" and node.op._type == "Mult" then
    local l = self:lower_expr(node.left)
    local r = self:lower_expr(node.right)
    local res = self:_new_tmp()
    self:_emit("LIST_REPEAT", {l, r}, res)
    return res
  elseif t == "BinOp" then
    if node.left and node.left._type == "Constant" and node.right and node.right._type == "Constant" then
      local lv = node.left.value
      local rv = node.right.value
      if type(lv) == "number" and type(rv) == "number" then
        local op = node.op and (type(node.op) == "string" and node.op or node.op._type) or ""
        local res = nil
        if op == "Add" then res = lv + rv
        elseif op == "Sub" then res = lv - rv
        elseif op == "Mult" then res = lv * rv
        elseif op == "Div" and rv ~= 0 then res = lv / rv
        elseif op == "Pow" then res = lv ^ rv
        elseif op == "FloorDiv" and rv ~= 0 then res = math.floor(lv / rv)
        elseif op == "Mod" and rv ~= 0 then res = lv % rv
        end
        if res ~= nil then
          return self:lower_expr({_type = "Constant", value = res})
        end
      end
    end
    local l = self:lower_expr(node.left)
    local r = self:lower_expr(node.right)
    local res = self:_new_tmp()
    self:_emit("BINOP", {self:_binop(node.op), l, r}, res)
    return res
  elseif t == "BoolOp" then
    local op = node.op
    local op_name = type(op) == "string" and op or op._type  -- "And" or "Or"
    local result = self:_new_tmp()
    -- Evaluate left operand first
    local left_tmp = self:lower_expr(node.values[1])
    local end_lbl = self:_new_label("bool_end")
    if op_name == "And" then
        -- a and b: if not a then goto false_label (result is _t1)
        local false_lbl = self:_new_label("and_false")
        self:_emit("BRANCH_FALSE", {left_tmp, false_lbl})
        -- Evaluate right operand
        local right_tmp = self:lower_expr(node.values[2])
        self:_emit("STORE", {result, right_tmp})
        self:_emit("JUMP", {end_lbl})
        self._cur_block = self:_new_block(false_lbl)
        self:_emit("STORE", {result, left_tmp})
        self._cur_block = self:_new_block(end_lbl)
    elseif op_name == "Or" then
        -- a or b: if a then goto true_label (result is _t1)
        local true_lbl = self:_new_label("or_true")
        self:_emit("BRANCH_TRUE", {left_tmp, true_lbl})
        -- Evaluate right operand
        local right_tmp = self:lower_expr(node.values[2])
        self:_emit("STORE", {result, right_tmp})
        self:_emit("JUMP", {end_lbl})
        self._cur_block = self:_new_block(true_lbl)
        self:_emit("STORE", {result, left_tmp})
        self._cur_block = self:_new_block(end_lbl)
    end
    return result
  elseif t == "UnaryOp" then
    local v = self:lower_expr(node.operand)
    local res = self:_new_tmp()
    self:_emit("UNOP", {self:_unop(node.op), v}, res)
    return res
  elseif t == "Compare" then
    local l = self:lower_expr(node.left)
    local ops = node.ops or {}
    local comparators = node.comparators or {}
    local result = self:_new_tmp()
    local current = l
    for i, op in ipairs(ops) do
      local r = self:lower_expr(comparators[i])
      local cmp_res = self:_new_tmp()
      self:_emit("CMP", {self:_cmpop(op), l, r}, cmp_res)
      if i > 1 then
        -- Combine with previous comparison using AND
        local prev_res = result
        local new_res = self:_new_tmp()
        self:_emit("BINOP", {"and", prev_res, cmp_res}, new_res)
        result = new_res
      else
        result = cmp_res
      end
      l = r  -- chain: next comparison starts from current right
    end
    return result
  elseif t == "Call" then
    if node.func._type == "Name" and node.func.id == "super" and (not node.args or #node.args == 0) then
      local cur_cls = self._cur_class
      local first_arg = self._cur_method_first_arg
      if cur_cls and first_arg then
        node.args = {{_type = "Name", id = cur_cls}, {_type = "Name", id = first_arg}}
      end
    end

    local kw_table = self:_lower_call_keywords(node)
    local has_starred = false
    for _, a in ipairs(node.args or {}) do
      if a._type == "Starred" then has_starred = true; break end
    end

    local target_fn = nil
    local pos_args = {}
    if node.func._type == "Attribute" then
      local is_module = false
      local known_submodules = {
        ["os.path"] = true, ["urllib.parse"] = true, ["urllib.request"] = true,
        ["urllib.error"] = true, ["http.client"] = true, ["http.server"] = true,
        ["collections.abc"] = true, ["ffi.C"] = true, ["math.simd"] = true,
      }
      if node.func.value._type == "Name" then
        local id = node.func.value.id
        if BUILTIN_MODULES[id] or (self._imported_modules and self._imported_modules[id]) then
          is_module = true
        end
      elseif node.func.value._type == "Attribute" then
        local parts = {}
        local curr = node.func.value
        while curr._type == "Attribute" do
          table.insert(parts, 1, curr.attr)
          curr = curr.value
        end
        if curr._type == "Name" then
          table.insert(parts, 1, curr.id)
          local dotted = table.concat(parts, ".")
          if known_submodules[dotted] or (self._imported_modules and self._imported_modules[dotted]) then
            is_module = true
          end
        end
      end

      if is_module then
        target_fn = self:lower_expr(node.func)
        pos_args = {}
      else
        local obj = self:lower_expr(node.func.value)
        local meth = self:_new_tmp()
        local attr = node.func.attr
        if LUA_RESERVED_KEYWORDS[attr] then
          self:_emit("SUBSCR", {obj, '"' .. attr .. '"'}, meth)
        else
          self:_emit("GET_ATTR", {obj, attr}, meth)
        end
        target_fn = meth
        pos_args = {obj}
      end
    else
      target_fn = self:lower_expr(node.func)
      pos_args = {}
    end

    if has_starred then
      local flat_args_tmp = self:_new_tmp()
      self:_emit("MAKE_LIST", {}, flat_args_tmp)
      for _, obj_arg in ipairs(pos_args) do
        self:_emit("CALL", {"_seq_append", flat_args_tmp, obj_arg})
      end
      for _, a in ipairs(node.args or {}) do
        if a._type == "Starred" then
          local seq = self:lower_expr(a.value)
          self:_emit("CALL", {"_seq_extend", flat_args_tmp, seq})
        else
          local val = self:lower_expr(a)
          self:_emit("CALL", {"_seq_append", flat_args_tmp, val})
        end
      end
      local res = self:_new_tmp()
      if kw_table then
        self:_emit("CALL", {"_luthon_call_starred", target_fn, flat_args_tmp, kw_table}, res)
      else
        self:_emit("CALL", {"_luthon_call_starred", target_fn, flat_args_tmp}, res)
      end
      return res
    end

    local all_args = {}
    for _, a in ipairs(pos_args) do table.insert(all_args, a) end
    for _, a in ipairs(node.args or {}) do table.insert(all_args, self:lower_expr(a)) end
    return self:_emit_call(target_fn, all_args, kw_table)
  elseif t == "IfExp" then
    local cond = self:lower_expr(node.test)
    local res = self:_new_tmp()
    local a = self:lower_expr(node.body)
    local b = self:lower_expr(node.orelse)
    self:_emit("SELECT", {cond, a, b}, res)
    return res
  elseif t == "Slice" then
    -- Slice(lower, upper, step) -> _luthon_slice(lower, upper, step)
    local lower = node.lower and self:lower_expr(node.lower) or nil
    local upper = node.upper and self:lower_expr(node.upper) or nil
    local step = node.step and self:lower_expr(node.step) or nil
    local args = {}
    if lower then table.insert(args, lower) end
    if upper then table.insert(args, upper) end
    if step then table.insert(args, step) end
    local res = self:_new_tmp()
    self:_emit("CALL", {"_luthon_slice", unpack(args)}, res)
    return res
  elseif t == "List" then
    local has_starred = false
    for _, e in ipairs(node.elts or {}) do
      if e._type == "Starred" then has_starred = true; break end
    end
    if not has_starred then
      local res = self:_new_tmp()
      local els = {}
      for _, e in ipairs(node.elts or {}) do table.insert(els, self:lower_expr(e)) end
      self:_emit("MAKE_LIST", els, res)
      return res
    end
    local res = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, res)
    for _, e in ipairs(node.elts or {}) do
      if e._type == "Starred" then
        local seq = self:lower_expr(e.value)
        self:_emit("CALL", {"_seq_extend", res, seq})
      else
        local val = self:lower_expr(e)
        self:_emit("LIST_APPEND", {res, val})
      end
    end
    return res
  elseif t == "Tuple" then
    local has_starred = false
    for _, e in ipairs(node.elts or {}) do
      if e._type == "Starred" then has_starred = true; break end
    end
    if not has_starred then
      local res = self:_new_tmp()
      local els = {}
      for _, e in ipairs(node.elts or {}) do table.insert(els, self:lower_expr(e)) end
      self:_emit("MAKE_TUPLE", els, res)
      return res
    end
    local list_tmp = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, list_tmp)
    for _, e in ipairs(node.elts or {}) do
      if e._type == "Starred" then
        local seq = self:lower_expr(e.value)
        self:_emit("CALL", {"_seq_extend", list_tmp, seq})
      else
        local val = self:lower_expr(e)
        self:_emit("LIST_APPEND", {list_tmp, val})
      end
    end
    local res = self:_new_tmp()
    self:_emit("CALL", {"tuple", list_tmp}, res)
    return res
  elseif t == "Set" then
    local res = self:_new_tmp()
    self:_emit("MAKE_SET", {}, res)
    for _, e in ipairs(node.elts or {}) do
      local val = self:lower_expr(e)
      self:_emit("SET_ADD", {res, val})
    end
    return res
  elseif t == "ListComp" then
    local res = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, res)
    local end_lbl = self:_new_label("lend")
    self:_lower_comprehension_generators(node.generators, function()
      local val = self:lower_expr(node.elt)
      self:_emit("LIST_APPEND", {res, val})
    end, end_lbl)
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "SetComp" then
    local res = self:_new_tmp()
    self:_emit("MAKE_SET", {}, res)
    local end_lbl = self:_new_label("send")
    self:_lower_comprehension_generators(node.generators, function()
      local val = self:lower_expr(node.elt)
      self:_emit("SET_ADD", {res, val})
    end, end_lbl)
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "DictComp" then
    local res = self:_new_tmp()
    self:_emit("MAKE_DICT", {}, res)
    local end_lbl = self:_new_label("dend")
    self:_lower_comprehension_generators(node.generators, function()
      local key = self:lower_expr(node.key)
      local val = self:lower_expr(node.value)
      self:_emit("DICT_SET", {res, key, val})
    end, end_lbl)
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "GeneratorExp" then
    local res = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, res)
    local end_lbl = self:_new_label("gend")
    self:_lower_comprehension_generators(node.generators, function()
      local val = self:lower_expr(node.elt)
      self:_emit("LIST_APPEND", {res, val})
    end, end_lbl)
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "Dict" then
    local res = self:_new_tmp()
    local items = {}
    for i, k in ipairs(node.keys or {}) do
      local v = node.values[i]
      table.insert(items, {k and self:lower_expr(k) or nil, self:lower_expr(v)})
    end
    self:_emit("MAKE_DICT", items, res)
    return res
  elseif t == "Lambda" then
    local args = {}
    if node.args and node.args.args then
      for _, a in ipairs(node.args.args) do table.insert(args, a.arg or a) end
      if node.args.vararg or node.args.kwarg then
        table.insert(args, "...")
      end
    elseif type(node.args) == "table" then
      for _, a in ipairs(node.args) do table.insert(args, type(a) == "table" and (a.arg or a.id) or tostring(a)) end
    end
    -- Create a nested function for the lambda body
    local lambda_name = "_lambda_" .. self._tmp
    self._tmp = self._tmp + 1
    local fn = Function.new(lambda_name, args)
    fn.is_nested = true
    local sc = node._scope
    if sc then
      fn.locals = {}
      for k in pairs(sc.locals or {}) do table.insert(fn.locals, k) end
      table.sort(fn.locals)
      fn.freevars = {}
      for k in pairs(sc.freevars or {}) do table.insert(fn.freevars, k) end
      table.sort(fn.freevars)
      fn.cellvars = {}
      for k in pairs(sc.cellvars or {}) do table.insert(fn.cellvars, k) end
      table.sort(fn.cellvars)
      fn.upvalues = {}
      for _, fv in ipairs(fn.freevars) do table.insert(fn.upvalues, fv) end
    end
    local prev_fn = self._cur_fn
    local prev_block = self._cur_block
    local prev_try_depth = self._try_depth
    self._try_depth = 0
    self._cur_fn = fn
    local b = Block.new("entry")
    table.insert(fn.blocks, b)
    self._cur_block = b
    if node.args and node.args.vararg then
      local vararg_name = node.args.vararg.arg
      local t_dots = self:_new_tmp()
      self:_emit("CALL", {"_tuple_pack", "..."}, t_dots)
      self:_emit("STORE", {vararg_name, t_dots})
    end
    if node.args and node.args.kwarg then
      local kwarg_name = node.args.kwarg.arg
      local t_kw = self:_new_tmp()
      self:_emit("CALL", {"_luthon_extract_kwargs", "..."}, t_kw)
      self:_emit("STORE", {kwarg_name, t_kw})
    end
    local body_tmp = self:lower_expr(node.body)
    self:_emit("RETURN", {body_tmp})
    table.insert(self.module.functions, fn)
    self._cur_fn = prev_fn
    self._cur_block = prev_block
    self._try_depth = prev_try_depth
    -- Emit MAKE_FUNCTION that references the nested function
    local res = self:_new_tmp()
    self:_emit("MAKE_FUNCTION", {fn.name}, res)
    if node.args and node.args.args and #node.args.args > 0 then
      local param_names = {}
      for _, a in ipairs(node.args.args) do
        table.insert(param_names, '"' .. (a.arg or a) .. '"')
      end
      local param_tuple = self:_new_tmp()
      self:_emit("MAKE_TUPLE", param_names, param_tuple)
      self:_emit("CALL", {"_luthon_reg_fn", res, param_tuple})
    end
    return res
  elseif t == "JoinedStr" then
    -- f-string: concatenate all parts using Lua's .. operator.
    -- FormattedValue parts are wrapped in tostring() since their type is unknown.
    local values = node.values or {}
    if #values == 0 then
      local res = self:_new_tmp()
      self:_emit("CONST", {""}, res)
      return res
    end

    -- Lower the first value
    local res = self:lower_expr(values[1])
    if values[1]._type == "FormattedValue" then
      local tmp = self:_new_tmp()
      self:_emit("CALL", {"tostring", res}, tmp)
      res = tmp
    end

    -- Concatenate remaining values
    for i = 2, #values do
      local val = self:lower_expr(values[i])
      if values[i]._type == "FormattedValue" then
        local tmp = self:_new_tmp()
        self:_emit("CALL", {"tostring", val}, tmp)
        val = tmp
      end
      local new_res = self:_new_tmp()
      self:_emit("BINOP", {"concat", res, val}, new_res)
      res = new_res
    end

    return res
  elseif t == "FormattedValue" then
    -- {expr[!conv][:format]} -> lower the inner expression; conversion/format handled by JoinedStr
    return self:lower_expr(node.value)
  elseif t == "Yield" then
    local val_tmp = node.value and self:lower_expr(node.value) or nil
    local args = {"coroutine.yield"}
    if val_tmp then table.insert(args, val_tmp) end
    local res = self:_new_tmp()
    self:_emit("CALL", args, res)
    return res
  elseif t == "YieldFrom" then
    local it_tmp = self:lower_expr(node.value)
    local iter_fn = self:_new_tmp()
    self:_emit("LOAD", {"iter"}, iter_fn)
    local nxt_iter = self:_new_tmp()
    self:_emit("CALL", {iter_fn, it_tmp}, nxt_iter)
    local loop_lbl = self:_new_label("yfrom_loop")
    local body_lbl = self:_new_label("yfrom_body")
    local end_lbl = self:_new_label("yfrom_end")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local val = self:_new_tmp()
    self:_emit("NEXT", {nxt_iter}, val)
    self:_emit("BRANCH_NONE", {val, end_lbl})
    self._cur_block = self:_new_block(body_lbl)
    self:_emit("CALL", {"coroutine.yield", val}, self:_new_tmp())
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(end_lbl)
    local res = self:_new_tmp()
    self:_emit("CONST", {nil}, res)
    return res
  else
    -- fallback
    local res = self:_new_tmp()
    self:_emit("EXPR", {tostring(node._type)}, res)
    return res
  end
end

------------------------------------------------------------------------------
-- Operator mappings
------------------------------------------------------------------------------

function IRLowerer:_binop(op)
  if type(op) == "string" then
    local m = {["+"]="add",["-"]="sub",["*"]="mul",["/"]="div",["%"]="mod",["**"]="pow",["//"]="floordiv",["<"]="lt",["<="]="le",[">"]="gt",[">="]="ge",["=="]="eq",["!="]="ne",
               ["Add"]="add",["Sub"]="sub",["Mult"]="mul",["Div"]="div",["FloorDiv"]="floordiv",["Mod"]="mod",["Pow"]="pow",
               ["LShift"]="<<",["RShift"]=">>",["BitAnd"]="band",["BitOr"]="bor",["BitXor"]="bxor",["MatMult"]="matmul"}
    local r = m[op] or op
    return r
  end
  local r = BINOP_MAP[op._type] or op._type
  return r
end

function IRLowerer:_unop(op)
  if type(op) == "string" then
    local m = {["-"]="neg",["+"]="pos",["not"]="not",["USub"]="neg",["UAdd"]="pos",["Not"]="not",["Invert"]="inv"}
    return m[op] or op
  end
  return UNARY_OP_MAP[op._type] or op._type
end

function IRLowerer:_cmpop(op)
  if type(op) == "string" then
    local m = {["=="]="eq",["!="]="ne",["<"]="lt",["<="]="le",[">"]="gt",[">="]="ge",["is"]="eq",["is not"]="ne",["in"]="in",["not in"]="notin",
               ["Eq"]="eq",["NotEq"]="ne",["Lt"]="lt",["LtE"]="le",["Gt"]="gt",["GtE"]="ge",["Is"]="is",["IsNot"]="isnot",["In"]="in",["NotIn"]="notin"}
    return m[op] or op
  end
  return CMPOP_MAP[op._type] or op._type
end

function IRLowerer:_lower_call_keywords(node)
  -- Lower keyword arguments into a table and return its tmp name, or nil
  if not node.keywords or #node.keywords == 0 then return nil end
  local kw_table = self:_new_tmp()
  self:_emit("MAKE_TABLE", {}, kw_table)
  for _, kw in ipairs(node.keywords) do
    if kw.arg == nil then
      local dict_tmp = self:lower_expr(kw.value)
      self:_emit("CALL", {"_dict_update", kw_table, dict_tmp})
    else
      local key_tmp = self:_new_tmp()
      self:_emit("CONST", {kw.arg}, key_tmp)
      local val_tmp = self:lower_expr(kw.value)
      self:_emit("STORE_SUBSCR", {kw_table, key_tmp, val_tmp})
    end
  end
  return kw_table
end

function IRLowerer:_emit_call(fn, args, kw_table)
  local t = self:_new_tmp()
  if kw_table then
    local call_args = {"_luthon_call_kw", fn, kw_table}
    for _, a in ipairs(args) do table.insert(call_args, a) end
    self:_emit("CALL", call_args, t)
  else
    local call_args = {fn}
    for _, a in ipairs(args) do table.insert(call_args, a) end
    self:_emit("CALL", call_args, t)
  end
  return t
end

------------------------------------------------------------------------------
-- Verification
------------------------------------------------------------------------------

function IRLowerer:verify(module)
  local errors = {}
  for _, fn in ipairs(module.functions or {}) do
    local labels = {}
    for _, b in ipairs(fn.blocks or {}) do labels[b.label] = true end
    if #fn.blocks == 0 then
      table.insert(errors, fn.name .. ": no blocks")
    end
    for _, b in ipairs(fn.blocks or {}) do
      if #b.instrs == 0 then goto continue end
      local last = b.instrs[#b.instrs]
      if last.op == "JUMP" or last.op == "BRANCH" or last.op == "RETURN" or last.op == "BRANCH_NONE" then
        -- ok
      end
      ::continue::
    end
    -- check jump targets resolve
    for _, b in ipairs(fn.blocks or {}) do
      for _, ins in ipairs(b.instrs or {}) do
        if ins.op == "JUMP" or ins.op == "BRANCH" or ins.op == "BRANCH_NONE" then
          for i = 2, #ins.args do
            local a = ins.args[i]
            if type(a) == "string" and not labels[a] and not a:match("^_") then
              table.insert(errors, fn.name .. ": unknown label " .. a)
            end
          end
        end
      end
    end
  end
  return errors
end

function IRLowerer:make_cell(name)
  local t = self:_new_tmp()
  self:_emit("MAKE_CELL", {name}, t)
  return t
end

function IRLowerer:cell_get(cell)
  local t = self:_new_tmp()
  self:_emit("CELL_GET", {cell}, t)
  return t
end

function IRLowerer:cell_set(cell, value)
  self:_emit("CELL_SET", {cell, value})
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function M.lower(source)
  local parser = dofile("src/luthon/lua/parser.lua")
  local tree = parser.parse(source)
  local lowerer = IRLowerer.new()
  return lowerer:lower_module(tree)
end

function M.lower_ast(tree)
  local lowerer = IRLowerer.new()
  return lowerer:lower_module(tree)
end

function M.lower_source(source)
  local parser = require("src/luthon/lua/parser")
  local tree = parser.parse(source)
  local lowerer = IRLowerer.new()
  return lowerer:lower_module(tree)
end

-- Make classes available for testing
M.Instr = Instr
M.Block = Block
M.Function = Function
M.Module = Module
M.IRLowerer = IRLowerer

return M
