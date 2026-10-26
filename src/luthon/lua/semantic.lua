--[[
  Luthon Semantic Analyzer (pure Lua)
  ====================================
  Scoped symbol tables and name resolution for Luthon's Lua-based AST.
  Works with AST nodes produced by src/luthon/lua/parser.lua.

  Resolves every Name reference to a binding and classifies it as:
    - 'local'   : defined in the current function scope
    - 'global'  : module-level / builtin
    - 'free'    : captured from an enclosing function (upvalue)
    - 'cell'    : local that is captured by a nested function
    - 'param'   : function parameter

  Nonlocal declarations promote a name to a free variable of the enclosing scope.
--]]

local M = {}

------------------------------------------------------------------------------
-- Dataclass-like constructors
------------------------------------------------------------------------------

local function new_scope(kind, name, parent)
  return {
    kind = kind,
    name = name,
    parent = parent,
    locals = {},      -- name -> Symbol
    globals = {},     -- set of name strings
    nonlocals = {},   -- set of name strings
    freevars = {},    -- set of name strings (captured from enclosing)
    cellvars = {},    -- set of name strings (captured by nested)
    children = {},    -- list of child Scope tables
    future_features = {}, -- set of __future__ feature strings
  }
end

local function new_symbol(name, kind, scope, node)
  return {
    name = name,
    kind = kind,
    scope = scope,
    node = node,
  }
end

------------------------------------------------------------------------------
-- Builtins and future features
------------------------------------------------------------------------------

local BUILTINS = {
  ["abs"] = true, ["all"] = true, ["any"] = true, ["bool"] = true,
  ["dict"] = true, ["enumerate"] = true, ["float"] = true, ["int"] = true,
  ["len"] = true, ["list"] = true, ["max"] = true, ["min"] = true,
  ["range"] = true, ["set"] = true, ["sorted"] = true, ["str"] = true,
  ["sum"] = true, ["tuple"] = true, ["zip"] = true,
  ["True"] = true, ["False"] = true, ["None"] = true, ["print"] = true,
}

local FUTURE_FEATURES = {
  ["annotations"] = true, ["division"] = true, ["absolute_import"] = true,
  ["print_function"] = true, ["unicode_literals"] = true,
  ["generator_stop"] = true, ["nested_scopes"] = true,
  ["with_statement"] = true, ["generators"] = true,
}

------------------------------------------------------------------------------
-- SemanticAnalyzer
------------------------------------------------------------------------------

local SemanticAnalyzer = {}
SemanticAnalyzer.__index = SemanticAnalyzer

function SemanticAnalyzer.new()
  local self = setmetatable({}, SemanticAnalyzer)
  self.root = new_scope("module", "<module>", nil)
  self._stack = { self.root }
  self.errors = {}
  return self
end

