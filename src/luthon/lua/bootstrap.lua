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

function bool(x) return x ~= nil and x ~= false end

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
-- String methods (attached via metatable)
------------------------------------------------------------------------------

local strmt = {}
strmt.__index = function(s, k)
  if type(k) == "string" then
    if k == "upper" then
      return function(self) return string.upper(self) end
    elseif k == "lower" then
      return function(self) return string.lower(self) end
    elseif k == "strip" then
      return function(self) return self:match("^%s*(.-)%s*$") end
    elseif k == "split" then
      return function(self, sep)
        sep = sep or "%s"
        local r = {}
        for part in self:gmatch("([^" .. sep .. "]+)") do r[#r + 1] = part end
        return r
      end
    elseif k == "replace" then
      return function(self, a, b) return self:gsub(a, b) end
    elseif k == "startswith" then
      return function(self, p) return self:sub(1, #p) == p end
    elseif k == "endswith" then
      return function(self, p) return self:sub(-#p) == p end
    elseif k == "find" then
      return function(self, p) return self:find(p, 1, true) end
    end
  end
  return nil
end
debug.setmetatable("", strmt)

------------------------------------------------------------------------------
-- Exception classes (matchable by except, constructable via raise)
------------------------------------------------------------------------------

for _, cls in ipairs({
  "ValueError", "TypeError", "AssertionError", "NameError",
  "KeyError", "IndexError",
}) do
  _G[cls] = { __name = cls, __type = cls }
  setmetatable(_G[cls], {
    __call = function(c, m)
      return { __type = c.__type, __msg = tostring(m or "") }
    end,
  })
end

------------------------------------------------------------------------------
-- IR runtime helpers
------------------------------------------------------------------------------

function _luthon_exc_match(exc, cls)
  if type(exc) ~= "table" then return false end
  local tname = type(cls) == "string" and cls or (cls.__name or cls.__type or tostring(cls))
  return exc.__type == tname
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
