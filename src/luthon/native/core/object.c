/*
 * Luthon C-API Proxy: Core Object System (core/object.c)
 */

#include "luthon_capi.h"

/* Standard Singletons */
EXPORT PyObject _Py_NoneStruct  = { 1000000000, &Base_Type, PY_TAG_NONE, 0, { .i_val = 0 } };
EXPORT PyObject _Py_TrueStruct  = { 1000000000, &PyBool_Type, PY_TAG_BOOL, 0, { .i_val = 1 } };
EXPORT PyObject _Py_FalseStruct = { 1000000000, &PyBool_Type, PY_TAG_BOOL, 0, { .i_val = 0 } };

EXPORT PyObject* alloc_pyobject(PyTag tag, PyTypeObject *type) {
    PyObject *o = (PyObject *)calloc(1, sizeof(PyObject));
    if (!o) return NULL;
    o->ob_refcnt = 1;
    o->ob_type = type ? type : &Base_Type;
    o->tag = tag;
    return o;
}

EXPORT void Py_IncRef(PyObject *o) {
    if (o) o->ob_refcnt++;
}

EXPORT void _Py_Dealloc(PyObject *o) {
    if (!o) return;
    if (o == &_Py_NoneStruct || o == &_Py_TrueStruct || o == &_Py_FalseStruct) return;

    if (o->ob_type && o->ob_type->tp_dealloc) {
        o->ob_type->tp_dealloc(o);
        return;
    }

    if (o->tag == PY_TAG_STR || o->tag == PY_TAG_BYTES) {
        free(o->as.str_val.data);
    } else if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST) {
        if (o->as.seq_val.items) {
            for (Py_ssize_t i = 0; i < o->as.seq_val.size; i++) {
                Py_DecRef(o->as.seq_val.items[i]);
            }
            free(o->as.seq_val.items);
        }
    } else if (o->tag == PY_TAG_SLICE) {
        Py_DecRef(o->as.slice_val.start);
        Py_DecRef(o->as.slice_val.stop);
        Py_DecRef(o->as.slice_val.step);
    } else if (o->tag == PY_TAG_STREAM) {
        if (o->as.stream_val.buffer) {
            free(o->as.stream_val.buffer);
        }
    } else if (o->tag == PY_TAG_CAPSULE) {
        PyCapsuleObject *cap = (PyCapsuleObject *)o;
        if (cap->destructor) {
            cap->destructor(o);
        }
    }
    free(o);
}

EXPORT void Py_DecRef(PyObject *o) {
    if (!o) return;
    if (--o->ob_refcnt <= 0) {
        _Py_Dealloc(o);
    }
}

EXPORT int PyObject_IsTrue(PyObject *o) {
    if (!o || o == &_Py_NoneStruct || o == &_Py_FalseStruct) return 0;
    if (o == &_Py_TrueStruct) return 1;
    if (o->tag == PY_TAG_INT || o->tag == PY_TAG_BOOL) return o->as.i_val != 0;
    if (o->tag == PY_TAG_FLOAT) return o->as.f_val != 0.0;
    if (o->tag == PY_TAG_STR || o->tag == PY_TAG_BYTES) return o->as.str_val.size > 0;
    if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST) return o->as.seq_val.size > 0;
    if (o->tag == PY_TAG_STREAM) return o->as.stream_val.size > 0;
    if (o->ob_type && o->ob_type->tp_as_number && o->ob_type->tp_as_number->nb_bool) {
        return o->ob_type->tp_as_number->nb_bool(o);
    }
    return 1;
}

EXPORT PyObject* PyObject_Type(PyObject *o) {
    if (!o) return (PyObject *)&Base_Type;
    return (PyObject *)o->ob_type;
}

/* Primitive Constructors */
EXPORT PyObject* PyLong_FromLongLong(long long v) {
    PyObject *o = alloc_pyobject(PY_TAG_INT, &PyLong_Type);
    if (o) o->as.i_val = (int64_t)v;
    return o;
}

