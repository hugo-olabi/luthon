--[[
  Real-Time Zero-GC Preallocated Memory Freelists (Phase 21)
  ==========================================================
  Based on Snabb network architecture and low-latency financial systems:
  Eliminates garbage collector jitter during steady-state processing by
  recycling preallocated FFI memory buffers via stack-based index freelists.
--]]

local ffi = require("ffi")

local pool = {}

local Freelist = {}
Freelist.__index = Freelist

function Freelist.new(ctype_str, capacity)
  capacity = capacity or 1024
  local elem_size = ffi.sizeof(ctype_str)
  local pool_buf = ffi.new(ctype_str .. "[?]", capacity)
  local free_indices = ffi.new("int32_t[?]", capacity)
  for i = 0, capacity - 1 do
    free_indices[i] = i
  end

  local self = setmetatable({
    _ctype = ctype_str,
    _buf = pool_buf,
    _free_indices = free_indices,
    _capacity = capacity,
    _head = capacity - 1,
    _elem_size = elem_size,
    _allocated = 0
  }, Freelist)

  return self
end

function Freelist:acquire()
  if self._head < 0 then
    error("PoolExhaustedError: memory freelist pool capacity exceeded")
  end
  local idx = self._free_indices[self._head]
  self._head = self._head - 1
  self._allocated = self._allocated + 1
  return self._buf + idx, idx
end

function Freelist:release(idx_or_ptr)
  local idx
  if type(idx_or_ptr) == "number" then
    idx = idx_or_ptr
  else
    idx = tonumber(idx_or_ptr - self._buf)
  end
  if idx < 0 or idx >= self._capacity then
    error("ValueError: pointer or index outside freelist buffer boundaries")
  end
  self._head = self._head + 1
  self._free_indices[self._head] = idx
  self._allocated = self._allocated - 1
end

function Freelist:allocated()
  return self._allocated
end

function Freelist:capacity()
  return self._capacity
end

function pool.create_freelist(ctype_str, capacity)
  return Freelist.new(ctype_str, capacity)
end

return pool
