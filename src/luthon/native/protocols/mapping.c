/*
 * Luthon C-API Proxy: Mapping, Subscript & Multi-Dimensional Slicing (protocols/mapping.c)
 */

#include "luthon_capi.h"

/* Dict Implementation (keyValue linear array) */
EXPORT PyObject* PyDict_New(void) {
    PyObject *o = alloc_pyobject(PY_TAG_DICT, &PyDict_Type);
    return o;
}

EXPORT int PyDict_SetItemString(PyObject *dp, const char *key, PyObject *item) {
    (void)dp; (void)key; (void)item;
    return 0;
}

EXPORT PyObject* PyDict_GetItemString(PyObject *dp, const char *key) {
    (void)dp; (void)key;
    return NULL;
}

EXPORT Py_ssize_t PyDict_Size(PyObject *dp) {
    if (!dp || dp->tag != PY_TAG_DICT) return 0;
    return 0;
}

/* Slice Construction */
EXPORT PyObject* PySlice_New(PyObject *start, PyObject *stop, PyObject *step) {
    PyObject *o = alloc_pyobject(PY_TAG_SLICE, &PySlice_Type);
    if (!o) return NULL;
    if (start) Py_IncRef(start);
    if (stop) Py_IncRef(stop);
    if (step) Py_IncRef(step);
    o->as.slice_val.start = start ? start : Py_None;
    o->as.slice_val.stop  = stop  ? stop  : Py_None;
    o->as.slice_val.step  = step  ? step  : Py_None;
    return o;
}

/* Mapping & Subscript Protocol */
EXPORT int PyMapping_Check(PyObject *o) {
    if (!o) return 0;
    if (o->tag == PY_TAG_DICT) return 1;
    if (o->ob_type && o->ob_type->tp_as_mapping && o->ob_type->tp_as_mapping->mp_subscript) return 1;
    return 0;
}

EXPORT PyObject* PyObject_GetItem(PyObject *o, PyObject *key) {
    if (!o || !key) return NULL;

    PyTypeObject *tp = o->ob_type;

    /* 1. Mapping protocol subscript (handles ndarray multi-dim tuple indexing) */
    if (tp && tp->tp_as_mapping && tp->tp_as_mapping->mp_subscript) {
        return tp->tp_as_mapping->mp_subscript(o, key);
    }

    /* 2. Sequence protocol subscript with integer index */
    if (key->tag == PY_TAG_INT || key->tag == PY_TAG_BOOL) {
        Py_ssize_t idx = (Py_ssize_t)key->as.i_val;
        if (o->tag == PY_TAG_TUPLE) return PyTuple_GetItem(o, idx);
        if (o->tag == PY_TAG_LIST) return PyList_GetItem(o, idx);
        if (tp && tp->tp_as_sequence && tp->tp_as_sequence->sq_item) {
            return tp->tp_as_sequence->sq_item(o, idx);
        }
    }

    /* 3. Slice indexing on built-in sequences */
    if (key->tag == PY_TAG_SLICE && (o->tag == PY_TAG_TUPLE || o->tag == PY_TAG_LIST)) {
        Py_ssize_t total = o->as.seq_val.size;
        Py_ssize_t start = 0, stop = total, step = 1;

        if (key->as.slice_val.start && key->as.slice_val.start->tag == PY_TAG_INT) {
            start = (Py_ssize_t)key->as.slice_val.start->as.i_val;
            if (start < 0) start += total;
            if (start < 0) start = 0;
        }
        if (key->as.slice_val.stop && key->as.slice_val.stop->tag == PY_TAG_INT) {
            stop = (Py_ssize_t)key->as.slice_val.stop->as.i_val;
            if (stop < 0) stop += total;
            if (stop > total) stop = total;
        }
        if (key->as.slice_val.step && key->as.slice_val.step->tag == PY_TAG_INT) {
            step = (Py_ssize_t)key->as.slice_val.step->as.i_val;
            if (step == 0) step = 1;
        }

        Py_ssize_t new_len = 0;
        if (step > 0 && start < stop) {
            new_len = (stop - start + step - 1) / step;
        }

        PyObject *res = (o->tag == PY_TAG_TUPLE) ? PyTuple_New(new_len) : PyList_New(new_len);
        if (!res) return NULL;

        Py_ssize_t dest_idx = 0;
        for (Py_ssize_t cur = start; cur < stop && dest_idx < new_len; cur += step) {
            PyObject *elem = o->as.seq_val.items[cur];
            Py_IncRef(elem);
            if (o->tag == PY_TAG_TUPLE) {
                PyTuple_SetItem(res, dest_idx++, elem);
            } else {
                PyList_SetItem(res, dest_idx++, elem);
            }
        }
        return res;
    }

    return NULL;
}

