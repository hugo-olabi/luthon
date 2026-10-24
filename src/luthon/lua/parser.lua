--[[
  Luthon Python Parser (pure Lua)
  ===============================
  A recursive-descent parser for a subset of Python, producing AST nodes
  that match Luthon's IR lowerer input expectations.

  Grammar (subset):
    module       := stmt*
    stmt         := assign | aug_assign | ann_assign | if_stmt | while_stmt
                  | for_stmt | with_stmt | try_stmt | return_stmt | raise_stmt
                  | assert_stmt | delete_stmt | import_stmt | expr_stmt
                  | pass_stmt | break_stmt | continue_stmt | global_stmt
                  | nonlocal_stmt | func_def | class_def | suite
    suite        := NEWLINE INDENT stmt+ DEDENT | simple_stmt
    expr         := bool_op | named_expr
    bool_op      := or_test
    or_test      := and_test (or and_test)*
    and_test     := not_test (and not_test)*
    not_test     := not not_test | comparison
    comparison   := arith_expr (cmpop arith_expr)*
    arith_expr   := term ((add|sub) term)*
    term         := factor ((mul|div|mod|floor_div) factor)*
    factor       := (add|sub|invert) factor | power
    power        := atom (pow factor)? | atom
    atom         := constant | name | lambda | display | grouped | yield
                  | subscript | attribute | call | slice_expr
    display      := list_display | dict_display | set_display | genexp
    simple_stmt  := small_stmt (';' small_stmt)* [NEWLINE]
    small_stmt   := expr_stmt | del_stmt | pass_stmt | flow_stmt
                  | import_stmt | global_stmt | nonlocal_stmt | assert_stmt
    flow_stmt    := break_stmt | continue_stmt | return_stmt | raise_stmt
]]--

local parser = {}

------------------------------------------------------------------------------
-- Token types
------------------------------------------------------------------------------
local TT = {
  NAME       = "NAME",
  NUMBER     = "NUMBER",
  STRING     = "STRING",
  OP         = "OP",
  NEWLINE    = "NEWLINE",
  NL         = "NL",            -- non-logical newline (inside parens, etc.)
  INDENT     = "INDENT",
  DEDENT     = "DEDENT",
  EOF        = "EOF",
  COMMENT    = "COMMENT",
  ENCODING   = "ENCODING",
}

-- Operators (multi-char first, then single-char)
local OPS_MULTI = {
  ["=="] = "Eq", ["!="] = "NotEq", ["<="] = "LtE", [">="] = "GtE",
  ["<<"] = "LShift", [">>"] = "RShift", ["**"] = "Pow",
  ["+="] = "Add", ["-="] = "Sub", ["*="] = "Mult", ["/="] = "Div",
  ["%="] = "Mod", ["&="] = "BitAnd", ["|="] = "BitOr", ["^="] = "BitXor",
  ["//="] = "FloorDiv", ["@="] = "MatMult",
  ["@"] = "MatMult", ["->"] = "Arrow", [":="] = "ColonEq",
}
local OPS_SINGLE = {
  ["("] = "Lparen", [")"] = "Rparen", ["["] = "Lbracket", ["]"] = "Rbracket",
  ["{"] = "Lbrace", ["}"] = "Rbrace", [","] = "Comma", ["."] = "Dot",
  [";"] = "Semi", [":"] = "Colon", ["@"] = "At", ["="] = "Assign",
  ["+"] = "Add", ["-"] = "Sub", ["*"] = "Mult", ["/"] = "Div",
  ["%"] = "Mod", ["<"] = "Lt", [">"] = "Gt", ["|"] = "BitOr",
  ["^"] = "BitXor", ["&"] = "BitAnd", ["~"] = "Invert", ["!"] = "Not",
}

-- Python keywords
local KEYWORDS = {
  ["and"] = true, ["as"] = true, ["assert"] = true, ["async"] = true,
  ["await"] = true, ["break"] = true, ["class"] = true, ["continue"] = true,
  ["def"] = true, ["del"] = true, ["elif"] = true, ["else"] = true,
  ["except"] = true, ["finally"] = true, ["for"] = true, ["from"] = true,
  ["global"] = true, ["if"] = true, ["import"] = true, ["in"] = true,
  ["is"] = true, ["lambda"] = true, ["nonlocal"] = true, ["not"] = true,
  ["or"] = true, ["pass"] = true, ["raise"] = true, ["return"] = true,
  ["try"] = true, ["while"] = true, ["with"] = true, ["yield"] = true,
  ["True"] = true, ["False"] = true, ["None"] = true,
}

------------------------------------------------------------------------------
-- Tokenizer / Lexer
------------------------------------------------------------------------------
local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(source)
  local self = setmetatable({}, Lexer)
  self.src = source
  self.pos = 1
  self.line = 1
  self.col = 0
  self.tokens = {}
  self.indent_stack = {0}
  self.indent_pending = nil
  self.newline_pending = false
  self.in_paren = 0
  self.at_line_start = true
  self:tokenize()
  return self
end

function Lexer:peek(n)
  n = n or 0
  return self.src:sub(self.pos + n, self.pos + n)
end

function Lexer:advance(n)
  n = n or 1
  for i = 1, n do
    local c = self.src:sub(self.pos, self.pos)
    if c == "\n" then
      self.line = self.line + 1
      self.col = 0
    else
      self.col = self.col + 1
    end
    self.pos = self.pos + 1
  end
