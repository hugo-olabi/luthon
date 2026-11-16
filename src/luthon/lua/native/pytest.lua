--[[
  Luthon Native Pytest Shim (src/luthon/lua/native/pytest.lua)
  ============================================================
  Provides pure-Lua fixture, mark, raises, skip, and approx primitives
  for testing Python suites without CPython frame inspection overhead.
--]]

local M = {}

-- Fixture decorator
M.fixture = function(...)
  local args = {...}
  if #args == 1 and type(args[1]) == "function" then
    return args[1]
  end
  return function(fn)
    return fn
  end
end

-- Parametrize and mark decorators
local function make_mark_decorator(...)
  local outer_args = {...}
  return function(fn)
    return fn
  end
end

M.mark = setmetatable({}, {
  __index = function(t, k)
    local m = function(...)
      return make_mark_decorator(...)
    end
    rawset(t, k, m)
    return m
  end
})

-- pytest.raises context manager
M.raises = function(expected_exc, ...)
  local cm = {
    __enter__ = function(self)
      return self
    end,
    __exit__ = function(self, exc_type, exc_val, tb)
      if exc_type == nil then
        error("AssertionError: DID NOT RAISE " .. tostring(expected_exc), 0)
      end
      local exc = exc_val ~= nil and exc_val or exc_type
      if _luthon_exc_match and _luthon_exc_match(exc, expected_exc) then
        return true -- suppressed!
      end
      local tname = type(expected_exc) == "string" and expected_exc or (expected_exc.__name or expected_exc.__type or tostring(expected_exc))
      local act_name = type(exc) == "table" and (exc.__name or exc.__type or (exc.__class__ and exc.__class__.__name__)) or tostring(exc)
      if tostring(act_name):find(tostring(tname), 1, true) then
        return true
      end
      return false -- re-raise
    end
  }
  return cm
end

M.skip = function(reason)
  return nil
end

M.param = function(...)
  return {...}
end

M.approx = function(val, rel, abs_tol)
  return setmetatable({val = val, rel = rel, abs = abs_tol}, {
    __eq = function(a, b)
      local v1 = type(a) == "table" and a.val or a
      local v2 = type(b) == "table" and b.val or b
      local diff = math.abs(v1 - v2)
      local tol = (abs_tol or 1e-6)
      if rel then tol = math.max(tol, rel * math.abs(v2)) end
      return diff <= tol
    end
  })
end

-- PyBridge delegation fallback for any other pytest attributes
local py_pytest = nil
setmetatable(M, {
  __index = function(t, k)
    if not py_pytest then
      local ok, pb = _G.pcall(_G.require, "src/luthon/lua/pybridge")
      if not ok or not pb then
        ok, pb = _G.pcall(_G.require, "luthon.lua.pybridge")
      end
      if ok and pb and pb.is_available() then
        local ok_imp, mod = _G.pcall(pb.import, "pytest")
        if ok_imp and mod then
          py_pytest = mod
        end
      end
    end
    if py_pytest then
      local val = py_pytest[k]
      if val ~= nil then
        rawset(t, k, val)
        return val
      end
    end
    return nil
  end
})

return M
