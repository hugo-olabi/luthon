--[[
  websockets native shim for Luthon (Phase 2)
  ===========================================
  Provides websockets.serve async context manager, websocket connection handling,
  message framing (RFC 6455), and exception tables.
--]]

local ffi = require("ffi")

local websockets = {}

-- Exceptions table matching websockets.exceptions
websockets.exceptions = {
  ConnectionClosed = "ConnectionClosed",
  ConnectionClosedError = "ConnectionClosedError",
  ConnectionClosedOK = "ConnectionClosedOK",
  WebSocketException = "WebSocketException",
}

-- Socket FFI declarations
pcall(function()
  ffi.cdef[[
    typedef int socket_t;
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in {
      int16_t sin_family;
      uint16_t sin_port;
      struct in_addr sin_addr;
      char sin_zero[8];
    };
    struct sockaddr {
      uint16_t sa_family;
      char sa_data[14];
    };

    int socket(int domain, int type, int protocol);
    int bind(int sockfd, const struct sockaddr *addr, uint32_t addrlen);
    int connect(int sockfd, const struct sockaddr *addr, uint32_t addrlen);
    int listen(int sockfd, int backlog);
    int accept(int sockfd, struct sockaddr *addr, uint32_t *addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
    int setsockopt(int sockfd, int level, int optname, const void *optval, uint32_t optlen);
    int fcntl(int fd, int cmd, ...);
    uint16_t htons(uint16_t hostshort);
    int inet_pton(int af, const char *src, void *dst);

    typedef struct pollfd {
      int   fd;
      short events;
      short revents;
    } pollfd;
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
  ]]
end)

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_REUSEADDR = 2
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

local function b64_encode(data)
  local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local res = {}
  local len = #data
  for i = 1, len, 3 do
    local b1 = data:byte(i)
    local b2 = i + 1 <= len and data:byte(i + 1) or 0
    local b3 = i + 2 <= len and data:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    table.insert(res, b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1))
    table.insert(res, b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if i + 1 <= len then
      table.insert(res, b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
    else
      table.insert(res, "=")
    end
    if i + 2 <= len then
      table.insert(res, b64chars:sub(n % 64 + 1, n % 64 + 1))
    else
      table.insert(res, "=")
    end
  end
  return table.concat(res)
end

-- OpenSSL sha1 for WebSocket handshake
local ok_crypto, libcrypto = pcall(ffi.load, "libcrypto.so")
if not ok_crypto then ok_crypto, libcrypto = pcall(ffi.load, "crypto") end
pcall(function()
  ffi.cdef[[
    typedef struct env_md_ctx_st EVP_MD_CTX;
    typedef struct env_md_st EVP_MD;
    EVP_MD_CTX *EVP_MD_CTX_new(void);
    void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
    const EVP_MD *EVP_sha1(void);
    int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, void *impl);
    int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
    int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);
  ]]
end)