EXPORT PyObject* PyLong_FromLong(long v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT PyObject* PyLong_FromSize_t(size_t v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT long long PyLong_AsLongLong(PyObject *o) {
    if (!o) return 0;
    if (o->tag == PY_TAG_INT || o->tag == PY_TAG_BOOL) return (long long)o->as.i_val;
    if (o->tag == PY_TAG_FLOAT) return (long long)o->as.f_val;
    return 0;
}

EXPORT long PyLong_AsLong(PyObject *o) {
    return (long)PyLong_AsLongLong(o);
}

EXPORT PyObject* PyFloat_FromDouble(double v) {
    PyObject *o = alloc_pyobject(PY_TAG_FLOAT, &PyFloat_Type);
    if (o) o->as.f_val = v;
    return o;
}

EXPORT double PyFloat_AsDouble(PyObject *o) {
    if (!o) return 0.0;
    if (o->tag == PY_TAG_FLOAT) return o->as.f_val;
    if (o->tag == PY_TAG_INT || o->tag == PY_TAG_BOOL) return (double)o->as.i_val;
    return 0.0;
}

EXPORT PyObject* PyBool_FromLong(long v) {
    return v ? &_Py_TrueStruct : &_Py_FalseStruct;
}

EXPORT PyObject* PyUnicode_FromStringAndSize(const char *s, Py_ssize_t size) {
    PyObject *o = alloc_pyobject(PY_TAG_STR, &PyUnicode_Type);
    if (!o) return NULL;
    o->as.str_val.size = size;
    o->as.str_val.data = (char *)malloc(size + 1);
    if (s && o->as.str_val.data) {
        memcpy(o->as.str_val.data, s, size);
        o->as.str_val.data[size] = '\0';
    }
    return o;
}

EXPORT PyObject* PyUnicode_FromString(const char *s) {
    return PyUnicode_FromStringAndSize(s, s ? strlen(s) : 0);
}

EXPORT const char* PyUnicode_AsUTF8AndSize(PyObject *o, Py_ssize_t *size) {
    if (!o || o->tag != PY_TAG_STR) return "";
    if (size) *size = o->as.str_val.size;
    return o->as.str_val.data ? o->as.str_val.data : "";
}

EXPORT const char* PyUnicode_AsUTF8(PyObject *o) {
    return PyUnicode_AsUTF8AndSize(o, NULL);
}

EXPORT PyObject* PyBytes_FromStringAndSize(const char *s, Py_ssize_t size) {
    PyObject *o = alloc_pyobject(PY_TAG_BYTES, &PyBytes_Type);
    if (!o) return NULL;
    o->as.str_val.size = size;
    o->as.str_val.data = (char *)malloc(size + 1);
    if (s && o->as.str_val.data) {
        memcpy(o->as.str_val.data, s, size);
        o->as.str_val.data[size] = '\0';
    }
    return o;
}

EXPORT char* PyBytes_AsString(PyObject *o) {
    if (!o || o->tag != PY_TAG_BYTES) return "";
    return o->as.str_val.data ? o->as.str_val.data : "";
}

EXPORT Py_ssize_t PyBytes_Size(PyObject *o) {
    if (!o || o->tag != PY_TAG_BYTES) return 0;
    return o->as.str_val.size;
}

/* Heap Object Allocation for C-Extensions */
EXPORT PyObject* _PyObject_New(PyTypeObject *tp) {
    if (!tp) return NULL;
    size_t size = tp->tp_basicsize ? (size_t)tp->tp_basicsize : sizeof(PyObject);
    PyObject *op = (PyObject *)calloc(1, size);
    if (!op) return PyErr_NoMemory();
    op->ob_refcnt = 1;
    op->ob_type = tp;
    op->tag = PY_TAG_OPAQUE;
    return op;
}

EXPORT void PyObject_Free(void *ptr) {
    if (ptr) free(ptr);
}

EXPORT int PyObject_Print(PyObject *op, FILE *fp, int flags) {
    (void)flags;
    if (!fp) fp = stdout;
    if (!op) {
        fprintf(fp, "<NULL>");
        return 0;
    }
    if (op == &_Py_NoneStruct) {
        fprintf(fp, "None");
    } else if (op->tag == PY_TAG_INT || op->tag == PY_TAG_BOOL) {
        fprintf(fp, "%lld", (long long)op->as.i_val);
    } else if (op->tag == PY_TAG_FLOAT) {
        fprintf(fp, "%f", op->as.f_val);
    } else if (op->tag == PY_TAG_STR) {
        fprintf(fp, "%s", op->as.str_val.data ? op->as.str_val.data : "");
    } else {
        fprintf(fp, "<%s object at %p>", (op->ob_type && op->ob_type->tp_name) ? op->ob_type->tp_name : "unknown", (void *)op);
    }
    return 0;
}

EXPORT int PyType_IsSubtype(PyTypeObject *a, PyTypeObject *b) {
    if (!a || !b) return 0;
    if (a == b) return 1;
    for (PyTypeObject *base = a->tp_base; base; base = base->tp_base) {
        if (base == b) return 1;
    }
    return 0;
}

/* Thread State Stubs for Single-Threaded LuaJIT Runtime */
EXPORT void* PyEval_SaveThread(void) {
    return (void *)1;
}

EXPORT void PyEval_RestoreThread(void *tstate) {
    (void)tstate;
}

EXPORT int PyOS_snprintf(char *str, size_t size, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int ret = vsnprintf(str, size, format, args);
    va_end(args);
    return ret;
}

/* Singletons: NotImplemented & Ellipsis */
EXPORT PyObject _Py_NotImplementedStruct = { 1000000000, &Base_Type, PY_TAG_OPAQUE, 0, { .i_val = 0 } };
EXPORT PyObject _Py_EllipsisObject        = { 1000000000, &Base_Type, PY_TAG_OPAQUE, 0, { .i_val = 0 } };

/* ASCII Whitespace Table */
EXPORT const unsigned char _Py_ascii_whitespace[256] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

/* Memory Allocation Protocols */
EXPORT void* PyMem_Malloc(size_t size) { return malloc(size); }
EXPORT void* PyMem_Calloc(size_t nelem, size_t elsize) { return calloc(nelem, elsize); }
EXPORT void* PyMem_Realloc(void *ptr, size_t new_size) { return realloc(ptr, new_size); }
EXPORT void  PyMem_Free(void *ptr) { free(ptr); }

EXPORT void* PyMem_RawMalloc(size_t size) { return malloc(size); }
EXPORT void* PyMem_RawCalloc(size_t nelem, size_t elsize) { return calloc(nelem, elsize); }
EXPORT void* PyMem_RawRealloc(void *ptr, size_t new_size) { return realloc(ptr, new_size); }
EXPORT void  PyMem_RawFree(void *ptr) { free(ptr); }

EXPORT void* PyObject_Malloc(size_t size) { return malloc(size); }

/* Object Initialization and GC Protocols */
EXPORT PyObject* PyObject_Init(PyObject *op, PyTypeObject *tp) {
    if (!op) return NULL;
    op->ob_refcnt = 1;
    op->ob_type = tp ? tp : &Base_Type;
    return op;
}

EXPORT PyObject* PyObject_InitVar(PyObject *op, PyTypeObject *tp, Py_ssize_t size) {
    (void)size;
    return PyObject_Init(op, tp);
}

EXPORT PyObject* _PyObject_NewVar(PyTypeObject *tp, Py_ssize_t nitems) {
    size_t size = (tp && tp->tp_basicsize) ? (size_t)tp->tp_basicsize : sizeof(PyObject);
    size += (tp && tp->tp_itemsize) ? (size_t)(tp->tp_itemsize * nitems) : 0;
    PyObject *op = (PyObject *)calloc(1, size);
    if (!op) return PyErr_NoMemory();
    op->ob_refcnt = 1;
    op->ob_type = tp ? tp : &Base_Type;
    op->tag = PY_TAG_OPAQUE;
    return op;
}

EXPORT PyObject* _PyObject_GC_New(PyTypeObject *tp) {
    return _PyObject_New(tp);
}

EXPORT void PyObject_GC_Track(void *op) { (void)op; }
EXPORT void PyObject_GC_UnTrack(void *op) { (void)op; }
EXPORT void PyObject_GC_Del(void *op) { free(op); }
EXPORT void PyObject_ClearWeakRefs(PyObject *op) { (void)op; }

/* Callable and Instance Inspection */
EXPORT int PyCallable_Check(PyObject *o) {
    if (!o) return 0;
    if (o->ob_type && o->ob_type->tp_call) return 1;
    if (o->tag == PY_TAG_OPAQUE && o->as.buf_val.ptr) return 1;
    return 0;
}

EXPORT int PyObject_IsInstance(PyObject *inst, PyObject *cls) {
    if (!inst || !cls) return 0;
    PyTypeObject *inst_type = inst->ob_type;
    PyTypeObject *target = (PyTypeObject *)cls;
    return PyType_IsSubtype(inst_type, target);
}

EXPORT int PyObject_IsSubclass(PyObject *derived, PyObject *cls) {
    if (!derived || !cls) return 0;
    return PyType_IsSubtype((PyTypeObject *)derived, (PyTypeObject *)cls);
}

EXPORT int PyObject_Not(PyObject *o) {
    return !PyObject_IsTrue(o);
}

EXPORT Py_ssize_t PyObject_LengthHint(PyObject *o, Py_ssize_t defaultvalue) {
    if (!o) return defaultvalue;
    if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST) return o->as.seq_val.size;
    if (o->tag == PY_TAG_STR || o->tag == PY_TAG_BYTES) return o->as.str_val.size;
    if (o->ob_type && o->ob_type->tp_as_sequence && o->ob_type->tp_as_sequence->sq_length) {
        return o->ob_type->tp_as_sequence->sq_length(o);
    }
    return defaultvalue;
}

EXPORT intptr_t PyObject_Hash(PyObject *o) {
    if (!o) return 0;

    /* 1. Custom tp_hash slot on custom C-extension classes */
    if (o->ob_type && o->ob_type->tp_hash) {
        hashfunc hfn = (hashfunc)o->ob_type->tp_hash;
        intptr_t h = hfn(o);
        if (h == -1) h = -2;
        return h;
    }

    /* 2. Integers and Booleans */
    if (o->tag == PY_TAG_INT || o->tag == PY_TAG_BOOL) {
        intptr_t h = (intptr_t)o->as.i_val;
        if (h == -1) h = -2;
        return h;
    }

    /* 3. Floating-point numbers */
    if (o->tag == PY_TAG_FLOAT) {
        double d = o->as.f_val;
        if (d == 0.0) return 0;
        uint64_t bits;
        memcpy(&bits, &d, sizeof(bits));
        intptr_t h = (intptr_t)(bits ^ (bits >> 32));
        if (h == -1) h = -2;
        return h;
    }

    /* 4. Strings (polynomial / FNV hash) */
    if (o->tag == PY_TAG_STR) {
        intptr_t h = 0x345678;
        const char *s = o->as.str_val.data;
        Py_ssize_t len = o->as.str_val.size;
        for (Py_ssize_t i = 0; i < len; i++) {
            h = (1000003 * h) ^ (unsigned char)s[i];
        }
        h ^= len;
        if (h == -1) h = -2;
        return h;
    }

    /* 5. Tuples */
    if (o->tag == PY_TAG_TUPLE) {
        intptr_t mult = 1000003;
        intptr_t x = 0x345678;
        Py_ssize_t len = o->as.seq_val.size;
        for (Py_ssize_t i = 0; i < len; i++) {
            intptr_t y = PyObject_Hash(o->as.seq_val.items[i]);
            x = (x ^ y) * mult;
            mult += (intptr_t)(82520 + 2 * len);
        }
        x += 97531;
        if (x == -1) x = -2;
        return x;
    }

    /* 6. Pointer fallback for generic objects */
    intptr_t h = (intptr_t)o;
    h = (h >> 4) ^ h;
    if (h == -1) h = -2;
    return h;
}

EXPORT int PyObject_AsFileDescriptor(PyObject *o) {
    if (!o) return -1;
    if (o->tag == PY_TAG_INT) return (int)o->as.i_val;
    return -1;
}

EXPORT int PyUnstable_Object_IsUniquelyReferenced(PyObject *op) {
    return op && (op->ob_refcnt == 1);
}

EXPORT int PyUnstable_Object_IsUniqueReferencedTemporary(PyObject *op) {
    return op && (op->ob_refcnt == 1);
}

/* Generic Attribute Access */
EXPORT PyObject* PyObject_GenericGetAttr(PyObject *o, PyObject *name) {
    if (!o || !name) return NULL;
    const char *attr_name = PyUnicode_AsUTF8(name);
    return PyObject_GetAttrString(o, attr_name);
}

EXPORT int PyObject_GenericSetAttr(PyObject *o, PyObject *name, PyObject *value) {
    if (!o || !name) return -1;
    const char *attr_name = PyUnicode_AsUTF8(name);
    return PyObject_SetAttrString(o, attr_name, value);
}

EXPORT PyObject* PyObject_GetAttr(PyObject *o, PyObject *name) {
    return PyObject_GenericGetAttr(o, name);
}

EXPORT int PyObject_GetOptionalAttr(PyObject *obj, PyObject *name, PyObject **result) {
    if (!result) return -1;
    *result = PyObject_GetAttr(obj, name);
    if (*result) return 1;
    PyErr_Clear();
    *result = NULL;
    return 0;
}

EXPORT PyObject* PyObject_GenericGetDict(PyObject *o, void *context) {
    (void)context;
    if (!o) return NULL;
    PyObject *d = PyDict_New();
    return d;
}

/* Iteration Protocols */
EXPORT PyObject* PyObject_SelfIter(PyObject *o) {
    Py_IncRef(o);
    return o;
}

EXPORT PyObject* PyObject_GetIter(PyObject *o) {
    if (!o) return NULL;

    /* 1. Custom tp_iter callback */
    if (o->ob_type && o->ob_type->tp_iter) {
        return o->ob_type->tp_iter(o);
    }

    /* 2. Object is already an iterator (has tp_iternext) */
    if (o->ob_type && o->ob_type->tp_iternext) {
        Py_IncRef(o);
        return o;
    }

    /* 3. Sequence fallback iterator */
    if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST || (o->ob_type && o->ob_type->tp_as_sequence)) {
        return PySeqIter_New(o);
    }

    Py_IncRef(o);
    return o;
}

