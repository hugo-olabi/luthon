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

if _G._luthon_pybridge then
  return _G._luthon_pybridge
end

local ffi = require("ffi")

local pybridge = {}
_G._luthon_pybridge = pybridge
package.loaded["pybridge"] = pybridge
package.loaded["luthon.lua.pybridge"] = pybridge
package.loaded["src/luthon/lua/pybridge"] = pybridge

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
  if os.getenv("LUTHON_NYI_DISABLED") == "1" then return end
  local count = 0
  for _ in pairs(_nyi_features) do count = count + 1 end
  if count == 0 then return end

  local nyi_path = os.getenv("LUTHON_NYI_FILE")
  if not nyi_path or nyi_path == "" then
    local target_file = _G.__file__ or os.getenv("LUTHON_EXECUTED_FILE")
    if not target_file or target_file == "" then return end
    nyi_path = target_file .. ".luthon-nyi"
  end

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
  int setenv(const char *name, const char *value, int overwrite);
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
  long PyLong_AsLong(PyObject *obj);
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
  extern PyTypeObject PyType_Type;
  extern PyObject _Py_NoneStruct;

  int PyObject_IsInstance(PyObject *inst, PyObject *cls);
  int PyObject_IsSubclass(PyObject *derived, PyObject *cls);

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

  typedef PyObject *(*PyCFunctionWithKeywords)(PyObject *, PyObject *, PyObject *);
  typedef struct PyMethodDef {
    const char *ml_name;
    PyCFunctionWithKeywords ml_meth;
    int ml_flags;
    const char *ml_doc;
  } PyMethodDef;
  PyObject* PyCFunction_NewEx(PyMethodDef *ml, PyObject *self, PyObject *mod);
  void PyErr_SetString(PyObject *type, const char *message);
  void PyErr_SetObject(PyObject *type, PyObject *value);
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

  local base_py = nil
  local venv = os.getenv("VIRTUAL_ENV") or os.getenv("CONDA_PREFIX")
  if not venv and io.open(".venv/pyvenv.cfg", "r") then
    venv = ".venv"
  end
  local home = os.getenv("HOME") or ""
  if not venv and home ~= "" and io.open(home .. "/Projects/luthon/.venv/pyvenv.cfg", "r") then
    venv = home .. "/Projects/luthon/.venv"
  end
  if venv then
    local cfg = io.open(venv .. "/pyvenv.cfg", "r")
    if cfg then
      local content = cfg:read("*a")
      cfg:close()
      local home_dir = content:match("home%s*=%s*([^\r\n]+)")
      if home_dir then
        base_py = home_dir:match("^(.-)/bin$") or home_dir
        for _, v in ipairs({"3.14", "3.13", "3.12", "3.11", "3.10", "3.9"}) do
          table.insert(libs, base_py .. "/lib/libpython" .. v .. ".so")
          table.insert(libs, base_py .. "/lib/libpython" .. v .. ".so.1.0")
        end
        table.insert(libs, base_py .. "/lib/libpython3.so")
      end
    end
    for _, v in ipairs({"3.14", "3.13", "3.12", "3.11", "3.10", "3.9"}) do
      table.insert(libs, venv .. "/lib/libpython" .. v .. ".so")
      table.insert(libs, venv .. "/lib/libpython" .. v .. ".so.1.0")
    end
  end

  local loaded_soname = nil
  for _, l in ipairs(candidate_libs) do table.insert(libs, l) end
  for _, soname in ipairs(libs) do
    -- Ensure libpython symbols are exported globally for C extensions (RTLD_NOW | RTLD_GLOBAL = 258)
    pcall(function() ffi.C.dlopen(soname, 258) end)
    local ok, lib = pcall(function() return ffi.load(soname) end)
    if ok and lib then
      libpy = lib
      loaded_soname = soname
      break
    end
  end
  if not libpy then
    error("pybridge: could not locate or load libpython3 shared library", 2)
  end
  if libpy.Py_IsInitialized() == 0 then
    if loaded_soname then
      local matched_home = loaded_soname:match("^(.-)/lib[0-9]*/libpython")
      if matched_home and matched_home ~= "" and matched_home ~= "/usr" and matched_home ~= "/usr/local" then
        pcall(function() ffi.C.setenv("PYTHONHOME", matched_home, 0) end)
      end
    end
    libpy.Py_Initialize()
    pcall(function()
      libpy.PyRun_SimpleString([[
import sys, os
try:
    import site
except ImportError:
    site = None

def _add_site_dir(d):
    if not os.path.isdir(d):
        return
    if site and hasattr(site, "addsitedir"):
        site.addsitedir(d)
    if d not in sys.path:
        sys.path.insert(0, d)
    else:
        try:
            sys.path.remove(d)
            sys.path.insert(0, d)
        except ValueError:
            pass

venv = os.environ.get("VIRTUAL_ENV") or os.environ.get("CONDA_PREFIX")
if not venv and os.path.isdir(".venv"):
    venv = os.path.abspath(".venv")
home_env = os.environ.get("HOME", "")
if not venv and home_env and os.path.isdir(os.path.join(home_env, "Projects", "luthon", ".venv")):
    venv = os.path.join(home_env, "Projects", "luthon", ".venv")
if venv:
    for py_bin in [os.path.join(venv, "bin", "python"), os.path.join(venv, "bin", "python3")]:
        if os.path.isfile(py_bin):
            sys.executable = py_bin
            if hasattr(sys, "_base_executable"):
                sys._base_executable = py_bin
            break
    for ver in ["3.16", "3.15", "3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]:
        sp = os.path.join(venv, "lib", f"python{ver}", "site-packages")
        _add_site_dir(sp)
for ver in ["3.16", "3.15", "3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]:
    local_sp = os.path.abspath(os.path.join(".", ".venv", "lib", f"python{ver}", "site-packages"))
    _add_site_dir(local_sp)
if home_env:
    _add_site_dir(os.path.join(home_env, ".luthon", "site-packages"))
    for ver in ["3.16", "3.15", "3.14", "3.13", "3.12"]:
        _add_site_dir(os.path.join(home_env, ".local", "lib", f"python{ver}", "site-packages"))
env_luthon_sp = os.environ.get("LUTHON_SITE_PACKAGES")
if env_luthon_sp:
    _add_site_dir(env_luthon_sp)
pp = os.environ.get("PYTHONPATH")
if pp:
    for p in pp.split(os.pathsep):
        if p and os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)
try:
    import inspect
    class _DummyFrame:
        def __init__(self):
            self.f_locals = {}
            self.f_globals = {}
    _orig_inspect_stack = inspect.stack
    def _safe_inspect_stack(*args, **kwargs):
        try:
            res = _orig_inspect_stack(*args, **kwargs)
            if res and res[0].function == '_safe_inspect_stack':
                res = res[1:]
        except (ValueError, IndexError):
            res = []
        while len(res) < 4:
            res.append(inspect.FrameInfo(_DummyFrame(), '<luthon>', 1, '<module>', ['class Dummy:\n'], 0))
        return res
    inspect.stack = _safe_inspect_stack
except Exception:
    pass
try:
    from twisted.internet import defer
    _orig_add_timeout = defer.Deferred.addTimeout
    def _safe_add_timeout(self, timeout=None, clock=None, *args, **kwargs):
        if timeout is None:
            timeout = 5.0
        if clock is None:
            from twisted.internet import reactor as _reactor
            clock = _reactor
        return _orig_add_timeout(self, timeout, clock, *args, **kwargs)
    defer.Deferred.addTimeout = _safe_add_timeout
except Exception:
    pass
try:
    import gi
    try:
        gi.require_version('Gtk', '3.0')
    except (ValueError, AttributeError):
        pass
    try:
        gi.require_version('Gdk', '3.0')
    except (ValueError, AttributeError):
        pass
except (ImportError, Exception):
    pass
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
    local is_system_exit = false
    local exc_name = ""
    if ptype[0] ~= nil then
      local name_obj = libpy.PyObject_GetAttrString(ptype[0], "__name__")
      if name_obj ~= nil then
        local sz = ffi.new("Py_ssize_t[1]")
        local s = libpy.PyUnicode_AsUTF8AndSize(name_obj, sz)
        if s ~= nil then
          exc_name = ffi.string(s, sz[0])
          if exc_name == "StopIteration" then
            is_stop_iter = true
          elseif exc_name == "SystemExit" then
            is_system_exit = true
          end
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
    if is_system_exit then
      local exit_code = 0
      if pval[0] ~= nil then
        local code_obj = libpy.PyObject_GetAttrString(pval[0], "code")
        if code_obj ~= nil then
          if code_obj == none_ptr then
            exit_code = 0
          else
            local py_long = libpy.PyLong_AsLong(code_obj)
            if py_long ~= -1 or libpy.PyErr_Occurred() == nil then
              exit_code = tonumber(py_long)
            else
              libpy.PyErr_Clear()
              local sz = ffi.new("Py_ssize_t[1]")
              local s = libpy.PyUnicode_AsUTF8AndSize(code_obj, sz)
              if s ~= nil then
                exit_code = ffi.string(s, sz[0])
              else
                exit_code = 1
              end
            end
          end
          decref(code_obj)
        end
      end
      decref(ptype[0])
      decref(pval[0])
      decref(ptb[0])
      if _G.SystemExit then
        error(_G.SystemExit(exit_code), 3)
      else
        error({__type = "SystemExit", code = exit_code}, 3)
      end
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
pybridge.check_py_error = check_py_error

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
    if type(res) == "table" and rawget(res, "_py") and libpy.PyCallable_Check(res._py) ~= 0 then
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

  if type(val) == "function" then
    rawset(self, key, val)
    return
  end

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
    local arg1_py = (total_args > 0 and type(args[1]) == "table") and (rawget(args[1], "_py") or (type(rawget(args[1], "_py")) == "table" and rawget(args[1]._py, "_py"))) or nil
    if type(arg1_py) == "table" and rawget(arg1_py, "_py") then arg1_py = rawget(arg1_py, "_py") end
    if total_args > 0 and type(args[1]) == "table" and (rawget(args[1], "_py") == self_obj or arg1_py == self_obj) then
      table.remove(args, 1)
      total_args = total_args - 1
      dropped_self = true
    end
    decref(self_obj)
  else
    libpy.PyErr_Clear()
    if total_args >= 2 then
      local arg1_py = lua_to_py(args[1])
      if arg1_py ~= nil then
        local t1 = libpy.PyObject_Type(arg1_py)
        local is_type = (libpy.PyType_IsSubtype(t1, libpy.PyType_Type) ~= 0)
        decref(t1)
        if is_type then
          local arg2_py = lua_to_py(args[2])
          if arg2_py ~= nil then
            if libpy.PyObject_IsInstance(arg2_py, arg1_py) == 1 then
              table.remove(args, 1)
              total_args = total_args - 1
              dropped_self = true
            end
            decref(arg2_py)
          else
            libpy.PyErr_Clear()
          end
        end
        decref(arg1_py)
      else
        libpy.PyErr_Clear()
      end
    end
  end
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
  local is_kw = false
  if total_args >= 1 and type(last_arg) == "table" and last_arg ~= _G._luthon_none and not rawget(last_arg, "_py") then
    if rawget(last_arg, "__luthon_kw") or (last_mt and last_mt.__luthon_kw) then
      is_kw = true
    elseif total_args >= 2 and not (last_mt and (last_mt.__tuple__ or last_mt.__bytes__ or last_mt.__set__)) and
           not rawget(last_arg, "__type") and not rawget(last_arg, "__msg") and
           not rawget(last_arg, "__name") and not rawget(last_arg, "__class__") and
           not rawget(last_arg, "_dict") and not (last_mt and last_mt.__dict__) then
      local has_hole = false
      for i = 1, total_args - 1 do
        if args[i] == nil then has_hole = true break end
      end
      if has_hole then
        is_kw = true
      end
    end
  end
  if is_kw then
    local pos_count = 0
    for i = 1, total_args - 1 do
      if args[i] ~= nil then pos_count = i end
    end
    py_kwargs = libpy.PyDict_New()
    for k, val in pairs(last_arg) do
      if k ~= "__luthon_kw" then
        local py_val = lua_to_py(val)
        if py_val ~= nil then
          libpy.PyDict_SetItemString(py_kwargs, tostring(k), py_val)
          decref(py_val)
        end
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

local py_fn_registry = {}
local py_fn_counter = 0
local py_fn_cache = setmetatable({}, { __mode = "k" })
local py_callback = nil

local function get_py_callback()
  if py_callback then return py_callback end
  py_callback = ffi.cast("PyCFunctionWithKeywords", function(self_ptr, args_ptr, kwargs_ptr)
    local id = tonumber(libpy.PyLong_AsLongLong(self_ptr))
    local fn = py_fn_registry[id]
    if not fn then
      local builtins = libpy.PyImport_ImportModule("builtins")
      local exc_type = libpy.PyObject_GetAttrString(builtins, "RuntimeError")
      decref(builtins)
      libpy.PyErr_SetString(exc_type, "luthon pybridge: callback function not found")
      decref(exc_type)
      return nil
    end

    local sz = args_ptr ~= nil and tonumber(libpy.PyTuple_Size(args_ptr)) or 0
    local lua_args = {}
    for i = 0, sz - 1 do
      local item = libpy.PyTuple_GetItem(args_ptr, i)
      table.insert(lua_args, py_to_lua(item))
    end

    local kw = nil
    if kwargs_ptr ~= nil and tonumber(libpy.PyDict_Size(kwargs_ptr)) > 0 then
      kw = py_to_lua(kwargs_ptr, true)
    end

    local ok, res
    if kw ~= nil and type(kw) == "table" and _G._luthon_call_kw then
      ok, res = pcall(_G._luthon_call_kw, fn, kw, unpack(lua_args))
    else
      ok, res = pcall(fn, unpack(lua_args))
    end

    if not ok then
      local builtins = libpy.PyImport_ImportModule("builtins")
      local exc_type_name = "Exception"
      local exit_code = nil
      if type(res) == "table" and (res.__type == "SystemExit" or (res.__class__ and res.__class__.__name__ == "SystemExit") or res.code ~= nil) then
        exc_type_name = "SystemExit"
        exit_code = res.code or (res.args and res.args[1]) or 0
      elseif type(res) == "string" and (res:find("SystemExit") or res:find("SystemExit:%s*%d+")) then
        exc_type_name = "SystemExit"
        exit_code = tonumber(res:match("SystemExit:%s*(%d+)")) or 0
      end

      local exc_type = libpy.PyObject_GetAttrString(builtins, exc_type_name)
      decref(builtins)
      if exc_type_name == "SystemExit" then
        local code_py = lua_to_py(exit_code or 0)
        local args = libpy.PyTuple_New(1)
        libpy.PyTuple_SetItem(args, 0, code_py)
        local exc_inst = libpy.PyObject_CallObject(exc_type, args)
        decref(args)
        if exc_inst ~= nil then
          libpy.PyErr_SetObject(exc_type, exc_inst)
          decref(exc_inst)
        else
          libpy.PyErr_SetString(exc_type, tostring(exit_code or 0))
        end
      else
        libpy.PyErr_SetString(exc_type, tostring(res))
      end
      decref(exc_type)
      return nil
    end

    return lua_to_py(res)
  end)
  return py_callback
end

local function py_fn_from_lua(fn)
  if py_fn_cache[fn] then
    libpy.Py_IncRef(py_fn_cache[fn])
    return py_fn_cache[fn]
  end

  local cb = get_py_callback()
  local mdef = ffi.new("PyMethodDef")
  mdef.ml_name = "luthon_callback"
  mdef.ml_meth = cb
  mdef.ml_flags = 3 -- METH_VARARGS | METH_KEYWORDS
  mdef.ml_doc = nil

  py_fn_counter = py_fn_counter + 1
  py_fn_registry[py_fn_counter] = fn

  local self_obj = libpy.PyLong_FromLongLong(py_fn_counter)
  local py_fn = libpy.PyCFunction_NewEx(mdef, self_obj, nil)
  decref(self_obj)

  py_fn_cache[fn] = py_fn
  rawset(py_fn_registry, "mdef_" .. tostring(py_fn_counter), mdef)

  return py_fn
end

local py_file_wrapper_cls = nil

local function get_py_file_wrapper_cls()
  if py_file_wrapper_cls ~= nil then return py_file_wrapper_cls end
  pybridge.get_lib()
  local code = [[
class _LuthonFileWrapper:
    def __init__(self, write=None, read=None, readline=None, flush=None, close=None, seek=None, tell=None):
        self._write_fn = write
        self._read_fn = read
        self._readline_fn = readline
        self._flush_fn = flush
        self._close_fn = close
        self._seek_fn = seek
        self._tell_fn = tell
        self.closed = False
    def write(self, data):
        return self._write_fn(data)
    def read(self, *args):
        res = self._read_fn(*args) if self._read_fn else b""
        if isinstance(res, str):
            return res.encode('latin1')
        return res
    def readline(self, *args):
        res = self._readline_fn(*args) if self._readline_fn else b""
        if isinstance(res, str):
            return res.encode('latin1')
        return res
    def flush(self):
        if self._flush_fn:
            return self._flush_fn()
    def close(self):
        self.closed = True
        if self._close_fn:
            return self._close_fn()
    def seek(self, offset, whence=0):
        if self._seek_fn:
            return self._seek_fn(offset, whence)
        return 0
    def tell(self):
        if self._tell_fn:
            return self._tell_fn()
        return 0
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()
]]
  libpy.PyRun_SimpleString(code)
  local main_mod = libpy.PyImport_ImportModule("__main__")
  if main_mod ~= nil then
    py_file_wrapper_cls = libpy.PyObject_GetAttrString(main_mod, "_LuthonFileWrapper")
    decref(main_mod)
  end
  return py_file_wrapper_cls
end

local py_wrap_method_fn = nil

local function get_py_wrap_method_fn()
  if py_wrap_method_fn ~= nil then return py_wrap_method_fn end
  pybridge.get_lib()
  local code = [[
def _luthon_wrap_method(fn):
    def method(self, *args, **kwargs):
        return fn(self, *args, **kwargs)
    return method
]]
  libpy.PyRun_SimpleString(code)
  local main_mod = libpy.PyImport_ImportModule("__main__")
  if main_mod ~= nil then
    py_wrap_method_fn = libpy.PyObject_GetAttrString(main_mod, "_luthon_wrap_method")
    decref(main_mod)
  end
  return py_wrap_method_fn
end

local function wrap_lua_file(f)
  local cls = get_py_file_wrapper_cls()
  if cls == nil then
    libpy.Py_IncRef(none_ptr)
    return none_ptr
  end
  local write_fn = py_fn_from_lua(function(data)
    f:write(data)
    return #data
  end)
  local read_fn = py_fn_from_lua(function(size)
    local s = f:read(size or "*a")
    return s or ""
  end)
  local readline_fn = py_fn_from_lua(function()
    local s = f:read("*l")
    if s then return s .. "\n" end
    return ""
  end)
  local flush_fn = py_fn_from_lua(function()
    pcall(function() f:flush() end)
  end)
  local close_fn = py_fn_from_lua(function()
    pcall(function() f:close() end)
  end)
  local seek_fn = py_fn_from_lua(function(offset, whence)
    local w = whence == 0 and "set" or (whence == 1 and "cur" or "end")
    local ok, res = pcall(function() return f:seek(w, offset) end)
    return ok and res or 0
  end)
  local tell_fn = py_fn_from_lua(function()
    local ok, res = pcall(function() return f:seek() end)
    return ok and res or 0
  end)
  local args = libpy.PyTuple_New(7)
  libpy.PyTuple_SetItem(args, 0, write_fn)
  libpy.PyTuple_SetItem(args, 1, read_fn)
  libpy.PyTuple_SetItem(args, 2, readline_fn)
  libpy.PyTuple_SetItem(args, 3, flush_fn)
  libpy.PyTuple_SetItem(args, 4, close_fn)
  libpy.PyTuple_SetItem(args, 5, seek_fn)
  libpy.PyTuple_SetItem(args, 6, tell_fn)
  local py_inst = libpy.PyObject_CallObject(cls, args)
  decref(args)
  return py_inst
end

local active_patches = {}

local function resolve_lua_target(path)
  if not path or path == "" then return nil end
  local sys_modules = _G._luthon_sys_modules
  local mm = _G._luthon_modules
  if not sys_modules or not mm then
    for _, cand in ipairs({"luthon.lua.modules", "src/luthon/lua/modules", "modules", "luthon.modules"}) do
      if package.loaded[cand] then
        mm = package.loaded[cand]
        break
      end
    end
    if not mm then
      for _, cand in ipairs({"luthon.lua.modules", "src/luthon/lua/modules", "modules", "luthon.modules"}) do
        local ok, m = pcall(require, cand)
        if ok and m then mm = m; break end
      end
    end
    sys_modules = (mm and mm.sys_modules) or _G._luthon_sys_modules or {}
  end

  local parts = {}
  for part in path:gmatch("[^%.]+") do
    table.insert(parts, part)
  end
  if #parts == 0 then return nil end

  -- Try longest prefix match in sys_modules
  for i = #parts, 1, -1 do
    local mod_name = table.concat(parts, ".", 1, i)
    local cur = sys_modules[mod_name] or (_MODULES and _MODULES[mod_name]) or _G[mod_name]
    if cur == nil and mm and mm.load then
      local ok_load, loaded = pcall(mm.load, mod_name)
      if ok_load and loaded then
        cur = loaded
      end
    end
    if cur ~= nil then
      local found = true
      for j = i + 1, #parts do
        if type(cur) == "table" and cur[parts[j]] ~= nil then
          cur = cur[parts[j]]
        else
          found = false
          break
        end
      end
      if found then
        return cur
      end
    end
  end

  local cur = _G[parts[1]]
  if cur ~= nil then
    for j = 2, #parts do
      if type(cur) == "table" and cur[parts[j]] ~= nil then
        cur = cur[parts[j]]
      else
        return nil
      end
    end
    return cur
  end

  return nil
end

local function lua_patch_start(patch_id, target_path, attr, mock_obj)
  local target_obj = resolve_lua_target(target_path)
  if target_obj and type(target_obj) == "table" and attr and attr ~= "" then
    local orig_val = target_obj[attr]
    active_patches[patch_id] = {
      target_obj = target_obj,
      attr = attr,
      orig_val = orig_val,
      has_orig = (orig_val ~= nil)
    }
    target_obj[attr] = mock_obj
  end
  return true
end

local function lua_patch_stop(patch_id)
  local entry = active_patches[patch_id]
  if entry then
    active_patches[patch_id] = nil
    if entry.has_orig then
      entry.target_obj[entry.attr] = entry.orig_val
    else
      entry.target_obj[entry.attr] = nil
    end
  end
  return true
end

local _patch_hook_installed = false
function pybridge.ensure_patch_hook()
  if _patch_hook_installed then return end
  _patch_hook_installed = true
  local lib = pybridge.get_lib()
  if not lib then return end

  local py_start = py_fn_from_lua(lua_patch_start)
  local py_stop = py_fn_from_lua(lua_patch_stop)

  local sys_mod = libpy.PyImport_ImportModule("sys")
  if sys_mod ~= nil then
    libpy.PyObject_SetAttrString(sys_mod, "_luthon_patch_start", py_start)
    libpy.PyObject_SetAttrString(sys_mod, "_luthon_patch_stop", py_stop)
    decref(sys_mod)
  end
  decref(py_start)
  decref(py_stop)

  libpy.PyRun_SimpleString([[
try:
    import sys, unittest.mock, functools

    def _extract_target_path(p):
        if hasattr(p, 'getter') and hasattr(p.getter, 'args') and p.getter.args:
            return str(p.getter.args[0])
        tgt = getattr(p, 'target', None)
        if tgt is None and hasattr(p, 'getter'):
            try:
                tgt = p.getter()
            except Exception:
                tgt = None
        if tgt is not None:
            mod = getattr(tgt, '__module__', None)
            name = getattr(tgt, '__qualname__', None) or getattr(tgt, '__name__', None)
            if mod and name:
                return f"{mod}.{name}"
            elif name:
                return str(name)
            elif mod:
                return str(mod)
        return ""

    if not getattr(unittest.mock._patch, '_luthon_hooked', False):
        _orig_enter = unittest.mock._patch.__enter__
        _orig_exit = unittest.mock._patch.__exit__

        def _hooked_enter(self):
            res = _orig_enter(self)
            try:
                handler = getattr(sys, '_luthon_patch_start', None)
                if handler:
                    tgt_path = _extract_target_path(self)
                    attr = str(getattr(self, 'attribute', '') or '')
                    pid = id(self)
                    handler(pid, tgt_path, attr, res)
            except Exception:
                pass
            return res

        def _hooked_exit(self, *args):
            try:
                handler = getattr(sys, '_luthon_patch_stop', None)
                if handler:
                    pid = id(self)
                    handler(pid)
            except Exception:
                pass
            return _orig_exit(self, *args)

        unittest.mock._patch.__enter__ = _hooked_enter
        unittest.mock._patch.__exit__ = _hooked_exit
        unittest.mock._patch._luthon_hooked = True
except Exception:
    pass
]])
end

-- Convert Lua value to PyObject*
lua_to_py = function(v, visited)
  pybridge.get_lib()
  if v == nil or v == _G._luthon_none or (type(v) == "table" and rawget(v, "__is_none__") == true) then
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
      local p = rawget(v, "_py")
      if type(p) == "table" and rawget(p, "_py") then
        p = rawget(p, "_py")
      end
      libpy.Py_IncRef(p)
      return p
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

    if v == _G.NoneType or (rawget(v, "__class__") == _G._luthon_type and rawget(v, "__name__") == "NoneType") then
      local nt = ffi.cast("PyObject*", libpy.PyObject_Type(none_ptr))
      libpy.Py_IncRef(nt)
      visited[v] = nt
      return nt
    end
    if _G._luthon_type ~= nil and rawget(v, "__class__") == _G._luthon_type and type(rawget(v, "__name__")) == "string" then
      local bname = rawget(v, "__name__")
      local builtins_mod = libpy.PyImport_ImportModule("builtins")
      if builtins_mod ~= nil then
        local builtin_cls = libpy.PyObject_GetAttrString(builtins_mod, bname)
        decref(builtins_mod)
        if builtin_cls ~= nil then
          visited[v] = builtin_cls
          return builtin_cls
        end
        libpy.PyErr_Clear()
      end
    end

    -- Check if this is a Luthon class
    local is_class = (rawget(v, "__class__") == nil and (rawget(v, "__instance_mt") ~= nil or rawget(v, "__index") == v) and type(rawget(v, "__name__") or rawget(v, "__name")) == "string")
    if is_class then
      local cls_name = rawget(v, "__name__") or rawget(v, "__name") or "CustomClass"
      local builtins_mod = libpy.PyImport_ImportModule("builtins")
      if builtins_mod ~= nil then
        local builtin_cls = libpy.PyObject_GetAttrString(builtins_mod, cls_name)
        decref(builtins_mod)
        if builtin_cls ~= nil then
          visited[v] = builtin_cls
          return builtin_cls
        end
        libpy.PyErr_Clear()
      end
      local dotted_name = cls_name:find("%.") and cls_name or ("_luthon." .. cls_name)
      local base_cls = rawget(v, "__base__")
      local is_exc = (cls_name:match("Error$") or cls_name:match("Exception$") or cls_name:match("Failure$") or cls_name:match("Warning$") or (type(base_cls) == "table" and tostring(base_cls.__name__ or base_cls.__name):match("Exception|Error|Failure|Warning")))
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
        local wrap_fn = get_py_wrap_method_fn()
        for m_name, m_val in pairs(v) do
          if type(m_val) == "function" and type(m_name) == "string" and not m_name:match("^__instance") then
            pcall(function()
              local py_fn = py_fn_from_lua(m_val)
              if py_fn then
                local wrapped = nil
                if wrap_fn then
                  local args = libpy.PyTuple_New(1)
                  libpy.PyTuple_SetItem(args, 0, py_fn)
                  wrapped = libpy.PyObject_CallObject(wrap_fn, args)
                  decref(args)
                else
                  wrapped = py_fn
                end
                if wrapped then
                  libpy.PyDict_SetItemString(empty_dict, m_name, wrapped)
                  decref(wrapped)
                end
              end
            end)
          end
        end
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
    if inst_class and inst_class ~= v and type(inst_class) == "table" and type(rawget(inst_class, "__name__") or rawget(inst_class, "__name")) == "string" then
      local cls_name = rawget(inst_class, "__name__") or rawget(inst_class, "__name")
      if cls_name:match("Error$") or cls_name:match("Exception$") or cls_name:match("Failure$") then
        local py_cls = lua_to_py(inst_class, visited)
        local msg = v.message or v.msg or (v.args and v.args[1]) or tostring(v)
        local msg_py = libpy.PyUnicode_FromStringAndSize(tostring(msg), #tostring(msg))
        local args = libpy.PyTuple_New(1)
        libpy.PyTuple_SetItem(args, 0, msg_py)
        local exc_inst = libpy.PyObject_CallObject(py_cls, args)
        decref(args)
        if exc_inst then
          libpy.Py_IncRef(exc_inst)
          local gc_exc = ffi.gc(exc_inst, function(p)
            if libpy and libpy.Py_IsInitialized() ~= 0 then
              libpy.Py_DecRef(p)
            end
          end)
          visited[v] = exc_inst
          rawset(v, "_py", gc_exc)
          return exc_inst
        end
      else
        local py_cls = lua_to_py(inst_class, visited)
        if py_cls and py_cls ~= none_ptr then
          local builtins_mod = libpy.PyImport_ImportModule("builtins")
          local object_cls = libpy.PyObject_GetAttrString(builtins_mod, "object")
          decref(builtins_mod)
          local new_fn = object_cls and libpy.PyObject_GetAttrString(object_cls, "__new__")
          if object_cls then decref(object_cls) end
          local py_inst = nil
          if new_fn then
            local args = libpy.PyTuple_New(1)
            libpy.Py_IncRef(py_cls)
            libpy.PyTuple_SetItem(args, 0, py_cls)
            py_inst = libpy.PyObject_CallObject(new_fn, args)
            decref(args)
            decref(new_fn)
            if py_inst == nil then libpy.PyErr_Clear() end
          end
          if py_inst then
            for k, val in pairs(v) do
              if type(k) == "string" and not k:match("^__") and k ~= "_py" then
                pcall(function()
                  local py_val = lua_to_py(val, visited)
                  if py_val then
                    libpy.PyObject_SetAttrString(py_inst, k, py_val)
                    decref(py_val)
                  end
                end)
              end
            end
            libpy.Py_IncRef(py_inst)
            local gc_py = ffi.gc(py_inst, function(p)
              if libpy and libpy.Py_IsInitialized() ~= 0 then
                libpy.Py_DecRef(p)
              end
            end)
            local proxy = setmetatable({_py = gc_py}, PyProxy)
            rawset(v, "_py", proxy)
            visited[v] = py_inst
            return py_inst
          end
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
    if rawget(v, "getvalue") and type(v.getvalue) == "function" then
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

    if rawget(v, "_file") and (io.type(rawget(v, "_file")) == "file" or io.type(rawget(v, "_file")) == "closed file") then
      local py_f = wrap_lua_file(rawget(v, "_file"), rawget(v, "name") or rawget(v, "_name"))
      visited[v] = py_f
      return py_f
    end

    -- Check if list or sequential array
    local mt = getmetatable(v)
    local is_list_obj = (mt and (mt == _G._list_mt or rawget(mt, "__index") == _G._list_methods)) or rawget(v, "_list")
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
      is_array = is_list_obj or (next(v) == nil and is_list_obj)
    end

    if is_list_obj or (is_array and n > 0) then
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
  elseif type(v) == "function" then
    return py_fn_from_lua(v)
  elseif type(v) == "userdata" then
    if io.type(v) == "file" or io.type(v) == "closed file" then
      return wrap_lua_file(v)
    end
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
  if name == "unittest.mock" or name == "unittest" or name:find("^unittest%..*") then
    pcall(pybridge.ensure_patch_hook)
  end
  local mod = libpy.PyImport_ImportModule(name)
  if mod == nil then
    check_py_error()
    error("pybridge: failed to import module '" .. name .. "'", 2)
  end
  local file_attr = libpy.PyObject_GetAttrString(mod, "__file__")
  local has_file = false
  if file_attr ~= nil then
    if file_attr ~= none_ptr then has_file = true end
    decref(file_attr)
  else
    libpy.PyErr_Clear()
  end

  if not has_file and libpy.PyObject_HasAttrString(mod, "__version__") == 0 and libpy.PyObject_HasAttrString(mod, "__all__") == 0 then
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

local function sync_sys_argv(custom_args)
  pcall(function()
    local libpy = pybridge.get_lib()
    if not libpy then return end
    local sys_mod = libpy.PyImport_ImportModule("sys")
    if sys_mod ~= nil and sys_mod ~= none_ptr then
      local args_to_use = {}
      if custom_args and type(custom_args) == "table" then
        for i = 1, #custom_args do
          table.insert(args_to_use, tostring(custom_args[i]))
        end
      elseif _G.sys and type(_G.sys.argv) == "table" and #_G.sys.argv > 0 then
        for i = 1, #_G.sys.argv do
          table.insert(args_to_use, tostring(_G.sys.argv[i]))
        end
      elseif _G.arg and type(_G.arg) == "table" then
        table.insert(args_to_use, _G.arg[0] or "luthon")
        for i = 1, #_G.arg do
          table.insert(args_to_use, tostring(_G.arg[i]))
        end
      end
      if #args_to_use == 0 then table.insert(args_to_use, "luthon") end

      local py_argv = libpy.PyList_New(#args_to_use)
      for i = 1, #args_to_use do
        local s = tostring(args_to_use[i])
        local pystr = libpy.PyUnicode_FromStringAndSize(s, #s)
        libpy.PyList_SetItem(py_argv, i - 1, pystr)
      end
      libpy.PyObject_SetAttrString(sys_mod, "argv", py_argv)
      decref(py_argv)
      decref(sys_mod)
    end
  end)
end
pybridge.sync_sys_argv = sync_sys_argv
sync_sys_argv()

return pybridge
