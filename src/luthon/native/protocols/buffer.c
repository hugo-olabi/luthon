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
