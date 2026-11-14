/*
 * Luthon C-API Proxy: Module Loader & Reflection Dispatch (modules/loader.c)
 */

#include "luthon_capi.h"

static void _get_module_def_fields(void *raw_def, const char **p_name, const char **p_doc, PyMethodDef **p_methods) {
    *p_name = NULL;
    *p_doc = NULL;
    *p_methods = NULL;
    if (!raw_def) return;

    /* Detect legacy PyModuleDef layout vs standard CPython PyModuleDef */
    void *field_at_8 = *(void **)((char *)raw_def + 8);
    if (field_at_8 != NULL) {
        /* Legacy layout: m_name is at offset 8 */
        typedef struct {
            int m_base;
            int _pad;
            const char *m_name;
            const char *m_doc;
            Py_ssize_t m_size;
            PyMethodDef *m_methods;
        } _LegacyDef;
        _LegacyDef *leg = (_LegacyDef *)raw_def;
        *p_name = leg->m_name;
        *p_doc = leg->m_doc;
        *p_methods = leg->m_methods;
    } else {
        /* Standard CPython PyModuleDef: m_base.ob_type is NULL in PyModuleDef_HEAD_INIT */
        PyModuleDef *std = (PyModuleDef *)raw_def;
        *p_name = std->m_name;
        *p_doc = std->m_doc;
        *p_methods = std->m_methods;
    }
}

EXPORT PyObject* PyModule_Create2(PyModuleDef *def, int apiver) {
    (void)apiver;
    PyObject *mod = alloc_pyobject(PY_TAG_MODULE, NULL);
    if (!mod) return NULL;

    mod->as.mod_val.module_def = (void *)def;
    mod->as.mod_val.dict = PyDict_New();

    if (def) {
        const char *name = NULL;
        const char *doc = NULL;
        PyMethodDef *methods = NULL;
        _get_module_def_fields(def, &name, &doc, &methods);

        if (name) {
            PyDict_SetItemString(mod->as.mod_val.dict, "__name__", PyUnicode_FromString(name));
        }
        if (doc) {
            PyDict_SetItemString(mod->as.mod_val.dict, "__doc__", PyUnicode_FromString(doc));
        }
        if (methods) {
            for (PyMethodDef *m = methods; m->ml_name != NULL; m++) {
                PyObject *fn = alloc_pyobject(PY_TAG_OPAQUE, &Base_Type);
                if (fn) {
                    fn->as.buf_val.ptr = m->ml_meth;
                    PyDict_SetItemString(mod->as.mod_val.dict, m->ml_name, fn);
                    Py_DecRef(fn);
                }
            }
        }
    }

    return mod;
}

EXPORT int PyArg_ParseTuple(PyObject *args, const char *fmt, ...) {
    if (!args || args->tag != PY_TAG_TUPLE) return 0;
    va_list vl;
    va_start(vl, fmt);

    Py_ssize_t arg_idx = 0;
    Py_ssize_t total = args->as.seq_val.size;

    for (const char *p = fmt; *p; p++) {
        if (*p == '|') continue;
        if (*p == ':') break;

        if (arg_idx >= total) {
            va_end(vl);
            return 0;
        }
        PyObject *item = args->as.seq_val.items[arg_idx++];

        switch (*p) {
            case 'i': {
                int *out = va_arg(vl, int *);
                *out = (int)PyLong_AsLongLong(item);
                break;
            }
            case 'l': {
                long *out = va_arg(vl, long *);
                *out = (long)PyLong_AsLongLong(item);
                break;
            }
            case 'L': {
                long long *out = va_arg(vl, long long *);
                *out = PyLong_AsLongLong(item);
                break;
            }
            case 'd': {
                double *out = va_arg(vl, double *);
                *out = PyFloat_AsDouble(item);
                break;
            }
            case 'f': {
                float *out = va_arg(vl, float *);
                *out = (float)PyFloat_AsDouble(item);
                break;
            }
            case 's': {
                const char **out = va_arg(vl, const char **);
                *out = PyUnicode_AsUTF8(item);
                break;
            }
            case 'O': {
                PyObject **out = va_arg(vl, PyObject **);
                *out = item;
                break;
            }
            default:
                break;
        }
    }
    va_end(vl);
    return 1;
}

EXPORT int PyArg_ParseTupleAndKeywords(PyObject *args, PyObject *kwargs, const char *fmt, char **kwlist, ...) {
    (void)kwargs; (void)kwlist;
    /* Basic fallback to PyArg_ParseTuple */
    va_list vl;
    va_start(vl, kwlist);
    int res = PyArg_ParseTuple(args, fmt, vl);
    va_end(vl);
    return res;
}

/* Module Attribute and Constant Helpers */
EXPORT PyObject* PyModule_GetDict(PyObject *mod) {
    if (!mod) return NULL;
    if (mod->tag == PY_TAG_MODULE) {
        return mod->as.mod_val.dict;
    }
    return NULL;
}

EXPORT int PyModule_AddObjectRef(PyObject *mod, const char *name, PyObject *value) {
    if (!mod || !name || !value) return -1;
    PyObject *dict = PyModule_GetDict(mod);
    if (!dict) return -1;
    return PyDict_SetItemString(dict, name, value);
}

EXPORT int PyModule_AddObject(PyObject *mod, const char *name, PyObject *value) {
    int res = PyModule_AddObjectRef(mod, name, value);
    if (res == 0 && value) {
        Py_DecRef(value);
    }
    return res;
}