function SemanticAnalyzer:current()
  return self._stack[#self._stack]
end

function SemanticAnalyzer:_push(s)
  s.parent = self:current()
  table.insert(self:current().children, s)
  table.insert(self._stack, s)
end

function SemanticAnalyzer:_pop()
  table.remove(self._stack)
end

function SemanticAnalyzer:_module()
  local s = self:current()
  while s.parent ~= nil do
    s = s.parent
  end
  return s
end

function SemanticAnalyzer:analyze(source)
  local parser = dofile("src/luthon/lua/parser.lua")
local tree = parser.parse(source)
  self:visit(tree)
  self:_resolve_up(self.root)
  return self.root
end

------------------------------------------------------------------------------
-- Scope helpers
------------------------------------------------------------------------------

local function scope_define(scope, name, kind, node)
  local sym = new_symbol(name, kind, scope, node)
  scope.locals[name] = sym
  return sym
end

------------------------------------------------------------------------------
-- Node visitors
------------------------------------------------------------------------------

function SemanticAnalyzer:visit(node)
  if node == nil then return end
  local t = node._type
  if t == "Module" then return self:visit_Module(node)
  elseif t == "FunctionDef" then return self:visit_FunctionDef(node)
  elseif t == "AsyncFunctionDef" then return self:visit_AsyncFunctionDef(node)
  elseif t == "Lambda" then return self:visit_Lambda(node)
  elseif t == "ClassDef" then return self:visit_ClassDef(node)
  elseif t == "ListComp" then return self:_comp(node)
  elseif t == "SetComp" then return self:_comp(node)
  elseif t == "DictComp" then return self:_comp(node)
  elseif t == "GeneratorExp" then return self:_comp(node)
  elseif t == "Assign" then return self:visit_Assign(node)
  elseif t == "AnnAssign" then return self:visit_AnnAssign(node)
  elseif t == "AugAssign" then return self:visit_AugAssign(node)
  elseif t == "For" then return self:visit_For(node)
  elseif t == "While" then return self:visit_While(node)
  elseif t == "If" then return self:visit_If(node)
  elseif t == "With" then return self:visit_With(node)
  elseif t == "Try" then return self:visit_Try(node)
  elseif t == "Global" then return self:visit_Global(node)
  elseif t == "Nonlocal" then return self:visit_Nonlocal(node)
  elseif t == "Import" then return self:visit_Import(node)
  elseif t == "ImportFrom" then return self:visit_ImportFrom(node)
  elseif t == "Expr" then return self:visit_Expr(node)
  elseif t == "Return" then return self:visit_Return(node)
  elseif t == "Raise" then return self:visit_Raise(node)
  elseif t == "Assert" then return self:visit_Assert(node)
  elseif t == "Delete" then return self:visit_Delete(node)
  elseif t == "Name" then return self:visit_Name(node)
  else
    self:generic_visit(node)
  end
end

function SemanticAnalyzer:visit_Module(node)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_FunctionDef(node)
  local scope = new_scope("function", node.name, nil)
  -- Bind function name in enclosing scope
  scope_define(self:current(), node.name, "local", node)
  local args = node.args or {}
  for _, a in ipairs(args.posonlyargs or {}) do
    scope_define(scope, a.arg, "param", a)
  end
  for _, a in ipairs(args.args or {}) do
    scope_define(scope, a.arg, "param", a)
  end
  for _, a in ipairs(args.kwonlyargs or {}) do
    scope_define(scope, a.arg, "param", a)
  end
  if args.vararg then
    scope_define(scope, args.vararg.arg, "param", args.vararg)
  end
  if args.kwarg then
    scope_define(scope, args.kwarg.arg, "param", args.kwarg)
  end
  self:_push(scope)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  self:_pop()
  node._scope = scope
end

function SemanticAnalyzer:visit_AsyncFunctionDef(node)
  self:visit_FunctionDef(node)
end

function SemanticAnalyzer:visit_Lambda(node)
  local scope = new_scope("function", "<lambda>", nil)
  local args = node.args or {}
  for _, a in ipairs(args.args or {}) do
    scope_define(scope, a.arg, "param", a)
  end
  if args.vararg then
    scope_define(scope, args.vararg.arg, "param", args.vararg)
  end
  if args.kwarg then
    scope_define(scope, args.kwarg.arg, "param", args.kwarg)
  end
  self:_push(scope)
  self:visit(node.body)
  self:_pop()
  node._scope = scope
end

function SemanticAnalyzer:visit_ClassDef(node)
  local scope = new_scope("class", node.name, nil)
  -- Bind class name in enclosing scope
  scope_define(self:current(), node.name, "local", node)
  self:_push(scope)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  self:_pop()
  node._scope = scope
end

function SemanticAnalyzer:_comp(node)
  local scope = new_scope("comprehension", "<comp>", nil)
  self:_push(scope)
  for _, gen in ipairs(node.generators or {}) do
    self:_bind_store(gen.target)
    self:visit(gen.iter)
    for _, c in ipairs(gen.ifs or {}) do
      self:visit(c)
    end
  end
  if node.elt then self:visit(node.elt) end
  if node.key then self:visit(node.key) end
  if node.value then self:visit(node.value) end
  self:_pop()
  node._scope = scope
end

function SemanticAnalyzer:visit_Assign(node)
  for _, t in ipairs(node.targets or {}) do
    self:_bind_store(t)
  end
  self:visit(node.value)
end

function SemanticAnalyzer:visit_AnnAssign(node)
  if node.target ~= nil then
    self:_bind_store(node.target)
  end
  if node.value ~= nil then
    self:visit(node.value)
  end
end

function SemanticAnalyzer:visit_AugAssign(node)
  self:visit(node.target)
  self:visit(node.value)
end

function SemanticAnalyzer:visit_For(node)
  self:_bind_store(node.target)
  self:visit(node.iter)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  for _, s in ipairs(node.orelse or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_While(node)
  self:visit(node.test)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  for _, s in ipairs(node.orelse or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_If(node)
  self:visit(node.test)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  for _, s in ipairs(node.orelse or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_With(node)
  for _, item in ipairs(node.items or {}) do
    self:visit(item.context_expr)
    if item.optional_vars ~= nil then
      self:_bind_store(item.optional_vars)
    end
  end
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_Try(node)
  for _, s in ipairs(node.body or {}) do
    self:visit(s)
  end
  for _, h in ipairs(node.handlers or {}) do
    if h.name then
      scope_define(self:current(), h.name, "local", h)
    end
    for _, s in ipairs(h.body or {}) do
      self:visit(s)
    end
  end
  for _, s in ipairs(node.orelse or {}) do
    self:visit(s)
  end
  for _, s in ipairs(node.finalbody or {}) do
    self:visit(s)
  end
end

function SemanticAnalyzer:visit_Global(node)
  for _, n in ipairs(node.names or {}) do
    self:current().globals[n] = true
  end
end

function SemanticAnalyzer:visit_Nonlocal(node)
  for _, n in ipairs(node.names or {}) do
    self:current().nonlocals[n] = true
  end
end

function SemanticAnalyzer:visit_Import(node)
  for _, n in ipairs(node.names or {}) do
    local alias = n.asname or n.name:match("([^%.]+)")
    scope_define(self:current(), alias, "local", n)
  end
end

function SemanticAnalyzer:visit_ImportFrom(node)
  if node.module == "__future__" then
    -- Record __future__ features on the root (module) scope
    local root = self:_module()
    for _, n in ipairs(node.names or {}) do
      if FUTURE_FEATURES[n.name] then
        root.future_features[n.name] = true
      end
    end
    return
  end
  for _, n in ipairs(node.names or {}) do
    local alias = n.asname or n.name
    scope_define(self:current(), alias, "local", n)
  end
end

function SemanticAnalyzer:visit_Expr(node)
  self:visit(node.value)
end

function SemanticAnalyzer:visit_Return(node)
  if node.value ~= nil then
    self:visit(node.value)
  end
end

function SemanticAnalyzer:visit_Raise(node)
  if node.exc ~= nil then
    self:visit(node.exc)
  end
end

function SemanticAnalyzer:visit_Assert(node)
  self:visit(node.test)
  if node.msg ~= nil then
    self:visit(node.msg)
  end
end

function SemanticAnalyzer:visit_Delete(node)
  for _, t in ipairs(node.targets or {}) do
    self:visit(t)
  end
end

function SemanticAnalyzer:visit_Name(node)
  local name = node.id
  -- Always treat as Load; binding (Store) is handled by statement visitors
  node._binding = self:_resolve(name, node)
end

function SemanticAnalyzer:_bind_store(node)
  if node._type == "Name" then
    local name = node.id
    if not self:current().globals[name] and not self:current().nonlocals[name] then
      if not self:current().locals[name] then
        scope_define(self:current(), name, "local", node)
      end
    end
    node._binding = self:current().locals[name]
  elseif node._type == "Tuple" or node._type == "List" then
    for _, e in ipairs(node.elts or {}) do
      self:_bind_store(e)
    end
  elseif node._type == "Subscript" then
    self:visit(node.value)
    self:visit(node.slice)
  elseif node._type == "Attribute" then
    self:visit(node.value)
  end
end

function SemanticAnalyzer:_resolve(name, node)
  local scope = self:current()
  if scope.globals[name] then
    local root = self:_module()
    if not root.locals[name] then
      scope_define(root, name, "global", node)
    end
    return root.locals[name]
  end
  if scope.nonlocals[name] then
    local s = scope.parent
    while s ~= nil do
      if s.locals[name] then
        s.cellvars[name] = true
        scope.freevars[name] = true
        return s.locals[name]
      end
      s = s.parent
    end
    table.insert(self.errors, "nonlocal '" .. name .. "' not found")
    return nil
  end
  local s = scope
  local first = true
  while s ~= nil do
    if s.locals[name] then
      if s ~= scope then
        scope.freevars[name] = true
        s.cellvars[name] = true
      end
      return s.locals[name]
    end
    if s.globals[name] then
      local root = self:_module()
      if not root.locals[name] then
        scope_define(root, name, "global", node)
      end
      return root.locals[name]
    end
    s = s.parent
    first = false
  end
  if BUILTINS[name] then
    local root = self:_module()
    if not root.locals[name] then
      scope_define(root, name, "global", node)
    end
    return root.locals[name]
  end
  local root = self:_module()
  if not root.locals[name] then
    scope_define(root, name, "global", node)
  end
  return root.locals[name]
end

function SemanticAnalyzer:_bind_store(node)
  if node._type == "Name" then
    local name = node.id
    if not self:current().globals[name] and not self:current().nonlocals[name] then
      if not self:current().locals[name] then
        scope_define(self:current(), name, "local", node)
      end
    end
    node._binding = self:current().locals[name]
  elseif node._type == "Tuple" or node._type == "List" then
    for _, e in ipairs(node.elts or {}) do
      self:_bind_store(e)
    end
  elseif node._type == "Subscript" then
    self:visit(node.value)
    self:visit(node.slice)
  elseif node._type == "Attribute" then
    self:visit(node.value)
  end
end

function SemanticAnalyzer:_resolve_up(scope)
  for _, child in ipairs(scope.children or {}) do
    self:_resolve_up(child)
    for fv in pairs(child.freevars or {}) do
      if scope.locals[fv] then
        scope.cellvars[fv] = true
      end
    end  end
  if scope.parent ~= nil then
    for fv in pairs(scope.freevars or {}) do
      if scope.parent.locals[fv] then
        scope.parent.cellvars[fv] = true
      end
    end
  end
end

function SemanticAnalyzer:generic_visit(node)
  -- For unknown node types, try to visit common child fields
  if type(node) ~= "table" then return end
  -- Don't recurse into metadata fields
  local skip = {_type=true, lineno=true, col_offset=true, _binding=true, _scope=true}
  for k, v in pairs(node) do
    if not skip[k] then
      if type(v) == "table" then
        if v._type then
          self:visit(v)
        else
          -- Could be a list of nodes
          for _, item in ipairs(v) do
            if type(item) == "table" and item._type then
              self:visit(item)
            end
          end
        end
      end
    end
  end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function M.analyze(source)
  local a = SemanticAnalyzer.new()
  return a:analyze(source)
end

function M.analyze_file(path)
  local f = io.open(path, "r")
  if not f then error("Cannot open file: " .. path) end
  local source = f:read("*a")
  f:close()
  local a = SemanticAnalyzer.new()
  return a:analyze(source)
end

function M.future_features(source)
  local root = M.analyze(source)
  local result = {}
  for k in pairs(root.future_features or {}) do
    table.insert(result, k)
  end
  return result
end

M.SemanticAnalyzer = SemanticAnalyzer
M.Scope = Scope
M.Symbol = Symbol

return M
