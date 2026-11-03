/*
 * Luthon C-API Proxy: Type System & Slot Dispatch (core/types.c)
 */

#include "luthon_capi.h"

/* Standard Type Objects */
EXPORT PyTypeObject Base_Type    = { 1, NULL, "object", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyType_Type  = { 1, &Base_Type, "type", sizeof(PyTypeObject), 0, NULL };
EXPORT PyTypeObject PyLong_Type  = { 1, &Base_Type, "int", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyFloat_Type = { 1, &Base_Type, "float", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyUnicode_Type = { 1, &Base_Type, "str", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyBytes_Type = { 1, &Base_Type, "bytes", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyTuple_Type = { 1, &Base_Type, "tuple", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyList_Type  = { 1, &Base_Type, "list", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyDict_Type  = { 1, &Base_Type, "dict", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyBool_Type  = { 1, &Base_Type, "bool", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PySlice_Type = { 1, &Base_Type, "slice", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyStream_Type = { 1, &Base_Type, "BytesIO", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyBaseObject_Type = { 1, NULL, "object", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyComplex_Type = { 1, &Base_Type, "complex", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyCFunction_Type = { 1, &Base_Type, "builtin_function_or_method", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyDictProxy_Type = { 1, &Base_Type, "mappingproxy", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyGetSetDescr_Type = { 1, &Base_Type, "getset_descriptor", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyMemberDescr_Type = { 1, &Base_Type, "member_descriptor", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyMethodDescr_Type = { 1, &Base_Type, "method_descriptor", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyMemoryView_Type = { 1, &Base_Type, "memoryview", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PySet_Type = { 1, &Base_Type, "set", sizeof(PyObject), 0, NULL };
EXPORT PyTypeObject PyFrozenSet_Type = { 1, &Base_Type, "frozenset", sizeof(PyObject), 0, NULL };

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

    return 0;
}

/* Attribute access with full Descriptor / Property / Member dispatch (Phase 32) */
EXPORT PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name) {
    if (!o || !attr_name) return NULL;

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
    if (o->tag == PY_TAG_MODULE && o->as.module_def) {
        PyModuleDef *def = (PyModuleDef *)o->as.module_def;
        if (def->m_methods) {
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