EXPORT int PyModule_AddIntConstant(PyObject *mod, const char *name, long value) {
    PyObject *val_obj = PyLong_FromLong(value);
    return PyModule_AddObject(mod, name, val_obj);
}

EXPORT int PyModule_AddStringConstant(PyObject *mod, const char *name, const char *value) {
    PyObject *val_obj = PyUnicode_FromString(value ? value : "");
    return PyModule_AddObject(mod, name, val_obj);
}

/* PEP 489 Multi-Phase Module Initialization (Phase 40) */
EXPORT PyObject* PyModule_FromDefAndSpec2(PyModuleDef *def, PyObject *spec, int module_api_version) {
    (void)module_api_version;
    if (!def) return NULL;

    typedef PyObject *(*mod_create_func)(PyObject *, PyModuleDef *);
    if (def->m_slots) {
        for (struct PyModuleDef_Slot *s = def->m_slots; s->slot != 0; s++) {
            if (s->slot == Py_mod_create && s->value) {
                mod_create_func cfn = (mod_create_func)s->value;
                return cfn(spec, def);
            }
        }
    }

    return PyModule_Create2(def, 3);
}

EXPORT PyObject* PyModule_FromDefAndSpec(PyModuleDef *def, PyObject *spec) {
    return PyModule_FromDefAndSpec2(def, spec, 3);
}

EXPORT int PyModule_ExecDef(PyObject *module, PyModuleDef *def) {
    if (!module || !def) return -1;
    if (def->m_slots) {
        typedef int (*mod_exec_func)(PyObject *);
        for (struct PyModuleDef_Slot *s = def->m_slots; s->slot != 0; s++) {
            if (s->slot == Py_mod_exec && s->value) {
                mod_exec_func efn = (mod_exec_func)s->value;
                int ret = efn(module);
                if (ret != 0) return ret;
            }
        }
    }
    return 0;
}

EXPORT PyObject* PyModuleDef_Init(PyModuleDef *def) {
    if (!def) return NULL;
    if (def->m_slots != NULL) {
        return (PyObject *)def;
    }
    return PyModule_Create2(def, 3);
}

EXPORT Py_ssize_t PyObject_Size(PyObject *o) {
    return PySequence_Size(o);
}

EXPORT PyObject* Py_BuildValue(const char *format, ...) {
    if (!format || !*format) return Py_None;

    va_list vl;
    va_start(vl, format);

    if (strcmp(format, "i") == 0) {
        int v = va_arg(vl, int);
        va_end(vl);
        return PyLong_FromLong((long)v);
    } else if (strcmp(format, "l") == 0 || strcmp(format, "L") == 0) {
        long long v = va_arg(vl, long long);
        va_end(vl);
        return PyLong_FromLongLong(v);
    } else if (strcmp(format, "d") == 0) {
        double v = va_arg(vl, double);
        va_end(vl);
        return PyFloat_FromDouble(v);
    } else if (strcmp(format, "s") == 0) {
        const char *s = va_arg(vl, const char *);
        va_end(vl);
        return s ? PyUnicode_FromString(s) : Py_None;
    } else if (strcmp(format, "O") == 0) {
        PyObject *o = va_arg(vl, PyObject *);
        va_end(vl);
        if (o) Py_IncRef(o);
        return o ? o : Py_None;
    } else if (strcmp(format, "(ii)") == 0) {
        int a = va_arg(vl, int);
        int b = va_arg(vl, int);
        va_end(vl);
        PyObject *t = PyTuple_New(2);
        if (t) {
            PyTuple_SetItem(t, 0, PyLong_FromLong(a));
            PyTuple_SetItem(t, 1, PyLong_FromLong(b));
        }
        return t;
    }

    va_end(vl);
    return Py_None;
}

EXPORT PyObject* PyObject_CallFunction(PyObject *callable, const char *format, ...) {
    if (!callable) return NULL;
    va_list vl;
    va_start(vl, format);
    /* For simple 0 or 1-arg calls */
    PyObject *args = PyTuple_New(0);
    PyObject *res = PyObject_Call(callable, args, NULL);
    Py_DecRef(args);
    va_end(vl);
    return res;
}

EXPORT PyObject* PyObject_CallMethod(PyObject *o, const char *name, const char *format, ...) {
    if (!o || !name) return NULL;
    PyObject *method = PyObject_GetAttrString(o, name);
    if (!method) return NULL;
    va_list vl;
    va_start(vl, format);
    PyObject *args = PyTuple_New(0);
    PyObject *res = PyObject_Call(method, args, NULL);
    Py_DecRef(args);
    Py_DecRef(method);
    va_end(vl);
    return res;
}

/* Lifecycle */
EXPORT int Py_IsInitialized(void) {
    return 1;
}

EXPORT void Py_Initialize(void) {
}

EXPORT void Py_Finalize(void) {
}

/* Stage 3: Dynamic Module Imports & Global Attributes */

EXPORT PyObject* PyEval_GetBuiltins(void) {
    static PyObject *g_builtins = NULL;
    if (!g_builtins) {
        g_builtins = PyDict_New();
    }
    return g_builtins;
}

EXPORT PyObject* PySys_GetObject(const char *name) {
    (void)name;
    return NULL;
}

EXPORT PyObject* PyImport_ImportModule(const char *name) {
    (void)name;
    return PyDict_New();
}

EXPORT PyObject* PyImport_Import(PyObject *name) {
    (void)name;
    return PyDict_New();
}
