/*
 * Luthon C-API Proxy: Type System & Slot Dispatch (core/types.c)
 */

#include "luthon_capi.h"

/* Standard Type Objects */
EXPORT PyTypeObject Base_Type    = { .ob_refcnt = 1, .ob_type = NULL, .tp_name = "object", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyType_Type  = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "type", .tp_basicsize = sizeof(PyTypeObject) };
EXPORT PyTypeObject PyLong_Type  = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "int", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyFloat_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "float", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyUnicode_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "str", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyBytes_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "bytes", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyTuple_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "tuple", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyList_Type  = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "list", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyDict_Type  = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "dict", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyBool_Type  = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "bool", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PySlice_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "slice", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyStream_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "BytesIO", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyBaseObject_Type = { .ob_refcnt = 1, .ob_type = NULL, .tp_name = "object", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyComplex_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "complex", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyCFunction_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "builtin_function_or_method", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyDictProxy_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "mappingproxy", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyGetSetDescr_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "getset_descriptor", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyMemberDescr_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "member_descriptor", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyMethodDescr_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "method_descriptor", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyMemoryView_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "memoryview", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PySet_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "set", .tp_basicsize = sizeof(PyObject) };
EXPORT PyTypeObject PyFrozenSet_Type = { .ob_refcnt = 1, .ob_type = &Base_Type, .tp_name = "frozenset", .tp_basicsize = sizeof(PyObject) };

/* PyType_Ready: initializes type slots and inherits missing slots from tp_base */
EXPORT int PyType_Ready(PyTypeObject *type) {
    if (!type) return -1;

    if (!type->ob_type) {
        type->ob_type = &PyType_Type;
    }
    if (!type->tp_base) {
        type->tp_base = &Base_Type;
    }

    PyTypeObject *base = type->tp_base;

    /* Inherit slot suites if not explicitly populated */
    if (!type->tp_as_number && base->tp_as_number) {
        type->tp_as_number = base->tp_as_number;
    }
    if (!type->tp_as_sequence && base->tp_as_sequence) {
        type->tp_as_sequence = base->tp_as_sequence;
    }
    if (!type->tp_as_mapping && base->tp_as_mapping) {
        type->tp_as_mapping = base->tp_as_mapping;
    }

    /* Inherit call and attribute slots */
    if (!type->tp_call && base->tp_call) {
        type->tp_call = base->tp_call;
    }
    if (!type->tp_getattro && base->tp_getattro) {
        type->tp_getattro = base->tp_getattro;
    }
    if (!type->tp_setattro && base->tp_setattro) {
        type->tp_setattro = base->tp_setattro;
    }
    if (!type->tp_richcompare && base->tp_richcompare) {
        type->tp_richcompare = base->tp_richcompare;
    }
    if (!type->tp_iter && base->tp_iter) {
        type->tp_iter = base->tp_iter;
    }
    if (!type->tp_iternext && base->tp_iternext) {
        type->tp_iternext = base->tp_iternext;
    }
    if (!type->tp_as_async && base->tp_as_async) {
        type->tp_as_async = base->tp_as_async;
    }
    if (!type->tp_finalize && base->tp_finalize) {
        type->tp_finalize = base->tp_finalize;
    }
    if (!type->tp_dict) {
        type->tp_dict = PyDict_New();
    }

    return 0;
}

