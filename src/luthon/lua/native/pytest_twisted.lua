--[[
  Luthon Native pytest_twisted Shim (src/luthon/lua/native/pytest_twisted.lua)
  =============================================================================
  Provides pytest_twisted.inlineCallbacks decorator delegating to Twisted's
  defer.inlineCallbacks or transparent function passthrough.
--]]

local M = {}

local function make_fixture_decorator(...)
  local args = {...}
  if #args == 1 and type(args[1]) == "function" then
    return args[1]
  end
  return function(fn)
    return fn
  end
end

M.async_yield_fixture = make_fixture_decorator
M.async_fixture = make_fixture_decorator
M.fixture = make_fixture_decorator
M.ensureDeferred = function(fn) return fn end
M.use_asyncio = function(...) return make_fixture_decorator(...) end

M.inlineCallbacks = function(fn)
  local ok, pb = pcall(require, "src/luthon/lua/pybridge")
  if not ok or not pb then
    ok, pb = pcall(require, "luthon.lua.pybridge")
  end
  if ok and pb and pb.is_available() then
    local ok_defer, dmod = pcall(pb.import, "twisted.internet.defer")
    if ok_defer and dmod and dmod.inlineCallbacks then
      return dmod.inlineCallbacks(fn)
    end
  end
  return fn
end

setmetatable(M, {
  __index = function(t, k)
    local ok, pb = pcall(require, "src/luthon/lua/pybridge")
    if not ok or not pb then
      ok, pb = pcall(require, "luthon.lua.pybridge")
    end
    if ok and pb and pb.is_available() then
      local ok_pt, pt = pcall(pb.import, "pytest_twisted")
      if ok_pt and pt and pt[k] ~= nil then
        return pt[k]
      end
    end
    return nil
  end
})

return M
