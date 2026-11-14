/*
 * Luthon C-API Proxy: PyCapsule Protocol (core/capsule.c)
 */

#include "luthon_capi.h"

EXPORT PyTypeObject PyCapsule_Type = {
    1000000000,
    &PyType_Type,
    "PyCapsule",
    sizeof(PyCapsuleObject),
    0,
    NULL
};

EXPORT PyObject* PyCapsule_New(void *pointer, const char *name, PyCapsule_Destructor destructor) {
    if (!pointer) {
        PyErr_SetString(PyExc_ValueError, "PyCapsule_New called with null pointer");
        return NULL;
    }

    PyCapsuleObject *capsule = (PyCapsuleObject *)calloc(1, sizeof(PyCapsuleObject));
    if (!capsule) {
        return PyErr_NoMemory();
    }

    capsule->ob_refcnt = 1;
    capsule->ob_type = &PyCapsule_Type;
    capsule->tag = PY_TAG_CAPSULE;
    capsule->pointer = pointer;
    capsule->name = name;
    capsule->context = NULL;
    capsule->destructor = destructor;

    if (name) {
        PyCapsule_Register(name, pointer);
    }

    return (PyObject *)capsule;
}

EXPORT int PyCapsule_IsValid(PyObject *op, const char *name) {
    if (!op || op->tag != PY_TAG_CAPSULE) return 0;
    PyCapsuleObject *capsule = (PyCapsuleObject *)op;
    if (!capsule->pointer) return 0;
    if (name && (!capsule->name || strcmp(name, capsule->name) != 0)) return 0;
    return 1;
}

EXPORT void* PyCapsule_GetPointer(PyObject *op, const char *name) {
    if (!op || op->tag != PY_TAG_CAPSULE) {
        PyErr_SetString(PyExc_TypeError, "PyCapsule_GetPointer called with non-capsule object");
        return NULL;
    }
    PyCapsuleObject *capsule = (PyCapsuleObject *)op;
    if (name) {
        if (!capsule->name || strcmp(name, capsule->name) != 0) {
            PyErr_Format(PyExc_ValueError, "PyCapsule_GetPointer called with incorrect name (expected '%s', got '%s')",
                         name, capsule->name ? capsule->name : "<null>");
            return NULL;
        }
    }
    return capsule->pointer;
}

EXPORT void* PyCapsule_GetContext(PyObject *op) {
    if (!op || op->tag != PY_TAG_CAPSULE) {
        PyErr_SetString(PyExc_TypeError, "PyCapsule_GetContext called with non-capsule object");
        return NULL;
    }
    PyCapsuleObject *capsule = (PyCapsuleObject *)op;
    return capsule->context;
}

EXPORT int PyCapsule_SetContext(PyObject *op, void *context) {
    if (!op || op->tag != PY_TAG_CAPSULE) {
        PyErr_SetString(PyExc_TypeError, "PyCapsule_SetContext called with non-capsule object");
        return -1;
    }
    PyCapsuleObject *capsule = (PyCapsuleObject *)op;
    capsule->context = context;
    return 0;
}

EXPORT int PyCapsule_SetName(PyObject *op, const char *name) {
    if (!op || op->tag != PY_TAG_CAPSULE) {
        PyErr_SetString(PyExc_TypeError, "PyCapsule_SetName called with non-capsule object");
        return -1;
    }
    PyCapsuleObject *capsule = (PyCapsuleObject *)op;
    capsule->name = name;
    return 0;
}

/* Global Capsule Registry for Inter-Module C-API Function Tables (Phase 40) */
typedef struct _CapsuleEntry {
    char name[128];
    void *pointer;
    struct _CapsuleEntry *next;
} CapsuleEntry;

static CapsuleEntry *g_capsules = NULL;

EXPORT int PyCapsule_Register(const char *name, void *pointer) {
    if (!name || !pointer) return -1;
    for (CapsuleEntry *e = g_capsules; e; e = e->next) {
        if (strcmp(e->name, name) == 0) {
            e->pointer = pointer;
            return 0;
        }
    }
    CapsuleEntry *new_entry = (CapsuleEntry *)malloc(sizeof(CapsuleEntry));
    if (!new_entry) return -1;
    strncpy(new_entry->name, name, sizeof(new_entry->name) - 1);
    new_entry->name[sizeof(new_entry->name) - 1] = '\0';
    new_entry->pointer = pointer;
    new_entry->next = g_capsules;
    g_capsules = new_entry;
    return 0;
}

EXPORT void* PyCapsule_Import(const char *name, int no_block) {
    if (!name) return NULL;

    /* 1. Check global capsule registry table */
    for (CapsuleEntry *e = g_capsules; e; e = e->next) {
        if (strcmp(e->name, name) == 0) {
            return e->pointer;
        }
    }

    /* 2. Hierarchical module attribute lookup (e.g. "scipy.linalg.cython_blas") */
    const char *last_dot = strrchr(name, '.');
    if (last_dot) {
        size_t mod_len = (size_t)(last_dot - name);
        char mod_name[128];
        if (mod_len < sizeof(mod_name)) {
            memcpy(mod_name, name, mod_len);
            mod_name[mod_len] = '\0';
            const char *attr_name = last_dot + 1;

            PyObject *mod = PyImport_ImportModule(mod_name);
            if (mod) {
                PyObject *capsule_obj = PyObject_GetAttrString(mod, attr_name);
                if (capsule_obj) {
                    void *ptr = PyCapsule_GetPointer(capsule_obj, name);
                    Py_DecRef(capsule_obj);
                    if (ptr) {
                        PyCapsule_Register(name, ptr);
                        return ptr;
                    }
                }
            }
        }
    }

    if (!no_block) {
        PyErr_Format(PyExc_ImportError, "PyCapsule_Import could not import capsule '%s'", name);
    }
    return NULL;
}