/* Dynamic Heap Types & Type Spec Protocol (PEP 384 / Phase 40) */
EXPORT PyObject* PyType_FromSpecWithBases(PyType_Spec *spec, PyObject *bases) {
    if (!spec) {
        return PyErr_Format(PyExc_ValueError, "PyType_FromSpecWithBases received NULL spec");
    }

    PyHeapTypeObject *ht = (PyHeapTypeObject *)calloc(1, sizeof(PyHeapTypeObject));
    if (!ht) {
        return PyErr_NoMemory();
    }

    PyTypeObject *type = &ht->ht_type;
    type->ob_refcnt = 1;
    type->ob_type = &PyType_Type;
    type->tp_name = spec->name ? spec->name : "AnonymousHeapType";
    type->tp_basicsize = spec->basicsize > 0 ? (Py_ssize_t)spec->basicsize : (Py_ssize_t)sizeof(PyObject);
    type->tp_itemsize = spec->itemsize;
    type->tp_flags = spec->flags | Py_TPFLAGS_HEAPTYPE;

    /* Link embedded method suites directly into the heap type */
    type->tp_as_async = &ht->as_async;
    type->tp_as_number = &ht->as_number;
    type->tp_as_mapping = &ht->as_mapping;
    type->tp_as_sequence = &ht->as_sequence;
    type->tp_as_buffer = (void *)&ht->as_buffer;

    /* Base inheritance resolution */
    if (bases) {
        if (bases->tag == PY_TAG_TUPLE && bases->as.seq_val.size > 0) {
            type->tp_base = (PyTypeObject *)bases->as.seq_val.items[0];
        } else if (bases->ob_type == &PyType_Type || (bases->ob_type && (bases->ob_type->tp_flags & Py_TPFLAGS_HEAPTYPE))) {
            type->tp_base = (PyTypeObject *)bases;
        }
    }
    if (!type->tp_base) {
        type->tp_base = &Base_Type;
    }

    /* Iterate through slots */
    if (spec->slots) {
        for (PyType_Slot *slot = spec->slots; slot->slot != 0; slot++) {
            void *p = slot->pfunc;
            switch (slot->slot) {
                case Py_tp_alloc: type->tp_alloc = p; break;
                case Py_tp_base: type->tp_base = (PyTypeObject *)p; break;
                case Py_tp_call: type->tp_call = (PyObject *(*)(PyObject *, PyObject *, PyObject *))p; break;
                case Py_tp_clear: type->tp_clear = p; break;
                case Py_tp_dealloc: type->tp_dealloc = (void (*)(PyObject *))p; break;
                case Py_tp_descr_get: type->tp_descr_get = p; break;
                case Py_tp_descr_set: type->tp_descr_set = p; break;
                case Py_tp_doc: type->tp_doc = (const char *)p; break;
                case Py_tp_getattr: type->tp_getattr = p; break;
                case Py_tp_getattro: type->tp_getattro = (PyObject *(*)(PyObject *, PyObject *))p; break;
                case Py_tp_hash: type->tp_hash = p; break;
                case Py_tp_init: type->tp_init = (int (*)(PyObject *, PyObject *, PyObject *))p; break;
                case Py_tp_iter: type->tp_iter = (PyObject *(*)(PyObject *))p; break;
                case Py_tp_iternext: type->tp_iternext = (PyObject *(*)(PyObject *))p; break;
                case Py_tp_methods: type->tp_methods = (PyMethodDef *)p; break;
                case Py_tp_new: type->tp_new = (PyObject *(*)(struct _typeobject *, PyObject *, PyObject *))p; break;
                case Py_tp_repr: type->tp_repr = p; break;
                case Py_tp_richcompare: type->tp_richcompare = (PyObject *(*)(PyObject *, PyObject *, int))p; break;
                case Py_tp_setattr: type->tp_setattr = p; break;
                case Py_tp_setattro: type->tp_setattro = (int (*)(PyObject *, PyObject *, PyObject *))p; break;
                case Py_tp_str: type->tp_str = p; break;
                case Py_tp_traverse: type->tp_traverse = p; break;
                case Py_tp_members: type->tp_members = p; break;
                case Py_tp_getset: type->tp_getset = p; break;
                case Py_tp_free: type->tp_free = p; break;
                case Py_tp_finalize: type->tp_finalize = (void (*)(PyObject *))p; break;

                /* Number slots */
                case Py_nb_add: ht->as_number.nb_add = p; break;
                case Py_nb_subtract: ht->as_number.nb_subtract = p; break;
                case Py_nb_multiply: ht->as_number.nb_multiply = p; break;
                case Py_nb_remainder: ht->as_number.nb_remainder = p; break;
                case Py_nb_divmod: ht->as_number.nb_divmod = p; break;
                case Py_nb_power: ht->as_number.nb_power = p; break;
                case Py_nb_negative: ht->as_number.nb_negative = p; break;
                case Py_nb_positive: ht->as_number.nb_positive = p; break;
                case Py_nb_absolute: ht->as_number.nb_absolute = p; break;
                case Py_nb_bool: ht->as_number.nb_bool = (int (*)(PyObject *))p; break;
                case Py_nb_invert: ht->as_number.nb_invert = p; break;
                case Py_nb_lshift: ht->as_number.nb_lshift = p; break;
                case Py_nb_rshift: ht->as_number.nb_rshift = p; break;
                case Py_nb_and: ht->as_number.nb_and = p; break;
                case Py_nb_xor: ht->as_number.nb_xor = p; break;
                case Py_nb_or: ht->as_number.nb_or = p; break;
                case Py_nb_int: ht->as_number.nb_int = p; break;
                case Py_nb_float: ht->as_number.nb_float = p; break;
                case Py_nb_inplace_add: ht->as_number.nb_inplace_add = p; break;
                case Py_nb_inplace_subtract: ht->as_number.nb_inplace_subtract = p; break;
                case Py_nb_inplace_multiply: ht->as_number.nb_inplace_multiply = p; break;
                case Py_nb_inplace_power: ht->as_number.nb_inplace_power = p; break;
                case Py_nb_true_divide: ht->as_number.nb_true_divide = p; break;
                case Py_nb_floor_divide: ht->as_number.nb_floor_divide = p; break;
                case Py_nb_matrix_multiply: ht->as_number.nb_matrix_multiply = p; break;
                case Py_nb_inplace_matrix_multiply: ht->as_number.nb_inplace_matrix_multiply = p; break;

                /* Sequence slots */
                case Py_sq_length: ht->as_sequence.sq_length = (Py_ssize_t (*)(PyObject *))p; break;
                case Py_sq_concat: ht->as_sequence.sq_concat = p; break;
                case Py_sq_repeat: ht->as_sequence.sq_repeat = (PyObject *(*)(PyObject *, Py_ssize_t))p; break;
                case Py_sq_item: ht->as_sequence.sq_item = (PyObject *(*)(PyObject *, Py_ssize_t))p; break;
                case Py_sq_ass_item: ht->as_sequence.sq_ass_item = (int (*)(PyObject *, Py_ssize_t, PyObject *))p; break;
                case Py_sq_contains: ht->as_sequence.sq_contains = (int (*)(PyObject *, PyObject *))p; break;

                /* Mapping slots */
                case Py_mp_length: ht->as_mapping.mp_length = (Py_ssize_t (*)(PyObject *))p; break;
                case Py_mp_subscript: ht->as_mapping.mp_subscript = (PyObject *(*)(PyObject *, PyObject *))p; break;
                case Py_mp_ass_subscript: ht->as_mapping.mp_ass_subscript = (int (*)(PyObject *, PyObject *, PyObject *))p; break;

                /* Buffer slots */
                case Py_bf_getbuffer: ht->as_buffer.bf_getbuffer = (getbufferproc)p; break;
                case Py_bf_releasebuffer: ht->as_buffer.bf_releasebuffer = (releasebufferproc)p; break;

                /* Async slots */
                case Py_am_await: ht->as_async.am_await = p; break;
                case Py_am_aiter: ht->as_async.am_aiter = p; break;
                case Py_am_anext: ht->as_async.am_anext = p; break;

                default: break;
            }
        }
    }

    PyType_Ready(type);

    /* Populate tp_dict with methods, members, getsets */
    if (type->tp_dict) {
        if (type->tp_doc) {
            PyDict_SetItemString(type->tp_dict, "__doc__", PyUnicode_FromString(type->tp_doc));
        }
        if (type->tp_name) {
            PyDict_SetItemString(type->tp_dict, "__name__", PyUnicode_FromString(type->tp_name));
        }
    }

    return (PyObject *)type;
}

