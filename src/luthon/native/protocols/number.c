/*
 * Luthon C-API Proxy: Number Protocols & Rich Comparisons (protocols/number.c)
 */

#include "luthon_capi.h"
#include <math.h>

EXPORT PyObject* PyObject_RichCompare(PyObject *v, PyObject *w, int op) {
    if (!v || !w) return PyBool_FromLong(0);

    /* 1. Custom tp_richcompare slot */
    if (v->ob_type && v->ob_type->tp_richcompare) {
        return v->ob_type->tp_richcompare(v, w, op);
    }
    if (w->ob_type && w->ob_type->tp_richcompare) {
        /* Reverse operator for right operand */
        int rev_op = op;
        switch (op) {
            case Py_LT: rev_op = Py_GT; break;
            case Py_LE: rev_op = Py_GE; break;
            case Py_EQ: rev_op = Py_EQ; break;
            case Py_NE: rev_op = Py_NE; break;
            case Py_GT: rev_op = Py_LT; break;
            case Py_GE: rev_op = Py_LE; break;
        }
        return w->ob_type->tp_richcompare(w, v, rev_op);
    }

    /* 2. Numeric comparison */
    if ((v->tag == PY_TAG_INT || v->tag == PY_TAG_FLOAT) &&
        (w->tag == PY_TAG_INT || w->tag == PY_TAG_FLOAT)) {
        double d1 = (v->tag == PY_TAG_INT) ? (double)v->as.i_val : v->as.f_val;
        double d2 = (w->tag == PY_TAG_INT) ? (double)w->as.i_val : w->as.f_val;
        int cmp = 0;
        switch (op) {
            case Py_LT: cmp = (d1 < d2); break;
            case Py_LE: cmp = (d1 <= d2); break;
            case Py_EQ: cmp = (d1 == d2); break;
            case Py_NE: cmp = (d1 != d2); break;
            case Py_GT: cmp = (d1 > d2); break;
            case Py_GE: cmp = (d1 >= d2); break;
        }
        return PyBool_FromLong(cmp);
    }

    /* 3. Pointer equality fallback */
    int eq = (v == w);
    if (op == Py_EQ) return PyBool_FromLong(eq);
    if (op == Py_NE) return PyBool_FromLong(!eq);

    return PyBool_FromLong(0);
}

EXPORT int PyObject_RichCompareBool(PyObject *v, PyObject *w, int op) {
    PyObject *res = PyObject_RichCompare(v, w, op);
    int b = PyObject_IsTrue(res);
    Py_DecRef(res);
    return b;
}

/* Complex Numbers Implementation */
typedef struct {
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    Py_complex cval;
} PyComplexObject;

EXPORT PyObject* PyComplex_FromDoubles(double real, double imag) {
    PyComplexObject *op = (PyComplexObject *)calloc(1, sizeof(PyComplexObject));
    if (!op) return PyErr_NoMemory();
    op->ob_refcnt = 1;
    op->ob_type = &PyComplex_Type;
    op->tag = PY_TAG_OPAQUE;
    op->cval.real = real;
    op->cval.imag = imag;
    return (PyObject *)op;
}

EXPORT PyObject* PyComplex_FromCComplex(Py_complex v) {
    return PyComplex_FromDoubles(v.real, v.imag);
}

EXPORT Py_complex PyComplex_AsCComplex(PyObject *op) {
    Py_complex c = { 0.0, 0.0 };
    if (!op) return c;
    if (op->ob_type == &PyComplex_Type) {
        return ((PyComplexObject *)op)->cval;
    }
    if (op->tag == PY_TAG_FLOAT) {
        c.real = op->as.f_val;
    } else if (op->tag == PY_TAG_INT || op->tag == PY_TAG_BOOL) {
        c.real = (double)op->as.i_val;
    }
    return c;
}

EXPORT double PyComplex_RealAsDouble(PyObject *op) {
    return PyComplex_AsCComplex(op).real;
}

EXPORT double PyComplex_ImagAsDouble(PyObject *op) {
    return PyComplex_AsCComplex(op).imag;
}

