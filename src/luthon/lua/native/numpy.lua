--[[
  Luthon Native NumPy Shim (src/luthon/lua/native/numpy.lua)
  ==========================================================
  Provides zero-CPython, high-performance ndarray support using LuaJIT FFI:
    - np.array(img_or_seq)
    - np.stack(list_of_arrays, axis=-1)
    - np.any(cond)
    - Multi-dimensional strided slicing (arr[:, :, 0], arr[:, :, 1], arr[:, :, 2], arr[:, :, 3])
    - Comparison operators (arr > 0)
    - Metamethods: __bool__, __len__, __index
--]]

local ffi = require("ffi")

local np = {}

local ndarray_mt = {}
ndarray_mt.__index = ndarray_mt

function ndarray_mt:__len__()
  return self.shape[1] or 0
end

function ndarray_mt:__bool__()
  -- Python semantics: truth value of an array with more than one element is ambiguous
  -- But for scalars or bool masks checked with bool(np.any(...)), np.any returns a boolean
  if self.ndim == 0 or (self.shape[1] == 1 and self.shape[2] == 1 and (self.shape[3] or 1) == 1) then
    return self.data[0] ~= 0
  end
  error("ValueError: The truth value of an array with more than one element is ambiguous. Use a.any() or a.all()")
end

-- Comparison: arr > val
function ndarray_mt:__gt__(val)
  if type(self) ~= "table" then
    -- Reversed call: e.g. 0 < arr dispatched to __gt__(0, arr)
    return val:lt(self)
  end
  return self:gt(val)
end
ndarray_mt.__gt = ndarray_mt.__gt__

function ndarray_mt:__lt__(val)
  if type(self) ~= "table" then
    -- Reversed call: e.g. arr > 0 inverted by Lua to 0 < arr -> __lt__(0, arr)
    return val:gt(self)
  end
  return self:lt(val)
end
ndarray_mt.__lt = ndarray_mt.__lt__

function ndarray_mt:gt(val)
  local total = 1
  for _, d in ipairs(self.shape) do total = total * d end

  local out_data = ffi.new("uint8_t[?]", total)
  local threshold = tonumber(val) or 0

  -- Traverse elements
  if self.ndim == 2 then
    local h, w = self.shape[1], self.shape[2]
    local s0, s1 = self.strides[1], self.strides[2]
    local idx = 0
    for y = 0, h - 1 do
      local row_off = y * s0
      for x = 0, w - 1 do
        out_data[idx] = (self.data[row_off + x * s1] > threshold) and 1 or 0
        idx = idx + 1
      end
    end
  elseif self.ndim == 3 then
    local h, w, c = self.shape[1], self.shape[2], self.shape[3]
    local s0, s1, s2 = self.strides[1], self.strides[2], self.strides[3]
    local idx = 0
    for y = 0, h - 1 do
      local row_off = y * s0
      for x = 0, w - 1 do
        local col_off = row_off + x * s1
        for ch = 0, c - 1 do
          out_data[idx] = (self.data[col_off + ch * s2] > threshold) and 1 or 0
          idx = idx + 1
        end
      end
    end
  else
    for i = 0, total - 1 do
      out_data[i] = (self.data[i] > threshold) and 1 or 0
    end
  end

  local res = {
    data = out_data,
    shape = {unpack(self.shape)},
    strides = {unpack(self.shape)}, -- contiguous
    ndim = self.ndim,
    dtype = "bool",
  }
  -- Compute standard contiguous strides
  local acc = 1
  for i = #res.shape, 1, -1 do
    res.strides[i] = acc
    acc = acc * res.shape[i]
  end

  return setmetatable(res, ndarray_mt)
end

-- Comparison: arr < val
function ndarray_mt:__lt__(val)
  local total = 1
  for _, d in ipairs(self.shape) do total = total * d end
  local out_data = ffi.new("uint8_t[?]", total)
  local threshold = tonumber(val) or 0
  for i = 0, total - 1 do
    out_data[i] = (self.data[i] < threshold) and 1 or 0
  end
  local res = {
    data = out_data,
    shape = {unpack(self.shape)},
    strides = {unpack(self.strides)},
    ndim = self.ndim,
    dtype = "bool",
  }
  return setmetatable(res, ndarray_mt)
end

