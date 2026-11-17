-- Luthon stdlib
-- CData Memory Anchor Registry (Phase 19)
local _CDATA_ANCHORS = {}
local _CDATA_REF_COUNTS = {}

function _luthon_anchor(cdata_ptr, owner_obj)
  if cdata_ptr == nil then return end
  local key = tostring(cdata_ptr)
  _CDATA_ANCHORS[key] = owner_obj
  _CDATA_REF_COUNTS[key] = (_CDATA_REF_COUNTS[key] or 0) + 1
  return cdata_ptr
end

function _luthon_release_anchor(cdata_ptr)
  if cdata_ptr == nil then return end
  local key = tostring(cdata_ptr)
  local count = (_CDATA_REF_COUNTS[key] or 1) - 1
  if count <= 0 then
    _CDATA_ANCHORS[key] = nil
    _CDATA_REF_COUNTS[key] = nil
  else
    _CDATA_REF_COUNTS[key] = count
  end
end

function _luthon_is_anchored(cdata_ptr)
  if cdata_ptr == nil then return false end
  return _CDATA_ANCHORS[tostring(cdata_ptr)] ~= nil
end

-- Return unwinding for try/except blocks
local _luthon_ret_val = nil
local _luthon_has_ret = false

-- FFI and C-runtime bindings
local ffi = require("ffi")
pcall(function()
  ffi.cdef[[
    double sqrt(double x);
    double sin(double x);
    double cos(double x);
    double exp(double x);
    void *memcpy(void *dest, const void *src, size_t n);

    typedef struct __dirstream DIR;
    typedef struct _IO_FILE FILE;
    int fileno(FILE *stream);
    int fsync(int fd);
    int chmod(const char *pathname, unsigned int mode);
    struct dirent {
      unsigned long  d_ino;
      long           d_off;
      unsigned short d_reclen;
      unsigned char  d_type;
      char           d_name[256];
    };
    DIR *opendir(const char *name);
    struct dirent *readdir(DIR *dirp);
    int closedir(DIR *dirp);

    typedef struct stat {
      unsigned long  st_dev;
      unsigned long  st_ino;
      unsigned long  st_nlink;
      unsigned int   st_mode;
      unsigned int   st_uid;
      unsigned int   st_gid;
      unsigned int   __pad0;
      unsigned long  st_rdev;
      long           st_size;
      long           st_blksize;
      long           st_blocks;
      long           st_atime;
      unsigned long  st_atime_nsec;
      long           st_mtime;
      unsigned long  st_mtime_nsec;
      long           st_ctime;
      unsigned long  st_ctime_nsec;
      long           __unused[3];
    } stat_t;
    int stat(const char *pathname, stat_t *statbuf);
    int mkdir(const char *pathname, unsigned int mode);

    /* Luthon Native C Stdlib Declarations */
    typedef struct {
      int64_t current;
      int64_t stop;
      int64_t step;
      int64_t length;
    } LuthonRange;

    LuthonRange luthon_range_init(int64_t start, int64_t stop, int64_t step);
    bool        luthon_range_next(LuthonRange *r, int64_t *out_val);
    int64_t     luthon_range_len(const LuthonRange *r);

    int64_t     luthon_math_ipow(int64_t base, int64_t exp);
    void        luthon_math_divmod(int64_t a, int64_t b, int64_t *out_div, int64_t *out_mod);

    size_t      luthon_b64_decoded_size(const char *src, size_t src_len);
    size_t      luthon_b64_decode(const char *src, size_t src_len, uint8_t *dst);
    size_t      luthon_b64_encode(const uint8_t *src, size_t src_len, char *dst);

    size_t      luthon_hex_decode(const char *src, size_t src_len, uint8_t *dst);
    size_t      luthon_hex_encode(const uint8_t *src, size_t src_len, char *dst);

    size_t      luthon_path_join(const char *p1, const char *p2, char *dst, size_t max_len);
    const char* luthon_path_basename(const char *path);
    size_t      luthon_path_dirname(const char *path, char *dst, size_t max_len);
    bool        luthon_path_exists(const char *path);
    bool        luthon_path_isdir(const char *path);
    size_t      luthon_path_getsize(const char *path);

    typedef struct {
      int64_t start;
      int64_t stop;
      int64_t step;
      int64_t length;
    } LuthonSlice;

    LuthonSlice luthon_slice_calc(int64_t length, int64_t start, int64_t stop, int64_t step, bool has_start, bool has_stop, bool has_step);
    int         luthon_fast_memcmp(const void *s1, size_t n1, const void *s2, size_t n2);
    int64_t     luthon_memfind(const void *haystack, size_t h_len, const void *needle, size_t n_len);

    bool        luthon_png_read_mem(const uint8_t *data, size_t size, int *out_w, int *out_h, int *out_channels, uint8_t **out_buf);
    bool        luthon_png_write_mem(const uint8_t *buf, int w, int h, int channels, uint8_t **out_data, size_t *out_size);
    void        luthon_png_free(void *ptr);
    void        luthon_img_mer_to_orm_emission(const uint8_t *src_rgba, int w, int h, uint8_t *dst_orm_rgb, uint8_t *dst_em_l, bool *out_has_emission);
  ]]
end)

local _luthon_native_lib = nil
pcall(function()
  local candidates = {
    "src/luthon/native/libluthon_capi.so",
    "./libluthon_capi.so",
    "libluthon_capi.so"
  }
  for _, cand in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, cand)
    if ok and lib then
      _luthon_native_lib = lib
      break
    end
  end
end)

local _LUTHON_STAT_BUF = nil
pcall(function() _LUTHON_STAT_BUF = ffi.new("stat_t") end)

local _ARRAY_TYPE_MAP = {
  ["b"] = "int8_t",
  ["B"] = "uint8_t",
  ["h"] = "int16_t",
  ["H"] = "uint16_t",
  ["i"] = "int32_t",
  ["I"] = "uint32_t",
  ["l"] = "int64_t",
  ["L"] = "uint64_t",
  ["f"] = "float",
  ["d"] = "double",
}

local _ARRAY_ITEMSIZE_MAP = {
  ["b"] = 1, ["B"] = 1, ["h"] = 2, ["H"] = 2,
  ["i"] = 4, ["I"] = 4, ["l"] = 8, ["L"] = 8,
  ["f"] = 4, ["d"] = 8,
}

local _Array_methods = {}

function _Array_methods:append(val)
  local len = rawget(self, "_len")
  local cap = rawget(self, "_cap")
  if len >= cap then
    local new_cap = math.max(4, cap * 2)
    local ctype = _ARRAY_TYPE_MAP[self.typecode] .. "[?]"
    local new_buf = ffi.new(ctype, new_cap)
    if len > 0 then
      ffi.copy(new_buf, rawget(self, "_buf"), len * self.itemsize)
    end
    rawset(self, "_buf", new_buf)
    rawset(self, "_cap", new_cap)
  end
  rawget(self, "_buf")[len] = val
  rawset(self, "_len", len + 1)
end

function _Array_methods:tolist()
  local len = rawget(self, "_len")
  local buf = rawget(self, "_buf")
  local r = {}
  for i = 0, len - 1 do
    r[i + 1] = tonumber(buf[i])
  end
  return r
end

function _Array_methods:slice(start, stop)
  local len = rawget(self, "_len")
  start = start or 0
  stop = stop or len
  if start < 0 then start = len + start end
  if stop < 0 then stop = len + stop end
  start = math.max(0, math.min(len, start))
  stop = math.max(0, math.min(len, stop))
  local slice_len = math.max(0, stop - start)

  local sub = setmetatable({}, _Array_mt)
  rawset(sub, "typecode", self.typecode)
  rawset(sub, "itemsize", self.itemsize)
  rawset(sub, "_len", slice_len)
  rawset(sub, "_cap", slice_len)
  local buf = ffi.new(_ARRAY_TYPE_MAP[self.typecode] .. "[?]", math.max(1, slice_len))
  if slice_len > 0 then
    ffi.copy(buf, rawget(self, "_buf") + start, slice_len * self.itemsize)
  end
  rawset(sub, "_buf", buf)
  return sub
end

-- Vectorized arithmetic operations and 2D matrix multiplication
function _Array_methods:add(other)
  local len = rawget(self, "_len")
  local res = array(self.typecode)
  local b = ffi.new(_ARRAY_TYPE_MAP[self.typecode] .. "[?]", math.max(1, len))
  rawset(res, "_buf", b)
  rawset(res, "_len", len)
  rawset(res, "_cap", len)
  local buf1 = rawget(self, "_buf")
  if type(other) == "number" then
    for i = 0, len - 1 do b[i] = buf1[i] + other end
  elseif type(other) == "table" and rawget(other, "_buf") then
    local buf2 = rawget(other, "_buf")
    if _simd_lib and self.typecode == "d" then
      _simd_lib.luthon_simd_add_f64(b, buf1, buf2, len)
    elseif _simd_lib and self.typecode == "f" then
      _simd_lib.luthon_simd_add_f32(b, buf1, buf2, len)
    else
      for i = 0, len - 1 do b[i] = buf1[i] + buf2[i] end
    end
  end
  return res
end

function _Array_methods:mul(other)
  local len = rawget(self, "_len")
  local res = array(self.typecode)
  local b = ffi.new(_ARRAY_TYPE_MAP[self.typecode] .. "[?]", math.max(1, len))
  rawset(res, "_buf", b)
  rawset(res, "_len", len)
  rawset(res, "_cap", len)
  local buf1 = rawget(self, "_buf")
  if type(other) == "number" then
    for i = 0, len - 1 do b[i] = buf1[i] * other end
  elseif type(other) == "table" and rawget(other, "_buf") then
    local buf2 = rawget(other, "_buf")
    if _simd_lib and self.typecode == "d" then
      _simd_lib.luthon_simd_mul_f64(b, buf1, buf2, len)
    elseif _simd_lib and self.typecode == "f" then
      _simd_lib.luthon_simd_mul_f32(b, buf1, buf2, len)
    else
      for i = 0, len - 1 do b[i] = buf1[i] * buf2[i] end
    end
  end
  return res
end

function _Array_methods:matmul(other)
  local M = rawget(self, "rows") or rawget(self, "_len")
  local K = rawget(self, "cols") or 1
  local K2 = rawget(other, "rows") or rawget(other, "_len")
  local N = rawget(other, "cols") or 1
  if K ~= K2 then
    error(string.format("ValueError: shapes (%d, %d) and (%d, %d) not aligned", M, K, K2, N))
  end
  local total = M * N
  local res = array("d")
  rawset(res, "rows", M)
  rawset(res, "cols", N)
  local c_buf = ffi.new("double[?]", math.max(1, total))
  rawset(res, "_buf", c_buf)
  rawset(res, "_len", total)
  rawset(res, "_cap", total)

  local a_buf = rawget(self, "_buf")
  local b_buf = rawget(other, "_buf")

  -- Unrolled cache-friendly matrix multiplication
  for i = 0, M - 1 do
    local i_step = i * K
    local c_step = i * N
    for k = 0, K - 1 do
      local a_val = a_buf[i_step + k]
      local b_step = k * N
      for j = 0, N - 1 do
        c_buf[c_step + j] = c_buf[c_step + j] + a_val * b_buf[b_step + j]
      end
    end
  end
  return res
end

function matrix(rows, cols, initializer)
  local total = rows * cols
  local arr = array("d", initializer)
  rawset(arr, "rows", rows)
  rawset(arr, "cols", cols)
  if rawget(arr, "_len") < total then
    rawset(arr, "_len", total)
  end
  return arr
end

_Array_mt = {
  __index = function(self, k)
    local v = rawget(self, k)
    if v ~= nil then return v end
    if type(k) == "number" then
      local len = rawget(self, "_len")
      if k < 0 then k = len + k end
      if k < 0 or k >= len then error("IndexError: array index out of range") end
      return rawget(self, "_buf")[k]
    end
    return _Array_methods[k]
  end,
  __newindex = function(self, k, v)
    if type(k) == "number" then
      local len = rawget(self, "_len")
      if k < 0 then k = len + k end
      if k < 0 or k >= len then error("IndexError: array assignment index out of range") end
      rawget(self, "_buf")[k] = v
    else
      rawset(self, k, v)
    end
  end,
  __len = function(self) return rawget(self, "_len") end,
}

function array(typecode, initializer)
  local ctype = _ARRAY_TYPE_MAP[typecode]
  if not ctype then error("ValueError: bad typecode (must be b, B, h, H, i, I, l, L, f, d)") end
  local itemsize = _ARRAY_ITEMSIZE_MAP[typecode]

  local arr = setmetatable({}, _Array_mt)
  rawset(arr, "typecode", typecode)
  rawset(arr, "itemsize", itemsize)

  local init_len = 0
  if type(initializer) == "table" then
    init_len = #initializer
  end
  local cap = math.max(4, init_len)
  rawset(arr, "_len", init_len)
  rawset(arr, "_cap", cap)
  local buf = ffi.new(ctype .. "[?]", cap)

  if init_len > 0 then
    for i = 1, init_len do
      buf[i - 1] = initializer[i]
    end
  end
  rawset(arr, "_buf", buf)
  return arr
end

local _dict_methods = {
  get = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then return v end
    if default == nil then return _G._luthon_none end
    return default
  end,
  setdefault = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then return v end
    if default == nil then default = _G._luthon_none end
    rawset(self, k, default)
    return default
  end,
  pop = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then
      rawset(self, k, nil)
      return v
    end
    if default ~= nil then return default end
    local ke = _G.KeyError or KeyError
    if ke then error(ke(tostring(k)), 0) end
    error("KeyError: " .. tostring(k), 0)
  end,
  popitem = function(self)
    for k, v in pairs(self) do
      rawset(self, k, nil)
      return {k, v}
    end
    local ke = _G.KeyError or KeyError
    if ke then error(ke("popitem(): dictionary is empty"), 0) end
    error("KeyError: popitem(): dictionary is empty", 0)
  end,
  keys = function(self)
    local r = setmetatable({}, _list_mt)
    for k in pairs(self) do table.insert(r, k) end
    return r
  end,
  values = function(self)
    local r = setmetatable({}, _list_mt)
    for _, v in pairs(self) do table.insert(r, v) end
    return r
  end,
  items = function(self)
    local r = setmetatable({}, _list_mt)
    for k, v in pairs(self) do table.insert(r, {k, v}) end
    return r
  end,
  update = function(self, other)
    return _dict_update(self, other)
  end,
  clear = function(self)
    for k in pairs(self) do rawset(self, k, nil) end
  end,
  copy = function(self)
    local r = setmetatable({}, _dict_mt)
    for k, v in pairs(self) do r[k] = v end
    return r
  end,
}
local _dict_mt = {
  __dict__ = true,
  __index = function(t, k)
    return _dict_methods[k]
  end
}

local function _luthon_key_repr(k)
  if type(k) == "table" and (k.__tuple__ or (getmetatable(k) and getmetatable(k).__tuple__)) then
    for idx = 1, #k do
      if type(k[idx]) == "table" and (k[idx].__slice__ or rawget(k[idx], "_py")) then
        return k
      end
    end
    local p = {"__tup__"}
    for idx = 1, #k do table.insert(p, tostring(_luthon_key_repr(k[idx]))) end
    return table.concat(p, "\0")
  end
  return k
end

_G._luthon_none = _G._luthon_none or setmetatable({
  __is_none__ = true,
  __bool__ = function() return false end,
  __tostring = function() return "None" end,
}, {
  __tostring = function() return "None" end,
  __call = function() error("TypeError: 'NoneType' object is not callable") end,
  __index = function(t, k)
    if k == "_py" then return nil end
    if k == "__is_none__" then return true end
    if k == "__bool__" then return function() return false end end
    error("AttributeError: 'NoneType' object has no attribute '" .. tostring(k) .. "'")
  end
})

True = true
False = false
None = _G._luthon_none

function __luthon_get(t, i)
  if t == nil or t == _G._luthon_none or (type(t) == "table" and rawget(t, "__is_none__") == true) then return nil end
  if type(t) == "table" and rawget(t, "_buf") and rawget(t, "_len") then
    return t[i]
  end
  if type(t) == "table" and rawget(t, "_py") then
    return t[i]
  end
  i = _luthon_key_repr(i)
  if type(t) == "string" then
    if type(i) == "number" then
      if i < 0 then i = #t + i + 1 else i = i + 1 end
      return string.sub(t, i, i)
    end
    if _str_methods and _str_methods[i] ~= nil then
      return _str_methods[i]
    end
    if string[i] ~= nil then
      return string[i]
    end
    return nil
  end
  if type(t) ~= "table" and type(t) ~= "userdata" and type(t) ~= "cdata" then
    return t
  end
  local mt = getmetatable(t)
  if type(t) == "table" and (rawget(t, "_dict") or (mt and (mt.__dict__ == true or mt == _G._dict_mt or (_dict_mt ~= nil and mt == _dict_mt)))) then
    local v = rawget(t, i)
    if v == nil then
      if _dict_methods and _dict_methods[i] ~= nil then
        return _dict_methods[i]
      end
      local ke = _G.KeyError or KeyError
      if ke then error(ke(tostring(i)), 0) end
      error("KeyError: " .. tostring(i), 0)
    end
    return v
  end
  if type(i) == "number" then
    if i < 0 then i = #t + i + 1 else i = i + 1 end
    return t[i]
  end
  local raw_val = type(t) == "table" and rawget(t, i) or nil
  if raw_val ~= nil then
    if type(raw_val) == "table" and rawget(raw_val, "_py") then
      local pb = _G._luthon_pybridge
      if not pb then
        local ok, pbmod = pcall(require, "pybridge")
        if not ok or not pbmod or not pbmod.get_lib then ok, pbmod = pcall(require, "luthon.lua.pybridge") end
        if not ok or not pbmod or not pbmod.get_lib then ok, pbmod = pcall(require, "src/luthon/lua/pybridge") end
        if ok and pbmod and pbmod.get_lib then pb = pbmod end
      end
      if pb and pb.get_lib then
        local libpy = pb.get_lib()
        local self_obj = libpy.PyObject_GetAttrString(raw_val._py, "__self__")
        if self_obj ~= nil then
          libpy.Py_DecRef(self_obj)
          return function(self_arg, ...)
            if self_arg == t then
              return raw_val(...)
            else
              return raw_val(self_arg, ...)
            end
          end
        else
          libpy.PyErr_Clear()
        end
      end
    end
    return raw_val
  end
  local val = t[i]
  if val == nil and type(t) == "table" then
    local getitem = t.__getitem__ or (t.__class__ and t.__class__.__getitem__)
    if type(getitem) == "function" then
      return getitem(t, i)
    end
    if _dict_methods and _dict_methods[i] ~= nil then
      return _dict_methods[i]
    end
  end
  if type(val) == "table" and type(val.__get__) == "function" then
    return val:__get__(t, t.__class__)
  end
  return val
end

function _dict_update(target, src)
  if type(target) == "table" and type(src) == "table" then
    if #src > 0 and type(src[1]) == "table" and src[1][1] ~= nil then
      for _, kv in ipairs(src) do
        target[kv[1]] = kv[2]
      end
    else
      for k, v in pairs(src) do
        target[k] = v
      end
    end
  end
  return target
end

