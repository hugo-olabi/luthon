--[[
  Luthon Native Pillow Image Shim (src/luthon/lua/native/PIL/Image.lua)
  =====================================================================
  Zero-CPython native implementation of PIL.Image backed by libpng FFI:
    - Image.open(fp_or_path)
    - Image.fromarray(arr, mode)
    - im.verify()
    - im.convert(mode)
    - im.save(fp_or_path)
    - im.size, im.mode, im.format
--]]

local ffi = require("ffi")

-- Ensure libpng and C standard I/O declarations
ffi.cdef[[
  typedef void* png_structp;
  typedef void* png_infop;
  typedef void (*png_error_ptr)(png_structp, const char*);
  typedef void (*png_rw_ptr)(png_structp, uint8_t*, size_t);
  typedef void (*png_flush_ptr)(png_structp);

  png_structp png_create_read_struct(const char *user_png_ver, void *error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn);
  png_infop png_create_info_struct(png_structp png_ptr);
  void png_destroy_read_struct(png_structp *png_ptr_ptr, png_infop *info_ptr_ptr, png_infop *end_info_ptr_ptr);

  png_structp png_create_write_struct(const char *user_png_ver, void *error_ptr, png_error_ptr error_fn, png_error_ptr warn_fn);
  void png_destroy_write_struct(png_structp *png_ptr_ptr, png_infop *info_ptr_ptr);

  void png_set_read_fn(png_structp png_ptr, void *io_ptr, png_rw_ptr read_data_fn);
  void png_set_write_fn(png_structp png_ptr, void *io_ptr, png_rw_ptr write_data_fn, png_flush_ptr output_flush_fn);

  void png_read_info(png_structp png_ptr, png_infop info_ptr);
  uint32_t png_get_image_width(png_structp png_ptr, png_infop info_ptr);
  uint32_t png_get_image_height(png_structp png_ptr, png_infop info_ptr);
  uint8_t png_get_color_type(png_structp png_ptr, png_infop info_ptr);
  uint8_t png_get_bit_depth(png_structp png_ptr, png_infop info_ptr);

  void png_set_expand(png_structp png_ptr);
  void png_set_strip_16(png_structp png_ptr);
  void png_set_palette_to_rgb(png_structp png_ptr);
  void png_set_gray_to_rgb(png_structp png_ptr);
  void png_set_filler(png_structp png_ptr, uint32_t filler, int flags);
  void png_read_update_info(png_structp png_ptr, png_infop info_ptr);
  void png_read_image(png_structp png_ptr, uint8_t **row_pointers);
  void png_read_end(png_structp png_ptr, png_infop info_ptr);

  void png_set_IHDR(png_structp png_ptr, png_infop info_ptr, uint32_t width, uint32_t height, int bit_depth, int color_type, int interlace_method, int compression_method, int filter_method);
  void png_write_info(png_structp png_ptr, png_infop info_ptr);
  void png_write_image(png_structp png_ptr, uint8_t **row_pointers);
  void png_write_end(png_structp png_ptr, png_infop info_ptr);
]]

local libpng = nil
for _, name in ipairs({"libpng16.so.16", "libpng16.so", "libpng.so"}) do
  local ok, lib = pcall(ffi.load, name)
  if ok and lib then libpng = lib; break end
end

local Image = {}
local Image_mt = {}
Image_mt.__index = Image_mt

-- PNG color types
local PNG_COLOR_TYPE_GRAY = 0
local PNG_COLOR_TYPE_RGB  = 2
local PNG_COLOR_TYPE_PALETTE = 3
local PNG_COLOR_TYPE_GA   = 4
local PNG_COLOR_TYPE_RGBA = 6

-- Memory stream reading state
local function make_mem_reader(str_data)
  local pos = 1
  local len = #str_data
  local cdata_str = ffi.cast("const uint8_t*", str_data)

  local cb = ffi.cast("png_rw_ptr", function(png_ptr, out_buf, length)
    local n = tonumber(length)
    if pos + n - 1 > len then
      error("PNG read: unexpected end of stream")
    end
    ffi.copy(out_buf, cdata_str + (pos - 1), n)
    pos = pos + n
  end)

  return cb
end

