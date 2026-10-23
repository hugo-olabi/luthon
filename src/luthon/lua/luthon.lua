-- Luthon runtime library for LuaJIT
-- Provides Python-like helpers and string methods.

local M = {}

-- string methods
function M.str(x) return tostring(x) end
function M.len(x) return #x end

local strmt = {}
strmt.__index = function(s, k)
    if type(k) == "string" then
        if k == "upper" then return function(self) return string.upper(self) end
        elseif k == "lower" then return function(self) return string.lower(self) end
        elseif k == "strip" then return function(self) return self:match("^%s*(.-)%s*$") end
        elseif k == "split" then return function(self, sep)
            sep = sep or "%s"
            local r = {}
            for part in self:gmatch("([^" .. sep .. "]+)") do r[#r+1] = part end
            return r
        end
        elseif k == "replace" then return function(self, a, b) return self:gsub(a, b) end
        elseif k == "startswith" then return function(self, p) return self:sub(1, #p) == p end
        elseif k == "endswith" then return function(self, p) return self:sub(-#p) == p end
        elseif k == "find" then return function(self, p) return self:find(p, 1, true) end
        end
    end
    return nil
end
-- attach to strings via metatable
debug.setmetatable("", strmt)

-- collections
function M.list(t) local r = {} for i,v in ipairs(t or {}) do r[i]=v end return r end
function M.dict(t) return t or {} end
function M.set(t) local r={} for _,v in ipairs(t or {}) do r[v]=true end return r end
function M.tuple(t) return t end
function M.range(a, b, step)
    if b == nil then a, b = 0, a; step = 1 end
    if step == nil then step = 1 end
    local r = {}
    if step > 0 then for i = a, b - 1, step do r[#r+1] = i end
    else for i = a, b + 1, step do r[#r+1] = i end end
    return r
end
function M.enumerate(t) local r={} for i,v in ipairs(t) do r[i]={i-1,v} end return r end
function M.zip(a,b) local r={} for i=1,math.min(#a,#b) do r[i]={a[i],b[i]} end return r end
function M.sorted(t) local r=M.list(t); table.sort(r); return r end
function M.sum(t) local s=0 for _,v in ipairs(t) do s=s+v end return s end
function M.min(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]<m then m=a[i] end end return m end
function M.max(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]>m then m=a[i] end end return m end
function M.abs(x) return math.abs(x) end
function M.any(t) for _,v in ipairs(t) do if v then return true end end return false end
function M.all(t) for _,v in ipairs(t) do if not v then return false end end return true end
function M.int(x) return math.floor(tonumber(x) or 0) end
function M.float(x) return tonumber(x) or 0.0 end
function M.bool(x) return not not x end

-- context manager helper
function M.with(ctx, body)
    if ctx.__enter__ then ctx:__enter__() end
    local ok, err = pcall(body, ctx)
    if ctx.__exit__ then ctx:__exit__() end
    if not ok then error(err) end
end

-- generator wrapping helper
function M.gen(f)
    return coroutine.wrap(f)
end

-- module registration
M.modules = M.modules or {}
function M.module(name, t)
    M.modules[name] = t
    package.loaded[name] = t
    return t
end

-- simple MRO: walk __index chain
function M.getattr(obj, name)
    local cls = getmetatable(obj) and getmetatable(obj).__index
    while cls do
        if cls[name] ~= nil then return cls[name] end
        cls = getmetatable(cls) and getmetatable(cls).__index
    end
    return nil
end

return M