EXPORT int PyIter_Check(PyObject *o) {
    return (o && o->ob_type && o->ob_type->tp_iternext != NULL);
}

EXPORT PyObject* PyIter_Next(PyObject *iter) {
    if (!iter || !iter->ob_type || !iter->ob_type->tp_iternext) return NULL;
    return iter->ob_type->tp_iternext(iter);
}

/* Call and Vectorcall Protocols */
EXPORT PyObject* PyObject_CallFunctionObjArgs(PyObject *callable, ...) {
    if (!callable) return NULL;
    va_list args;
    va_start(args, callable);
    PyObject *arg = va_arg(args, PyObject*);
    PyObject *tuple = PyTuple_New(arg ? 1 : 0);
    if (arg) PyTuple_SetItem(tuple, 0, arg);
    va_end(args);
    PyObject *res = PyObject_CallObject(callable, tuple);
    Py_DecRef(tuple);
    return res;
}

EXPORT PyObject* PyObject_CallOneArg(PyObject *callable, PyObject *arg) {
    if (!callable) return NULL;
    PyObject *tuple = PyTuple_New(1);
    PyTuple_SetItem(tuple, 0, arg);
    PyObject *res = PyObject_CallObject(callable, tuple);
    Py_DecRef(tuple);
    return res;
}