local function make_mem_writer()
  local chunks = {}
  local cb = ffi.cast("png_rw_ptr", function(png_ptr, in_buf, length)
    local n = tonumber(length)
    if n > 0 then
      table.insert(chunks, ffi.string(in_buf, n))
    end
  end)
  local flush_cb = ffi.cast("png_flush_ptr", function(png_ptr) end)
  return cb, flush_cb, function() return table.concat(chunks) end
end

function Image_mt:verify()
  if not self._raw_bytes then return true end
  local b = self._raw_bytes
  if #b < 8 then error("SyntaxError: not a valid PNG") end
  -- Check PNG signature: \x89PNG\r\n\x1a\n
  local sig = string.sub(b, 1, 8)
  if sig ~= "\137PNG\r\n\026\n" then
    error("SyntaxError: not a valid PNG header")
  end
  return true
end

function Image_mt:convert(target_mode)
  target_mode = target_mode or "RGBA"
  if self.mode == target_mode then return self end

  local w, h = self.size[1], self.size[2]
  local src_buf = self._buffer
  local src_mode = self.mode

  if target_mode == "RGBA" then
    local dst_buf = ffi.new("uint8_t[?]", w * h * 4)
    if src_mode == "RGB" then
      local idx = 0
      local src_idx = 0
      for i = 1, w * h do
        dst_buf[idx] = src_buf[src_idx]
        dst_buf[idx + 1] = src_buf[src_idx + 1]
        dst_buf[idx + 2] = src_buf[src_idx + 2]
        dst_buf[idx + 3] = 255
        idx = idx + 4
        src_idx = src_idx + 3
      end
    elseif src_mode == "L" then
      local idx = 0
      for i = 0, w * h - 1 do
        local l = src_buf[i]
        dst_buf[idx] = l
        dst_buf[idx + 1] = l
        dst_buf[idx + 2] = l
        dst_buf[idx + 3] = 255
        idx = idx + 4
      end
    end
    local res = {
      _buffer = dst_buf,
      size = setmetatable({w, h}, _G._tuple_mt),
      mode = "RGBA",
      format = self.format,
    }
    return setmetatable(res, Image_mt)
  elseif target_mode == "RGB" then
    local dst_buf = ffi.new("uint8_t[?]", w * h * 3)
    if src_mode == "RGBA" then
      local idx = 0
      local src_idx = 0
      for i = 1, w * h do
        dst_buf[idx] = src_buf[src_idx]
        dst_buf[idx + 1] = src_buf[src_idx + 1]
        dst_buf[idx + 2] = src_buf[src_idx + 2]
        idx = idx + 3
        src_idx = src_idx + 4
      end
    elseif src_mode == "L" then
      local idx = 0
      for i = 0, w * h - 1 do
        local l = src_buf[i]
        dst_buf[idx] = l
        dst_buf[idx + 1] = l
        dst_buf[idx + 2] = l
        idx = idx + 3
      end
    end
    local res = {
      _buffer = dst_buf,
      size = setmetatable({w, h}, _G._tuple_mt),
      mode = "RGB",
      format = self.format,
    }
    return setmetatable(res, Image_mt)
  elseif target_mode == "L" then
    local dst_buf = ffi.new("uint8_t[?]", w * h)
    if src_mode == "RGBA" then
      local idx = 0
      for i = 0, w * h - 1 do
        -- Standard luminance: 0.299 R + 0.587 G + 0.114 B
        local r, g, b = src_buf[idx], src_buf[idx + 1], src_buf[idx + 2]
        dst_buf[i] = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
        idx = idx + 4
      end
    elseif src_mode == "RGB" then
      local idx = 0
      for i = 0, w * h - 1 do
        local r, g, b = src_buf[idx], src_buf[idx + 1], src_buf[idx + 2]
        dst_buf[i] = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
        idx = idx + 3
      end
    end
    local res = {
      _buffer = dst_buf,
      size = setmetatable({w, h}, _G._tuple_mt),
      mode = "L",
      format = self.format,
    }
    return setmetatable(res, Image_mt)
  end

  error("PIL.Image.convert: unsupported mode conversion " .. tostring(src_mode) .. " -> " .. tostring(target_mode))
end

