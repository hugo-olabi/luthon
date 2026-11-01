/*
 * Luthon C-API Proxy: Module Loader & Reflection Dispatch (modules/loader.c)
 */

#include "luthon_capi.h"

static char g_last_error[1024] = {0};
static int  g_has_error = 0;

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

/* Error Handling */
EXPORT void PyErr_SetString(PyObject *type, const char *message) {
    (void)type;
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

/* Lifecycle */
EXPORT int Py_IsInitialized(void) {
    return 1;
}

EXPORT void Py_Initialize(void) {
}

EXPORT void Py_Finalize(void) {
}
