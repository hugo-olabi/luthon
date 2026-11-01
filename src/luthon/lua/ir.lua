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

function IRLowerer.new()
  local self = setmetatable({}, IRLowerer)
  self._tmp = 0
  self.module = Module.new("<module>")
  self._cur_fn = nil
  self._cur_block = nil
  self._label_counter = 0
  self._break_stack = {}
  self._continue_stack = {}
  self._try_depth = 0
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

function IRLowerer:_lower_stmt_impl(node)
  local t = node._type
  if t == "Expr" then
    self:lower_expr(node.value)
  elseif t == "Assign" then
    if node.targets and #node.targets > 0 and node.targets[1]._type == "Tuple" then
      -- Tuple unpacking: f, name = expr
      local val = self:lower_expr(node.value)
      for i, tgt in ipairs(node.targets[1].elts or {}) do
        if tgt._type == "Name" then
          local idx_tmp = self:_new_tmp()
          self:_emit("CONST", {i}, idx_tmp)
          local elem_tmp = self:_new_tmp()
          self:_emit("SUBSCR", {val, idx_tmp}, elem_tmp)
          self:_emit("STORE", {tgt.id, elem_tmp})
        end
      end
    else
      local val = self:lower_expr(node.value)
      for _, tgt in ipairs(node.targets or {}) do
        if tgt._type == "Name" then
          if self._cur_fn and self._cur_fn.cellvars and self._cur_fn.cellvars[tgt.id] then
            self:_emit("CELL_SET", {tgt.id, val})
          else
            self:_emit("STORE", {tgt.id, val})
          end
        elseif tgt._type == "Subscript" then
          local base = self:lower_expr(tgt.value)
          local sl = self:lower_expr(tgt.slice)
          self:_emit("STORE_SUBSCR", {base, sl, val})
        elseif tgt._type == "Attribute" then
          local obj = self:lower_expr(tgt.value)
          self:_emit("SET_ATTR", {obj, tgt.attr, val})
        end
      end
    end
  elseif t == "Delete" then
    -- del target -> set to nil (or delete attribute/item)
    for _, tgt in ipairs(node.targets or {}) do
      local nil_tmp = self:_new_tmp()
      self:_emit("CONST", {nil}, nil_tmp)
      if tgt._type == "Name" then
        self:_emit("STORE", {tgt.id, nil_tmp})
      elseif tgt._type == "Attribute" then
        local obj = self:lower_expr(tgt.value)
        self:_emit("SET_ATTR", {obj, tgt.attr, nil_tmp})
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
    if node.target._type == "Name" then
      self:_emit("STORE", {node.target.id, res})
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
    if #self._break_stack > 0 then table.remove(self._break_stack) end
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
      self:_emit("STORE", {node.target.id, nxt})
    end
    self:_emit("JUMP", {body_lbl})
    self._cur_block = self:_new_block(body_lbl)
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    self:_emit("JUMP", {cond_lbl})
    if #self._break_stack > 0 then table.remove(self._break_stack) end
    if #self._continue_stack > 0 then table.remove(self._continue_stack) end
    self._cur_block = self:_new_block(end_lbl)
  elseif t == "FunctionDef" then
    local fn = Function.new(node.name, {})
    for _, a in ipairs(node.args.args or {}) do table.insert(fn.params, a.arg) end
    -- upvalues from semantic scope if available
    local sc = node._scope
    if sc then
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
    for _, s in ipairs(node.body or {}) do self:lower_stmt(s) end
    if not node.body or node.body[#node.body]._type ~= "Return" then
      self:_emit("RETURN", {})
    end
    table.insert(self.module.functions, fn)
    -- Switch back to enclosing block before applying decorators
    self._cur_fn = prev_fn
    self._cur_block = prev_block
    -- Apply decorators (innermost first)
    for i = #node.decorator_list, 1, -1 do
      local dec = node.decorator_list[i]
      local dec_tmp = self:lower_expr(dec)
      local fn_tmp = self:_new_tmp()
      self:_emit("LOAD", {fn.name}, fn_tmp)
      local result_tmp = self:_new_tmp()
      self:_emit("CALL", {dec_tmp, fn_tmp}, result_tmp)
      self:_emit("STORE", {fn.name, result_tmp})
    end
  elseif t == "Import" then
    for _, alias in ipairs(node.names or {}) do
      local name = alias.asname or alias.name:match("([^%.]+)")
      self:_emit("IMPORT", {name, alias.name})
    end
  elseif t == "ImportFrom" then
    local mod = node.module or ""
    for _, alias in ipairs(node.names or {}) do
      local name = alias.asname or alias.name
      self:_emit("IMPORT_FROM", {name, mod, alias.name})
    end
  elseif t == "Try" then
    -- try/except/finally
    local try_label = self:_new_label("try")
    local try_block = self:_new_block(try_label)
    self._cur_block = try_block
    -- emit TRY_BEGIN marker
    self:_emit("TRY_BEGIN", {}, self:_new_tmp())
    -- lower try body
    self._try_depth = self._try_depth + 1
    for _, s in ipairs(node.body or {}) do
      self:lower_stmt(s)
    end
    self._try_depth = self._try_depth - 1
    -- end try block
    self:_emit("END_TRY", {}, self:_new_tmp())
    -- except handlers
    local handlers = node.handlers or {}
    local finally_label = self:_new_label("finally")
    local end_label = self:_new_label("end_try")
    local handler_blocks = {}
    for i, h in ipairs(handlers) do
      local handler_lbl = self:_new_label("except")
      table.insert(handler_blocks, handler_lbl)
      self._cur_block = self:_new_block(handler_lbl)
      -- bind exception variable
      if h.name then
        self:_emit("STORE", {h.name, "_exc"})
      end
      for _, s in ipairs(h.body or {}) do
        self:lower_stmt(s)
      end
      self:_emit("END_CATCH", {}, self:_new_tmp())
    end
    -- Mark end of all exception handlers: re-raise if none matched
    self:_emit("END_ALL_CATCH", {}, self:_new_tmp())
    -- else clause (not supported yet)
    if node.orelse and #node.orelse > 0 then
      for _, s in ipairs(node.orelse or {}) do
        self:lower_stmt(s)
      end
    end
    -- finally block
    if node.finalbody and #node.finalbody > 0 then
      self._cur_block = self:_new_block(finally_label)
      for _, s in ipairs(node.finalbody or {}) do
        self:lower_stmt(s)
      end
    end
    self._cur_block = self:_new_block(end_label)
    self:_emit("TRY_UNWIND", {})
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
        if dec.func._type == "Name" and dec.func.id == "dataclass" then
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
    for _, stmt in ipairs(node.body or {}) do
      if stmt._type == "FunctionDef" then
        if stmt.name == "__init__" then has_init = true end
        if stmt.name == "__repr__" then has_repr = true end
        if stmt.name == "__eq__" then has_eq = true end
        local fn = Function.new(node.name .. "." .. stmt.name, {})
        for _, a in ipairs(stmt.args.args or {}) do table.insert(fn.params, a.arg) end
        local prev_fn = self._cur_fn
        local prev_block = self._cur_block
        self._cur_fn = fn
        local b = Block.new("entry")
        table.insert(fn.blocks, b)
        self._cur_block = b
        for _, s2 in ipairs(stmt.body or {}) do self:lower_stmt(s2) end
        if not stmt.body or stmt.body[#stmt.body]._type ~= "Return" then
          self:_emit("RETURN", {})
        end
        table.insert(self.module.functions, fn)
        self._cur_fn = prev_fn
        self._cur_block = prev_block
      end
    end

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
      self:_emit("CALL", {"error", "nil"}, self:_new_tmp())
    end
  elseif t == "With" then
    -- with statement: enter context, run body, exit context
    local aliases = {}
    for i, item in ipairs(node.items or {}) do
      local ctx_tmp = self:lower_expr(item.context_expr)
      local alias
      if item.optional_vars then
        alias = self:lower_expr(item.optional_vars)
      else
        alias = self:_new_tmp()
      end
      table.insert(aliases, alias)
      self:_emit("STORE", {alias, ctx_tmp})
      -- Call __enter__(alias) if method exists
      local enter_tmp = self:_new_tmp()
      self:_emit("GET_ATTR", {alias, "__enter__"}, enter_tmp)
      local enter_lbl = self:_new_label("with_enter")
      local end_enter_lbl = self:_new_label("with_enter_end")
      self:_emit("BRANCH", {enter_tmp, enter_lbl, end_enter_lbl})
      self._cur_block = self:_new_block(enter_lbl)
      self:_emit("DO", {})
      self:_emit("CALL", {enter_tmp, alias}, self:_new_tmp())
      self:_emit("END", {})
      self._cur_block = self:_new_block(end_enter_lbl)
    end
    -- body
    for _, s in ipairs(node.body or {}) do
      self:lower_stmt(s)
    end
    -- __exit__ for each context manager (reverse order)
    for i = #aliases, 1, -1 do
      local alias = aliases[i]
      local exit_tmp = self:_new_tmp()
      self:_emit("GET_ATTR", {alias, "__exit__"}, exit_tmp)
      local exit_lbl = self:_new_label("with_exit")
      local end_exit_lbl = self:_new_label("with_exit_end")
      self:_emit("BRANCH", {exit_tmp, exit_lbl, end_exit_lbl})
      self._cur_block = self:_new_block(exit_lbl)
      self:_emit("DO", {})
      self:_emit("CALL", {exit_tmp, alias}, self:_new_tmp())
      self:_emit("END", {})
      self._cur_block = self:_new_block(end_exit_lbl)
    end
  else
    -- fallback: record unsupported
    self:_emit("NOP", {type(node).__name__ or type(node)})
  end
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
      self:_emit("CONST", {v}, res)
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
    self:_emit("GET_ATTR", {obj, node.attr}, res)
    return res
  elseif t == "Name" then
    if self._cur_fn and self._cur_fn.cellvars and self._cur_fn.cellvars[node.id] then
      local res = self:_new_tmp()
      self:_emit("CELL_GET", {node.id}, res)
      return res
    end
    local res = self:_new_tmp()
    self:_emit("LOAD", {node.id}, res)
    return res
  elseif t == "BinOp" and node.left._type == "List" and node.op._type == "Mult" then
    local l = self:lower_expr(node.left)
    local r = self:lower_expr(node.right)
    local res = self:_new_tmp()
    self:_emit("LIST_REPEAT", {l, r}, res)
    return res
  elseif t == "BinOp" then
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
    if node.func._type == "Attribute" then
      -- module-level / builtin functions: don't prepend self
      -- determine root name of attribute chain
      local root = node.func.value
      while root._type == "Attribute" do root = root.value end
      if root._type == "Name" and BUILTIN_MODULES[root.id] then
        local fn = self:lower_expr(node.func)
        local args = {}
        for _, a in ipairs(node.args or {}) do table.insert(args, self:lower_expr(a)) end
        local kw_table = self:_lower_call_keywords(node)
        return self:_emit_call(fn, args, kw_table)
      end
      local obj = self:lower_expr(node.func.value)
      local meth = self:_new_tmp()
      self:_emit("GET_ATTR", {obj, node.func.attr}, meth)
      local args = {obj}
      for _, a in ipairs(node.args or {}) do table.insert(args, self:lower_expr(a)) end
      local kw_table = self:_lower_call_keywords(node)
      return self:_emit_call(meth, args, kw_table)
    end
    local fn = self:lower_expr(node.func)
    local args = {}
    for _, a in ipairs(node.args or {}) do table.insert(args, self:lower_expr(a)) end
    local kw_table = self:_lower_call_keywords(node)
    return self:_emit_call(fn, args, kw_table)
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
    local res = self:_new_tmp()
    local els = {}
    for _, e in ipairs(node.elts or {}) do table.insert(els, self:lower_expr(e)) end
    self:_emit("MAKE_LIST", els, res)
    return res
  elseif t == "Tuple" then
    local res = self:_new_tmp()
    local els = {}
    for _, e in ipairs(node.elts or {}) do table.insert(els, self:lower_expr(e)) end
    self:_emit("MAKE_TUPLE", els, res)
    return res
  elseif t == "ListComp" then
    -- basic: build list from first generator
    local res = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, res)
    local gen = node.generators[1]
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(gen.iter)}, iter_tmp)
    local loop_lbl = self:_new_label("lcomp")
    local body_lbl = self:_new_label("lbody")
    local end_lbl = self:_new_label("lend")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    self:_emit("BRANCH_NONE", {nxt, end_lbl})
    -- bind target
    if gen.target._type == "Name" then
      self:_emit("STORE", {gen.target.id, nxt})
    end
    -- condition
    if gen.ifs and #gen.ifs > 0 then
      local cond = self:lower_expr(gen.ifs[1])
      self:_emit("BRANCH", {cond, body_lbl, loop_lbl})
      self._cur_block = self:_new_block(body_lbl)
    end
    local val = self:lower_expr(node.elt)
    self:_emit("LIST_APPEND", {res, val})
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "SetComp" then
    -- {elt for target in iter [if cond]} -> set built via SET_ADD
    local res = self:_new_tmp()
    self:_emit("MAKE_SET", {}, res)
    local gen = node.generators[1]
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(gen.iter)}, iter_tmp)
    local loop_lbl = self:_new_label("scomp")
    local body_lbl = self:_new_label("sbody")
    local end_lbl = self:_new_label("send")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    self:_emit("BRANCH_NONE", {nxt, end_lbl})
    if gen.target._type == "Name" then
      self:_emit("STORE", {gen.target.id, nxt})
    end
    if gen.ifs and #gen.ifs > 0 then
      local cond = self:lower_expr(gen.ifs[1])
      self:_emit("BRANCH", {cond, body_lbl, loop_lbl})
      self._cur_block = self:_new_block(body_lbl)
    end
    local val = self:lower_expr(node.elt)
    self:_emit("SET_ADD", {res, val})
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "DictComp" then
    -- {key: value for target in iter [if cond]} -> dict built via DICT_SET
    local res = self:_new_tmp()
    self:_emit("MAKE_DICT", {}, res)
    local gen = node.generators[1]
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(gen.iter)}, iter_tmp)
    local loop_lbl = self:_new_label("dcomp")
    local body_lbl = self:_new_label("dbody")
    local end_lbl = self:_new_label("dend")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    self:_emit("BRANCH_NONE", {nxt, end_lbl})
    if gen.target._type == "Name" then
      self:_emit("STORE", {gen.target.id, nxt})
    end
    if gen.ifs and #gen.ifs > 0 then
      local cond = self:lower_expr(gen.ifs[1])
      self:_emit("BRANCH", {cond, body_lbl, loop_lbl})
      self._cur_block = self:_new_block(body_lbl)
    end
    local key = self:lower_expr(node.key)
    local value = self:lower_expr(node.value)
    self:_emit("DICT_SET", {res, key, value})
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(end_lbl)
    return res
  elseif t == "GeneratorExp" then
    -- (elt for target in iter [if cond]) -> eager list, like ListComp
    local res = self:_new_tmp()
    self:_emit("MAKE_LIST", {}, res)
    local gen = node.generators[1]
    local iter_tmp = self:_new_tmp()
    self:_emit("CALL", {"iter", self:lower_expr(gen.iter)}, iter_tmp)
    local loop_lbl = self:_new_label("gen")
    local body_lbl = self:_new_label("genbody")
    local end_lbl = self:_new_label("genend")
    self:_emit("JUMP", {loop_lbl})
    self._cur_block = self:_new_block(loop_lbl)
    local nxt = self:_new_tmp()
    self:_emit("NEXT", {iter_tmp}, nxt)
    self:_emit("BRANCH_NONE", {nxt, end_lbl})
    if gen.target._type == "Name" then
      self:_emit("STORE", {gen.target.id, nxt})
    end
    if gen.ifs and #gen.ifs > 0 then
      local cond = self:lower_expr(gen.ifs[1])
      self:_emit("BRANCH", {cond, body_lbl, loop_lbl})
      self._cur_block = self:_new_block(body_lbl)
    end
    local val = self:lower_expr(node.elt)
    self:_emit("LIST_APPEND", {res, val})
    self:_emit("JUMP", {loop_lbl})
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
    elseif type(node.args) == "table" then
      for _, a in ipairs(node.args) do table.insert(args, type(a) == "table" and (a.arg or a.id) or tostring(a)) end
    end
    -- Create a nested function for the lambda body
    local lambda_name = "_lambda_" .. self._tmp
    local fn = Function.new(lambda_name, args)
    local prev_fn = self._cur_fn
    local prev_block = self._cur_block
    self._cur_fn = fn
    local b = Block.new("entry")
    table.insert(fn.blocks, b)
    self._cur_block = b
    local body_tmp = self:lower_expr(node.body)
    self:_emit("RETURN", {body_tmp})
    table.insert(self.module.functions, fn)
    self._cur_fn = prev_fn
    self._cur_block = prev_block
    -- Emit MAKE_FUNCTION that references the nested function
    local res = self:_new_tmp()
    self:_emit("MAKE_FUNCTION", {fn.name}, res)
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
    local key_tmp = self:_new_tmp()
    self:_emit("CONST", {kw.arg}, key_tmp)
    local val_tmp = self:lower_expr(kw.value)
    self:_emit("STORE_SUBSCR", {kw_table, key_tmp, val_tmp})
  end
  return kw_table
end

function IRLowerer:_emit_call(fn, args, kw_table)
  local all_args = args
  if kw_table then
    table.insert(all_args, kw_table)
  end
  local t = self:_new_tmp()
  self:_emit("CALL", {fn, unpack(all_args)}, t)
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