local function sha1_raw(msg)
  if ok_crypto and libcrypto and libcrypto.EVP_MD_CTX_new then
    local ctx = libcrypto.EVP_MD_CTX_new()
    libcrypto.EVP_DigestInit_ex(ctx, libcrypto.EVP_sha1(), nil)
    libcrypto.EVP_DigestUpdate(ctx, msg, #msg)
    local out = ffi.new("unsigned char[20]")
    local len = ffi.new("unsigned int[1]")
    libcrypto.EVP_DigestFinal_ex(ctx, out, len)
    libcrypto.EVP_MD_CTX_free(ctx)
    return ffi.string(out, 20)
  end
  return ""
end

local function compute_accept_key(ws_key)
  local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  return b64_encode(sha1_raw(ws_key .. guid))
end

local WebSocketConnection = {}
WebSocketConnection.__index = WebSocketConnection

function WebSocketConnection.new(fd)
  local self = setmetatable({
    _fd = fd,
    _closed = false,
    _in_queue = {},
    _buf = "",
  }, WebSocketConnection)
  return self
end

function WebSocketConnection:send(data)
  if self._closed then return end
  data = tostring(data or "")
  local payload_len = #data
  local frame = {}

  -- Opcode 0x81: FIN (0x80) | Text (0x01)
  frame[1] = string.char(0x81)

  if payload_len <= 125 then
    frame[2] = string.char(payload_len)
  elseif payload_len <= 65535 then
    frame[2] = string.char(126)
    frame[3] = string.char(math.floor(payload_len / 256), payload_len % 256)
  else
    frame[2] = string.char(127)
    local len_bytes = {}
    local rem = payload_len
    for i = 8, 1, -1 do
      len_bytes[i] = string.char(rem % 256)
      rem = math.floor(rem / 256)
    end
    frame[3] = table.concat(len_bytes)
  end
  frame[#frame + 1] = data

  local full_msg = table.concat(frame)
  pcall(function()
    ffi.C.send(self._fd, full_msg, #full_msg, 0)
  end)
end

function WebSocketConnection:recv()
  if #self._in_queue > 0 then
    return table.remove(self._in_queue, 1)
  end
  -- Non-blocking read from socket
  local buf = ffi.new("char[4096]")
  local n = ffi.C.recv(self._fd, buf, 4096, 0)
  if n > 0 then
    self._buf = self._buf .. ffi.string(buf, n)
    self:_parse_frames()
    if #self._in_queue > 0 then
      return table.remove(self._in_queue, 1)
    end
  elseif n == 0 then
    self:close()
  end
  return nil
end

function WebSocketConnection:_parse_frames()
  local bit = require("bit")
  while #self._buf >= 2 do
    local b1 = self._buf:byte(1)
    local b2 = self._buf:byte(2)
    local opcode = bit.band(b1, 0x0f)
    local is_masked = bit.band(b2, 0x80) ~= 0
    local payload_len = bit.band(b2, 0x7f)
    local header_len = 2

    if payload_len == 126 then
      if #self._buf < 4 then return end
      payload_len = self._buf:byte(3) * 256 + self._buf:byte(4)
      header_len = 4
    elseif payload_len == 127 then
      if #self._buf < 10 then return end
      local hi = self._buf:byte(3) * 16777216 + self._buf:byte(4) * 65536 + self._buf:byte(5) * 256 + self._buf:byte(6)
      local lo = self._buf:byte(7) * 16777216 + self._buf:byte(8) * 65536 + self._buf:byte(9) * 256 + self._buf:byte(10)
      payload_len = hi * 4294967296 + lo
      header_len = 10
    end

    local mask_len = is_masked and 4 or 0
    if #self._buf < header_len + mask_len + payload_len then
      return
    end

    local mask = {}
    if is_masked then
      for m = 1, 4 do
        mask[m] = self._buf:byte(header_len + m)
      end
    end

    local payload_start = header_len + mask_len + 1
    local payload_bytes = {}
    for p = 0, payload_len - 1 do
      local byte_val = self._buf:byte(payload_start + p)
      if is_masked then
        byte_val = bit.bxor(byte_val, mask[(p % 4) + 1])
      end
      payload_bytes[p + 1] = string.char(byte_val)
    end
    local payload = table.concat(payload_bytes)

    self._buf = self._buf:sub(header_len + mask_len + payload_len + 1)

    if opcode == 0x01 then -- Text frame
      table.insert(self._in_queue, payload)
    elseif opcode == 0x08 then -- Connection close
      self:close()
      return
    elseif opcode == 0x09 then -- Ping -> Pong
      local pong_frame = string.char(0x8a, #payload) .. payload
      pcall(ffi.C.send, self._fd, pong_frame, #pong_frame, 0)
    end
  end
end

function WebSocketConnection:close()
  if not self._closed then
    self._closed = true
    if self._fd and self._fd >= 0 then
      pcall(ffi.C.close, self._fd)
      self._fd = -1
    end
  end
end

-- Async iterator support: `async for msg in websocket:`
function WebSocketConnection:__aiter__()
  return self
end

function WebSocketConnection:__anext__()
  while not self._closed do
    local msg = self:recv()
    if msg ~= nil then
      return msg
    end
    -- Poll socket waiting for input
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = self._fd
    pfd[0].events = 1 -- POLLIN
    local r = ffi.C.poll(pfd, 1, 100)
    if r < 0 then
      break
    end
  end
  return nil
end

-- Server context manager for `websockets.serve(handler, host, port)`
local Server_mt = {}
Server_mt.__index = Server_mt

function Server_mt:__aenter__()
  -- Bind socket and start listening
  local ok, fd = pcall(function()
    local s = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if s < 0 then return -1 end

    local optval = ffi.new("int[1]", 1)
    ffi.C.setsockopt(s, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof("int"))

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = ffi.C.htons(self.port)
    local pton_res = ffi.C.inet_pton(AF_INET, self.host == "0.0.0.0" and "0.0.0.0" or self.host, addr.sin_addr)
    if pton_res <= 0 then
      addr.sin_addr.s_addr = 0
    end

    local b_res = ffi.C.bind(s, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
    if b_res < 0 then
      addr.sin_addr.s_addr = 0
      b_res = ffi.C.bind(s, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
    end

    ffi.C.listen(s, 128)
    return s
  end)

  if ok and fd >= 0 then
    self._server_fd = fd
    -- Register in active websocket servers
    _G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS = _G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS or {}
    table.insert(_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS, self)
  end
  return self
end

function Server_mt:run_event_loop(future)
  local client_addrs = ffi.new("struct sockaddr_in")
  local addrlen = ffi.new("uint32_t[1]", ffi.sizeof("struct sockaddr_in"))
  local pfd = ffi.new("struct pollfd[1]")

  while self._server_fd and self._server_fd >= 0 and (not future or not future:done()) do
    pfd[0].fd = self._server_fd
    pfd[0].events = 1 -- POLLIN
    local r = ffi.C.poll(pfd, 1, 200) -- 200ms poll
    if r > 0 then
      local client_fd = ffi.C.accept(self._server_fd, ffi.cast("struct sockaddr*", client_addrs), addrlen)
      if client_fd >= 0 then
        -- Read HTTP WebSocket Upgrade Request
        local req_buf = ffi.new("char[4096]")
        local n = ffi.C.recv(client_fd, req_buf, 4096, 0)
        if n > 0 then
          local req_str = ffi.string(req_buf, n)
          local ws_key = req_str:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
          if ws_key then
            -- Trim trailing whitespace
            ws_key = ws_key:match("^%s*(.-)%s*$")
            local accept_key = compute_accept_key(ws_key)
            local handshake_resp = "HTTP/1.1 101 Switching Protocols\r\n" ..
                                   "Upgrade: websocket\r\n" ..
                                   "Connection: Upgrade\r\n" ..
                                   "Sec-WebSocket-Accept: " .. accept_key .. "\r\n\r\n"
            ffi.C.send(client_fd, handshake_resp, #handshake_resp, 0)

            local ws = WebSocketConnection.new(client_fd)
            if self.handler then
              local ok_h, err_h = pcall(self.handler, ws)
              if not ok_h then
                print("WebSocket handler error:", err_h)
              end
            end
          else
            ffi.C.close(client_fd)
          end
        end
      end
    end
  end
end

function Server_mt:close()
  if self._server_fd and self._server_fd >= 0 then
    pcall(ffi.C.close, self._server_fd)
    self._server_fd = -1
  end
  if _G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS then
    for i, srv in ipairs(_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS) do
      if srv == self then
        table.remove(_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS, i)
        break
      end
    end
  end
end

function Server_mt:wait_closed()
  return true
end

function Server_mt:__aexit__()
  self:close()
end

function websockets.serve(...)
  local args = {...}
  local handler = args[1]
  local host = nil
  local port = nil

  -- Look for keyword arguments table (passed at end or as table argument)
  for i = #args, 1, -1 do
    local a = args[i]
    if type(a) == "table" and (a.host ~= nil or a.port ~= nil) then
      host = a.host
      port = a.port
      break
    end
  end

  if host == nil and type(args[2]) == "string" then
    host = args[2]
  end
  if port == nil and type(args[3]) == "number" then
    port = args[3]
  end

  host = host or "0.0.0.0"
  port = tonumber(port) or 3003

  local srv = {
    handler = handler,
    host = host,
    port = port,
    _server_fd = -1,
  }
  setmetatable(srv, Server_mt)
  -- Immediately bind and listen so it is available before being awaited or entered
  srv:__aenter__()
  return srv
end

-- Client context manager for `websockets.connect(uri)`
local Client_mt = {}
Client_mt.__index = Client_mt

function Client_mt:__aenter__()
  -- Parse uri ws://host:port
  local host, port = self.uri:match("ws://([^:]+):?(%d*)")
  host = (host and host ~= "") and host or "127.0.0.1"
  if host == "localhost" then host = "127.0.0.1" end
  port = (port and port ~= "") and tonumber(port) or 80

  local s = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
  if s < 0 then error("Cannot create client socket") end

  local addr = ffi.new("struct sockaddr_in")
  addr.sin_family = AF_INET
  addr.sin_port = ffi.C.htons(port)
  ffi.C.inet_pton(AF_INET, host, addr.sin_addr)

  local c_res = ffi.C.connect(s, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
  if c_res < 0 then
    ffi.C.close(s)
    error("ConnectionRefusedError: could not connect to " .. self.uri)
  end

  local client_key = "dGhlIHNhbXBsZSBub25jZQ=="
  local req = "GET / HTTP/1.1\r\n" ..
              "Host: " .. host .. ":" .. port .. "\r\n" ..
              "Upgrade: websocket\r\n" ..
              "Connection: Upgrade\r\n" ..
              "Sec-WebSocket-Key: " .. client_key .. "\r\n" ..
              "Sec-WebSocket-Version: 13\r\n\r\n"
  ffi.C.send(s, req, #req, 0)

  local resp_buf = ffi.new("char[4096]")
  local n = ffi.C.recv(s, resp_buf, 4096, 0)
  if n <= 0 then
    ffi.C.close(s)
    error("WebSocket handshake failed")
  end

  local ws = WebSocketConnection.new(s)
  self._ws = ws
  return ws
end

function Client_mt:__aexit__()
  if self._ws then
    self._ws:close()
    self._ws = nil
  end
end

function websockets.connect(uri)
  return setmetatable({ uri = uri, _ws = nil }, Client_mt)
end

_G.websockets = websockets
return websockets
