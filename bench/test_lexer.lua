local TT = {
  NAME = "NAME", NUMBER = "NUMBER", STRING = "STRING", OP = "OP",
  NEWLINE = "NEWLINE", NL = "NL", INDENT = "INDENT", DEDENT = "DEDENT",
  EOF = "EOF", COMMENT = "COMMENT", ENCODING = "ENCODING",
}

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

local source = "def fib(n):\n    if n < 2:\n        return n\n"

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
  self.newline_pending = nil
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
  if self.in_paren > 0 then
    self.newline_pending = "NL"
    return
  end
  self.newline_pending = "NEWLINE"
  self:skip_whitespace()
  if self:peek() == "\n" or self:peek() == "" then
    return
  end
  local indent = 0
  while self:peek() == " " do indent = indent + 1; self:advance() end
  while self:peek() == "\t" do indent = indent + 1; self:advance() end
  local cur = self.indent_stack[#self.indent_stack]
  if indent > cur then
    table.insert(self.indent_stack, indent)
    self.indent_pending = "INDENT"
  elseif indent < cur then
    while #self.indent_stack > 1 and self.indent_stack[#self.indent_stack] > indent do
      table.remove(self.indent_stack)
    end
    if self.indent_stack[#self.indent_stack] ~= indent then
      error("IndentationError: unexpected indent at line " .. self.line)
    end
    self.indent_pending = "DEDENT"
  end
end

function Lexer:tokenize()
  while self.pos <= #self.src do
    if self.indent_pending then
      local t = self.indent_pending
      self.indent_pending = nil
      table.insert(self.tokens, {type = t, line = self.line, col = self.col})
    end
    if self.newline_pending then
      local t = self.newline_pending
      self.newline_pending = nil
      table.insert(self.tokens, {type = t, line = self.line, col = self.col})
    end

    self:skip_whitespace()
    local c = self:peek()
    if c == "" then
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
end

local lexer = Lexer.new(source)
for i, t in ipairs(lexer.tokens) do
  print(string.format("Token %d: type=%s value=%s line=%d col=%d", i, t.type, tostring(t.value), t.line, t.col))
end
