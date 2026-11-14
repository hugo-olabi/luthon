/*
 * Luthon C-API Proxy: Mapping, Subscript & Multi-Dimensional Slicing (protocols/mapping.c)
 */

#include "luthon_capi.h"

/* Dict Implementation (dynamic key-value array) */
typedef struct {
    char *key;
    PyObject *val;
} PyDictItem;

typedef struct {
    PyDictItem *items;
    Py_ssize_t size;
    Py_ssize_t capacity;
} PyDictStorage;

EXPORT PyObject* PyDict_New(void) {
    PyObject *o = alloc_pyobject(PY_TAG_DICT, &PyDict_Type);
    if (!o) return NULL;
    PyDictStorage *st = (PyDictStorage *)calloc(1, sizeof(PyDictStorage));
    if (!st) {
        free(o);
        return PyErr_NoMemory();
    }
    st->capacity = 8;
    st->items = (PyDictItem *)calloc(st->capacity, sizeof(PyDictItem));
    o->as.buf_val.ptr = st;
    return o;
}

EXPORT int PyDict_SetItemString(PyObject *dp, const char *key, PyObject *item) {
    if (!dp || dp->tag != PY_TAG_DICT || !key) return -1;
    PyDictStorage *st = (PyDictStorage *)dp->as.buf_val.ptr;
    if (!st) return -1;

    for (Py_ssize_t i = 0; i < st->size; i++) {
        if (st->items[i].key && strcmp(st->items[i].key, key) == 0) {
            Py_DecRef(st->items[i].val);
            st->items[i].val = item;
            if (item) Py_IncRef(item);
            return 0;
        }
    }

    if (st->size >= st->capacity) {
        Py_ssize_t new_cap = st->capacity * 2;
        if (new_cap < 8) new_cap = 8;
        PyDictItem *new_items = (PyDictItem *)realloc(st->items, sizeof(PyDictItem) * new_cap);
        if (!new_items) return -1;
        st->items = new_items;
        st->capacity = new_cap;
    }

    st->items[st->size].key = strdup(key);
    st->items[st->size].val = item;
    if (item) Py_IncRef(item);
    st->size++;
    return 0;
}

EXPORT PyObject* PyDict_GetItemString(PyObject *dp, const char *key) {
    if (!dp || dp->tag != PY_TAG_DICT || !key) return NULL;
    PyDictStorage *st = (PyDictStorage *)dp->as.buf_val.ptr;
    if (!st) return NULL;

    for (Py_ssize_t i = 0; i < st->size; i++) {
        if (st->items[i].key && strcmp(st->items[i].key, key) == 0) {
            return st->items[i].val; /* Borrowed reference */
        }
    }
    return NULL;
}

EXPORT Py_ssize_t PyDict_Size(PyObject *dp) {
    if (!dp || dp->tag != PY_TAG_DICT) return 0;
    PyDictStorage *st = (PyDictStorage *)dp->as.buf_val.ptr;
    return st ? st->size : 0;
}

EXPORT int PyDict_GetItemRef(PyObject *p, PyObject *key, PyObject **result) {
    if (!p || !result) return -1;
    *result = NULL;
    if (!key) return 0;
    const char *kstr = (key->tag == PY_TAG_STR) ? PyUnicode_AsUTF8(key) : NULL;
    if (!kstr) return 0;
    PyObject *val = PyDict_GetItemString(p, kstr);
    if (val) {
        Py_IncRef(val);
        *result = val;
        return 1;
    }
    return 0;
}

EXPORT int PyDict_SetItem(PyObject *dp, PyObject *key, PyObject *item) {
    if (!dp || !key) return -1;
    const char *kstr = (key->tag == PY_TAG_STR) ? PyUnicode_AsUTF8(key) : NULL;
    if (!kstr) return -1;
    return PyDict_SetItemString(dp, kstr, item);
}

EXPORT PyObject* PyDict_GetItem(PyObject *dp, PyObject *key) {
    if (!dp || !key) return NULL;
    const char *kstr = (key->tag == PY_TAG_STR) ? PyUnicode_AsUTF8(key) : NULL;
    if (!kstr) return NULL;
    return PyDict_GetItemString(dp, kstr);
}

EXPORT int PyDict_Contains(PyObject *dp, PyObject *key) {
    return PyDict_GetItem(dp, key) != NULL;
}

EXPORT int PyDict_DelItem(PyObject *dp, PyObject *key) {
    if (!dp || dp->tag != PY_TAG_DICT || !key) return -1;
    const char *kstr = (key->tag == PY_TAG_STR) ? PyUnicode_AsUTF8(key) : NULL;
    if (!kstr) return -1;
    PyDictStorage *st = (PyDictStorage *)dp->as.buf_val.ptr;
    if (!st) return -1;

    for (Py_ssize_t i = 0; i < st->size; i++) {
        if (st->items[i].key && strcmp(st->items[i].key, kstr) == 0) {
            free(st->items[i].key);
            Py_DecRef(st->items[i].val);
            st->items[i] = st->items[st->size - 1];
            st->size--;
            return 0;
        }
    }
    PyErr_SetString(PyExc_KeyError, kstr);
    return -1;
}

EXPORT int PyMapping_SetItemString(PyObject *o, const char *key, PyObject *v) {
    if (!o || !key) return -1;
    if (o->tag == PY_TAG_DICT) {
        return PyDict_SetItemString(o, key, v);
    }
    PyObject *k = PyUnicode_FromString(key);
    int res = PyObject_SetItem(o, k, v);
    Py_DecRef(k);
    return res;
}