EXPORT PyObject* PyVectorcall_Call(PyObject *callable, PyObject *tuple_args, PyObject *kwargs) {
    return PyObject_Call(callable, tuple_args, kwargs);
}

EXPORT PyObject* PyObject_Vectorcall(PyObject *callable, PyObject *const *args, size_t nargsf, PyObject *kwnames) {
    size_t nargs = nargsf & ~(((size_t)1) << (sizeof(size_t)*8 - 1));
    PyObject *tuple = PyTuple_New((Py_ssize_t)nargs);
    for (size_t i = 0; i < nargs; i++) {
        Py_IncRef(args[i]);
        PyTuple_SetItem(tuple, (Py_ssize_t)i, args[i]);
    }
    PyObject *res = PyObject_Call(callable, tuple, kwnames);
    Py_DecRef(tuple);
    return res;
}

EXPORT PyObject* PyObject_VectorcallMethod(PyObject *name, PyObject *const *args, size_t nargsf, PyObject *kwnames) {
    if (!args || nargsf == 0) return NULL;
    PyObject *self = args[0];
    const char *attr = PyUnicode_AsUTF8(name);
    PyObject *meth = PyObject_GetAttrString(self, attr);
    if (!meth) return NULL;
    PyObject *res = PyObject_Vectorcall(meth, args + 1, nargsf - 1, kwnames);
    Py_DecRef(meth);
    return res;
}