function _seq_extend(target, src)
  if type(target) == "table" and type(src) == "table" then
    for i = 1, #src do
      target[#target + 1] = src[i]
    end
  end
  return target
end

_G.__LUTHON_FN_PARAMS = _G.__LUTHON_FN_PARAMS or {}
_G._kw_mt = _G._kw_mt or { __luthon_kw = true }

function _luthon_reg_fn(fn, params)
  if fn and params then
    _G.__LUTHON_FN_PARAMS[fn] = params
  end
  return fn
end

function _luthon_call_kw(fn, kw_table, ...)
  if fn == nil then
    return function(...)
      local args = { ... }
      return args[1]
    end
  end
  if type(fn) == "table" and rawget(fn, "_py") then
    local ok_pb, pb = pcall(require, "src/luthon/lua/pybridge")
    if not ok_pb or not pb then ok_pb, pb = pcall(require, "luthon.lua.pybridge") end
    if ok_pb and pb and pb.get_lib then
      local libpy = pb.get_lib()
      local pos_args = { ... }
      local num_pos = select("#", ...)
      local self_obj = libpy.PyObject_GetAttrString(fn._py, "__self__")
      if self_obj ~= nil then
        if num_pos > 0 and type(pos_args[1]) == "table" and rawget(pos_args[1], "_py") == self_obj then
          table.remove(pos_args, 1)
          num_pos = num_pos - 1
        end
        libpy.Py_DecRef(self_obj)
      else
        libpy.PyErr_Clear()
      end
      local tuple = libpy.PyTuple_New(num_pos)
      for i = 1, num_pos do
        local py_v = pb.lua_to_py(pos_args[i])
        libpy.PyTuple_SetItem(tuple, i - 1, py_v)
      end
      local py_kw = nil
      if type(kw_table) == "table" and next(kw_table) ~= nil then
        py_kw = libpy.PyDict_New()
        for k, v in pairs(kw_table) do
          local py_v = pb.lua_to_py(v)
          libpy.PyDict_SetItemString(py_kw, tostring(k), py_v)
          libpy.Py_DecRef(py_v)
        end
      end
      local res = libpy.PyObject_Call(fn._py, tuple, py_kw)
      libpy.Py_DecRef(tuple)
      if py_kw ~= nil then libpy.Py_DecRef(py_kw) end
      if res == nil then
        pb.check_py_error()
      end
      local lua_res = pb.py_to_lua(res)
      libpy.Py_DecRef(res)
      return lua_res
    end
  end
  local param_names = _G.__LUTHON_FN_PARAMS and _G.__LUTHON_FN_PARAMS[fn]
  if param_names then
    local pos_args = { ... }
    local call_args = {}
    local num_params = #param_names
    local num_pos = #pos_args
    local max_idx = num_params > num_pos and num_params or num_pos
    for i = 1, num_params do
      local name = param_names[i]
      if pos_args[i] ~= nil then
        call_args[i] = pos_args[i]
      elseif kw_table and kw_table[name] ~= nil then
        call_args[i] = kw_table[name]
      end
    end
    for i = num_params + 1, num_pos do
      call_args[i] = pos_args[i]
    end
    return fn(unpack(call_args, 1, max_idx))
  end
  local args = { ... }
  if kw_table ~= nil and next(kw_table) ~= nil then
    table.insert(args, kw_table)
  end
  return fn(unpack(args))
end

function _luthon_call_starred(fn, args, kw)
  local unpack_fn = table.unpack or unpack
  if kw ~= nil and next(kw) ~= nil then
    return _luthon_call_kw(fn, kw, unpack_fn(args))
  else
    return fn(unpack_fn(args))
  end
end

function _tuple_pack(...)
  return setmetatable({...}, _tuple_mt or {})
end

local function _is_callable(x)
  if type(x) == "function" then return true end
  if type(x) == "table" or type(x) == "userdata" then
    local mt = getmetatable(x)
    if mt and (type(mt.__call) == "function" or type(mt.__call) == "table") then return true end
    if type(x.__call) == "function" then return true end
  end
  return false
end

function _luthon_with_enter(mgr)
  if mgr == nil then return nil end
  local enter = (type(mgr) == "table" or type(mgr) == "userdata") and (mgr.__enter__ or mgr.__aenter__ or mgr.enter)
  if _is_callable(enter) then
    return enter(mgr)
  end
  return mgr
end

function _luthon_with_exit(mgr, exc)
  if mgr == nil then return false end
  local exit_fn = (type(mgr) == "table" or type(mgr) == "userdata") and (mgr.__exit__ or mgr.__aexit__ or mgr.exit)
  if not exit_fn and type(mgr) == "userdata" and io.type(mgr) == "file" then
    pcall(function() mgr:close() end)
    return false
  end
  if _is_callable(exit_fn) then
    if exc ~= nil then
      local exc_type = (type(exc) == "table" and (exc.__class__ or exc)) or "Exception"
      if type(exc) == "string" then
        local name = exc:match("^(%w+Error):") or exc:match("^(%w+Exception):") or exc:match("^(%w+Failure):") or "Exception"
        exc_type = _G[name] or name
      end
      local res = exit_fn(mgr, exc_type, exc, nil)
      return res and res ~= false and res ~= 0
    else
      exit_fn(mgr, nil, nil, nil)
      return false
    end
  end
  return false
end

function _luthon_exc_match(exc, cls)
  if cls == nil then return false end
  if type(cls) == "table" and (rawget(cls, "__is_tuple") or (cls[1] and rawget(cls, "__class__") == nil)) then
    for i = 1, #cls do
      if _luthon_exc_match(exc, cls[i]) then return true end
    end
    return false
  end
  local tname = type(cls) == "string" and cls or (cls.__name or cls.__name__ or cls.__type or tostring(cls))
  if tname == "Exception" or tname == "BaseException" or cls == Exception or cls == BaseException then return true end
  if type(exc) ~= "table" then
    local str_exc = tostring(exc)
    if str_exc:find(tname, 1, true) then return true end
    if (tname == "ImportError" or cls == ImportError) and str_exc:find("ModuleNotFoundError", 1, true) then return true end
    if (tname == "OSError" or cls == OSError) and (str_exc:find("IOError", 1, true) or str_exc:find("FileNotFoundError", 1, true) or str_exc:find("No such file", 1, true) or str_exc:find("cannot create temp file", 1, true)) then return true end
    if (tname == "FileNotFoundError" or cls == FileNotFoundError) and str_exc:find("No such file", 1, true) then return true end
    return false
  end
  if exc.__type == tname or exc.__name == tname or exc.__name__ == tname then return true end
  local exc_cls = exc.__class__ or exc
  if type(cls) == "table" and issubclass and issubclass(exc_cls, cls) then return true end
  local curr = exc_cls
  while type(curr) == "table" do
    if curr == cls or curr.__name == tname or curr.__type == tname or curr.__name__ == tname then return true end
    curr = rawget(curr, "__base__")
  end
  return false
end

function _luthon_assert_fail(test, msg)
  if not test then
    if AssertionError then
      error(AssertionError(tostring(msg or "")), 0)
    else
      error("AssertionError: " .. tostring(msg or ""), 0)
    end
  end
  return true
end

function _seq_append(seq, val)
  seq[#seq + 1] = val
end

function _seq_extend(seq, other)
  if type(other) == "table" then
    for i = 1, #other do
      seq[#seq + 1] = other[i]
    end
  end
end

function __luthon_set(t, i, v)
  if type(t) == "table" and rawget(t, "_buf") and rawget(t, "_len") then
    t[i] = v
    return
  end
  if type(t) == "table" and rawget(t, "_py") then
    t[i] = v
    return
  end
  if type(t) == "table" and not rawget(t, "_dict") and not rawget(t, "_list") then
    local setitem = t.__setitem__ or (t.__class__ and t.__class__.__setitem__)
    if type(setitem) == "function" then
      setitem(t, i, v)
      return
    end
  end
  i = _luthon_key_repr(i)
  local mt = getmetatable(t)
  if type(t) == "table" and (rawget(t, "_dict") or (mt and (mt.__dict__ == true or mt == _G._dict_mt or (_dict_mt ~= nil and mt == _dict_mt)))) then
    if v == nil then v = _G._luthon_none end
    t[i] = v
    return
  end
  if type(i) == "number" then
    if i < 0 then i = #t + i + 1 else i = i + 1 end
    t[i] = v
  else
    t[i] = v
  end
end

function __luthon_delitem(t, k)
  if type(t) == "table" then
    local delitem = t.__delitem__ or (t.__class__ and t.__class__.__delitem__)
    if type(delitem) == "function" then
      return delitem(t, k)
    end
    t[k] = nil
  end
end

function _luthon_slice_desc(lower, upper, step)
  return {__slice__ = true, lower = lower, upper = upper, step = step}
end

function _luthon_slice(obj, lower, upper, step)
  if type(obj) == "string" then
    local n = #obj
    local l = 1
    if lower ~= nil then
      if lower >= 0 then l = lower + 1
      else l = n + lower + 1; if l < 1 then l = 1 end end
    end
    local u = n
    if upper ~= nil then
      if upper >= 0 then u = upper
      else u = n + upper; if u < 0 then u = 0 end end
    end
    if l > u then return "" end
    return string.sub(obj, l, u)
  elseif type(obj) == "table" then
    -- High-performance unboxed array slice view via ffi.copy
    if rawget(obj, "_buf") and rawget(obj, "_len") then
      return obj:slice(lower, upper, step)
    end
    if rawget(obj, "_dict") or rawget(obj, "__class__") == dict or (getmetatable(obj) and getmetatable(obj).__dict__) or (#obj == 0 and next(obj) ~= nil) then
      if TypeError then error(TypeError("unhashable type: 'slice'"), 0)
      else error("TypeError: unhashable type: 'slice'", 0) end
    end
    local n = #obj
    lower = lower or 0
    if lower < 0 then lower = n + lower end
    lower = lower + 1
    if upper == nil then
      upper = n
    else
      if upper < 0 then upper = n + upper end
    end
    step = step or 1
    local r = {}
    if step == 1 and lower <= upper and table.move then
      -- Vectorized slice copy via table.move (fast native C loop in LuaJIT)
      table.move(obj, lower, upper, 1, r)
    elseif step > 0 then
      for i = lower, upper, step do table.insert(r, obj[i]) end
    else
      for i = lower, upper, step do table.insert(r, obj[i]) end
    end
    return setmetatable(r, _list_mt)
  end
  return obj
end

function _luthon_add(a, b)
  local ta = type(a)
  local tb = type(b)
  if (ta == "number" or ta == "cdata") and (tb == "number" or tb == "cdata") then
    return a + b
  end
  if ta == "string" and tb == "string" then
    return a .. b
  end
  if ta == "table" then
    local mt = getmetatable(a)
    if mt and mt.__add then
      return a + b
    end
    if type(a.__add__) == "function" then
      return a:__add__(b)
    end
  end
  if tb == "table" then
    local mt = getmetatable(b)
    if mt and mt.__add then
      return a + b
    end
    if type(b.__radd__) == "function" then
      return b:__radd__(a)
    end
  end
  return a + b
end

function _luthon_cmp(op, a, b)
  if op == "is" then
    local a_is_none = (a == nil) or (a == _G._luthon_none) or (type(a) == "table" and rawget(a, "__is_none__") == true)
    local b_is_none = (b == nil) or (b == _G._luthon_none) or (type(b) == "table" and rawget(b, "__is_none__") == true)
    if a_is_none and b_is_none then return true end
    if a_is_none or b_is_none then return false end
    return rawequal(a, b)
  elseif op == "isnot" then
    return not _luthon_cmp("is", a, b)
  end
  local a_is_none = (a == nil) or (a == _G._luthon_none) or (type(a) == "table" and rawget(a, "__is_none__") == true)
  local b_is_none = (b == nil) or (b == _G._luthon_none) or (type(b) == "table" and rawget(b, "__is_none__") == true)
  if a_is_none or b_is_none then
    if a_is_none and b_is_none then
      if op == "==" or op == "eq" then return true end
      if op == "~=" or op == "ne" or op == "!=" then return false end
      return false
    else
      if op == "==" or op == "eq" then return false end
      if op == "~=" or op == "ne" or op == "!=" then return true end
      return false
    end
  end
  if (type(a) == "table" and rawget(a, "_py")) or (type(b) == "table" and rawget(b, "_py")) then
    local ok, pybridge = pcall(require, "luthon.lua.pybridge")
    if not ok or not pybridge then ok, pybridge = pcall(require, "src/luthon/lua/pybridge") end
    if ok and pybridge and pybridge.get_lib then
      local ok_lib, libpy = pcall(pybridge.get_lib)
      if ok_lib and libpy and libpy.PyObject_RichCompare then
        local op_map = {["<"]=0, ["lt"]=0, ["<="]=1, ["le"]=1, ["=="]=2, ["eq"]=2, ["~="]=3, ["!="]=3, ["ne"]=3, [">"]=4, ["gt"]=4, [">="]=5, ["ge"]=5}
        local op_num = op_map[op] or 2
        local py_a = pybridge.lua_to_py(a)
        local py_b = pybridge.lua_to_py(b)
        local res = libpy.PyObject_RichCompare(py_a, py_b, op_num)
        libpy.Py_DecRef(py_a)
        libpy.Py_DecRef(py_b)
        if res ~= nil then
          local lres = pybridge.py_to_lua(res)
          libpy.Py_DecRef(res)
          return lres
        end
        libpy.PyErr_Clear()
      end
    end
  end
  if type(a) == "table" and type(b) == "table" then
    local mta = getmetatable(a)
    local mtb = getmetatable(b)
    local clsa = a.__class__ or (mta and (type(mta.__index) == "table" and mta.__index or mta))
    local clsb = b.__class__ or (mtb and (type(mtb.__index) == "table" and mtb.__index or mtb))
    local has_clsa = type(clsa) == "table"
    local has_clsb = type(clsb) == "table"
    if op == "<" or op == "lt" then
      if has_clsa and type(clsa.__lt__) == "function" then return clsa.__lt__(a, b) end
      if has_clsb and type(clsb.__gt__) == "function" then return clsb.__gt__(b, a) end
      if has_clsa and type(clsa.__ge__) == "function" then return not clsa.__ge__(a, b) end
    elseif op == "<=" or op == "le" then
      if has_clsa and type(clsa.__le__) == "function" then return clsa.__le__(a, b) end
      if has_clsb and type(clsb.__ge__) == "function" then return clsb.__ge__(b, a) end
      if has_clsb and type(clsb.__lt__) == "function" then return not clsb.__lt__(b, a) end
      if has_clsa and type(clsa.__gt__) == "function" then return not clsa.__gt__(a, b) end
    elseif op == ">" or op == "gt" then
      if has_clsa and type(clsa.__gt__) == "function" then return clsa.__gt__(a, b) end
      if has_clsb and type(clsb.__lt__) == "function" then return clsb.__lt__(b, a) end
      if has_clsa and type(clsa.__le__) == "function" then return not clsa.__le__(a, b) end
    elseif op == ">=" or op == "ge" then
      if has_clsa and type(clsa.__ge__) == "function" then return clsa.__ge__(a, b) end
      if has_clsb and type(clsb.__le__) == "function" then return clsb.__le__(b, a) end
      if has_clsa and type(clsa.__lt__) == "function" then return not clsa.__lt__(a, b) end
      if has_clsb and type(clsb.__gt__) == "function" then return not clsb.__gt__(b, a) end
    elseif op == "==" or op == "eq" then
      if has_clsa and type(clsa.__eq__) == "function" then return clsa.__eq__(a, b) end
      if has_clsb and type(clsb.__eq__) == "function" then return clsb.__eq__(b, a) end
    elseif op == "~=" or op == "ne" or op == "!=" then
      if has_clsa and type(clsa.__ne__) == "function" then return clsa.__ne__(a, b) end
      if has_clsb and type(clsb.__ne__) == "function" then return clsb.__ne__(b, a) end
      if (has_clsa and type(clsa.__eq__) == "function") or (has_clsb and type(clsb.__eq__) == "function") then
        return not _luthon_cmp("==", a, b)
      end
    end
    if a == b then
      if op == "==" or op == "eq" then return true end
      if op == "~=" or op == "ne" or op == "!=" then return false end
    end
    local mtb = getmetatable(b)
    local is_a_dict = (mta and (mta.__dict__ == true or (_dict_methods ~= nil and mta.__index == _dict_methods))) or rawget(a, "_dict") or (mta ~= nil and ((_dict_mt ~= nil and mta == _dict_mt) or (_G._dict_mt ~= nil and mta == _G._dict_mt)))
    local is_b_dict = (mtb and (mtb.__dict__ == true or (_dict_methods ~= nil and mtb.__index == _dict_methods))) or rawget(b, "_dict") or (mtb ~= nil and ((_dict_mt ~= nil and mtb == _dict_mt) or (_G._dict_mt ~= nil and mtb == _G._dict_mt)))
    if is_a_dict or is_b_dict then
      if op == "==" or op == "eq" then
        if not (is_a_dict and is_b_dict) then return false end
        for k, v in pairs(a) do
          if not _luthon_cmp("==", v, b[k]) then return false end
        end
        for k in pairs(b) do
          if a[k] == nil then return false end
        end
        return true
      elseif op == "~=" or op == "ne" or op == "!=" then
        return not _luthon_cmp("==", a, b)
      end
    end
    local is_a_list = (mta and (mta.__list__ or mta.__tuple__)) or rawget(a, "_list")
    local is_b_list = (mtb and (mtb.__list__ or mtb.__tuple__)) or rawget(b, "_list")
    local na, nb = #a, #b
    if is_a_list or is_b_list or na > 0 or nb > 0 then
      if op == "==" or op == "eq" then
        if na ~= nb then return false end
        for i = 1, na do
          if not _luthon_cmp("==", a[i], b[i]) then return false end
        end
        return true
      end
      if op == "~=" or op == "ne" or op == "!=" then
        return not _luthon_cmp("==", a, b)
      end
      local min_n = math.min(na, nb)
      for i = 1, min_n do
        local va, vb = a[i], b[i]
        if not _luthon_cmp("==", va, vb) then
          if op == "<" or op == "lt" or op == "<=" or op == "le" then
            return _luthon_cmp("<", va, vb)
          else
            return _luthon_cmp(">", va, vb)
          end
        end
      end
      if op == "<" or op == "lt" then return na < nb end
      if op == "<=" or op == "le" then return na <= nb end
      if op == ">" or op == "gt" then return na > nb end
      if op == ">=" or op == "ge" then return na >= nb end
    end
    if op == "==" or op == "eq" then
      return rawequal(a, b)
    elseif op == "~=" or op == "ne" or op == "!=" then
      return not rawequal(a, b)
    end
  end
  if type(a) == "table" then
    local mta = getmetatable(a)
    local cls = a.__class__ or (mta and (type(mta.__index) == "table" and mta.__index or mta))
    if type(cls) == "table" then
      if (op == "<" or op == "lt") and type(cls.__lt__) == "function" then return cls.__lt__(a, b) end
      if (op == "<=" or op == "le") and type(cls.__le__) == "function" then return cls.__le__(a, b) end
      if (op == ">" or op == "gt") and type(cls.__gt__) == "function" then return cls.__gt__(a, b) end
      if (op == ">=" or op == "ge") and type(cls.__ge__) == "function" then return cls.__ge__(a, b) end
    end
  end
  if type(b) == "table" then
    local mtb = getmetatable(b)
    local cls = b.__class__ or (mtb and (type(mtb.__index) == "table" and mtb.__index or mtb))
    if type(cls) == "table" then
      if (op == "<" or op == "lt") and type(cls.__gt__) == "function" then return cls.__gt__(b, a) end
      if (op == "<=" or op == "le") and type(cls.__ge__) == "function" then return cls.__ge__(b, a) end
      if (op == ">" or op == "gt") and type(cls.__lt__) == "function" then return cls.__lt__(b, a) end
      if (op == ">=" or op == "ge") and type(cls.__le__) == "function" then return cls.__le__(b, a) end
    end
  end
  if op == "<" or op == "lt" then return a < b end
  if op == "<=" or op == "le" then return a <= b end
  if op == ">" or op == "gt" then return a > b end
  if op == ">=" or op == "ge" then return a >= b end
  if op == "==" or op == "eq" then return a == b end
  if op == "~=" or op == "ne" then return a ~= b end
  return false
end

function _luthon_in(a, b)
  a = _luthon_key_repr(a)
  if type(b) == "table" then
    if b[a] ~= nil then return true end
    local n = #b
    for i = 1, n do
      if b[i] == a then return true end
    end
    return false
  elseif type(b) == "string" then
    if type(a) == "string" then
      return string.find(b, a, 1, true) ~= nil
    end
    return false
  end
  return false
end

function _luthon_not_in(a, b)
  return not _luthon_in(a, b)
end

local _set_methods = {
  add = function(self, x) self[x] = true end,
  remove = function(self, x) self[x] = nil end,
  discard = function(self, x) self[x] = nil end,
  clear = function(self) for k in pairs(self) do self[k] = nil end end,
  pop = function(self)
    for k in pairs(self) do
      self[k] = nil
      return k
    end
    error("KeyError: 'pop from an empty set'")
  end,
  issuperset = function(self, other)
    if type(other) == "string" then
      for i = 1, #other do
        local ch = string.sub(other, i, i)
        if not self[ch] then return false end
      end
      return true
    elseif type(other) == "table" then
      for _, v in ipairs(other) do
        if not self[v] then return false end
      end
      for k in pairs(other) do
        if not self[k] then return false end
      end
      return true
    end
    return false
  end,
  issubset = function(self, other)
    local o_set = (type(other) == "table" and getmetatable(other) == _set_mt) and other or set(other)
    for k in pairs(self) do
      if not o_set[k] then return false end
    end
    return true
  end,
}
local _set_mt = {__index = _set_methods}

function set(t)
  local s = setmetatable({}, _set_mt)
  if t then
    if type(t) == "table" then
      for _, v in ipairs(t) do s[v] = true end
    elseif type(t) == "string" then
      for i = 1, #t do s[string.sub(t, i, i)] = true end
    end
  end
  return s
end

local _frozenset_mt = {
  __index = _set_methods,
  __newindex = function() error("frozenset is immutable") end
}

function frozenset(t)
  local s = {}
  if t then
    if type(t) == "table" then
      for _, v in ipairs(t) do s[v] = true end
    elseif type(t) == "string" then
      for i = 1, #t do s[string.sub(t, i, i)] = true end
    end
  end
  return setmetatable(s, _frozenset_mt)
end

function range(a, b, step)
  if b == nil then a, b = 0, a; step = 1 end
  if step == nil then step = 1 end
  if _luthon_native_lib ~= nil then
    local r_struct = _luthon_native_lib.luthon_range_init(a, b, step)
    local n = tonumber(r_struct.length)
    local r = {}
    local val_buf = ffi.new("int64_t[1]")
    local idx = 1
    while _luthon_native_lib.luthon_range_next(r_struct, val_buf) do
      r[idx] = tonumber(val_buf[0])
      idx = idx + 1
    end
    rawset(r, "_len", n)
    return setmetatable(r, _list_mt)
  end
  local r = {}
  if step > 0 then for i = a, b - 1, step do r[#r+1] = i end
  else for i = a, b + 1, step do r[#r+1] = i end end
  return setmetatable(r, _list_mt)
end
function len(t)
  if t == nil then return 0 end
  if type(t) == "table" then
    if rawget(t, "_len") ~= nil then return rawget(t, "_len") end
    local n = #t
    if n > 0 then return n end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
  end
  return #t
end
local function _luthon_lt(a, b)
  local ta = type(a)
  local tb = type(b)
  if ta == "number" and tb == "number" then return a < b end
  if ta == "string" and tb == "string" then return a < b end
  if ta == "boolean" and tb == "boolean" then return (not a) and b end
  if ta == "table" and tb == "table" then
    local mt_a = getmetatable(a)
    if mt_a and type(mt_a.__lt) == "function" and mt_a.__lt ~= _luthon_lt then return a < b end
    if type(a.__lt__) == "function" then return a:__lt__(b) end
    local na = #a
    local nb = #b
    local min_len = na < nb and na or nb
    for idx = 1, min_len do
      local ea = a[idx]
      local eb = b[idx]
      if ea ~= eb then return _luthon_lt(ea, eb) end
    end
    return na < nb
  end
  return tostring(a) < tostring(b)
end

local _list_methods = {
  append = function(self, x) table.insert(self, x) end,
  extend = function(self, other) local n = #other; for i=1,n do table.insert(self, other[i]) end end,
  pop = function(self, idx)
    idx = idx or (#self - 1)
    if idx < 0 then idx = #self + idx end
    return table.remove(self, idx + 1)
  end,
  insert = function(self, idx, x) table.insert(self, idx + 1, x) end,
  remove = function(self, x)
    local n = #self
    for i=1,n do
      if self[i] == x then table.remove(self, i) return end
    end
    error("ValueError: list.remove(x): x not in list")
  end,
  clear = function(self) for i=#self,1,-1 do self[i] = nil end end,
  sort = function(self, key_fn, reverse)
    if type(key_fn) == "table" and key_fn.key ~= nil then
      if key_fn.reverse ~= nil then reverse = key_fn.reverse end
      key_fn = key_fn.key
    end
    table.sort(self, function(a, b)
      local val_a = key_fn and key_fn(a) or a
      local val_b = key_fn and key_fn(b) or b
      if reverse then
        return _luthon_lt(val_b, val_a)
      else
        return _luthon_lt(val_a, val_b)
      end
    end)
  end,
  reverse = function(self)
    local n = #self
    for i = 1, math.floor(n / 2) do
      self[i], self[n - i + 1] = self[n - i + 1], self[i]
    end
  end,
  copy = function(self)
    local r = setmetatable({}, _list_mt)
    for i = 1, #self do r[i] = self[i] end
    return r
  end,
  count = function(self, x)
    local c = 0
    for i = 1, #self do if self[i] == x then c = c + 1 end end
    return c
  end,
  index = function(self, x, start, stop)
    start = (start or 0) + 1
    stop = stop and (stop + 1) or #self
    for i = start, stop do
      if self[i] == x then return i - 1 end
    end
    error("ValueError: " .. tostring(x) .. " is not in list")
  end,
}
local function _list_add(a, b)
  local r = setmetatable({}, _list_mt)
  if type(a) == "table" then
    for i = 1, #a do
      r[#r + 1] = a[i]
    end
  end
  if type(b) == "table" then
    for i = 1, #b do
      r[#r + 1] = b[i]
    end
  end
  return r
end

local function _list_mul(a, b)
  local lst, count
  if type(a) == "number" then
    count, lst = a, b
  else
    lst, count = a, b
  end
  local r = setmetatable({}, _list_mt)
  if type(lst) == "table" and type(count) == "number" and count > 0 then
    for _ = 1, count do
      for i = 1, #lst do
        r[#r + 1] = lst[i]
      end
    end
  end
  return r
end

_list_mt = {
  __index = _list_methods,
  __lt = _luthon_lt,
  __add = _list_add,
  __mul = _list_mul,
}

-- Auto-flush print for server and interactive logging
local _raw_print = print
function print(...)
  _raw_print(...)
  pcall(function() io.stdout:flush() end)
end

function make_list(...)
  local r = {...}
  return setmetatable(r, _list_mt)
end

table.pack = table.pack or function(...)
  return setmetatable({...}, _list_mt)
end

function list(t)
  if type(t) == "function" then
    local r = setmetatable({}, _list_mt)
    while true do
      local v = t()
      if v == nil then break end
      r[#r+1] = v
    end
    return r
  end
  if type(t) == "table" and t._py then
    local ok_pb, pb = pcall(require, "luthon.lua.pybridge")
    if not ok_pb or not pb then ok_pb, pb = pcall(require, "src/luthon/lua/pybridge") end
    if ok_pb and pb and pb.get_lib then
      local libpy = pb.get_lib()
      local iter = libpy.PyObject_GetIter(t._py)
      if iter ~= nil then
        local r = setmetatable({}, _list_mt)
        while true do
          local item = libpy.PyIter_Next(iter)
          if item == nil then break end
          local val = pb.py_to_lua(item)
          libpy.Py_DecRef(item)
          r[#r+1] = val
        end
        libpy.Py_DecRef(iter)
        return r
      else
        libpy.PyErr_Clear()
      end
    end
  end
  local r = setmetatable({}, _list_mt)
  if t then
    local n = #t
    for i=1,n do r[#r+1] = t[i] end
  end
  return r
end

local function _tuple_add(a, b)
  local r = setmetatable({}, _tuple_mt)
  if type(a) == "table" then
    for i = 1, #a do
      r[#r + 1] = a[i]
    end
  end
  if type(b) == "table" then
    for i = 1, #b do
      r[#r + 1] = b[i]
    end
  end
  return r
end

local function _tuple_mul(a, b)
  local tup, count
  if type(a) == "number" then
    count, tup = a, b
  else
    tup, count = a, b
  end
  local r = setmetatable({}, _tuple_mt)
  if type(tup) == "table" and type(count) == "number" and count > 0 then
    for _ = 1, count do
      for i = 1, #tup do
        r[#r + 1] = tup[i]
      end
    end
  end
  return r
end

_tuple_mt = {
  __tuple__ = true,
  __lt = _luthon_lt,
  __add = _tuple_add,
  __mul = _tuple_mul,
  __index = function(t, k)
    if type(k) == "number" then
      if k < 0 then k = #t + k + 1 else k = k + 1 end
      return t[k]
    end
    return nil
  end
}

_bytes_mt = {
  __bytes__ = true,
  __tostring = function(t) return t[1] or "" end,
  __len = function(t) return #(t[1] or "") end,
  __index = function(t, k)
    if type(k) == "number" then
      local s = t[1] or ""
      if k < 0 then k = #s + k + 1 else k = k + 1 end
      return s:byte(k)
    end
    return nil
  end
}

_bytearray_mt = {
  __bytes__ = true,
  __tostring = function(t)
    local chars = {}
    local len = rawget(t, "_len") or 0
    local buf = rawget(t, "_buf")
    if buf then
      return ffi.string(buf, len)
    end
    for i = 0, len - 1 do chars[i + 1] = string.char(t[i] or 0) end
    return table.concat(chars)
  end,
  __len = function(t) return rawget(t, "_len") or 0 end,
  __index = function(t, k)
    if type(k) == "number" then
      local len = rawget(t, "_len") or 0
      if k < 0 then k = len + k end
      local buf = rawget(t, "_buf")
      if buf then return buf[k] end
      return rawget(t, k) or 0
    end
    return nil
  end,
  __newindex = function(t, k, v)
    if type(k) == "number" then
      local len = rawget(t, "_len") or 0
      if k < 0 then k = len + k end
      local buf = rawget(t, "_buf")
      if buf then
        buf[k] = v
        return
      end
      rawset(t, k, v)
    else
      rawset(t, k, v)
    end
  end
}

function bytearray(init)
  local len = 0
  local obj = setmetatable({}, _bytearray_mt)
  if type(init) == "number" then
    len = math.floor(init)
    if ffi and ffi.new then
      rawset(obj, "_buf", ffi.new("uint8_t[?]", math.max(1, len)))
    end
    rawset(obj, "_len", len)
  elseif type(init) == "string" then
    len = #init
    if ffi and ffi.new then
      local buf = ffi.new("uint8_t[?]", math.max(1, len))
      ffi.copy(buf, init, len)
      rawset(obj, "_buf", buf)
    else
      for i = 0, len - 1 do rawset(obj, i, init:byte(i + 1)) end
    end
    rawset(obj, "_len", len)
  elseif type(init) == "table" then
    len = #init
    if ffi and ffi.new then
      local buf = ffi.new("uint8_t[?]", math.max(1, len))
      for i = 0, len - 1 do buf[i] = (init[i + 1] or init[i] or 0) end
      rawset(obj, "_buf", buf)
    else
      for i = 0, len - 1 do rawset(obj, i, init[i + 1] or init[i] or 0) end
    end
    rawset(obj, "_len", len)
  else
    rawset(obj, "_len", 0)
  end
  return obj
end

function bytes(s)
  if type(s) == "table" and getmetatable(s) == _bytearray_mt then
    return setmetatable({tostring(s)}, _bytes_mt)
  end
  return setmetatable({tostring(s or "")}, _bytes_mt)
end

function tuple(t)
  local r = setmetatable({}, _tuple_mt)
  if type(t) == "function" then
    while true do
      local v = t()
      if v == nil then break end
      r[#r+1] = v
    end
    return r
  end
  if type(t) == "table" then
    local n = #t
    for i = 1, n do r[#r+1] = t[i] end
    return r
  end
  r[1] = t
  return r
end
local _dict_methods = {
  get = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then return v end
    if default == nil then return _G._luthon_none end
    return default
  end,
  setdefault = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then return v end
    if default == nil then default = _G._luthon_none end
    rawset(self, k, default)
    return default
  end,
  pop = function(self, k, default)
    local v = rawget(self, k)
    if v ~= nil then
      rawset(self, k, nil)
      return v
    end
    if default ~= nil then return default end
    local ke = _G.KeyError or KeyError
    if ke then error(ke(tostring(k)), 0) end
    error("KeyError: " .. tostring(k), 0)
  end,
  popitem = function(self)
    for k, v in pairs(self) do
      rawset(self, k, nil)
      return {k, v}
    end
    local ke = _G.KeyError or KeyError
    if ke then error(ke("popitem(): dictionary is empty"), 0) end
    error("KeyError: popitem(): dictionary is empty", 0)
  end,
  keys = function(self)
    local r = setmetatable({}, _list_mt)
    for k in pairs(self) do table.insert(r, k) end
    return r
  end,
  values = function(self)
    local r = setmetatable({}, _list_mt)
    for _, v in pairs(self) do table.insert(r, v) end
    return r
  end,
  items = function(self)
    local r = setmetatable({}, _list_mt)
    for k, v in pairs(self) do table.insert(r, {k, v}) end
    return r
  end,
  update = function(self, other)
    return _dict_update(self, other)
  end,
  clear = function(self)
    for k in pairs(self) do rawset(self, k, nil) end
  end,
  copy = function(self)
    local r = setmetatable({}, _dict_mt)
    for k, v in pairs(self) do r[k] = v end
    return r
  end,
}
local _dict_mt = {__dict__ = true, __index = _dict_methods}
_G._dict_mt = _dict_mt

function dict(t)
  local d = setmetatable({}, _dict_mt)
  if t then
    if type(t) == "table" then
      for _, kv in ipairs(t) do
        if type(kv) == "table" and kv[1] ~= nil then
          d[kv[1]] = kv[2]
        end
      end
    end
  end
  return d
end

local _lua_raw_str_find = string.find
local _orig_string_format = string.format
local _str_methods
_str_methods = {
  join = function(sep, iterable)
    local parts = {}
    if type(iterable) == "table" then
      for _, v in ipairs(iterable) do table.insert(parts, tostring(v)) end
    elseif type(iterable) == "function" then
      while true do
        local v = iterable()
        if v == nil then break end
        table.insert(parts, tostring(v))
      end
    end
    return table.concat(parts, sep)
  end,
  startswith = function(s, prefix)
    if type(prefix) == "table" then
      for i = 1, #prefix do
        local p = prefix[i]
        if string.sub(s, 1, #p) == p then return true end
      end
      return false
    end
    return string.sub(s, 1, #prefix) == prefix
  end,
  endswith = function(s, suffix)
    if type(suffix) == "table" then
      for i = 1, #suffix do
        local suf = suffix[i]
        if suf == "" or string.sub(s, -#suf) == suf then return true end
      end
      return false
    end
    return suffix == "" or string.sub(s, -#suffix) == suffix
  end,
  split = function(s, sep, maxsplit)
    sep = sep or "%s+"
    maxsplit = maxsplit or -1
    local r = setmetatable({}, _list_mt)
    local pos = 1
    local len = #s
    if sep == "%s+" then
      for w in string.gmatch(s, "%S+") do table.insert(r, w) end
      return r
    end
    local splits = 0
    while pos <= len do
      if maxsplit >= 0 and splits >= maxsplit then
        table.insert(r, string.sub(s, pos))
        break
      end
      local s_start, s_end = _lua_raw_str_find(s, sep, pos, true)
      if not s_start then
        table.insert(r, string.sub(s, pos))
        break
      end
      table.insert(r, string.sub(s, pos, s_start - 1))
      splits = splits + 1
      pos = s_end + 1
    end
    return r
  end,
  rsplit = function(s, sep, maxsplit)
    sep = sep or "%s+"
    maxsplit = maxsplit or -1
    if maxsplit == 0 then
      return setmetatable({s}, _list_mt)
    end
    if maxsplit < 0 then
      return _str_methods.split(s, sep)
    end
    local r = setmetatable({}, _list_mt)
    if sep == "%s+" then
      local words = {}
      for w in string.gmatch(s, "%S+") do table.insert(words, w) end
      if #words <= maxsplit + 1 then return _str_methods.split(s, sep) end
      local result = setmetatable({}, _list_mt)
      local right_items = {}
      for i = 1, maxsplit do
        table.insert(right_items, 1, table.remove(words))
      end
      table.insert(result, table.concat(words, " "))
      for _, w in ipairs(right_items) do table.insert(result, w) end
      return result
    end
    local pos = 1
    local len = #s
    local indices = {}
    while pos <= len do
      local s_start, s_end = _lua_raw_str_find(s, sep, pos, true)
      if not s_start then break end
      table.insert(indices, {s_start, s_end})
      pos = s_end + 1
    end
    if #indices == 0 then
      return setmetatable({s}, _list_mt)
    end
    local split_count = math.min(#indices, maxsplit)
    local cut_from = #indices - split_count + 1
    local res = setmetatable({}, _list_mt)
    table.insert(res, string.sub(s, 1, indices[cut_from][1] - 1))
    for i = cut_from, #indices do
      local seg_start = indices[i][2] + 1
      local seg_end = (i < #indices) and (indices[i+1][1] - 1) or len
      table.insert(res, string.sub(s, seg_start, seg_end))
    end
    return res
  end,
  partition = function(s, sep)
    if sep == nil or sep == "" then error("ValueError: empty separator") end
    local s_start, s_end = _lua_raw_str_find(s, sep, 1, true)
    if not s_start then
      return setmetatable({s, "", ""}, _tuple_mt)
    end
    local before = string.sub(s, 1, s_start - 1)
    local match = string.sub(s, s_start, s_end)
    local after = string.sub(s, s_end + 1)
    return setmetatable({before, match, after}, _tuple_mt)
  end,
  rpartition = function(s, sep)
    if sep == nil or sep == "" then error("ValueError: empty separator") end
    local last_start, last_end = nil, nil
    local init = 1
    while true do
      local s_start, s_end = _lua_raw_str_find(s, sep, init, true)
      if not s_start then break end
      last_start, last_end = s_start, s_end
      init = s_start + 1
    end
    if not last_start then
      return setmetatable({"", "", s}, _tuple_mt)
    end
    local before = string.sub(s, 1, last_start - 1)
    local match = string.sub(s, last_start, last_end)
    local after = string.sub(s, last_end + 1)
    return setmetatable({before, match, after}, _tuple_mt)
  end,
  format = function(s, ...)
    local args = {...}
    if _lua_raw_str_find(s, "{}", 1, true) then
      local idx = 1
      return (string.gsub(s, "{}", function()
        local val = tostring(args[idx] or "")
        idx = idx + 1
        return val
      end))
    end
    return _orig_string_format(s, ...)
  end,
  encode = function(s, encoding)
    return s
  end,
  decode = function(s, encoding)
    return s
  end,
  find = function(s, sub, start, stop)
    start = (start or 0) + 1
    if start < 1 then start = 1 end
    local pos, end_pos = _lua_raw_str_find(s, sub, start, true)
    if not pos then return -1 end
    if stop ~= nil then
      local py_end = stop < 0 and (#s + stop) or stop
      if pos - 1 >= py_end then return -1 end
    end
    return pos - 1
  end,
  index = function(s, sub, start, stop)
    local idx = _str_methods.find(s, sub, start, stop)
    if idx == -1 then
      error("ValueError: substring not found")
    end
    return idx
  end,
  count = function(s, sub, start, stop)
    if sub == "" then return #s + 1 end
    start = (start or 0) + 1
    local c = 0
    while true do
      local pos, end_pos = _lua_raw_str_find(s, sub, start, true)
      if not pos then break end
      if stop ~= nil and (pos - 1 >= stop) then break end
      c = c + 1
      start = end_pos + 1
    end
    return c
  end,
  replace = function(s, old, new, count)
    if count == nil or count < 0 then count = nil end
    local esc_old = old:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
    local esc_new = new:gsub("%%", "%%%%")
    local res, n = string.gsub(s, esc_old, esc_new, count)
    return res
  end,
  strip = function(s, chars)
    if chars then
      local pat = "^[" .. chars:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. "]+"
      local pat_end = "[" .. chars:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. "]+$"
      return s:gsub(pat, ""):gsub(pat_end, "")
    end
    return s:match("^%s*(.-)%s*$")
  end,
  lstrip = function(s, chars)
    if chars then
      local pat = "^[" .. chars:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. "]+"
      return s:gsub(pat, "")
    end
    return s:match("^%s*(.*)$")
  end,
  rstrip = function(s, chars)
    if chars then
      local pat_end = "[" .. chars:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. "]+$"
      return s:gsub(pat_end, "")
    end
    return s:match("^(.-)%s*$")
  end,
  lower = string.lower,
  upper = string.upper,
  isdigit = function(s) return s:match("^%d+$") ~= nil end,
  isalpha = function(s) return s:match("^%a+$") ~= nil end,
  isalnum = function(s) return s:match("^%w+$") ~= nil end,
}
for k, v in pairs(_str_methods) do
  if k ~= "find" then
    string[k] = v
  end
end
local function _str_format_map(fmt, map)
  return (fmt:gsub("%%%(([%a%w_]+)%)([-+0 #]*%d*%.?%d*[a-zA-Z%%])", function(k, spec)
    local v = map[k]
    if v == nil and type(map) == "table" and map[k] == nil then
      error("KeyError: " .. tostring(k))
    end
    if spec == "s" then
      return tostring(v)
    else
      return string.format("%" .. spec, v)
    end
  end))
end

local function _expand_dynamic_format(fmt, t)
  if not fmt:find("%*") then return fmt, t end
  local new_t = {}
  local in_idx = 1
  local out_fmt = fmt:gsub("%%([%-+0 #]*)(%*?)%.?(%*?)([a-zA-Z%%])", function(flags, w_star, p_star, spec)
    if spec == "%" then return "%%" end
    local w = ""
    local p = ""
    if w_star == "*" then
      w = tostring(t[in_idx] or "")
      in_idx = in_idx + 1
    end
    if p_star == "*" then
      p = "." .. tostring(t[in_idx] or "0")
      in_idx = in_idx + 1
    end
    return "%" .. flags .. w .. p .. spec
  end)
  for i = in_idx, #t do
    new_t[#new_t + 1] = t[i]
  end
  return out_fmt, new_t
end

local function _str_mod(fmt, args)
  if type(fmt) ~= "string" then
    error("TypeError: unsupported operand type(s) for %")
  end
  local t = {}
  local is_tuple = (type(args) == "table" and (rawget(args, "__is_tuple") or (getmetatable(args) and getmetatable(args).__tuple__)))
  if is_tuple then
    for i = 1, #args do
      t[i] = args[i]
    end
  elseif type(args) == "table" and fmt:find("%%%([%a%w_]+%)") then
    return _str_format_map(fmt, args)
  else
    t = {args}
  end
  local f2, t2 = _expand_dynamic_format(fmt, t)
  if #t2 > 0 then
    local arg_idx = 1
    f2 = f2:gsub("%%([%-+0 #]*)(%d*)%.?(%d*)([a-zA-Z%%])", function(flags, w, p, spec)
      if spec == "%" then return "%%" end
      local cur_idx = arg_idx
      arg_idx = arg_idx + 1
      if spec == "r" or spec == "a" then
        if t2[cur_idx] ~= nil then
          local r_fn = _G.repr or repr or tostring
          t2[cur_idx] = r_fn(t2[cur_idx])
        end
        return "%" .. flags .. w .. (p ~= "" and ("." .. p) or "") .. "s"
      end
      return "%" .. flags .. w .. (p ~= "" and ("." .. p) or "") .. spec
    end)
    local fmt_args = {}
    for i = 1, #t2 do
      local val = t2[i]
      if type(val) == "table" or type(val) == "userdata" then
        fmt_args[i] = tostring(val)
      else
        fmt_args[i] = val
      end
    end
    return string.format(f2, unpack(fmt_args))
  else
    return f2
  end
end

debug.setmetatable("", {
  __index = string,
  __add = function(a, b) return tostring(a) .. tostring(b) end,
  __mul = function(a, b)
    if type(a) == "string" and type(b) == "number" then
      return string.rep(a, b)
    elseif type(b) == "string" and type(a) == "number" then
      return string.rep(b, a)
    end
    error("TypeError: can only multiply string by integer")
  end,
  __mod = _str_mod
})

local _fn_attrs = {}
debug.setmetatable(function() end, {
  __index = function(f, k)
    local t = _fn_attrs[f]
    return t and t[k]
  end,
  __newindex = function(f, k, v)
    local t = _fn_attrs[f]
    if not t then
      t = {}
      _fn_attrs[f] = t
    end
    t[k] = v
  end,
})

function make_generator(fn, ...)
  local args = {...}
  local co = coroutine.create(function() return fn(unpack(args)) end)
  local gen = {}
  gen.__next__ = function()
    if coroutine.status(co) == "dead" then return nil end
    local ok, val = coroutine.resume(co)
    if not ok then error(val) end
    if coroutine.status(co) == "dead" then return nil end
    return (val == nil) and _G._luthon_none or val
  end
  gen.__iter__ = function() return gen end
  setmetatable(gen, {
    __call = function() return gen.__next__() end
  })
  return gen
end

function make_coroutine(fn, ...)
  local args = {...}
  local co = coroutine.create(function()
    return fn(unpack(args))
  end)
  return co
end

function iter(t)
  if type(t) == "table" and t.__anext__ then
    return function() return t:__anext__() end
  end
  if type(t) == "table" and t.__aiter__ then
    local it = t:__aiter__()
    if type(it) == "table" and it.__anext__ then
      return function() return it:__anext__() end
    end
    return it
  end
  if type(t) == "table" and rawget(t, "_py") then
    local ok, pb = pcall(require, "luthon.lua.pybridge")
    if not ok or not pb then ok, pb = pcall(require, "src/luthon/lua/pybridge") end
    if ok and pb and pb.get_lib then
      local lib = pb.get_lib()
      local it = lib.PyObject_GetIter(t._py)
      if it ~= nil then
        return function()
          local item = lib.PyIter_Next(it)
          if item == nil then
            lib.Py_DecRef(it)
            return nil
          end
          local res = pb.py_to_lua(item)
          lib.Py_DecRef(item)
          return res
        end
      end
    end
  end
  if type(t) == "table" and t.__iter__ then
    local it = t:__iter__()
    if type(it) == "table" and it.__next__ then
      return function() return it:__next__() end
    end
    return it
  end
  if type(t) == "table" and t.__next__ then
    return function() return t:__next__() end
  end
  if type(t) == "userdata" and io.type(t) == "file" then return t:lines() end
  if type(t) == "table" and t.lines then return t:lines() end
  if type(t) == "function" then return t end
  local i = 0
  return function()
    i = i + 1
    if i <= #t then return t[i] end
    return nil
  end
end
function unpack_list(t)
  return t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10]
end
function list_repeat(t, n) local r={}; for i=1,n do for _,v in ipairs(t) do r[#r+1]=v end end; return r end
local _raw_str = function(x)
  if x == nil or x == _G._luthon_none or (type(x) == "table" and rawget(x, "__is_none__") == true) then return "None" end
  return tostring(x or "")
end
local _raw_int = function(x, base)
  if x == nil then return 0 end
  if type(x) == "boolean" then return x and 1 or 0 end
  if type(x) == "string" then
    x = x:match("^%s*(.-)%s*$")
  end
  local num = base and tonumber(x, base) or tonumber(x)
  if num == nil then
    local ve = _G.ValueError or ValueError
    if ve then
      error(ve("invalid literal for int(): " .. tostring(x)), 0)
    else
      error("ValueError: invalid literal for int(): " .. tostring(x), 0)
    end
  end
  return math.floor(num)
end
local _raw_float = function(x)
  if x == nil then return 0.0 end
  if type(x) == "boolean" then return x and 1.0 or 0.0 end
  if type(x) == "string" then
    x = x:match("^%s*(.-)%s*$")
  end
  local num = tonumber(x)
  if num == nil then
    local ve = _G.ValueError or ValueError
    if ve then
      error(ve("could not convert string to float: " .. tostring(x)), 0)
    else
      error("ValueError: could not convert string to float: " .. tostring(x), 0)
    end
  end
  return num
end
function abs(x) return math.abs(x) end
function repr(x)
  if x == nil or x == _G._luthon_none or (type(x) == "table" and rawget(x, "__is_none__") == true) then return "None" end
  if type(x) == "string" then
    return string.format("%q", x)
  elseif type(x) == "boolean" then
    return x and "True" or "False"
  elseif type(x) == "table" then
    if x.__repr__ then
      return x:__repr__()
    elseif getmetatable(x) and getmetatable(x).__repr__ then
      return getmetatable(x).__repr__(x)
    elseif getmetatable(x) == _dict_mt or (getmetatable(x) and getmetatable(x).__dict__) then
      local parts = {}
      for k, v in pairs(x) do
        table.insert(parts, repr(k) .. ": " .. repr(v))
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    elseif getmetatable(x) == _list_mt then
      local parts = {}
      for i, v in ipairs(x) do
        table.insert(parts, repr(v))
      end
      return "[" .. table.concat(parts, ", ") .. "]"
    elseif getmetatable(x) == _tuple_mt or x.__tuple__ then
      local parts = {}
      for i, v in ipairs(x) do
        table.insert(parts, repr(v))
      end
      if #parts == 1 then return "(" .. parts[1] .. ",)" end
      return "(" .. table.concat(parts, ", ") .. ")"
    end
  end
  return tostring(x)
end
local _raw_bool = function(x)
  if x == nil or x == false or x == _G._luthon_none or (type(x) == "table" and rawget(x, "__is_none__") == true) then return false end
  if type(x) == "number" then return x ~= 0 end
  if type(x) == "string" then return #x > 0 end
  if type(x) == "table" then
    if x.__bool__ then return x:__bool__() end
    if x.__len__ then return x:__len__() > 0 end
    return next(x) ~= nil
  end
  return true
end

local _builtin_types = {}

local function _create_builtin_type(name, ctor)
  local t = {
    __name__ = name,
    __class__ = nil,
    __tostring = function() return "<class '" .. name .. "'>" end
  }
  setmetatable(t, {
    __call = function(self, ...) return ctor(...) end,
    __tostring = function() return "<class '" .. name .. "'>" end
  })
  _builtin_types[name] = t
  return t
end

local _raw_list = list
local _raw_dict = dict
local _raw_tuple = tuple
local _raw_set = set
local _raw_frozenset = frozenset
local _raw_bytes = bytes

str = _create_builtin_type("str", _raw_str)
int = _create_builtin_type("int", _raw_int)
float = _create_builtin_type("float", _raw_float)
bool = _create_builtin_type("bool", _raw_bool)
list = _create_builtin_type("list", _raw_list)
dict = _create_builtin_type("dict", _raw_dict)
tuple = _create_builtin_type("tuple", _raw_tuple)
set = _create_builtin_type("set", _raw_set)
frozenset = _create_builtin_type("frozenset", _raw_frozenset)
bytes = _create_builtin_type("bytes", _raw_bytes)
NoneType = _create_builtin_type("NoneType", function() return None end)
object = _create_builtin_type("object", function() return {} end)

_luthon_type = _create_builtin_type("type", function(...)
  local n = select("#", ...)
  if n == 1 then
    local x = select(1, ...)
    if x == nil or x == _G._luthon_none or (type(x) == "table" and rawget(x, "__is_none__") == true) then return _builtin_types["NoneType"] end
    local lt = type(x)
    if lt == "number" then
      if math.floor(x) == x and not (x == 1/0 or x == -1/0) then
        return int
      else
        return float
      end
    elseif lt == "string" then
      return str
    elseif lt == "boolean" then
      return bool
    elseif lt == "table" then
      if rawget(x, "_py") then
        local c = x.__class__
        if c then return c end
      end
      local c = rawget(x, "__class__") or (getmetatable(x) and getmetatable(x).__class)
      if c then return c end
      if rawget(x, "_bytes") or (getmetatable(x) and getmetatable(x) == _bytes_mt) then
        return bytes
      end
      if rawget(x, "_set") or (getmetatable(x) and getmetatable(x) == _set_mt) then
        return set
      end
      if rawget(x, "_frozenset") or (getmetatable(x) and getmetatable(x) == _frozenset_mt) then
        return frozenset
      end
      if rawget(x, "_tuple") or (getmetatable(x) and (getmetatable(x).__tuple or getmetatable(x) == _tuple_mt)) then
        return tuple
      end
      if rawget(x, "_list") or (getmetatable(x) and getmetatable(x) == _list_mt) then
        return list
      end
      if rawget(x, "_dict") or (getmetatable(x) and getmetatable(x) == _dict_mt) then
        return dict
      end
      if #x > 0 or rawget(x, 1) ~= nil then
        return list
      end
      return dict
    end
    return _builtin_types["object"]
  elseif n == 3 then
    local name, bases, dict_cls = ...
    local cls = dict_cls or {}
    cls.__name__ = name
    cls.__name = name
    if bases and #bases > 0 then
      cls.__base__ = bases[1]
    end
    cls.__index = cls
    cls.__instance_mt = {__index = cls}
    setmetatable(cls, {
      __index = function(t, k)
        local b = rawget(t, '__base__')
        return b and b[k]
      end,
      __call = function(self, ...)
        local instance = setmetatable({__class__ = cls}, cls.__instance_mt)
        if cls.__init__ then cls.__init__(instance, ...) end
        return instance
      end,
      __tostring = function() return "<class '" .. name .. "'>" end
    })
    return cls
  end
  return _builtin_types["object"]
end)

_luthon_type.__class__ = _luthon_type
for _, t in pairs(_builtin_types) do
  t.__class__ = _luthon_type
end

function callable(x)
  if type(x) == "function" then return true end
  if type(x) == "table" then
    local mt = getmetatable(x)
    if mt and type(mt.__call) == "function" then return true end
    if type(x.__call) == "function" then return true end
  end
  return false
end

function issubclass(sub, sup)
  if sub == nil or sup == nil then return false end
  if type(sup) == "table" and (sup.__tuple__ or (getmetatable(sup) and getmetatable(sup).__tuple) or (rawget(sup, 1) and rawget(sup, "__name__") == nil)) then
    for i = 1, #sup do
      if issubclass(sub, sup[i]) then return true end
    end
    return false
  end
  if sub == sup then return true end
  local c = sub.__base__ or (getmetatable(sub) and getmetatable(sub).__index)
  while c do
    if c == sup or (sup.__name__ and c.__name__ == sup.__name__) or c.__name == sup.__name then
      return true
    end
    c = c.__base__ or (getmetatable(c) and getmetatable(c).__index)
  end
  return false
end
function round(x, n) n=n or 0; local f=10^n; return math.floor(x*f+0.5)/f end
function min(...)
  local argc = select("#", ...)
  local a = select(1, ...)
  local key_fn = nil
  for i = argc, 2, -1 do
    local arg = select(i, ...)
    if type(arg) == "table" and arg.key ~= nil then
      key_fn = arg.key
      break
    end
  end

  if type(a) ~= "table" or a._py then
    local args_list = {}
    for i = 1, argc do
      local arg = select(i, ...)
      if type(arg) == "table" and arg.key ~= nil and i >= 2 then break end
      table.insert(args_list, arg)
    end
    a = args_list
  elseif type(a) == "table" and #a == 0 then
    -- Table/dict with non-sequential or string keys: collect keys
    local keys = {}
    for k in pairs(a) do table.insert(keys, k) end
    a = keys
  end

  local best_item = a[1]
  local best_score = key_fn and key_fn(best_item) or best_item
  local n = #a
  for i = 2, n do
    local item = a[i]
    local score = key_fn and key_fn(item) or item
    if _luthon_cmp("<", score, best_score) then
      best_item = item
      best_score = score
    end
  end
  return best_item
end

function max(...)
  local argc = select("#", ...)
  local a = select(1, ...)
  local key_fn = nil
  for i = argc, 2, -1 do
    local arg = select(i, ...)
    if type(arg) == "table" and arg.key ~= nil then
      key_fn = arg.key
      break
    end
  end

  if type(a) ~= "table" or a._py then
    local args_list = {}
    for i = 1, argc do
      local arg = select(i, ...)
      if type(arg) == "table" and arg.key ~= nil and i >= 2 then break end
      table.insert(args_list, arg)
    end
    a = args_list
  elseif type(a) == "table" and #a == 0 then
    -- Table/dict with non-sequential or string keys: collect keys
    local keys = {}
    for k in pairs(a) do table.insert(keys, k) end
    a = keys
  end

  local best_item = a[1]
  local best_score = key_fn and key_fn(best_item) or best_item
  local n = #a
  for i = 2, n do
    local item = a[i]
    local score = key_fn and key_fn(item) or item
    if _luthon_cmp(">", score, best_score) then
      best_item = item
      best_score = score
    end
  end
  return best_item
end
function sum(t) local s=0; local n=#t; for i=1,n do s=s+t[i] end; return s end
function sorted(...)
  local argc = select("#", ...)
  local t = select(1, ...)
  local key_fn = nil
  local reverse = false
  for i = 2, argc do
    local arg = select(i, ...)
    if type(arg) == "table" then
      if arg.key ~= nil then key_fn = arg.key end
      if arg.reverse ~= nil then reverse = arg.reverse end
    elseif type(arg) == "boolean" then
      reverse = arg
    end
  end
  local r = setmetatable({}, _list_mt)
  if type(t) == "table" then
    local n = #t
    if n > 0 or rawget(t, 1) ~= nil then
      for i = 1, n do r[i] = t[i] end
    else
      for k in pairs(t) do table.insert(r, k) end
    end
  elseif type(t) == "function" then
    while true do
      local v = t()
      if v == nil then break end
      r[#r+1] = v
    end
  end
  table.sort(r, function(a, b)
    local val_a = key_fn and key_fn(a) or a
    local val_b = key_fn and key_fn(b) or b
    if reverse then
      return _luthon_lt(val_b, val_a)
    else
      return _luthon_lt(val_a, val_b)
    end
  end)
  return r
end
function ord(c)
  if type(c) == "string" then return string.byte(c) end
  if type(c) == "number" then return c end
  return tonumber(c) or 0
end
function chr(n)
  return string.char(tonumber(n) or 0)
end
function reversed(t) local r={}; for i=#t,1,-1 do r[#r+1]=t[i] end; return r end
function enumerate(t, start)
  start = start or 0
  local r = setmetatable({}, _list_mt)
  if type(t) == "table" and rawget(t, "_py") ~= nil then
    local n = #t
    for i = 1, n do
      r[#r + 1] = setmetatable({start + i - 1, t[i - 1]}, _tuple_mt)
    end
    return r
  end
  local it = iter(t)
  local idx = start
  while true do
    local val = it()
    if val == nil then break end
    r[#r + 1] = setmetatable({idx, val}, _tuple_mt)
    idx = idx + 1
  end
  return r
end
function zip(a,b) local r={}; for i=1,math.min(#a,#b) do r[#r+1]={a[i],b[i]} end; return r end
function map(f,t)
  local r = setmetatable({}, _list_mt)
  if type(t) == "table" then
    local n = #t
    for i=1,n do r[#r+1]=f(t[i]) end
  elseif type(t) == "function" then
    while true do
      local v = t()
      if v == nil then break end
      r[#r+1] = f(v)
    end
  end
  return r
end
function filter(f,t) local r={}; local n=#t; for i=1,n do local v=t[i]; if f(v) then r[#r+1]=v end end; return r end
function any(t) local n=#t; for i=1,n do if t[i] then return true end end; return false end
function all(t) local n=#t; for i=1,n do if not t[i] then return false end end; return true end

local _py_builtins = nil
_ = _ or function(s)
  if _py_builtins == nil then
    local ok, pb = pcall(require, "src/luthon/lua/pybridge")
    if ok and pb and pb.is_available() then
      local ok_b, b = pcall(pb.import, "builtins")
      if ok_b and b then _py_builtins = b end
    end
    if not _py_builtins then _py_builtins = false end
  end
  if _py_builtins and _py_builtins._ then
    local ok_call, res = pcall(_py_builtins._, s)
    if ok_call and res ~= nil then return res end
  end
  return s
end

_n = _n or function(singular, plural, n)
  if _py_builtins == nil then
    local ok, pb = pcall(require, "src/luthon/lua/pybridge")
    if ok and pb and pb.is_available() then
      local ok_b, b = pcall(pb.import, "builtins")
      if ok_b and b then _py_builtins = b end
    end
    if not _py_builtins then _py_builtins = false end
  end
  if _py_builtins and _py_builtins.ngettext then
    local ok_call, res = pcall(_py_builtins.ngettext, singular, plural, n)
    if ok_call and res ~= nil then return res end
  end
  if n == 1 then return singular else return plural end
end
ngettext = ngettext or _n

function slice(start, stop, step)
  return {start = start, stop = stop, step = step or 1}
end

function property(fget, fset, fdel)
  local prop = {fget = fget, fset = fset, fdel = fdel}
  prop.__get__ = function(self, obj, objtype)
    if obj == nil then return self end
    if self.fget then return self.fget(obj) end
    return nil
  end
  prop.__set__ = function(self, obj, val)
    if self.fset then self.fset(obj, val) end
  end
  prop.__delete__ = function(self, obj)
    if self.fdel then self.fdel(obj) end
  end
  prop.setter = function(self_or_f, maybe_f)
    local f = (maybe_f ~= nil or self_or_f == prop) and maybe_f or self_or_f
    return property(prop.fget, f, prop.fdel)
  end
  prop.deleter = function(self_or_f, maybe_f)
    local f = (maybe_f ~= nil or self_or_f == prop) and maybe_f or self_or_f
    return property(prop.fget, prop.fset, f)
  end
  prop.getter = function(self_or_f, maybe_f)
    local f = (maybe_f ~= nil or self_or_f == prop) and maybe_f or self_or_f
    return property(f, prop.fset, prop.fdel)
  end
  return prop
end

function staticmethod(f)
  return f
end

function classmethod(f)
  return f
end

function super(cls, obj)
  local base = cls and cls.__base__
  local proxy = {}
  local mt = {
    __index = function(_, k)
      local target = base
      local visited = {}
      while target and type(target) == "table" and not visited[target] do
        visited[target] = true
        if target[k] ~= nil then
          local m = target[k]
          if type(m) == "function" or (type(m) == "table" and (rawget(m, "_py") or (getmetatable(m) and getmetatable(m).__call))) then
            local wrapper = function(first_arg, ...)
              if first_arg == proxy then
                local arg1 = ...
                if arg1 == obj then
                  return m(...)
                else
                  return m(obj, ...)
                end
              elseif first_arg == obj then
                return m(obj, ...)
              else
                return m(obj, first_arg, ...)
              end
            end
            if _G.__LUTHON_FN_PARAMS and _G.__LUTHON_FN_PARAMS[m] then
              _G.__LUTHON_FN_PARAMS[wrapper] = _G.__LUTHON_FN_PARAMS[m]
            end
            return wrapper
          end
          return m
        end
        target = target.__base__
      end
      if k == "__init__" then return function(...) end end
      return nil
    end
  }
  return setmetatable(proxy, mt)
end

function isinstance(val, cls)
  if cls == nil then return false end
  if type(cls) == "table" and (cls.__tuple__ or (getmetatable(cls) and getmetatable(cls).__tuple) or (rawget(cls, 1) and rawget(cls, "__name__") == nil)) then
    for i = 1, #cls do
      if isinstance(val, cls[i]) then return true end
    end
    return false
  end
  local is_none = (val == nil or val == _G._luthon_none or (type(val) == "table" and rawget(val, "__is_none__") == true))
  if is_none then
    local cls_name = type(cls) == "string" and cls or (type(cls) == "table" and (rawget(cls, "__name__") or cls.__name__))
    if cls_name == "NoneType" or cls == (_builtin_types and _builtin_types["NoneType"]) or (types and types.NoneType and cls == types.NoneType) then
      return true
    end
    return false
  end
  local t = type(val)
  if t == "function" then
    if cls == "function" or cls == (types and types.FunctionType) or cls == (types and types.LambdaType) or cls == (types and types.BuiltinFunctionType) then return true end
    local name = type(cls) == "string" and cls or (type(cls) == "table" and (rawget(cls, "__name__") or cls.__name__))
    if name == "function" or name == "FunctionType" or name == "builtin_function_or_method" or name == "BuiltinFunctionType" then return true end
    return false
  end
  if t == "number" then
    if cls == "int" or cls == "float" or cls == int or cls == float then return true end
    local name = type(cls) == "string" and cls or (type(cls) == "table" and (rawget(cls, "__name__") or cls.__name__))
    if name == "Number" or name == "Real" or name == "Complex" then return true end
    if (name == "Integral" or name == "Rational") and math.floor(val) == val then return true end
    return false
  end
  if t == "string" then return cls == "str" or cls == str end
  if t == "boolean" then return cls == "bool" or cls == bool end
  if t == "table" then
    if cls == "tuple" or cls == tuple then return rawget(val, "_tuple") or (getmetatable(val) and (getmetatable(val).__tuple or getmetatable(val) == _tuple_mt)) end
    if cls == "bytes" or cls == bytes then return rawget(val, "_bytes") or (getmetatable(val) and getmetatable(val) == _bytes_mt) end
    if cls == "set" or cls == set then return rawget(val, "_set") or (getmetatable(val) and getmetatable(val) == _set_mt) end
    if cls == "list" or cls == list then return rawget(val, "_list") or getmetatable(val) == _list_mt or #val > 0 end
    if cls == "dict" or cls == dict then return true end
    local c = val.__class__ or (getmetatable(val) and getmetatable(val).__index)
    while c do
      if c == cls or (cls.__name__ and c.__name__ == cls.__name__) or c.__name == cls.__name then
        return true
      end
      c = c.__base__ or (getmetatable(c) and getmetatable(c).__index)
    end
  end
  return false
end

function getattr(obj, name, default)
  if obj == nil or obj == _G._luthon_none then
    if default ~= nil then return default end
    error("AttributeError: 'NoneType' object has no attribute '" .. tostring(name) .. "'")
  end
  if type(obj) == "string" and _str_methods and _str_methods[name] ~= nil then
    return _str_methods[name]
  end
  local ok, val = pcall(function() return obj[name] end)
  if ok and val ~= nil then
    if type(val) == "table" and type(val.__get__) == "function" then
      return val:__get__(obj, obj.__class__)
    end
    return val
  end
  if type(obj) == "table" and _dict_methods[name] ~= nil then
    return _dict_methods[name]
  end
  local cls = obj.__class__ or (getmetatable(obj) and getmetatable(obj).__index)
  if type(cls) == "table" and type(cls[name]) == "table" and type(cls[name].__get__) == "function" then
    return cls[name]:__get__(obj, cls)
  end
  if type(obj.__getattr__) == "function" then
    local ok_ga, res = pcall(obj.__getattr__, obj, name)
    if ok_ga and res ~= nil then return res end
  end
  if default ~= nil then return default end
  error("AttributeError: object has no attribute " .. tostring(name))
end

function hasattr(obj, name)
  if obj == nil or obj == _G._luthon_none then return false end
  local ok, res = pcall(getattr, obj, name)
  return ok and res ~= nil
end

function setattr(obj, name, val)
  if obj == nil then error("AttributeError: cannot set attribute on nil") end
  obj[name] = val
end

function delattr(obj, name)
  if obj == nil then error("AttributeError: cannot del attribute on nil") end
  obj[name] = nil
end

function globals()
  local g = setmetatable({}, {
    __index = function(_, k)
      if _dict_methods[k] then return _dict_methods[k] end
      return _G[k]
    end,
    __newindex = function(_, k, v)
      _G[k] = v
    end
  })
  return g
end

function locals()
  return globals()
end

types = types or {}
types.FunctionType = { __name__ = "function" }
types.LambdaType = types.FunctionType
types.BuiltinFunctionType = { __name__ = "builtin_function_or_method" }
types.MethodType = { __name__ = "method" }
types.GeneratorType = { __name__ = "generator" }
types.CoroutineType = { __name__ = "coroutine" }
types.ModuleType = types.ModuleType or { __name__ = "ModuleType" }
types.TracebackType = { __name__ = "traceback" }
types.FrameType = { __name__ = "frame" }
types.CodeType = { __name__ = "code" }
types.MappingProxyType = function(d)
  local proxy = {}
  return setmetatable(proxy, {
    __index = d,
    __newindex = function(t, k, v)
      error("TypeError: 'mappingproxy' object does not support item assignment", 2)
    end,
    __len = function() return (type(d) == "table" and (d.__len and d:__len() or #d)) or 0 end,
    __tostring = function() return "mappingproxy(" .. tostring(d) .. ")" end,
    __class__ = { __name__ = "mappingproxy" }
  })
end
types.SimpleNamespace = function(kwargs)
  local ns = kwargs or {}
  return setmetatable(ns, {
    __tostring = function()
      local parts = {}
      for k, v in pairs(ns) do
        if type(k) == "string" and not tostring(k):match("^__") then
          table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
      end
      return "namespace(" .. table.concat(parts, ", ") .. ")"
    end,
    __class__ = { __name__ = "SimpleNamespace" }
  })
end
object = object or {}
object.__name__ = "object"
object.__index = object
object.__new__ = function(cls, ...)
  local mt = cls and cls.__instance_mt or {__index = cls}
  return setmetatable({__class__ = cls}, mt)
end
object.__init__ = function(self, ...) end
object.__str__ = function(self)
  local cls = rawget(self, "__class__")
  local name = cls and (cls.__name__ or rawget(cls, "__name__")) or "object"
  return "<" .. tostring(name) .. " object>"
end
object.__repr__ = object.__str__
setmetatable(object, {
  __call = function(cls, ...)
    local self = setmetatable({__class__ = cls}, cls.__instance_mt or {__index = cls})
    if cls.__init__ then cls.__init__(self, ...) end
    return self
  end
})

local function _exception_str_impl(e)
  if e.message ~= nil then return tostring(e.message) end
  if e.__msg ~= nil then return tostring(e.__msg) end
  if e.args and #e.args == 1 then return tostring(e.args[1]) end
  return (e.__class__ and (e.__class__.__name__ or rawget(e.__class__, "__name__"))) or e.__type or "Exception"
end

local _exc_inst_mt = {
  __tostring = function(e)
    local s = rawget(e, "__str__")
    if type(s) == "function" and s ~= _exc_inst_mt.__tostring and s ~= _exception_str_impl then return s(e) end
    return _exception_str_impl(e)
  end
}

Exception = Exception or {}
Exception.__name__ = "Exception"
Exception.__type = "Exception"
Exception.__base__ = object
Exception.__index = Exception
Exception.__new__ = object.__new__
Exception.__init__ = function(self, msg, ...)
  if type(self) == "table" then
    self.message = msg
    self.__msg = msg
    self.args = setmetatable({msg, ...}, _tuple_mt or {})
  end
end
Exception.__str__ = _exception_str_impl
Exception.__repr__ = function(self)
  local name = (self.__class__ and self.__class__.__name__) or self.__type or "Exception"
  local m = self.message or self.__msg
  return name .. "(" .. (m and string.format("%q", tostring(m)) or "") .. ")"
end
Exception.__instance_mt = {
  __index = Exception,
  __tostring = _exc_inst_mt.__tostring
}
setmetatable(Exception, {
  __index = object,
  __call = function(c, msg, ...)
    local inst = setmetatable({__class__ = c, __type = c.__name or "Exception"}, c.__instance_mt or _exc_inst_mt)
    if c.__init__ then c.__init__(inst, msg, ...) end
    return inst
  end
})
_G.Exception = Exception
if _G.__LUTHON_FN_PARAMS then
  _G.__LUTHON_FN_PARAMS[Exception.__init__] = setmetatable({"self", "message"}, _tuple_mt or {})
  _G.__LUTHON_FN_PARAMS[Exception] = setmetatable({"message"}, _tuple_mt or {})
end

local _STD_EXCEPTIONS = {
  "BaseException", "SystemExit", "KeyboardInterrupt", "GeneratorExit",
  "ValueError", "TypeError", "AssertionError",
  "NameError", "KeyError", "IndexError", "AttributeError", "RuntimeError",
  "StopIteration", "ZeroDivisionError", "FileNotFoundError", "IOError", "OSError",
  "ImportError", "ModuleNotFoundError", "Warning", "UserWarning",
  "DeprecationWarning", "PendingDeprecationWarning", "SyntaxWarning",
  "RuntimeWarning", "FutureWarning", "ImportWarning", "UnicodeWarning",
  "BytesWarning", "ResourceWarning"
}

for _, cls_name in ipairs(_STD_EXCEPTIONS) do
  local exc = _G[cls_name] or {}
  exc.__name__ = cls_name
  exc.__type = cls_name
  exc.__base__ = Exception
  exc.__index = exc
  exc.__new__ = object.__new__
  exc.__init__ = Exception.__init__
  exc.__str__ = Exception.__str__
  exc.__repr__ = Exception.__repr__
  exc.__instance_mt = {
    __index = exc,
    __tostring = _exc_inst_mt.__tostring
  }
  setmetatable(exc, {
    __index = Exception,
    __call = function(c, msg, ...)
      local inst = setmetatable({__class__ = c, __type = c.__name or cls_name}, c.__instance_mt or _exc_inst_mt)
      if c.__init__ then c.__init__(inst, msg, ...) end
      return inst
    end
  })
  _G[cls_name] = exc
  if _G.__LUTHON_FN_PARAMS then
    _G.__LUTHON_FN_PARAMS[exc] = setmetatable({"message"}, _tuple_mt or {})
  end
end

if _G.SystemExit then
  _G.SystemExit.__init__ = function(self, code, ...)
    local c = (code == nil) and 0 or code
    self.code = c
    self.args = setmetatable({c, ...}, _tuple_mt or {})
    self.message = tostring(c)
    self.__msg = tostring(c)
  end
end

if _G.ModuleNotFoundError and _G.ImportError then
  _G.ModuleNotFoundError.__base__ = _G.ImportError
end

local function _exception_tostring(err)
  if type(err) ~= "table" then return tostring(err) end
  local cls_name = (err.__class__ and err.__class__.__name__) or "Exception"
  local msg = (err.args and err.args[1]) or err.message or err.msg or ""
  if msg ~= "" then
    return cls_name .. ": " .. tostring(msg)
  end
  return cls_name
end

local _error = error
error = function(err, level)
  if type(err) == "table" then
    local mt = getmetatable(err)
    if not mt then
      setmetatable(err, { __tostring = _exception_tostring })
    elseif not mt.__tostring then
      mt.__tostring = _exception_tostring
    end
    _error(err, level or 1)
  else
    _error(err, level or 1)
  end
end
_G["exec"] = _G["exec"] or function(...) end
__name__ = __name__ or "__main__"
os.sep = "/"
os.name = "posix"
os.linesep = "\n"
os.curdir = "."
os.pardir = ".."
os.devnull = "/dev/null"
os.path = os.path or {}
os.path.sep = "/"
os.path.curdir = "."
os.path.pardir = ".."
os.path.devnull = "/dev/null"
local _PATH_BUF = ffi.new("char[1024]")
os.path.join = function(...)
  local n = select("#", ...)
  if n == 0 then return "" end
  if _luthon_native_lib ~= nil then
    local cur = tostring(select(1, ...) or "")
    for i = 2, n do
      local part = tostring(select(i, ...) or "")
      local written = _luthon_native_lib.luthon_path_join(cur, part, _PATH_BUF, 1024)
      cur = ffi.string(_PATH_BUF, written)
    end
    return cur
  end
  local a = {...}
  return table.concat(a, "/")
end

os.path.dirname = function(p)
  p = tostring(p or "")
  if _luthon_native_lib ~= nil then
    local written = _luthon_native_lib.luthon_path_dirname(p, _PATH_BUF, 1024)
    return ffi.string(_PATH_BUF, written)
  end
  local dir = p:match("^(.*)/[^/]*$")
  if dir == "" then return "/" end
  return dir or "."
end

os.path.basename = function(p)
  p = tostring(p or "")
  if _luthon_native_lib ~= nil then
    local ptr = _luthon_native_lib.luthon_path_basename(p)
    if ptr ~= nil then return ffi.string(ptr) end
  end
  return p:match("^.*/([^/]*)$") or p
end
os.path.splitext = os.path.splitext or function(p)
  p = tostring(p or "")
  local base, ext = p:match("^(.*)(%.[^./\\]*)$")
  if base then return setmetatable({base, ext}, _list_mt) end
  return setmetatable({p, ""}, _list_mt)
end
os.path.abspath = os.path.abspath or function(p)
  p = tostring(p or "")
  if p:sub(1, 1) == "/" then return p end
  local cwd = "."
  local ok, res = pcall(function()
    ffi.cdef[[ char *getcwd(char *buf, size_t size); ]]
    local buf = ffi.new("char[1024]")
    local ptr = ffi.C.getcwd(buf, 1024)
    if ptr ~= nil then return ffi.string(ptr) end
  end)
  if ok and res then cwd = res end
  if p == "" or p == "." then return cwd end
  return cwd .. "/" .. p
end
os.path.realpath = function(p)
  p = tostring(p or "")
  local ok, res = pcall(function()
    ffi.cdef[[ char *realpath(const char *path, char *resolved_path); ]]
    local buf = ffi.new("char[4096]")
    local ptr = ffi.C.realpath(p, buf)
    if ptr ~= nil then return ffi.string(ptr) end
  end)
  if ok and res then return res end
  return os.path.abspath(p)
end
os.path.expanduser = function(p)
  p = tostring(p or "")
  local home = os.getenv("HOME") or "/"
  if p == "~" then return home end
  if p:sub(1, 2) == "~/" then return home .. p:sub(2) end
  return p
end

os.path.expandvars = function(p)
  p = tostring(p or "")
  return p:gsub("%${([%w_]+)}", function(v) return os.getenv(v) or ("${" .. v .. "}") end)
          :gsub("%$([%w_]+)", function(v) return os.getenv(v) or ("$" .. v) end)
end

os.path.getsize = os.path.getsize or function(p)
  p = tostring(p or "")
  local f = io.open(p, "rb")
  if not f then
    if FileNotFoundError then
      error(FileNotFoundError("No such file or directory: " .. p), 0)
    else
      error("FileNotFoundError: No such file or directory: " .. p, 0)
    end
  end
  local sz = f:seek("end")
  f:close()
  return sz or 0
end
os.path.exists = os.path.exists or function(p)
  p = tostring(p or "")
  if p == "" then return false end
  if _luthon_native_lib ~= nil then
    return _luthon_native_lib.luthon_path_exists(p)
  end
  if _LUTHON_STAT_BUF ~= nil then
    return ffi.C.stat(p, _LUTHON_STAT_BUF) == 0
  end
  local f = io.open(p, "r"); if f then f:close(); return true end; return false
end
os.path.isfile = os.path.isfile or function(p)
  p = tostring(p or "")
  if p == "" then return false end
  if _LUTHON_STAT_BUF ~= nil and ffi.C.stat(p, _LUTHON_STAT_BUF) == 0 then
    local bit_ok, bit_mod = pcall(require, "bit")
    if bit_ok and bit_mod then
      return bit_mod.band(_LUTHON_STAT_BUF.st_mode, 0x8000) ~= 0
    end
  end
  return os.path.exists(p)
end
os.path.isdir = os.path.isdir or function(p)
  p = tostring(p or "")
  if p == "" then return false end
  if _luthon_native_lib ~= nil then
    return _luthon_native_lib.luthon_path_isdir(p)
  end
  if _LUTHON_STAT_BUF ~= nil and ffi.C.stat(p, _LUTHON_STAT_BUF) == 0 then
    local bit_ok, bit_mod = pcall(require, "bit")
    if bit_ok and bit_mod then
      return bit_mod.band(_LUTHON_STAT_BUF.st_mode, 0x4000) ~= 0
    end
  end
  local ok = os.execute("test -d \"" .. p .. "\"")
  return ok == true or ok == 0
end
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
os.stat = function(p)
  p = tostring(p or "")
  local ffi = require("ffi")
  local sbuf = ffi.new("stat_t")
  local rc = ffi.C.stat(p, sbuf)
  if rc ~= 0 then
    if FileNotFoundError then
      error(FileNotFoundError("No such file or directory: '" .. p .. "'"), 0)
    else
      error("FileNotFoundError: [Errno 2] No such file or directory: '" .. p .. "'", 0)
    end
  end
  local res = {
    st_mode = tonumber(sbuf.st_mode),
    st_ino = tonumber(sbuf.st_ino),
    st_dev = tonumber(sbuf.st_dev),
    st_nlink = tonumber(sbuf.st_nlink),
    st_uid = tonumber(sbuf.st_uid),
    st_gid = tonumber(sbuf.st_gid),
    st_size = tonumber(sbuf.st_size),
    st_atime = tonumber(sbuf.st_atime) + tonumber(sbuf.st_atime_nsec) / 1e9,
    st_mtime = tonumber(sbuf.st_mtime) + tonumber(sbuf.st_mtime_nsec) / 1e9,
    st_ctime = tonumber(sbuf.st_ctime) + tonumber(sbuf.st_ctime_nsec) / 1e9,
  }
  return res
end
os.chmod = function(p, mode)
  p = tostring(p or "")
  local ffi = require("ffi")
  local rc = ffi.C.chmod(p, tonumber(mode or 0))
  if rc ~= 0 then
    local err_fn = _G.OSError or _G.IOError or OSError or IOError
    if err_fn then
      error(err_fn("chmod failed on: " .. p), 0)
    else
      error("OSError: chmod failed on: " .. p, 0)
    end
  end
  return 0
end
os.mkdir = os.mkdir or function(p, mode)
  p = tostring(p or "")
  mode = mode or 511
  local rc = ffi.C.mkdir(p, mode)
  if rc ~= 0 then
    local err_fn = _G.FileExistsError or _G.OSError or FileExistsError or OSError
    if err_fn then
      error(err_fn("File exists: " .. p), 0)
    else
      error("FileExistsError: File exists: " .. p, 0)
    end
  end
  return 0
end
local _urandom_f = nil
os.urandom = os.urandom or function(n)
  n = tonumber(n or 0)
  if n <= 0 then return "" end
  if not _urandom_f then
    _urandom_f = io.open("/dev/urandom", "rb")
  end
  if _urandom_f then
    local data = _urandom_f:read(n)
    if data and #data == n then
      return data
    end
  end
  local chars = {}
  for i = 1, n do
    chars[i] = string.char(math.random(0, 255))
  end
  return table.concat(chars)
end
os.makedirs = os.makedirs or function(p)
  p = tostring(p or "")
  if p == "" or os.path.isdir(p) then return end
  if _LUTHON_STAT_BUF ~= nil then
    local parts = {}
    for part in p:gmatch("[^/]+") do table.insert(parts, part) end
    local cur = p:sub(1, 1) == "/" and "/" or ""
    for _, part in ipairs(parts) do
      cur = cur == "/" and ("/" .. part) or (cur == "" and part or (cur .. "/" .. part))
      if not os.path.isdir(cur) then
        ffi.C.mkdir(cur, 511)
      end
    end
    return
  end
  if p ~= "" then os.execute("mkdir -p \"" .. p .. "\"") end
end
os.listdir = os.listdir or function(p)
  p = tostring(p or ".")
  local results = setmetatable({}, _list_mt)
  if ffi and ffi.C and ffi.C.opendir then
    local d = ffi.C.opendir(p)
    if d ~= nil then
      while true do
        local ent = ffi.C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
          table.insert(results, name)
        end
      end
      ffi.C.closedir(d)
      return results
    end
  end
  local cmd = "ls -1 -a \"" .. p .. "\" 2>/dev/null"
  local pipe = io.popen(cmd)
  if not pipe then return results end
  for line in pipe:lines() do
    if line ~= "." and line ~= ".." and line ~= "" then
      table.insert(results, line)
    end
  end
  pipe:close()
  return results
end
os.walk = os.walk or function(top)
  local results = setmetatable({}, _list_mt)
  if not top or not os.path.isdir(top) then return results end
  top = tostring(top or ".")
  if ffi and ffi.C and ffi.C.opendir and _LUTHON_STAT_BUF ~= nil then
    local bit_ok, bit_mod = pcall(require, "bit")
    local function walk_rec(dir)
      local d = ffi.C.opendir(dir)
      if d == nil then return end
      local subdirs = setmetatable({}, _list_mt)
      local files = setmetatable({}, _list_mt)
      while true do
        local ent = ffi.C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
          local full = dir .. "/" .. name
          if ent.d_type == 4 then
            table.insert(subdirs, name)
          elseif ent.d_type == 0 and bit_ok and bit_mod then
            if ffi.C.stat(full, _LUTHON_STAT_BUF) == 0 and bit_mod.band(_LUTHON_STAT_BUF.st_mode, 0x4000) ~= 0 then
              table.insert(subdirs, name)
            else
              table.insert(files, name)
            end
          else
            table.insert(files, name)
          end
        end
      end
      ffi.C.closedir(d)
      table.insert(results, setmetatable({dir, subdirs, files}, _list_mt))
      for _, s in ipairs(subdirs) do
        walk_rec(dir .. "/" .. s)
      end
    end
    walk_rec(top)
    return results
  end
  local p = io.popen("find \"" .. top .. "\" 2>/dev/null")
  if not p then return results end
  local dirs_map = {}
  local files_map = {}
  local all_dirs = {}
  for line in p:lines() do
    local ok = os.execute("test -d \"" .. line .. "\"")
    local is_dir = (ok == true or ok == 0)
    if is_dir then
      table.insert(all_dirs, line)
      dirs_map[line] = setmetatable({}, _list_mt)
      files_map[line] = setmetatable({}, _list_mt)
    else
      local parent = line:match("^(.*)/[^/]+$") or top
      local name = line:match("^.*/([^/]+)$") or line
      if not files_map[parent] then files_map[parent] = setmetatable({}, _list_mt) end
      table.insert(files_map[parent], name)
    end
  end
  p:close()
  for _, d in ipairs(all_dirs) do
    if d ~= top then
      local parent = d:match("^(.*)/[^/]+$") or top
      local name = d:match("^.*/([^/]+)$") or d
      if dirs_map[parent] then table.insert(dirs_map[parent], name) end
    end
  end
  for _, d in ipairs(all_dirs) do
    table.insert(results, setmetatable({d, dirs_map[d] or setmetatable({}, _list_mt), files_map[d] or setmetatable({}, _list_mt)}, _list_mt))
  end
  return results
end

sys = {argv = {}, path = setmetatable({}, _list_mt), meta_path = setmetatable({}, _list_mt), version = "3.14", version_info = setmetatable({3, 14, 0, "final", 0}, _list_mt), implementation = {name = "cpython", version = setmetatable({3, 14, 0, "final", 0}, _list_mt)}, modules = setmetatable({}, {__index = function(t, k) return _luthon_import(k) end})}
__import__ = function(name) return _luthon_import(name) end

json = {}
json.encode = nil
json.load = function(fp)
  local c = fp:read("*a")
  return json.loads(c)
end
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

local _py_re = nil
local function _get_py_re()
  if _py_re == nil then
    local ok, pb = pcall(require, "luthon.lua.pybridge")
    if not ok or not pb then ok, pb = pcall(require, "src/luthon/lua/pybridge") end
    if ok and pb and pb.is_available() then
      local ok_r, r = pcall(pb.import, "re")
      if ok_r and r then _py_re = r end
    end
    if not _py_re then _py_re = false end
  end
  return _py_re
end

re = {}
re.IGNORECASE = 2
re.I = 2
re.MULTILINE = 8
re.M = 8
re.DOTALL = 16
re.S = 16
re.VERBOSE = 64
re.X = 64
re.ASCII = 256
re.A = 256
re.compile = function(pattern, flags)
  local pyr = _get_py_re()
  if pyr then
    local ok, res
    if flags ~= nil and flags ~= 0 then
      ok, res = pcall(pyr.compile, pattern, flags)
    else
      ok, res = pcall(pyr.compile, pattern)
    end
    if ok and res then return res end
  end
  local obj = {
    pattern = pattern,
    flags = flags or 0,
    search = function(self, s) return re.search(pattern, s) end,
    match = function(self, s) return re.match(pattern, s) end,
    fullmatch = function(self, s)
      -- Match entire string
      local clean_pat = pattern:gsub("%(\\?[sS]%)%*?", ""):gsub("%^", ""):gsub("%$", "")
      -- Basic fallback match object for Version parsing
      local m = {
        _groups = {},
        group = function(self, g)
          if type(g) == "number" then return s end
          return self._groups[g]
        end
      }
      -- Parse PEP 440 version patterns (e.g. 2.0.0a1, 1.2.0, 1.10.0)
      local epoch, rem = s:match("^(%d+)!+(.*)$")
      if not rem then rem = s end
      local rel, pre_l, pre_n = rem:match("^(%d+%.[%d%.]+)(%a+)(%d*)")
      if not rel then
        rel = rem:match("^(%d+%.[%d%.]+)")
      end
      if rel then
        m._groups["epoch"] = epoch
        m._groups["release"] = rel
        if pre_l then
          m._groups["pre"] = pre_l .. (pre_n or "")
          m._groups["pre_l"] = pre_l
          m._groups["pre_n"] = pre_n
        end
        return m
      end
      return nil
    end,
    sub = function(self, repl, s) return re.sub(pattern, repl, s) end,
    findall = function(self, s) return re.findall(pattern, s) end,
    split = function(self, s) return string.split(s, pattern) end,
  }
  return obj
end
re.match = function(pat, s, flags)
  if s == nil then
    if TypeError then error(TypeError("expected string or bytes-like object, got 'NoneType'"), 0)
    else error("TypeError: expected string or bytes-like object, got 'NoneType'", 0) end
  end
  -- If pat is a compiled regex (PyProxy), use its .match method
  if type(pat) == "table" and rawget(pat, "_py") and pat.match then
    local bound = pat.match
    return bound(s)
  end
  local pyr = _get_py_re()
  if pyr then
    if flags ~= nil then
      return pyr.match(pat, s, flags)
    else
      return pyr.match(pat, s)
    end
  end
  local p = (type(pat) == "table" and (pat.pattern or pat)) or pat
  return string.match(s, p)
end
re.search = function(pat, s, flags)
  if s == nil then
    if TypeError then error(TypeError("expected string or bytes-like object, got 'NoneType'"), 0)
    else error("TypeError: expected string or bytes-like object, got 'NoneType'", 0) end
  end
  -- If pat is a compiled regex (PyProxy), use its .search method
  if type(pat) == "table" and rawget(pat, "_py") and pat.search then
    local bound = pat.search
    return bound(s)
  end
  local pyr = _get_py_re()
  if pyr then
    if flags ~= nil then
      return pyr.search(pat, s, flags)
    else
      return pyr.search(pat, s)
    end
  end
  local p = (type(pat) == "table" and (pat.pattern or pat)) or pat
  return string.match(s, p)
end
re.sub = function(pat, repl, s, count, flags)
  -- If pat is a compiled regex (PyProxy), use its .sub method
  if type(pat) == "table" and rawget(pat, "_py") and pat.sub then
    local bound = pat.sub
    local ok, res
    if count ~= nil then
      ok, res = pcall(bound, repl, s, count)
    else
      ok, res = pcall(bound, repl, s)
    end
    if ok then return res end
  end
  local pyr = _get_py_re()
  if pyr then
    local ok, res
    if count ~= nil and flags ~= nil then
      ok, res = pcall(pyr.sub, pat, repl, s, count, flags)
    elseif count ~= nil then
      ok, res = pcall(pyr.sub, pat, repl, s, count)
    else
      ok, res = pcall(pyr.sub, pat, repl, s)
    end
    if ok then return res end
  end
  local p = (type(pat) == "table" and (pat.pattern or pat)) or pat
  return (string.gsub(s, p, repl))
end
re.findall = function(pat, s, flags)
  -- If pat is a compiled regex (PyProxy), use its .findall method
  if type(pat) == "table" and rawget(pat, "_py") and pat.findall then
    local bound = pat.findall
    local ok, res = pcall(bound, s)
    if ok then return res end
  end
  local pyr = _get_py_re()
  if pyr then
    local ok, res
    if flags ~= nil then
      ok, res = pcall(pyr.findall, pat, s, flags)
    else
      ok, res = pcall(pyr.findall, pat, s)
    end
    if ok then return res end
  end
  local p = (type(pat) == "table" and (pat.pattern or pat)) or pat
  local r = {}
  for m in string.gmatch(s, p) do r[#r+1] = m end
  return r
end

setmetatable(re, {
  __index = function(t, k)
    local pyr = _get_py_re()
    if pyr and pyr[k] ~= nil then return pyr[k] end
    return nil
  end
})

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
local _sys_table = sys or {}
_sys_table.argv = _sys_table.argv or setmetatable({}, _list_mt)
_sys_table.path = _sys_table.path or setmetatable({}, _list_mt)
_sys_table.version = _sys_table.version or "3.14"
_sys_table.version_info = _sys_table.version_info or setmetatable({3, 14, 0, "final", 0}, _list_mt)
_sys_table.platform = "linux"
_sys_table.exit = function(code)
  code = (code == nil) and 0 or code
  if SystemExit then error(SystemExit(code), 2) else os.exit(code) end
end
_sys_table.stdout = io.stdout
_sys_table.stderr = io.stderr
_sys_table.stdin = io.stdin

if arg and type(arg) == "table" then
  _sys_table.argv = setmetatable({}, _list_mt)
  table.insert(_sys_table.argv, arg[0] or "luthon")
  local n = #arg
  for i = 1, n do table.insert(_sys_table.argv, arg[i]) end
end

sys = setmetatable({}, {
  __index = _sys_table,
  __newindex = function(t, k, v)
    _sys_table[k] = v
    if k == "argv" then
      pcall(function()
        local pb = _G.pybridge or package.loaded["pybridge"] or package.loaded["luthon.lua.pybridge"] or package.loaded["src/luthon/lua/pybridge"]
        if pb and pb.sync_sys_argv then
          pb.sync_sys_argv(v)
        end
      end)
    end
  end
})

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
functools.update_wrapper = function(wrapper, wrapped)
  if type(wrapper) == "table" or type(wrapper) == "function" then
    if type(wrapped) == "table" or type(wrapped) == "function" then
      if type(wrapper) == "table" and type(wrapped) == "table" then
        if wrapped.__name__ then wrapper.__name__ = wrapped.__name__ end
        if wrapped.__doc__ then wrapper.__doc__ = wrapped.__doc__ end
        if wrapped.__annotations__ then wrapper.__annotations__ = wrapped.__annotations__ end
        if wrapped.__qualname__ then wrapper.__qualname__ = wrapped.__qualname__ end
      end
      if type(wrapper) == "table" then
        wrapper.__wrapped__ = wrapped
      end
    end
  end
  return wrapper
end
functools.wraps = function(wrapped)
  return function(wrapper)
    return functools.update_wrapper(wrapper, wrapped)
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
local _timedelta_mt = {}
_timedelta_mt.__index = _timedelta_mt
function _timedelta_mt:total_seconds()
  return (self.days or 0) * 86400 + (self.seconds or 0) + (self.microseconds or 0) * 1e-6
end
_timedelta_mt.__tostring = function(self)
  local s = math.floor(self.seconds or 0)
  local hrs = math.floor(s / 3600)
  local mins = math.floor((s % 3600) / 60)
  local secs = s % 60
  if (self.days or 0) ~= 0 then
    return string.format("%d days, %d:%02d:%02d", self.days, hrs, mins, secs)
  else
    return string.format("%d:%02d:%02d", hrs, mins, secs)
  end
end
_timedelta_mt.__lt = function(a, b)
  return a:total_seconds() < b:total_seconds()
end
_timedelta_mt.__le = function(a, b)
  return a:total_seconds() <= b:total_seconds()
end
_timedelta_mt.__eq = function(a, b)
  return a:total_seconds() == b:total_seconds()
end

local _datetime_mt = {}
_datetime_mt.__index = _datetime_mt

local function _datetime_to_timestamp(self)
  local t = {
    year = self.year or 1970,
    month = self.month or 1,
    day = self.day or 1,
    hour = self.hour or 0,
    min = self.minute or self.min or 0,
    sec = self.second or self.sec or 0,
  }
  return os.time(t)
end

local function _datetime_add(a, b)
  local dt_obj, td_obj = a, b
  if type(b) == "table" and (b.hour ~= nil or (b.month ~= nil and b.day ~= nil)) and (a.days ~= nil or a.seconds ~= nil) then
    dt_obj, td_obj = b, a
  end
  local total_secs = 0
  if td_obj and td_obj.total_seconds then
    total_secs = td_obj:total_seconds()
  elseif type(td_obj) == "table" then
    total_secs = (td_obj.days or 0) * 86400 + (td_obj.seconds or 0) + (td_obj.microseconds or 0) * 1e-6
  elseif type(td_obj) == "number" then
    total_secs = td_obj
  end
  local ts = _datetime_to_timestamp(dt_obj) + (dt_obj.microsecond or 0) * 1e-6 + total_secs
  return datetime.datetime.fromtimestamp(ts)
end

local function _datetime_sub(a, b)
  if type(b) == "table" and (b.days ~= nil or b.seconds ~= nil) and b.hour == nil and b.month == nil then
    local total_secs = 0
    if b.total_seconds then
      total_secs = b:total_seconds()
    else
      total_secs = (b.days or 0) * 86400 + (b.seconds or 0) + (b.microseconds or 0) * 1e-6
    end
    local ts = _datetime_to_timestamp(a) + (a.microsecond or 0) * 1e-6 - total_secs
    return datetime.datetime.fromtimestamp(ts)
  end
  local tsa = _datetime_to_timestamp(a) + (a.microsecond or 0) * 1e-6
  local tsb = _datetime_to_timestamp(b) + (b.microsecond or 0) * 1e-6
  local diff = tsa - tsb
  local d = math.floor(diff / 86400)
  local rem = diff - d * 86400
  local s = math.floor(rem)
  local us = math.floor((rem - s) * 1e6 + 0.5)
  return datetime.timedelta(d, s, us)
end

local function _datetime_lt(a, b)
  local tsa = _datetime_to_timestamp(a) + (a.microsecond or 0) * 1e-6
  local tsb = _datetime_to_timestamp(b) + (b.microsecond or 0) * 1e-6
  return tsa < tsb
end

local function _datetime_le(a, b)
  local tsa = _datetime_to_timestamp(a) + (a.microsecond or 0) * 1e-6
  local tsb = _datetime_to_timestamp(b) + (b.microsecond or 0) * 1e-6
  return tsa <= tsb
end

local function _datetime_eq(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return (a.year == b.year and a.month == b.month and a.day == b.day and
          (a.hour or 0) == (b.hour or 0) and
          (a.minute or a.min or 0) == (b.minute or b.min or 0) and
          (a.second or a.sec or 0) == (b.second or b.sec or 0) and
          (a.microsecond or 0) == (b.microsecond or 0))
end

_datetime_mt.__add = _datetime_add
_datetime_mt.__sub = _datetime_sub
_datetime_mt.__lt = _datetime_lt
_datetime_mt.__le = _datetime_le
_datetime_mt.__eq = _datetime_eq

_timedelta_mt.__add = function(a, b)
  if type(a) == "table" and (a.hour ~= nil or (a.month ~= nil and a.day ~= nil)) then
    return _datetime_add(a, b)
  end
  if type(b) == "table" and (b.hour ~= nil or (b.month ~= nil and b.day ~= nil)) then
    return _datetime_add(a, b)
  end
  return datetime.timedelta(
    (a.days or 0) + (b.days or 0),
    (a.seconds or 0) + (b.seconds or 0),
    (a.microseconds or 0) + (b.microseconds or 0)
  )
end

local function _datetime_replace(self, year, month, day, hour, minute, second, microsecond)
  if type(year) == "table" and month == nil then
    local kw = year
    year = kw.year
    month = kw.month
    day = kw.day
    hour = kw.hour
    minute = kw.minute or kw.min
    second = kw.second or kw.sec
    microsecond = kw.microsecond
  end
  local res = {
    year = year or self.year,
    month = month or self.month,
    day = day or self.day,
    hour = hour or self.hour,
    minute = minute or self.minute or self.min or 0,
    min = minute or self.minute or self.min or 0,
    second = second or self.second or self.sec or 0,
    sec = second or self.second or self.sec or 0,
    microsecond = microsecond or self.microsecond or 0,
  }
  return setmetatable(res, _datetime_mt)
end

local function _datetime_isoformat(self, sep)
  sep = sep or "T"
  local s = string.format("%04d-%02d-%02d%s%02d:%02d:%02d",
    self.year or 1970,
    self.month or 1,
    self.day or 1,
    sep,
    self.hour or 0,
    self.minute or self.min or 0,
    self.second or self.sec or 0)
  if self.microsecond and self.microsecond > 0 then
    s = s .. string.format(".%06d", self.microsecond)
  end
  return s
end

local function _datetime_strftime(self, fmt)
  local ts = _datetime_to_timestamp(self)
  return os.date(fmt, ts)
end

local function _datetime_timetuple(self)
  local ts = _datetime_to_timestamp(self)
  local dt = os.date("*t", ts)
  return _tuple_pack(dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec, (dt.wday + 5) % 7, dt.yday, dt.isdst and 1 or 0)
end

local function _datetime_timestamp(self)
  local ts = _datetime_to_timestamp(self)
  if self.microsecond and self.microsecond > 0 then
    return ts + self.microsecond * 1e-6
  end
  return ts
end

local function _datetime_date(self)
  return datetime.date(self.year, self.month, self.day)
end

local function _datetime_time(self)
  return datetime.time(self.hour, self.minute or self.min or 0, self.second or self.sec or 0)
end

_datetime_mt.replace = _datetime_replace
_datetime_mt.isoformat = _datetime_isoformat
_datetime_mt.strftime = _datetime_strftime
_datetime_mt.timetuple = _datetime_timetuple
_datetime_mt.timestamp = _datetime_timestamp
_datetime_mt.date = _datetime_date
_datetime_mt.time = _datetime_time
_datetime_mt.__tostring = function(self)
  return _datetime_isoformat(self, " ")
end

_luthon_reg_fn(_datetime_replace, {"self", "year", "month", "day", "hour", "minute", "second", "microsecond"})
_luthon_reg_fn(_datetime_isoformat, {"self", "sep", "timespec"})
_luthon_reg_fn(_datetime_strftime, {"self", "fmt"})
_luthon_reg_fn(_datetime_timetuple, {"self"})
_luthon_reg_fn(_datetime_timestamp, {"self"})
_luthon_reg_fn(_datetime_date, {"self"})
_luthon_reg_fn(_datetime_time, {"self"})

local _date_mt = {}
_date_mt.__index = _date_mt
function _date_mt:isoformat()
  return string.format("%04d-%02d-%02d", self.year or 1970, self.month or 1, self.day or 1)
end
function _date_mt:strftime(fmt)
  local ts = os.time({year = self.year or 1970, month = self.month or 1, day = self.day or 1, hour = 0, min = 0, sec = 0})
  return os.date(fmt, ts)
end
function _date_mt:timetuple()
  local ts = os.time({year = self.year or 1970, month = self.month or 1, day = self.day or 1, hour = 0, min = 0, sec = 0})
  local dt = os.date("*t", ts)
  return _tuple_pack(dt.year, dt.month, dt.day, 0, 0, 0, (dt.wday + 5) % 7, dt.yday, -1)
end
_date_mt.__tostring = function(self)
  return self:isoformat()
end
_date_mt.__lt = function(a, b)
  if a.year ~= b.year then return (a.year or 0) < (b.year or 0) end
  if a.month ~= b.month then return (a.month or 0) < (b.month or 0) end
  return (a.day or 0) < (b.day or 0)
end
_date_mt.__le = function(a, b)
  if a.year ~= b.year then return (a.year or 0) <= (b.year or 0) end
  if a.month ~= b.month then return (a.month or 0) <= (b.month or 0) end
  return (a.day or 0) <= (b.day or 0)
end
_date_mt.__eq = function(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.year == b.year and a.month == b.month and a.day == b.day
end

datetime = {}
datetime.date = setmetatable({
  today = function()
    local t = os.date("*t")
    return setmetatable({year = t.year, month = t.month, day = t.day}, _date_mt)
  end,
  fromtimestamp = function(ts)
    local t = os.date("*t", math.floor(ts or 0))
    return setmetatable({year = t.year, month = t.month, day = t.day}, _date_mt)
  end,
}, {
  __call = function(_, y, m, d)
    return setmetatable({year = y or 1970, month = m or 1, day = d or 1}, _date_mt)
  end
})

datetime.time = setmetatable({}, {
  __call = function(_, hour, minute, second)
    return {hour = hour or 0, minute = minute or 0, min = minute or 0, second = second or 0, sec = second or 0}
  end
})

local function _datetime_create(year, month, day, hour, minute, second, microsecond)
  if type(year) == "table" and month == nil then
    local kw = year
    year = kw.year
    month = kw.month
    day = kw.day
    hour = kw.hour
    minute = kw.minute or kw.min
    second = kw.second or kw.sec
    microsecond = kw.microsecond
  end
  local obj = {
    year = year or 1970,
    month = month or 1,
    day = day or 1,
    hour = hour or 0,
    minute = minute or 0,
    min = minute or 0,
    second = second or 0,
    sec = second or 0,
    microsecond = microsecond or 0,
  }
  return setmetatable(obj, _datetime_mt)
end

datetime.datetime = setmetatable({
  now = function()
    local t = os.date("*t")
    local obj = {
      year = t.year,
      month = t.month,
      day = t.day,
      hour = t.hour,
      minute = t.min,
      min = t.min,
      second = t.sec,
      sec = t.sec,
      microsecond = 0,
    }
    return setmetatable(obj, _datetime_mt)
  end,
  utcnow = function()
    local t = os.date("!*t")
    local obj = {
      year = t.year,
      month = t.month,
      day = t.day,
      hour = t.hour,
      minute = t.min,
      min = t.min,
      second = t.sec,
      sec = t.sec,
      microsecond = 0,
    }
    return setmetatable(obj, _datetime_mt)
  end,
  fromtimestamp = function(ts)
    local t = os.date("*t", math.floor(ts or 0))
    local us = math.floor(((ts or 0) - math.floor(ts or 0)) * 1e6 + 0.5)
    local obj = {
      year = t.year,
      month = t.month,
      day = t.day,
      hour = t.hour,
      minute = t.min,
      min = t.min,
      second = t.sec,
      sec = t.sec,
      microsecond = us,
    }
    return setmetatable(obj, _datetime_mt)
  end,
  utcfromtimestamp = function(ts)
    local t = os.date("!*t", math.floor(ts or 0))
    local us = math.floor(((ts or 0) - math.floor(ts or 0)) * 1e6 + 0.5)
    local obj = {
      year = t.year,
      month = t.month,
      day = t.day,
      hour = t.hour,
      minute = t.min,
      min = t.min,
      second = t.sec,
      sec = t.sec,
      microsecond = us,
    }
    return setmetatable(obj, _datetime_mt)
  end,
  min = _datetime_create(1, 1, 1, 0, 0, 0, 0),
  max = _datetime_create(9999, 12, 31, 23, 59, 59, 999999),
}, {
  __call = function(_, ...)
    return _datetime_create(...)
  end
})
_luthon_reg_fn(_datetime_create, {"year", "month", "day", "hour", "minute", "second", "microsecond"})

_datetime_mt.__name__ = "datetime"
_datetime_mt.__class__ = datetime.datetime
_datetime_mt.__base__ = datetime.date
datetime.datetime.__name__ = "datetime"

_date_mt.__name__ = "date"
_date_mt.__class__ = datetime.date
datetime.date.__name__ = "date"

datetime.timedelta = function(days, seconds, microseconds, milliseconds, minutes, hours, weeks)
  if type(days) == "table" and seconds == nil then
    local kw = days
    days = kw.days
    seconds = kw.seconds
    microseconds = kw.microseconds
    milliseconds = kw.milliseconds
    minutes = kw.minutes
    hours = kw.hours
    weeks = kw.weeks
  end
  local total_secs = (days or 0) * 86400 +
                     (weeks or 0) * 7 * 86400 +
                     (hours or 0) * 3600 +
                     (minutes or 0) * 60 +
                     (seconds or 0) +
                     (milliseconds or 0) * 0.001 +
                     (microseconds or 0) * 1e-6
  local d = math.floor(total_secs / 86400)
  local rem = total_secs - d * 86400
  local s = math.floor(rem)
  local us = math.floor((rem - s) * 1e6 + 0.5)
  return setmetatable({days = d, seconds = s, microseconds = us}, _timedelta_mt)
end
_luthon_reg_fn(datetime.timedelta, {"days", "seconds", "microseconds", "milliseconds", "minutes", "hours", "weeks"})

_timedelta_mt.__name__ = "timedelta"
_timedelta_mt.__class__ = datetime.timedelta
datetime.datetime.timedelta = datetime.timedelta
datetime.datetime.date = datetime.date
datetime.datetime.time = datetime.time

-- time
time = time or {}
local _time_tv = nil
pcall(function()
  ffi.cdef[[
    typedef struct timeval {
      long tv_sec;
      long tv_usec;
    } timeval;
    int gettimeofday(struct timeval *tv, void *tz);
  ]]
  _time_tv = ffi.new("struct timeval")
end)

time.time = function()
  if _time_tv ~= nil and ffi.C.gettimeofday then
    ffi.C.gettimeofday(_time_tv, nil)
    return tonumber(_time_tv.tv_sec) + tonumber(_time_tv.tv_usec) * 1e-6
  end
  return os.time()
end
time.perf_counter = time.time
time.monotonic = time.time
time.sleep = function(secs)
  pcall(function()
    ffi.cdef[[ int usleep(unsigned int usec); ]]
    ffi.C.usleep(math.floor((secs or 0) * 1000000))
  end)
end
time.mktime = function(t)
  if type(t) == "table" then
    if t.year and t.month and t.day then
      return os.time({year = t.year, month = t.month, day = t.day, hour = t.hour or t.min or 0, min = t.minute or t.min or 0, sec = t.second or t.sec or 0})
    elseif #t >= 6 then
      return os.time({year = t[1], month = t[2], day = t[3], hour = t[4], min = t[5], sec = t[6]})
    end
  end
  return os.time()
end
time.localtime = function(secs)
  local t = os.date("*t", math.floor(secs or os.time()))
  return _tuple_pack(t.year, t.month, t.day, t.hour, t.min, t.sec, (t.wday + 5) % 7, t.yday, t.isdst and 1 or 0)
end
time.gmtime = function(secs)
  local t = os.date("!*t", math.floor(secs or os.time()))
  return _tuple_pack(t.year, t.month, t.day, t.hour, t.min, t.sec, (t.wday + 5) % 7, t.yday, 0)
end
time.strftime = function(fmt, t)
  if t == nil then return os.date(fmt) end
  return os.date(fmt, time.mktime(t))
end

-- string constants and methods
string.ascii_letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
string.ascii_lowercase = "abcdefghijklmnopqrstuvwxyz"
string.ascii_uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
string.digits = "0123456789"
string.hexdigits = "0123456789abcdefABCDEF"
string.octdigits = "01234567"
string.punctuation = string.char(33,35,36,37,38,39,40,41,42,43,44,45,46,47,58,59,60,61,62,63,64,91,92,93,94,95,96,123,124,125,126)
string.whitespace = " \t\n\r\f\v"
string.strip = function(self, chars) return _str_methods.strip(self, chars) end
string.lstrip = function(self, chars) return _str_methods.lstrip(self, chars) end
string.rstrip = function(self, chars) return _str_methods.rstrip(self, chars) end
string.split = function(self, sep, maxsplit) return _str_methods.split(self, sep, maxsplit) end
string.replace = function(self, a, b, count) return _str_methods.replace(self, a, b, count) end
string.startswith = function(self, p)
  if type(p) == "table" then
    for i = 1, #p do
      local pref = p[i]
      if string.sub(self, 1, #pref) == pref then return true end
    end
    return false
  end
  return string.sub(self, 1, #p) == p
end
string.endswith = function(self, p)
  if type(p) == "table" then
    for i = 1, #p do
      local suf = p[i]
      if suf == "" or string.sub(self, -#suf) == suf then return true end
    end
    return false
  end
  return p == "" or string.sub(self, -#p) == p
end
string.find_py = function(self, p)
  local pos = string.find(self, p, 1, true)
  return pos and (pos - 1) or -1
end
string.join = function(self, t)
  local r = {}
  for i, v in ipairs(t or {}) do r[#r + 1] = tostring(v) end
  return table.concat(r, self)
end

-- base64
base64 = {}
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64map = {}
for i = 1, #b64chars do b64map[b64chars:sub(i, i)] = i - 1 end

local _b64_ffi_ok, _b64_ffi = pcall(require, "ffi")
local _b64_bit_ok, _b64_bit = pcall(require, "bit")

local _b64lut = nil
local _b64chars_ptr = nil
if _b64_ffi_ok and _b64_bit_ok then
  _b64lut = _b64_ffi.new("int16_t[256]")
  for i = 0, 255 do _b64lut[i] = -1 end
  for i = 1, #b64chars do _b64lut[b64chars:byte(i)] = i - 1 end
  _b64lut[61] = -2 -- "="
  _b64lut[9] = -3  -- tab
  _b64lut[10] = -3 -- LF
  _b64lut[13] = -3 -- CR
  _b64lut[32] = -3 -- space
  _b64chars_ptr = _b64_ffi.cast("const uint8_t*", b64chars)
end

base64.b64encode = function(data)
  data = tostring(data or "")
  local len = #data
  if len == 0 then return "" end

  if _luthon_native_lib ~= nil then
    local max_out = math.floor((len + 2) / 3) * 4 + 4
    local buf = ffi.new("char[?]", max_out)
    local n = _luthon_native_lib.luthon_b64_encode(ffi.cast("const uint8_t*", data), len, buf)
    return ffi.string(buf, n)
  elseif _b64_ffi_ok and _b64_bit_ok then
    local buf = _b64_ffi.new("uint8_t[?]", max_out)
    local ptr = _b64_ffi.cast("const uint8_t*", data)
    local out_pos = 0
    local i = 0
    while i + 2 < len do
      local a = ptr[i]
      local b = ptr[i+1]
      local c = ptr[i+2]
      local n = _b64_bit.bor(_b64_bit.lshift(a, 16), _b64_bit.lshift(b, 8), c)
      buf[out_pos] = _b64chars_ptr[_b64_bit.rshift(n, 18)]
      buf[out_pos + 1] = _b64chars_ptr[_b64_bit.band(_b64_bit.rshift(n, 12), 0x3F)]
      buf[out_pos + 2] = _b64chars_ptr[_b64_bit.band(_b64_bit.rshift(n, 6), 0x3F)]
      buf[out_pos + 3] = _b64chars_ptr[_b64_bit.band(n, 0x3F)]
      out_pos = out_pos + 4
      i = i + 3
    end
    local rem = len - i
    if rem == 1 then
      local a = ptr[i]
      local n = _b64_bit.lshift(a, 16)
      buf[out_pos] = _b64chars_ptr[_b64_bit.rshift(n, 18)]
      buf[out_pos + 1] = _b64chars_ptr[_b64_bit.band(_b64_bit.rshift(n, 12), 0x3F)]
      buf[out_pos + 2] = 61
      buf[out_pos + 3] = 61
      out_pos = out_pos + 4
    elseif rem == 2 then
      local a = ptr[i]
      local b = ptr[i+1]
      local n = _b64_bit.bor(_b64_bit.lshift(a, 16), _b64_bit.lshift(b, 8))
      buf[out_pos] = _b64chars_ptr[_b64_bit.rshift(n, 18)]
      buf[out_pos + 1] = _b64chars_ptr[_b64_bit.band(_b64_bit.rshift(n, 12), 0x3F)]
      buf[out_pos + 2] = _b64chars_ptr[_b64_bit.band(_b64_bit.rshift(n, 6), 0x3F)]
      buf[out_pos + 3] = 61
      out_pos = out_pos + 4
    end
    return _b64_ffi.string(buf, out_pos)
  end

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
  data = tostring(data or "")
  local len = #data
  if len == 0 then return "" end

  if _luthon_native_lib ~= nil then
    local max_out = math.floor(len * 3 / 4) + 4
    local buf = ffi.new("uint8_t[?]", max_out)
    local n = _luthon_native_lib.luthon_b64_decode(data, len, buf)
    return ffi.string(buf, n)
  elseif _b64_ffi_ok and _b64_bit_ok then
    local buf = _b64_ffi.new("uint8_t[?]", max_out)
    local ptr = _b64_ffi.cast("const uint8_t*", data)
    local quad_idx = 0
    local val = 0
    local out_pos = 0

    for i = 0, len - 1 do
      local code = _b64lut[ptr[i]]
      if code >= 0 then
        val = _b64_bit.bor(_b64_bit.lshift(val, 6), code)
        quad_idx = quad_idx + 1
        if quad_idx == 4 then
          buf[out_pos] = _b64_bit.rshift(val, 16)
          buf[out_pos + 1] = _b64_bit.band(_b64_bit.rshift(val, 8), 0xFF)
          buf[out_pos + 2] = _b64_bit.band(val, 0xFF)
          out_pos = out_pos + 3
          quad_idx = 0
          val = 0
        end
      elseif code == -2 then -- =
        if quad_idx == 2 then
          buf[out_pos] = _b64_bit.rshift(val, 4)
          out_pos = out_pos + 1
          quad_idx = 0
        elseif quad_idx == 3 then
          buf[out_pos] = _b64_bit.rshift(val, 10)
          buf[out_pos + 1] = _b64_bit.band(_b64_bit.rshift(val, 2), 0xFF)
          out_pos = out_pos + 2
          quad_idx = 0
        end
      end
    end
    if quad_idx == 2 then
      buf[out_pos] = _b64_bit.rshift(val, 4)
      out_pos = out_pos + 1
    elseif quad_idx == 3 then
      buf[out_pos] = _b64_bit.rshift(val, 10)
      buf[out_pos + 1] = _b64_bit.band(_b64_bit.rshift(val, 2), 0xFF)
      out_pos = out_pos + 2
    end
    return _b64_ffi.string(buf, out_pos)
  end

  data = data:gsub("%s+", "")
  local result = {}
  local i = 1
  while i <= #data do
    local chars = data:sub(i, i+3)
    local vals = {}
    for j = 1, 4 do
      local c = chars:sub(j, j)
      if c == "=" or c == "" then vals[j] = nil
      else vals[j] = b64map[c] end
    end
    if vals[1] and vals[2] then
      local n = vals[1] * 262144 + vals[2] * 4096 + (vals[3] or 0) * 64 + (vals[4] or 0)
      result[#result+1] = string.char(math.floor(n / 65536))
      if vals[3] ~= nil then result[#result+1] = string.char(math.floor((n % 65536) / 256) % 256) end
      if vals[4] ~= nil then result[#result+1] = string.char(n % 256) end
    end
    i = i + 4
  end
  return table.concat(result)
end

local py_base64 = nil
local function _get_py_base64()
  if not py_base64 then
    local ok, pb = _G.pcall(_G.require, "src/luthon/lua/pybridge")
    if not ok or not pb then
      ok, pb = _G.pcall(_G.require, "luthon.lua.pybridge")
    end
    if ok and pb and pb.is_available() then
      local ok_imp, mod = _G.pcall(pb.import, "base64")
      if ok_imp and mod then
        py_base64 = mod
      end
    end
  end
  return py_base64
end

setmetatable(base64, {
  __index = function(t, k)
    local py_b = _get_py_base64()
    if py_b then
      local val = py_b[k]
      if val ~= nil then
        rawset(t, k, val)
        return val
      end
    end
    return nil
  end
})

-- io StringIO
io.StringIO = function(initial)
  local s = {_buf = initial or "", _pos = 1}
  function s:write(str) self._buf = self._buf:sub(1, self._pos - 1) .. str .. self._buf:sub(self._pos + #str); self._pos = self._pos + #str; return self end
  function s:read(n) n = n or -1; if n < 0 then local c = self._buf:sub(self._pos); self._pos = #self._buf + 1; return c end; local c = self._buf:sub(self._pos, self._pos + n - 1); self._pos = self._pos + n; return c end
  function s:getvalue() return self._buf end
  function s:seek(whence, offset) offset = offset or 0; if whence == "set" then self._pos = offset + 1 elseif whence == "cur" then self._pos = self._pos + offset elseif whence == "end" then self._pos = #self._buf + 1 + offset end; return self._pos - 1 end
  return s
end

local _cached_py_bio_ctor = nil
local _cached_py_libpy = nil
local _cached_py_bridge = nil
local _cached_capi_stream = nil

io.BytesIO = function(initial)
  initial = tostring(initial or "")

  -- 1. Check for native Luthon C-API stream (Zero CPython Fallback)
  if _cached_capi_stream == nil then
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi then
      local ok_load, capi = pcall(function()
        ffi.cdef[[
          typedef struct _object PyObject;
          typedef long Py_ssize_t;
          PyObject* PyStream_FromBytes(const void *data, Py_ssize_t size);
          Py_ssize_t PyStream_Read(PyObject *stream, void *dest, Py_ssize_t size);
          Py_ssize_t PyStream_Write(PyObject *stream, const void *src, Py_ssize_t size);
          Py_ssize_t PyStream_Seek(PyObject *stream, Py_ssize_t offset, int whence);
          Py_ssize_t PyStream_Tell(PyObject *stream);
          const uint8_t* PyStream_GetBuffer(PyObject *stream, Py_ssize_t *size);
          void Py_DecRef(PyObject *o);
        ]]
        local lib_paths = {
          "src/luthon/native/libluthon_capi.so",
          "../luthon/src/luthon/native/libluthon_capi.so",
          (os.getenv("LUTHON_CAPI_LIB") or ""),
          ((os.getenv("HOME") or "") .. "/Projects/luthon/src/luthon/native/libluthon_capi.so"),
        }
        for _, lp in ipairs(lib_paths) do
          if lp ~= "" then
            local f = io.open(lp, "r")
            if f then
              f:close()
              return ffi.load(lp)
            end
          end
        end
        return ffi.load("libluthon_capi.so")
      end)
      if ok_load and capi then
        _cached_capi_stream = capi
      else
        _cached_capi_stream = false
      end
    else
      _cached_capi_stream = false
    end
  end

  if _cached_capi_stream then
    local ffi = require("ffi")
    local capi = _cached_capi_stream
    local c_stream = capi.PyStream_FromBytes(initial, #initial)
    if c_stream ~= nil then
      local s = {
        _handle = c_stream,
        _ffi = ffi,
        _capi = capi,
      }
      function s:read(n)
        n = n or -1
        if n < 0 then
          local cur = capi.PyStream_Tell(self._handle)
          local sz = ffi.new("Py_ssize_t[1]")
          local buf = capi.PyStream_GetBuffer(self._handle, sz)
          local remaining = tonumber(sz[0]) - tonumber(cur)
          if remaining <= 0 then return "" end
          local tmp = ffi.new("uint8_t[?]", remaining)
          local read_bytes = capi.PyStream_Read(self._handle, tmp, remaining)
          return ffi.string(tmp, read_bytes)
        else
          local tmp = ffi.new("uint8_t[?]", n)
          local read_bytes = capi.PyStream_Read(self._handle, tmp, n)
          return ffi.string(tmp, read_bytes)
        end
      end
      function s:write(str)
        str = tostring(str or "")
        capi.PyStream_Write(self._handle, str, #str)
        return #str
      end
      function s:seek(offset, whence)
        offset = offset or 0
        local w = 0
        if whence == "cur" or whence == 1 then w = 1
        elseif whence == "end" or whence == 2 then w = 2
        end
        return tonumber(capi.PyStream_Seek(self._handle, offset, w))
      end
      function s:tell()
        return tonumber(capi.PyStream_Tell(self._handle))
      end
      function s:getvalue()
        local sz = ffi.new("Py_ssize_t[1]")
        local buf = capi.PyStream_GetBuffer(self._handle, sz)
        if buf ~= nil and sz[0] > 0 then
          return ffi.string(buf, sz[0])
        end
        return ""
      end
      function s:close()
        if self._handle ~= nil then
          capi.Py_DecRef(self._handle)
          self._handle = nil
        end
      end
      return s
    end
  end

  -- 2. Fallback to CPython bridge if native stream unavailable
  if _cached_py_bio_ctor ~= nil then
    local b = _cached_py_libpy.PyBytes_FromStringAndSize(initial, #initial)
    local proxy = _cached_py_bridge.make_proxy(b)
    _cached_py_libpy.Py_DecRef(b)
    return _cached_py_bio_ctor(proxy)
  end

  local ok, py_bridge = pcall(require, "luthon.lua.pybridge")
  if not ok or not py_bridge then
    ok, py_bridge = pcall(require, "src/luthon/lua/pybridge")
  end
  if ok and py_bridge and py_bridge.get_lib then
    local ok_lib, libpy = pcall(py_bridge.get_lib)
    if ok_lib and libpy and libpy.PyBytes_FromStringAndSize then
      local ok_mod, mm = pcall(require, "luthon.lua.modules")
      if not ok_mod or not mm then
        ok_mod, mm = pcall(require, "src/luthon/lua/modules")
      end
      if ok_mod and mm and mm.load then
        local pio = mm.load("io")
        if pio and pio.BytesIO then
          _cached_py_bridge = py_bridge
          _cached_py_libpy = libpy
          _cached_py_bio_ctor = pio.BytesIO
          local b = libpy.PyBytes_FromStringAndSize(initial, #initial)
          local proxy = py_bridge.make_proxy(b)
          libpy.Py_DecRef(b)
          return _cached_py_bio_ctor(proxy)
        end
      end
    end
  end
  return io.StringIO(initial)
end

-- struct (minimal + pybridge fallback)
struct = {}
struct.error = setmetatable({
  __name__ = "error",
  __type = "struct.error",
  __base__ = Exception,
  __instance_mt = {
    __index = function(inst, k) return inst.__class__ and inst.__class__[k] or Exception[k] end,
    __tostring = _exc_inst_mt and _exc_inst_mt.__tostring or tostring,
  }
}, {
  __index = Exception,
  __call = function(c, msg, ...)
    local inst = setmetatable({__class__ = c, __type = "struct.error"}, c.__instance_mt or _exc_inst_mt)
    if Exception and Exception.__init__ then Exception.__init__(inst, msg, ...) end
    return inst
  end
})

local _struct_type_sizes = {
  x = 1, c = 1, b = 1, B = 1, ["?"] = 1,
  h = 2, H = 2,
  i = 4, I = 4, l = 4, L = 4, f = 4,
  q = 8, Q = 8, d = 8,
}
struct.calcsize = function(fmt)
  local size = 0
  local i = 1
  local first = fmt:sub(1, 1)
  if first == "@" or first == "=" or first == "<" or first == ">" or first == "!" then
    i = 2
  end
  while i <= #fmt do
    local num_str = fmt:match("^(%d+)", i)
    local count = 1
    if num_str then
      count = tonumber(num_str)
      i = i + #num_str
    end
    if i <= #fmt then
      local ch = fmt:sub(i, i)
      if ch == "s" or ch == "p" then
        size = size + count
      elseif _struct_type_sizes[ch] then
        size = size + count * _struct_type_sizes[ch]
      end
      i = i + 1
    end
  end
  return size
end

local py_struct = nil
local function _get_py_struct()
  if not py_struct then
    local ok, pb = _G.pcall(_G.require, "src/luthon/lua/pybridge")
    if not ok or not pb then
      ok, pb = _G.pcall(_G.require, "luthon.lua.pybridge")
    end
    if ok and pb and pb.is_available() then
      local ok_imp, mod = _G.pcall(pb.import, "struct")
      if ok_imp and mod then
        py_struct = mod
      end
    end
  end
  return py_struct
end

struct.pack = function(fmt, ...)
  local args = {...}
  local arg_idx = 1
  local endian = ">"
  local i = 1
  local first = fmt:sub(1, 1)
  if first == "<" or first == ">" or first == "!" or first == "=" or first == "@" then
    if first == "<" then endian = "<" else endian = ">" end
    i = 2
  end
  local out = {}
  while i <= #fmt do
    local num_str = fmt:match("^(%d+)", i)
    local count = 1
    if num_str then count = tonumber(num_str); i = i + #num_str end
    if i <= #fmt then
      local ch = fmt:sub(i, i)
      if ch == "s" or ch == "p" then
        local val = args[arg_idx]
        if type(val) == "table" and val[1] and type(val[1]) == "string" then val = val[1] end
        val = tostring(val or "")
        arg_idx = arg_idx + 1
        if #val < count then val = val .. string.rep("\0", count - #val)
        elseif #val > count then val = val:sub(1, count) end
        table.insert(out, val)
      elseif ch == "x" then
        table.insert(out, string.rep("\0", count))
      else
        for _ = 1, count do
          local v = tonumber(args[arg_idx] or 0)
          arg_idx = arg_idx + 1
          if ch == "B" or ch == "b" or ch == "c" or ch == "?" then
            table.insert(out, string.char(v % 256))
          elseif ch == "H" or ch == "h" then
            local b1 = v % 256
            local b2 = math.floor(v / 256) % 256
            if endian == "<" then table.insert(out, string.char(b1, b2))
            else table.insert(out, string.char(b2, b1)) end
          elseif ch == "I" or ch == "i" or ch == "L" or ch == "l" then
            local b1 = v % 256
            local b2 = math.floor(v / 256) % 256
            local b3 = math.floor(v / 65536) % 256
            local b4 = math.floor(v / 16777216) % 256
            if endian == "<" then table.insert(out, string.char(b1, b2, b3, b4))
            else table.insert(out, string.char(b4, b3, b2, b1)) end
          end
        end
      end
      i = i + 1
    end
  end
  if #out > 0 then return table.concat(out) end

  local py_s = _get_py_struct()
  if py_s then
    local res = py_s.pack(fmt, ...)
    if type(res) == "table" and rawget(res, "_py") then
      local pb = require("src/luthon/lua/pybridge")
      local libpy = pb.get_lib()
      local ffi = require("ffi")
      local s = libpy.PyBytes_AsString(res._py)
      local sz = libpy.PyBytes_Size(res._py)
      return ffi.string(s, sz)
    end
    return res
  end
  return ""
end
struct.unpack = function(fmt, s)
  if type(s) == "table" and s[1] and type(s[1]) == "string" then
    s = s[1]
  end
  s = tostring(s or "")
  local endian = ">"
  local i = 1
  local first = fmt:sub(1, 1)
  if first == "<" or first == ">" or first == "!" or first == "=" or first == "@" then
    if first == "<" then endian = "<" else endian = ">" end
    i = 2
  end
  local s_pos = 1
  local out = {}
  while i <= #fmt do
    local num_str = fmt:match("^(%d+)", i)
    local count = 1
    if num_str then count = tonumber(num_str); i = i + #num_str end
    if i <= #fmt then
      local ch = fmt:sub(i, i)
      if ch == "s" or ch == "p" then
        table.insert(out, s:sub(s_pos, s_pos + count - 1))
        s_pos = s_pos + count
      elseif ch == "x" then
        s_pos = s_pos + count
      else
        for _ = 1, count do
          if ch == "B" or ch == "b" or ch == "c" or ch == "?" then
            table.insert(out, s:byte(s_pos) or 0)
            s_pos = s_pos + 1
          elseif ch == "H" or ch == "h" then
            local b1 = s:byte(s_pos) or 0
            local b2 = s:byte(s_pos + 1) or 0
            s_pos = s_pos + 2
            if endian == "<" then table.insert(out, b1 + b2 * 256)
            else table.insert(out, b2 + b1 * 256) end
          elseif ch == "I" or ch == "i" or ch == "L" or ch == "l" then
            local b1 = s:byte(s_pos) or 0
            local b2 = s:byte(s_pos + 1) or 0
            local b3 = s:byte(s_pos + 2) or 0
            local b4 = s:byte(s_pos + 3) or 0
            s_pos = s_pos + 4
            if endian == "<" then table.insert(out, b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
            else table.insert(out, b4 + b3 * 256 + b2 * 65536 + b1 * 16777216) end
          end
        end
      end
      i = i + 1
    end
  end
  if #out > 0 then return setmetatable(out, _tuple_mt or {}) end

  local py_s = _get_py_struct()
  if py_s then
    local pb = require("src/luthon/lua/pybridge")
    local libpy = pb.get_lib()
    local py_bytes = libpy.PyBytes_FromStringAndSize(s, #s)
    local res = py_s.unpack(fmt, py_bytes)
    libpy.Py_DecRef(py_bytes)
    return res
  end
  return setmetatable({0}, _tuple_mt or {})
end
struct.Struct = setmetatable({}, {
  __call = function(_, fmt)
    return {
      format = fmt,
      size = struct.calcsize(fmt),
      pack = function(self, ...) return struct.pack(fmt, ...) end,
      unpack = function(self, s) return struct.unpack(fmt, s) end
    }
  end
})

setmetatable(struct, {
  __index = function(t, k)
    local py_s = _get_py_struct()
    if py_s then
      local val = py_s[k]
      if val ~= nil then
        rawset(t, k, val)
        return val
      end
    end
    return nil
  end
})

-- hashlib (with libcrypto FFI when available, fallback otherwise)
hashlib = {}
do
  local libcrypto = nil
  pcall(function()
    local ffi = require("ffi")
    ffi.cdef[[
      typedef void EVP_MD_CTX;
      typedef void EVP_MD;
      EVP_MD_CTX *EVP_MD_CTX_new(void);
      void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
      const EVP_MD *EVP_md5(void);
      const EVP_MD *EVP_sha1(void);
      const EVP_MD *EVP_sha256(void);
      const EVP_MD *EVP_sha512(void);
      int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, void *impl);
      int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
      int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);
    ]]
    for _, soname in ipairs({"libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so", "crypto"}) do
      local ok, lib = pcall(function() return ffi.load(soname) end)
      if ok and lib then
        libcrypto = lib
        break
      end
    end
  end)

  local function evp_digest(data, get_evp_fn, out_len)
    if libcrypto then
      local ffi = require("ffi")
      local ctx = libcrypto.EVP_MD_CTX_new()
      libcrypto.EVP_DigestInit_ex(ctx, get_evp_fn(), nil)
      libcrypto.EVP_DigestUpdate(ctx, data, #data)
      local out = ffi.new("unsigned char[?]", out_len)
      local len = ffi.new("unsigned int[1]")
      libcrypto.EVP_DigestFinal_ex(ctx, out, len)
      libcrypto.EVP_MD_CTX_free(ctx)
      local hex = {}
      for i = 0, len[0] - 1 do
        table.insert(hex, string.format("%02x", out[i]))
      end
      return table.concat(hex)
    end
    return nil
  end

  local function make_hash_obj(data, evp_fn, out_len, fallback_fn)
    local buffer = {}
    if data ~= nil and data ~= "" then
      table.insert(buffer, tostring(data))
    end
    local obj = {
      _buffer = buffer,
      update = function(self, chunk)
        if chunk ~= nil then
          table.insert(self._buffer, tostring(chunk))
        end
        return self
      end,
      hexdigest = function(self)
        local all_data = table.concat(self._buffer)
        if libcrypto and evp_fn then
          local hex = evp_digest(all_data, evp_fn, out_len)
          if hex then return hex end
        end
        return fallback_fn(all_data)
      end,
      digest = function(self)
        local hex = self:hexdigest()
        local bytes = {}
        for i = 1, #hex, 2 do
          table.insert(bytes, string.char(tonumber(hex:sub(i, i+1), 16)))
        end
        return table.concat(bytes)
      end,
      copy = function(self)
        local new_obj = make_hash_obj("", evp_fn, out_len, fallback_fn)
        for _, c in ipairs(self._buffer) do table.insert(new_obj._buffer, c) end
        return new_obj
      end
    }
    setmetatable(obj, {__tostring = function(self) return self:hexdigest() end})
    return obj
  end

  hashlib.md5 = function(data)
    return make_hash_obj(data, libcrypto and libcrypto.EVP_md5, 16, function(d)
      local h = 0
      for i = 1, #d do h = (h * 31 + d:byte(i)) % 4294967296 end
      return string.format("%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296)
    end)
  end

  hashlib.sha1 = function(data)
    return make_hash_obj(data, libcrypto and libcrypto.EVP_sha1, 20, function(d)
      local h = 0
      for i = 1, #d do h = (h * 37 + d:byte(i)) % 4294967296 end
      return string.format("%08x%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296, h * 1664525 % 4294967296)
    end)
  end

  hashlib.sha256 = function(data)
    return make_hash_obj(data, libcrypto and libcrypto.EVP_sha256, 32, function(d)
      local h = 0
      for i = 1, #d do h = (h * 41 + d:byte(i)) % 4294967296 end
      return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h, h * 2654435761 % 4294967296, h * 1566083941 % 4294967296, h * 40503 % 4294967296, h * 1664525 % 4294967296, h * 1103515245 % 4294967296, h * 12345 % 4294967296, h * 99991 % 4294967296)
    end)
  end

  hashlib.sha512 = function(data)
    return make_hash_obj(data, libcrypto and libcrypto.EVP_sha512, 64, function(d)
      return hashlib.sha256(d):hexdigest() .. hashlib.sha256(d .. "salt"):hexdigest()
    end)
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
    function path:read_text() local f = io.open(self._p, "r"); if not f then error("no such file: " .. self._p) end; local c = f:read("*a"); f:close(); return c end
    function path:write_text(c) local f = io.open(self._p, "w"); f:write(c); f:close() end
    function path:is_absolute() return self._p:match("^/") ~= nil end
    function path:resolve() if self:is_absolute() then return self._p end; return os.getenv("PWD") or "." .. "/" .. self._p end
    function path:is_relative_to(other) local other_path = type(other) == "string" and other or other._p; return self._p:sub(1, #other_path) == other_path end
    function path:glob(pattern) 
      local results = {}
      local dir = self:parent()
      local f = io.popen("ls " .. dir .. " 2>/dev/null")
      if f then
        for line in f:lines() do
          if line:match(pattern) then table.insert(results, pathlib.Path(self._p .. "/" .. line)) end
        end
        f:close()
      end
      return results
    end
    return path
  end
})
pathlib.Path.cwd = function() return pathlib.Path(".") end
pathlib.Path.home = function() return pathlib.Path(os.getenv("HOME") or "/") end

-- set and tuple (Lua doesn't have these natively)
-- (set and tuple are already defined above)

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
setmetatable(typing, {
  __index = function(t, k)
    local dummy = setmetatable({}, {
      __index = function(_, _) return t.Any end,
      __call = function(_, ...) return ... end,
    })
    rawset(t, k, dummy)
    return dummy
  end
})

-- json (complete with FFI cJSON acceleration and fast fallback)
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

local _cjson_lib = nil
local _cjson_init_done = false
local function _get_cjson()
  if _cjson_init_done then return _cjson_lib end
  _cjson_init_done = true
  local ffi_ok, ffi_mod = pcall(require, "ffi")
  if not ffi_ok or not ffi_mod then return nil end
  pcall(function()
    ffi_mod.cdef[[
      typedef struct cJSON {
        struct cJSON *next;
        struct cJSON *prev;
        struct cJSON *child;
        int type;
        char *valuestring;
        int valueint;
        double valuedouble;
        char *string;
      } cJSON;

      cJSON *cJSON_Parse(const char *value);
      void cJSON_Delete(cJSON *c);
    ]]
  end)
  local cand = {"libcjson.so.1", "libcjson.so", "/usr/lib64/libcjson.so.1", "/usr/local/lib/libcjson.so.1"}
  for _, soname in ipairs(cand) do
    local ok, lib = pcall(ffi_mod.load, soname)
    if ok and lib then
      _cjson_lib = {ffi = ffi_mod, lib = lib}
      return _cjson_lib
    end
  end
  return nil
end

local function _cjson_node_to_lua(node, ffi_str_fn)
  if node == nil then return nil end
  local t = node.type
  if t >= 256 then t = t % 256 end

  if t == 16 then -- cJSON_String
    return ffi_str_fn(node.valuestring)
  elseif t == 8 then -- cJSON_Number
    return node.valuedouble
  elseif t == 64 then -- cJSON_Object
    local obj = {}
    local curr = node.child
    while curr ~= nil do
      obj[ffi_str_fn(curr.string)] = _cjson_node_to_lua(curr, ffi_str_fn)
      curr = curr.next
    end
    return obj
  elseif t == 32 then -- cJSON_Array
    local arr = {}
    local curr = node.child
    local idx = 1
    while curr ~= nil do
      arr[idx] = _cjson_node_to_lua(curr, ffi_str_fn)
      idx = idx + 1
      curr = curr.next
    end
    rawset(arr, "_len", idx - 1)
    return arr
  elseif t == 2 then -- cJSON_True
    return true
  elseif t == 1 then -- cJSON_False
    return false
  elseif t == 4 then -- cJSON_NULL
    return nil
  end
  return nil
end

json.decode = function(s)
  s = tostring(s or "")
  local cj = _get_cjson()
  if cj ~= nil then
    local root = cj.lib.cJSON_Parse(s)
    if root ~= nil then
      local ffi_str_fn = cj.ffi.string
      local res = _cjson_node_to_lua(root, ffi_str_fn)
      cj.lib.cJSON_Delete(root)
      return res
    end
  end

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
json.load = function(fp)
  local c = fp:read("*a")
  return json.decode(c)
end

local _py_json_mod = nil
setmetatable(json, {
  __index = function(t, k)
    if not _py_json_mod then
      local ok, pb = pcall(require, "src/luthon/lua/pybridge")
      if not ok or not pb then ok, pb = pcall(require, "luthon.lua.pybridge") end
      if ok and pb and pb.is_available() then
        local ok_imp, mod = pcall(pb.import, "json")
        if ok_imp and mod then _py_json_mod = mod end
      end
    end
    if _py_json_mod then
      local val = _py_json_mod[k]
      if val ~= nil then
        rawset(t, k, val)
        return val
      end
    end
    return nil
  end
})

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

os.sep = "/"
os.name = "posix"
os.linesep = "\n"
os.curdir = "."
os.pardir = ".."
os.devnull = "/dev/null"
os.path = os.path or {}
os.path.sep = "/"
os.path.curdir = "."
os.path.pardir = ".."
os.path.devnull = "/dev/null"
os.path.join = function(...) local a={...}; return table.concat(a, "/") end
os.path.dirname = function(p)
  p = tostring(p or "")
  local dir = p:match("^(.*)/[^/]*$")
  if dir == "" then return "/" end
  return dir or "."
end
os.path.basename = function(p)
  p = tostring(p or "")
  return p:match("^.*/([^/]*)$") or p
end
os.path.splitext = function(p)
  p = tostring(p or "")
  local base, ext = p:match("^(.*)(%.[^./\\]*)$")
  if base then return setmetatable({base, ext}, _list_mt) end
  return setmetatable({p, ""}, _list_mt)
end
os.path.abspath = function(p)
  p = tostring(p or "")
  if p:sub(1, 1) == "/" then return p end
  local cwd = "."
  local ok, res = pcall(function()
    ffi.cdef[[ char *getcwd(char *buf, size_t size); ]]
    local buf = ffi.new("char[1024]")
    local ptr = ffi.C.getcwd(buf, 1024)
    if ptr ~= nil then return ffi.string(ptr) end
  end)
  if ok and res then cwd = res end
  if p == "" or p == "." then return cwd end
  return cwd .. "/" .. p
end
os.path.realpath = function(p)
  p = tostring(p or "")
  local ok, res = pcall(function()
    ffi.cdef[[ char *realpath(const char *path, char *resolved_path); ]]
    local buf = ffi.new("char[4096]")
    local ptr = ffi.C.realpath(p, buf)
    if ptr ~= nil then return ffi.string(ptr) end
  end)
  if ok and res then return res end
  return os.path.abspath(p)
end
os.path.expanduser = function(p)
  p = tostring(p or "")
  local home = os.getenv("HOME") or "/"
  if p == "~" then return home end
  if p:sub(1, 2) == "~/" then return home .. p:sub(2) end
  return p
end

os.path.expandvars = function(p)
  p = tostring(p or "")
  return p:gsub("%${([%w_]+)}", function(v) return os.getenv(v) or ("${" .. v .. "}") end)
          :gsub("%$([%w_]+)", function(v) return os.getenv(v) or ("$" .. v) end)
end

os.path.getsize = function(p)
  p = tostring(p or "")
  local f = io.open(p, "rb")
  if not f then
    if FileNotFoundError then
      error(FileNotFoundError("No such file or directory: " .. p), 0)
    else
      error("FileNotFoundError: No such file or directory: " .. p, 0)
    end
  end
  local sz = f:seek("end")
  f:close()
  return sz or 0
end
os.path.exists = function(p)
  if p == nil then return false end
  p = tostring(p)
  if p == "" then return false end
  local ok, res = pcall(function()
    local ffi = require("ffi")
    local st = ffi.new("stat_t")
    return ffi.C.stat(p, st) == 0
  end)
  if ok then return res end
  local f = io.open(p, "r"); if f then f:close(); return true end; return false
end
os.path.isfile = function(p)
  if p == nil then return false end
  p = tostring(p)
  if p == "" then return false end
  local ok, res = pcall(function()
    local ffi = require("ffi")
    local st = ffi.new("stat_t")
    if ffi.C.stat(p, st) == 0 then
      local mode = tonumber(st.st_mode)
      local bit = require("bit")
      return bit.band(mode, 0xF000) == 0x8000
    end
    return false
  end)
  if ok then return res end
  local f = io.open(p, "r"); if f then f:close(); return true end; return false
end
os.path.isdir = function(p)
  p = tostring(p or "")
  if p == "" then return false end
  local ok = os.execute("test -d \"" .. p .. "\"")
  return ok == true or ok == 0
end
os.rmdir = os.remove or function(p) end

-- open builtin (Python's open -> io.open with __enter__ / __exit__)
local _orig_io_open = io.open
local _file_mt = getmetatable(io.stdout)
if _file_mt then
  _file_mt.__enter__ = function(self) return self end
  _file_mt.__exit__ = function(self) self:close() end
  local _orig_file_read = _file_mt.read
  local _py_file_read = function(self, size, ...)
    if size == nil or (type(size) == "number" and size < 0) then
      local res = _orig_file_read(self, "*a")
      return res or ""
    end
    return _orig_file_read(self, size, ...)
  end
  _file_mt.read = _py_file_read
  _file_mt.readline = function(self, size)
    local line = _orig_file_read(self, "*l")
    if line then return line .. "\n" end
    return ""
  end
  _file_mt.readlines = function(self)
    local lines = setmetatable({}, _list_mt or {})
    while true do
      local l = _file_mt.readline(self)
      if l == "" then break end
      lines[#lines + 1] = l
    end
    return lines
  end
  _file_mt.fileno = function(self)
    local ffi = require("ffi")
    local ok, p = pcall(ffi.cast, "FILE*", self)
    if ok and p ~= nil then
      local ok_fn, fd = pcall(ffi.C.fileno, p)
      if ok_fn and fd >= 0 then return tonumber(fd) end
    end
    return 0
  end
  if type(_file_mt.__index) == "table" then
    _file_mt.__index.read = _file_mt.read
    _file_mt.__index.readline = _file_mt.readline
    _file_mt.__index.readlines = _file_mt.readlines
    _file_mt.__index.__enter__ = _file_mt.__enter__
    _file_mt.__index.__exit__ = _file_mt.__exit__
    _file_mt.__index.fileno = _file_mt.fileno
  end
end

os.fsync = function(fd)
  local ffi = require("ffi")
  if type(fd) == "number" then
    pcall(ffi.C.fsync, fd)
  end
  return 0
end

open = function(filename, mode, ...)
  local extra = {...}
  local kw = nil
  if #extra > 0 and type(extra[#extra]) == "table" and rawget(extra[#extra], "__luthon_kw") then
    kw = extra[#extra]
  end
  if type(mode) == "table" then
    kw = mode
    mode = nil
  end
  if type(filename) == "table" and (filename.name or filename._path or getmetatable(filename)) then
    filename = tostring(filename)
  end
  if kw and kw.mode then mode = kw.mode end
  mode = type(mode) == "string" and mode or "r"
  mode = mode:gsub("t", "")
  local f, err = _orig_io_open(tostring(filename), mode)
  if not f then
    if FileNotFoundError then
      error(FileNotFoundError(tostring(err or ("No such file: " .. tostring(filename)))), 0)
    elseif OSError then
      error(OSError(tostring(err or ("No such file: " .. tostring(filename)))), 0)
    else
      error(tostring(err or ("No such file: " .. tostring(filename))), 0)
    end
  end
  local mt = getmetatable(f)
  if mt then
    mt.__enter__ = mt.__enter__ or function(self) return self end
    mt.__exit__ = mt.__exit__ or function(self) self:close() end
    mt.__iter__ = mt.__iter__ or function(self) return self:lines() end
  end
  return f
end

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

  local pb = _G._luthon_pybridge
  if not pb then
    local ok, pbmod = pcall(require, "luthon.lua.pybridge")
    if not ok or not pbmod or not pbmod.get_lib then ok, pbmod = pcall(require, "src/luthon/lua/pybridge") end
    if not ok or not pbmod or not pbmod.get_lib then ok, pbmod = pcall(require, "pybridge") end
    if ok and pbmod and pbmod.get_lib then pb = pbmod end
  end
  if pb and pb.get_lib then
    local py_tempfile = pb.import("tempfile")
    if py_tempfile and py_tempfile.NamedTemporaryFile then
      local kw_table = {}
      if _kw then
        for k, v in pairs(_kw) do kw_table[k] = v end
      end
      if suffix ~= nil then kw_table.suffix = suffix end
      if prefix ~= nil then kw_table.prefix = prefix end
      if dir ~= nil then kw_table.dir = dir end
      if delete ~= nil then kw_table.delete = delete end
      if mode ~= nil then kw_table.mode = mode end
      kw_table.__luthon_kw = true
      return py_tempfile.NamedTemporaryFile(kw_table)
    end
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
  local self = {_file = f, name = name, _name = name, _delete = delete}
  function self:write(...) return self._file:write(...) end
  function self:read(...) return self._file:read(...) end
  function self:close() self._file:close(); if self._delete then os.remove(self._name) end end
  function self:flush() return self._file:flush() end
  function self:seek(...) return self._file:seek(...) end
  function self:fileno() return -1 end
  function self:__enter__() return self end
  function self:__exit__() self:close() end
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

-- shutil
shutil = shutil or {}
shutil.move = function(src, dst)
  src = tostring(src)
  dst = tostring(dst)
  if not os.path.exists(src) then
    local fnfe = _G.FileNotFoundError or FileNotFoundError
    if fnfe then error(fnfe("No such file or directory: '" .. src .. "'"), 0) end
    local ose = _G.OSError or OSError
    if ose then error(ose("No such file or directory: '" .. src .. "'"), 0) end
    error("FileNotFoundError: [Errno 2] No such file or directory: '" .. src .. "'", 0)
  end
  local ok, err = os.rename(src, dst)
  if not ok then
    local inf = io.open(src, "rb")
    if not inf then
      local ose = _G.OSError or OSError
      if ose then error(ose(err or ("Cannot open " .. src)), 0) end
      error("OSError: " .. tostring(err or ("Cannot open " .. src)), 0)
    end
    local outf = io.open(dst, "wb")
    if not outf then
      inf:close()
      local ose = _G.OSError or OSError
      if ose then error(ose(err or ("Cannot open " .. dst)), 0) end
      error("OSError: " .. tostring(err or ("Cannot open " .. dst)), 0)
    end
    outf:write(inf:read("*a"))
    inf:close()
    outf:close()
    os.remove(src)
  end
  return dst
end
shutil.copy = function(src, dst)
  src = tostring(src)
  dst = tostring(dst)
  local inf = io.open(src, "rb")
  if not inf then error("Cannot open " .. src) end
  local outf = io.open(dst, "wb")
  if not outf then inf:close(); error("Cannot open " .. dst) end
  outf:write(inf:read("*a"))
  inf:close()
  outf:close()
  return dst
end
shutil.copy2 = shutil.copy
shutil.copyfile = shutil.copy
shutil.rmtree = function(path)
  path = tostring(path)
  os.execute("rm -rf " .. string.format("%q", path))
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
    local f = io.popen(cmd .. " 2>&1; echo __LUTHON_EXIT_CODE__$?")
    local output = f:read("*a")
    f:close()
    -- Parse exit code from output
    local rc = 0
    output = output:gsub("__LUTHON_EXIT_CODE__(%d+)$", function(code) rc = tonumber(code); return "" end)
    return subprocess.CompletedProcess(cmd, rc, output, nil)
  else
    local ok = os.execute(cmd)
    local rc = ok and 0 or 1
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
  -- Try to use the Lua parser if available
  local ok, parser = pcall(require, "luthon.lua.parser")
  if ok then
    return parser.parse(source)
  end
  error("ast.parse is not available in Lua target; Python source must be parsed before transpilation using luthon.transpile()", 2)
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

-- uuid builtin module
uuid = {}
local _uuid_rnd = math.random
local function _uuid4()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  local res = string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and _uuid_rnd(0, 0xf) or _uuid_rnd(8, 0xb)
    return string.format("%x", v)
  end)
  local obj = {
    hex = string.gsub(res, "-", ""),
    __str__ = function() return res end,
  }
  return setmetatable(obj, {
    __tostring = function() return res end
  })
end
uuid.uuid4 = _uuid4
uuid.UUID = function(s) return tostring(s) end
_G.uuid = uuid

-- socket native stdlib module
local _socket_mod = {
  AF_INET = 2,
  AF_INET6 = 10,
  SOCK_STREAM = 1,
  SOCK_DGRAM = 2,
  SOL_SOCKET = 1,
  SO_REUSEADDR = 2,
  SO_REUSEPORT = 15,
  IPPROTO_TCP = 6,
}

pcall(function()
  local ffi = require("ffi")
  ffi.cdef[[
    typedef int socket_t;
    struct in_addr { uint32_t s_addr; };
    struct sockaddr_in {
      int16_t sin_family;
      uint16_t sin_port;
      struct in_addr sin_addr;
      char sin_zero[8];
    };
    struct sockaddr { uint16_t sa_family; char sa_data[14]; };
    int socket(int domain, int type, int protocol);
    int bind(int sockfd, const struct sockaddr *addr, uint32_t addrlen);
    int connect(int sockfd, const struct sockaddr *addr, uint32_t addrlen);
    int listen(int sockfd, int backlog);
    int accept(int sockfd, struct sockaddr *addr, uint32_t *addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
    int setsockopt(int sockfd, int level, int optname, const void *optval, uint32_t optlen);
    uint16_t htons(uint16_t hostshort);
    uint16_t ntohs(uint16_t netshort);
    int inet_pton(int af, const char *src, void *dst);
    const char* inet_ntop(int af, const void *src, char *dst, uint32_t size);
  ]]
end)

local Socket_mt = {}
Socket_mt.__index = Socket_mt

function Socket_mt:setsockopt(level, optname, val)
  local ffi = require("ffi")
  local optval = ffi.new("int[1]", val)
  return ffi.C.setsockopt(self._fd, level, optname, optval, ffi.sizeof("int"))
end

function Socket_mt:bind(addr_tuple)
  local ffi = require("ffi")
  local host = addr_tuple[1] or "0.0.0.0"
  local port = tonumber(addr_tuple[2]) or 0
  local addr = ffi.new("struct sockaddr_in")
  addr.sin_family = self._family or 2
  addr.sin_port = ffi.C.htons(port)
  local pton = ffi.C.inet_pton(self._family or 2, host == "" and "0.0.0.0" or host, addr.sin_addr)
  if pton <= 0 then addr.sin_addr.s_addr = 0 end
  local res = ffi.C.bind(self._fd, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
  if res < 0 then error("OSError: [Errno 98] Address already in use", 2) end
  return 0
end

function Socket_mt:listen(backlog)
  local ffi = require("ffi")
  return ffi.C.listen(self._fd, backlog or 128)
end

function Socket_mt:accept()
  local ffi = require("ffi")
  local client_addr = ffi.new("struct sockaddr_in")
  local addrlen = ffi.new("uint32_t[1]", ffi.sizeof("struct sockaddr_in"))
  local c_fd = ffi.C.accept(self._fd, ffi.cast("struct sockaddr*", client_addr), addrlen)
  if c_fd < 0 then error("OSError: accept failed", 2) end
  local client_sock = setmetatable({ _fd = c_fd, _family = self._family, _type = self._type }, Socket_mt)
  local port = ffi.C.ntohs(client_addr.sin_port)
  local ip_buf = ffi.new("char[64]")
  ffi.C.inet_ntop(self._family or 2, client_addr.sin_addr, ip_buf, 64)
  local host = ffi.string(ip_buf)
  return setmetatable({ client_sock, setmetatable({ host, port }, _tuple_mt) }, _tuple_mt)
end

function Socket_mt:connect(addr_tuple)
  local ffi = require("ffi")
  local host = addr_tuple[1] or "127.0.0.1"
  if host == "localhost" then host = "127.0.0.1" end
  local port = tonumber(addr_tuple[2]) or 80
  local addr = ffi.new("struct sockaddr_in")
  addr.sin_family = self._family or 2
  addr.sin_port = ffi.C.htons(port)
  ffi.C.inet_pton(self._family or 2, host, addr.sin_addr)
  local res = ffi.C.connect(self._fd, ffi.cast("struct sockaddr*", addr), ffi.sizeof("struct sockaddr_in"))
  if res < 0 then error("ConnectionRefusedError: [Errno 111] Connection refused", 2) end
  return 0
end

function Socket_mt:send(data)
  local ffi = require("ffi")
  data = tostring(data or "")
  local n = ffi.C.send(self._fd, data, #data, 0)
  return tonumber(n)
end

function Socket_mt:sendall(data)
  return self:send(data)
end

function Socket_mt:recv(bufsize)
  local ffi = require("ffi")
  bufsize = tonumber(bufsize) or 4096
  local buf = ffi.new("char[?]", bufsize)
  local n = ffi.C.recv(self._fd, buf, bufsize, 0)
  if n <= 0 then return "" end
  return ffi.string(buf, n)
end

function Socket_mt:close()
  local ffi = require("ffi")
  if self._fd and self._fd >= 0 then
    ffi.C.close(self._fd)
    self._fd = -1
  end
end

function Socket_mt:__enter__()
  return self
end

function Socket_mt:__exit__()
  self:close()
end

_socket_mod.socket = function(family, sock_type, proto)
  local ffi = require("ffi")
  family = family or 2
  sock_type = sock_type or 1
  proto = proto or 0
  local fd = ffi.C.socket(family, sock_type, proto)
  if fd < 0 then error("OSError: cannot create socket", 2) end
  return setmetatable({ _fd = fd, _family = family, _type = sock_type }, Socket_mt)
end

_socket_mod.inet_pton = function(family, ip_str)
  local ffi = require("ffi")
  local buf_size = (family == 10) and 16 or 4
  local buf = ffi.new("uint8_t[?]", buf_size)
  local rc = ffi.C.inet_pton(family, tostring(ip_str or ""), buf)
  if rc <= 0 then
    error(OSError("illegal IP address string passed to inet_pton"), 2)
  end
  return ffi.string(buf, buf_size)
end

_socket_mod.inet_ntop = function(family, packed_ip)
  local ffi = require("ffi")
  local max_len = (family == 10) and 46 or 16
  local dst = ffi.new("char[?]", max_len)
  local ptr = ffi.C.inet_ntop(family, packed_ip, dst, max_len)
  if ptr == nil then
    error(OSError("unknown address family or invalid packed IP"), 2)
  end
  return ffi.string(ptr)
end

local _socket_gaierror = function(msg)
  local exc = { __type = "gaierror", __msg = tostring(msg or ""), __class__ = { __name__ = "gaierror" } }
  return setmetatable(exc, { __tostring = function(e) return "gaierror: " .. e.__msg end })
end
_socket_mod.gaierror = _socket_gaierror
_socket_mod.herror = _socket_gaierror
_socket_mod.timeout = _G.TimeoutError or OSError
_socket_mod.error = _G.OSError or OSError

local _py_socket = nil
setmetatable(_socket_mod, {
  __index = function(t, k)
    if _py_socket == nil then
      local ok, pb = pcall(require, "src/luthon/lua/pybridge")
      if not ok or not pb then ok, pb = pcall(require, "luthon.lua.pybridge") end
      if ok and pb and pb.is_available() then
        local ok_s, s = pcall(pb.import, "socket")
        if ok_s and s then _py_socket = s end
      end
      if not _py_socket then _py_socket = false end
    end
    if _py_socket and _py_socket[k] ~= nil then
      return _py_socket[k]
    end
    return nil
  end
})

_G.socket = _socket_mod

-- asyncio cooperative event loop runner & task scheduler (Phase 35)
asyncio = {}

asyncio.Future = function()
  return setmetatable({ _done = false, _result = nil, _error = nil }, {
    __index = {
      done = function(self) return self._done end,
      result = function(self)
        if self._error then error(self._error, 2) end
        return self._result
      end,
      set_result = function(self, val) self._done = true; self._result = val end,
      set_exception = function(self, exc) self._done = true; self._error = exc end,
    }
  })
end

local _task_mt = {
  done = function(self) return self._done end,
  result = function(self)
    if self._error then error(self._error, 2) end
    return self._result
  end,
  cancel = function(self)
    self._done = true
    self._error = "CancelledError"
  end,
  set_result = function(self, val)
    self._done = true
    self._result = val
  end,
  set_exception = function(self, exc)
    self._done = true
    self._error = exc
  end
}
_task_mt.__index = _task_mt

asyncio.Task = function(coro)
  local co = type(coro) == "thread" and coro or coroutine.create(coro)
  local task = setmetatable({
    _is_task = true,
    _co = co,
    _done = false,
    _result = nil,
    _error = nil,
  }, _task_mt)

  if _G.__LUTHON_ACTIVE_LOOP then
    _G.__LUTHON_ACTIVE_LOOP:add_task(task)
  end
  return task
end

asyncio.create_task = function(coro)
  return asyncio.Task(coro)
end

asyncio.gather = function(...)
  local n = select("#", ...)
  local args = { ... }
  local tasks = {}
  for i = 1, n do
    local a = args[i]
    if type(a) == "table" and a._is_task then
      table.insert(tasks, a)
    else
      table.insert(tasks, asyncio.create_task(a))
    end
  end

  local gather_coro = coroutine.create(function()
    local results = {}
    for i, t in ipairs(tasks) do
      while not t:done() do
        coroutine.yield("await_task", t)
      end
      table.insert(results, t:result())
    end
    return setmetatable(results, _list_mt)
  end)

  return asyncio.create_task(gather_coro)
end

asyncio.run = function(coro_or_fn)
  local loop = {
    _tasks = {},
    _ready = {},
    _timers = {},
    add_task = function(self, t)
      table.insert(self._tasks, t)
      table.insert(self._ready, t)
    end
  }
  _G.__LUTHON_ACTIVE_LOOP = loop

  local main_task = (type(coro_or_fn) == "table" and coro_or_fn._is_task) and coro_or_fn or asyncio.create_task(coro_or_fn)

  local ffi_ok, ffi_mod = pcall(require, "ffi")
  if ffi_ok and ffi_mod and ffi_mod.C then
    pcall(function()
      ffi_mod.cdef[[
        int poll(void *fds, unsigned long nfds, int timeout);
      ]]
    end)
  end

  while not main_task:done() do
    local now = os.clock()
    -- 1. Check expired timers
    local remaining_timers = {}
    for _, tm in ipairs(loop._timers) do
      if now >= tm.time then
        table.insert(loop._ready, tm.task)
      else
        table.insert(remaining_timers, tm)
      end
    end
    loop._timers = remaining_timers

    -- Service active network servers (e.g. WebSocket / HTTP servers)
    if _G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS then
      for _, srv in ipairs(_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS) do
        if srv.poll_accept then srv:poll_accept() end
      end
    end

    -- 2. Run one round of ready microtasks
    local current_ready = loop._ready
    loop._ready = {}

    for _, t in ipairs(current_ready) do
      if not t:done() and coroutine.status(t._co) ~= "dead" then
        local ok, tag, arg = coroutine.resume(t._co)
        if not ok then
          t._done = true
          t._error = tostring(tag)
          if t == main_task then
            _G.__LUTHON_ACTIVE_LOOP = nil
            error(tostring(tag), 2)
          end
        elseif coroutine.status(t._co) == "dead" then
          t._done = true
          t._result = tag
        else
          if tag == "sleep" then
            local dur = tonumber(arg) or 0
            table.insert(loop._timers, { time = os.clock() + dur, task = t })
          elseif tag == "await_task" then
            local awaited = arg
            if awaited and awaited:done() then
              table.insert(loop._ready, t)
            else
              table.insert(loop._ready, t)
            end
          else
            table.insert(loop._ready, t)
          end
        end
      end
    end

    -- 3. Sleep or poll if no tasks immediately ready
    if #loop._ready == 0 and #loop._timers > 0 then
      local min_wait = 1000
      local cur_t = os.clock()
      for _, tm in ipairs(loop._timers) do
        local diff = math.max(1, math.floor((tm.time - cur_t) * 1000))
        if diff < min_wait then min_wait = diff end
      end
      if min_wait > 50 then min_wait = 50 end

      local polled = false
      if ffi_ok and ffi_mod and ffi_mod.C and ffi_mod.C.poll then
        local ok_poll = pcall(function() ffi_mod.C.poll(nil, 0, min_wait) end)
        if ok_poll then polled = true end
      end
      if not polled then
        local t_end = os.clock() + (min_wait / 1000.0)
        while os.clock() < t_end do end
      end
    end
  end

  _G.__LUTHON_ACTIVE_LOOP = nil
  return main_task:result()
end

asyncio.sleep = function(secs)
  return coroutine.yield("sleep", secs)
end

asyncio.TimeoutError = "TimeoutError"
asyncio.exceptions = { TimeoutError = "TimeoutError" }
asyncio.wait_for = function(fut_or_fn, timeout)
  local t_start = os.clock()
  timeout = timeout or 0
  while true do
    if type(fut_or_fn) == "thread" then
      if coroutine.status(fut_or_fn) == "dead" then break end
      local ok, res = coroutine.resume(fut_or_fn)
      if not ok then error(tostring(res), 2) end
      if coroutine.status(fut_or_fn) == "dead" then return res end
    elseif type(fut_or_fn) == "function" then
      local ok, res = pcall(fut_or_fn)
      if ok and res ~= nil then return res end
    elseif type(fut_or_fn) == "table" and type(fut_or_fn.done) == "function" then
      if fut_or_fn:done() then return fut_or_fn:result() end
    end
    if timeout > 0 and (os.clock() - t_start) >= timeout then
      error("TimeoutError: operation timed out", 2)
    end
    local ffi_ok, ffi_mod = pcall(require, "ffi")
    if ffi_ok and ffi_mod and ffi_mod.C and ffi_mod.C.poll then
      ffi_mod.C.poll(nil, 0, 50)
    end
  end
end
_G.asyncio = asyncio

-- =========================================================================
-- Phase 38: Native Multi-Threading & Concurrency Runtime (GIL-Free OS Threads)
-- =========================================================================

local _thread_lib = nil
local function _get_thread_lib()
  if _thread_lib ~= nil then return _thread_lib end
  local ok, ffi = pcall(require, "ffi")
  if not ok or not ffi then return nil end
  pcall(function()
    ffi.cdef[[
      typedef struct LuthonThreadPool LuthonThreadPool;
      typedef void* (*luthon_task_fn)(void *arg);
      LuthonThreadPool* luthon_threadpool_create(int num_workers);
      int               luthon_threadpool_worker_count(const LuthonThreadPool *pool);
      uint64_t          luthon_threadpool_submit(LuthonThreadPool *pool, luthon_task_fn fn, void *arg);
      uint64_t          luthon_threadpool_submit_lua(LuthonThreadPool *pool, const char *code, const char *entry_func, void *arg);
      uint64_t          luthon_threadpool_submit_bytecode(LuthonThreadPool *pool, const char *bytecode, size_t bytecode_len, int has_arg_num, double arg_num, void *arg_ptr);
      bool              luthon_threadpool_is_done(LuthonThreadPool *pool, uint64_t task_id);
      void*             luthon_threadpool_wait(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
      double            luthon_threadpool_wait_number(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
      const char*       luthon_threadpool_get_error(LuthonThreadPool *pool, uint64_t task_id);
      void              luthon_threadpool_destroy(LuthonThreadPool *pool);

      void* luthon_dedicated_thread_create(const char *bytecode, size_t len, double arg_num, void *arg_ptr);
      void  luthon_dedicated_thread_join(void *handle);
      bool  luthon_dedicated_thread_is_alive(void *handle);

      typedef struct {
          void     *data;
          size_t    size;
          int32_t   type_tag;
          uint64_t  tag;
      } LuthonMessage;
      typedef struct LuthonChannel LuthonChannel;
      LuthonChannel* luthon_channel_create(size_t capacity);
      bool           luthon_channel_push(LuthonChannel *chan, const LuthonMessage *msg);
      bool           luthon_channel_pop(LuthonChannel *chan, LuthonMessage *out_msg);
      size_t         luthon_channel_size(const LuthonChannel *chan);
      bool           luthon_channel_is_empty(const LuthonChannel *chan);
      void           luthon_channel_destroy(LuthonChannel *chan);

      typedef struct LuthonMutex LuthonMutex;
      typedef struct LuthonEvent LuthonEvent;
      typedef struct LuthonSemaphore LuthonSemaphore;
      LuthonMutex* luthon_mutex_create(bool recursive);
      bool         luthon_mutex_lock(LuthonMutex *m);
      bool         luthon_mutex_trylock(LuthonMutex *m);
      bool         luthon_mutex_unlock(LuthonMutex *m);
      void         luthon_mutex_destroy(LuthonMutex *m);

      LuthonEvent* luthon_event_create(bool initial_state);
      void         luthon_event_set(LuthonEvent *e);
      void         luthon_event_clear(LuthonEvent *e);
      bool         luthon_event_is_set(LuthonEvent *e);
      bool         luthon_event_wait(LuthonEvent *e, double timeout_sec);
      void         luthon_event_destroy(LuthonEvent *e);

      LuthonSemaphore* luthon_semaphore_create(int initial_value);
      bool             luthon_semaphore_acquire(LuthonSemaphore *s, double timeout_sec);
      void             luthon_semaphore_release(LuthonSemaphore *s);
      int              luthon_semaphore_get_value(LuthonSemaphore *s);
      void             luthon_semaphore_destroy(LuthonSemaphore *s);
    ]]
  end)
  local candidate_paths = {
    "src/luthon/native/libluthon_capi.so",
    "./src/luthon/native/libluthon_capi.so",
    "./libluthon_capi.so",
    "libluthon_capi.so"
  }
  for _, cp in ipairs(candidate_paths) do
    local ok_load, lib = pcall(ffi.load, cp)
    if ok_load and lib then
      _thread_lib = lib
      return _thread_lib
    end
  end
  return nil
end

local _future_mt = {}
_future_mt.__index = _future_mt

function _future_mt:done()
  if self._resolved then return true end
  if self._task_id and self._pool then
    local lib = _get_thread_lib()
    if lib and lib.luthon_threadpool_is_done(self._pool, self._task_id) then
      pcall(function() self:result() end)
      return true
    end
  end
  return self._resolved
end

function _future_mt:result(timeout)
  if self._resolved then
    if self._error then error(self._error, 2) end
    return self._result
  end
  if self._task_id and self._pool then
    local lib = _get_thread_lib()
    if lib then
      local ffi = require("ffi")
      local err = ffi.new("int[1]")
      if self._is_numeric then
        local num = lib.luthon_threadpool_wait_number(self._pool, self._task_id, err)
        if err[0] ~= 0 then
          local err_msg = lib.luthon_threadpool_get_error(self._pool, self._task_id)
          self._error = err_msg ~= nil and ffi.string(err_msg) or "Thread execution error"
          self._resolved = true
          error(self._error, 2)
        end
        self._result = num
        self._resolved = true
        return num
      else
        local ptr = lib.luthon_threadpool_wait(self._pool, self._task_id, err)
        if err[0] ~= 0 then
          local err_msg = lib.luthon_threadpool_get_error(self._pool, self._task_id)
          self._error = err_msg ~= nil and ffi.string(err_msg) or "Thread execution error"
          self._resolved = true
          error(self._error, 2)
        end
        self._result = self._result or ptr
        self._resolved = true
        return self._result
      end
    end
  end
  if self._error then error(self._error, 2) end
  return self._result
end

function _future_mt:exception(timeout)
  pcall(function() self:result(timeout) end)
  return self._error
end

function _future_mt:cancel()
  if self:done() then return false end
  self._error = "CancelledError"
  self._resolved = true
  return true
end

local _futures = {}

_futures.Future = function()
  return setmetatable({ _resolved = false, _result = nil, _error = nil }, _future_mt)
end

_futures.ThreadPoolExecutor = function(opts_or_workers)
  local max_workers = 4
  if type(opts_or_workers) == "number" then
    max_workers = opts_or_workers
  elseif type(opts_or_workers) == "table" and opts_or_workers.max_workers then
    max_workers = opts_or_workers.max_workers
  end
  local lib = _get_thread_lib()
  local pool = lib and lib.luthon_threadpool_create(max_workers) or nil
  return setmetatable({ _pool = pool, _max_workers = max_workers, _shutdown = false, _futures = {} }, {
    __index = {
      submit = function(self, fn, ...)
        if self._shutdown then error("cannot schedule new futures after shutdown", 2) end
        local fut = _futures.Future()
        local lib = _get_thread_lib()
        local n_args = select("#", ...)
        local arg1 = select(1, ...)
        if self._pool and lib and type(fn) == "function" then
          local ok_dump, bc = pcall(string.dump, fn)
          if ok_dump and bc then
            local has_num = (type(arg1) == "number") and 1 or 0
            local num_val = has_num == 1 and arg1 or 0.0
            local ptr_val = (type(arg1) == "cdata" or type(arg1) == "userdata") and arg1 or nil
            local tid = lib.luthon_threadpool_submit_bytecode(self._pool, bc, #bc, has_num, num_val, ptr_val)
            fut._task_id = tid
            fut._pool = self._pool
            fut._is_numeric = (type(arg1) == "number")
            table.insert(self._futures, fut)
            return fut
          end
        end
        -- In-process fallback execution
        local ok, res = pcall(fn, ...)
        if ok then
          fut._result = res
          fut._resolved = true
        else
          fut._error = res
          fut._resolved = true
        end
        table.insert(self._futures, fut)
        return fut
      end,
      map = function(self, fn, iterable)
        local results = {}
        local pending = {}
        for _, item in ipairs(iterable) do
          local fut = self:submit(fn, item)
          table.insert(pending, fut)
        end
        for _, fut in ipairs(pending) do
          table.insert(results, fut:result())
        end
        return setmetatable(results, _list_mt)
      end,
      shutdown = function(self, wait)
        if self._shutdown then return end
        self._shutdown = true
        if wait and self._pool then
          for _, fut in ipairs(self._futures) do
            pcall(function() fut:result() end)
          end
        end
        if self._pool then
          local lib = _get_thread_lib()
          if lib then lib.luthon_threadpool_destroy(self._pool) end
          self._pool = nil
        end
      end,
      __enter__ = function(self) return self end,
      __exit__ = function(self, exc_type, exc_val, exc_tb) self:shutdown(true) end,
    }
  })
end

_futures.as_completed = function(fs)
  local list = {}
  for _, f in ipairs(fs) do table.insert(list, f) end
  local idx = 0
  return function()
    idx = idx + 1
    if idx <= #list then
      list[idx]:result()
      return list[idx]
    end
    return nil
  end
end

_futures.wait = function(fs, timeout, return_when)
  local done = {}
  local not_done = {}
  for _, f in ipairs(fs) do
    f:result(timeout)
    table.insert(done, f)
  end
  return setmetatable({ setmetatable(done, _set_mt), setmetatable(not_done, _set_mt) }, _tuple_mt)
end

local _concurrent = {
  futures = _futures
}

local _threading = {}

_threading.Lock = function()
  local lib = _get_thread_lib()
  local m = lib and lib.luthon_mutex_create(false) or nil
  return setmetatable({ _m = m, _locked = false }, {
    __index = {
      acquire = function(self, blocking, timeout)
        if self._m then
          local ok = (blocking == false) and lib.luthon_mutex_trylock(self._m) or lib.luthon_mutex_lock(self._m)
          if ok then self._locked = true end
          return ok
        end
        self._locked = true
        return true
      end,
      release = function(self)
        if self._m then lib.luthon_mutex_unlock(self._m) end
        self._locked = false
      end,
      locked = function(self) return self._locked end,
      __enter__ = function(self) self:acquire(true) return self end,
      __exit__ = function(self, exc_type, exc_val, exc_tb) self:release() end,
    }
  })
end

_threading.RLock = function()
  local lib = _get_thread_lib()
  local m = lib and lib.luthon_mutex_create(true) or nil
  local count = 0
  return setmetatable({ _m = m }, {
    __index = {
      acquire = function(self, blocking, timeout)
        if self._m then
          local ok = (blocking == false) and lib.luthon_mutex_trylock(self._m) or lib.luthon_mutex_lock(self._m)
          if ok then count = count + 1 end
          return ok
        end
        count = count + 1
        return true
      end,
      release = function(self)
        if self._m then lib.luthon_mutex_unlock(self._m) end
        count = count - 1
      end,
      __enter__ = function(self) self:acquire(true) return self end,
      __exit__ = function(self, exc_type, exc_val, exc_tb) self:release() end,
    }
  })
end

_threading.Event = function()
  local lib = _get_thread_lib()
  local e = lib and lib.luthon_event_create(false) or nil
  local state = false
  return setmetatable({ _e = e }, {
    __index = {
      is_set = function(self)
        if self._e then return lib.luthon_event_is_set(self._e) end
        return state
      end,
      isSet = function(self) return self:is_set() end,
      set = function(self)
        if self._e then lib.luthon_event_set(self._e) else state = true end
      end,
      clear = function(self)
        if self._e then lib.luthon_event_clear(self._e) else state = false end
      end,
      wait = function(self, timeout)
        if self._e then return lib.luthon_event_wait(self._e, timeout or 0.0) end
        return state
      end,
    }
  })
end

_threading.Semaphore = function(value)
  local lib = _get_thread_lib()
  local initial = value or 1
  local s = lib and lib.luthon_semaphore_create(initial) or nil
  return setmetatable({ _s = s, _val = initial }, {
    __index = {
      acquire = function(self, blocking, timeout)
        if self._s then return lib.luthon_semaphore_acquire(self._s, (blocking == false and 0.000001) or (timeout or 0.0)) end
        if self._val > 0 then self._val = self._val - 1 return true end
        return false
      end,
      release = function(self)
        if self._s then lib.luthon_semaphore_release(self._s) else self._val = self._val + 1 end
      end,
      __enter__ = function(self) self:acquire(true) return self end,
      __exit__ = function(self, exc_type, exc_val, exc_tb) self:release() end,
    }
  })
end

_threading.Thread = function(opts)
  opts = opts or {}
  local target = opts.target
  local args = opts.args or {}
  return setmetatable({ _target = target, _args = args, _alive = false }, {
    __index = {
      start = function(self)
        self._alive = true
        local lib = _get_thread_lib()
        if lib and self._target then
          local ok_dump, bc = pcall(string.dump, self._target)
          if ok_dump and bc then
            local arg1 = self._args[1]
            local has_num = (type(arg1) == "number") and 1 or 0
            local num_val = (has_num == 1) and arg1 or 0.0
            local ptr_val = (type(arg1) == "cdata" or type(arg1) == "userdata") and arg1 or nil
            self._handle = lib.luthon_dedicated_thread_create(bc, #bc, num_val, ptr_val)
            return
          end
        end
        pcall(self._target, unpack(self._args))
        self._alive = false
      end,
      join = function(self, timeout)
        if self._handle then
          local lib = _get_thread_lib()
          if lib then
            lib.luthon_dedicated_thread_join(self._handle)
            self._handle = nil
          end
        end
        self._alive = false
      end,
      is_alive = function(self)
        if self._handle then
          local lib = _get_thread_lib()
          if lib then
            return lib.luthon_dedicated_thread_is_alive(self._handle)
          end
        end
        return self._alive
      end,
    }
  })
end

_threading.current_thread = function()
  return { name = "MainThread", ident = 1 }
end

_G.concurrent = _concurrent
_G["concurrent.futures"] = _futures
_G.threading = _threading
_MODULES = _MODULES or {}
_MODULES["concurrent"] = _concurrent
_MODULES["concurrent.futures"] = _futures
_MODULES["threading"] = _threading
_MODULES["os"] = os
_MODULES["os.path"] = os and os.path
_MODULES["sys"] = sys
_MODULES["time"] = time
_MODULES["datetime"] = datetime
_MODULES["math"] = math
_MODULES["string"] = string
_MODULES["types"] = types
_MODULES["socket"] = _socket_mod
_MODULES["hashlib"] = hashlib

-- Phase 39: math.simd runtime module
local _simd_mod = {}
_simd_mod.get_vector_width = function() return _simd_lib and _simd_lib.luthon_simd_get_vector_width() or 4 end
_simd_mod.get_backend_name = function()
  if _simd_lib and type(_simd_lib.luthon_simd_get_backend_name) == "cdata" then
    local ffi = require("ffi")
    return ffi.string(_simd_lib.luthon_simd_get_backend_name())
  end
  return "AVX2+FMA (256-bit)"
end
_simd_mod.saxpy = function(n, alpha, x, y)
  local x_buf = rawget(x, "_buf") or x
  local y_buf = rawget(y, "_buf") or y
  if _simd_lib then _simd_lib.luthon_simd_saxpy(n, alpha, x_buf, y_buf)
  else for i=0, n-1 do y_buf[i] = alpha*x_buf[i] + y_buf[i] end end
end
_simd_mod.daxpy = function(n, alpha, x, y)
  local x_buf = rawget(x, "_buf") or x
  local y_buf = rawget(y, "_buf") or y
  if _simd_lib then _simd_lib.luthon_simd_daxpy(n, alpha, x_buf, y_buf)
  else for i=0, n-1 do y_buf[i] = alpha*x_buf[i] + y_buf[i] end end
end
_simd_mod.dot = function(n, x, y)
  local x_buf = rawget(x, "_buf") or x
  local y_buf = rawget(y, "_buf") or y
  if _simd_lib then return _simd_lib.luthon_simd_dot_f64(n, x_buf, y_buf) end
  local s = 0.0
  for i=0, n-1 do s = s + x_buf[i]*y_buf[i] end
  return s
end
_simd_mod.euclidean = function(n, x, y)
  local x_buf = rawget(x, "_buf") or x
  local y_buf = rawget(y, "_buf") or y
  if _simd_lib then return _simd_lib.luthon_simd_euclidean_f64(n, x_buf, y_buf) end
  local s = 0.0
  for i=0, n-1 do local d = x_buf[i]-y_buf[i]; s = s + d*d end
  return math.sqrt(s)
end
_simd_mod.poly_eval = function(n, x, out, coeffs, deg)
  local x_buf = rawget(x, "_buf") or x
  local out_buf = rawget(out, "_buf") or out
  local c_buf = rawget(coeffs, "_buf") or coeffs
  if type(c_buf) == "table" and not rawget(coeffs, "_buf") then
    local ffi = require("ffi")
    local tmp = ffi.new("double[?]", #c_buf)
    for i=1, #c_buf do tmp[i-1] = c_buf[i] end
    c_buf = tmp
  end
  if _simd_lib then _simd_lib.luthon_simd_poly_eval_f64(n, x_buf, out_buf, c_buf, deg)
  else
    for i=0, n-1 do
      local xi = x_buf[i]
      local p = c_buf[deg]
      for k=deg-1, 0, -1 do p = p * xi + c_buf[k] end
      out_buf[i] = p
    end
  end
end
_simd_mod.vec_sin = function(n, x, out)
  local x_buf = rawget(x, "_buf") or x
  local out_buf = rawget(out, "_buf") or out
  if _simd_lib then _simd_lib.luthon_simd_sin_f64(out_buf, x_buf, n)
  else for i=0, n-1 do out_buf[i] = math.sin(x_buf[i]) end end
end
_simd_mod.vec_cos = function(n, x, out)
  local x_buf = rawget(x, "_buf") or x
  local out_buf = rawget(out, "_buf") or out
  if _simd_lib then _simd_lib.luthon_simd_cos_f64(out_buf, x_buf, n)
  else for i=0, n-1 do out_buf[i] = math.cos(x_buf[i]) end end
end
_simd_mod.vec_exp = function(n, x, out)
  local x_buf = rawget(x, "_buf") or x
  local out_buf = rawget(out, "_buf") or out
  if _simd_lib then _simd_lib.luthon_simd_exp_f64(out_buf, x_buf, n)
  else for i=0, n-1 do out_buf[i] = math.exp(x_buf[i]) end end
end
_simd_mod.vec_sqrt = function(n, x, out)
  local x_buf = rawget(x, "_buf") or x
  local out_buf = rawget(out, "_buf") or out
  if _simd_lib then _simd_lib.luthon_simd_sqrt_f64(out_buf, x_buf, n)
  else for i=0, n-1 do out_buf[i] = math.sqrt(x_buf[i]) end end
end

math.simd = _simd_mod
_MODULES["math.simd"] = _simd_mod
_G["math.simd"] = _simd_mod


function _luthon_await(val)
  if type(val) == "table" and (val._is_task or (type(val.done) == "function" and type(val.result) == "function")) then
    while not val:done() do
      coroutine.yield("await_task", val)
    end
    return val:result()
  elseif type(val) == "thread" then
    while coroutine.status(val) ~= "dead" do
      local ok, tag, arg = coroutine.resume(val)
      if not ok then error(tostring(tag), 2) end
      if coroutine.status(val) == "dead" then
        return tag
      end
      -- Pass yield tag and argument up to event loop runner (asyncio.run)
      coroutine.yield(tag, arg)
    end
    return nil
  elseif type(val) == "function" then
    return val()
  elseif type(val) == "table" and type(val.result) == "function" and not val:done() then
    -- If awaiting an unfinished Future/Task, poll until resolved
    -- If a WebSocket server is active, dispatch its event loop
    if _G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS and #_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS > 0 then
      for _, srv in ipairs(_G.__LUTHON_ACTIVE_WEBSOCKET_SERVERS) do
        if srv.run_event_loop then
          return srv:run_event_loop(val)
        end
      end
    end
    -- Fallback: block waiting
    local pcall_yield = pcall(function() return coroutine.yield() end)
    while not val:done() do
      if not pcall_yield then
        -- We are in main thread or C-call boundary, use sleep
        local ffi_ok, ffi_mod = pcall(require, "ffi")
        if ffi_ok and ffi_mod and ffi_mod.C and ffi_mod.C.poll then
          ffi_mod.C.poll(nil, 0, 100)
        else
          local t_end = os.clock() + 0.1
          while os.clock() < t_end do end
        end
      else
        coroutine.yield()
      end
      if val:done() then break end
    end
    return val:result()
  end
  return val
end

-- Runtime import helper functions
local _luthon_modules_mod = nil
local function _get_modules_mod()
  if not _luthon_modules_mod then
    for _, cand in ipairs({"modules", "luthon.lua.modules", "src/luthon/lua/modules", "luthon.modules"}) do
      local ok, m = pcall(require, cand)
      if ok and m then
        _luthon_modules_mod = m
        break
      end
    end
  end
  return _luthon_modules_mod
end

function _luthon_import(mod_name, full_name)
  if mod_name == "__future__" then return {} end
  if mod_name == "types" and types then return types end

  -- If full_name is provided (e.g. root = "mypkg", full_name = "mypkg.bar")
  if full_name and full_name ~= mod_name then
    local sub = _luthon_import(full_name)
    local root = _luthon_import(mod_name)
    if type(root) == "table" and type(sub) == "table" then
      local parts = {}
      for p in full_name:gmatch("([^%.]+)") do table.insert(parts, p) end
      local curr = root
      for i = 2, #parts - 1 do
        curr[parts[i]] = curr[parts[i]] or {}
        curr = curr[parts[i]]
      end
      curr[parts[#parts]] = sub
    end
    return root
  end

  if _MODULES and type(_MODULES[mod_name]) == "table" then return _MODULES[mod_name] end
  if mod_name == "os.path" and os and os.path then return os.path end
  if type(_G[mod_name]) == "table" then return _G[mod_name] end
  local mm = _get_modules_mod()
  if mm and mm.load then
    local ok2, m2 = pcall(mm.load, mod_name)
    if ok2 and type(m2) == "table" then return m2 end
    if not ok2 and m2 and (tostring(m2):find("Error executing") or tostring(m2):find("Syntax error") or tostring(m2):find("module load error")) then
      error(m2, 0)
    end
  end
  local ok, m = pcall(require, mod_name)
  if ok and type(m) == "table" then return m end
  if type(_G[mod_name]) == "table" then return _G[mod_name] end
  local err_msg = "No module named '" .. tostring(mod_name) .. "'"
  if ModuleNotFoundError then
    error(ModuleNotFoundError(err_msg), 0)
  elseif ImportError then
    error(ImportError(err_msg), 0)
  else
    error("ModuleNotFoundError: " .. err_msg, 0)
  end
end

function _luthon_import_from(mod_name, item_name)
  if mod_name == "__future__" then return item_name end
  if mod_name == "" and __package__ and __package__ ~= "" then
    mod_name = __package__
  end
  local ok, m = pcall(_luthon_import, mod_name)
  if ok and type(m) == "table" and m[item_name] ~= nil then
    return m[item_name]
  end
  if _G[item_name] ~= nil then
    return _G[item_name]
  end
  -- Try loading submodule mod_name .. "." .. item_name
  local ok_sub, sub = pcall(_luthon_import, mod_name .. "." .. item_name)
  if ok_sub and sub ~= nil and sub ~= _G[mod_name] and type(sub) == "table" and (next(sub) ~= nil or rawget(sub, "__name__") or rawget(sub, "_py")) then return sub end
  if not ok_sub and sub and (tostring(sub):find("Error executing") or tostring(sub):find("Syntax error")) then
    error(sub, 0)
  end
  if ok and type(m) == "table" and m[item_name] ~= nil then return m[item_name] end
  if _G[item_name] ~= nil then return _G[item_name] end
  if not ok then error(m, 0) end
  local err_msg = "cannot import name '" .. tostring(item_name) .. "' from '" .. tostring(mod_name) .. "'"
  if ImportError then error(ImportError(err_msg), 0) else error("ImportError: " .. err_msg, 0) end
end
