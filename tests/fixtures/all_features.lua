-- Luthon runtime helpers
local bit = require('bit')
function range(a, b, step)
    if b == nil then a, b = 0, a; step = 1 end
    if step == nil then step = 1 end
    local r = {}
    if step > 0 then for i = a, b - 1, step do r[#r+1] = i end
    else for i = a, b + 1, step do r[#r+1] = i end end
    return r
end
function len(t) return #t end
open = io.open
function ValueError(m) return m end
sqrt = math.sqrt
if not os.path then os.path = {join = function(...) local a={...}; return table.concat(a, '/') end} end
function str(x) return tostring(x) end
function int(x) return math.floor(tonumber(x) or 0) end
function float(x) return tonumber(x) or 0.0 end
function bool(x) return not not x end
function list(t) local r={} for i,v in ipairs(t or {}) do r[i]=v end return r end
function dict(t) return t or {} end
function set(t) local r={} for _,v in ipairs(t or {}) do r[v]=true end return r end
function tuple(t) return t end
function abs(x) return math.abs(x) end
function min(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]<m then m=a[i] end end return m end
function max(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]>m then m=a[i] end end return m end
function sum(t) local s=0; for _,v in ipairs(t) do s=s+v end return s end
function sorted(t) local r=list(t); table.sort(r); return r end
function enumerate(t) local r={}; for i,v in ipairs(t) do r[i]={i-1,v} end return r end
function zip(a,b) local r={}; for i=1,math.min(#a,#b) do r[i]={a[i],b[i]} end return r end
function any(t) for _,v in ipairs(t) do if v then return true end end return false end
function all(t) for _,v in ipairs(t) do if not v then return false end end return true end

local os = require('os')
local sqrt = require('math').sqrt
x = 5
x = x + 3
function f(a, b)
    if b == nil then b = 2 end
    if a > b then
        return a
    elseif a == b then
        return 0
    else
        return b
    end
end
local A = {}
    A.__index = A
    setmetatable(A, {__call = function(cls, ...) return cls.new(...) end})
    function A.new(...)
        local self = setmetatable({}, A)
        if self.init then self:init(...) end
        return self
    end
    function A:__init__(v)
        self.v = v
    end
    function A:get()
        return self.v
    end
a = A(10)
print(a:get())
y = (function() local r={}; for _,i in ipairs({1, 2, 3}) do if i > 1 then r[#r+1]=(i * 2) end end return r end)()
d = (function() local r={}; for _,k in ipairs({1, 2, 3}) do if true then r[k]=(k * k) end end return r end)()
s = (function() local r={}; for _,i in ipairs({1, 2, 3}) do if true then r[i]=true end end return r end)()
t = {1, 2, 3}
do
    local __tmp = (function() local r={}; local i=0; for idx=0,2,1 do i=i+1; r[i]=t[idx] end return r end)()
    u = __tmp[1]
    v = __tmp[2]
end
z = (false and x or 7)
local __ok, __err = pcall(function()
    error(ValueError('boom'))
end)
if not __ok then
    if tostring(__err):find('ValueError') then
        local e = __err
        print(e)
    end
end
print('done')
assert(1 == 1, 'ok')
fh = {['__enter__'] = function(self) return nil end, ['__exit__'] = function(self) return nil end}
local __ctx0 = fh
if __ctx0.__enter__ then __ctx0:__enter__() end
do
    -- pass
end
if __ctx0.__exit__ then __ctx0:__exit__() end
lambda_fn = function(x) return (x + 1) end
print(lambda_fn(5))
for _, i in ipairs({1, 2, 3}) do
    if i == 2 then
        -- continue (not native in Lua; use goto)
        goto __continue
    end
    if i == 3 then
        break
    end
    ::__continue::
end
-- for-else (approximated)
print('no break')
while false do
    -- pass
end
print(sqrt(16))
print(os.path.join('a', 'b'))