EXPORT PyObject* PyType_FromSpec(PyType_Spec *spec) {
    return PyType_FromSpecWithBases(spec, NULL);
}

/* Attribute access with full Descriptor / Property / Member dispatch (Phase 32) */
EXPORT PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name) {
    if (!o || !attr_name) return NULL;

    /* 0. If target is a Type Object itself, resolve class attributes */
    if (o->ob_type == &PyType_Type) {
        PyTypeObject *as_type = (PyTypeObject *)o;
        if (strcmp(attr_name, "__name__") == 0) return PyUnicode_FromString(as_type->tp_name ? as_type->tp_name : "");
        if (strcmp(attr_name, "__doc__") == 0) return PyUnicode_FromString(as_type->tp_doc ? as_type->tp_doc : "");
        if (as_type->tp_dict) {
            PyObject *v = PyDict_GetItemString(as_type->tp_dict, attr_name);
            if (v) { Py_IncRef(v); return v; }
        }
        if (as_type->tp_methods) {
            for (PyMethodDef *m = as_type->tp_methods; m->ml_name != NULL; m++) {
                if (strcmp(m->ml_name, attr_name) == 0) {
                    PyObject *fn = alloc_pyobject(PY_TAG_OPAQUE, &Base_Type);
                    if (fn) fn->as.buf_val.ptr = m->ml_meth;
                    return fn;
                }
            }
        }
    }

    PyTypeObject *tp = o->ob_type;
    if (!tp) tp = &Base_Type;

    /* 1. Custom tp_getattro handler */
    if (tp->tp_getattro) {
        PyObject *name_obj = PyUnicode_FromString(attr_name);
        PyObject *res = tp->tp_getattro(o, name_obj);
        Py_DecRef(name_obj);
        return res;
    }

    /* 2. Custom Descriptor check in tp_dict */
    if (tp->tp_dict && tp->tp_dict->ob_type && tp->tp_dict->ob_type->tp_as_mapping) {
        PyObject *descr = PyDict_GetItemString(tp->tp_dict, attr_name);
        if (descr && descr->ob_type && descr->ob_type->tp_descr_get) {
            descrgetfunc dget = (descrgetfunc)descr->ob_type->tp_descr_get;
            return dget(descr, o, (PyObject *)tp);
        }
    }

    /* 3. PyGetSetDef table lookup (@property and C-extension getters) */
    if (tp->tp_getset) {
        for (PyGetSetDef *g = (PyGetSetDef *)tp->tp_getset; g->name != NULL; g++) {
            if (strcmp(g->name, attr_name) == 0) {
                if (g->get) {
                    return g->get(o, g->closure);
                } else {
                    return PyErr_Format(PyExc_AttributeError, "Attribute '%s' is not readable", attr_name);
                }
            }
        }
    }

    /* 4. PyMemberDef struct offset lookup */
    if (tp->tp_members) {
        char *base_addr = (char *)o;
        for (PyMemberDef *m = (PyMemberDef *)tp->tp_members; m->name != NULL; m++) {
            if (strcmp(m->name, attr_name) == 0) {
                void *addr = base_addr + m->offset;
                switch (m->type) {
                    case T_SHORT: return PyLong_FromLong(*(short *)addr);
                    case T_INT: return PyLong_FromLong(*(int *)addr);
                    case T_LONG: return PyLong_FromLong(*(long *)addr);
                    case T_LONGLONG: return PyLong_FromLongLong(*(long long *)addr);
                    case T_PYSSIZET: return PyLong_FromLongLong((long long)*(Py_ssize_t *)addr);
                    case T_FLOAT: return PyFloat_FromDouble((double)*(float *)addr);
                    case T_DOUBLE: return PyFloat_FromDouble(*(double *)addr);
                    case T_STRING: {
                        char *str = *(char **)addr;
                        if (str) return PyUnicode_FromString(str);
                        Py_IncRef(Py_None);
                        return Py_None;
                    }
                    case T_STRING_INPLACE: return PyUnicode_FromString((char *)addr);
                    case T_BOOL: return PyBool_FromLong(*(char *)addr != 0);
                    case T_OBJECT: {
                        PyObject *obj = *(PyObject **)addr;
                        if (!obj) obj = Py_None;
                        Py_IncRef(obj);
                        return obj;
                    }
                    default: break;
                }
            }
        }
    }

    /* 5. Method table lookup on type */
    if (tp->tp_methods) {
        for (PyMethodDef *m = tp->tp_methods; m->ml_name != NULL; m++) {
            if (strcmp(m->ml_name, attr_name) == 0) {
                /* Wrap method definition */
                PyObject *fn = alloc_pyobject(PY_TAG_OPAQUE, &Base_Type);
                if (fn) fn->as.buf_val.ptr = m->ml_meth;
                return fn;
            }
        }
    }

    /* 6. Module dictionary / method lookup */
    if (o->tag == PY_TAG_MODULE) {
        PyObject *dict = PyModule_GetDict(o);
        if (dict) {
            PyObject *val = PyDict_GetItemString(dict, attr_name);
            if (val) {
                Py_IncRef(val);
                return val;
            }
        }
        PyModuleDef *def = (PyModuleDef *)o->as.mod_val.module_def;
        if (def && def->m_methods) {
            for (PyMethodDef *m = def->m_methods; m->ml_name != NULL; m++) {
                if (strcmp(m->ml_name, attr_name) == 0) {
                    PyObject *fn = alloc_pyobject(PY_TAG_OPAQUE, &Base_Type);
                    if (fn) fn->as.buf_val.ptr = m->ml_meth;
                    return fn;
                }
            }
        }
    }

    /* 7. tp_base recursion */
    if (tp->tp_base) {
        PyTypeObject orig_type = *o->ob_type;
        o->ob_type = tp->tp_base;
        PyObject *res = PyObject_GetAttrString(o, attr_name);
        *o->ob_type = orig_type;
        if (res) return res;
    }

    /* 8. Legacy tp_getattr */
    if (tp->tp_getattr) {
        typedef PyObject *(*getattrfunc)(PyObject *, const char *);
        getattrfunc gfn = (getattrfunc)tp->tp_getattr;
        return gfn(o, attr_name);
    }

    return NULL;
}

