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
static PyTypeObject _PyExc_AttributeError_Type = { 1000000000, &PyType_Type, "AttributeError", sizeof(PyObject) };
static PyTypeObject _PyExc_KeyError_Type       = { 1000000000, &PyType_Type, "KeyError", sizeof(PyObject) };
static PyTypeObject _PyExc_NameError_Type      = { 1000000000, &PyType_Type, "NameError", sizeof(PyObject) };
static PyTypeObject _PyExc_NotImplementedError_Type = { 1000000000, &PyType_Type, "NotImplementedError", sizeof(PyObject) };
static PyTypeObject _PyExc_RecursionError_Type = { 1000000000, &PyType_Type, "RecursionError", sizeof(PyObject) };
static PyTypeObject _PyExc_UserWarning_Type    = { 1000000000, &PyType_Type, "UserWarning", sizeof(PyObject) };
static PyTypeObject _PyExc_DeprecationWarning_Type = { 1000000000, &PyType_Type, "DeprecationWarning", sizeof(PyObject) };
static PyTypeObject _PyExc_FutureWarning_Type  = { 1000000000, &PyType_Type, "FutureWarning", sizeof(PyObject) };
static PyTypeObject _PyExc_RuntimeWarning_Type = { 1000000000, &PyType_Type, "RuntimeWarning", sizeof(PyObject) };
static PyTypeObject _PyExc_FloatingPointError_Type = { 1000000000, &PyType_Type, "FloatingPointError", sizeof(PyObject) };
static PyTypeObject _PyExc_IOError_Type        = { 1000000000, &PyType_Type, "IOError", sizeof(PyObject) };
static PyTypeObject _PyExc_ImportError_Type    = { 1000000000, &PyType_Type, "ImportError", sizeof(PyObject) };
static PyTypeObject _PyExc_ImportWarning_Type  = { 1000000000, &PyType_Type, "ImportWarning", sizeof(PyObject) };
static PyTypeObject _PyExc_UnicodeDecodeError_Type = { 1000000000, &PyType_Type, "UnicodeDecodeError", sizeof(PyObject) };
static PyTypeObject _PyExc_UnicodeEncodeError_Type = { 1000000000, &PyType_Type, "UnicodeEncodeError", sizeof(PyObject) };
static PyTypeObject _PyExc_ZeroDivisionError_Type  = { 1000000000, &PyType_Type, "ZeroDivisionError", sizeof(PyObject) };

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
EXPORT PyObject *PyExc_AttributeError = (PyObject *)&_PyExc_AttributeError_Type;
EXPORT PyObject *PyExc_KeyError       = (PyObject *)&_PyExc_KeyError_Type;
EXPORT PyObject *PyExc_NameError      = (PyObject *)&_PyExc_NameError_Type;
EXPORT PyObject *PyExc_NotImplementedError = (PyObject *)&_PyExc_NotImplementedError_Type;
EXPORT PyObject *PyExc_RecursionError = (PyObject *)&_PyExc_RecursionError_Type;
EXPORT PyObject *PyExc_UserWarning    = (PyObject *)&_PyExc_UserWarning_Type;
EXPORT PyObject *PyExc_DeprecationWarning = (PyObject *)&_PyExc_DeprecationWarning_Type;
EXPORT PyObject *PyExc_FutureWarning  = (PyObject *)&_PyExc_FutureWarning_Type;
EXPORT PyObject *PyExc_RuntimeWarning = (PyObject *)&_PyExc_RuntimeWarning_Type;
EXPORT PyObject *PyExc_FloatingPointError = (PyObject *)&_PyExc_FloatingPointError_Type;
EXPORT PyObject *PyExc_IOError        = (PyObject *)&_PyExc_IOError_Type;
EXPORT PyObject *PyExc_ImportError    = (PyObject *)&_PyExc_ImportError_Type;
EXPORT PyObject *PyExc_ImportWarning  = (PyObject *)&_PyExc_ImportWarning_Type;
EXPORT PyObject *PyExc_UnicodeDecodeError = (PyObject *)&_PyExc_UnicodeDecodeError_Type;
EXPORT PyObject *PyExc_UnicodeEncodeError = (PyObject *)&_PyExc_UnicodeEncodeError_Type;
EXPORT PyObject *PyExc_ZeroDivisionError  = (PyObject *)&_PyExc_ZeroDivisionError_Type;

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

/* Stage 6: Error Protocol Expansions & Exception Contexts */
EXPORT int PyErr_CheckSignals(void) {
    return 0;
}

EXPORT void PyErr_SetNone(PyObject *exception) {
    PyErr_SetString(exception, "");
}

EXPORT void PyErr_SetObject(PyObject *type, PyObject *value) {
    g_has_error = 1;
    g_current_exc = type;
    const char *s = PyUnicode_AsUTF8(value);
    if (s && *s) {
        snprintf(g_last_error, sizeof(g_last_error), "%s", s);
    }
}

EXPORT void PyErr_Fetch(PyObject **ptype, PyObject **pvalue, PyObject **ptraceback) {
    if (ptype) *ptype = g_current_exc;
    if (pvalue) *pvalue = g_has_error ? PyUnicode_FromString(g_last_error) : NULL;
    if (ptraceback) *ptraceback = NULL;
    PyErr_Clear();
}

EXPORT void PyErr_Restore(PyObject *type, PyObject *value, PyObject *traceback) {
    g_current_exc = type;
    g_has_error = (type != NULL);
    if (value) {
        const char *s = PyUnicode_AsUTF8(value);
        if (s) snprintf(g_last_error, sizeof(g_last_error), "%s", s);
    }
    (void)traceback;
}

EXPORT int PyErr_GivenExceptionMatches(PyObject *err, PyObject *exc) {
    if (!err || !exc) return 0;
    if (err == exc) return 1;
    if (exc == PyExc_BaseException || exc == PyExc_Exception) return 1;
    return PyType_IsSubtype(err->ob_type, (PyTypeObject *)exc);
}

EXPORT void PyErr_NormalizeException(PyObject **exc, PyObject **val, PyObject **tb) {
    (void)exc; (void)val; (void)tb;
}

EXPORT void PyErr_Print(void) {
    if (g_has_error) {
        fprintf(stderr, "Exception: %s\n", g_last_error);
        PyErr_Clear();
    }
}

EXPORT int PyErr_WarnEx(PyObject *category, const char *message, Py_ssize_t stack_level) {
    (void)category; (void)message; (void)stack_level;
    return 0;
}

EXPORT int PyErr_WarnFormat(PyObject *category, Py_ssize_t stack_level, const char *format, ...) {
    (void)category; (void)stack_level; (void)format;
    return 0;
}

EXPORT void PyErr_WriteUnraisable(PyObject *obj) {
    (void)obj;
}

EXPORT void PyException_SetCause(PyObject *self, PyObject *cause) {
    (void)self; (void)cause;
}

EXPORT void PyException_SetContext(PyObject *self, PyObject *context) {
    (void)self; (void)context;
}

EXPORT int PyException_SetTraceback(PyObject *self, PyObject *tb) {
    (void)self; (void)tb;
    return 0;
}
