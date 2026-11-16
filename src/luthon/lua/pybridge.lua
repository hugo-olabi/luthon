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

-- Track non-implemented features accessed via PyBridge fallback
local _nyi_features = {}
local _nyi_registered_exit = false

local function _record_nyi_feature(category, name)
  local key = tostring(category) .. ": " .. tostring(name)
  _nyi_features[key] = (_nyi_features[key] or 0) + 1
  if not _nyi_registered_exit then
    _nyi_registered_exit = true
    local guard = newproxy(true)
    getmetatable(guard).__gc = function()
      pybridge.flush_nyi_report()
    end
    _G.__luthon_nyi_exit_guard__ = guard
  end
end

function pybridge.flush_nyi_report()
  local target_file = _G.__file__ or os.getenv("LUTHON_EXECUTED_FILE")
  if not target_file or target_file == "" then return end
  local count = 0
  for _ in pairs(_nyi_features) do count = count + 1 end
  if count == 0 then return end

  -- Path beside the executed file: "<filename>.luthon-nyi"
  local nyi_path = target_file .. ".luthon-nyi"
  local f = io.open(nyi_path, "w")
  if not f then return end

  f:write("# Luthon Fallback NYI Feature Report\n")
  f:write("# The following features were intercepted by pybridge (CPython fallback):\n\n")

  local sorted_keys = {}
  for k in pairs(_nyi_features) do table.insert(sorted_keys, k) end
  table.sort(sorted_keys)

  for _, k in ipairs(sorted_keys) do
    f:write(string.format("- %s (invoked %d time%s)\n", k, _nyi_features[k], _nyi_features[k] == 1 and "" or "s"))
  end
  f:close()
end