EXPORT int PyObject_SetAttrString(PyObject *o, const char *attr_name, PyObject *v) {
    if (!o || !attr_name) return -1;

    PyTypeObject *tp = o->ob_type;
    if (!tp) tp = &Base_Type;

    /* 1. Custom tp_setattro handler */
    if (tp->tp_setattro) {
        PyObject *name_obj = PyUnicode_FromString(attr_name);
        int res = tp->tp_setattro(o, name_obj, v);
        Py_DecRef(name_obj);
        return res;
    }

    /* 2. Custom Descriptor check in tp_dict */
    if (tp->tp_dict && tp->tp_dict->ob_type && tp->tp_dict->ob_type->tp_as_mapping) {
        PyObject *descr = PyDict_GetItemString(tp->tp_dict, attr_name);
        if (descr && descr->ob_type && descr->ob_type->tp_descr_set) {
            descrsetfunc dset = (descrsetfunc)descr->ob_type->tp_descr_set;
            return dset(descr, o, v);
        }
    }

    /* 3. PyGetSetDef table lookup (@property and C-extension setters) */
    if (tp->tp_getset) {
        for (PyGetSetDef *g = (PyGetSetDef *)tp->tp_getset; g->name != NULL; g++) {
            if (strcmp(g->name, attr_name) == 0) {
                if (g->set) {
                    return g->set(o, v, g->closure);
                } else {
                    PyErr_SetString(PyExc_AttributeError, "attribute is read-only");
                    return -1;
                }
            }
        }
    }

    /* 4. PyMemberDef struct offset lookup */
    if (tp->tp_members) {
        char *base_addr = (char *)o;
        for (PyMemberDef *m = (PyMemberDef *)tp->tp_members; m->name != NULL; m++) {
            if (strcmp(m->name, attr_name) == 0) {
                if (m->flags & READONLY) {
                    PyErr_SetString(PyExc_AttributeError, "attribute is read-only");
                    return -1;
                }
                void *addr = base_addr + m->offset;
                switch (m->type) {
                    case T_SHORT: *(short *)addr = (short)PyLong_AsLongLong(v); return 0;
                    case T_INT: *(int *)addr = (int)PyLong_AsLongLong(v); return 0;
                    case T_LONG: *(long *)addr = (long)PyLong_AsLongLong(v); return 0;
                    case T_LONGLONG: *(long long *)addr = PyLong_AsLongLong(v); return 0;
                    case T_PYSSIZET: *(Py_ssize_t *)addr = (Py_ssize_t)PyLong_AsLongLong(v); return 0;
                    case T_FLOAT: *(float *)addr = (float)PyFloat_AsDouble(v); return 0;
                    case T_DOUBLE: *(double *)addr = PyFloat_AsDouble(v); return 0;
                    case T_BOOL: *(char *)addr = PyObject_IsTrue(v) ? 1 : 0; return 0;
                    case T_OBJECT: {
                        PyObject *old = *(PyObject **)addr;
                        Py_IncRef(v);
                        *(PyObject **)addr = v;
                        if (old) Py_DecRef(old);
                        return 0;
                    }
                    default: break;
                }
            }
        }
    }

    /* 5. Legacy tp_setattr */
    if (tp->tp_setattr) {
        typedef int (*setattrfunc)(PyObject *, const char *, PyObject *);
        setattrfunc sfn = (setattrfunc)tp->tp_setattr;
        return sfn(o, attr_name, v);
    }

    return -1;
}