end

function Lexer:skip_whitespace()
  while true do
    local c = self:peek()
    if c == " " or c == "\t" then
      self:advance()
    elseif c == "\r" then
      if self:peek(1) == "\n" then self:advance(2) else self:advance() end
    else
      break
    end
  end
end

function Lexer:read_number()
  local start = self.pos
  local c = self:peek()
  if c == "0" then
    local n2 = self:peek(1)
    if n2 == "x" or n2 == "X" then
      self:advance(2)
      while self:peek():match("[%x]") do self:advance() end
    elseif n2 == "o" or n2 == "O" then
      self:advance(2)
      while self:peek():match("[0-7]") do self:advance() end
    elseif n2 == "b" or n2 == "B" then
      self:advance(2)
      while self:peek():match("[01]") do self:advance() end
    else
      self:advance()
      while self:peek():match("[0-9]") do self:advance() end
      if self:peek() == "." then
        self:advance()
        while self:peek():match("[0-9]") do self:advance() end
      end
    end
  else
    self:advance()
    while self:peek():match("[0-9]") do self:advance() end
    if self:peek() == "." then
      self:advance()
      while self:peek():match("[0-9]") do self:advance() end
    end
  end
  if self:peek() == "e" or self:peek() == "E" then
    self:advance()
    if self:peek() == "+" or self:peek() == "-" then self:advance() end
    while self:peek():match("[0-9]") do self:advance() end
  end
  if self:peek() == "j" or self:peek() == "J" then self:advance() end
  return self.src:sub(start, self.pos - 1)
end

function Lexer:read_string()
  local start = self.pos
  local quote = self:peek()
  local triple = false
  if self:peek(1) == quote and self:peek(2) == quote then
    triple = true
    self:advance(3)
  else
    self:advance()
  end
  while true do
    local c = self:peek()
    if c == "" then break end
    if c == "\n" and not triple then break end
    if c == "\\" then
      self:advance(2)
    elseif triple and c == quote and self:peek(1) == quote and self:peek(2) == quote then
      self:advance(3)
      break
    elseif not triple and c == quote then
      self:advance()
      break
    else
      self:advance()
    end
  end
  return self.src:sub(start, self.pos - 1)
end

function Lexer:read_ident()
  local start = self.pos
  while self:peek():match("[%w_]") do self:advance() end
  return self.src:sub(start, self.pos - 1)
end

function Lexer:read_op()
  local start = self.pos
  -- Try multi-char operators first (2 chars)
  local s2 = self.src:sub(self.pos, self.pos + 1)
  local s3 = self.src:sub(self.pos, self.pos + 2)
  if OPS_MULTI[s3] then
    self:advance(3)
    return s3
  end
  if OPS_MULTI[s2] then
    self:advance(2)
    return s2
  end
  local c = self:peek()
  if OPS_SINGLE[c] then
    self:advance()
    return c
  end
  self:advance()
  return c
end

