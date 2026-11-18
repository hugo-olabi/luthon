/*
 * Luthon C-API Proxy: Module Loader & Reflection Dispatch (modules/loader.c)
 */

#define _GNU_SOURCE
#include <elf.h>
#include <dlfcn.h>
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

static int _vparse_tuple(PyObject *args, const char *fmt, va_list vl) {
    if (!args || args->tag != PY_TAG_TUPLE) return 0;
    Py_ssize_t arg_idx = 0;
    Py_ssize_t total = args->as.seq_val.size;

    for (const char *p = fmt; *p; p++) {
        if (*p == '|') continue;
        if (*p == ':') break;

        if (arg_idx >= total) {
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
    return 1;
}

EXPORT int PyArg_ParseTuple(PyObject *args, const char *fmt, ...) {
    va_list vl;
    va_start(vl, fmt);
    int res = _vparse_tuple(args, fmt, vl);
    va_end(vl);
    return res;
}

EXPORT int PyArg_ParseTupleAndKeywords(PyObject *args, PyObject *kwargs, const char *fmt, char **kwlist, ...) {
    (void)kwargs; (void)kwlist;
    va_list vl;
    va_start(vl, kwlist);
    int res = _vparse_tuple(args, fmt, vl);
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

/* Extension Preflight Validation */
EXPORT int luthon_capi_can_load_extension(const char *so_path, const char *init_symbol) {
    if (!so_path) return 0;
    FILE *fp = fopen(so_path, "rb");
    if (!fp) return 0;

    Elf64_Ehdr ehdr;
    if (fread(&ehdr, sizeof(ehdr), 1, fp) != 1) {
        fclose(fp);
        return 0;
    }

    if (memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0 || ehdr.e_ident[EI_CLASS] != ELFCLASS64) {
        fclose(fp);
        return 0;
    }

    if (ehdr.e_shoff == 0 || ehdr.e_shnum == 0) {
        fclose(fp);
        return 0;
    }

    Elf64_Shdr *shdrs = malloc(sizeof(Elf64_Shdr) * ehdr.e_shnum);
    if (!shdrs) {
        fclose(fp);
        return 0;
    }

    if (fseek(fp, ehdr.e_shoff, SEEK_SET) != 0 ||
        fread(shdrs, sizeof(Elf64_Shdr), ehdr.e_shnum, fp) != ehdr.e_shnum) {
        free(shdrs);
        fclose(fp);
        return 0;
    }

    Elf64_Shdr *dynsym_sh = NULL;
    Elf64_Shdr *dynstr_sh = NULL;

    for (int i = 0; i < ehdr.e_shnum; i++) {
        if (shdrs[i].sh_type == SHT_DYNSYM) {
            dynsym_sh = &shdrs[i];
            if (dynsym_sh->sh_link < ehdr.e_shnum) {
                dynstr_sh = &shdrs[dynsym_sh->sh_link];
            }
            break;
        }
    }

    if (!dynsym_sh || !dynstr_sh || dynsym_sh->sh_entsize == 0) {
        free(shdrs);
        fclose(fp);
        return 0;
    }

    size_t num_syms = dynsym_sh->sh_size / dynsym_sh->sh_entsize;
    Elf64_Sym *syms = malloc(dynsym_sh->sh_size);
    char *strings = malloc(dynstr_sh->sh_size);
    if (!syms || !strings) {
        free(syms);
        free(strings);
        free(shdrs);
        fclose(fp);
        return 0;
    }

    if (fseek(fp, dynsym_sh->sh_offset, SEEK_SET) != 0 ||
        fread(syms, dynsym_sh->sh_size, 1, fp) != 1 ||
        fseek(fp, dynstr_sh->sh_offset, SEEK_SET) != 0 ||
        fread(strings, dynstr_sh->sh_size, 1, fp) != 1) {
        free(syms);
        free(strings);
        free(shdrs);
        fclose(fp);
        return 0;
    }

    fclose(fp);
    free(shdrs);

    Dl_info info;
    void *capi_handle = NULL;
    if (dladdr((void *)luthon_capi_can_load_extension, &info) && info.dli_fname) {
        capi_handle = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    }
    if (!capi_handle) {
        capi_handle = dlopen(NULL, RTLD_NOW);
    }

    int found_init = (init_symbol == NULL) ? 1 : 0;
    int can_load = 1;

    for (size_t i = 0; i < num_syms; i++) {
        if (syms[i].st_name >= dynstr_sh->sh_size) continue;
        const char *name = strings + syms[i].st_name;
        if (!name || !*name) continue;

        if (init_symbol && strcmp(name, init_symbol) == 0) {
            if (syms[i].st_shndx != SHN_UNDEF) {
                found_init = 1;
            }
        }

        if (syms[i].st_shndx == SHN_UNDEF) {
            if (strncmp(name, "Py", 2) == 0 || strncmp(name, "_Py", 3) == 0) {
                void *sym_ptr = capi_handle ? dlsym(capi_handle, name) : dlsym(RTLD_DEFAULT, name);
                if (!sym_ptr) {
                    can_load = 0;
                    break;
                }
            }
        }
    }

    if (capi_handle) {
        dlclose(capi_handle);
    }
    free(syms);
    free(strings);

    return can_load && found_init;
}

/* Single-Phase and PEP 489 Multi-Phase Module Initialization */
EXPORT PyObject* luthon_capi_init_module(void *init_fn_ptr, const char *name) {
    if (!init_fn_ptr) return NULL;
    typedef PyObject *(*init_func)(void);
    init_func fn = (init_func)init_fn_ptr;
    PyObject *res = fn();
    if (!res) return NULL;

    if (res->tag == PY_TAG_MODULE) {
        if (name && res->as.mod_val.dict) {
            PyDict_SetItemString(res->as.mod_val.dict, "__name__", PyUnicode_FromString(name));
        }
        return res;
    }

    PyModuleDef *def = (PyModuleDef *)res;
    PyObject *mod = PyModule_FromDefAndSpec2(def, NULL, 3);
    if (!mod) return NULL;
    if (PyModule_ExecDef(mod, def) != 0) {
        Py_DecRef(mod);
        return NULL;
    }
    if (name && mod->as.mod_val.dict) {
        PyDict_SetItemString(mod->as.mod_val.dict, "__name__", PyUnicode_FromString(name));
    }
    return mod;
}

EXPORT PyMethodDef* luthon_capi_get_module_methods(PyObject *mod) {
    if (!mod || mod->tag != PY_TAG_MODULE) return NULL;
    void *raw_def = mod->as.mod_val.module_def;
    if (!raw_def) return NULL;
    const char *name = NULL, *doc = NULL;
    PyMethodDef *methods = NULL;
    _get_module_def_fields(raw_def, &name, &doc, &methods);
    return methods;
}

/* C-Function Invocation Dispatch */
EXPORT PyObject* luthon_capi_call_cfunction(void *meth_ptr, int ml_flags, PyObject *self, PyObject *args, PyObject *kwargs) {
    if (!meth_ptr) return NULL;

    if (ml_flags & METH_KEYWORDS) {
        typedef PyObject *(*cfunc_kw)(PyObject *, PyObject *, PyObject *);
        cfunc_kw fn = (cfunc_kw)meth_ptr;
        return fn(self, args ? args : PyTuple_New(0), kwargs);
    } else if (ml_flags & METH_NOARGS) {
        typedef PyObject *(*cfunc_noargs)(PyObject *, PyObject *);
        cfunc_noargs fn = (cfunc_noargs)meth_ptr;
        return fn(self, NULL);
    } else if (ml_flags & METH_O) {
        typedef PyObject *(*cfunc_o)(PyObject *, PyObject *);
        cfunc_o fn = (cfunc_o)meth_ptr;
        PyObject *arg = Py_None;
        if (args && args->tag == PY_TAG_TUPLE && args->as.seq_val.size > 0) {
            arg = args->as.seq_val.items[0];
        } else if (args) {
            arg = args;
        }
        return fn(self, arg);
    } else {
        typedef PyObject *(*cfunc_varargs)(PyObject *, PyObject *);
        cfunc_varargs fn = (cfunc_varargs)meth_ptr;
        return fn(self, args ? args : PyTuple_New(0));
    }
}
