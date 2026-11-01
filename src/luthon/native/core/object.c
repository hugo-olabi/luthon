/*
 * Luthon C-API Proxy: Core Object System (core/object.c)
 */

#include "luthon_capi.h"

/* Standard Singletons */
EXPORT PyObject _Py_NoneStruct  = { 1000000000, &Base_Type, PY_TAG_NONE };
EXPORT PyObject _Py_TrueStruct  = { 1000000000, &PyBool_Type, PY_TAG_BOOL, { .i_val = 1 } };
EXPORT PyObject _Py_FalseStruct = { 1000000000, &PyBool_Type, PY_TAG_BOOL, { .i_val = 0 } };

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
        } else if (o->tag == PY_TAG_SLICE) {
            Py_DecRef(o->as.slice_val.start);
            Py_DecRef(o->as.slice_val.stop);
            Py_DecRef(o->as.slice_val.step);
        } else if (o->tag == PY_TAG_STREAM) {
            if (o->as.stream_val.buffer) {
                free(o->as.stream_val.buffer);
            }
        }
        free(o);
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
