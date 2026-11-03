/*
 * Luthon C-API Proxy: Multi-Dimensional Buffer Protocol (PEP 3118) & GC Lifetime Sync (protocols/buffer.c)
 */

#include "luthon_capi.h"
#include <ctype.h>

/* Central dual-ownership GC pointer registry */
typedef struct GCRegistryEntry {
    void *cdata_ptr;
    PyObject *py_obj;
    int is_owned;
    struct GCRegistryEntry *next;
} GCRegistryEntry;

#define GC_HASH_SIZE 1024
static GCRegistryEntry* g_gc_table[GC_HASH_SIZE];

static inline size_t gc_hash(void *ptr) {
    uintptr_t val = (uintptr_t)ptr;
    return (size_t)((val ^ (val >> 12) ^ (val >> 20)) % GC_HASH_SIZE);
}

EXPORT void luthon_gc_register(void *cdata_ptr, PyObject *py_obj, int is_owned) {
    if (!cdata_ptr || !py_obj) return;
    size_t h = gc_hash(cdata_ptr);
    GCRegistryEntry *entry = (GCRegistryEntry *)malloc(sizeof(GCRegistryEntry));
    if (!entry) return;
    entry->cdata_ptr = cdata_ptr;
    entry->py_obj = py_obj;
    entry->is_owned = is_owned;
    entry->next = g_gc_table[h];
    g_gc_table[h] = entry;
    if (is_owned) {
        Py_IncRef(py_obj);
    }
}

EXPORT void luthon_gc_unregister(void *cdata_ptr) {
    if (!cdata_ptr) return;
    size_t h = gc_hash(cdata_ptr);
    GCRegistryEntry **curr = &g_gc_table[h];
    while (*curr) {
        if ((*curr)->cdata_ptr == cdata_ptr) {
            GCRegistryEntry *to_free = *curr;
            *curr = to_free->next;
            if (to_free->is_owned && to_free->py_obj) {
                Py_DecRef(to_free->py_obj);
            }
            free(to_free);
            return;
        }
        curr = &(*curr)->next;
    }
}

EXPORT PyObject* luthon_gc_lookup(void *cdata_ptr) {
    if (!cdata_ptr) return NULL;
    size_t h = gc_hash(cdata_ptr);
    for (GCRegistryEntry *e = g_gc_table[h]; e; e = e->next) {
        if (e->cdata_ptr == cdata_ptr) {
            return e->py_obj;
        }
    }
    return NULL;
}

EXPORT void luthon_gc_dec_ref(PyObject *py_obj) {
    if (py_obj) {
        Py_DecRef(py_obj);
    }
}

/* PEP 3118 Format string itemsize calculation */
EXPORT Py_ssize_t PyBuffer_SizeFromFormat(const char *format) {
    if (!format || !*format) return 1;

    /* Skip standard byte order / alignment prefix (@, =, <, >, !) */
    while (*format == '@' || *format == '=' || *format == '<' || *format == '>' || *format == '!') {
        format++;
    }

    /* Parse repeat count if present */
    Py_ssize_t repeat = 0;
    while (isdigit((unsigned char)*format)) {
        repeat = repeat * 10 + (*format - '0');
        format++;
    }
    if (repeat == 0) repeat = 1;

    Py_ssize_t base_size = 1;
    switch (*format) {
        case 'c':
        case 'b':
        case 'B':
        case '?':
            base_size = 1;
            break;
        case 'h':
        case 'H':
            base_size = 2;
            break;
        case 'i':
        case 'I':
        case 'l':
        case 'L':
            base_size = 4;
            break;
        case 'q':
        case 'Q':
            base_size = 8;
            break;
        case 'f':
            base_size = 4;
            break;
        case 'd':
            base_size = 8;
            break;
        case 'P':
            base_size = sizeof(void *);
            break;
        default:
            base_size = 1;
            break;
    }

    return base_size * repeat;
}

EXPORT int PyBuffer_FillContiguousStrides(int ndims, Py_ssize_t *shape, Py_ssize_t *strides, int itemsize, char fort) {
    if (!strides) return 0;
    Py_ssize_t sd = itemsize;
    if (fort == 'F' || fort == 'f') {
        for (int i = 0; i < ndims; i++) {
            strides[i] = sd;
            sd *= shape[i];
        }
    } else {
        for (int i = ndims - 1; i >= 0; i--) {
            strides[i] = sd;
            sd *= shape[i];
        }
    }
    return 0;
}