EXPORT int PyObject_SetItem(PyObject *o, PyObject *key, PyObject *v) {
    if (!o || !key) return -1;
    PyTypeObject *tp = o->ob_type;

    if (tp && tp->tp_as_mapping && tp->tp_as_mapping->mp_ass_subscript) {
        return tp->tp_as_mapping->mp_ass_subscript(o, key, v);
    }
    if ((key->tag == PY_TAG_INT || key->tag == PY_TAG_BOOL) && (o->tag == PY_TAG_LIST)) {
        return PyList_SetItem(o, (Py_ssize_t)key->as.i_val, v);
    }
    return -1;
}

EXPORT int PyObject_DelItem(PyObject *o, PyObject *key) {
    return PyObject_SetItem(o, key, NULL);
}

EXPORT int PyDict_GetItemRef(PyObject *p, PyObject *key, PyObject **result) {
    if (!p || !result) return -1;
    *result = NULL;
    if (key && key->tag == PY_TAG_STR) {
        PyObject *v = PyDict_GetItemString(p, PyUnicode_AsUTF8(key));
        if (v) {
            Py_IncRef(v);
            *result = v;
            return 1;
        }
    }
    return 0;
}

EXPORT int PySlice_Unpack(PyObject *r, Py_ssize_t *start, Py_ssize_t *stop, Py_ssize_t *step) {
    if (!r || r->tag != PY_TAG_SLICE) {
        PyErr_SetString(PyExc_TypeError, "expected slice object");
        return -1;
    }
    PySliceObject *s = &r->as.slice_val;
    *start = (s->start && s->start != Py_None) ? (Py_ssize_t)PyLong_AsLongLong(s->start) : 0;
    *stop  = (s->stop && s->stop != Py_None) ? (Py_ssize_t)PyLong_AsLongLong(s->stop) : PY_SSIZE_T_MAX;
    *step  = (s->step && s->step != Py_None) ? (Py_ssize_t)PyLong_AsLongLong(s->step) : 1;
    if (*step == 0) {
        PyErr_SetString(PyExc_ValueError, "slice step cannot be zero");
        return -1;
    }
    return 0;
}

EXPORT Py_ssize_t PySlice_AdjustIndices(Py_ssize_t length, Py_ssize_t *start, Py_ssize_t *stop, Py_ssize_t step) {
    if (step > 0) {
        if (*start < 0) {
            *start += length;
            if (*start < 0) *start = 0;
        } else if (*start > length) {
            *start = length;
        }
        if (*stop < 0) {
            *stop += length;
            if (*stop < 0) *stop = 0;
        } else if (*stop > length) {
            *stop = length;
        }
        if (*start >= *stop) return 0;
        return (*stop - *start + step - 1) / step;
    } else {
        if (*start < 0) {
            *start += length;
            if (*start < -1) *start = -1;
        } else if (*start >= length) {
            *start = length - 1;
        }
        if (*stop < 0) {
            *stop += length;
            if (*stop < -1) *stop = -1;
        } else if (*stop >= length) {
            *stop = length - 1;
        }
        if (*stop >= *start) return 0;
        return (*start - *stop - step - 1) / (-step);
    }
}