/* String Formatting and Representation */
EXPORT PyObject* PyObject_Str(PyObject *v) {
    if (!v) return PyUnicode_FromString("<NULL>");
    if (v->ob_type && v->ob_type->tp_str) {
        return (PyObject *)v->ob_type->tp_str;
    }
    if (v->tag == PY_TAG_STR) {
        Py_IncRef(v);
        return v;
    }
    if (v->tag == PY_TAG_INT) {
        char buf[64];
        snprintf(buf, sizeof(buf), "%lld", (long long)v->as.i_val);
        return PyUnicode_FromString(buf);
    }
    if (v->tag == PY_TAG_FLOAT) {
        char buf[64];
        snprintf(buf, sizeof(buf), "%f", v->as.f_val);
        return PyUnicode_FromString(buf);
    }
    return PyUnicode_FromString("<object>");
}

EXPORT PyObject* PyObject_Bytes(PyObject *v) {
    if (!v) return PyBytes_FromStringAndSize("", 0);
    if (v->tag == PY_TAG_BYTES) {
        Py_IncRef(v);
        return v;
    }
    if (v->tag == PY_TAG_STR) {
        return PyBytes_FromStringAndSize(v->as.str_val.data, v->as.str_val.size);
    }
    return PyBytes_FromStringAndSize("", 0);
}