EXPORT PyObject* PyMapping_GetItemString(PyObject *o, const char *key) {
    if (!o || !key) return NULL;
    if (o->tag == PY_TAG_DICT) {
        return PyDict_GetItemString(o, key);
    }
    PyObject *k = PyUnicode_FromString(key);
    PyObject *res = PyObject_GetItem(o, k);
    Py_DecRef(k);
    return res;
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

    /* 1b. Dictionary string key lookup */
    if (o->tag == PY_TAG_DICT && key->tag == PY_TAG_STR) {
        PyObject *res = PyDict_GetItemString(o, PyUnicode_AsUTF8(key));
        if (res) Py_IncRef(res);
        return res;
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
    if (o->tag == PY_TAG_DICT && key->tag == PY_TAG_STR) {
        if (!v) return PyDict_DelItem(o, key);
        return PyDict_SetItemString(o, PyUnicode_AsUTF8(key), v);
    }
    if ((key->tag == PY_TAG_INT || key->tag == PY_TAG_BOOL) && (o->tag == PY_TAG_LIST)) {
        return PyList_SetItem(o, (Py_ssize_t)key->as.i_val, v);
    }
    if (tp && tp->tp_as_sequence && tp->tp_as_sequence->sq_ass_item && (key->tag == PY_TAG_INT || key->tag == PY_TAG_BOOL)) {
        return tp->tp_as_sequence->sq_ass_item(o, (Py_ssize_t)key->as.i_val, v);
    }
    return -1;
}

EXPORT int PyObject_DelItem(PyObject *o, PyObject *key) {
    return PyObject_SetItem(o, key, NULL);
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

/* Stage 4: Expanded Dict & Mapping Operations */
EXPORT PyObject* PyDictProxy_New(PyObject *mapping) {
    PyObject *proxy = alloc_pyobject(PY_TAG_OPAQUE, &PyDictProxy_Type);
    if (proxy) proxy->as.buf_val.ptr = mapping;
    return proxy;
}

EXPORT PyObject* PyDict_GetItemWithError(PyObject *p, PyObject *key) {
    return PyDict_GetItem(p, key);
}

EXPORT int PyDict_GetItemStringRef(PyObject *p, const char *key, PyObject **result) {
    if (!result) return -1;
    *result = NULL;
    if (!p || !key) return 0;
    PyObject *val = PyDict_GetItemString(p, key);
    if (val) {
        Py_IncRef(val);
        *result = val;
        return 1;
    }
    return 0;
}

EXPORT int PyDict_SetDefaultRef(PyObject *d, PyObject *key, PyObject *default_value, PyObject **result) {
    if (!d || !key) return -1;
    PyObject *existing = PyDict_GetItem(d, key);
    if (existing) {
        if (result) {
            *result = existing;
            Py_IncRef(existing);
        }
        return 0;
    }
    PyDict_SetItem(d, key, default_value);
    if (result) {
        *result = default_value;
        if (default_value) Py_IncRef(default_value);
    }
    return 0;
}

EXPORT int PyDict_DelItemString(PyObject *p, const char *key) {
    if (!p || !key) return -1;
    PyObject *k = PyUnicode_FromString(key);
    int res = PyDict_DelItem(p, k);
    Py_DecRef(k);
    return res;
}

EXPORT int PyDict_Next(PyObject *p, Py_ssize_t *ppos, PyObject **pkey, PyObject **pvalue) {
    if (!p || p->tag != PY_TAG_DICT || !ppos) return 0;
    PyDictStorage *st = (PyDictStorage *)p->as.buf_val.ptr;
    if (!st || *ppos >= st->size) return 0;
    if (pkey) *pkey = PyUnicode_FromString(st->items[*ppos].key);
    if (pvalue) *pvalue = st->items[*ppos].val;
    (*ppos)++;
    return 1;
}

EXPORT int PyDict_Merge(PyObject *a, PyObject *b, int _override) {
    if (!a || a->tag != PY_TAG_DICT || !b || b->tag != PY_TAG_DICT) return -1;
    PyDictStorage *st_b = (PyDictStorage *)b->as.buf_val.ptr;
    if (!st_b) return 0;
    for (Py_ssize_t i = 0; i < st_b->size; i++) {
        if (_override || !PyDict_GetItemString(a, st_b->items[i].key)) {
            PyDict_SetItemString(a, st_b->items[i].key, st_b->items[i].val);
        }
    }
    return 0;
}

EXPORT PyObject* PyDict_Copy(PyObject *d) {
    if (!d || d->tag != PY_TAG_DICT) return PyDict_New();
    PyObject *copy = PyDict_New();
    PyDict_Merge(copy, d, 1);
    return copy;
}

EXPORT int PyDict_ContainsString(PyObject *p, const char *key) {
    if (!p || !key) return 0;
    return PyDict_GetItemString(p, key) != NULL;
}

EXPORT PyObject* PyDict_Values(PyObject *mp) {
    if (!mp || mp->tag != PY_TAG_DICT) return PyList_New(0);
    PyDictStorage *st = (PyDictStorage *)mp->as.buf_val.ptr;
    if (!st) return PyList_New(0);
    PyObject *lst = PyList_New(st->size);
    for (Py_ssize_t i = 0; i < st->size; i++) {
        Py_IncRef(st->items[i].val);
        PyList_SetItem(lst, i, st->items[i].val);
    }
    return lst;
}
