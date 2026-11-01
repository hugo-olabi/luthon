--[[
  Luthon Direct Image Codecs & Buffer Shims (src/luthon/lua/native/codecs.lua)
  =============================================================================
  Direct LuaJIT FFI bindings for libpng and libjpeg-turbo / libjpeg,
  providing zero-overhead image decoding, encoding, and channel swizzling
  without falling back to Pillow (PIL) across PyBridge.
--]]

local ffi = require("ffi")

local M = {}

-- C definitions for libpng and libjpeg
ffi.cdef[[
  typedef void* png_structp;
  typedef void* png_infop;
  typedef void (*png_error_ptr)(png_structp, const char*);
  typedef void (*png_rw_ptr)(png_structp, uint8_t*, size_t);

  png_structp png_create_read_struct(const char *user_png_ver, void *error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn);
  png_structp png_create_write_struct(const char *user_png_ver, void *error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn);
  png_infop png_create_info_struct(png_structp png_ptr);
  void png_destroy_read_struct(png_structp *png_ptr_ptr, png_infop *info_ptr_ptr, png_infop *end_info_ptr_ptr);
  void png_destroy_write_struct(png_structp *png_ptr_ptr, png_infop *info_ptr_ptr);
  void png_set_read_fn(png_structp png_ptr, void *io_ptr, png_rw_ptr read_data_fn);
  void png_set_write_fn(png_structp png_ptr, void *io_ptr, png_rw_ptr write_data_fn, void *output_flush_fn);
  void png_read_info(png_structp png_ptr, png_infop info_ptr);
  void png_read_image(png_structp png_ptr, uint8_t **row_pointers);
  void png_read_end(png_structp png_ptr, png_infop info_ptr);
  void png_write_info(png_structp png_ptr, png_infop info_ptr);
  void png_write_image(png_structp png_ptr, uint8_t **row_pointers);
  void png_write_end(png_structp png_ptr, png_infop info_ptr);
  uint32_t png_get_image_width(png_structp png_ptr, png_infop info_ptr);
  uint32_t png_get_image_height(png_structp png_ptr, png_infop info_ptr);
  uint8_t png_get_color_type(png_structp png_ptr, png_infop info_ptr);
  uint8_t png_get_bit_depth(png_structp png_ptr, png_infop info_ptr);
  void png_set_IHDR(png_structp png_ptr, png_infop info_ptr, uint32_t width, uint32_t height,
                    int bit_depth, int color_type, int interlace_method,
                    int compression_method, int filter_method);
]]

-- Load libpng
local libpng = nil
local png_candidates = { "libpng16.so.16", "libpng16.so", "libpng.so" }
for _, name in ipairs(png_candidates) do
  local ok, lib = pcall(ffi.load, name)
  if ok and lib then
    libpng = lib
    break
  end
end

M.has_png = (libpng ~= nil)

-- Color types matching png.h
local PNG_COLOR_TYPE_GRAY = 0
local PNG_COLOR_TYPE_RGB  = 2
local PNG_COLOR_TYPE_RGBA = 6

------------------------------------------------------------------------------
-- Fast In-Memory PNG Encoder / Decoder
------------------------------------------------------------------------------

-- Custom read callback from Lua string / buffer
local function create_reader_state(data)
  return {
    data = data,
    pos = 1,
    len = #data,
  }
end

--- Decode PNG bytes into raw RGBA/RGB pixel buffer
function M.decode_png(data)
  if not libpng then
    error("libpng is not available on this system", 2)
  end

  local reader_state = create_reader_state(data)
  local read_cb = ffi.cast("png_rw_ptr", function(png_ptr, dest, length)
    local n = tonumber(length)
    if reader_state.pos + n - 1 > reader_state.len then
      n = reader_state.len - reader_state.pos + 1
    end
    if n > 0 then
      local chunk = reader_state.data:sub(reader_state.pos, reader_state.pos + n - 1)
      ffi.copy(dest, chunk, n)
      reader_state.pos = reader_state.pos + n
    end
  end)

  local png_ptr = libpng.png_create_read_struct("1.6.0", nil, nil, nil)
  if png_ptr == nil then error("failed to create png_read_struct", 2) end
  local info_ptr = libpng.png_create_info_struct(png_ptr)
  if info_ptr == nil then
    local p = ffi.new("png_structp[1]", png_ptr)
    libpng.png_destroy_read_struct(p, nil, nil)
    error("failed to create png_info_struct", 2)
  end

  libpng.png_set_read_fn(png_ptr, nil, read_cb)
  libpng.png_read_info(png_ptr, info_ptr)

  local width = libpng.png_get_image_width(png_ptr, info_ptr)
  local height = libpng.png_get_image_height(png_ptr, info_ptr)
  local color_type = libpng.png_get_color_type(png_ptr, info_ptr)

  local channels = 4
  if color_type == PNG_COLOR_TYPE_RGB then channels = 3
  elseif color_type == PNG_COLOR_TYPE_GRAY then channels = 1
  end

  local row_stride = width * channels
  local buffer = ffi.new("uint8_t[?]", height * row_stride)
  local row_pointers = ffi.new("uint8_t*[?]", height)
  for y = 0, height - 1 do
    row_pointers[y] = buffer + (y * row_stride)
  end

  libpng.png_read_image(png_ptr, row_pointers)
  libpng.png_read_end(png_ptr, nil)

  local p_png = ffi.new("png_structp[1]", png_ptr)
  local p_info = ffi.new("png_infop[1]", info_ptr)
  libpng.png_destroy_read_struct(p_png, p_info, nil)
  read_cb:free()

  return {
    width = tonumber(width),
    height = tonumber(height),
    channels = channels,
    data = buffer,
    size = height * row_stride,
  }