EXPORT int PyBuffer_IsContiguous(const Py_buffer *view, char fort) {
    if (!view) return 0;
    if (view->ndim == 0) return 1;
    if (!view->strides) return 1;

    Py_ssize_t sd = view->itemsize;
    if (fort == 'F' || fort == 'f') {
        for (int i = 0; i < view->ndim; i++) {
            if (view->shape[i] > 1 && view->strides[i] != sd) return 0;
            sd *= view->shape[i];
        }
    } else {
        for (int i = view->ndim - 1; i >= 0; i--) {
            if (view->shape[i] > 1 && view->strides[i] != sd) return 0;
            sd *= view->shape[i];
        }
    }
    return 1;
}

EXPORT int PyBuffer_FillInfo(Py_buffer *view, PyObject *o, void *buf, Py_ssize_t len, int readonly, int flags) {
    if (!view) return -1;
    memset(view, 0, sizeof(Py_buffer));

    if ((flags & PyBUF_WRITABLE) && readonly) {
        PyErr_SetString(PyExc_BufferError, "Object is not writable");
        return -1;
    }

    view->obj = o;
    if (o) {
        Py_IncRef(o);
        o->buf_locks++;
    }

    view->buf = buf;
    view->len = len;
    view->readonly = readonly;
    view->itemsize = 1;
    view->format = NULL;

    if ((flags & PyBUF_FORMAT)) {
        view->format = "B";
    }

    if ((flags & PyBUF_ND)) {
        view->ndim = 1;
        /* Allocate space for shape/strides in internal */
        Py_ssize_t *shapes = (Py_ssize_t *)malloc(sizeof(Py_ssize_t) * 2);
        if (!shapes) {
            PyErr_NoMemory();
            return -1;
        }
        shapes[0] = len;
        shapes[1] = 1;
        view->shape = &shapes[0];
        view->strides = (flags & PyBUF_STRIDES) ? &shapes[1] : NULL;
        view->internal = shapes;
    } else {
        view->ndim = 0;
        view->shape = NULL;
        view->strides = NULL;
    }

    view->suboffsets = NULL;
    return 0;
}

EXPORT int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags) {
    if (!view) return -1;
    memset(view, 0, sizeof(Py_buffer));

    if (!obj) {
        PyErr_SetString(PyExc_BufferError, "NULL object cannot be exported as buffer");
        return -1;
    }

    /* 1. Custom tp_as_buffer handler if defined */
    if (obj->ob_type && obj->ob_type->tp_as_buffer) {
        PyBufferProcs *bp = (PyBufferProcs *)obj->ob_type->tp_as_buffer;
        if (bp->bf_getbuffer) {
            int ret = bp->bf_getbuffer(obj, view, flags);
            if (ret == 0) {
                obj->buf_locks++;
                Py_IncRef(obj);
            }
            return ret;
        }
    }

    /* 2. Bytes buffer */
    if (obj->tag == PY_TAG_BYTES) {
        return PyBuffer_FillInfo(view, obj, obj->as.str_val.data, obj->as.str_val.size, 1, flags);
    }

    /* 3. Native Stream / BytesIO buffer */
    if (obj->tag == PY_TAG_STREAM) {
        return PyBuffer_FillInfo(view, obj, obj->as.stream_val.buffer, obj->as.stream_val.size,
                                 obj->as.stream_val.is_readonly, flags);
    }

    PyErr_Format(PyExc_TypeError, "a bytes-like object is required, not '%s'",
                 (obj->ob_type && obj->ob_type->tp_name) ? obj->ob_type->tp_name : "object");
    return -1;
}

EXPORT void PyBuffer_Release(Py_buffer *view) {
    if (!view) return;

    PyObject *obj = view->obj;
    if (obj) {
        if (obj->buf_locks > 0) {
            obj->buf_locks--;
        }

        if (obj->ob_type && obj->ob_type->tp_as_buffer) {
            PyBufferProcs *bp = (PyBufferProcs *)obj->ob_type->tp_as_buffer;
            if (bp->bf_releasebuffer) {
                bp->bf_releasebuffer(obj, view);
            }
        }
        Py_DecRef(obj);
    }

    if (view->internal) {
        free(view->internal);
        view->internal = NULL;
    }

    view->buf = NULL;
    view->obj = NULL;
}

EXPORT int PyObject_CheckBuffer(PyObject *obj) {
    if (!obj) return 0;
    if (obj->tag == PY_TAG_BYTES || obj->tag == PY_TAG_STREAM) return 1;
    if (obj->ob_type && obj->ob_type->tp_as_buffer) {
        PyBufferProcs *bp = (PyBufferProcs *)obj->ob_type->tp_as_buffer;
        if (bp->bf_getbuffer != NULL) return 1;
    }
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
    /* Buffer locking check: cannot resize if active buffer exports exist */
    if (v->buf_locks > 0) {
        PyErr_SetString(PyExc_BufferError, "Existing exports of data: object cannot be reallocated");
        return -1;
    }

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