EXPORT PyObject* PyObject_Format(PyObject *obj, PyObject *format_spec) {
    (void)format_spec;
    return PyObject_Str(obj);
}

/* Bytes & MemoryView Constructors */
EXPORT PyObject* PyBytes_FromString(const char *v) {
    return PyBytes_FromStringAndSize(v, v ? strlen(v) : 0);
}

EXPORT PyObject* PyMemoryView_FromObject(PyObject *base) {
    PyObject *mv = alloc_pyobject(PY_TAG_OPAQUE, &PyMemoryView_Type);
    if (mv) mv->as.buf_val.ptr = base;
    return mv;
}

/* Unicode Operations */
EXPORT PyObject* PyUnicode_InternFromString(const char *u) {
    return PyUnicode_FromString(u);
}

EXPORT Py_ssize_t PyUnicode_GetLength(PyObject *unicode) {
    if (!unicode || unicode->tag != PY_TAG_STR) return 0;
    return unicode->as.str_val.size;
}

EXPORT PyObject* PyUnicode_Substring(PyObject *str, Py_ssize_t start, Py_ssize_t end) {
    if (!str || str->tag != PY_TAG_STR) return PyUnicode_FromString("");
    Py_ssize_t len = str->as.str_val.size;
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) return PyUnicode_FromString("");
    return PyUnicode_FromStringAndSize(str->as.str_val.data + start, end - start);
}

EXPORT PyObject* PyUnicode_Concat(PyObject *left, PyObject *right) {
    if (!left || !right) return NULL;
    const char *s1 = PyUnicode_AsUTF8(left);
    const char *s2 = PyUnicode_AsUTF8(right);
    size_t l1 = strlen(s1), l2 = strlen(s2);
    char *buf = (char *)malloc(l1 + l2 + 1);
    if (!buf) return PyErr_NoMemory();
    memcpy(buf, s1, l1);
    memcpy(buf + l1, s2, l2);
    buf[l1 + l2] = '\0';
    PyObject *res = PyUnicode_FromStringAndSize(buf, l1 + l2);
    free(buf);
    return res;
}

EXPORT int PyUnicode_Compare(PyObject *left, PyObject *right) {
    const char *s1 = PyUnicode_AsUTF8(left);
    const char *s2 = PyUnicode_AsUTF8(right);
    return strcmp(s1, s2);
}

EXPORT int PyUnicode_CompareWithASCIIString(PyObject *uni, const char *string) {
    const char *s = PyUnicode_AsUTF8(uni);
    return strcmp(s, string ? string : "");
}

EXPORT int PyUnicode_Contains(PyObject *container, PyObject *element) {
    const char *haystack = PyUnicode_AsUTF8(container);
    const char *needle = PyUnicode_AsUTF8(element);
    return strstr(haystack, needle) != NULL;
}

