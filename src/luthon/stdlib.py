STDLIB_LUA = r"""
-- Luthon stdlib
function range(a, b, step)
  if b == nil then a, b = 0, a; step = 1 end
  if step == nil then step = 1 end
  local r = {}
  if step > 0 then for i = a, b - 1, step do r[#r+1] = i end
  else for i = a, b + 1, step do r[#r+1] = i end end
  return r
end
function len(t) return #t end
function list(t) if type(t) == "function" then local r={}; for v in t do r[#r+1]=v end; return r end; local r={}; if t then for _,v in ipairs(t) do r[#r+1]=v end end; return r end
function iter(t) local i=0; return function() i=i+1; if i<=#t then return t[i] end; return nil end end
function unpack_list(t)
  return t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10]
end
function list_repeat(t, n) local r={}; for i=1,n do for _,v in ipairs(t) do r[#r+1]=v end end; return r end
function str(x) return tostring(x) end
function int(x) return math.floor(tonumber(x)) end
function float(x) return tonumber(x) end
function abs(x) return math.abs(x) end
function bool(x) return x ~= nil and x ~= false end
function round(x, n) n=n or 0; local f=10^n; return math.floor(x*f+0.5)/f end
function min(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]<m then m=a[i] end end; return m end
function max(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]>m then m=a[i] end end; return m end
function sum(t) local s=0; for _,v in ipairs(t) do s=s+v end; return s end
function sorted(t) local r={}; for i,v in ipairs(t) do r[i]=v end; table.sort(r); return r end
function reversed(t) local r={}; for i=#t,1,-1 do r[#r+1]=t[i] end; return r end
function enumerate(t) local r={}; for i,v in ipairs(t) do r[#r+1]={i-1,v} end; return r end
function zip(a,b) local r={}; for i=1,math.min(#a,#b) do r[#r+1]={a[i],b[i]} end; return r end
function map(f,t) local r={}; for i,v in ipairs(t) do r[#r+1]=f(v) end; return r end
function filter(f,t) local r={}; for _,v in ipairs(t) do if f(v) then r[#r+1]=v end end; return r end
function any(t) for _,v in ipairs(t) do if v then return true end end; return false end
function all(t) for _,v in ipairs(t) do if not v then return false end end; return true end
os.path = os.path or {}
os.path.join = function(...) local a={...}; return table.concat(a, "/") end
math.pi = 3.141592653589793
math.e = 2.718281828459045
math.sin = math.sin
math.cos = math.cos
math.tan = math.tan
math.log = math.log
math.exp = math.exp
math.floor = math.floor
math.ceil = math.ceil
math.pow = function(a,b) return a^b end
math.fabs = math.abs
math.sqrt = math.sqrt

os.getenv = os.getenv or function(k) return nil end
os.makedirs = os.makedirs or function(p) end
os.listdir = os.listdir or function(p) return {} end

sys = {argv = {}, path = {}, version = "3.14"}

json = {}
json.encode = nil
json.dumps = function(x)
  if type(x) == "table" then
    local parts = {}
    if #x > 0 then
      for i,v in ipairs(x) do parts[#parts+1] = json.dumps(v) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k,v in pairs(x) do parts[#parts+1] = string.char(34) .. tostring(k) .. string.char(34) .. ":" .. json.dumps(v) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif type(x) == "string" then
    return string.char(34) .. x .. string.char(34)
  elseif type(x) == "boolean" then
    return x and "true" or "false"
  elseif x == nil then
    return "null"
  else
    return tostring(x)
  end
end

random = {}
random.random = function() return math.random() end
random.randint = function(a,b) return math.random(a,b) end
random.choice = function(t) return t[math.random(1,#t)] end
random.seed = function(x) math.randomseed(x) end

re = {}
re.match = function(pat, s) return string.match(s, pat) end
re.search = function(pat, s) return string.match(s, pat) end
re.sub = function(pat, repl, s) return (string.gsub(s, pat, repl)) end
re.findall = function(pat, s) local r={}; for m in string.gmatch(s, pat) do r[#r+1]=m end; return r end

-- os extended
os.environ = os.environ or {}
os.exit = os.exit or os.exit
os.rename = os.rename or function(old, new) return true end
os.tmpname = os.tmpname or function() return "/tmp/luthon_tmp" end
os.clock = os.clock or os.clock
os.date = os.date or os.date
os.time = os.time or os.time
os.difftime = os.difftime or os.difftime
os.execute = os.execute or function(cmd) return os.execute(cmd) end

-- sys
sys.argv = sys.argv or {}
sys.path = sys.path or {}
sys.version = sys.version or "3.14"
sys.platform = "android"
sys.exit = os.exit
sys.stdout = io.stdout
sys.stderr = io.stderr
sys.stdin = io.stdin

-- collections
collections = {}
collections.deque = function()
  local d = {_data = {}, _head = 1, _tail = 0}
  function d:append(x) self._tail = self._tail + 1; self._data[self._tail] = x; return self end
  function d:appendleft(x) self._head = self._head - 1; self._data[self._head] = x; return self end
  function d:pop() if self._tail < self._head then return nil end; local v = self._data[self._tail]; self._data[self._tail] = nil; self._tail = self._tail - 1; return v end
  function d:popleft() if self._tail < self._head then return nil end; local v = self._data[self._head]; self._data[self._head] = nil; self._head = self._head + 1; return v end
  function d:__len() return self._tail - self._head + 1 end
  return d
end
collections.defaultdict = function(default_factory)
  local d = {_data = {}, _factory = default_factory}
  setmetatable(d, {__index = function(t, k) local v = t._data[k]; if v == nil then v = t._factory(); t._data[k] = v end; return v end, __newindex = function(t, k, v) t._data[k] = v end})
  return d
end
collections.Counter = function(iterable)
  local c = {_data = {}, _is_counter = true}
  setmetatable(c, {__index = function(t, k)
    local mt = getmetatable(t)
    if type(k) == "string" and (k == "update" or k == "most_common" or k == "elements") then
      if k == "update" then return function(self, item) self._data[item] = (self._data[item] or 0) + 1 end
      elseif k == "most_common" then return function(self) local r={}; for kk,vv in pairs(self._data) do r[#r+1]={kk,vv} end; return r end
      else return function(self) local r={}; for kk,vv in pairs(self._data) do for i=1,vv do r[#r+1]=kk end end; return r end end
    end
    return rawget(t, "_data")[k] or 0
  end,
  __newindex = function(t, k, v) rawget(t, "_data")[k] = v end})
  if iterable then for _, v in ipairs(iterable) do c._data[v] = (c._data[v] or 0) + 1 end end
  return c
end
collections.OrderedDict = function()
  local o = {_data = {}, _keys = {}}
  setmetatable(o, {
    __newindex = function(t, k, v) if t._data[k] == nil then t._keys[#t._keys+1] = k end; t._data[k] = v end,
    __index = function(t, k) if k == "keys" then return function() return t._keys end end; return t._data[k] end
  })
  return o
end

-- itertools
itertools = {}
itertools.chain = function(...)
  local args = {...}
  local result = {}
  for _, arr in ipairs(args) do
    for _, v in ipairs(arr) do
      result[#result+1] = v
    end
  end
  return result
end
itertools.product = function(...)
  local args = {...}
  -- simplified: cartesian product of lists
  local result = {{}}
  for _, arr in ipairs(args) do
    local new = {}
    for _, prefix in ipairs(result) do
      for _, v in ipairs(arr) do
        local np = {}
        for i, pv in ipairs(prefix) do np[i] = pv end
        np[#np+1] = v
        new[#new+1] = np
      end
    end
    result = new
  end
  return result
end
itertools.permutations = function(iterable, r)
  local pool = type(iterable) == "table" and iterable or {iterable}
  local n = #pool
  r = r or n
  if r > n then return {} end
  local result = {}
  local function permute(arr, start)
    if start > r then
      local p = {}
      for i = 1, r do p[i] = arr[i] end
      result[#result+1] = p
      return
    end
    for i = start, n do
      arr[start], arr[i] = arr[i], arr[start]
      permute(arr, start + 1)
      arr[start], arr[i] = arr[i], arr[start]
    end
  end
  permute(pool, 1)
  return result
end
itertools.combinations = function(iterable, r)
  local pool = type(iterable) == "table" and iterable or {iterable}
  local n = #pool
  if r > n then return {} end
  local result = {}
  local function comb(start, chosen)
    if #chosen == r then
      local p = {}
      for i = 1, r do p[i] = chosen[i] end
      result[#result+1] = p
      return
    end
    for i = start, n do
      chosen[#chosen+1] = pool[i]
      comb(i + 1, chosen)
      chosen[#chosen] = nil
    end
  end
  comb(1, {})
  return result
end

-- functools
functools = {}
functools.reduce = function(func, iterable, initializer)
  local acc = initializer
  local start = 1
  if initializer == nil then
    acc = iterable[1]
    start = 2
  end
  for i = start, #iterable do acc = func(acc, iterable[i]) end
  return acc
end
functools.partial = function(func, ...)
  local fixed = {...}
  return function(...)
    local all = {}
    for i, v in ipairs(fixed) do all[#all+1] = v end
    for i, v in ipairs({...}) do all[#all+1] = v end
    return func(unpack_list(all))
  end
end
functools.lru_cache = function(func)
  local cache = {}
  return function(...)
    local key = table.concat({...}, "")
    if cache[key] == nil then cache[key] = func(...) end
    return cache[key]
  end
end

-- pathlib
pathlib = {}
pathlib.Path = setmetatable({}, {
  __call = function(t, p)
    local path = {_p = tostring(p)}
    function path:__tostring() return self._p end
    function path:name() return self._p:match("([^/]+)$") or self._p end
    function path:parent() return self._p:match("(.*)/") or "." end
    function path:exists() local f = io.open(self._p, "r"); if f then f:close(); return true end; return false end
    function path:is_file() return self:exists() end
    function path:is_dir() return false end
    function path:join(...) return pathlib.Path(self._p .. "/" .. table.concat({...}, "/")) end
    function path:read_text() local f = io.open(self._p, "r"); if not f then error("no such file") end; local c = f:read("*a"); f:close(); return c end
    function path:write_text(c) local f = io.open(self._p, "w"); f:write(c); f:close() end
    return path
  end
})
pathlib.Path.cwd = function() return pathlib.Path(".") end
pathlib.Path.home = function() return pathlib.Path(os.getenv("HOME") or "/") end

-- random
random.seed = random.seed or function(x) math.randomseed(x) end
random.random = random.random or function() return math.random() end
random.randint = random.randint or function(a, b) return math.random(a, b) end
random.choice = random.choice or function(t) return t[math.random(1, #t)] end
random.shuffle = function(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end
random.uniform = function(a, b) return a + (b - a) * math.random() end
random.randrange = function(start, stop, step)
  step = step or 1
  if stop == nil then stop = start; start = 0 end
  local count = math.floor((stop - start - 1) / step) + 1
  return start + math.random(1, count) * step - step
end
random.sample = function(population, k)
  local result = {}
  local pool = {}
  for _, v in ipairs(population) do pool[#pool+1] = v end
  for i = 1, k do
    local j = math.random(1, #pool)
    result[#result+1] = pool[j]
    pool[j] = pool[#pool]
    pool[#pool] = nil
  end
  return result
end

-- datetime
datetime = {}
datetime.date = {}
datetime.date.today = function()
  local t = os.date("*t")
  return {year = t.year, month = t.month, day = t.day}
end
datetime.time = {}
datetime.time.__call = function(hour, minute, second) return {hour = hour or 0, minute = minute or 0, second = second or 0} end
datetime.datetime = {}
datetime.datetime.now = function()
  local t = os.date("*t")
  return {year = t.year, month = t.month, day = t.day, hour = t.hour, min = t.min, sec = t.sec}
end
datetime.timedelta = function(days, seconds, microseconds, milliseconds, minutes, hours, weeks)
  return {days = days or 0, seconds = seconds or 0}
end

-- string constants
string.ascii_letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
string.ascii_lowercase = "abcdefghijklmnopqrstuvwxyz"
string.ascii_uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
string.digits = "0123456789"
string.hexdigits = "0123456789abcdefABCDEF"
string.octdigits = "01234567"
string.punctuation = string.char(33,35,36,37,38,39,40,41,42,43,44,45,46,47,58,59,60,61,62,63,64,91,92,93,94,95,96,123,124,125,126)
string.whitespace = " \t\n\r\f\v"

-- base64
base64 = {}
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
base64.b64encode = function(data)
  local result = {}
  local pad = 0
  local i = 1
  while i <= #data do
    local a = data:byte(i)
    local b = data:byte(i+1) or 0
    local c = data:byte(i+2) or 0
    if i+1 > #data then pad = 2; b = 0; c = 0
    elseif i+2 > #data then pad = 1; c = 0 end
    local n = a * 65536 + b * 256 + c
    result[#result+1] = b64chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
    result[#result+1] = b64chars:sub(math.floor((n % 262144) / 4096) + 1, math.floor((n % 262144) / 4096) + 1)
    if pad < 2 then result[#result+1] = b64chars:sub(math.floor((n % 4096) / 64) + 1, math.floor((n % 4096) / 64) + 1) else result[#result+1] = "=" end
    if pad < 1 then result[#result+1] = b64chars:sub((n % 64) + 1, (n % 64) + 1) else result[#result+1] = "=" end
    i = i + 3
  end
  return table.concat(result)
end
base64.b64decode = function(data)
  local result = {}
  local i = 1
  while i <= #data do
    local chars = data:sub(i, i+3)
    local vals = {}
    for j = 1, 4 do
      local c = chars:sub(j, j)
      if c == "=" then vals[j] = nil
      else vals[j] = b64chars:find(c, 1, true) - 1 end
    end
    if vals[1] and vals[2] then
      local n = vals[1] * 262144 + vals[2] * 4096 + (vals[3] or 0) * 64 + (vals[4] or 0)
      result[#result+1] = string.char(math.floor(n / 65536))
      if vals[3] ~= nil then result[#result+1] = string.char(math.floor((n % 65536) / 256)) end
      if vals[4] ~= nil then result[#result+1] = string.char(n % 256) end
    end
    i = i + 4
  end
  return table.concat(result)
end

-- io StringIO
io.StringIO = function(initial)
  local s = {_buf = initial or "", _pos = 1}
  function s:write(str) self._buf = self._buf:sub(1, self._pos - 1) .. str .. self._buf:sub(self._pos + #str); self._pos = self._pos + #str; return self end
  function s:read(n) n = n or -1; if n < 0 then local c = self._buf:sub(self._pos); self._pos = #self._buf + 1; return c end; local c = self._buf:sub(self._pos, self._pos + n - 1); self._pos = self._pos + n; return c end
  function s:getvalue() return self._buf end
  function s:seek(whence, offset) offset = offset or 0; if whence == "set" then self._pos = offset + 1 elseif whence == "cur" then self._pos = self._pos + offset elseif whence == "end" then self._pos = #self._buf + 1 + offset end; return self._pos - 1 end
  return s
end

-- struct (minimal)
struct = {}
struct.pack = function(fmt, ...)
  -- minimal: only support ">i" (big-endian int32)
  if fmt == ">i" then
    local v = ...
    local b4 = math.floor(v / 16777216) % 256
    local b3 = math.floor(v / 65536) % 256
    local b2 = math.floor(v / 256) % 256
    local b1 = v % 256
    return string.char(b4, b3, b2, b1)
  end
  return ""
end
struct.unpack = function(fmt, s)
  if fmt == ">i" and #s >= 4 then
    local b1, b2, b3, b4 = s:byte(1, 4)
    return b4 + b3 * 256 + b2 * 65536 + b1 * 16777216
  end
  return 0
end

-- hashlib (minimal)
hashlib = {}
hashlib.md5 = function(data)
  -- simplified MD5: not cryptographically correct, returns fixed-length hex
  local h = 0
  for i = 1, #data do
    h = (h * 31 + data:byte(i)) % 4294967296
  end
  return string.format("%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296)
end
hashlib.sha1 = function(data)
  local h = 0
  for i = 1, #data do
    h = (h * 37 + data:byte(i)) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296, h * 1664525 % 4294967296)
end
hashlib.sha256 = function(data)
  local h = 0
  for i = 1, #data do
    h = (h * 41 + data:byte(i)) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296, h * 1664525 % 4294967296, h * 1103515245 % 4294967296, h * 12345 % 4294967296, h * 99991 % 4294967296)
end
hashlib.sha512 = function(data)
  return hashlib.sha256(data) .. hashlib.sha256(data .. "salt")
end

-- pathlib
pathlib = {}
pathlib.Path = setmetatable({}, {
  __call = function(t, p)
    local path = {_p = tostring(p)}
    function path:__tostring() return self._p end
    function path:name() return self._p:match("([^/]+)$") or self._p end
    function path:parent() return self._p:match("(.*)/") or "." end
    function path:exists() local f = io.open(self._p, "r"); if f then f:close(); return true end; return false end
    function path:is_file() return self:exists() end
    function path:is_dir() return false end
    function path:join(...) return pathlib.Path(self._p .. "/" .. table.concat({...}, "/")) end
    function path:read_text() local f = io.open(self._p, "r"); if not f then error("no such file: " .. self._p) end; local c = f:read("*a"); f:close(); return c end
    function path:write_text(c) local f = io.open(self._p, "w"); f:write(c); f:close() end
    return path
  end
})
pathlib.Path.cwd = function() return pathlib.Path(".") end
pathlib.Path.home = function() return pathlib.Path(os.getenv("HOME") or "/") end

-- set and tuple (Lua doesn't have these natively)
set = function(t) return t end
tuple = function(...) return {...} end

-- typing (runtime placeholders; type hints are erased)
typing = {}
typing.Any = {}
typing.List = list
typing.Dict = {}
typing.Set = set
typing.Tuple = tuple
typing.Optional = function(x) return x end
typing.Union = function(...) return ... end
typing.Callable = function(...) return ... end
typing.Generic = function(base) return base end
typing.TypeVar = function(name, ...) return name end
typing.NoReturn = {}
typing.ClassVar = function(x) return x end

-- json (complete)
json = {}
json.encode = function(x)
  if type(x) == "table" then
    local parts = {}
    if #x > 0 then
      for i,v in ipairs(x) do parts[#parts+1] = json.encode(v) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k,v in pairs(x) do parts[#parts+1] = string.char(34) .. tostring(k) .. string.char(34) .. ":" .. json.encode(v) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif type(x) == "string" then
    return string.char(34) .. x .. string.char(34)
  elseif type(x) == "boolean" then
    return x and "true" or "false"
  elseif x == nil then
    return "null"
  else
    return tostring(x)
  end
end
json.dumps = json.encode
json.decode = function(s)
  local pos = 1
  local len = #s
  local parse_value, parse_object, parse_array, parse_string, parse_bool, parse_null, parse_number
  local function skip_ws()
    while pos <= len and s:sub(pos,pos):match("%s") do pos = pos + 1 end
  end
  function parse_value()
    skip_ws()
    local c = s:sub(pos,pos)
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == string.char(34) then return parse_string() end
    if c == "t" or c == "f" then return parse_bool() end
    if c == "n" then return parse_null() end
    return parse_number()
  end
  function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws()
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = s:sub(pos,pos)
      if c == "}" then pos = pos + 1; break end
      pos = pos + 1
    end
    return obj
  end
  function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
    while true do
      skip_ws()
      arr[#arr+1] = parse_value()
      skip_ws()
      local c = s:sub(pos,pos)
      if c == "]" then pos = pos + 1; break end
      pos = pos + 1
    end
    return arr
  end
  function parse_string()
    pos = pos + 1
    local result = {}
    while pos <= len do
      local c = s:sub(pos,pos)
      if c == "\\" then
        pos = pos + 1
        local esc = s:sub(pos,pos)
        if esc == "n" then result[#result+1] = "\n"
        elseif esc == "t" then result[#result+1] = "\t"
        elseif esc == "r" then result[#result+1] = "\r"
        elseif esc == string.char(34) then result[#result+1] = string.char(34)
        elseif esc == "\\" then result[#result+1] = "\\"
        elseif esc == "/" then result[#result+1] = "/"
        elseif esc == "b" then result[#result+1] = "\b"
        elseif esc == "f" then result[#result+1] = "\f"
        elseif esc == "u" then
          local hex = s:sub(pos+1, pos+4)
          result[#result+1] = string.char(tonumber(hex, 16))
          pos = pos + 4
        else
          result[#result+1] = esc
        end
      elseif c == string.char(34) then
        pos = pos + 1
        break
      else
        result[#result+1] = c
      end
      pos = pos + 1
    end
    return table.concat(result)
  end
  function parse_bool()
    if s:sub(pos, pos+3) == "true" then pos = pos + 4; return true end
    pos = pos + 5; return false
  end
  function parse_null()
    pos = pos + 4; return nil
  end
  function parse_number()
    local start = pos
    while pos <= len and s:sub(pos,pos):match("[%-%.%deE]") do pos = pos + 1 end
    return tonumber(s:sub(start, pos-1))
  end
  return parse_value()
end
json.loads = json.decode

-- site
site = {}
site.getsitepackages = function()
  local paths = {}
  local home = os.getenv("HOME") or "/"
  paths[#paths+1] = home .. "/.local/lib/python3.14/site-packages"
  paths[#paths+1] = "/usr/lib/python3.14/site-packages"
  paths[#paths+1] = "/usr/local/lib/python3.14/site-packages"
  return paths
end
site.getusersitepackages = function()
  return os.getenv("HOME") .. "/.local/lib/python3.14/site-packages"
end
site.addsitedir = function(dir) end

os.path = os.path or {}
os.path.join = function(...) local a={...}; return table.concat(a, "/") end
os.path.exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end
os.path.isfile = os.path.exists
os.path.isdir = function(p) return false end
os.rmdir = os.remove or function(p) end

-- open builtin (Python's open -> io.open)
open = io.open

-- tempfile
tempfile = {}
tempfile._counter = 0
tempfile.gettempdir = function() return os.getenv("TMPDIR") or "/tmp" end
tempfile.mkdtemp = function(suffix, prefix, dir, _kw)
  -- Handle keyword-only call: single table arg
  if type(suffix) == "table" and prefix == nil then
    _kw = suffix
    suffix = nil
    prefix = nil
    dir = nil
  end
  suffix = _kw and _kw.suffix or suffix or ""
  prefix = _kw and _kw.prefix or prefix or "tmp"
  dir = _kw and _kw.dir or dir or tempfile.gettempdir()
  tempfile._counter = tempfile._counter + 1
  local name = dir .. "/" .. prefix .. tostring(os.time()) .. "_" .. tempfile._counter .. suffix
  os.execute("mkdir -p " .. name)
  return name
end
tempfile.mkstemp = function(suffix, prefix, dir, _kw)
  -- Handle keyword-only call: single table arg
  if type(suffix) == "table" and prefix == nil then
    _kw = suffix
    suffix = nil
    prefix = nil
    dir = nil
  end
  suffix = _kw and _kw.suffix or suffix or ""
  prefix = _kw and _kw.prefix or prefix or "tmp"
  dir = _kw and _kw.dir or dir or tempfile.gettempdir()
  tempfile._counter = tempfile._counter + 1
  local base = dir or tempfile.gettempdir()
  local name = base .. "/" .. prefix .. tostring(os.time()) .. "_" .. tempfile._counter .. suffix
  local f = io.open(name, "w+")
  if not f then error("cannot create temp file: " .. name) end
  return {f, name}
end
tempfile.NamedTemporaryFile = function(suffix, prefix, dir, delete, mode, _kw)
  -- Handle keyword-only call: single table arg
  if type(suffix) == "table" and prefix == nil then
    _kw = suffix
    suffix = nil
    prefix = nil
    dir = nil
    delete = nil
    mode = nil
  end
  suffix = _kw and _kw.suffix or suffix or ""
  prefix = _kw and _kw.prefix or prefix or "tmp"
  dir = _kw and _kw.dir or dir or tempfile.gettempdir()
  if _kw and _kw.delete ~= nil then delete = _kw.delete end
  if delete == nil then delete = true end
  mode = _kw and _kw.mode or mode or "w+"
  tempfile._counter = tempfile._counter + 1
  local base = dir or tempfile.gettempdir()
  local name = base .. "/" .. prefix .. tostring(os.time()) .. "_" .. tempfile._counter .. suffix
  local f = io.open(name, mode)
  if not f then error("cannot create temp file: " .. name) end
  local self = {_file = f, _name = name, _delete = delete}
  function self:write(...) return self._file:write(...) end
  function self:read(...) return self._file:read(...) end
  function self:close() self._file:close(); if self._delete then os.remove(self._name) end end
  function self:name() return self._name end
  function self:flush() return self._file:flush() end
  function self:seek(...) return self._file:seek(...) end
  return self
end
tempfile.TemporaryFile = function(mode, _kw)
  -- Handle keyword-only call: single table arg
  if type(mode) == "table" and _kw == nil then
    _kw = mode
    mode = nil
  end
  mode = _kw and _kw.mode or mode or "w+"
  return tempfile.NamedTemporaryFile("", "tmp", nil, true, mode, _kw)
end

-- dataclasses
dataclasses = {}
dataclasses.field = function(default) return default end

function dataclasses_repr(self, fields)
  local parts = {}
  for _, f in ipairs(fields) do
    parts[#parts+1] = f .. "=" .. tostring(self[f])
  end
  return (self.__name__ or "Class") .. "(" .. table.concat(parts, ", ") .. ")"
end

function dataclasses_eq(self, other, fields)
  if self.__name__ ~= other.__name__ then return false end
  for _, f in ipairs(fields) do
    if self[f] ~= other[f] then return false end
  end
  return true
end

-- subprocess
subprocess = {}
subprocess.CompletedProcess = function(args, returncode, stdout, stderr)
  local cp = {args=args, returncode=returncode, stdout=stdout, stderr=stderr}
  return cp
end
subprocess.run = function(cmd, capture_output)
  capture_output = capture_output or false
  if capture_output then
    local f = io.popen(cmd .. " 2>&1")
    local output = f:read("*a")
    f:close()
    -- LuaJIT io.popen returns exit code via close
    local rc = 0 -- simplified; actual exit code handling varies
    return subprocess.CompletedProcess(cmd, rc, output, nil)
  else
    local rc = os.execute(cmd)
    return subprocess.CompletedProcess(cmd, rc, nil, nil)
  end
end
subprocess.call = function(cmd)
  local cp = subprocess.run(cmd, false)
  return cp.returncode
end
subprocess.check_output = function(cmd)
  local cp = subprocess.run(cmd, true)
  return cp.stdout
end
subprocess.Popen = function(cmd)
  local f = io.popen(cmd .. " 2>&1")
  local self = {_f=f}
  function self:read() return self._f:read("*a") end
  function self:close() return self._f:close() end
  function self:poll() return nil end -- simplified
  return self
end

-- ast
ast = {}
ast.Module = "Module"
ast.FunctionDef = "FunctionDef"
ast.AsyncFunctionDef = "AsyncFunctionDef"
ast.ClassDef = "ClassDef"
ast.Return = "Return"
ast.If = "If"
ast.While = "While"
ast.For = "For"
ast.With = "With"
ast.Try = "Try"
ast.Assign = "Assign"
ast.AnnAssign = "AnnAssign"
ast.AugAssign = "AugAssign"
ast.Name = "Name"
ast.Attribute = "Attribute"
ast.Call = "Call"
ast.BinOp = "BinOp"
ast.UnaryOp = "UnaryOp"
ast.Compare = "Compare"
ast.Constant = "Constant"
ast.List = "List"
ast.Tuple = "Tuple"
ast.Set = "Set"
ast.Dict = "Dict"
ast.ListComp = "ListComp"
ast.SetComp = "SetComp"
ast.DictComp = "DictComp"
ast.GeneratorExp = "GeneratorExp"
ast.Lambda = "Lambda"
ast.IfExp = "IfExp"
ast.BoolOp = "BoolOp"
ast.Starred = "Starred"
ast.Subscript = "Subscript"
ast.Slice = "Slice"
ast.Eq = "Eq"
ast.NotEq = "NotEq"
ast.Lt = "Lt"
ast.LtE = "LtE"
ast.Gt = "Gt"
ast.GtE = "GtE"
ast.Add = "Add"
ast.Sub = "Sub"
ast.Mult = "Mult"
ast.Div = "Div"
ast.Mod = "Mod"
ast.Pow = "Pow"

ast.dump = function(node, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  if type(node) == "table" then
    local parts = {}
    parts[#parts+1] = pad .. "table("
    local first = true
    for k, v in pairs(node) do
      if first then first = false else parts[#parts+1] = "," end
      parts[#parts+1] = "\n" .. pad .. "  " .. tostring(k) .. " = " .. ast.dump(v, indent + 2)
    end
    if #parts > 2 then parts[#parts+1] = "\n" .. pad end
    parts[#parts+1] = ")"
    return table.concat(parts)
  elseif type(node) == "string" then
    return pad .. '"' .. node .. '"'
  elseif type(node) == "number" then
    return pad .. tostring(node)
  elseif type(node) == "boolean" then
    return pad .. tostring(node)
  elseif node == nil then
    return pad .. "nil"
  else
    return pad .. type(node)
  end
end

ast.parse = function(source)
  error("ast.parse is not available in Lua target; parse Python source before transpiling", 2)
end

ast.iter_fields = function(node)
  if type(node) ~= "table" then return function() return nil end end
  local keys = {}
  for k in pairs(node) do keys[#keys+1] = k end
  table.sort(keys)
  local i = 0
  return function()
    i = i + 1
    local k = keys[i]
    if k == nil then return nil end
    return k, node[k]
  end
end

ast.walk = function(node)
  local visited = {}
  local stack = {node}
  return function()
    while #stack > 0 do
      local n = table.remove(stack)
      if type(n) == "table" then
        if visited[tostring(n)] then
          -- skip already visited
        else
          visited[tostring(n)] = true
          -- push fields
          for k, v in pairs(n) do
            if type(v) == "table" then table.insert(stack, v) end
          end
          return n
        end
      end
    end
    return nil
  end
end

ast.fix_missing_locations = function(node)
  return node
end

ast.copy_location = function(new_node, old_node)
  return new_node
end

ast.increment_lineno = function(node, n)
  n = n or 1
  return node
end
"""