function Image_mt:save(fp, format)
  if not libpng then error("PIL.Image.save: libpng is not loaded") end

  local w, h = self.size[1], self.size[2]
  local channels = (self.mode == "RGBA" and 4) or (self.mode == "RGB" and 3) or 1
  local color_type = (self.mode == "RGBA" and PNG_COLOR_TYPE_RGBA) or (self.mode == "RGB" and PNG_COLOR_TYPE_RGB) or PNG_COLOR_TYPE_GRAY

  local png_ptr = libpng.png_create_write_struct("1.6.0", nil, nil, nil)
  if png_ptr == nil then error("libpng write struct creation failed") end
  local info_ptr = libpng.png_create_info_struct(png_ptr)
  if info_ptr == nil then
    local p = ffi.new("png_structp[1]", png_ptr)
    libpng.png_destroy_write_struct(p, nil)
    error("libpng write info struct creation failed")
  end

  local write_cb, flush_cb, get_bytes = make_mem_writer()
  libpng.png_set_write_fn(png_ptr, nil, write_cb, flush_cb)

  libpng.png_set_IHDR(png_ptr, info_ptr, w, h, 8, color_type, 0, 0, 0)
  libpng.png_write_info(png_ptr, info_ptr)

  local row_pointers = ffi.new("uint8_t*[?]", h)
  local row_stride = w * channels
  for y = 0, h - 1 do
    row_pointers[y] = self._buffer + y * row_stride
  end
  libpng.png_write_image(png_ptr, row_pointers)
  libpng.png_write_end(png_ptr, info_ptr)

  local p_png = ffi.new("png_structp[1]", png_ptr)
  local p_info = ffi.new("png_infop[1]", info_ptr)
  libpng.png_destroy_write_struct(p_png, p_info)
  write_cb:free()
  flush_cb:free()

  local output_data = get_bytes()

  if type(fp) == "string" then
    local f = io.open(fp, "wb")
    if not f then error("Cannot open destination file " .. fp .. " for writing") end
    f:write(output_data)
    f:close()
  elseif type(fp) == "table" and type(fp.write) == "function" then
    fp:write(output_data)
  end
  return true
end

function Image.open(fp)
  local raw_bytes = nil
  if type(fp) == "string" then
    local f = io.open(fp, "rb")
    if not f then error("FileNotFoundError: " .. fp) end
    raw_bytes = f:read("*a")
    f:close()
  elseif type(fp) == "table" and type(fp.getvalue) == "function" then
    raw_bytes = fp:getvalue()
  elseif type(fp) == "table" and type(fp.read) == "function" then
    raw_bytes = fp:read()
  else
    error("Image.open: unsupported argument " .. tostring(fp))
  end

  if #raw_bytes < 8 or string.sub(raw_bytes, 1, 8) ~= "\137PNG\r\n\026\n" then
    error("SyntaxError: unsupported or corrupted image format")
  end

  if not libpng then error("PIL.Image: libpng not available") end

  local png_ptr = libpng.png_create_read_struct("1.6.0", nil, nil, nil)
  if png_ptr == nil then error("libpng read struct failed") end
  local info_ptr = libpng.png_create_info_struct(png_ptr)
  if info_ptr == nil then
    local p = ffi.new("png_structp[1]", png_ptr)
    libpng.png_destroy_read_struct(p, nil, nil)
    error("libpng info struct failed")
  end

  local read_cb = make_mem_reader(raw_bytes)
  libpng.png_set_read_fn(png_ptr, nil, read_cb)

  libpng.png_read_info(png_ptr, info_ptr)
  local w = tonumber(libpng.png_get_image_width(png_ptr, info_ptr))
  local h = tonumber(libpng.png_get_image_height(png_ptr, info_ptr))
  local color_type = tonumber(libpng.png_get_color_type(png_ptr, info_ptr))
  local bit_depth = tonumber(libpng.png_get_bit_depth(png_ptr, info_ptr))

  if bit_depth == 16 then libpng.png_set_strip_16(png_ptr) end
  if color_type == PNG_COLOR_TYPE_PALETTE then libpng.png_set_palette_to_rgb(png_ptr) end
  if color_type == PNG_COLOR_TYPE_GRAY and bit_depth < 8 then libpng.png_set_expand(png_ptr) end

  local mode = "RGBA"
  local channels = 4
  if color_type == PNG_COLOR_TYPE_RGBA then
    mode = "RGBA"
    channels = 4
  elseif color_type == PNG_COLOR_TYPE_RGB or color_type == PNG_COLOR_TYPE_PALETTE then
    -- Convert RGB to RGBA for standard representation
    libpng.png_set_filler(png_ptr, 0xFF, 1) -- 1 = PNG_FILLER_AFTER
    mode = "RGBA"
    channels = 4
  elseif color_type == PNG_COLOR_TYPE_GA then
    libpng.png_set_gray_to_rgb(png_ptr)
    mode = "RGBA"
    channels = 4
  elseif color_type == PNG_COLOR_TYPE_GRAY then
    libpng.png_set_gray_to_rgb(png_ptr)
    libpng.png_set_filler(png_ptr, 0xFF, 1)
    mode = "RGBA"
    channels = 4
  end

  libpng.png_read_update_info(png_ptr, info_ptr)

  local buf = ffi.new("uint8_t[?]", w * h * channels)
  local row_pointers = ffi.new("uint8_t*[?]", h)
  local stride = w * channels
  for y = 0, h - 1 do
    row_pointers[y] = buf + y * stride
  end

  libpng.png_read_image(png_ptr, row_pointers)
  libpng.png_read_end(png_ptr, info_ptr)

  local p_png = ffi.new("png_structp[1]", png_ptr)
  local p_info = ffi.new("png_infop[1]", info_ptr)
  libpng.png_destroy_read_struct(p_png, p_info, nil)
  read_cb:free()

  local im = {
    _buffer = buf,
    _raw_bytes = raw_bytes,
    size = setmetatable({w, h}, _G._tuple_mt),
    mode = mode,
    format = "PNG",
  }
  return setmetatable(im, Image_mt)