function Lexer:handle_newline()
  -- Only emit NEWLINE/INDENT/DEDENT at logical line start
  if self.in_paren > 0 then
    self.newline_pending = "NL"
    return
  end
  self.newline_pending = "NEWLINE"
  -- Check indentation of next line (count BEFORE skipping whitespace)
  -- Note: self.pos already points past the \n
  local indent = 0
  while self:peek() == " " do indent = indent + 1; self:advance() end
  while self:peek() == "\t" do indent = indent + 1; self:advance() end
  local cur = self.indent_stack[#self.indent_stack]
  if indent > cur then
    table.insert(self.indent_stack, indent)
    self.indent_pending = "INDENT"
  elseif indent < cur then
    -- pop dedents
    local dedented = false
    while #self.indent_stack > 1 and self.indent_stack[#self.indent_stack] > indent do
        table.remove(self.indent_stack)
        dedented = true
    end
    if dedented then
        self.indent_pending = "DEDENT"
    elseif self.indent_stack[#self.indent_stack] ~= indent then
        error("IndentationError: unexpected indent at line " .. self.line)
    end
  end
end

function Lexer:tokenize()
  while self.pos <= #self.src do
    if self.newline_pending then
      local t = self.newline_pending
      self.newline_pending = nil
      table.insert(self.tokens, {type = t, line = self.line, col = self.col})
    end
    if self.indent_pending then
      local t = self.indent_pending
      self.indent_pending = nil
      table.insert(self.tokens, {type = t, line = self.line, col = self.col})
    end

    self:skip_whitespace()
    local c = self:peek()
    if c == "" then
      -- EOF: emit dedents
      while #self.indent_stack > 1 do
        table.remove(self.indent_stack)
        table.insert(self.tokens, {type = "DEDENT", line = self.line, col = self.col})
      end
      table.insert(self.tokens, {type = TT.EOF, line = self.line, col = self.col})
      break
    end

    if c == "\n" then
      self:advance()
      self:handle_newline()
    elseif c == "#" then
      -- comment
      local start = self.pos
      while self:peek() ~= "" and self:peek() ~= "\n" do self:advance() end
      table.insert(self.tokens, {type = TT.COMMENT, value = self.src:sub(start, self.pos - 1), line = self.line, col = self.col})
    elseif c:match("[0-9]") then
      local num = self:read_number()
      table.insert(self.tokens, {type = TT.NUMBER, value = num, line = self.line, col = self.col})
    elseif c:match("[%w_]") then
      local word = self:read_ident()
      table.insert(self.tokens, {type = TT.NAME, value = word, line = self.line, col = self.col})
    elseif c == "'" or c == '"' then
      local str = self:read_string()
      table.insert(self.tokens, {type = TT.STRING, value = str, line = self.line, col = self.col})
    elseif c == "(" or c == "[" or c == "{" then
      self:advance()
      self.in_paren = self.in_paren + 1
      table.insert(self.tokens, {type = TT.OP, value = c, line = self.line, col = self.col})
    elseif c == ")" or c == "]" or c == "}" then
      self:advance()
      self.in_paren = math.max(0, self.in_paren - 1)
      table.insert(self.tokens, {type = TT.OP, value = c, line = self.line, col = self.col})
    else
      local op = self:read_op()
      table.insert(self.tokens, {type = TT.OP, value = op, line = self.line, col = self.col})
    end
  end
  -- Emit any remaining pending tokens and EOF
  if self.indent_pending then
    table.insert(self.tokens, {type = self.indent_pending, line = self.line, col = self.col})
    self.indent_pending = nil
  end
  if self.newline_pending then
    table.insert(self.tokens, {type = self.newline_pending, line = self.line, col = self.col})
    self.newline_pending = nil
  end
  while #self.indent_stack > 1 do
    table.remove(self.indent_stack)
    table.insert(self.tokens, {type = "DEDENT", line = self.line, col = self.col})
  end
  table.insert(self.tokens, {type = TT.EOF, line = self.line, col = self.col})
end

------------------------------------------------------------------------------
-- AST Node constructors
------------------------------------------------------------------------------
local function node(ntype, fields)
  fields = fields or {}
  fields._type = ntype
  fields.lineno = fields.lineno or 0
  fields.col_offset = fields.col_offset or 0
  return fields
end

local NT = {
  Module = "Module",
  FunctionDef = "FunctionDef",
  AsyncFunctionDef = "AsyncFunctionDef",
  ClassDef = "ClassDef",
  Return = "Return",
  Delete = "Delete",
  Assign = "Assign",
  AugAssign = "AugAssign",
  AnnAssign = "AnnAssign",
  For = "For",
  AsyncFor = "AsyncFor",
  While = "While",
  If = "If",
  With = "With",
  AsyncWith = "AsyncWith",
  Match = "Match",
  Raise = "Raise",
  Try = "Try",
  ExceptHandler = "ExceptHandler",
  Assert = "Assert",
  Import = "Import",
  ImportFrom = "ImportFrom",
  Global = "Global",
  Nonlocal = "Nonlocal",
  Expr = "Expr",
  Pass = "Pass",
  Break = "Break",
  Continue = "Continue",
  BoolOp = "BoolOp",
  NamedExpr = "NamedExpr",
  BinOp = "BinOp",
  UnaryOp = "UnaryOp",
  Lambda = "Lambda",
  IfExp = "IfExp",
  Dict = "Dict",
  Set = "Set",
  ListComp = "ListComp",
  SetComp = "SetComp",
  DictComp = "DictComp",
  GeneratorExp = "GeneratorExp",
  Await = "Await",
  Yield = "Yield",
  YieldFrom = "YieldFrom",
  Compare = "Compare",
  Call = "Call",
  FormattedValue = "FormattedValue",
  JoinedStr = "JoinedStr",
  Constant = "Constant",
  Attribute = "Attribute",
  Subscript = "Subscript",
  Starred = "Starred",
  Name = "Name",
  List = "List",
  Tuple = "Tuple",
  Slice = "Slice",
  comprehension = "comprehension",
  excepthandler = "ExceptHandler",
  arguments = "arguments",
  arg = "arg",
  keyword = "keyword",
  alias = "alias",
  withitem = "withitem",
}

-- Operator mappings for IR lowerer
local BINOP_MAP = {
  ["+"] = "Add", ["-"] = "Sub", ["*"] = "Mult", ["/"] = "Div",
  ["%"] = "Mod", ["**"] = "Pow", ["//"] = "FloorDiv",
  ["<<"] = "LShift", [">>"] = "RShift", ["|"] = "BitOr",
  ["^"] = "BitXor", ["&"] = "BitAnd",
  ["+="] = "Add", ["-="] = "Sub", ["*="] = "Mult", ["/="] = "Div",
  ["%="] = "Mod", ["&="] = "BitAnd", ["|="] = "BitOr", ["^="] = "BitXor",
  ["//="] = "FloorDiv",
}
local CMPOP_MAP = {
  ["=="] = "Eq", ["!="] = "NotEq", ["<"] = "Lt", ["<="] = "LtE",
  [">"] = "Gt", [">="] = "GtE", ["is"] = "Is", ["is not"] = "IsNot",
  ["in"] = "In", ["not in"] = "NotIn",
}
local BOOL_OP_MAP = {["and"] = "And", ["or"] = "Or"}
local UNARY_OP_MAP = {["-"] = "USub", ["+"] = "UAdd", ["not"] = "Not", ["~"] = "Invert"}

------------------------------------------------------------------------------
-- Parser
------------------------------------------------------------------------------
local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
  local self = setmetatable({}, Parser)
  self.tokens = tokens
  self.pos = 1
  return self
end

function Parser:peek()
  local tok = self.tokens[self.pos]
  if not tok then
    error("Parser:peek() called past end of tokens at pos " .. self.pos .. " (max " .. #self.tokens .. ")")
  end
  return tok
end

function Parser:advance()
  local tok = self.tokens[self.pos]
  self.pos = self.pos + 1
  return tok
end

function Parser:expect(ttype, value)
  local tok = self:peek()
  if tok.type ~= ttype then
    error("ParseError: expected " .. ttype .. " got " .. tok.type .. " at line " .. tok.line)
  end
  if value and tok.value ~= value then
    error("ParseError: expected " .. value .. " got " .. tok.value .. " at line " .. tok.line)
  end
  return self:advance()
end

function Parser:check(ttype, value)
  local tok = self:peek()
  if tok.type == ttype then
    if value == nil or tok.value == value then return true end
  end
  return false
end

function Parser:check2(ttype1, v1, ttype2, v2)
  local tok = self:peek()
  if tok.type == ttype1 and tok.value == v1 then return true end
  if tok.type == ttype2 and tok.value == v2 then return true end
  return false
end

function Parser:match(ttype, value)
  if self:check(ttype, value) then return self:advance() end
  return nil
end

function Parser:newline_or_eof()
  local tok = self:peek()
  return tok.type == TT.NEWLINE or tok.type == TT.EOF or tok.type == TT.DEDENT
end

function Parser:new_suite()
  -- expects NEWLINE already consumed, now expect INDENT
  self:expect(TT.INDENT)
  local stmts = {}
  while not self:check(TT.DEDENT) and not self:check(TT.EOF) do
    if self:check(TT.NEWLINE) or self:check(TT.NL) then
      self:advance()
    else
      table.insert(stmts, self:stmt())
    end
  end
  self:expect(TT.DEDENT)
  return stmts
end

------------------------------------------------------------------------------
-- Statement parsing
------------------------------------------------------------------------------
function Parser:stmt()
  local tok = self:peek()
  if tok.type == TT.NEWLINE or tok.type == TT.DEDENT or tok.type == TT.EOF then
    print('DEBUG: stmt() got unexpected token: ' .. tok.type .. ' at line ' .. tok.line)
    error("stmt() got unexpected token: " .. tok.type .. " (" .. (tok.value or "") .. ") at line " .. tok.line)
  end
  local t = tok.type
  local v = tok.value

  if t == TT.NAME then
    if v == "def" then return self:func_def()
    elseif v == "class" then return self:class_def()
    elseif v == "if" then return self:if_stmt()
    elseif v == "while" then return self:while_stmt()
    elseif v == "for" then return self:for_stmt()
    elseif v == "with" then return self:with_stmt()
    elseif v == "try" then return self:try_stmt()
    elseif v == "return" then return self:return_stmt()
    elseif v == "raise" then return self:raise_stmt()
    elseif v == "assert" then return self:assert_stmt()
    elseif v == "del" then return self:delete_stmt()
    elseif v == "pass" then self:advance(); return node(NT.Pass)
    elseif v == "break" then self:advance(); return node(NT.Break)
    elseif v == "continue" then self:advance(); return node(NT.Continue)
    elseif v == "import" then return self:import_stmt()
    elseif v == "from" then return self:import_from_stmt()
    elseif v == "global" then return self:global_stmt()
    elseif v == "nonlocal" then return self:nonlocal_stmt()
    else return self:expr_stmt() end
  elseif t == TT.OP then
    if v == "@" then return self:decorated() end
    return self:expr_stmt()
  else
    return self:expr_stmt()
  end
end

function Parser:simple_stmt()
  local first = self:small_stmt()
  local stmts = {first}
  while self:match(TT.OP, ";") do
    table.insert(stmts, self:small_stmt())
  end
  self:match(TT.NEWLINE)
  self:match(TT.NL)
  if #stmts == 1 then return stmts[1] end
  -- wrap multiple in a list for the caller
  return {_type = "simple_stmts", stmts = stmts}
end

function Parser:small_stmt()
  local tok = self:peek()
  local t = tok.type
  local v = tok.value

  if t == TT.NAME then
    if v == "return" then self:advance(); local v = self:test(); self:match(TT.NEWLINE); return node(NT.Return, {value = v, lineno = tok.line, col_offset = tok.col})
    elseif v == "raise" then self:advance(); local exc = nil; if not self:newline_or_eof() then exc = self:test() end; self:match(TT.NEWLINE); return node(NT.Raise, {exc = exc, lineno = tok.line, col_offset = tok.col})
    elseif v == "assert" then self:advance(); local test = self:test(); local msg = nil; if self:match(TT.OP, ",") then msg = self:test() end; self:match(TT.NEWLINE); return node(NT.Assert, {test = test, msg = msg, lineno = tok.line, col_offset = tok.col})
    elseif v == "del" then self:advance(); local targets = {self:expr()}; while self:match(TT.OP, ",") do table.insert(targets, self:expr()) end; self:match(TT.NEWLINE); return node(NT.Delete, {targets = targets, lineno = tok.line, col_offset = tok.col})
    elseif v == "pass" then self:advance(); self:match(TT.NEWLINE); return node(NT.Pass)
    elseif v == "break" then self:advance(); self:match(TT.NEWLINE); return node(NT.Break)
    elseif v == "continue" then self:advance(); self:match(TT.NEWLINE); return node(NT.Continue)
    elseif v == "import" then return self:import_stmt()
    elseif v == "from" then return self:import_from_stmt()
    elseif v == "global" then self:advance(); local names = {}; table.insert(names, self:expect(TT.NAME).value); while self:match(TT.OP, ",") do table.insert(names, self:expect(TT.NAME).value) end; self:match(TT.NEWLINE); return node(NT.Global, {names = names, lineno = tok.line, col_offset = tok.col})
    elseif v == "nonlocal" then self:advance(); local names = {}; table.insert(names, self:expect(TT.NAME).value); while self:match(TT.OP, ",") do table.insert(names, self:expect(TT.NAME).value) end; self:match(TT.NEWLINE); return node(NT.Nonlocal, {names = names, lineno = tok.line, col_offset = tok.col})
    else return self:expr_stmt() end
  else
    return self:expr_stmt()
  end
end

function Parser:expr_stmt()
  local test = self:test()
  if self:check(TT.OP, "=") or self:check2(TT.OP, "+=", TT.OP, "-=") or self:check2(TT.OP, "*=", TT.OP, "/=") or self:check2(TT.OP, "%=", TT.OP, "&=") or self:check2(TT.OP, "|=", TT.OP, "|=") or self:check2(TT.OP, "^=", TT.OP, "^=") or self:check2(TT.OP, "//=", TT.OP, "//=") then
    local op_tok = self:advance()
    local op = BINOP_MAP[op_tok.value] or "Assign"
    local value = self:test()
    self:match(TT.NEWLINE)
    if op == "Assign" then
      return node(NT.Assign, {targets = {test}, value = value, lineno = op_tok.line, col_offset = op_tok.col})
    else
      return node(NT.AugAssign, {target = test, op = op, value = value, lineno = op_tok.line, col_offset = op_tok.col})
    end
  end
  self:match(TT.NEWLINE)
  return node(NT.Expr, {value = test, lineno = test.lineno, col_offset = test.col_offset})
end

function Parser:decorated()
  local decorators = {}
  while self:match(TT.OP, "@") do
    local dec = self:expr()
    self:match(TT.NEWLINE)
    table.insert(decorators, dec)
  end
  local tok = self:peek()
  if tok.type == TT.NAME and tok.value == "def" then
    local fn = self:func_def()
    fn.decorator_list = decorators
    return fn
  elseif tok.type == TT.NAME and tok.value == "class" then
    local cls = self:class_def()
    cls.decorator_list = decorators
    return cls
  end
  error("Expected def or class after decorator at line " .. tok.line)
end

function Parser:func_def()
  self:expect(TT.NAME, "def")
  local name = self:expect(TT.NAME).value
  self:expect(TT.OP, "(")
  local args = self:arguments()
  self:expect(TT.OP, ")")
  local returns = nil
  if self:match(TT.OP, "->") then returns = self:expr() end
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  local body
  if self:check(TT.INDENT) then
    body = self:new_suite()
  else
    local simple = self:simple_stmt()
    body = {simple}
  end
  return node(NT.FunctionDef, {
    name = name, args = args, body = body, decorator_list = {},
    returns = returns, lineno = 0, col_offset = 0
  })
end

function Parser:arguments()
  local args = {}
  while not self:check(TT.OP, ")") do
    local arg_name = self:expect(TT.NAME).value
    local annotation = nil
    if self:match(TT.OP, ":") then annotation = self:expr() end
    table.insert(args, {arg = arg_name, annotation = annotation, lineno = 0, col_offset = 0, _type = "arg"})
    if not self:match(TT.OP, ",") then break end
  end
  return {args = args, vararg = nil, kwonlyargs = {}, kw_defaults = {}, kwarg = nil, defaults = {}, _type = "arguments"}
end

function Parser:class_def()
  self:expect(TT.NAME, "class")
  local name = self:expect(TT.NAME).value
  local bases = {}
  local keywords = {}
  if self:match(TT.OP, "(") then
    if not self:check(TT.OP, ")") then
      table.insert(bases, self:expr())
      while self:match(TT.OP, ",") do table.insert(bases, self:expr()) end
    end
    self:expect(TT.OP, ")")
  end
  if self:match(TT.OP, ":") then -- keyword args not fully supported yet
    -- skip
  end
  self:match(TT.NEWLINE)
  local body
  if self:check(TT.INDENT) then
    body = self:new_suite()
  else
    local simple = self:simple_stmt()
    body = {simple}
  end
  return node(NT.ClassDef, {name = name, bases = bases, keywords = keywords, body = body, decorator_list = {}, lineno = 0, col_offset = 0})
end

function Parser:if_stmt()
  self:expect(TT.NAME, "if")
  local test = self:expr()
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  local body = self:new_suite()
  local orelse = {}
  while self:check(TT.NAME, "elif") do
    self:advance()
    local test2 = self:expr()
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    local body2 = self:new_suite()
    table.insert(orelse, node(NT.If, {test = test2, body = body2, orelse = {}, lineno = 0, col_offset = 0}))
  end
  if self:match(TT.NAME, "else") then
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then
      orelse = self:new_suite()
    else
      local simple = self:simple_stmt()
      orelse = {simple}
    end
  end
  return node(NT.If, {test = test, body = body, orelse = orelse, lineno = 0, col_offset = 0})
end

function Parser:while_stmt()
  self:expect(TT.NAME, "while")
  local test = self:expr()
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  local body = self:new_suite()
  local orelse = {}
  if self:match(TT.NAME, "else") then
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then orelse = self:new_suite()
    else orelse = {self:simple_stmt()} end
  end
  return node(NT.While, {test = test, body = body, orelse = orelse, lineno = 0, col_offset = 0})
end

function Parser:for_stmt()
  self:expect(TT.NAME, "for")
  local target = self:expr()
  self:expect(TT.NAME, "in")
  local iter = self:expr()
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  local body = self:new_suite()
  local orelse = {}
  if self:match(TT.NAME, "else") then
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then orelse = self:new_suite()
    else orelse = {self:simple_stmt()} end
  end
  return node(NT.For, {target = target, iter = iter, body = body, orelse = orelse, lineno = 0, col_offset = 0})
end

function Parser:with_stmt()
  self:expect(TT.NAME, "with")
  local items = {}
  repeat
    local ctx = self:expr()
    local vars = nil
    if self:match(TT.NAME, "as") then vars = self:expr() end
    table.insert(items, {context_expr = ctx, optional_vars = vars})
  until not self:match(TT.OP, ",")
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  local body = self:new_suite()
  return node(NT.With, {items = items, body = body, lineno = 0, col_offset = 0})
end

function Parser:try_stmt()
  self:expect(TT.NAME, "try")
  self:match(TT.NEWLINE)
  local body = self:new_suite()
  local handlers = {}
  while self:match(TT.NAME, "except") do
    local typ = nil
    local name = nil
    if not self:newline_or_eof() then
      typ = self:expr()
      if self:match(TT.NAME, "as") then name = self:expect(TT.NAME).value end
    end
    self:match(TT.NEWLINE)
    local hbody = self:new_suite()
    table.insert(handlers, {type = typ, name = name, body = hbody, lineno = 0, col_offset = 0})
  end
  local orelse = {}
  if self:match(TT.NAME, "else") then
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then orelse = self:new_suite()
    else orelse = {self:simple_stmt()} end
  end
  local finalbody = {}
  if self:match(TT.NAME, "finally") then
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then finalbody = self:new_suite()
    else finalbody = {self:simple_stmt()} end
  end
  return node(NT.Try, {body = body, handlers = handlers, orelse = orelse, finalbody = finalbody, lineno = 0, col_offset = 0})
end

function Parser:return_stmt()
  self:expect(TT.NAME, "return")
  local value = nil
  if not self:newline_or_eof() then value = self:test() end
  self:match(TT.NEWLINE)
  return node(NT.Return, {value = value, lineno = 0, col_offset = 0})
end

function Parser:raise_stmt()
  self:expect(TT.NAME, "raise")
  local exc = nil
  if not self:newline_or_eof() then exc = self:expr() end
  self:match(TT.NEWLINE)
  return node(NT.Raise, {exc = exc, lineno = 0, col_offset = 0})
end

function Parser:assert_stmt()
  self:expect(TT.NAME, "assert")
  local test = self:test()
  local msg = nil
  if self:match(TT.OP, ",") then msg = self:test() end
  self:match(TT.NEWLINE)
  return node(NT.Assert, {test = test, msg = msg, lineno = 0, col_offset = 0})
end

function Parser:delete_stmt()
  self:expect(TT.NAME, "del")
  local targets = {self:expr()}
  while self:match(TT.OP, ",") do table.insert(targets, self:expr()) end
  self:match(TT.NEWLINE)
  return node(NT.Delete, {targets = targets, lineno = 0, col_offset = 0})
end

function Parser:import_stmt()
  self:expect(TT.NAME, "import")
  local names = {}
  repeat
    local name = self:expect(TT.NAME).value
    local alias = nil
    if self:match(TT.NAME, "as") then alias = self:expect(TT.NAME).value end
    table.insert(names, {name = name, asname = alias})
  until not self:match(TT.OP, ",")
  self:match(TT.NEWLINE)
  return node(NT.Import, {names = names, lineno = 0, col_offset = 0})
end

function Parser:import_from_stmt()
  self:expect(TT.NAME, "from")
  local module = nil
  if not self:match(TT.NAME, "import") then
    local parts = {self:expect(TT.NAME).value}
    while self:match(TT.OP, ".") do table.insert(parts, self:expect(TT.NAME).value) end
    module = table.concat(parts, ".")
    self:expect(TT.NAME, "import")
  end
  local names = {}
  if self:match(TT.OP, "(") then
    repeat
      local name = self:expect(TT.NAME).value
      local alias = nil
      if self:match(TT.NAME, "as") then alias = self:expect(TT.NAME).value end
      table.insert(names, {name = name, asname = alias})
    until not self:match(TT.OP, ",")
    self:expect(TT.OP, ")")
  else
    repeat
      local name = self:expect(TT.NAME).value
      local alias = nil
      if self:match(TT.NAME, "as") then alias = self:expect(TT.NAME).value end
      table.insert(names, {name = name, asname = alias})
    until not self:match(TT.OP, ",")
  end
  local level = 0 -- not handling relative imports yet
  self:match(TT.NEWLINE)
  return node(NT.ImportFrom, {module = module, names = names, level = level, lineno = 0, col_offset = 0})
end

function Parser:global_stmt()
  self:expect(TT.NAME, "global")
  local names = {self:expect(TT.NAME).value}
  while self:match(TT.OP, ",") do table.insert(names, self:expect(TT.NAME).value) end
  self:match(TT.NEWLINE)
  return node(NT.Global, {names = names, lineno = 0, col_offset = 0})
end

function Parser:nonlocal_stmt()
  self:expect(TT.NAME, "nonlocal")
  local names = {self:expect(TT.NAME).value}
  while self:match(TT.OP, ",") do table.insert(names, self:expect(TT.NAME).value) end
  self:match(TT.NEWLINE)
  return node(NT.Nonlocal, {names = names, lineno = 0, col_offset = 0})
end

------------------------------------------------------------------------------
-- Expression parsing (precedence climbing)
------------------------------------------------------------------------------
function Parser:test()
  return self:or_test()
end

function Parser:or_test()
  local result = self:and_test()
  while self:match(TT.NAME, "or") do
    local right = self:and_test()
    result = node(NT.BoolOp, {op = "Or", values = {result, right}, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:and_test()
  local result = self:not_test()
  while self:match(TT.NAME, "and") do
    local right = self:not_test()
    result = node(NT.BoolOp, {op = "And", values = {result, right}, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:not_test()
  if self:match(TT.NAME, "not") then
    local operand = self:not_test()
    return node(NT.UnaryOp, {op = "Not", operand = operand, lineno = 0, col_offset = 0})
  end
  return self:comparison()
end

function Parser:comparison()
  local left = self:arith_expr()
  local ops = {}
  local comparators = {}
  while self:check2(TT.OP, "==", TT.OP, "!=")
      or self:check2(TT.OP, "<", TT.OP, "<=")
      or self:check2(TT.OP, ">", TT.OP, ">=")
      or self:check(TT.NAME, "is") or self:check(TT.NAME, "in") do
    local op_tok = self:advance()
    local op = CMPOP_MAP[op_tok.value] or op_tok.value
    if op_tok.value == "is" and self:match(TT.NAME, "not") then op = "IsNot" end
    if op_tok.value == "in" and self:match(TT.NAME, "not") then op = "NotIn" end
    table.insert(ops, op)
    table.insert(comparators, self:arith_expr())
  end
  if #ops > 0 then
    return node(NT.Compare, {left = left, ops = ops, comparators = comparators, lineno = 0, col_offset = 0})
  end
  return left
end

function Parser:arith_expr()
  local result = self:term()
  while self:check2(TT.OP, "+", TT.OP, "-") do
    local op_tok = self:advance()
    local op = BINOP_MAP[op_tok.value]
    local right = self:term()
    result = node(NT.BinOp, {left = result, op = op, right = right, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:term()
  local result = self:factor()
  while self:check2(TT.OP, "*", TT.OP, "/")
      or self:check2(TT.OP, "%", TT.OP, "//") do
    local op_tok = self:advance()
    local op = BINOP_MAP[op_tok.value]
    local right = self:factor()
    result = node(NT.BinOp, {left = result, op = op, right = right, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:factor()
  if self:check2(TT.OP, "+", TT.OP, "-") or self:check2(TT.OP, "~", TT.OP, "not") then
    local op_tok = self:advance()
    local op = UNARY_OP_MAP[op_tok.value]
    local operand = self:factor()
    return node(NT.UnaryOp, {op = op, operand = operand, lineno = 0, col_offset = 0})
  end
  return self:power()
end

function Parser:power()
  local base = self:atom()
  if self:match(TT.OP, "**") then
    local exp = self:factor()
    return node(NT.BinOp, {left = base, op = "Pow", right = exp, lineno = 0, col_offset = 0})
  end
  return base
end

function Parser:atom()
  local tok = self:peek()
  if not tok then
    error("Parser:atom() called past end of tokens at pos " .. self.pos)
  end
  local t = tok.type
  local v = tok.value
  if t == TT.NEWLINE or t == TT.DEDENT or t == TT.EOF then
    error("Atom got unexpected token: " .. t .. " (" .. (v or "") .. ") at line " .. tok.line)
  end

  if t == TT.NUMBER then
    self:advance()
    return node(NT.Constant, {value = tonumber(v), lineno = tok.line, col_offset = tok.col})
  elseif t == TT.STRING then
    self:advance()
    return node(NT.Constant, {value = v, lineno = tok.line, col_offset = tok.col})
  elseif t == TT.NAME then
    self:advance()
    local ctx = "Load"
    local name_node = node(NT.Name, {id = v, ctx = ctx, lineno = tok.line, col_offset = tok.col})
    -- Check for function call: name(args)
    if self:check(TT.OP, "(") then
      self:advance() -- consume (
      local args = {}
      if not self:check(TT.OP, ")") then
        table.insert(args, self:expr())
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, ")") then break end
          table.insert(args, self:expr())
        end
      end
      self:expect(TT.OP, ")")
      return node(NT.Call, {func = name_node, args = args, lineno = tok.line, col_offset = tok.col})
    end
    return name_node
  elseif t == TT.OP then
    if v == "(" then
      self:advance()
      if self:check(TT.OP, ")") then
        self:advance()
        return node(NT.Tuple, {elts = {}, lineno = 0, col_offset = 0})
      end
      local expr = self:expr()
      if self:match(TT.OP, ",") then
        local elts = {expr}
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, ")") then break end
          table.insert(elts, self:expr())
        end
        self:expect(TT.OP, ")")
        return node(NT.Tuple, {elts = elts, lineno = 0, col_offset = 0})
      else
        self:expect(TT.OP, ")")
        return expr
      end
    elseif v == "[" then
      self:advance()
      if self:check(TT.OP, "]") then
        self:advance()
        return node(NT.List, {elts = {}, lineno = 0, col_offset = 0})
      end
      local first = self:expr()
      if self:match(TT.OP, ",") then
        local elts = {first}
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, "]") then break end
          table.insert(elts, self:expr())
        end
        self:expect(TT.OP, "]")
        return node(NT.List, {elts = elts, lineno = 0, col_offset = 0})
      else
        self:expect(TT.OP, "]")
        return first
      end
    elseif v == "{" then
      self:advance()
      if self:check(TT.OP, "}") then
        self:advance()
        return node(NT.Dict, {keys = {}, values = {}, lineno = 0, col_offset = 0})
      end
      local key = self:expr()
      if self:match(TT.OP, ":") then
        local keys = {key}
        local values = {self:expr()}
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, "}") then break end
          table.insert(keys, self:expr())
          self:expect(TT.OP, ":")
          table.insert(values, self:expr())
        end
        self:expect(TT.OP, "}")
        return node(NT.Dict, {keys = keys, values = values, lineno = 0, col_offset = 0})
      else
        -- set
        local elts = {key}
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, "}") then break end
          table.insert(elts, self:expr())
        end
        self:expect(TT.OP, "}")
        return node(NT.Set, {elts = elts, lineno = 0, col_offset = 0})
      end
    elseif v == "lambda" then
      self:advance()
      local args = {}
      if not self:check2(TT.NAME, "in", TT.NAME, "if") and not self:newline_or_eof() then
        repeat
          table.insert(args, self:expect(TT.NAME).value)
        until not self:match(TT.OP, ",")
      end
      self:expect(TT.OP, ":")
      local body = self:expr()
      return node(NT.Lambda, {args = args, body = body, lineno = 0, col_offset = 0})
    else
      error("Unexpected operator in atom: " .. v .. " at line " .. tok.line)
    end
  else
    error("Unexpected token: " .. t .. " (" .. (v or "") .. ") at line " .. tok.line)
  end
end

function Parser:test_nocond()
  return self:or_test_nocond()
end

function Parser:or_test_nocond()
  local node = self:and_test_nocond()
  while self:match(TT.NAME, "or") do
    local right = self:and_test_nocond()
    node = node(NT.BoolOp, {op = "Or", values = {node, right}, lineno = 0, col_offset = 0})
  end
  return node
end

function Parser:and_test_nocond()
  local node = self:not_test_nocond()
  while self:match(TT.NAME, "and") do
    local right = self:not_test_nocond()
    node = node(NT.BoolOp, {op = "And", values = {node, right}, lineno = 0, col_offset = 0})
  end
  return node
end

function Parser:not_test_nocond()
  if self:match(TT.NAME, "not") then
    local operand = self:not_test_nocond()
    return node(NT.UnaryOp, {op = "Not", operand = operand, lineno = 0, col_offset = 0})
  end
  return self:comparison_nocond()
end

function Parser:comparison_nocond()
  local left = self:arith_expr()
  local ops = {}
  local comparators = {}
  while self:check2(TT.OP, "==", TT.OP, "!=")
      or self:check2(TT.OP, "<", TT.OP, "<=")
      or self:check2(TT.OP, ">", TT.OP, ">=")
      or self:check(TT.NAME, "is") or self:check(TT.NAME, "in") do
    local op_tok = self:advance()
    local op = CMPOP_MAP[op_tok.value] or op_tok.value
    if op_tok.value == "is" and self:match(TT.NAME, "not") then op = "IsNot" end
    if op_tok.value == "in" and self:match(TT.NAME, "not") then op = "NotIn" end
    table.insert(ops, op)
    table.insert(comparators, self:arith_expr())
  end
  if #ops > 0 then
    return node(NT.Compare, {left = left, ops = ops, comparators = comparators, lineno = 0, col_offset = 0})
  end
  return left
end

function Parser:if_exp()
  local cond = self:or_test_nocond()
  if self:match(TT.NAME, "if") then
    local body = self:or_test_nocond()
    self:expect(TT.NAME, "else")
    local orelse = self:or_test_nocond()
    return node(NT.IfExp, {test = cond, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  end
  return cond
end

function Parser:expr()
  return self:if_exp()
end

------------------------------------------------------------------------------
-- Module parsing
------------------------------------------------------------------------------
function Parser:parse()
  local stmts = {}
  local stmt_count = 0
  while not self:check(TT.EOF) do
    if self:check(TT.NEWLINE) or self:check(TT.NL) or self:check(TT.DEDENT) then
      self:advance()
    else
      local stmt = self:stmt()
      if stmt then table.insert(stmts, stmt) end
      stmt_count = stmt_count + 1
      if stmt_count > 20 then
        error("Too many statements, possible infinite loop")
      end
    end
  end
  self:expect(TT.EOF)
  return node(NT.Module, {body = stmts, lineno = 0, col_offset = 0})
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------
function parser.parse(source)
  local lexer = Lexer.new(source)
  local parser_inst = Parser.new(lexer.tokens)
  return parser_inst:parse()
end

function parser.parse_string(source)
  return parser.parse(source)
end

return parser
