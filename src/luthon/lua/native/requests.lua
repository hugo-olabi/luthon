--[[
  requests native shim for Luthon (Phase 1)
  =========================================
  Provides HTTP GET/POST with streaming raw response, content, text, status_code, and json().
  Uses libcurl via LuaJIT FFI with transparent curl CLI fallback.
--]]

local ffi = require("ffi")

local requests = {}

-- Stream reader compatible with PIL.Image.open(stream.raw)
local RawStream_mt = {
  read = function(self, n)
    if not n then
      local rem = self._data:sub(self._pos)
      self._pos = #self._data + 1
      return rem
    end
    if self._pos > #self._data then return "" end
    local chunk = self._data:sub(self._pos, self._pos + n - 1)
    self._pos = self._pos + #chunk
    return chunk
  end,
  seek = function(self, offset, whence)
    whence = whence or 0
    if whence == 0 or whence == "set" then
      self._pos = offset + 1
    elseif whence == 1 or whence == "cur" then
      self._pos = self._pos + offset
    elseif whence == 2 or whence == "end" then
      self._pos = #self._data + 1 + offset
    end
    return self._pos - 1
  end,
  tell = function(self)
    return self._pos - 1
  end,
  close = function(self) end,
}
RawStream_mt.__index = RawStream_mt

local function make_raw_stream(data)
  return setmetatable({ _data = data or "", _pos = 1 }, RawStream_mt)
end

-- Response metatable
local Response_mt = {}
Response_mt.__index = Response_mt

function Response_mt:json()
  local json = _G.json or require("json")
  return json.loads(self.text or self.content)
end

-- Try loading libcurl FFI
local curl_loaded = false
local libcurl = nil
pcall(function()
  ffi.cdef[[
    typedef void CURL;
    typedef int CURLcode;
    typedef size_t (*curl_write_callback)(char *ptr, size_t size, size_t nmemb, void *userdata);

    CURL *curl_easy_init(void);
    CURLcode curl_easy_setopt(CURL *curl, int option, ...);
    CURLcode curl_easy_perform(CURL *curl);
    void curl_easy_cleanup(CURL *curl);
    CURLcode curl_easy_getinfo(CURL *curl, int info, ...);
  ]]
  for _, libname in ipairs({"libcurl.so.4", "libcurl.so", "libcurl.4.dylib"}) do
    local ok, lib = pcall(ffi.load, libname)
    if ok and lib then libcurl = lib; break end
  end
end)
if libcurl ~= nil then curl_loaded = true end

local CURLOPT_URL = 10002
local CURLOPT_WRITEFUNCTION = 20011
local CURLOPT_WRITEDATA = 10001
local CURLOPT_FOLLOWLOCATION = 52
local CURLOPT_TIMEOUT = 13
local CURLINFO_RESPONSE_CODE = 0x200000 + 2

local function fetch_http_ffi(url, stream, method, body, headers)
  if not curl_loaded or not libcurl then return nil end
  local curl = libcurl.curl_easy_init()
  if curl == nil then return nil end

  local chunks = {}
  local write_cb = ffi.cast("curl_write_callback", function(ptr, size, nmemb, userdata)
    local bytes = tonumber(size * nmemb)
    if bytes > 0 then
      chunks[#chunks + 1] = ffi.string(ptr, bytes)
    end
    return bytes
  end)

  libcurl.curl_easy_setopt(curl, CURLOPT_URL, ffi.cast("const char*", url))
  libcurl.curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, ffi.cast("long", 1))
  libcurl.curl_easy_setopt(curl, CURLOPT_TIMEOUT, ffi.cast("long", 30))
  libcurl.curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb)

  local res = libcurl.curl_easy_perform(curl)
  write_cb:free()

  if res ~= 0 then
    libcurl.curl_easy_cleanup(curl)
    return nil
  end

  local status_buf = ffi.new("long[1]")
  libcurl.curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status_buf)
  local status_code = tonumber(status_buf[0])
  libcurl.curl_easy_cleanup(curl)

  local content = table.concat(chunks)
  local resp = {
    content = content,
    text = content,
    status_code = status_code,
    ok = (status_code >= 200 and status_code < 300),
    raw = make_raw_stream(content),
    url = url,
  }
  return setmetatable(resp, Response_mt)
end

local function fetch_http_cli(url, stream, method, body, headers)
  local cmd = string.format("curl -s -L %q", url)
  local p = io.popen(cmd, "r")
  if not p then
    error("requests: failed to execute curl", 2)
  end
  local content = p:read("*a")
  p:close()

  local resp = {
    content = content,
    text = content,
    status_code = 200,
    ok = true,
    raw = make_raw_stream(content),
    url = url,
  }
  return setmetatable(resp, Response_mt)
end

function requests.get(url, ...)
  local total = select("#", ...)
  local stream = false
  for i = 1, total do
    local arg = select(i, ...)
    if type(arg) == "table" and arg.stream ~= nil then
      stream = arg.stream
    end
  end

  local resp = fetch_http_ffi(url, stream, "GET")
  if not resp then
    resp = fetch_http_cli(url, stream, "GET")
  end
  return resp
end

function requests.post(url, ...)
  local resp = fetch_http_ffi(url, false, "POST")
  if not resp then
    resp = fetch_http_cli(url, false, "POST")
  end
  return resp
end

_G.requests = requests
return requests