end

local function _extract_kw(...)
  local total = select("#", ...)
  if total == 0 then return nil end
  local last = select(total, ...)
  if type(last) == "table" and not last._buffer and not last.shape then
    return last
  end
  return nil
end

function Image.fromarray(arr, ...)
  local total = select("#", ...)
  local kw = _extract_kw(...)
  local mode = nil
  if kw and kw.mode ~= nil then
    mode = kw.mode
  end
  if not mode and total >= 1 then
    local a1 = select(1, ...)
    if type(a1) == "string" then mode = a1 end
  end
  mode = mode or "RGB"

  local h = arr.shape[1]
  local w = arr.shape[2]
  local src_c = arr.ndim == 3 and arr.shape[3] or 1

  local dst_c = (mode == "RGBA" and 4) or (mode == "RGB" and 3) or 1
  local buf = ffi.new("uint8_t[?]", w * h * dst_c)

  if mode == "RGB" and src_c == 3 and arr.strides[1] == w * 3 and arr.strides[2] == 3 and arr.strides[3] == 1 then
    -- Direct contiguous copy
    ffi.copy(buf, arr.data, w * h * 3)
  elseif mode == "L" and src_c == 1 and arr.strides[1] == w and arr.strides[2] == 1 then
    ffi.copy(buf, arr.data, w * h)
  elseif mode == "RGB" and src_c == 3 then
    local s0, s1, s2 = arr.strides[1], arr.strides[2], arr.strides[3]
    local src = arr.data
    local dst_idx = 0
    for y = 0, h - 1 do
      local row = y * s0
      for x = 0, w - 1 do
        local col = row + x * s1
        buf[dst_idx]     = src[col]
        buf[dst_idx + 1] = src[col + s2]
        buf[dst_idx + 2] = src[col + 2 * s2]
        dst_idx = dst_idx + 3
      end
    end
  elseif mode == "L" then
    local s0 = arr.strides[1]
    local s1 = arr.strides[2] or 1
    local src = arr.data
    local dst_idx = 0
    for y = 0, h - 1 do
      local row = y * s0
      for x = 0, w - 1 do
        buf[dst_idx] = src[row + x * s1]
        dst_idx = dst_idx + 1
      end
    end
  else
    error("Image.fromarray: unhandled conversion to mode " .. tostring(mode))
  end

  local im = {
    _buffer = buf,
    size = setmetatable({w, h}, _G._tuple_mt),
    mode = mode,
    format = "PNG",
  }
  return setmetatable(im, Image_mt)
end

return Image
