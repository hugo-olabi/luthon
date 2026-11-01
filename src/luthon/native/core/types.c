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

/* Attribute access */
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

    /* 2. Method table lookup on type */
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

    /* 3. Module dictionary / method lookup */
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

    return NULL;
}

EXPORT int PyObject_SetAttrString(PyObject *o, const char *attr_name, PyObject *v) {
    if (!o || !attr_name) return -1;

    PyTypeObject *tp = o->ob_type;
    if (!tp) tp = &Base_Type;

    if (tp->tp_setattro) {
        PyObject *name_obj = PyUnicode_FromString(attr_name);
        int res = tp->tp_setattro(o, name_obj, v);
        Py_DecRef(name_obj);
        return res;
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
