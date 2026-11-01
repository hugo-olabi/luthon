--[[
  Luthon Hybrid Python Bridge (pybridge.lua)
  ===========================================
  Lazy on-demand CPython bridge using LuaJIT FFI to load libpython3.so.
  Provides:
    - Lazy loading of libpython3 on first import/call
    - Transparent type marshaling (nil, bool, int, float, string, list, dict)
    - Opaque pointer passing for complex objects (PyObject*)
    - Python object proxy (PyProxy) with attribute lookup, method invocation,
      call syntax, string conversion, and length operator.
--]]

local ffi = require("ffi")

local pybridge = {}

-- CPython C-API declarations
ffi.cdef[[
  typedef struct _object PyObject;
  typedef struct _typeobject PyTypeObject;
  typedef long Py_ssize_t;

  void* dlopen(const char* filename, int flags);
  void Py_Initialize(void);
  int Py_IsInitialized(void);
  void Py_Finalize(void);

  PyObject* PyImport_ImportModule(const char *name);
  PyObject* PyObject_GetAttrString(PyObject *o, const char *name);
  int PyObject_SetAttrString(PyObject *o, const char *name, PyObject *val);
  int PyObject_HasAttrString(PyObject *o, const char *name);
  PyObject* PyObject_GetItem(PyObject *o, PyObject *key);
  int PyObject_SetItem(PyObject *o, PyObject *key, PyObject *v);
  PyObject* PyObject_CallObject(PyObject *callable, PyObject *args);
  PyObject* PyObject_Str(PyObject *v);
  const char* PyUnicode_AsUTF8AndSize(PyObject *unicode, Py_ssize_t *size);
  Py_ssize_t PyObject_Size(PyObject *o);

  PyObject* PyLong_FromLongLong(long long v);
  long long PyLong_AsLongLong(PyObject *obj);
  PyObject* PyFloat_FromDouble(double v);
  double PyFloat_AsDouble(PyObject *obj);
  PyObject* PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size);
  PyObject* PyBool_FromLong(long v);
  int PyObject_IsTrue(PyObject *o);

  PyObject* PyList_New(Py_ssize_t len);
  int PyList_SetItem(PyObject *list, Py_ssize_t index, PyObject *item);
  Py_ssize_t PyList_Size(PyObject *list);
  PyObject* PyList_GetItem(PyObject *list, Py_ssize_t index);

  PyObject* PyDict_New(void);
  int PyDict_SetItemString(PyObject *dp, const char *key, PyObject *item);
  PyObject* PyDict_GetItemString(PyObject *dp, const char *key);
  Py_ssize_t PyDict_Size(PyObject *dp);
  int PyDict_Next(PyObject *p, Py_ssize_t *ppos, PyObject **pkey, PyObject **pvalue);

  PyObject* PyTuple_New(Py_ssize_t len);
  int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);
  Py_ssize_t PyTuple_Size(PyObject *p);
  PyObject* PyTuple_GetItem(PyObject *p, Py_ssize_t pos);

  extern PyTypeObject PyLong_Type;
  extern PyTypeObject PyFloat_Type;
  extern PyTypeObject PyUnicode_Type;
  extern PyTypeObject PyList_Type;
  extern PyTypeObject PyDict_Type;
  extern PyTypeObject PyTuple_Type;
  extern PyTypeObject PyBool_Type;
  extern PyTypeObject PyBytes_Type;
  extern PyObject _Py_NoneStruct;

  PyObject* PyBytes_FromStringAndSize(const char *v, Py_ssize_t len);
  char* PyBytes_AsString(PyObject *op);
  Py_ssize_t PyBytes_Size(PyObject *op);

  PyTypeObject* PyObject_Type(PyObject *o);
  int PyType_IsSubtype(PyTypeObject *a, PyTypeObject *b);

  void Py_IncRef(PyObject *o);
  void Py_DecRef(PyObject *o);

  PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs);
  PyObject* PySlice_New(PyObject *start, PyObject *stop, PyObject *step);
  PyObject* PyObject_RichCompare(PyObject *v, PyObject *w, int op);

  int PyCallable_Check(PyObject *o);
  PyObject* PyObject_GetIter(PyObject *o);
  PyObject* PyIter_Next(PyObject *o);
  PyObject* PyErr_Occurred(void);
  void PyErr_Clear(void);
  void PyErr_Fetch(PyObject **ptype, PyObject **pvalue, PyObject **ptraceback);
]]

local libpy = nil
local none_ptr = nil

