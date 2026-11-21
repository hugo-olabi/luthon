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

local function _unquote(s)
  if type(s) == "string" then
    return s:gsub('^["\']', ''):gsub('["\']$', '')
  end
  return s
end

local function _is_numeric_node(n)
  if not n then return false end
  local t = n._type
  if t == "Constant" and type(n.value) == "number" then return true end
  if t == "UnaryOp" and (n.op == "UAdd" or n.op == "USub" or n.op == "+" or n.op == "-") and _is_numeric_node(n.operand) then return true end
  if t == "BinOp" and _is_numeric_node(n.left) and _is_numeric_node(n.right) then return true end
  return false
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
  self._try_loop_depth_stack = {}
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
  for _, f in ipairs(self.module.functions) do
    self:normalize_basic_blocks(f)
  end
  return self.module
end

function IRLowerer:normalize_basic_blocks(fn)
  local BRANCH_FALLTHROUGH_OPS = {BRANCH_TRUE = true, BRANCH_FALSE = true}
  local TERMINAL_OPS = {JUMP = true, RETURN = true, BRANCH = true}
  local STRUCTURAL_OPS = {
    ["DO"] = true, ["END"] = true,
    ["TRY_BEGIN"] = true, ["END_TRY"] = true,
    ["CATCH_BEGIN"] = true, ["END_CATCH"] = true, ["END_ALL_CATCH"] = true,
    ["TRY_ELSE"] = true, ["END_TRY_ELSE"] = true, ["TRY_CLOSE"] = true,
    ["FINALLY_BEGIN"] = true, ["FINALLY_END"] = true,
    ["WITH_BEGIN"] = true, ["WITH_END"] = true,
  }
  local i = 1
  local split_cnt = 0
  while i <= #fn.blocks do
    local b = fn.blocks[i]
    local split_idx = nil
    local is_terminal = false
    local has_structural = false
    for _, ins in ipairs(b.instrs) do
      if STRUCTURAL_OPS[ins.op] then has_structural = true break end
    end
    for idx, ins in ipairs(b.instrs) do
      if BRANCH_FALLTHROUGH_OPS[ins.op] and idx < #b.instrs then
        split_idx = idx
        break
      elseif TERMINAL_OPS[ins.op] and idx < #b.instrs then
        if not has_structural then
          split_idx = idx
          is_terminal = true
          break
        end
      end
    end
    if split_idx then
      if is_terminal then
        local trimmed = {}
        for k = 1, split_idx do trimmed[k] = b.instrs[k] end
        b.instrs = trimmed
      else
        split_cnt = split_cnt + 1
        local new_lbl = b.label .. "_ft_" .. tostring(split_cnt)
        local new_block = Block.new(new_lbl)
        for k = split_idx + 1, #b.instrs do table.insert(new_block.instrs, b.instrs[k]) end
        local trimmed = {}
        for k = 1, split_idx do trimmed[k] = b.instrs[k] end
        b.instrs = trimmed
        table.insert(fn.blocks, i + 1, new_block)
      end
    end
    i = i + 1
  end
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
    if node.value and node.value._type == "Constant" then return end
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
    local is_sorted_items = false
    local sorted_dict_node = nil
    if (node.target._type == "Tuple" or node.target._type == "List")
       and node.target.elts and #node.target.elts == 2
       and node.target.elts[1]._type == "Name" and node.target.elts[2]._type == "Name"
       and node.iter and node.iter._type == "Call"
       and node.iter.func and node.iter.func._type == "Name" and node.iter.func.id == "sorted"
       and node.iter.args and #node.iter.args == 1
       and (not node.iter.keywords or #node.iter.keywords == 0) then
      local inner = node.iter.args[1]
      if inner._type == "Call" and inner.func and inner.func._type == "Attribute" and inner.func.attr == "items"
         and (not inner.args or #inner.args == 0) and (not inner.keywords or #inner.keywords == 0) then
        is_sorted_items = true
        sorted_dict_node = inner.func.value
      end
    end

    if is_sorted_items then
      local dict_tmp = self:lower_expr(sorted_dict_node)
      local keys_tmp = self:_new_tmp()
      self:_emit("CALL", {"_luthon_sorted_dict_keys", dict_tmp}, keys_tmp)
      local idx_tmp = self:_new_tmp()
      self:_emit("CONST", {0}, idx_tmp)
      local len_tmp = self:_new_tmp()
      self:_emit("CALL", {"_luthon_raw_len", keys_tmp}, len_tmp)
      local cond_lbl = self:_new_label("forcond")
      local body_lbl = self:_new_label("forbody")
      local end_lbl = self:_new_label("forend")
      table.insert(self._break_stack, end_lbl)
      table.insert(self._continue_stack, cond_lbl)
      self:_emit("JUMP", {cond_lbl})
      self._cur_block = self:_new_block(cond_lbl)
      local one_tmp = self:_new_tmp()
      self:_emit("CONST", {1}, one_tmp)
      self:_emit("BINOP", {"add", idx_tmp, one_tmp}, idx_tmp)
      local cmp_tmp = self:_new_tmp()
      self:_emit("CMP_DIRECT", {"gt", idx_tmp, len_tmp}, cmp_tmp)
      self:_emit("BRANCH", {cmp_tmp, end_lbl, body_lbl})
      self._cur_block = self:_new_block(body_lbl)
      local k_tmp = self:_new_tmp()
      self:_emit("SUBSCR_FAST_KEY", {keys_tmp, idx_tmp}, k_tmp)
      self:_emit("STORE", {_safe_var(node.target.elts[1].id), k_tmp})
      local v_tmp = self:_new_tmp()
      self:_emit("SUBSCR_FAST_KEY", {dict_tmp, k_tmp}, v_tmp)
      self:_emit("STORE", {_safe_var(node.target.elts[2].id), v_tmp})
      for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
      self:_emit("JUMP", {cond_lbl})
      if #self._break_stack > 0 then table.remove(self._break_stack) end
      if #self._continue_stack > 0 then table.remove(self._continue_stack) end
      self._cur_block = self:_new_block(end_lbl)
      return
    end

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
    local prev_try_loop_depth = {}
    for _, d in ipairs(self._try_loop_depth_stack) do table.insert(prev_try_loop_depth, d) end
    self._try_depth = 0
    self._try_loop_depth_stack = {}
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
    self._try_loop_depth_stack = prev_try_loop_depth

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

    -- Check for try: k = k.encode(...) except AttributeError: pass
    if node.body and #node.body == 1
       and node.body[1]._type == "Assign"
       and node.body[1].targets and #node.body[1].targets == 1
       and node.body[1].targets[1]._type == "Name"
       and node.body[1].value and node.body[1].value._type == "Call"
       and node.body[1].value.func and node.body[1].value.func._type == "Attribute" and node.body[1].value.func.attr == "encode"
       and node.body[1].value.func.value and node.body[1].value.func.value._type == "Name"
       and node.body[1].targets[1].id == node.body[1].value.func.value.id
       and handlers and #handlers == 1
       and (not handlers[1].type or (handlers[1].type._type == "Name" and (handlers[1].type.id == "AttributeError" or handlers[1].type.id == "Exception" or handlers[1].type.id == "BaseException")))
       and (not orelse or #orelse == 0)
       and (not finalbody or #finalbody == 0) then
      local all_pass = true
      for _, s in ipairs(handlers[1].body or {}) do
        if s._type ~= "Pass" then all_pass = false; break end
      end
      if all_pass then return end
    end
    if (#orelse == 0) and (#finalbody == 0) then
      local all_noop = true
      for _, s in ipairs(node.body or {}) do
        if s._type == "Pass" or (s._type == "Expr" and s.value and s.value._type == "Constant") or
           (s._type == "Assign" and s.targets and #s.targets == 1 and s.targets[1]._type == "Name" and s.value and s.value._type == "Name" and s.targets[1].id == s.value.id) then
          -- noop
        else
          all_noop = false
          break
        end
      end
      if all_noop then return end
    end

    local is_inet_pton = false
    local fam_node = nil
    local ip_node = nil
    if node.body and #node.body == 1
       and node.body[1]._type == "Expr" and node.body[1].value and node.body[1].value._type == "Call"
       and node.body[1].value.func and node.body[1].value.func._type == "Attribute" and node.body[1].value.func.attr == "inet_pton"
       and node.body[1].value.args and #node.body[1].value.args >= 2
       and #handlers == 1
       and (not handlers[1].type or (handlers[1].type._type == "Name" and (handlers[1].type.id == "OSError" or handlers[1].type.id == "Exception" or handlers[1].type.id == "error")))
       and handlers[1].body and #handlers[1].body == 1
       and handlers[1].body[1]._type == "Return" and handlers[1].body[1].value and handlers[1].body[1].value._type == "Constant" and handlers[1].body[1].value.value == false
       and #orelse == 1
       and orelse[1]._type == "Return" and orelse[1].value and orelse[1].value._type == "Constant" and orelse[1].value.value == true then
      is_inet_pton = true
      fam_node = node.body[1].value.args[1]
      ip_node = node.body[1].value.args[2]
    elseif node.body and #node.body == 2
       and node.body[1]._type == "Expr" and node.body[1].value and node.body[1].value._type == "Call"
       and node.body[1].value.func and node.body[1].value.func._type == "Attribute" and node.body[1].value.func.attr == "inet_pton"
       and node.body[1].value.args and #node.body[1].value.args >= 2
       and node.body[2]._type == "Return" and node.body[2].value and node.body[2].value._type == "Constant" and node.body[2].value.value == true
       and #handlers == 1
       and (not handlers[1].type or (handlers[1].type._type == "Name" and (handlers[1].type.id == "OSError" or handlers[1].type.id == "Exception" or handlers[1].type.id == "error")))
       and handlers[1].body and #handlers[1].body == 1
       and handlers[1].body[1]._type == "Return" and handlers[1].body[1].value and handlers[1].body[1].value._type == "Constant" and handlers[1].body[1].value.value == false
       and #orelse == 0 then
      is_inet_pton = true
      fam_node = node.body[1].value.args[1]
      ip_node = node.body[1].value.args[2]
    end

    if is_inet_pton then
      local fam_tmp = self:lower_expr(fam_node)
      local ip_tmp = self:lower_expr(ip_node)
      local chk_tmp = self:_new_tmp()
      self:_emit("CALL", {"_socket_mod.inet_pton_bool", fam_tmp, ip_tmp}, chk_tmp)
      self:_emit("RETURN", {chk_tmp})
      return
    end

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

    local outer_break = #self._break_stack > 0 and self._break_stack[#self._break_stack] or ""
    local outer_continue = #self._continue_stack > 0 and self._continue_stack[#self._continue_stack] or ""
    table.insert(self._try_loop_depth_stack, #self._break_stack)

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
      table.remove(self._try_loop_depth_stack)
      self:_emit("FINALLY_BEGIN", {}, self:_new_tmp())
      local finally_label = self:_new_label("finally")
      self._cur_block = self:_new_block(finally_label)
      for _, s in ipairs(finalbody) do
        self:lower_stmt(s)
      end
      self:_emit("FINALLY_END", {}, self:_new_tmp())
      local end_label = self:_new_label("end_try")
      self._cur_block = self:_new_block(end_label)
      self:_emit("TRY_UNWIND", {tostring(self._try_depth), outer_break, outer_continue})
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
    table.remove(self._try_loop_depth_stack)
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
    self:_emit("TRY_UNWIND", {tostring(self._try_depth), outer_break, outer_continue})
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
        local prev_try_loop_depth = {}
        for _, d in ipairs(self._try_loop_depth_stack or {}) do table.insert(prev_try_loop_depth, d) end
        self._try_depth = 0
        self._try_loop_depth_stack = {}
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
    self._try_loop_depth_stack = prev_try_loop_depth
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
      if self._try_depth > 0 and (#self._try_loop_depth_stack == 0 or #self._break_stack <= self._try_loop_depth_stack[#self._try_loop_depth_stack]) then
        self:_emit("TRY_BREAK", {self._break_stack[#self._break_stack]})
      else
        self:_emit("JUMP", {self._break_stack[#self._break_stack]})
      end
    end
  elseif t == "Continue" then
    if #self._continue_stack > 0 then
      if self._try_depth > 0 and (#self._try_loop_depth_stack == 0 or #self._continue_stack <= self._try_loop_depth_stack[#self._try_loop_depth_stack]) then
        self:_emit("TRY_CONTINUE", {self._continue_stack[#self._continue_stack]})
      else
        self:_emit("JUMP", {self._continue_stack[#self._continue_stack]})
      end
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

    local outer_break = #self._break_stack > 0 and self._break_stack[#self._break_stack] or ""
    local outer_continue = #self._continue_stack > 0 and self._continue_stack[#self._continue_stack] or ""
    table.insert(self._try_loop_depth_stack, #self._break_stack)
    self._try_depth = self._try_depth + #mgrs
    for _, s in ipairs(node.body or {}) do
      self:lower_stmt(s)
    end
    self._try_depth = self._try_depth - #mgrs
    table.remove(self._try_loop_depth_stack)

    for i = #mgrs, 1, -1 do
      self:_emit("WITH_END", {mgrs[i]})
    end
    self:_emit("TRY_UNWIND", {tostring(self._try_depth), outer_break, outer_continue})
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
    if node.value and node.value._type == "Call"
       and node.value.func and node.value.func._type == "Attribute" and node.value.func.attr == "partition"
       and node.value.args and #node.value.args == 1
       and (not node.value.keywords or #node.value.keywords == 0)
       and node.slice and node.slice._type == "Constant" and (node.slice.value == 0 or node.slice.value == 1 or node.slice.value == -3) then
      local s_tmp = self:lower_expr(node.value.func.value)
      local sep_tmp = self:lower_expr(node.value.args[1])
      local res = self:_new_tmp()
      self:_emit("CALL", {"_str_partition_head", s_tmp, sep_tmp}, res)
      return res
    end
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
      name = "_luthon_fast_type"
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
    local binop_str = node.op and (type(node.op) == "string" and node.op or node.op._type) or ""
    if (binop_str == "Mod" or binop_str == "%") and node.left and node.left._type == "Constant" and type(node.left.value) == "string" then
      local raw_fmt = _unquote(node.left.value)
      local elts = (node.right and (node.right._type == "Tuple" or node.right._type == "List")) and (node.right.elts or {}) or nil
      if elts then
        local res = self:_new_tmp()
        if raw_fmt == "%.*f %s" and #elts == 3 then
          local p = self:lower_expr(elts[1])
          local val = self:lower_expr(elts[2])
          local unit = self:lower_expr(elts[3])
          self:_emit("CALL", {"_str_mod_prec_s", p, val, unit}, res)
          return res
        elseif raw_fmt == "%.*f%%" and #elts == 2 then
          local p = self:lower_expr(elts[1])
          local val = self:lower_expr(elts[2])
          self:_emit("CALL", {"_str_mod_prec_pcnt", p, val}, res)
          return res
        elseif raw_fmt == "%d %s" and #elts == 2 then
          local d = self:lower_expr(elts[1])
          local s = self:lower_expr(elts[2])
          self:_emit("CALL", {"_str_mod_d_s", d, s}, res)
          return res
        end
        local fmt = self:lower_expr(node.left)
        local call_args = {"_str_mod_direct", fmt}
        for _, elt in ipairs(elts) do
          table.insert(call_args, self:lower_expr(elt))
        end
        self:_emit("CALL", call_args, res)
        return res
      else
        local fmt = self:lower_expr(node.left)
        local arg = self:lower_expr(node.right)
        local res = self:_new_tmp()
        self:_emit("CALL", {"_str_mod_single", fmt, arg}, res)
        return res
      end
    end
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
    local end_lbl = self:_new_label("bool_end")
    if op_name == "And" then
      for i, val_node in ipairs(node.values or {}) do
        local v_tmp = self:lower_expr(val_node)
        self:_emit("STORE", {result, v_tmp})
        if i < #node.values then
          self:_emit("BRANCH_FALSE", {v_tmp, end_lbl})
          local next_lbl = self:_new_label("and_eval")
          self._cur_block = self:_new_block(next_lbl)
        end
      end
    elseif op_name == "Or" then
      for i, val_node in ipairs(node.values or {}) do
        local v_tmp = self:lower_expr(val_node)
        self:_emit("STORE", {result, v_tmp})
        if i < #node.values then
          self:_emit("BRANCH_TRUE", {v_tmp, end_lbl})
          local next_lbl = self:_new_label("or_eval")
          self._cur_block = self:_new_block(next_lbl)
        end
      end
    end
    self._cur_block = self:_new_block(end_lbl)
    return result
  elseif t == "UnaryOp" then
    local v = self:lower_expr(node.operand)
    local res = self:_new_tmp()
    self:_emit("UNOP", {self:_unop(node.op), v}, res)
    return res
  elseif t == "Compare" then
    local ops = node.ops or {}
    local comparators = node.comparators or {}
    if #ops == 1 and #comparators == 1 then
      local op = ops[1]
      local op_str = type(op) == "string" and op or (op._type or "")
      if op_str == "in" or op_str == "In" or op_str == "notin" or op_str == "NotIn" or op_str == "not in" then
        local comp = comparators[1]
        if comp and (comp._type == "Tuple" or comp._type == "List") and comp.elts and #comp.elts <= 6 then
          local all_const = true
          for _, elt in ipairs(comp.elts) do
            if elt._type ~= "Constant" then all_const = false; break end
          end
          if all_const then
            local is_in = (op_str == "in" or op_str == "In")
            local l = self:lower_expr(node.left)
            local res = self:_new_tmp()
            if #comp.elts == 0 then
              self:_emit("CONST", {not is_in}, res)
              return res
            end
            local const_vals = {l}
            for _, elt in ipairs(comp.elts) do
              local v = elt.value
              if type(v) == "string" then v = _unquote(v) end
              table.insert(const_vals, v)
            end
            local op_name = is_in and "IN_UNROLL" or "NOT_IN_UNROLL"
            self:_emit(op_name, const_vals, res)
            return res
          end
        end
      end
    end
    local l = self:lower_expr(node.left)
    local ops = node.ops or {}
    local comparators = node.comparators or {}
    if #ops == 1 and #comparators == 1 then
      local left_num = _is_numeric_node(node.left)
      local right_num = _is_numeric_node(comparators[1])
      local op_name = self:_cmpop(ops[1])
      if (left_num or right_num) and (op_name == "lt" or op_name == "le" or op_name == "gt" or op_name == "ge" or op_name == "eq" or op_name == "ne" or op_name == "<" or op_name == "<=" or op_name == ">" or op_name == ">=" or op_name == "==" or op_name == "~=" or op_name == "!=") then
        local r = self:lower_expr(comparators[1])
        local cmp_res = self:_new_tmp()
        self:_emit("CMP_DIRECT", {op_name, l, r}, cmp_res)
        return cmp_res
      end
    end
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
    if node.func and node.func._type == "Name" and node.func.id == "int"
       and node.args and #node.args == 1
       and (not node.keywords or #node.keywords == 0) then
      local arg = self:lower_expr(node.args[1])
      local res = self:_new_tmp()
      self:_emit("CALL", {"_luthon_fast_int", arg}, res)
      return res
    end

    if node.func and node.func._type == "Name" and node.func.id == "str"
       and node.args and #node.args == 1
       and (not node.keywords or #node.keywords == 0) then
      if node.args[1]._type == "Call" and node.args[1].func and node.args[1].func._type == "Name" and node.args[1].func.id == "len"
         and node.args[1].args and #node.args[1].args == 1
         and (not node.args[1].keywords or #node.args[1].keywords == 0) then
        local arg = self:lower_expr(node.args[1].args[1])
        local res = self:_new_tmp()
        self:_emit("CALL", {"_luthon_str_len", arg}, res)
        return res
      end
      local arg = self:lower_expr(node.args[1])
      local res = self:_new_tmp()
      self:_emit("CALL", {"_luthon_str", arg}, res)
      return res
    end

    if node.func and node.func._type == "Attribute" and node.func.attr == "extend"
       and node.args and #node.args == 1
       and (node.args[1]._type == "Tuple" or node.args[1]._type == "List")
       and (not node.keywords or #node.keywords == 0) then
      local obj = self:lower_expr(node.func.value)
      local elts = node.args[1].elts or {}
      for _, elt in ipairs(elts) do
        local elt_tmp = self:lower_expr(elt)
        self:_emit("LIST_APPEND", {obj, elt_tmp})
      end
      local res = self:_new_tmp()
      self:_emit("CONST", {nil}, res)
      return res
    end

    if node.func and node.func._type == "Attribute" and node.func.attr == "append"
       and node.args and #node.args == 1
       and (not node.keywords or #node.keywords == 0) then
      local obj = self:lower_expr(node.func.value)
      local val = self:lower_expr(node.args[1])
      local res = self:_new_tmp()
      self:_emit("CALL", {"_luthon_fast_append", obj, val}, res)
      return res
    end

    local enc_val = (node.args and #node.args == 1 and node.args[1]._type == "Constant") and _unquote(node.args[1].value) or nil
    if node.func and node.func._type == "Attribute" and (node.func.attr == "encode" or node.func.attr == "decode")
       and ((not node.args or #node.args == 0) or (enc_val and (enc_val == "utf8" or enc_val == "utf-8" or enc_val == "ascii" or enc_val == "latin1" or enc_val == "latin-1")))
       and (not node.keywords or #node.keywords == 0) then
      return self:lower_expr(node.func.value)
    end

    if node.func and node.func._type == "Attribute" and node.func.attr == "join"
       and node.args and #node.args == 1
       and (not node.keywords or #node.keywords == 0) then
      local sep = self:lower_expr(node.func.value)
      local seq = self:lower_expr(node.args[1])
      local res = self:_new_tmp()
      self:_emit("CALL", {"_luthon_fast_join", sep, seq}, res)
      return res
    end

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
    local then_lbl = self:_new_label("ifexp_then")
    local else_lbl = self:_new_label("ifexp_else")
    local end_lbl = self:_new_label("ifexp_end")
    self:_emit("BRANCH", {cond, then_lbl, else_lbl})
    self._cur_block = self:_new_block(then_lbl)
    local a = self:lower_expr(node.body)
    self:_emit("STORE", {res, a})
    self:_emit("JUMP", {end_lbl})
    self._cur_block = self:_new_block(else_lbl)
    local b = self:lower_expr(node.orelse)
    self:_emit("STORE", {res, b})
    self:_emit("JUMP", {end_lbl})
    self._cur_block = self:_new_block(end_lbl)
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
    local prev_try_loop_depth = {}
    for _, d in ipairs(self._try_loop_depth_stack) do table.insert(prev_try_loop_depth, d) end
    self._try_depth = 0
    self._try_loop_depth_stack = {}
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
    self._try_loop_depth_stack = prev_try_loop_depth
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
      self:_emit("CALL", {"_luthon_str", res}, tmp)
      res = tmp
    end

    -- Concatenate remaining values
    for i = 2, #values do
      local val = self:lower_expr(values[i])
      if values[i]._type == "FormattedValue" then
        local tmp = self:_new_tmp()
        self:_emit("CALL", {"_luthon_str", val}, tmp)
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
