/*
 * Luthon C-API Proxy: PyCapsule Protocol (core/capsule.c)
 */

#include "luthon_capi.h"

EXPORT PyTypeObject PyCapsule_Type = {
    1000000000,
    &PyType_Type,
    "PyCapsule",
    sizeof(PyCapsuleObject)
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
