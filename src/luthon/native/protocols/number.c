/*
 * Luthon C-API Proxy: Number Protocols & Rich Comparisons (protocols/number.c)
 */

#include "luthon_capi.h"

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
