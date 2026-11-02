/*
 * Luthon C-API Proxy: Exceptions & Error Subsystem (core/exceptions.c)
 */

#include "luthon_capi.h"
#include <errno.h>

/* Static Exception Types */
static PyTypeObject _PyExc_BaseException_Type = { 1000000000, &PyType_Type, "BaseException", sizeof(PyObject) };
static PyTypeObject _PyExc_Exception_Type     = { 1000000000, &PyType_Type, "Exception", sizeof(PyObject) };
static PyTypeObject _PyExc_BufferError_Type   = { 1000000000, &PyType_Type, "BufferError", sizeof(PyObject) };
static PyTypeObject _PyExc_IndexError_Type    = { 1000000000, &PyType_Type, "IndexError", sizeof(PyObject) };
static PyTypeObject _PyExc_MemoryError_Type   = { 1000000000, &PyType_Type, "MemoryError", sizeof(PyObject) };
static PyTypeObject _PyExc_OSError_Type       = { 1000000000, &PyType_Type, "OSError", sizeof(PyObject) };
static PyTypeObject _PyExc_OverflowError_Type = { 1000000000, &PyType_Type, "OverflowError", sizeof(PyObject) };
static PyTypeObject _PyExc_RuntimeError_Type  = { 1000000000, &PyType_Type, "RuntimeError", sizeof(PyObject) };
static PyTypeObject _PyExc_SystemError_Type   = { 1000000000, &PyType_Type, "SystemError", sizeof(PyObject) };
static PyTypeObject _PyExc_TypeError_Type     = { 1000000000, &PyType_Type, "TypeError", sizeof(PyObject) };
static PyTypeObject _PyExc_ValueError_Type    = { 1000000000, &PyType_Type, "ValueError", sizeof(PyObject) };

/* Exported Exception Singletons */
EXPORT PyObject *PyExc_BaseException = (PyObject *)&_PyExc_BaseException_Type;
EXPORT PyObject *PyExc_Exception     = (PyObject *)&_PyExc_Exception_Type;
EXPORT PyObject *PyExc_BufferError   = (PyObject *)&_PyExc_BufferError_Type;
EXPORT PyObject *PyExc_IndexError    = (PyObject *)&_PyExc_IndexError_Type;
EXPORT PyObject *PyExc_MemoryError   = (PyObject *)&_PyExc_MemoryError_Type;
EXPORT PyObject *PyExc_OSError       = (PyObject *)&_PyExc_OSError_Type;
EXPORT PyObject *PyExc_OverflowError = (PyObject *)&_PyExc_OverflowError_Type;
EXPORT PyObject *PyExc_RuntimeError  = (PyObject *)&_PyExc_RuntimeError_Type;
EXPORT PyObject *PyExc_SystemError   = (PyObject *)&_PyExc_SystemError_Type;
EXPORT PyObject *PyExc_TypeError     = (PyObject *)&_PyExc_TypeError_Type;
EXPORT PyObject *PyExc_ValueError    = (PyObject *)&_PyExc_ValueError_Type;

/* Global Error State */
static char g_last_error[2048] = {0};
static int  g_has_error = 0;
static PyObject *g_current_exc = NULL;

EXPORT void PyErr_SetString(PyObject *type, const char *message) {
    if (message) {
        snprintf(g_last_error, sizeof(g_last_error), "%s", message);
    } else {
        g_last_error[0] = '\0';
    }
    g_has_error = 1;
    g_current_exc = type;
}

EXPORT PyObject* PyErr_Occurred(void) {
    return g_has_error ? (g_current_exc ? g_current_exc : PyExc_RuntimeError) : NULL;
}

EXPORT void PyErr_Clear(void) {
    g_has_error = 0;
    g_current_exc = NULL;
    g_last_error[0] = '\0';
}

EXPORT PyObject* PyErr_Format(PyObject *exception, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(g_last_error, sizeof(g_last_error), format, args);
    va_end(args);
    g_has_error = 1;
    g_current_exc = exception;
    return NULL;
}

EXPORT PyObject* PyErr_NoMemory(void) {
    PyErr_SetString(PyExc_MemoryError, "out of memory");
    return NULL;
}

EXPORT PyObject* PyErr_SetFromErrno(PyObject *exc) {
    char buf[512];
    snprintf(buf, sizeof(buf), "%s (errno %d)", strerror(errno), errno);
    PyErr_SetString(exc ? exc : PyExc_OSError, buf);
    return NULL;
}

EXPORT int PyErr_ExceptionMatches(PyObject *exc) {
    if (!g_has_error || !g_current_exc) return 0;
    if (g_current_exc == exc) return 1;
    if (exc == PyExc_BaseException || exc == PyExc_Exception) return 1;
    return 0;
}

EXPORT void _PyErr_BadInternalCall(const char *filename, int lineno) {
    PyErr_Format(PyExc_SystemError, "Bad internal call at %s:%d", filename ? filename : "unknown", lineno);
}