/* Integer and Float Expansion */
EXPORT PyObject* PyLong_FromDouble(double v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT PyObject* PyLong_FromSsize_t(Py_ssize_t v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT PyObject* PyLong_FromUnsignedLong(unsigned long v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT PyObject* PyLong_FromUnsignedLongLong(unsigned long long v) {
    return PyLong_FromLongLong((long long)v);
}

EXPORT PyObject* PyLong_FromVoidPtr(void *p) {
    return PyLong_FromLongLong((long long)(uintptr_t)p);
}

EXPORT PyObject* PyLong_FromUnicodeObject(PyObject *u, int base) {
    (void)base;
    const char *s = PyUnicode_AsUTF8(u);
    return PyLong_FromLongLong(s ? atoll(s) : 0);
}

EXPORT void* PyLong_AsVoidPtr(PyObject *op) {
    return (void *)(uintptr_t)PyLong_AsLongLong(op);
}

EXPORT unsigned long PyLong_AsUnsignedLong(PyObject *op) {
    return (unsigned long)PyLong_AsLongLong(op);
}

EXPORT unsigned long long PyLong_AsUnsignedLongLong(PyObject *op) {
    return (unsigned long long)PyLong_AsLongLong(op);
}

EXPORT long PyLong_AsLongAndOverflow(PyObject *op, int *overflow) {
    if (overflow) *overflow = 0;
    return PyLong_AsLong(op);
}

EXPORT long long PyLong_AsLongLongAndOverflow(PyObject *op, int *overflow) {
    if (overflow) *overflow = 0;
    return PyLong_AsLongLong(op);
}

EXPORT int PyLong_IsZero(PyObject *op) {
    return PyLong_AsLongLong(op) == 0;
}

EXPORT PyObject* PyFloat_FromString(PyObject *str) {
    const char *s = PyUnicode_AsUTF8(str);
    return PyFloat_FromDouble(s ? atof(s) : 0.0);
}

EXPORT Py_hash_t _Py_HashDouble(PyObject *inst, double v) {
    (void)inst;
    return (Py_hash_t)(int64_t)v;
}

EXPORT double PyOS_string_to_double(const char *s, char **endptr, PyObject *overflow_exception) {
    (void)overflow_exception;
    return strtod(s, endptr);
}

EXPORT long PyOS_strtol(const char *str, char **endptr, int base) {
    return strtol(str, endptr, base);
}

EXPORT unsigned long PyOS_strtoul(const char *str, char **endptr, int base) {
    return strtoul(str, endptr, base);
}

/* Number Arithmetic Slot Dispatchers */
EXPORT PyObject* PyNumber_Add(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_add)
        return o1->ob_type->tp_as_number->nb_add(o1, o2);
    if ((o1->tag == PY_TAG_INT || o1->tag == PY_TAG_FLOAT) && (o2->tag == PY_TAG_INT || o2->tag == PY_TAG_FLOAT)) {
        if (o1->tag == PY_TAG_FLOAT || o2->tag == PY_TAG_FLOAT)
            return PyFloat_FromDouble(PyFloat_AsDouble(o1) + PyFloat_AsDouble(o2));
        return PyLong_FromLongLong(PyLong_AsLongLong(o1) + PyLong_AsLongLong(o2));
    }
    return NULL;
}

EXPORT PyObject* PyNumber_Subtract(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_subtract)
        return o1->ob_type->tp_as_number->nb_subtract(o1, o2);
    if ((o1->tag == PY_TAG_INT || o1->tag == PY_TAG_FLOAT) && (o2->tag == PY_TAG_INT || o2->tag == PY_TAG_FLOAT)) {
        if (o1->tag == PY_TAG_FLOAT || o2->tag == PY_TAG_FLOAT)
            return PyFloat_FromDouble(PyFloat_AsDouble(o1) - PyFloat_AsDouble(o2));
        return PyLong_FromLongLong(PyLong_AsLongLong(o1) - PyLong_AsLongLong(o2));
    }
    return NULL;
}

EXPORT PyObject* PyNumber_Multiply(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_multiply)
        return o1->ob_type->tp_as_number->nb_multiply(o1, o2);
    if ((o1->tag == PY_TAG_INT || o1->tag == PY_TAG_FLOAT) && (o2->tag == PY_TAG_INT || o2->tag == PY_TAG_FLOAT)) {
        if (o1->tag == PY_TAG_FLOAT || o2->tag == PY_TAG_FLOAT)
            return PyFloat_FromDouble(PyFloat_AsDouble(o1) * PyFloat_AsDouble(o2));
        return PyLong_FromLongLong(PyLong_AsLongLong(o1) * PyLong_AsLongLong(o2));
    }
    return NULL;
}

EXPORT PyObject* PyNumber_TrueDivide(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_true_divide)
        return o1->ob_type->tp_as_number->nb_true_divide(o1, o2);
    double d2 = PyFloat_AsDouble(o2);
    if (d2 == 0.0) return PyErr_Format(PyExc_ZeroDivisionError, "division by zero");
    return PyFloat_FromDouble(PyFloat_AsDouble(o1) / d2);
}

