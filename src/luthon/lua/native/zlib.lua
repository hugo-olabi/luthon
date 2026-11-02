--[[
  Native zlib FFI shim for LuaJIT (src/luthon/lua/native/zlib.lua)
--]]
local ffi = require("ffi")

local M = {}

ffi.cdef[[
  typedef void* (*alloc_func)(void* opaque, unsigned int items, unsigned int size);
  typedef void  (*free_func)(void* opaque, void* address);

  typedef struct z_stream_s {
    const uint8_t *next_in;
    unsigned int   avail_in;
    unsigned long  total_in;

    uint8_t       *next_out;
    unsigned int   avail_out;
    unsigned long  total_out;

    const char    *msg;
    struct internal_state *state;

    alloc_func     zalloc;
    free_func      zfree;
    void          *opaque;

    int            data_type;
    unsigned long  adler;
    unsigned long  reserved;
  } z_stream;

  const char *zlibVersion(void);
  unsigned long crc32(unsigned long crc, const uint8_t *buf, unsigned int len);
  int compress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
  int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
]]

local libz = nil
local candidates = {"libz.so.1", "libz.so", "z"}
for _, name in ipairs(candidates) do
  local ok, lib = pcall(ffi.load, name)
  if ok and lib then
    libz = lib
    break
  end
end

if not libz then
  error("libz (zlib) dynamic library could not be loaded")
end

function M.version()
  return ffi.string(libz.zlibVersion())
end

function M.crc32(str)
  local c_str = ffi.cast("const uint8_t*", str)
  return tonumber(libz.crc32(0, c_str, #str))
end

function M.compress(str)
  local src_len = #str
  local dest_len = ffi.new("unsigned long[1]", src_len + math.floor(src_len * 0.1) + 12)
  local dest = ffi.new("uint8_t[?]", dest_len[0])
  local c_src = ffi.cast("const uint8_t*", str)
  local res = libz.compress(dest, dest_len, c_src, src_len)
  if res ~= 0 then
    error("zlib compression failed with code: " .. tostring(res))
  end
  return ffi.string(dest, dest_len[0])
end

function M.decompress(data)
  local src_len = #data
  local buf_size = src_len * 4 + 1024
  local dest_len = ffi.new("unsigned long[1]", buf_size)
  local dest = ffi.new("uint8_t[?]", dest_len[0])
  local c_src = ffi.cast("const uint8_t*", data)
  local res = libz.uncompress(dest, dest_len, c_src, src_len)
  while res == -5 do -- Z_BUF_ERROR: need more buffer
    buf_size = buf_size * 2
    dest_len[0] = buf_size
    dest = ffi.new("uint8_t[?]", dest_len[0])
    res = libz.uncompress(dest, dest_len, c_src, src_len)
  end
  if res ~= 0 then
    error("zlib decompression failed with code: " .. tostring(res))
  end
  return ffi.string(dest, dest_len[0])
end

return M