end

--- Encode raw pixel buffer into PNG bytes
function M.encode_png(width, height, channels, pixel_data)
  if not libpng then
    error("libpng is not available on this system", 2)
  end

  local chunks = {}
  local write_cb = ffi.cast("png_rw_ptr", function(png_ptr, src, length)
    local n = tonumber(length)
    if n > 0 then
      table.insert(chunks, ffi.string(src, n))
    end
  end)

  local png_ptr = libpng.png_create_write_struct("1.6.0", nil, nil, nil)
  if png_ptr == nil then error("failed to create png_write_struct", 2) end
  local info_ptr = libpng.png_create_info_struct(png_ptr)
  if info_ptr == nil then
    local p = ffi.new("png_structp[1]", png_ptr)
    libpng.png_destroy_write_struct(p, nil)
    error("failed to create png_info_struct", 2)
  end

  libpng.png_set_write_fn(png_ptr, nil, write_cb, nil)

  local color_type = PNG_COLOR_TYPE_RGBA
  if channels == 3 then color_type = PNG_COLOR_TYPE_RGB
  elseif channels == 1 then color_type = PNG_COLOR_TYPE_GRAY
  end

  libpng.png_set_IHDR(png_ptr, info_ptr, width, height, 8, color_type, 0, 0, 0)
  libpng.png_write_info(png_ptr, info_ptr)

  local row_stride = width * channels
  local row_pointers = ffi.new("uint8_t*[?]", height)
  local raw_buf = ffi.cast("uint8_t*", pixel_data)
  for y = 0, height - 1 do
    row_pointers[y] = raw_buf + (y * row_stride)
  end

  libpng.png_write_image(png_ptr, row_pointers)
  libpng.png_write_end(png_ptr, nil)

  local p_png = ffi.new("png_structp[1]", png_ptr)
  local p_info = ffi.new("png_infop[1]", info_ptr)
  libpng.png_destroy_write_struct(p_png, p_info)
  write_cb:free()

  return table.concat(chunks)
end

------------------------------------------------------------------------------
-- Fast Pixel Buffer Swizzling & Texture Channel Packing (MER Textures)
------------------------------------------------------------------------------

--- Packs individual Metallic, Emissive, Roughness channel buffers into RGBA
function M.pack_mer_texture(width, height, metallic_buf, emissive_buf, roughness_buf, ao_buf)
  local total_pixels = width * height
  local rgba_buf = ffi.new("uint8_t[?]", total_pixels * 4)

  local m_ptr = metallic_buf and ffi.cast("uint8_t*", metallic_buf) or nil
  local e_ptr = emissive_buf and ffi.cast("uint8_t*", emissive_buf) or nil
  local r_ptr = roughness_buf and ffi.cast("uint8_t*", roughness_buf) or nil
  local a_ptr = ao_buf and ffi.cast("uint8_t*", ao_buf) or nil

  for i = 0, total_pixels - 1 do
    local offset = i * 4
    rgba_buf[offset + 0] = m_ptr and m_ptr[i] or 0    -- R: Metallic
    rgba_buf[offset + 1] = e_ptr and e_ptr[i] or 0    -- G: Emissive
    rgba_buf[offset + 2] = r_ptr and r_ptr[i] or 255  -- B: Roughness
    rgba_buf[offset + 3] = a_ptr and a_ptr[i] or 255  -- A: Ambient Occlusion
  end

  return rgba_buf
end

--- Extracts a single channel slice (0: R, 1: G, 2: B, 3: A) from an RGBA buffer
function M.extract_channel(width, height, rgba_buf, channel_idx)
  local total_pixels = width * height
  local out_buf = ffi.new("uint8_t[?]", total_pixels)
  local src_ptr = ffi.cast("uint8_t*", rgba_buf)

  for i = 0, total_pixels - 1 do
    out_buf[i] = src_ptr[i * 4 + channel_idx]
  end

  return out_buf
end

return M