-- Multi-dimensional indexing: arr[tuple] or arr[idx]
local raw_index = ndarray_mt.__index
ndarray_mt.__index = function(self, key)
  if type(key) == "string" then
    if raw_index[key] ~= nil then return raw_index[key] end
    if key == "shape" or key == "data" or key == "ndim" or key == "dtype" or key == "strides" then
      return rawget(self, key)
    end
    return nil
  end

  -- Tuple indexing: arr[:, :, 0], arr[:, :, 2], arr[:, :, 3], arr[:, :, 1]
  if type(key) == "table" and (getmetatable(key) == _G._tuple_mt or #key > 0) then
    -- Key is a list/tuple of dimensions, e.g. {slice, slice, 0}
    if self.ndim == 3 and #key == 3 then
      local dim0, dim1, dim2 = key[1], key[2], key[3]
      -- Common pattern in process_textures.py: arr[:, :, channel_idx]
      local is_dim0_full = type(dim0) == "table" and dim0.__slice__ and (dim0.start == nil or dim0.start == 0) and (dim0.stop == nil)
      local is_dim1_full = type(dim1) == "table" and dim1.__slice__ and (dim1.start == nil or dim1.start == 0) and (dim1.stop == nil)
      if (is_dim0_full or dim0 == nil) and (is_dim1_full or dim1 == nil) and type(dim2) == "number" then
        local ch = dim2
        local h, w = self.shape[1], self.shape[2]
        local s0, s1, s2 = self.strides[1], self.strides[2], self.strides[3]
        local base_offset = ch * s2

        -- Return a 2D channel view / slice
        local view = {
          data = self.data + base_offset,
          parent_data = self.data, -- keep reference alive
          shape = {h, w},
          strides = {s0, s1},
          ndim = 2,
          dtype = self.dtype,
        }
        return setmetatable(view, ndarray_mt)
      end
    end
  end

  -- 1D integer index
  if type(key) == "number" then
    local idx = key
    if self.ndim == 1 then
      return self.data[idx]
    elseif self.ndim == 2 then
      local w = self.shape[2]
      local s0 = self.strides[1]
      local view = {
        data = self.data + idx * s0,
        parent_data = self.data,
        shape = {w},
        strides = {self.strides[2]},
        ndim = 1,
        dtype = self.dtype,
      }
      return setmetatable(view, ndarray_mt)
    end
  end

  return nil
end

function np.array(obj)
  if type(obj) == "table" and getmetatable(obj) == ndarray_mt then
    return obj
  end

  -- Image object: has .size, .mode, .tobytes() or ._buffer
  if type(obj) == "table" and obj._buffer ~= nil and obj.size ~= nil then
    local w, h = obj.size[1], obj.size[2]
    local channels = 4
    if obj.mode == "RGBA" then channels = 4
    elseif obj.mode == "RGB" then channels = 3
    elseif obj.mode == "L" then channels = 1
    end

    local arr = {
      data = obj._buffer,
      parent_data = obj,
      shape = {h, w, channels},
      strides = {w * channels, channels, 1},
      ndim = 3,
      dtype = "uint8",
    }
    return setmetatable(arr, ndarray_mt)
  end

  -- Python / Lua table list of numbers
  if type(obj) == "table" then
    local n = #obj
    local data = ffi.new("double[?]", n)
    for i = 1, n do data[i - 1] = tonumber(obj[i]) or 0 end
    local arr = {
      data = data,
      shape = {n},
      strides = {1},
      ndim = 1,
      dtype = "float64",
    }
    return setmetatable(arr, ndarray_mt)
  end

  error("numpy.array: unsupported object type " .. type(obj))
end

local function _extract_kw(...)
  local total = select("#", ...)
  if total == 0 then return nil end
  local last = select(total, ...)
  if type(last) == "table" and not last.shape and not last._buffer then
    return last
  end
  return nil
end

-- np.stack([c0, c1, c2], axis=-1)
function np.stack(arrays, ...)
  local kw = _extract_kw(...)
  local axis = -1
  if kw and kw.axis ~= nil then
    axis = kw.axis
  else
    local a1 = select(1, ...)
    if type(a1) == "number" then
      axis = a1
    elseif type(a1) == "table" and a1.axis ~= nil then
      axis = a1.axis
    end
  end

  local num_arrays = #arrays
  if num_arrays == 0 then error("numpy.stack: empty array list") end

  local first = arrays[1]
  local h, w = first.shape[1], first.shape[2]
  local c = num_arrays

  -- Allocate contiguous memory for [h][w][c]
  local total_bytes = h * w * c
  local out_data = ffi.new("uint8_t[?]", total_bytes)

  -- Fast-path for 3-channel interleave (e.g. RGB / ORM maps)
  if num_arrays == 3 then
    local a0, a1, a2 = arrays[1], arrays[2], arrays[3]
    local s0_0, s0_1 = a0.strides[1], a0.strides[2]
    local s1_0, s1_1 = a1.strides[1], a1.strides[2]
    local s2_0, s2_1 = a2.strides[1], a2.strides[2]
    local src0, src1, src2 = a0.data, a1.data, a2.data
    for y = 0, h - 1 do
      local r0 = y * s0_0
      local r1 = y * s1_0
      local r2 = y * s2_0
      local dst_row = y * (w * 3)
      for x = 0, w - 1 do
        local dst_px = dst_row + x * 3
        out_data[dst_px]     = src0[r0 + x * s0_1]
        out_data[dst_px + 1] = src1[r1 + x * s1_1]
        out_data[dst_px + 2] = src2[r2 + x * s2_1]
      end
    end
  elseif num_arrays == 4 then
    local a0, a1, a2, a3 = arrays[1], arrays[2], arrays[3], arrays[4]
    local s0_0, s0_1 = a0.strides[1], a0.strides[2]
    local s1_0, s1_1 = a1.strides[1], a1.strides[2]
    local s2_0, s2_1 = a2.strides[1], a2.strides[2]
    local s3_0, s3_1 = a3.strides[1], a3.strides[2]
    local src0, src1, src2, src3 = a0.data, a1.data, a2.data, a3.data
    for y = 0, h - 1 do
      local r0 = y * s0_0
      local r1 = y * s1_0
      local r2 = y * s2_0
      local r3 = y * s3_0
      local dst_row = y * (w * 4)
      for x = 0, w - 1 do
        local dst_px = dst_row + x * 4
        out_data[dst_px]     = src0[r0 + x * s0_1]
        out_data[dst_px + 1] = src1[r1 + x * s1_1]
        out_data[dst_px + 2] = src2[r2 + x * s2_1]
        out_data[dst_px + 3] = src3[r3 + x * s3_1]
      end
    end
  else
    -- General N-channel copy
    for i = 1, num_arrays do
      local arr = arrays[i]
      local ch_idx = i - 1
      local s0, s1 = arr.strides[1], arr.strides[2]
      local src = arr.data
      for y = 0, h - 1 do
        local src_row = y * s0
        local dst_row = y * (w * c)
        for x = 0, w - 1 do
          out_data[dst_row + x * c + ch_idx] = src[src_row + x * s1]
        end
      end
    end
  end

  local res = {
    data = out_data,
    shape = {h, w, c},
    strides = {w * c, c, 1},
    ndim = 3,
    dtype = "uint8",
  }
  return setmetatable(res, ndarray_mt)
end

-- np.any(cond)
function np.any(cond)
  if type(cond) == "boolean" then return cond end
  if type(cond) == "number" then return cond ~= 0 end
  if type(cond) == "table" and getmetatable(cond) == ndarray_mt then
    local total = 1
    for _, d in ipairs(cond.shape) do total = total * d end

    if cond.ndim == 2 then
      local h, w = cond.shape[1], cond.shape[2]
      local s0, s1 = cond.strides[1], cond.strides[2]
      local src = cond.data
      for y = 0, h - 1 do
        local row = y * s0
        for x = 0, w - 1 do
          if src[row + x * s1] ~= 0 then return true end
        end
      end
      return false
    elseif cond.ndim == 3 then
      local h, w, c = cond.shape[1], cond.shape[2], cond.shape[3]
      local s0, s1, s2 = cond.strides[1], cond.strides[2], cond.strides[3]
      local src = cond.data
      for y = 0, h - 1 do
        local row = y * s0
        for x = 0, w - 1 do
          local col = row + x * s1
          for ch = 0, c - 1 do
            if src[col + ch * s2] ~= 0 then return true end
          end
        end
      end
      return false
    else
      for i = 0, total - 1 do
        if cond.data[i] ~= 0 then return true end
      end
      return false
    end
  end
  return false
end

return np
