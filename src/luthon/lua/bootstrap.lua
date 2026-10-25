-- Luthon bootstrap prelude
-- Combined stdlib + IR runtime helpers for self-hosted Luthon.
-- This file is prepended to every transpiled Lua module.

------------------------------------------------------------------------------
-- Builtin functions
------------------------------------------------------------------------------

function range(a, b, step)
  if b == nil then a, b = 0, a; step = 1 end
  if step == nil then step = 1 end
  local r = {}
  if step > 0 then
    for i = a, b - 1, step do r[#r+1] = i end
  else
    for i = a, b + 1, step do r[#r+1] = i end
  end
  return r
end

function len(t) return #t end

function list(t)
  if type(t) == "function" then
    local r = {}
    for v in t do r[#r+1] = v end
    return r
  end
  local r = {}
  if t then
    for _, v in ipairs(t) do r[#r+1] = v end
  end
  return r
end

function sum(t)
  local s = 0
  for _, v in ipairs(t or {}) do s = s + v end
  return s
end

function iter(t)
  local i = 0
  return function()
    i = i + 1
    if i <= #t then return t[i] end
    return nil
  end
end

function str(x) return tostring(x) end

function int(x) return math.floor(tonumber(x) or 0) end

function float(x) return tonumber(x) or 0.0 end

function abs(x) return math.abs(x) end

function bool(x)
  if x == nil or x == false then return false end
  if type(x) == "number" then return x ~= 0 end
  if type(x) == "string" then return #x > 0 end
  if type(x) == "table" then
    if x.__bool__ then return x:__bool__() end
    if x.__len__ then return x:__len__() > 0 end
    return next(x) ~= nil
  end
  return true
end

function round(x, n)
  n = n or 0
  local f = 10 ^ n
  return math.floor(x * f + 0.5) / f
end

function min(...)
  local a = { ... }
  local m = a[1]
  for i = 2, #a do
    if a[i] < m then m = a[i] end
  end
  return m
end

function max(...)
  local a = { ... }
  local m = a[1]
  for i = 2, #a do
    if a[i] > m then m = a[i] end
  end
  return m
end

function sorted(t)
  local r = {}
  for i, v in ipairs(t) do r[i] = v end
  table.sort(r)
  return r
end

function reversed(t)
  local r = {}
  for i = #t, 1, -1 do r[#r + 1] = t[i] end
  return r
end

function enumerate(t)
  local r = {}
  for i, v in ipairs(t) do r[#r + 1] = { i - 1, v } end
  return r
end

function zip(a, b)
  local r = {}
  for i = 1, math.min(#a, #b) do r[#r + 1] = { a[i], b[i] } end
  return r
end

function map(f, t)
  local r = {}
  for i, v in ipairs(t) do r[#r + 1] = f(v) end
  return r
end

function filter(f, t)
  local r = {}
  for i, v in ipairs(t) do
    if f(v) then r[#r + 1] = v end
  end
  return r
end

function any(t)
  for _, v in ipairs(t) do
    if v then return true end
  end
  return false
end

function all(t)
  for _, v in ipairs(t) do
    if not v then return false end
  end
  return true
end

------------------------------------------------------------------------------
-- String methods (attached to string table)
------------------------------------------------------------------------------

string.upper = string.upper
string.lower = string.lower
string.strip = function(self) return string.match(self, "^%s*(.-)%s*$") end
string.lstrip = function(self) return string.match(self, "^%s*(.-)$") end
string.rstrip = function(self) return string.match(self, "^(.-)%s*$") end
string.split = function(self, sep)
  sep = sep or "%s"
  local r = {}
  for part in string.gmatch(self, "([^" .. sep .. "]+)") do r[#r + 1] = part end
  return r
end
string.replace = function(self, a, b) return (string.gsub(self, a, b)) end
string.startswith = function(self, p) return string.sub(self, 1, #p) == p end
string.endswith = function(self, p) return string.sub(self, -#p) == p end
string.find = function(self, p)
  local pos = string.find(self, p, 1, true)
  return pos and (pos - 1) or -1
end
string.join = function(self, t)
  local r = {}
  for i, v in ipairs(t or {}) do r[#r + 1] = tostring(v) end
  return table.concat(r, self)
end

------------------------------------------------------------------------------
-- Exception classes (matchable by except, constructable via raise)
------------------------------------------------------------------------------

for _, cls in ipairs({
  "Exception", "BaseException", "ValueError", "TypeError", "AssertionError",
  "NameError", "KeyError", "IndexError", "AttributeError", "RuntimeError",
  "StopIteration", "ZeroDivisionError", "FileNotFoundError", "IOError", "OSError"
}) do
  local exc_tbl = { __name = cls, __type = cls }
  setmetatable(exc_tbl, {
    __call = function(c, m)
      return { __name = c.__name, __type = c.__type, __msg = tostring(m or "") }
    end,
    __tostring = function(e)
      return e.__type .. (e.__msg and (": " .. e.__msg) or "")
    end
  })
  _G[cls] = exc_tbl
end

------------------------------------------------------------------------------
-- IR runtime helpers
------------------------------------------------------------------------------

function _luthon_exc_match(exc, cls)
  if type(exc) ~= "table" then
    if cls == "Exception" or cls == "BaseException" or cls == Exception or cls == BaseException then
      return true
    end
    return false
  end
  local tname = type(cls) == "string" and cls or (cls.__name or cls.__type or tostring(cls))
  if tname == "Exception" or tname == "BaseException" then return true end
  return exc.__type == tname or exc.__name == tname
end

function _luthon_assert_fail(test, msg)
  if not test then
    error({ __type = "AssertionError", __msg = tostring(msg or "") })
  end
  return true
end

function _luthon_with_enter(ctx)
  return ctx.__enter__(ctx)
end

function _luthon_with_exit(ctx, exc)
  if exc then
    return ctx.__exit__(ctx, exc.__type or "Exception", exc.__msg or "", nil)
  else
    return ctx.__exit__(ctx, nil, nil, nil)
  end
end

-- Slice support: _luthon_slice(lower, upper, step) creates a slice descriptor.
-- Tables get an __index metatable that handles slice descriptors.
function _luthon_slice(lower, upper, step)
  return {_is_slice = true, lower = lower, upper = upper, step = step or 1}
end

-- Attach __index to all tables to support slice access like t[:16]
local _slice_mt = {}
_slice_mt.__index = function(t, k)
  if type(k) == "table" and k._is_slice then
    local n = #t
    local lower = k.lower or 1
    if lower < 0 then lower = n + lower + 1 end
    local upper = k.upper
    if upper == nil then upper = n end
    if upper < 0 then upper = n + upper + 1 end
    local step = k.step or 1
    local r = {}
    local i = lower
    if step > 0 then
      while i <= upper do
        r[#r + 1] = t[i]
        i = i + step
      end
    else
      while i >= upper do
        r[#r + 1] = t[i]
        i = i + step
      end
    end
    return r
  end
  return rawget(t, k)
end
debug.setmetatable({}, _slice_mt)

function _luthon_in(a, b)
  if type(b) == "table" then
    for _, v in ipairs(b) do
      if v == a then return true end
    end
  end
  return false
end

function _luthon_not_in(a, b)
  return not _luthon_in(a, b)
end

-- Override error to handle exception tables
local _error = error
error = function(err, level)
  if type(err) == "table" then
    _error(tostring(err), level or 1)
  else
    _error(err, level or 1)
  end
end

-- Module system
_MODULES = _MODULES or {}

function _luthon_module(name, t)
  _MODULES[name] = t
  package.loaded[name] = t
  return t
end

-- Simple getattr (walk __index chain)
function _luthon_getattr(obj, name)
  local cls = getmetatable(obj) and getmetatable(obj).__index
  while cls do
    if cls[name] ~= nil then return cls[name] end
    cls = getmetatable(cls) and getmetatable(cls).__index
  end
  return nil
end
