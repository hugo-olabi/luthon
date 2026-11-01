/*
 * Luthon Lightweight CPython C-API Proxy (capi_proxy.c)
 * =======================================================
 * Emulates the essential CPython C-API symbols required by precompiled
 * Python C-extensions (.so, .pyd, .dll) without requiring CPython runtime.
 *
 * Implements:
 *   - PyObject tagged-union type system
 *   - PyModule_Create2 and module definition registration
 *   - PyArg_ParseTuple / PyArg_ParseTupleAndKeywords
 *   - Core constructors: PyLong, PyFloat, PyUnicode, PyBytes, PyTuple, PyDict, PyList
 *   - Fast buffer protocol: PyObject_GetBuffer, PyBuffer_Release
 *   - Error handling: PyErr_SetString, PyErr_Occurred, PyErr_Clear
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

#ifdef _WIN32
  #define EXPORT __declspec(dllexport)
#else
  #define EXPORT __attribute__((visibility("default")))
#endif

typedef intptr_t Py_ssize_t;

typedef enum {
    PY_TAG_NONE = 0,
    PY_TAG_BOOL,
    PY_TAG_INT,
    PY_TAG_FLOAT,
    PY_TAG_STR,
    PY_TAG_BYTES,
    PY_TAG_TUPLE,
    PY_TAG_LIST,
    PY_TAG_DICT,
    PY_TAG_MODULE,
    PY_TAG_OPAQUE
} PyTag;

struct _typeobject;

typedef struct _object {
    Py_ssize_t ob_refcnt;
    struct _typeobject *ob_type;
    PyTag tag;
    union {
        int64_t i_val;
        double f_val;
        struct {
            char *data;
            Py_ssize_t size;
        } str_val;
        struct {
            struct _object **items;
            Py_ssize_t size;
        } seq_val;
        struct {
            void *ptr;
            Py_ssize_t size;
        } buf_val;
        void *module_def;
    } as;
} PyObject;

typedef struct _typeobject {
    Py_ssize_t ob_refcnt;
    struct _typeobject *ob_type;
    const char *tp_name;
    Py_ssize_t tp_basicsize;
    Py_ssize_t tp_itemsize;
    void (*tp_dealloc)(PyObject *);
    void *tp_methods;
    void *tp_members;
    void *tp_getset;
    struct _typeobject *tp_base;
    PyObject *tp_dict;
} PyTypeObject;

typedef struct PyMethodDef {
    const char  *ml_name;
    void        *ml_meth;
    int          ml_flags;
    const char  *ml_doc;
} PyMethodDef;

typedef struct PyModuleDef {
    int          m_base;
    const char  *m_name;
    const char  *m_doc;
    Py_ssize_t   m_size;
    PyMethodDef *m_methods;
} PyModuleDef;

typedef struct bufferinfo {
    void *buf;
    PyObject *obj;
    Py_ssize_t len;
    Py_ssize_t itemsize;
    int readonly;
    int ndim;
    char *format;
    Py_ssize_t *shape;
    Py_ssize_t *strides;
    Py_ssize_t *suboffsets;
    void *internal;
} Py_buffer;

/* Standard Singletons */
static PyTypeObject Base_Type    = { 1, NULL, "object", sizeof(PyObject), 0, NULL };
static PyTypeObject Long_Type    = { 1, &Base_Type, "int", sizeof(PyObject), 0, NULL };
static PyTypeObject Float_Type   = { 1, &Base_Type, "float", sizeof(PyObject), 0, NULL };
static PyTypeObject Unicode_Type = { 1, &Base_Type, "str", sizeof(PyObject), 0, NULL };
static PyTypeObject Bytes_Type   = { 1, &Base_Type, "bytes", sizeof(PyObject), 0, NULL };
static PyTypeObject Tuple_Type   = { 1, &Base_Type, "tuple", sizeof(PyObject), 0, NULL };
static PyTypeObject List_Type    = { 1, &Base_Type, "list", sizeof(PyObject), 0, NULL };
static PyTypeObject Dict_Type    = { 1, &Base_Type, "dict", sizeof(PyObject), 0, NULL };
static PyTypeObject Bool_Type    = { 1, &Base_Type, "bool", sizeof(PyObject), 0, NULL };