EXPORT int PyObject_HasAttrString(PyObject *o, const char *attr_name) {
    PyObject *res = PyObject_GetAttrString(o, attr_name);
    if (res) {
        Py_DecRef(res);
        return 1;
    }
    return 0;
}

/* Call invocations */
EXPORT PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs) {
    if (!callable) return NULL;

    PyTypeObject *tp = callable->ob_type;

    /* If callable is a Type object: instantiate via tp_new + tp_init */
    if (callable->ob_type == &PyType_Type || (tp && (tp->tp_flags & Py_TPFLAGS_HEAPTYPE))) {
        PyTypeObject *target_type = (PyTypeObject *)callable;
        PyObject *instance = NULL;
        if (target_type->tp_new) {
            instance = target_type->tp_new(target_type, args, kwargs);
        } else {
            instance = _PyObject_New(target_type);
        }
        if (instance && target_type->tp_init) {
            target_type->tp_init(instance, args, kwargs);
        }
        return instance;
    }

    if (tp && tp->tp_call) {
        return tp->tp_call(callable, args, kwargs);
    }

    /* Opaque method pointer callback */
    if (callable->tag == PY_TAG_OPAQUE && callable->as.buf_val.ptr) {
        typedef PyObject *(*py_c_func)(PyObject *, PyObject *);
        py_c_func fn = (py_c_func)callable->as.buf_val.ptr;
        return fn(NULL, args);
    }

    return NULL;
}

