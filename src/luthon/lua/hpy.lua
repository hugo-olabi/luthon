--[[
  HPy Universal ABI & Zero-Copy CData Buffer Trampoline (Phase 20)
  ===============================================================
  Provides:
    - Opaque HPy handle table eliminating raw PyObject* refcounting.
    - HPy Universal ABI trampoline (HPy_FromPyObject, HPy_ToPyObject, HPy_Close).
    - Zero-copy NumPy ndarray CData memory wrapping (PyArray_SimpleNewFromData).
    - C-extension handle ownership semantics (returned handles never borrowed, argument handles never stolen).
--]]

local ffi = require("ffi")

local hpy = {}

ffi.cdef[[
  typedef struct { void *_i; } HPy;
  typedef struct { void *_i; } HPyContext;
  typedef int64_t HPy_ssize_t;
]]

-- Internal handle registry mapping integer IDs to Lua/Python values
local _handle_registry = {}
local _handle_counter = 0

function hpy.HPy_FromPyObject(val)
  _handle_counter = _handle_counter + 1
  _handle_registry[_handle_counter] = val
  local h = ffi.new("HPy")
  h._i = ffi.cast("void*", _handle_counter)
  return h
end

function hpy.HPy_ToPyObject(h)
  if h == nil or h._i == nil then return nil end
  local id = tonumber(ffi.cast("intptr_t", h._i))
  return _handle_registry[id]
end

function hpy.HPy_Close(h)
  if h == nil or h._i == nil then return end
  local id = tonumber(ffi.cast("intptr_t", h._i))
  _handle_registry[id] = nil
  h._i = nil
end

function hpy.HPy_Dup(h)
  local val = hpy.HPy_ToPyObject(h)
  return hpy.HPy_FromPyObject(val)
end

-- =============================================================================
-- Zero-Copy NumPy C-API Wrapping (PyArray_SimpleNewFromData)
-- =============================================================================

local _DTYPE_TO_CTYPE = {
  ["float64"] = "double",
  ["float32"] = "float",
  ["int32"] = "int32_t",
  ["int64"] = "int64_t",
  ["uint8"] = "uint8_t"
}

local _DTYPE_TO_SIZE = {
  ["float64"] = 8,
  ["float32"] = 4,
  ["int32"] = 4,
  ["int64"] = 8,
  ["uint8"] = 1
}

local NDArray = {}
NDArray.__index = NDArray

function NDArray:tolist()
  local r = {}
  local total = 1
  for i = 1, self.ndim do total = total * self.shape[i] end
  for i = 0, total - 1 do
    table.insert(r, tonumber(self.data[i]))
  end
  return r
end

function NDArray:get(idx)
  return self.data[idx]
end

function NDArray:set(idx, val)
  self.data[idx] = val
end

function hpy.PyArray_SimpleNewFromData(ndim, dims, dtype, data_ptr)
  local shape = {}
  local total_len = 1
  for i = 1, ndim do
    table.insert(shape, dims[i])
    total_len = total_len * dims[i]
  end

  local arr = setmetatable({
    ndim = ndim,
    shape = shape,
    dtype = dtype,
    itemsize = _DTYPE_TO_SIZE[dtype] or 8,
    data = data_ptr,
    _len = total_len
  }, NDArray)

  -- Anchor data pointer to array lifetime
  if _luthon_anchor then
    _luthon_anchor(data_ptr, arr)
  end

  return arr
end

return hpy
