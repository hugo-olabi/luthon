/*
 * Luthon C-API Proxy: Sequence Protocols (protocols/sequence.c)
 */

#include "luthon_capi.h"

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

EXPORT int PyList_Append(PyObject *op, PyObject *newitem) {
    if (!op || op->tag != PY_TAG_LIST) return -1;
    Py_ssize_t old_sz = op->as.seq_val.size;
    PyObject **new_items = (PyObject **)realloc(op->as.seq_val.items, (old_sz + 1) * sizeof(PyObject *));
    if (!new_items) return -1;
    Py_IncRef(newitem);
    new_items[old_sz] = newitem;
    op->as.seq_val.items = new_items;
    op->as.seq_val.size = old_sz + 1;
    return 0;
}

/* Generic Sequence Protocol */
EXPORT Py_ssize_t PySequence_Size(PyObject *s) {
    if (!s) return 0;
    if (s->tag == PY_TAG_TUPLE || s->tag == PY_TAG_LIST) {
        return s->as.seq_val.size;
    }
    if (s->tag == PY_TAG_STR || s->tag == PY_TAG_BYTES) {
        return s->as.str_val.size;
    }
    if (s->ob_type && s->ob_type->tp_as_sequence && s->ob_type->tp_as_sequence->sq_length) {
        return s->ob_type->tp_as_sequence->sq_length(s);
    }
    return 0;
}

EXPORT PyObject* PySequence_GetItem(PyObject *s, Py_ssize_t i) {
    if (!s) return NULL;
    if (s->tag == PY_TAG_TUPLE) return PyTuple_GetItem(s, i);
    if (s->tag == PY_TAG_LIST) return PyList_GetItem(s, i);
    if (s->ob_type && s->ob_type->tp_as_sequence && s->ob_type->tp_as_sequence->sq_item) {
        return s->ob_type->tp_as_sequence->sq_item(s, i);
    }
    return NULL;
}

EXPORT int PySequence_SetItem(PyObject *s, Py_ssize_t i, PyObject *o) {
    if (!s) return -1;
    if (s->tag == PY_TAG_LIST) return PyList_SetItem(s, i, o);
    if (s->ob_type && s->ob_type->tp_as_sequence && s->ob_type->tp_as_sequence->sq_ass_item) {
        return s->ob_type->tp_as_sequence->sq_ass_item(s, i, o);
    }
    return -1;
}