local candidate_libs = {
  "libpython3.14.so.1.0",
  "libpython3.14.so",
  "libpython3.13.so.1.0",
  "libpython3.13.so",
  "libpython3.12.so.1.0",
  "libpython3.12.so",
  "libpython3.11.so.1.0",
  "libpython3.11.so",
  "libpython3.so",
}

function pybridge.get_lib()
  if libpy then return libpy end
  for _, soname in ipairs(candidate_libs) do
    -- Ensure libpython symbols are exported globally for C extensions (RTLD_NOW | RTLD_GLOBAL = 258)
    pcall(function() ffi.C.dlopen(soname, 258) end)
    local ok, lib = pcall(function() return ffi.load(soname) end)
    if ok and lib then
      libpy = lib
      break
    end
  end
  if not libpy then
    error("pybridge: could not locate or load libpython3 shared library", 2)
  end
  if libpy.Py_IsInitialized() == 0 then
    libpy.Py_Initialize()
  end
  none_ptr = ffi.cast("PyObject*", libpy._Py_NoneStruct)
  return libpy
end

function pybridge.is_available()
  local ok, _ = pcall(pybridge.get_lib)
  return ok
end

local function decref(obj)
  if obj ~= nil then
    libpy.Py_DecRef(ffi.cast("PyObject*", obj))
  end
end

local function check_py_error()
  local err = libpy.PyErr_Occurred()
  if err ~= nil then
    local ptype = ffi.new("PyObject*[1]")
    local pval = ffi.new("PyObject*[1]")
    local ptb = ffi.new("PyObject*[1]")
    libpy.PyErr_Fetch(ptype, pval, ptb)
    local msg = "Python error"
    if pval[0] ~= nil then
      local str_obj = libpy.PyObject_Str(pval[0])
      if str_obj ~= nil then
        local sz = ffi.new("Py_ssize_t[1]")
        local s = libpy.PyUnicode_AsUTF8AndSize(str_obj, sz)
        msg = ffi.string(s, sz[0])
        decref(str_obj)
      end
    end
    decref(ptype[0])
    decref(pval[0])
    decref(ptb[0])
    error("pybridge: " .. msg, 3)
  end
end

-- Metatable for Python Object Proxy
local PyProxy = {}
pybridge.PyProxy = PyProxy

local lua_to_py, py_to_lua, make_proxy

PyProxy.__index = function(self, key)
  local cache = rawget(self, "__attr_cache__")
  if cache and cache[key] ~= nil then
    return cache[key]
  end

  pybridge.get_lib()
  local py_attr = libpy.PyObject_GetAttrString(self._py, tostring(key))
  if py_attr ~= nil then
    local res = py_to_lua(py_attr)
    decref(py_attr)
    if type(res) == "table" and res._py and libpy.PyCallable_Check(res._py) ~= 0 then
      if not cache then
        cache = {}
        rawset(self, "__attr_cache__", cache)
      end
      cache[key] = res
    end
    return res
  end
  libpy.PyErr_Clear()
  -- If attribute lookup failed, try item access (for dicts, maps, etc.)
  local py_key = lua_to_py(key)
  local py_item = libpy.PyObject_GetItem(self._py, py_key)
  decref(py_key)
  if py_item ~= nil then
    local res = py_to_lua(py_item)
    decref(py_item)
    return res
  end
  libpy.PyErr_Clear()
  return nil
end

PyProxy.__newindex = function(self, key, val)
  local cache = rawget(self, "__attr_cache__")
  if cache then cache[key] = nil end

  pybridge.get_lib()
  local py_val = lua_to_py(val)
  -- Try attribute first, then item
  local rc = libpy.PyObject_SetAttrString(self._py, tostring(key), py_val)
  if rc ~= 0 then
    libpy.PyErr_Clear()
    local py_key = lua_to_py(key)
    rc = libpy.PyObject_SetItem(self._py, py_key, py_val)
    decref(py_key)
  end
  decref(py_val)
  if rc ~= 0 then
    check_py_error()
  end
end