EXPORT PyObject* PyNumber_FloorDivide(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_floor_divide)
        return o1->ob_type->tp_as_number->nb_floor_divide(o1, o2);
    int64_t i2 = PyLong_AsLongLong(o2);
    if (i2 == 0) return PyErr_Format(PyExc_ZeroDivisionError, "integer division by zero");
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) / i2);
}

EXPORT PyObject* PyNumber_Remainder(PyObject *o1, PyObject *o2) {
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_remainder)
        return o1->ob_type->tp_as_number->nb_remainder(o1, o2);
    int64_t i2 = PyLong_AsLongLong(o2);
    if (i2 == 0) return PyErr_Format(PyExc_ZeroDivisionError, "modulo by zero");
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) % i2);
}

EXPORT PyObject* PyNumber_Divmod(PyObject *o1, PyObject *o2) {
    PyObject *div = PyNumber_FloorDivide(o1, o2);
    PyObject *rem = PyNumber_Remainder(o1, o2);
    PyObject *res = PyTuple_New(2);
    PyTuple_SetItem(res, 0, div);
    PyTuple_SetItem(res, 1, rem);
    return res;
}

EXPORT PyObject* PyNumber_Power(PyObject *o1, PyObject *o2, PyObject *o3) {
    (void)o3;
    if (!o1 || !o2) return NULL;
    if (o1->ob_type && o1->ob_type->tp_as_number && o1->ob_type->tp_as_number->nb_power)
        return o1->ob_type->tp_as_number->nb_power(o1, o2, o3);
    double b = PyFloat_AsDouble(o1), e = PyFloat_AsDouble(o2);
    return PyFloat_FromDouble(pow(b, e));
}

EXPORT PyObject* PyNumber_Negative(PyObject *o) {
    if (!o) return NULL;
    if (o->ob_type && o->ob_type->tp_as_number && o->ob_type->tp_as_number->nb_negative)
        return o->ob_type->tp_as_number->nb_negative(o);
    if (o->tag == PY_TAG_FLOAT) return PyFloat_FromDouble(-o->as.f_val);
    return PyLong_FromLongLong(-PyLong_AsLongLong(o));
}

EXPORT PyObject* PyNumber_Positive(PyObject *o) {
    if (!o) return NULL;
    if (o->ob_type && o->ob_type->tp_as_number && o->ob_type->tp_as_number->nb_positive)
        return o->ob_type->tp_as_number->nb_positive(o);
    Py_IncRef(o);
    return o;
}

EXPORT PyObject* PyNumber_Absolute(PyObject *o) {
    if (!o) return NULL;
    if (o->ob_type && o->ob_type->tp_as_number && o->ob_type->tp_as_number->nb_absolute)
        return o->ob_type->tp_as_number->nb_absolute(o);
    if (o->tag == PY_TAG_FLOAT) return PyFloat_FromDouble(fabs(o->as.f_val));
    int64_t v = PyLong_AsLongLong(o);
    return PyLong_FromLongLong(v < 0 ? -v : v);
}

EXPORT PyObject* PyNumber_Invert(PyObject *o) {
    if (!o) return NULL;
    if (o->ob_type && o->ob_type->tp_as_number && o->ob_type->tp_as_number->nb_invert)
        return o->ob_type->tp_as_number->nb_invert(o);
    return PyLong_FromLongLong(~PyLong_AsLongLong(o));
}

EXPORT PyObject* PyNumber_Lshift(PyObject *o1, PyObject *o2) {
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) << PyLong_AsLongLong(o2));
}

EXPORT PyObject* PyNumber_Rshift(PyObject *o1, PyObject *o2) {
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) >> PyLong_AsLongLong(o2));
}

EXPORT PyObject* PyNumber_And(PyObject *o1, PyObject *o2) {
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) & PyLong_AsLongLong(o2));
}

EXPORT PyObject* PyNumber_Xor(PyObject *o1, PyObject *o2) {
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) ^ PyLong_AsLongLong(o2));
}

EXPORT PyObject* PyNumber_Or(PyObject *o1, PyObject *o2) {
    return PyLong_FromLongLong(PyLong_AsLongLong(o1) | PyLong_AsLongLong(o2));
}

EXPORT PyObject* PyNumber_Index(PyObject *o) {
    if (!o) return NULL;
    return PyLong_FromLongLong(PyLong_AsLongLong(o));
}

EXPORT PyObject* PyNumber_Long(PyObject *o) {
    if (!o) return NULL;
    return PyLong_FromLongLong(PyLong_AsLongLong(o));
}

EXPORT PyObject* PyNumber_Float(PyObject *o) {
    if (!o) return NULL;
    return PyFloat_FromDouble(PyFloat_AsDouble(o));
}
