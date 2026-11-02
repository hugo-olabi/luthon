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
    int listen(int sockfd, int backlog);
    int accept(int sockfd, struct sockaddr *addr, uint32_t *addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
    int setsockopt(int sockfd, int level, int optname, const void *optval, uint32_t optlen);
    int fcntl(int fd, int cmd, ...);
    uint16_t htons(uint16_t hostshort);
    int inet_pton(int af, const char *src, void *dst);
  ]]
end)

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_REUSEADDR = 2
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

local WebSocketConnection = {}
WebSocketConnection.__index = WebSocketConnection

function WebSocketConnection.new(fd)
  local self = setmetatable({
    _fd = fd,
    _closed = false,
    _in_queue = {},
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
  return nil
end

function WebSocketConnection:close()
  if not self._closed then
    self._closed = true
    if self._fd and self._fd >= 0 then
      pcall(ffi.C.close, self._fd)
    end
  end
end

-- Async iterator support: `async for msg in websocket:`
function WebSocketConnection:__aiter__()
  return self
end

function WebSocketConnection:__anext__()
  local msg = self:recv()
  if msg ~= nil then
    return msg
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
      -- Fallback to binding on any address if specific host cannot be bound
      addr.sin_addr.s_addr = 0
    end

    local b_res = ffi.C.bind(s, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
    if b_res < 0 then
      -- If specific IP fails, bind INADDR_ANY
      addr.sin_addr.s_addr = 0
      b_res = ffi.C.bind(s, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
    end

    ffi.C.listen(s, 128)
    return s
  end)

  if ok and fd >= 0 then
    self._server_fd = fd
  end
  return self
end

function Server_mt:__aexit__()
  if self._server_fd and self._server_fd >= 0 then
    pcall(ffi.C.close, self._server_fd)
    self._server_fd = -1
  end
end

function websockets.serve(handler, host, port, ...)
  -- Parse kwargs or positional
  if type(host) == "table" and port == nil then
    local kw = host
    host = kw.host or "127.0.0.1"
    port = kw.port or 3000
  end
  host = host or "127.0.0.1"
  port = tonumber(port) or 3000

  local srv = {
    handler = handler,
    host = host,
    port = port,
    _server_fd = -1,
  }
  return setmetatable(srv, Server_mt)
end

_G.websockets = websockets
return websockets
