--[[
  Luthon WebAssembly & Browser WebWorker JS Interoperability Bridge (Phase 41)
  =============================================================================
  Provides bi-directional data marshaling between JavaScript objects and Luthon types,
  and zero-copy WebAssembly linear memory exchange (ArrayBuffer / SharedArrayBuffer)
  for WebGL, WebGPU, and Canvas APIs.
--]]

local M = {}

------------------------------------------------------------------------------
-- 1. Bi-Directional Data Marshaling (JS <-> Luthon)
------------------------------------------------------------------------------

-- Convert Luthon / Lua value to JS-compatible representation or JSON descriptor
function M.to_js(val)
  if val == nil then
    return { __js_type = "null", value = nil }
  end
  local t = type(val)
  if t == "number" or t == "boolean" or t == "string" then
    return val
  end
  if t == "table" then
    -- Check if it's an array/list (sequential integer keys)
    local is_array = true
    local count = 0
    for k, _ in pairs(val) do
      count = count + 1
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        is_array = false
        break
      end
    end
    if is_array then
      local js_arr = {}
      for i = 1, #val do
        js_arr[i] = M.to_js(val[i])
      end
      return js_arr
    else
      local js_obj = {}
      for k, v in pairs(val) do
        js_obj[tostring(k)] = M.to_js(v)
      end
      return js_obj
    end
  end
  return tostring(val)
end

-- Convert JS value or descriptor into Luthon representation
function M.from_js(val)
  if val == nil then return nil end
  local t = type(val)
  if t == "number" or t == "boolean" or t == "string" then
    return val
  end
  if t == "table" then
    if val.__js_type == "null" or val.__js_type == "undefined" then
      return nil
    end
    -- Recursively convert table elements
    local res = {}
    for k, v in pairs(val) do
      res[k] = M.from_js(v)
    end
    return res
  end
  return val
end

------------------------------------------------------------------------------
-- 2. WebAssembly Linear Memory Zero-Copy Bridge
------------------------------------------------------------------------------

-- Descriptor wrapping a slice of WASM linear memory (SharedArrayBuffer / ArrayBuffer)
function M.create_buffer_view(pointer, byte_length, element_type)
  element_type = element_type or "f32"
  local type_sizes = {
    u8 = 1, i8 = 1,
    u16 = 2, i16 = 2,
    u32 = 4, i32 = 4,
    f32 = 4, f64 = 8
  }
  local item_size = type_sizes[element_type] or 4
  local count = math.floor(byte_length / item_size)

  return {
    __wasm_memory_view = true,
    pointer = pointer,
    byte_length = byte_length,
    element_type = element_type,
    element_count = count,
    item_size = item_size,
  }
end

-- Generate JS code snippet / instruction to instantiate a zero-copy TypedArray on WASM memory
function M.export_to_typed_array(view)
  if not view or not view.__wasm_memory_view then
    error("Invalid buffer view passed to export_to_typed_array")
  end
  local constructors = {
    u8 = "Uint8Array",
    i8 = "Int8Array",
    u16 = "Uint16Array",
    i16 = "Int16Array",
    u32 = "Uint32Array",
    i32 = "Int32Array",
    f32 = "Float32Array",
    f64 = "Float64Array",
  }
  local ctor = constructors[view.element_type] or "Uint8Array"
  return {
    constructor = ctor,
    byteOffset = view.pointer,
    length = view.element_count,
    byteLength = view.byte_length
  }
end

------------------------------------------------------------------------------
-- 3. Graphics & Hardware Acceleration Bridges (WebGL, WebGPU, Canvas)
------------------------------------------------------------------------------

-- Zero-copy 2D Canvas ImageData descriptor (RGBA 32-bit pixels)
function M.bind_canvas_framebuffer(pointer, width, height)
  local byte_length = width * height * 4
  return {
    target = "canvas_2d",
    pointer = pointer,
    width = width,
    height = height,
    byte_length = byte_length,
    typed_array = "Uint8ClampedArray"
  }
end

-- WebGL ArrayBuffer binding descriptor (GL_ARRAY_BUFFER, GL_ELEMENT_ARRAY_BUFFER)
function M.bind_webgl_buffer(pointer, byte_length, target, usage)
  target = target or 34962 -- GL_ARRAY_BUFFER
  usage = usage or 35044   -- GL_STATIC_DRAW
  return {
    target = "webgl",
    gl_target = target,
    gl_usage = usage,
    pointer = pointer,
    byte_length = byte_length,
    typed_array = "Float32Array"
  }
end

-- WebGPU Buffer binding descriptor
function M.bind_webgpu_buffer(pointer, byte_length, usage_flags)
  usage_flags = usage_flags or 0x0020 -- GPUBufferUsage.COPY_SRC | GPUBufferUsage.STORAGE
  return {
    target = "webgpu",
    usage = usage_flags,
    pointer = pointer,
    byte_length = byte_length
  }
end

return M