EXPORT PyObject* PyObject_CallObject(PyObject *callable, PyObject *args) {
    return PyObject_Call(callable, args, NULL);
}

/* Method Constructors & Type Flags */
EXPORT PyObject* PyMethod_New(PyObject *func, PyObject *self) {
    (void)self;
    Py_IncRef(func);
    return func;
}

EXPORT unsigned long PyType_GetFlags(PyTypeObject *type) {
    return type ? type->tp_flags : 0;
}

EXPORT void PyType_Modified(PyTypeObject *type) {
    (void)type;
}

EXPORT PyObject* PyType_GenericNew(PyTypeObject *type, PyObject *args, PyObject *kwds) {
    (void)args; (void)kwds;
    return _PyObject_New(type);
}

EXPORT PyObject* Py_GenericAlias(PyObject *origin, PyObject *args) {
    (void)args;
    Py_IncRef(origin);
    return origin;
}

/* ContextVar Protocol */
EXPORT PyObject* PyContextVar_New(const char *name, PyObject *default_value) {
    PyObject *cv = alloc_pyobject(PY_TAG_OPAQUE, &Base_Type);
    if (cv) cv->as.buf_val.ptr = default_value;
    (void)name;
    return cv;
}

EXPORT int PyContextVar_Get(PyObject *var, PyObject *default_value, PyObject **value) {
    if (!value) return -1;
    if (var && var->as.buf_val.ptr) {
        *value = (PyObject *)var->as.buf_val.ptr;
        Py_IncRef(*value);
    } else if (default_value) {
        *value = default_value;
        Py_IncRef(*value);
    } else {
        *value = NULL;
    }
    return 0;
}

EXPORT PyObject* PyContextVar_Set(PyObject *var, PyObject *value) {
    if (var) {
        PyObject *old = (PyObject *)var->as.buf_val.ptr;
        var->as.buf_val.ptr = value;
        return old ? old : Py_None;
    }
    return Py_None;
}

/* Threading & Mutex Protocol */
EXPORT void* PyThreadState_Get(void) {
    return (void *)0x1000;
}

EXPORT void* PyInterpreterState_Main(void) {
    return (void *)0x2000;
}

EXPORT int PyGILState_Ensure(void) {
    return 1;
}

EXPORT void PyGILState_Release(int state) {
    (void)state;
}

EXPORT void PyMutex_Lock(uint8_t *m) { (void)m; }
EXPORT void PyMutex_Unlock(uint8_t *m) { (void)m; }

EXPORT int Py_EnterRecursiveCall(const char *where) { (void)where; return 0; }
EXPORT void Py_LeaveRecursiveCall(void) {}

EXPORT int PyTraceMalloc_Track(unsigned int domain, uintptr_t ptr, size_t size) {
    (void)domain; (void)ptr; (void)size;
    return 0;
}

EXPORT int PyTraceMalloc_Untrack(unsigned int domain, uintptr_t ptr) {
    (void)domain; (void)ptr;
    return 0;
}
