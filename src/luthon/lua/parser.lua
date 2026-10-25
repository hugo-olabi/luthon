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
  ["<<"] = "LShift", [">>"] = "RShift", ["**"] = "Pow", ["//"] = "FloorDiv",
  ["+="] = "Add", ["-="] = "Sub", ["*="] = "Mult", ["/="] = "Div",
  ["%="] = "Mod", ["&="] = "BitAnd", ["|="] = "BitOr", ["^="] = "BitXor",
  ["//="] = "FloorDiv", ["<<="] = "LShiftE", [">>="] = "RShiftE", ["@="] = "MatMult",
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
    -- Inside parens/brackets, newlines are whitespace - skip entirely
    return
  end
  self.newline_pending = "NEWLINE"
  -- Check indentation of next line (count BEFORE skipping whitespace)
  -- Note: self.pos already points past the \n
  local save_pos = self.pos
  local indent = 0
  while self:peek() == " " do indent = indent + 1; self:advance() end
  while self:peek() == "\t" do indent = indent + 1; self:advance() end
  -- Blank line: skip indentation changes
  if self:peek() == "\n" then
    self.pos = save_pos
    return
  end
  local cur = self.indent_stack[#self.indent_stack]
  if indent > cur then
    table.insert(self.indent_stack, indent)
    self.indent_pending = "INDENT"
  elseif indent < cur then
    -- pop dedents: emit one DEDENT per level popped
    local popped = 0
    while #self.indent_stack > 1 and self.indent_stack[#self.indent_stack] > indent do
        table.remove(self.indent_stack)
        popped = popped + 1
    end
    if popped > 0 then
      if popped == 1 then
        self.indent_pending = "DEDENT"
      else
        -- Emit first DEDENT now, queue the rest as pending_dedents
        self.indent_pending = "DEDENT"
        self.pending_dedents = (self.pending_dedents or 0) + (popped - 1)
      end
    end
  elseif self.indent_stack[#self.indent_stack] ~= indent then
      error("IndentationError: unexpected indent at line " .. self.line)
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
      -- Emit any additional queued DEDENTs (one per popped level beyond the first)
      while self.pending_dedents and self.pending_dedents > 0 do
        self.pending_dedents = self.pending_dedents - 1
        table.insert(self.tokens, {type = "DEDENT", line = self.line, col = self.col})
      end
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
    -- Bytes literal prefix: b"..." or B"..." (treated as string in Lua)
    elseif (c == "b" or c == "B") and (self:peek(1) == '"' or self:peek(1) == "'") then
      self:advance() -- skip b/B prefix
      local str = self:read_string()
      table.insert(self.tokens, {type = TT.STRING, value = str, line = self.line, col = self.col})
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
    local prev = self.tokens[self.pos - 1]
    error("ParseError: expected " .. ttype .. (value and (" '" .. value .. "'") or "") .. " got " .. tok.type .. " ('" .. tostring(tok.value) .. "') at line " .. tok.line .. " col " .. tok.col .. " (prev tok=" .. (prev and (prev.type .. " '" .. tostring(prev.value) .. "' line " .. prev.line) or "none") .. ")")
  end
  if value and tok.value ~= value then
    local prev = self.tokens[self.pos - 1]
    error("ParseError: expected '" .. value .. "' got '" .. tostring(tok.value) .. "' at line " .. tok.line .. " col " .. tok.col .. " (prev tok=" .. (prev and (prev.type .. " '" .. tostring(prev.value) .. "' line " .. prev.line) or "none") .. ")")
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
  while not self:check(TT.DEDENT) and not self:check(TT.EOF)
      and not self:check(TT.NAME, "elif") and not self:check(TT.NAME, "else")
      and not self:check(TT.NAME, "except") do
    if self:check(TT.NEWLINE) or self:check(TT.NL) or self:check(TT.COMMENT) then
      self:advance()
    else
      table.insert(stmts, self:stmt())
    end
  end
  if self:check(TT.DEDENT) then
    self:expect(TT.DEDENT)
  end
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
  local test = self:expr()
  -- Handle tuple unpacking targets: a, b = expr
  local targets = {test}
  if self:check(TT.OP, ",") then
    repeat
      self:advance() -- consume comma
      table.insert(targets, self:expect(TT.NAME))
    until not self:match(TT.OP, ",")
  end
  if self:check(TT.OP, "=") or self:check2(TT.OP, "+=", TT.OP, "-=") or self:check2(TT.OP, "*=", TT.OP, "/=") or self:check2(TT.OP, "%=", TT.OP, "&=") or self:check2(TT.OP, "|=", TT.OP, "|=") or self:check2(TT.OP, "^=", TT.OP, "^=") or self:check2(TT.OP, "//=", TT.OP, "//=") or self:check2(TT.OP, "<<=", TT.OP, ">>=") then
    local op_tok = self:advance()
    local op = BINOP_MAP[op_tok.value] or "Assign"
    local value = self:expr()
    self:match(TT.NEWLINE)
    if op == "Assign" then
      return node(NT.Assign, {targets = targets, value = value, lineno = op_tok.line, col_offset = op_tok.col})
    else
      return node(NT.AugAssign, {target = test, op = op, value = value, lineno = op_tok.line, col_offset = op_tok.col})
    end
  end
  -- Annotated assignment: target: type [= value]
  if self:match(TT.OP, ":") then
    local annotation = self:expr()
    local value = nil
    if self:match(TT.OP, "=") then
      value = self:expr()
    end
    self:match(TT.NEWLINE)
    return node(NT.AnnAssign, {target = test, annotation = annotation, value = value, lineno = 0, col_offset = 0})
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
  local defaults = {}
  while not self:check(TT.OP, ")") do
    local arg_name = self:expect(TT.NAME).value
    local annotation = nil
    if self:match(TT.OP, ":") then annotation = self:expr() end
    local default = nil
    if self:match(TT.OP, "=") then default = self:expr() end
    table.insert(args, {arg = arg_name, annotation = annotation, default = default, lineno = 0, col_offset = 0, _type = "arg"})
    if default then table.insert(defaults, default) end
    if not self:match(TT.OP, ",") then break end
  end
  return {args = args, vararg = nil, kwonlyargs = {}, kw_defaults = {}, kwarg = nil, defaults = defaults, _type = "arguments"}
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
  self:match(TT.NL)
  if self:check(TT.INDENT) then
    local body = self:new_suite()
    local orelse = {}
    if self:match(TT.NAME, "else") then
      self:expect(TT.OP, ":")
      self:match(TT.NEWLINE)
      self:match(TT.NL)
      if self:check(TT.INDENT) then orelse = self:new_suite()
      else orelse = {self:simple_stmt()} end
    end
    return node(NT.While, {test = test, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  else
    local body = {self:simple_stmt()}
    local orelse = {}
    if self:match(TT.NAME, "else") then
      self:expect(TT.OP, ":")
      self:match(TT.NEWLINE)
      self:match(TT.NL)
      if self:check(TT.INDENT) then orelse = self:new_suite()
      else orelse = {self:simple_stmt()} end
    end
    return node(NT.While, {test = test, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  end
end

function Parser:for_stmt()
  self:expect(TT.NAME, "for")
  local target = self:comp_target()
  self:expect(TT.NAME, "in")
  local iter = self:expr()
  self:expect(TT.OP, ":")
  self:match(TT.NEWLINE)
  self:match(TT.NL)
  if self:check(TT.INDENT) then
    local body = self:new_suite()
    local orelse = {}
    if self:match(TT.NAME, "else") then
      self:expect(TT.OP, ":")
      self:match(TT.NEWLINE)
      self:match(TT.NL)
      if self:check(TT.INDENT) then orelse = self:new_suite()
      else orelse = {self:simple_stmt()} end
    end
    return node(NT.For, {target = target, iter = iter, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  else
    local body = {self:simple_stmt()}
    local orelse = {}
    if self:match(TT.NAME, "else") then
      self:expect(TT.OP, ":")
      self:match(TT.NEWLINE)
      self:match(TT.NL)
      if self:check(TT.INDENT) then orelse = self:new_suite()
      else orelse = {self:simple_stmt()} end
    end
    return node(NT.For, {target = target, iter = iter, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  end
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
  self:expect(TT.OP, ":")
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
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    local hbody = self:new_suite()
    table.insert(handlers, {type = typ, name = name, body = hbody, lineno = 0, col_offset = 0})
  end
  local orelse = {}
  if self:match(TT.NAME, "else") then
    self:expect(TT.OP, ":")
    self:match(TT.NEWLINE)
    if self:check(TT.INDENT) then orelse = self:new_suite()
    else orelse = {self:simple_stmt()} end
  end
  local finalbody = {}
  if self:match(TT.NAME, "finally") then
    self:expect(TT.OP, ":")
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
    local parts = {self:expect(TT.NAME).value}
    while self:match(TT.OP, ".") do table.insert(parts, self:expect(TT.NAME).value) end
    local name = table.concat(parts, ".")
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
  local level = 0
  -- Handle relative imports: leading dots
  while self:match(TT.OP, ".") do
    level = level + 1
  end
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
  return self:if_exp()
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
      or self:check(TT.NAME, "is") or self:check(TT.NAME, "in")
      or self:check(TT.NAME, "not") do
    local op_tok = self:advance()
    local op = CMPOP_MAP[op_tok.value] or op_tok.value
    if op_tok.value == "is" and self:match(TT.NAME, "not") then op = "IsNot" end
    if op_tok.value == "in" and self:match(TT.NAME, "not") then op = "NotIn" end
    if op_tok.value == "not" and self:match(TT.NAME, "in") then op = "NotIn" end
    table.insert(ops, op)
    table.insert(comparators, self:arith_expr())
  end
  if #ops > 0 then
    return node(NT.Compare, {left = left, ops = ops, comparators = comparators, lineno = 0, col_offset = 0})
  end
  return left
end

function Parser:expr_or_starred()
  if self:check(TT.OP, "*") then
    self:advance()
    local inner = self:expr()
    return node(NT.Starred, {value = inner, lineno = 0, col_offset = 0})
  end
  return self:expr()
end

function Parser:arith_expr()
  local result = self:shift_expr()
  while self:check2(TT.OP, "+", TT.OP, "-") do
    local op_tok = self:advance()
    local op = BINOP_MAP[op_tok.value]
    local right = self:shift_expr()
    result = node(NT.BinOp, {left = result, op = op, right = right, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:shift_expr()
  local result = self:term()
  while self:check2(TT.OP, "<<", TT.OP, ">>") do
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
      or self:check2(TT.OP, "%", TT.OP, "//")
      or self:check(TT.OP, "|")
      or self:check(TT.OP, "&")
      or self:check(TT.OP, "^") do
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

------------------------------------------------------------------------------
-- Comprehension / generator-expression helpers
-- Parses one or more 'for'/'if' clauses: for target in iter [if cond] [...]
------------------------------------------------------------------------------

-- Parse a comprehension target: a name or a parenthesized tuple of names.
-- Stops before the 'in' keyword (which comparison() would otherwise consume).
function Parser:comp_target()
  local t = self:peek()
  if t.type == TT.NAME then
    self:advance()
    local name_node = node(NT.Name, {id = t.value, ctx = "Store", lineno = 0, col_offset = 0})
    -- Handle comma-separated tuple: x, y in ... or name, (a, b) in ...
    if self:match(TT.OP, ",") then
      local elts = {name_node}
      repeat
        local t2 = self:peek()
        if t2.type == TT.OP and t2.value == "(" then
          -- Nested tuple: name, (a, b) in ...
          self:advance() -- consume (
          local inner = {}
          if not self:check(TT.OP, ")") then
            table.insert(inner, self:expect(TT.NAME))
            while self:match(TT.OP, ",") do
              if self:check(TT.OP, ")") then break end
              table.insert(inner, self:expect(TT.NAME))
            end
          end
          self:expect(TT.OP, ")")
          table.insert(elts, node(NT.Tuple, {elts = inner, lineno = 0, col_offset = 0}))
        else
          local nt = self:expect(TT.NAME)
          table.insert(elts, node(NT.Name, {id = nt.value, ctx = "Store", lineno = 0, col_offset = 0}))
        end
        if self:check(TT.NAME, "in") then break end
      until not self:match(TT.OP, ",")
      return node(NT.Tuple, {elts = elts, lineno = 0, col_offset = 0})
    end
    return name_node
  elseif t.type == TT.OP and t.value == "(" then
    self:advance()
    local elts = {}
    if not self:check(TT.OP, ")") then
      table.insert(elts, self:comp_target())
      while self:match(TT.OP, ",") do
        if self:check(TT.OP, ")") then break end
        table.insert(elts, self:comp_target())
      end
    end
    self:expect(TT.OP, ")")
    return node(NT.Tuple, {elts = elts, lineno = 0, col_offset = 0})
  else
    return self:expr()
  end
end

-- Parse comp_iter clauses starting at a 'for' token.
-- Returns a list of {target, iter, ifs} clause tables.
function Parser:comp_clauses()
  local clauses = {}
  while self:check(TT.NAME, "for") do
    self:advance() -- consume 'for'
    local target = self:comp_target()
    self:expect(TT.NAME, "in")
    -- Use the non-ternary expression chain so a trailing 'if' starts a new
    -- clause instead of being swallowed as a conditional expression.
    local iter = self:test_nocond()
    local ifs = {}
    while self:match(TT.NAME, "if") do
      table.insert(ifs, self:test_nocond())
    end
    table.insert(clauses, {target = target, iter = iter, ifs = ifs})
  end
  return clauses
end

-- Wrap a generator-expression body: '(' elt for target in iter [if cond] ')'.
function Parser:genexp_body(elt)
  local clauses = self:comp_clauses()
  self:expect(TT.OP, ")")
  return node(NT.GeneratorExp, {elt = elt, generators = clauses, lineno = 0, col_offset = 0})
end

function Parser:power()
  local base = self:atom()
  -- postfix trailers: attribute access, subscript, call (bind tighter than **)
  while true do
    local t2 = self:peek()
    if t2.type == TT.OP and t2.value == "." then
      self:advance()
      local name_tok = self:expect(TT.NAME)
      base = node(NT.Attribute, {value = base, attr = name_tok.value, lineno = name_tok.line, col_offset = name_tok.col})
    elseif t2.type == TT.OP and t2.value == "[" then
      self:advance()
      if self:check(TT.OP, "]") then
        self:advance()
        base = node(NT.Subscript, {value = base, slice = node(NT.Constant, {value = nil}), lineno = 0, col_offset = 0})
      else
        -- Handle slice notation: [start:stop:step]
        local lower = nil
        if not self:check(TT.OP, ":") then
          lower = self:expr()
        end
        if self:match(TT.OP, ":") then
          local upper = nil
          if not self:check(TT.OP, "]") then
            upper = self:expr()
          end
          local step = nil
          if self:match(TT.OP, ":") then
            if not self:check(TT.OP, "]") then
              step = self:expr()
            end
          end
          self:expect(TT.OP, "]")
          base = node(NT.Subscript, {value = base, slice = node(NT.Slice, {lower = lower, upper = upper, step = step, lineno = 0, col_offset = 0}), lineno = 0, col_offset = 0})
        else
          local slices = {lower}
          while self:match(TT.OP, ",") do
            if self:check(TT.OP, "]") then break end
            table.insert(slices, self:expr())
          end
          self:expect(TT.OP, "]")
          if #slices == 1 then
            base = node(NT.Subscript, {value = base, slice = slices[1], lineno = 0, col_offset = 0})
          else
            base = node(NT.Subscript, {value = base, slice = node(NT.Tuple, {elts = slices, lineno = 0, col_offset = 0}), lineno = 0, col_offset = 0})
          end
        end
      end
    elseif t2.type == TT.OP and t2.value == "(" then
      self:advance()
      local args = {}
      local keywords = {}
      if not self:check(TT.OP, ")") then
        local first_arg = self:expr_or_starred()
        if self:match(TT.OP, "=") then
          local kw_name = first_arg.id or tostring(first_arg)
          local kw_val = self:expr()
          table.insert(keywords, {arg = kw_name, value = kw_val})
        else
          table.insert(args, first_arg)
          -- Generator expression as call argument: f(elt for target in iter [if cond])
          if self:check(TT.NAME, "for") then
            local clauses = self:comp_clauses()
            self:expect(TT.OP, ")")
            local gen = node(NT.GeneratorExp, {elt = args[1], generators = clauses, lineno = 0, col_offset = 0})
            base = node(NT.Call, {func = base, args = {gen}, lineno = 0, col_offset = 0})
          end
        end
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, ")") then break end
          local arg_expr = self:expr_or_starred()
          if self:match(TT.OP, "=") then
            local kw_name = arg_expr.id or tostring(arg_expr)
            local kw_val = self:expr()
            table.insert(keywords, {arg = kw_name, value = kw_val})
          else
            table.insert(args, arg_expr)
          end
        end
      end
      if self:check(TT.OP, ")") then
        self:expect(TT.OP, ")")
      end
      local call_node = node(NT.Call, {func = base, args = args, lineno = 0, col_offset = 0})
      if #keywords > 0 then
        call_node.keywords = keywords
      end
      base = call_node
    else
      break
    end
  end
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
    local result = node(NT.Constant, {value = v, lineno = tok.line, col_offset = tok.col})
    -- Handle implicit string concatenation: "hello" "world" or "hello" f"world"
    while true do
        local next_tok = self:peek()
        if next_tok.type == TT.STRING then
            self:advance()
            local next_node = node(NT.Constant, {value = next_tok.value, lineno = next_tok.line, col_offset = next_tok.col})
            result = node(NT.BinOp, {left = result, op = "concat", right = next_node, lineno = 0, col_offset = 0})
        elseif next_tok.type == TT.NAME and (next_tok.value == "f" or next_tok.value == "F") then
            -- Check if f/F is followed by a string (f-string)
            self:advance() -- consume f/F
            local str_tok = self:peek()
            if str_tok.type == TT.STRING then
                self:advance() -- consume string
                local fnode = self:parse_fstring(str_tok.value, str_tok.line, str_tok.col)
                result = node(NT.BinOp, {left = result, op = "concat", right = fnode, lineno = 0, col_offset = 0})
            else
                -- Not an f-string, put f back? Can't un-advance easily.
                -- Just break and let the caller handle the f token
                break
            end
        else
            break
        end
    end
    return result
  elseif t == TT.NAME then
    self:advance()
    -- f-string: f"..." or F"..."  (f immediately followed by a string literal)
    if (v == "f" or v == "F") and self:check(TT.STRING) then
      local str_tok = self:advance()
      return self:parse_fstring(str_tok.value, str_tok.line, str_tok.col)
    end
    -- lambda: lambda args: body  (lambda is a NAME token, not OP)
    if v == "lambda" then
      local args = {}
      if not self:check2(TT.NAME, "in", TT.NAME, "if") and not self:newline_or_eof() and not self:check(TT.OP, ":") then
        repeat
          table.insert(args, self:expect(TT.NAME).value)
        until not self:match(TT.OP, ",")
      end
      self:expect(TT.OP, ":")
      local body = self:expr()
      return node(NT.Lambda, {args = args, body = body, lineno = tok.line, col_offset = tok.col})
    end
    local ctx = "Load"
    local name_node = node(NT.Name, {id = v, ctx = ctx, lineno = tok.line, col_offset = tok.col})
    -- Check for function call: name(args)
    if self:check(TT.OP, "(") then
      self:advance() -- consume (
      local args = {}
      local keywords = {}
      if not self:check(TT.OP, ")") then
        local first_arg = self:expr()
        if self:match(TT.OP, "=") then
          local kw_name = first_arg.id or tostring(first_arg)
          local kw_val = self:expr()
          table.insert(keywords, {arg = kw_name, value = kw_val})
        else
          table.insert(args, first_arg)
        end
        if self:check(TT.NAME, "for") then
          -- generator expression as call argument: f(elt for target in iter [if cond])
          local clauses = self:comp_clauses()
          self:expect(TT.OP, ")")
          local gen = node(NT.GeneratorExp, {elt = args[1], generators = clauses, lineno = 0, col_offset = 0})
          return node(NT.Call, {func = name_node, args = {gen}, lineno = tok.line, col_offset = tok.col})
        end
        while self:match(TT.OP, ",") do
          if self:check(TT.OP, ")") then break end
          local arg_expr = self:expr()
          if self:match(TT.OP, "=") then
            local kw_name = arg_expr.id or tostring(arg_expr)
            local kw_val = self:expr()
            table.insert(keywords, {arg = kw_name, value = kw_val})
          else
            table.insert(args, arg_expr)
          end
        end
      end
      self:expect(TT.OP, ")")
      local call_node = node(NT.Call, {func = name_node, args = args, lineno = tok.line, col_offset = tok.col})
      if #keywords > 0 then
        call_node.keywords = keywords
      end
      return call_node
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
      if self:check(TT.NAME, "for") then
        -- generator expression: (elt for target in iter [if cond])
        local clauses = self:comp_clauses()
        self:expect(TT.OP, ")")
        return node(NT.GeneratorExp, {elt = expr, generators = clauses, lineno = 0, col_offset = 0})
      end
      if self:match(TT.OP, ",") then
        local elts = {expr}
        repeat
          if self:check(TT.OP, ")") then break end
          table.insert(elts, self:expr())
        until not self:match(TT.OP, ",")
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
      if self:check(TT.NAME, "for") then
        -- list comprehension: [elt for target in iter [if cond]]
        local clauses = self:comp_clauses()
        self:expect(TT.OP, "]")
        return node(NT.ListComp, {elt = first, generators = clauses, lineno = 0, col_offset = 0})
      end
      if self:match(TT.OP, ",") then
        local elts = {first}
        repeat
          if self:check(TT.OP, "]") then break end
          table.insert(elts, self:expr())
        until not self:match(TT.OP, ",")
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
      if self:check(TT.NAME, "for") then
        -- set comprehension: {elt for target in iter [if cond]}
        local clauses = self:comp_clauses()
        self:expect(TT.OP, "}")
        return node(NT.SetComp, {elt = key, generators = clauses, lineno = 0, col_offset = 0})
      end
      if self:match(TT.OP, ":") then
        local keys = {key}
        local values = {self:expr()}
        if self:check(TT.NAME, "for") then
          -- dict comprehension: {k: v for target in iter [if cond]}
          local clauses = self:comp_clauses()
          self:expect(TT.OP, "}")
          return node(NT.DictComp, {key = keys[1], value = values[1], generators = clauses, lineno = 0, col_offset = 0})
        end
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
    else
      error("Unexpected operator in atom: " .. v .. " at line " .. tok.line)
    end
  else
    error("Unexpected token: " .. t .. " (" .. (v or "") .. ") at line " .. tok.line)
  end
end

------------------------------------------------------------------------------
-- f-string parsing
-- f"literal {expr} literal" -> JoinedStr with Constant and FormattedValue children
------------------------------------------------------------------------------

-- Parse a Python expression from a standalone string (used for f-string {expr} parts).
function Parser:parse_expr_from_string(expr_str)
  local lexer = Lexer.new(expr_str)
  local p = Parser.new(lexer.tokens)
  local result = p:expr()
  p:expect(TT.EOF)
  return result
end

-- Strip surrounding quotes from an f-string token value and return the inner content.
function Parser:_strip_fstring_quotes(str_value)
  local content = str_value
  local quote = content:sub(1, 1)
  local triple = false
  if content:sub(1, 3) == quote .. quote .. quote then
    triple = true
    content = content:sub(4, #content - 3)
  else
    content = content:sub(2, #content - 1)
  end
  return content
end

-- Find the first occurrence of `special` at top-level delimiter depth (outside {}, [], (), and quotes) within `s`.
local function _split_at_depth0(s, special)
  local brace = 0
  local bracket = 0
  local paren = 0
  local in_quote = nil
  local escape = false
  for j = 1, #s do
    local ch = s:sub(j, j)
    if in_quote then
      if escape then
        escape = false
      elseif ch == "\\" then
        escape = true
      elseif ch == in_quote then
        in_quote = nil
      end
    else
      if ch == "'" or ch == '"' then
        in_quote = ch
      elseif ch == "{" then
        brace = brace + 1
      elseif ch == "}" then
        brace = math.max(0, brace - 1)
      elseif ch == "[" then
        bracket = bracket + 1
      elseif ch == "]" then
        bracket = math.max(0, bracket - 1)
      elseif ch == "(" then
        paren = paren + 1
      elseif ch == ")" then
        paren = math.max(0, paren - 1)
      elseif brace == 0 and bracket == 0 and paren == 0 and ch == special then
        return j
      end
    end
  end
  return nil
end

-- Wrap a string in Lua double quotes, escaping any embedded double quotes.
local function _lua_str(s)
  s = s:gsub('"', '\\"')
  return '"' .. s .. '"'
end

-- Parse an f-string token value into a JoinedStr node.
function Parser:parse_fstring(str_value, line, col)
  local content = self:_strip_fstring_quotes(str_value)
  local values = {}
  local i = 1
  local len = #content

  while i <= len do
    local c = content:sub(i, i)

    if c == "{" then
      -- Escaped {{
      if content:sub(i, i + 1) == "{{" then
        table.insert(values, node(NT.Constant, {value = _lua_str("{"), lineno = line, col_offset = col}))
        i = i + 2
      else
        -- Find matching closing brace, tracking nesting depth and string literals
        i = i + 1 -- skip {
        local expr_start = i
        local depth = 1
        local in_q = nil
        local esc = false
        while i <= len and depth > 0 do
          local cc = content:sub(i, i)
          if in_q then
            if esc then
              esc = false
            elseif cc == "\\" then
              esc = true
            elseif cc == in_q then
              in_q = nil
            end
          else
            if cc == "'" or cc == '"' then
              in_q = cc
            elseif cc == "{" then
              depth = depth + 1
            elseif cc == "}" then
              depth = depth - 1
            end
          end
          if depth > 0 then
            i = i + 1
          end
        end
        local inner = content:sub(expr_start, i - 1)
        i = i + 1 -- skip closing }

        -- Split off conversion (!r, !s, !a) and format spec (:...)
        local conversion = nil
        local conv_pos = _split_at_depth0(inner, "!")
        local fmt_pos = _split_at_depth0(inner, ":")

        if conv_pos then
          conversion = inner:sub(conv_pos + 1, conv_pos + 1)
          inner = inner:sub(1, conv_pos - 1)
        end
        if fmt_pos then
          inner = inner:sub(1, fmt_pos - 1)
        end

        -- Trim whitespace from expression
        inner = inner:match("^%s*(.-)%s*$")

        local expr_node
        if inner == "" or inner == nil then
          error("Empty expression in f-string at line " .. line)
        else
          expr_node = self:parse_expr_from_string(inner)
        end

        table.insert(values, node(NT.FormattedValue, {
          value = expr_node,
          conversion = conversion,
          lineno = line,
          col_offset = col
        }))
      end
    elseif c == "}" then
      -- Escaped }}
      if content:sub(i, i + 1) == "}}" then
        table.insert(values, node(NT.Constant, {value = _lua_str("}"), lineno = line, col_offset = col}))
        i = i + 2
      else
        error("Unexpected '}' in f-string at line " .. line)
      end
    else
      -- Accumulate literal text
      local lit_start = i
      while i <= len do
        local cc = content:sub(i, i)
        if cc == "{" or cc == "}" then break end
        i = i + 1
      end
      local lit = content:sub(lit_start, i - 1)
      table.insert(values, node(NT.Constant, {value = _lua_str(lit), lineno = line, col_offset = col}))
    end
  end

  return node(NT.JoinedStr, {values = values, lineno = line, col_offset = col})
end

function Parser:test_nocond()
  return self:or_test_nocond()
end

function Parser:or_test_nocond()
  local result = self:and_test_nocond()
  while self:match(TT.NAME, "or") do
    local right = self:and_test_nocond()
    result = node(NT.BoolOp, {op = "Or", values = {result, right}, lineno = 0, col_offset = 0})
  end
  return result
end

function Parser:and_test_nocond()
  local result = self:not_test_nocond()
  while self:match(TT.NAME, "and") do
    local right = self:not_test_nocond()
    result = node(NT.BoolOp, {op = "And", values = {result, right}, lineno = 0, col_offset = 0})
  end
  return result
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
      or self:check(TT.NAME, "is") or self:check(TT.NAME, "in")
      or self:check(TT.NAME, "not") do
    local op_tok = self:advance()
    local op = CMPOP_MAP[op_tok.value] or op_tok.value
    if op_tok.value == "is" and self:match(TT.NAME, "not") then op = "IsNot" end
    if op_tok.value == "in" and self:match(TT.NAME, "not") then op = "NotIn" end
    if op_tok.value == "not" and self:match(TT.NAME, "in") then op = "NotIn" end
    table.insert(ops, op)
    table.insert(comparators, self:arith_expr())
  end
  if #ops > 0 then
    return node(NT.Compare, {left = left, ops = ops, comparators = comparators, lineno = 0, col_offset = 0})
  end
  return left
end

function Parser:if_exp()
  local body = self:or_test_nocond()
  if self:match(TT.NAME, "if") then
    local cond = self:or_test_nocond()
    self:expect(TT.NAME, "else")
    local orelse = self:or_test_nocond()
    return node(NT.IfExp, {test = cond, body = body, orelse = orelse, lineno = 0, col_offset = 0})
  end
  return body
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
    if self:check(TT.NEWLINE) or self:check(TT.NL) or self:check(TT.DEDENT) or self:check(TT.COMMENT) then
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