EXPORT int PyUnicode_Tailmatch(PyObject *str, PyObject *substr, Py_ssize_t start, Py_ssize_t end, int direction) {
    const char *s = PyUnicode_AsUTF8(str);
    const char *sub = PyUnicode_AsUTF8(substr);
    size_t len_s = strlen(s), len_sub = strlen(sub);
    (void)start; (void)end;
    if (direction > 0) { /* endswith */
        if (len_sub > len_s) return 0;
        return memcmp(s + len_s - len_sub, sub, len_sub) == 0;
    } else { /* startswith */
        if (len_sub > len_s) return 0;
        return memcmp(s, sub, len_sub) == 0;
    }
}

EXPORT PyObject* PyUnicode_Replace(PyObject *str, PyObject *substr, PyObject *replstr, Py_ssize_t maxcount) {
    (void)maxcount;
    (void)substr;
    (void)replstr;
    Py_IncRef(str);
    return str;
}

EXPORT PyObject* PyUnicode_Format(PyObject *format, PyObject *args) {
    (void)args;
    Py_IncRef(format);
    return format;
}

EXPORT PyObject* PyUnicode_FromFormat(const char *format, ...) {
    char buf[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    return PyUnicode_FromString(buf);
}

EXPORT PyObject* PyUnicode_FromFormatV(const char *format, va_list vargs) {
    char buf[1024];
    vsnprintf(buf, sizeof(buf), format, vargs);
    return PyUnicode_FromString(buf);
}

EXPORT PyObject* PyUnicode_FromKindAndData(int kind, const void *buffer, Py_ssize_t size) {
    (void)kind;
    return PyUnicode_FromStringAndSize((const char *)buffer, size);
}

EXPORT PyObject* PyUnicode_FromObject(PyObject *obj) {
    return PyObject_Str(obj);
}

EXPORT PyObject* PyUnicode_FromEncodedObject(PyObject *obj, const char *encoding, const char *errors) {
    (void)encoding; (void)errors;
    return PyObject_Str(obj);
}

EXPORT PyObject* PyUnicode_AsASCIIString(PyObject *unicode) {
    const char *s = PyUnicode_AsUTF8(unicode);
    return PyBytes_FromString(s);
}

EXPORT PyObject* PyUnicode_AsUTF8String(PyObject *unicode) {
    const char *s = PyUnicode_AsUTF8(unicode);
    return PyBytes_FromString(s);
}

EXPORT PyObject* PyUnicode_AsEncodedString(PyObject *unicode, const char *encoding, const char *errors) {
    (void)encoding; (void)errors;
    const char *s = PyUnicode_AsUTF8(unicode);
    return PyBytes_FromString(s);
}

EXPORT unsigned int* PyUnicode_AsUCS4(PyObject *unicode, unsigned int *copy, Py_ssize_t max_len, int init_first_mask) {
    (void)unicode; (void)init_first_mask;
    if (copy && max_len > 0) copy[0] = 0;
    return copy;
}

EXPORT unsigned int* PyUnicode_AsUCS4Copy(PyObject *unicode) {
    Py_ssize_t len = PyUnicode_GetLength(unicode);
    unsigned int *ucs4 = (unsigned int *)calloc(len + 1, sizeof(unsigned int));
    const char *s = PyUnicode_AsUTF8(unicode);
    for (Py_ssize_t i = 0; i < len; i++) ucs4[i] = (unsigned char)s[i];
    return ucs4;
}

/* Character Classification Helpers */
typedef uint32_t Py_UCS4;
EXPORT int _PyUnicode_IsAlpha(Py_UCS4 ch) { return ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')); }
EXPORT int _PyUnicode_IsDigit(Py_UCS4 ch) { return (ch >= '0' && ch <= '9'); }
EXPORT int _PyUnicode_IsDecimalDigit(Py_UCS4 ch) { return (ch >= '0' && ch <= '9'); }
EXPORT int _PyUnicode_IsNumeric(Py_UCS4 ch) { return (ch >= '0' && ch <= '9'); }
EXPORT int _PyUnicode_IsLowercase(Py_UCS4 ch) { return (ch >= 'a' && ch <= 'z'); }
EXPORT int _PyUnicode_IsUppercase(Py_UCS4 ch) { return (ch >= 'A' && ch <= 'Z'); }
EXPORT int _PyUnicode_IsTitlecase(Py_UCS4 ch) { return (ch >= 'A' && ch <= 'Z'); }
EXPORT int _PyUnicode_IsWhitespace(const Py_UCS4 ch) {
    return (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f' || ch == '\v');
}