PyProxy.__call = function(self, ...)
  pybridge.get_lib()
  local args = {...}
  -- If self is a bound method and the first argument is identical to its __self__, drop it
  local self_obj = libpy.PyObject_GetAttrString(self._py, "__self__")
  if self_obj ~= nil then
    if #args > 0 and type(args[1]) == "table" and args[1]._py == self_obj then
      table.remove(args, 1)
    end
    decref(self_obj)
  else
    libpy.PyErr_Clear()
  end
  -- If calling exec() with only 1 argument from LuaJIT, CPython's PyEval_GetGlobals()
  -- fails because there is no Python execution frame on the C call stack.
  -- Provide default empty globals dict if calling exec with 1 argument.
  local py_name = nil
  local name_obj = libpy.PyObject_GetAttrString(self._py, "__name__")
  if name_obj ~= nil then
    local size = ffi.new("Py_ssize_t[1]")
    local s = libpy.PyUnicode_AsUTF8AndSize(name_obj, size)
    if s ~= nil then py_name = ffi.string(s, size[0]) end
    decref(name_obj)
  else
    libpy.PyErr_Clear()
  end
  if py_name == "exec" and #args == 1 then
    args = {args[1], {}}
  end

  local total_args = select("#", ...)
  -- Check if Luthon padded calling convention with kwargs table was used:
  -- e.g. fn(arg1, nil, nil, nil, nil, {kw = val})
  local py_kwargs = nil
  local last_arg = total_args > 0 and select(total_args, ...) or nil
  if total_args >= 2 and type(last_arg) == "table" and not last_arg._py and not (getmetatable(last_arg) and getmetatable(last_arg).__tuple__) then
    -- Verify if intermediate args between pos args and last_arg are nils
    local pos_count = 0
    for i = 1, total_args - 1 do
      local a = select(i, ...)
      if a ~= nil then pos_count = i end
    end
    -- It is a kwargs call
    py_kwargs = libpy.PyDict_New()
    for k, val in pairs(last_arg) do
      local py_val = lua_to_py(val)
      libpy.PyDict_SetItemString(py_kwargs, tostring(k), py_val)
      decref(py_val)
    end
    local tuple = libpy.PyTuple_New(pos_count)
    for i = 1, pos_count do
      local py_v = lua_to_py(select(i, ...))
      libpy.PyTuple_SetItem(tuple, i - 1, py_v)
    end
    local res = libpy.PyObject_Call(self._py, tuple, py_kwargs)
    decref(tuple)
    decref(py_kwargs)
    if res == nil then
      check_py_error()
    end
    local lua_res = py_to_lua(res)
    decref(res)
    return lua_res
  end

  local tuple = libpy.PyTuple_New(#args)
  for i, v in ipairs(args) do
    local py_v = lua_to_py(v)
    -- PyTuple_SetItem steals reference
    libpy.PyTuple_SetItem(tuple, i - 1, py_v)
  end
  local res = libpy.PyObject_CallObject(self._py, tuple)
  decref(tuple)
  if res == nil then
    check_py_error()
  end
  local lua_res = py_to_lua(res)
  decref(res)
  return lua_res
end

PyProxy.__len = function(self)
  pybridge.get_lib()
  local sz = libpy.PyObject_Size(self._py)
  if sz < 0 then
    libpy.PyErr_Clear()
    return 0
  end
  return tonumber(sz)
end

PyProxy.__tostring = function(self)
  pybridge.get_lib()
  local str_obj = libpy.PyObject_Str(self._py)
  if str_obj == nil then
    libpy.PyErr_Clear()
    return "<PyObject>"
  end
  local size = ffi.new("Py_ssize_t[1]")
  local s = libpy.PyUnicode_AsUTF8AndSize(str_obj, size)
  local res = ffi.string(s, size[0])
  decref(str_obj)
  return res
end

make_proxy = function(py_obj)
  libpy.Py_IncRef(py_obj)
  local proxy = setmetatable({_py = py_obj}, PyProxy)
  -- Attach GC finalizer
  ffi.gc(py_obj, function(p)
    if libpy and libpy.Py_IsInitialized() ~= 0 then
      libpy.Py_DecRef(p)
    end
  end)
  return proxy
end
pybridge.make_proxy = make_proxy

-- Convert Lua value to PyObject*
lua_to_py = function(v)
  pybridge.get_lib()
  if v == nil then
    libpy.Py_IncRef(none_ptr)
    return none_ptr
  elseif type(v) == "boolean" then
    return libpy.PyBool_FromLong(v and 1 or 0)
  elseif type(v) == "number" then
    if math.floor(v) == v then
      return libpy.PyLong_FromLongLong(v)
    else
      return libpy.PyFloat_FromDouble(v)
    end
  elseif type(v) == "string" then
    return libpy.PyUnicode_FromStringAndSize(v, #v)
  elseif type(v) == "table" then
    if v._py then
      libpy.Py_IncRef(v._py)
      return v._py
    end
    if v.__slice__ then
      local py_lower = v.lower and lua_to_py(v.lower) or nil
      local py_upper = v.upper and lua_to_py(v.upper) or nil
      local py_step = v.step and lua_to_py(v.step) or nil
      local sl = libpy.PySlice_New(py_lower, py_upper, py_step)
      if py_lower then decref(py_lower) end
      if py_upper then decref(py_upper) end
      if py_step then decref(py_step) end
      return sl
    end
    local mt = getmetatable(v)
    if mt and mt.__tuple__ then
      local n = #v
      local tup = libpy.PyTuple_New(n)
      for i = 1, n do
        local item = lua_to_py(v[i])
        libpy.PyTuple_SetItem(tup, i - 1, item)
      end
      return tup
    end
    -- Check if sequential array
    local is_array = true
    local n = #v
    if n > 0 then
      for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > n then
          is_array = false
          break
        end
      end
    else
      is_array = (next(v) == nil)
    end

    if is_array and n > 0 then
      local list = libpy.PyList_New(n)
      for i = 1, n do
        local item = lua_to_py(v[i])
        libpy.PyList_SetItem(list, i - 1, item)
      end
      return list
    else
      local dict = libpy.PyDict_New()
      for k, val in pairs(v) do
        if type(val) ~= "function" and v ~= val then
          local py_val = lua_to_py(val)
          libpy.PyDict_SetItemString(dict, tostring(k), py_val)
          decref(py_val)
        end
      end
      return dict
    end
  elseif type(v) == "function" then
    -- When a Lua function is passed across the bridge to CPython (e.g. decorators), wrap with None
    libpy.Py_IncRef(none_ptr)
    return none_ptr
  end
  error("pybridge: cannot convert Lua type '" .. type(v) .. "' to Python object", 2)
end
pybridge.lua_to_py = lua_to_py

-- Convert PyObject* to Lua value (or proxy for complex types)
py_to_lua = function(py_obj, unwrap_primitives)
  pybridge.get_lib()
  if py_obj == nil or py_obj == none_ptr then
    return nil
  end

  local t = libpy.PyObject_Type(py_obj)
  local is_bool = libpy.PyType_IsSubtype(t, libpy.PyBool_Type) ~= 0
  if is_bool then
    decref(t)
    return libpy.PyObject_IsTrue(py_obj) == 1
  end

  local is_long = libpy.PyType_IsSubtype(t, libpy.PyLong_Type) ~= 0
  if is_long then
    decref(t)
    return tonumber(libpy.PyLong_AsLongLong(py_obj))
  end

  local is_float = libpy.PyType_IsSubtype(t, libpy.PyFloat_Type) ~= 0
  if is_float then
    decref(t)
    return libpy.PyFloat_AsDouble(py_obj)
  end

  local is_str = libpy.PyType_IsSubtype(t, libpy.PyUnicode_Type) ~= 0
  if is_str then
    decref(t)
    local size = ffi.new("Py_ssize_t[1]")
    local s = libpy.PyUnicode_AsUTF8AndSize(py_obj, size)
    return ffi.string(s, size[0])
  end

  if unwrap_primitives then
    local is_list = libpy.PyType_IsSubtype(t, libpy.PyList_Type) ~= 0
    if is_list then
      decref(t)
      local sz = tonumber(libpy.PyList_Size(py_obj))
      local r = {}
      for i = 0, sz - 1 do
        local item = libpy.PyList_GetItem(py_obj, i)
        table.insert(r, py_to_lua(item, true))
      end
      return r
    end

    local is_dict = libpy.PyType_IsSubtype(t, libpy.PyDict_Type) ~= 0
    if is_dict then
      decref(t)
      local r = {}
      local pos = ffi.new("Py_ssize_t[1]", 0)
      local k = ffi.new("PyObject*[1]")
      local v = ffi.new("PyObject*[1]")
      while libpy.PyDict_Next(py_obj, pos, k, v) ~= 0 do
        local lk = py_to_lua(k[0], true)
        local lv = py_to_lua(v[0], true)
        r[lk] = lv
      end
      return r
    end
  end

  decref(t)
  -- Return PyProxy for functions, modules, objects, tensors, etc.
  return make_proxy(py_obj)
end
pybridge.py_to_lua = py_to_lua

-- Import a Python module by name via libpython3
function pybridge.import(name)
  pybridge.get_lib()
  local mod = libpy.PyImport_ImportModule(name)
  if mod == nil then
    check_py_error()
    error("pybridge: failed to import module '" .. name .. "'", 2)
  end
  local proxy = make_proxy(mod)
  decref(mod)
  return proxy
end

return pybridge
