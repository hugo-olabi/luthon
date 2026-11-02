/*
 * Luthon C-API Proxy: Module Loader & Reflection Dispatch (modules/loader.c)
 */

#include "luthon_capi.h"

EXPORT PyObject* PyModule_Create2(PyModuleDef *def, int apiver) {
    (void)apiver;
    PyObject *mod = alloc_pyobject(PY_TAG_MODULE, NULL);
    if (!mod) return NULL;
    mod->as.module_def = (void *)def;
    return mod;
}

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

EXPORT int PyArg_ParseTupleAndKeywords(PyObject *args, PyObject *kwargs, const char *fmt, char **kwlist, ...) {
    (void)kwargs; (void)kwlist;
    /* Basic fallback to PyArg_ParseTuple */
    va_list vl;
    va_start(vl, kwlist);
    int res = PyArg_ParseTuple(args, fmt, vl);
    va_end(vl);
    return res;
}

/* Module Attribute and Constant Helpers */
EXPORT PyObject* PyModuleDef_Init(PyModuleDef *def) {
    return PyModule_Create2(def, 3);
}

EXPORT PyObject* PyModule_GetDict(PyObject *mod) {
    if (!mod) return NULL;
    /* Create or return dict */
    PyObject *d = PyDict_New();
    return d;
}

EXPORT int PyModule_AddObjectRef(PyObject *mod, const char *name, PyObject *value) {
    (void)mod; (void)name; (void)value;
    return 0;
}

EXPORT int PyModule_AddIntConstant(PyObject *mod, const char *name, long value) {
    (void)mod; (void)name; (void)value;
    return 0;
}

EXPORT Py_ssize_t PyObject_Size(PyObject *o) {
    return PySequence_Size(o);
}

EXPORT PyObject* Py_BuildValue(const char *format, ...) {
    if (!format || !*format) return Py_None;

    va_list vl;
    va_start(vl, format);

    if (strcmp(format, "i") == 0) {
        int v = va_arg(vl, int);
        va_end(vl);
        return PyLong_FromLong((long)v);
    } else if (strcmp(format, "l") == 0 || strcmp(format, "L") == 0) {
        long long v = va_arg(vl, long long);
        va_end(vl);
        return PyLong_FromLongLong(v);
    } else if (strcmp(format, "d") == 0) {
        double v = va_arg(vl, double);
        va_end(vl);
        return PyFloat_FromDouble(v);
    } else if (strcmp(format, "s") == 0) {
        const char *s = va_arg(vl, const char *);
        va_end(vl);
        return s ? PyUnicode_FromString(s) : Py_None;
    } else if (strcmp(format, "O") == 0) {
        PyObject *o = va_arg(vl, PyObject *);
        va_end(vl);
        if (o) Py_IncRef(o);
        return o ? o : Py_None;
    } else if (strcmp(format, "(ii)") == 0) {
        int a = va_arg(vl, int);
        int b = va_arg(vl, int);
        va_end(vl);
        PyObject *t = PyTuple_New(2);
        if (t) {
            PyTuple_SetItem(t, 0, PyLong_FromLong(a));
            PyTuple_SetItem(t, 1, PyLong_FromLong(b));
        }
        return t;
    }

    va_end(vl);
    return Py_None;
}

EXPORT PyObject* PyObject_CallFunction(PyObject *callable, const char *format, ...) {
    if (!callable) return NULL;
    va_list vl;
    va_start(vl, format);
    /* For simple 0 or 1-arg calls */
    PyObject *args = PyTuple_New(0);
    PyObject *res = PyObject_Call(callable, args, NULL);
    Py_DecRef(args);
    va_end(vl);
    return res;
}

EXPORT PyObject* PyObject_CallMethod(PyObject *o, const char *name, const char *format, ...) {
    if (!o || !name) return NULL;
    PyObject *method = PyObject_GetAttrString(o, name);
    if (!method) return NULL;
    va_list vl;
    va_start(vl, format);
    PyObject *args = PyTuple_New(0);
    PyObject *res = PyObject_Call(method, args, NULL);
    Py_DecRef(args);
    Py_DecRef(method);
    va_end(vl);
    return res;
}

/* Lifecycle */
EXPORT int Py_IsInitialized(void) {
    return 1;
}

EXPORT void Py_Initialize(void) {
}

EXPORT void Py_Finalize(void) {
}