-- CPython C-API declarations
ffi.cdef[[
  typedef struct _object PyObject;
  typedef struct _typeobject PyTypeObject;
  typedef long Py_ssize_t;

  void* dlopen(const char* filename, int flags);
  void Py_Initialize(void);
  int Py_IsInitialized(void);
  void Py_Finalize(void);
  int PyRun_SimpleString(const char *s);

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
  PyObject* PyErr_NewException(const char *name, PyObject *base, PyObject *dict);

  PyObject* PyNumber_Add(PyObject *v, PyObject *w);
  PyObject* PyNumber_Subtract(PyObject *v, PyObject *w);
  PyObject* PyNumber_Multiply(PyObject *v, PyObject *w);
  PyObject* PyNumber_TrueDivide(PyObject *v, PyObject *w);
  PyObject* PyNumber_FloorDivide(PyObject *v, PyObject *w);
  PyObject* PyNumber_Remainder(PyObject *v, PyObject *w);
  PyObject* PyNumber_Power(PyObject *v1, PyObject *v2, PyObject *v3);
  PyObject* PyNumber_Negative(PyObject *o);
  int PyObject_RichCompareBool(PyObject *v, PyObject *w, int opid);

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
  local env_lib = os.getenv("LUTHON_LIBPYTHON")
  local libs = {}
  if env_lib and env_lib ~= "" then table.insert(libs, env_lib) end
  for _, l in ipairs(candidate_libs) do table.insert(libs, l) end
  for _, soname in ipairs(libs) do
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
    pcall(function()
      libpy.PyRun_SimpleString([[
import sys, os
venv = os.environ.get("VIRTUAL_ENV") or os.environ.get("CONDA_PREFIX")
if venv:
    for ver in ["3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]:
        sp = os.path.join(venv, "lib", f"python{ver}", "site-packages")
        if os.path.isdir(sp) and sp not in sys.path:
            sys.path.insert(0, sp)
for ver in ["3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]:
    local_sp = os.path.abspath(os.path.join(".", ".venv", "lib", f"python{ver}", "site-packages"))
    if os.path.isdir(local_sp) and local_sp not in sys.path:
        sys.path.insert(0, local_sp)
]])
    end)
  end
  none_ptr = ffi.cast("PyObject*", libpy._Py_NoneStruct)
  return libpy
end

function pybridge.is_available()
  local ok, _ = pcall(pybridge.get_lib)
  return ok
end

-- Ensure an active CPython asyncio event loop exists on this thread if needed
function pybridge.ensure_event_loop()
  pcall(function()
    local lib = pybridge.get_lib()
    if not lib then return end
    libpy.PyRun_SimpleString([[
import asyncio
try:
    asyncio.get_running_loop()
except RuntimeError:
    try:
        _luthon_loop = asyncio.new_event_loop()
        asyncio.set_event_loop(_luthon_loop)
    except Exception:
        pass
]])
  end)
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
    local is_stop_iter = false
    if ptype[0] ~= nil then
      local name_obj = libpy.PyObject_GetAttrString(ptype[0], "__name__")
      if name_obj ~= nil then
        local sz = ffi.new("Py_ssize_t[1]")
        local s = libpy.PyUnicode_AsUTF8AndSize(name_obj, sz)
        if s ~= nil and ffi.string(s, sz[0]) == "StopIteration" then
          is_stop_iter = true
        end
        decref(name_obj)
      end
    end
    if is_stop_iter then
      decref(ptype[0])
      decref(pval[0])
      decref(ptb[0])
      return nil
    end
    local msg = "Python error"
    if pval[0] ~= nil then
      local str_obj = libpy.PyObject_Str(pval[0])
      if str_obj ~= nil then
        local sz = ffi.new("Py_ssize_t[1]")
        local s = libpy.PyUnicode_AsUTF8AndSize(str_obj, sz)
        if s ~= nil then
          msg = ffi.string(s, sz[0])
        end
        decref(str_obj)
      end
    end
    if ptype[0] ~= nil then
      local name_obj = libpy.PyObject_GetAttrString(ptype[0], "__name__")
      if name_obj ~= nil then
        local sz = ffi.new("Py_ssize_t[1]")
        local s = libpy.PyUnicode_AsUTF8AndSize(name_obj, sz)
        if s ~= nil then
          msg = ffi.string(s, sz[0]) .. ": " .. msg
        end
        decref(name_obj)
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

  if type(key) == "string" then
    _record_nyi_feature("attribute", key)
  else
    _record_nyi_feature("item_subscript", type(key) == "table" and (key.__slice__ and "slice" or "tuple_index") or type(key))
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
  local total_args = select("#", ...)
  local args = {}
  for i = 1, total_args do
    args[i] = select(i, ...)
  end

  local dropped_self = false
  local self_obj = libpy.PyObject_GetAttrString(self._py, "__self__")
  if self_obj ~= nil then
    if total_args > 0 and type(args[1]) == "table" and args[1]._py == self_obj then
      table.remove(args, 1)
      total_args = total_args - 1
      dropped_self = true
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
  if py_name == "exec" then
    local code = args[1]
    local globals_dict = args[2] or {}
    local locals_dict = args[3] or globals_dict
    local py_code = lua_to_py(code)
    local py_globals = lua_to_py(globals_dict)
    local py_locals = lua_to_py(locals_dict)
    local tuple = libpy.PyTuple_New(3)
    libpy.PyTuple_SetItem(tuple, 0, py_code)
    libpy.PyTuple_SetItem(tuple, 1, py_globals)
    libpy.PyTuple_SetItem(tuple, 2, py_locals)
    local res = libpy.PyObject_CallObject(self._py, tuple)
    decref(tuple)
    if res == nil then check_py_error() end
    decref(res)
    return nil
  end

  -- Check if Luthon padded calling convention with kwargs table was used:
  -- e.g. fn(arg1, nil, nil, nil, nil, {kw = val})
  local py_kwargs = nil
  local last_arg = total_args > 0 and args[total_args] or nil
  local last_mt = type(last_arg) == "table" and getmetatable(last_arg) or nil
  if total_args >= 2 and type(last_arg) == "table" and not last_arg._py and not (last_mt and (last_mt.__tuple__ or last_mt.__bytes__)) then
    local pos_count = 0
    for i = 1, total_args - 1 do
      if args[i] ~= nil then pos_count = i end
    end
    py_kwargs = libpy.PyDict_New()
    for k, val in pairs(last_arg) do
      local py_val = lua_to_py(val)
      if py_val ~= nil then
        libpy.PyDict_SetItemString(py_kwargs, tostring(k), py_val)
        decref(py_val)
      end
    end
    local tuple = libpy.PyTuple_New(pos_count)
    for i = 1, pos_count do
      local py_v = lua_to_py(args[i])
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

  local tuple = libpy.PyTuple_New(total_args)
  for i = 1, total_args do
    local py_v = lua_to_py(args[i])
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

local function _py_binop(a, b, fn_name)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local py_b = lua_to_py(b)
  local res = libpy[fn_name](py_a, py_b)
  decref(py_a)
  decref(py_b)
  if res == nil then
    check_py_error()
  end
  local lua_res = py_to_lua(res)
  decref(res)
  return lua_res
end

PyProxy.__add = function(a, b) return _py_binop(a, b, "PyNumber_Add") end
PyProxy.__sub = function(a, b) return _py_binop(a, b, "PyNumber_Subtract") end
PyProxy.__mul = function(a, b) return _py_binop(a, b, "PyNumber_Multiply") end
PyProxy.__div = function(a, b) return _py_binop(a, b, "PyNumber_TrueDivide") end
PyProxy.__mod = function(a, b) return _py_binop(a, b, "PyNumber_Remainder") end
PyProxy.__pow = function(a, b)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local py_b = lua_to_py(b)
  local res = libpy.PyNumber_Power(py_a, py_b, none_ptr)
  decref(py_a)
  decref(py_b)
  if res == nil then check_py_error() end
  local lua_res = py_to_lua(res)
  decref(res)
  return lua_res
end
PyProxy.__unm = function(a)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local res = libpy.PyNumber_Negative(py_a)
  decref(py_a)
  if res == nil then check_py_error() end
  local lua_res = py_to_lua(res)
  decref(res)
  return lua_res
end
PyProxy.__eq = function(a, b)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local py_b = lua_to_py(b)
  local res = libpy.PyObject_RichCompareBool(py_a, py_b, 2)
  decref(py_a)
  decref(py_b)
  if res < 0 then
    libpy.PyErr_Clear()
    return false
  end
  return res == 1
end
PyProxy.__lt = function(a, b)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local py_b = lua_to_py(b)
  local res = libpy.PyObject_RichCompareBool(py_a, py_b, 0)
  decref(py_a)
  decref(py_b)
  if res < 0 then check_py_error() end
  return res == 1
end
PyProxy.__le = function(a, b)
  pybridge.get_lib()
  local py_a = lua_to_py(a)
  local py_b = lua_to_py(b)
  local res = libpy.PyObject_RichCompareBool(py_a, py_b, 1)
  decref(py_a)
  decref(py_b)
  if res < 0 then check_py_error() end
  return res == 1
end
PyProxy.__concat = function(a, b)
  return tostring(a) .. tostring(b)
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
lua_to_py = function(v, visited)
  pybridge.get_lib()
  if v == nil or v == _G._luthon_none or (type(v) == "table" and v.__is_none__) then
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
    local py_str = libpy.PyUnicode_FromStringAndSize(v, #v)
    if py_str ~= nil then
      return py_str
    end
    libpy.PyErr_Clear()
    return libpy.PyBytes_FromStringAndSize(v, #v)
  elseif type(v) == "table" then
    if rawget(v, "_py") then
      libpy.Py_IncRef(rawget(v, "_py"))
      return rawget(v, "_py")
    end
    if rawget(v, "_p") and type(rawget(v, "_p")) == "string" and rawget(v, "is_absolute") then
      local py_path_mod = libpy.PyImport_ImportModule("pathlib")
      if py_path_mod ~= nil then
        local py_path_cls = libpy.PyObject_GetAttrString(py_path_mod, "Path")
        decref(py_path_mod)
        if py_path_cls ~= nil then
          local p_str = rawget(v, "_p")
          local py_str = libpy.PyUnicode_FromStringAndSize(p_str, #p_str)
          local tuple = libpy.PyTuple_New(1)
          libpy.PyTuple_SetItem(tuple, 0, py_str)
          local py_path_obj = libpy.PyObject_CallObject(py_path_cls, tuple)
          decref(py_path_cls)
          decref(tuple)
          if py_path_obj ~= nil then return py_path_obj end
          libpy.PyErr_Clear()
        end
      end
    end
    visited = visited or {}
    if visited[v] then
      libpy.Py_IncRef(visited[v])
      return visited[v]
    end

    -- Check if this is a Luthon class
    local is_class = (rawget(v, "__class__") == nil and (rawget(v, "__instance_mt") ~= nil or rawget(v, "__index") == v) and type(rawget(v, "__name__")) == "string")
    if is_class then
      local cls_name = rawget(v, "__name__") or "CustomClass"
      local dotted_name = cls_name:find("%.") and cls_name or ("_luthon." .. cls_name)
      local base_cls = rawget(v, "__base__")
      local is_exc = (cls_name:match("Error$") or cls_name:match("Exception$") or cls_name:match("Failure$") or (type(base_cls) == "table" and tostring(base_cls.__name__):match("Exception|Error|Failure")))
      local py_base = nil
      if base_cls ~= nil and base_cls ~= _G.object then
        py_base = lua_to_py(base_cls, visited)
      end
      local py_cls = nil
      if is_exc then
        py_cls = libpy.PyErr_NewException(dotted_name, py_base, nil)
      else
        local builtins_mod = libpy.PyImport_ImportModule("builtins")
        local type_fn = libpy.PyObject_GetAttrString(builtins_mod, "type")
        local name_py = libpy.PyUnicode_FromStringAndSize(cls_name, #cls_name)
        local bases_tuple
        if py_base ~= nil then
          bases_tuple = libpy.PyTuple_New(1)
          libpy.PyTuple_SetItem(bases_tuple, 0, py_base)
        else
          bases_tuple = libpy.PyTuple_New(0)
        end
        local empty_dict = libpy.PyDict_New()
        local args = libpy.PyTuple_New(3)
        libpy.PyTuple_SetItem(args, 0, name_py)
        libpy.PyTuple_SetItem(args, 1, bases_tuple)
        libpy.PyTuple_SetItem(args, 2, empty_dict)
        py_cls = libpy.PyObject_CallObject(type_fn, args)
        decref(args)
        decref(type_fn)
        decref(builtins_mod)
      end
      if py_cls then
        rawset(v, "_py", py_cls)
        visited[v] = py_cls
        return py_cls
      end
    end

    -- Check if this is an instance of a Luthon class
    local inst_class = rawget(v, "__class__")
    if inst_class and type(inst_class) == "table" and type(rawget(inst_class, "__name__")) == "string" then
      local cls_name = rawget(inst_class, "__name__")
      if cls_name:match("Error$") or cls_name:match("Exception$") or cls_name:match("Failure$") then
        local py_cls = lua_to_py(inst_class, visited)
        local msg = v.message or v.msg or (v.args and v.args[1]) or tostring(v)
        local msg_py = libpy.PyUnicode_FromStringAndSize(tostring(msg), #tostring(msg))
        local args = libpy.PyTuple_New(1)
        libpy.PyTuple_SetItem(args, 0, msg_py)
        local exc_inst = libpy.PyObject_CallObject(py_cls, args)
        decref(args)
        if exc_inst then
          visited[v] = exc_inst
          return exc_inst
        end
      end
    end

    if v.__slice__ then
      local py_lower = v.lower and lua_to_py(v.lower, visited) or nil
      local py_upper = v.upper and lua_to_py(v.upper, visited) or nil
      local py_step = v.step and lua_to_py(v.step, visited) or nil
      local sl = libpy.PySlice_New(py_lower, py_upper, py_step)
      if py_lower then decref(py_lower) end
      if py_upper then decref(py_upper) end
      if py_step then decref(py_step) end
      visited[v] = sl
      return sl
    end
    local mt = getmetatable(v)
    if mt and mt.__bytes__ then
      local data = v[1] or ""
      local b = libpy.PyBytes_FromStringAndSize(data, #data)
      visited[v] = b
      return b
    end
    if mt and mt.__tuple__ then
      local n = #v
      local tup = libpy.PyTuple_New(n)
      visited[v] = tup
      for i = 1, n do
        local item = lua_to_py(v[i], visited)
        libpy.PyTuple_SetItem(tup, i - 1, item)
      end
      return tup
    end
    -- Check if this is an io.BytesIO or stream object with getvalue / read
    if type(v.getvalue) == "function" then
      local val = v:getvalue()
      local io_mod = libpy.PyImport_ImportModule("io")
      local bio_cls = libpy.PyObject_GetAttrString(io_mod, "BytesIO")
      local py_bytes = libpy.PyBytes_FromStringAndSize(val, #val)
      local args = libpy.PyTuple_New(1)
      libpy.PyTuple_SetItem(args, 0, py_bytes)
      local py_bio = libpy.PyObject_CallObject(bio_cls, args)
      decref(args)
      decref(bio_cls)
      decref(io_mod)
      visited[v] = py_bio
      return py_bio
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
      visited[v] = list
      for i = 1, n do
        local item = lua_to_py(v[i], visited)
        libpy.PyList_SetItem(list, i - 1, item)
      end
      return list
    else
      local dict = libpy.PyDict_New()
      visited[v] = dict
      for k, val in pairs(v) do
        if type(k) == "string" and not k:match("^__") then
          if type(val) ~= "function" and type(val) ~= "userdata" and not visited[val] then
            local py_val = lua_to_py(val, visited)
            if py_val ~= nil then
              libpy.PyDict_SetItemString(dict, tostring(k), py_val)
              decref(py_val)
            end
          end
        elseif type(k) ~= "string" and not visited[val] then
          if type(val) ~= "function" and type(val) ~= "userdata" then
            local py_k = lua_to_py(k, visited)
            local py_val = lua_to_py(val, visited)
            libpy.PyObject_SetItem(dict, py_k, py_val)
            decref(py_k)
            decref(py_val)
          end
        end
      end
      return dict
    end
  elseif type(v) == "function" or type(v) == "userdata" then
    -- When a Lua function or opaque userdata is passed across the bridge to CPython, wrap with None
    libpy.Py_IncRef(none_ptr)
    return none_ptr
  elseif type(v) == "cdata" then
    -- If raw PyObject* cdata is passed across the bridge, cast and inc_ref
    local py_ptr = ffi.cast("PyObject*", v)
    libpy.Py_IncRef(py_ptr)
    return py_ptr
  end
  error("pybridge: cannot convert Lua type '" .. type(v) .. "' to Python object", 2)
end
pybridge.lua_to_py = lua_to_py

-- Convert PyObject* to Lua value (or proxy for complex types)
py_to_lua = function(py_obj, unwrap_primitives)
  pybridge.get_lib()
  if py_obj == nil then
    return nil
  end
  if py_obj == none_ptr then
    return _G._luthon_none or nil
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

  local is_bytes = libpy.PyType_IsSubtype(t, libpy.PyBytes_Type) ~= 0
  if is_bytes then
    decref(t)
    local s = libpy.PyBytes_AsString(py_obj)
    local sz = libpy.PyBytes_Size(py_obj)
    return ffi.string(s, sz)
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
  _record_nyi_feature("module", name)
  pybridge.get_lib()
  if name == "asyncio" or name == "websockets" then
    pybridge.ensure_event_loop()
  end
  local mod = libpy.PyImport_ImportModule(name)
  if mod == nil then
    check_py_error()
    error("pybridge: failed to import module '" .. name .. "'", 2)
  end
  if libpy.PyObject_HasAttrString(mod, "__file__") == 0 and libpy.PyObject_HasAttrString(mod, "__version__") == 0 and libpy.PyObject_HasAttrString(mod, "__all__") == 0 then
    local is_empty_ns = (libpy.PyObject_HasAttrString(mod, "__path__") ~= 0)
    if is_empty_ns and name == "libtorrent" then
      decref(mod)
      local err_msg = "No module named '" .. name .. "'"
      if ModuleNotFoundError then error(ModuleNotFoundError(err_msg), 0)
      else error("ModuleNotFoundError: " .. err_msg, 0) end
    end
  end
  local proxy = make_proxy(mod)
  decref(mod)
  return proxy
end

return pybridge
