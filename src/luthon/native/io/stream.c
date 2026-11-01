/*
 * Luthon C-API Proxy: Native Stream Protocol (io/stream.c)
 * ========================================================
 * Provides zero-copy file-like byte stream operations for Pillow and NumPy
 * eliminating PyBridge delegation for io.BytesIO.
 */

#include "luthon_capi.h"

EXPORT PyObject* PyStream_New(Py_ssize_t initial_capacity) {
    PyObject *o = alloc_pyobject(PY_TAG_STREAM, &PyStream_Type);
    if (!o) return NULL;
    if (initial_capacity < 64) initial_capacity = 64;
    o->as.stream_val.buffer = (uint8_t *)malloc(initial_capacity);
    o->as.stream_val.capacity = initial_capacity;
    o->as.stream_val.size = 0;
    o->as.stream_val.pos = 0;
    o->as.stream_val.is_readonly = 0;
    return o;
}

EXPORT PyObject* PyStream_FromBytes(const void *data, Py_ssize_t size) {
    PyObject *o = alloc_pyobject(PY_TAG_STREAM, &PyStream_Type);
    if (!o) return NULL;
    o->as.stream_val.buffer = (uint8_t *)malloc(size > 0 ? size : 1);
    if (data && size > 0 && o->as.stream_val.buffer) {
        memcpy(o->as.stream_val.buffer, data, size);
    }
    o->as.stream_val.capacity = size > 0 ? size : 1;
    o->as.stream_val.size = size;
    o->as.stream_val.pos = 0;
    o->as.stream_val.is_readonly = 0;
    return o;
}

EXPORT Py_ssize_t PyStream_Read(PyObject *stream, void *dest, Py_ssize_t size) {
    if (!stream || stream->tag != PY_TAG_STREAM || !dest || size <= 0) return 0;
    PyStreamObject *st = &stream->as.stream_val;
    if (st->pos >= st->size) return 0;

    Py_ssize_t avail = st->size - st->pos;
    Py_ssize_t to_read = (size < avail) ? size : avail;
    memcpy(dest, st->buffer + st->pos, to_read);
    st->pos += to_read;
    return to_read;
}

EXPORT Py_ssize_t PyStream_Write(PyObject *stream, const void *src, Py_ssize_t size) {
    if (!stream || stream->tag != PY_TAG_STREAM || !src || size <= 0) return 0;
    PyStreamObject *st = &stream->as.stream_val;
    if (st->is_readonly) return -1;

    Py_ssize_t req = st->pos + size;
    if (req > st->capacity) {
        Py_ssize_t new_cap = st->capacity * 2;
        if (new_cap < req) new_cap = req + 64;
        uint8_t *new_buf = (uint8_t *)realloc(st->buffer, new_cap);
        if (!new_buf) return -1;
        st->buffer = new_buf;
        st->capacity = new_cap;
    }

    memcpy(st->buffer + st->pos, src, size);
    st->pos += size;
    if (st->pos > st->size) st->size = st->pos;
    return size;
}

EXPORT Py_ssize_t PyStream_Seek(PyObject *stream, Py_ssize_t offset, int whence) {
    if (!stream || stream->tag != PY_TAG_STREAM) return -1;
    PyStreamObject *st = &stream->as.stream_val;

    Py_ssize_t new_pos = st->pos;
    switch (whence) {
        case 0: /* SEEK_SET */
            new_pos = offset;
            break;
        case 1: /* SEEK_CUR */
            new_pos = st->pos + offset;
            break;
        case 2: /* SEEK_END */
            new_pos = st->size + offset;
            break;
        default:
            return -1;
    }

    if (new_pos < 0) return -1;
    st->pos = new_pos;
    return st->pos;
}

EXPORT Py_ssize_t PyStream_Tell(PyObject *stream) {
    if (!stream || stream->tag != PY_TAG_STREAM) return -1;
    return stream->as.stream_val.pos;
}

EXPORT const uint8_t* PyStream_GetBuffer(PyObject *stream, Py_ssize_t *size) {
    if (!stream || stream->tag != PY_TAG_STREAM) {
        if (size) *size = 0;
        return NULL;
    }
    if (size) *size = stream->as.stream_val.size;
    return stream->as.stream_val.buffer;
}