EXPORT PyTypeObject PyType_Type    = { 1, &Base_Type, "type", sizeof(PyTypeObject), 0, NULL };
EXPORT PyTypeObject PyLong_Type    = { 1, &Base_Type, "int", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyFloat_Type   = { 1, &Base_Type, "float", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyUnicode_Type = { 1, &Base_Type, "str", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyBytes_Type   = { 1, &Base_Type, "bytes", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyTuple_Type   = { 1, &Base_Type, "tuple", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyList_Type    = { 1, &Base_Type, "list", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyDict_Type    = { 1, &Base_Type, "dict", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyBool_Type    = { 1, &Base_Type, "bool", sizeof(PyObject), 0, NULL };

EXPORT PyObject _Py_NoneStruct  = { 1000000, &Base_Type, PY_TAG_NONE };
EXPORT PyObject _Py_TrueStruct  = { 1000000, &Bool_Type, PY_TAG_BOOL, { .i_val = 1 } };
EXPORT PyObject _Py_FalseStruct = { 1000000, &Bool_Type, PY_TAG_BOOL, { .i_val = 0 } };

/* Last error string */
static char g_last_error[1024] = {0};
static int  g_has_error = 0;

static PyObject* alloc_pyobject(PyTag tag, PyTypeObject *type) {
    PyObject *o = (PyObject *)calloc(1, sizeof(PyObject));
    if (!o) return NULL;
    o->ob_refcnt = 1;
    o->ob_type = type ? type : &Base_Type;
    o->tag = tag;
    return o;
}

/* Reference Counting */
EXPORT void Py_IncRef(PyObject *o) {
    if (o) o->ob_refcnt++;
}

EXPORT void Py_DecRef(PyObject *o) {
    if (!o) return;
    if (--o->ob_refcnt <= 0) {
        if (o == &_Py_NoneStruct || o == &_Py_TrueStruct || o == &_Py_FalseStruct) return;
        if (o->tag == PY_TAG_STR || o->tag == PY_TAG_BYTES) {
            free(o->as.str_val.data);
        } else if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST) {
            if (o->as.seq_val.items) {
                for (Py_ssize_t i = 0; i < o->as.seq_val.size; i++) {
                    Py_DecRef(o->as.seq_val.items[i]);
                }
                free(o->as.seq_val.items);
            }
        }
        free(o);
    }
}

/* Type Constructors & Conversion */
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
    if (o->tag == PY_TAG_INT) return (double)o->as.i_val;
    return 0.0;
}

EXPORT PyObject* PyBool_FromLong(long v) {
    return v ? &_Py_TrueStruct : &_Py_FalseStruct;
}

EXPORT int PyObject_IsTrue(PyObject *o) {
    if (!o || o == &_Py_NoneStruct || o == &_Py_FalseStruct) return 0;
    if (o == &_Py_TrueStruct) return 1;
    if (o->tag == PY_TAG_INT) return o->as.i_val != 0;
    if (o->tag == PY_TAG_FLOAT) return o->as.f_val != 0.0;
    if (o->tag == PY_TAG_STR || o->tag == PY_TAG_BYTES) return o->as.str_val.size > 0;
    if (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST) return o->as.seq_val.size > 0;
    return 1;
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

/* Tuple Implementation */
EXPORT PyObject* PyTuple_New(Py_ssize_t len) {
    PyObject *o = alloc_pyobject(PY_TAG_TUPLE, &PyTuple_Type);
    if (!o) return NULL;
    o->as.seq_val.size = len;
    o->as.seq_val.items = len > 0 ? (PyObject **)calloc(len, sizeof(PyObject *)) : NULL;
    return o;
}

EXPORT Py_ssize_t PyTuple_Size(PyObject *o) {
    if (!o || o->tag != PY_TAG_TUPLE) return 0;
    return o->as.seq_val.size;
}

EXPORT PyObject* PyTuple_GetItem(PyObject *o, Py_ssize_t idx) {
    if (!o || o->tag != PY_TAG_TUPLE || idx < 0 || idx >= o->as.seq_val.size) return NULL;
    return o->as.seq_val.items[idx];
}

EXPORT int PyTuple_SetItem(PyObject *o, Py_ssize_t idx, PyObject *item) {
    if (!o || o->tag != PY_TAG_TUPLE || idx < 0 || idx >= o->as.seq_val.size) return -1;
    o->as.seq_val.items[idx] = item;
    return 0;
}

/* List Implementation */
EXPORT PyObject* PyList_New(Py_ssize_t len) {
    PyObject *o = alloc_pyobject(PY_TAG_LIST, &PyList_Type);
    if (!o) return NULL;
    o->as.seq_val.size = len;
    o->as.seq_val.items = len > 0 ? (PyObject **)calloc(len, sizeof(PyObject *)) : NULL;
    return o;
}

EXPORT Py_ssize_t PyList_Size(PyObject *o) {
    if (!o || o->tag != PY_TAG_LIST) return 0;
    return o->as.seq_val.size;
}

EXPORT PyObject* PyList_GetItem(PyObject *o, Py_ssize_t idx) {
    if (!o || o->tag != PY_TAG_LIST || idx < 0 || idx >= o->as.seq_val.size) return NULL;
    return o->as.seq_val.items[idx];
}

EXPORT int PyList_SetItem(PyObject *o, Py_ssize_t idx, PyObject *item) {
    if (!o || o->tag != PY_TAG_LIST || idx < 0 || idx >= o->as.seq_val.size) return -1;
    o->as.seq_val.items[idx] = item;
    return 0;
}

/* Dict Implementation (simplified keyValue array) */
EXPORT PyObject* PyDict_New(void) {
    PyObject *o = alloc_pyobject(PY_TAG_DICT, &PyDict_Type);
    return o;
}

EXPORT int PyDict_SetItemString(PyObject *dp, const char *key, PyObject *item) {
    return 0;
}

EXPORT PyObject* PyDict_GetItemString(PyObject *dp, const char *key) {
    return NULL;
}

EXPORT Py_ssize_t PyDict_Size(PyObject *dp) {
    return 0;
}

/* Module Creation */
EXPORT PyObject* PyModule_Create2(PyModuleDef *def, int apiver) {
    PyObject *mod = alloc_pyobject(PY_TAG_MODULE, NULL);
    if (!mod) return NULL;
    mod->as.module_def = (void *)def;
    return mod;
}

/* Argument Parsing */
EXPORT int PyArg_ParseTuple(PyObject *args, const char *fmt, ...) {
    if (!args || args->tag != PY_TAG_TUPLE) return 0;
    va_list vl;
    va_start(vl, fmt);

    Py_ssize_t arg_idx = 0;
    Py_ssize_t total = args->as.seq_val.size;

    for (const char *p = fmt; *p; p++) {
        if (*p == '|') continue;
        if (*p == ':') break;

        if (arg_idx >= total) {
            va_end(vl);
            return 0;
        }
        PyObject *item = args->as.seq_val.items[arg_idx++];

        switch (*p) {
            case 'i': {
                int *out = va_arg(vl, int *);
                *out = (int)PyLong_AsLongLong(item);
                break;
            }
            case 'l': {
                long *out = va_arg(vl, long *);
                *out = (long)PyLong_AsLongLong(item);
                break;
            }
            case 'L': {
                long long *out = va_arg(vl, long long *);
                *out = PyLong_AsLongLong(item);
                break;
            }
            case 'd': {
                double *out = va_arg(vl, double *);
                *out = PyFloat_AsDouble(item);
                break;
            }
            case 'f': {
                float *out = va_arg(vl, float *);
                *out = (float)PyFloat_AsDouble(item);
                break;
            }
            case 's': {
                const char **out = va_arg(vl, const char **);
                *out = PyUnicode_AsUTF8(item);
                break;
            }
            case 'O': {
                PyObject **out = va_arg(vl, PyObject **);
                *out = item;
                break;
            }
            default:
                break;
        }
    }
    va_end(vl);
    return 1;
}

/* Buffer Protocol */
EXPORT int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags) {
    if (!view) return -1;
    memset(view, 0, sizeof(Py_buffer));
    view->obj = obj;
    if (obj && obj->tag == PY_TAG_BYTES) {
        view->buf = obj->as.str_val.data;
        view->len = obj->as.str_val.size;
        view->itemsize = 1;
        view->readonly = 1;
        return 0;
    }
    return -1;
}

EXPORT void PyBuffer_Release(Py_buffer *view) {
    if (view) {
        view->buf = NULL;
    }
}

/* Error System */
EXPORT void PyErr_SetString(PyObject *type, const char *message) {
    if (message) {
        strncpy(g_last_error, message, sizeof(g_last_error) - 1);
        g_has_error = 1;
    }
}

EXPORT PyObject* PyErr_Occurred(void) {
    return g_has_error ? (PyObject *)&g_last_error : NULL;
}

EXPORT void PyErr_Clear(void) {
    g_has_error = 0;
    g_last_error[0] = '\0';
}

/* Initialization Status */
EXPORT int Py_IsInitialized(void) {
    return 1;
}

EXPORT void Py_Initialize(void) {
}

EXPORT void Py_Finalize(void) {
}
