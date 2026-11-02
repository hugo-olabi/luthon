/*
 * Luthon C-API Proxy: Buffer Protocol (protocols/buffer.c)
 */

#include "luthon_capi.h"

EXPORT int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags) {
    (void)flags;
    if (!view) return -1;
    memset(view, 0, sizeof(Py_buffer));
    view->obj = obj;

    if (!obj) return -1;

    /* Bytes buffer */
    if (obj->tag == PY_TAG_BYTES) {
        view->buf = obj->as.str_val.data;
        view->len = obj->as.str_val.size;
        view->itemsize = 1;
        view->readonly = 1;
        view->ndim = 1;
        view->format = "B";
        return 0;
    }

    /* Native Stream / BytesIO buffer */
    if (obj->tag == PY_TAG_STREAM) {
        view->buf = obj->as.stream_val.buffer;
        view->len = obj->as.stream_val.size;
        view->itemsize = 1;
        view->readonly = obj->as.stream_val.is_readonly;
        view->ndim = 1;
        view->format = "B";
        return 0;
    }

    /* Custom tp_as_buffer handler if defined */
    if (obj->ob_type && obj->ob_type->tp_as_buffer) {
        typedef int (*getbufferproc)(PyObject *, Py_buffer *, int);
        getbufferproc proc = (getbufferproc)obj->ob_type->tp_as_buffer;
        return proc(obj, view, flags);
    }

    return -1;
}

EXPORT void PyBuffer_Release(Py_buffer *view) {
    if (view) {
        view->buf = NULL;
        view->obj = NULL;
    }
}

EXPORT int PyObject_CheckBuffer(PyObject *obj) {
    if (!obj) return 0;
    if (obj->tag == PY_TAG_BYTES || obj->tag == PY_TAG_STREAM) return 1;
    if (obj->ob_type && obj->ob_type->tp_as_buffer) return 1;
    return 0;
}

EXPORT int PyBytes_AsStringAndSize(PyObject *obj, char **s, Py_ssize_t *len) {
    if (!obj || obj->tag != PY_TAG_BYTES) {
        PyErr_SetString(PyExc_TypeError, "expected bytes object");
        return -1;
    }
    if (s) *s = obj->as.str_val.data;
    if (len) *len = obj->as.str_val.size;
    return 0;
}

EXPORT int _PyBytes_Resize(PyObject **pv, Py_ssize_t newsize) {
    if (!pv || !*pv || (*pv)->tag != PY_TAG_BYTES) {
        PyErr_SetString(PyExc_TypeError, "expected bytes object");
        return -1;
    }
    PyObject *v = *pv;
    char *new_data = (char *)realloc(v->as.str_val.data, newsize + 1);
    if (!new_data && newsize > 0) {
        PyErr_NoMemory();
        return -1;
    }
    v->as.str_val.data = new_data;
    v->as.str_val.size = newsize;
    if (new_data) new_data[newsize] = '\0';
    return 0;
}

EXPORT PyObject* PyUnicode_AsLatin1String(PyObject *unicode) {
    if (!unicode || unicode->tag != PY_TAG_STR) {
        PyErr_SetString(PyExc_TypeError, "expected str object");
        return NULL;
    }
    return PyBytes_FromStringAndSize(unicode->as.str_val.data, unicode->as.str_val.size);
}
