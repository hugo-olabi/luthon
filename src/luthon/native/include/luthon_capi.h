/*
 * Luthon CPython C-API Proxy Engine (luthon_capi.h)
 * =================================================
 * Core types, macros, and function declarations emulating CPython's C-API
 * ABI for binary Python C-extensions executed under LuaJIT FFI.
 */

#ifndef LUTHON_CAPI_H
#define LUTHON_CAPI_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define EXPORT __declspec(dllexport)
#else
  #define EXPORT __attribute__((visibility("default")))
#endif

typedef intptr_t Py_ssize_t;
typedef intptr_t Py_hash_t;
#define PY_SSIZE_T_MAX ((Py_ssize_t)(((size_t)-1) >> 1))

/* Tagged union classification */
typedef enum {
    PY_TAG_NONE = 0,
    PY_TAG_BOOL,
    PY_TAG_INT,
    PY_TAG_FLOAT,
    PY_TAG_STR,
    PY_TAG_BYTES,
    PY_TAG_TUPLE,
    PY_TAG_LIST,
    PY_TAG_DICT,
    PY_TAG_MODULE,
    PY_TAG_OPAQUE,
    PY_TAG_SLICE,
    PY_TAG_STREAM,
    PY_TAG_CAPSULE
} PyTag;

/* Forward declarations */
struct _object;
typedef struct _object PyObject;
struct _typeobject;
typedef struct _typeobject PyTypeObject;

/* PyMethodDef */
typedef struct PyMethodDef {
    const char  *ml_name;
    void        *ml_meth;
    int          ml_flags;
    const char  *ml_doc;
} PyMethodDef;

/* Descriptors, Properties & GetSet */
typedef PyObject *(*getter)(PyObject *, void *);
typedef int (*setter)(PyObject *, PyObject *, void *);

typedef struct PyGetSetDef {
    const char *name;
    getter      get;
    setter      set;
    const char *doc;
    void       *closure;
} PyGetSetDef;

typedef PyObject *(*descrgetfunc)(PyObject *, PyObject *, PyObject *);
typedef int (*descrsetfunc)(PyObject *, PyObject *, PyObject *);
typedef intptr_t (*hashfunc)(PyObject *);

/* Struct Member Descriptors */
typedef struct PyMemberDef {
    const char *name;
    int         type;
    Py_ssize_t  offset;
    int         flags;
    const char *doc;
} PyMemberDef;

#define T_SHORT          0
#define T_INT            1
#define T_LONG           2
#define T_FLOAT          3
#define T_DOUBLE         4
#define T_STRING         5
#define T_OBJECT         6
#define T_CHAR           7
#define T_BYTE           8
#define T_UBYTE          9
#define T_USHORT         10
#define T_UINT           11
#define T_ULONG          12
#define T_STRING_INPLACE 13
#define T_BOOL           14
#define T_LONGLONG       16
#define T_ULONGLONG      17
#define T_PYSSIZET       18
#define READONLY         1

/* Sequence Iterator structure */
typedef struct {
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    int _pad;
    PyObject *seq;
    Py_ssize_t it_index;
} PySeqIterObject;

/* PyModuleDef_Base matching CPython 3.x */
typedef struct PyModuleDef_Base {
    Py_ssize_t  ob_refcnt;
    void       *ob_type;
    void*     (*m_init)(void);
    Py_ssize_t  m_index;
    void       *m_copy;
} PyModuleDef_Base;

/* PyModuleDef */
typedef struct PyModuleDef {
    PyModuleDef_Base m_base;
    const char      *m_name;
    const char      *m_doc;
    Py_ssize_t       m_size;
    PyMethodDef     *m_methods;
} PyModuleDef;

/* PEP 3118 Buffer Protocol Flags */
#define PyBUF_SIMPLE         0
#define PyBUF_WRITABLE       0x0001
#define PyBUF_FORMAT         0x0004
#define PyBUF_ND             0x0008
#define PyBUF_STRIDES        (0x0010 | PyBUF_ND)
#define PyBUF_C_CONTIGUOUS   (0x0020 | PyBUF_STRIDES)
#define PyBUF_F_CONTIGUOUS   (0x0040 | PyBUF_STRIDES)
#define PyBUF_ANY_CONTIGUOUS (0x0080 | PyBUF_STRIDES)
#define PyBUF_INDIRECT       (0x0100 | PyBUF_STRIDES)

#define PyBUF_FULL           (PyBUF_INDIRECT | PyBUF_WRITABLE | PyBUF_FORMAT)
#define PyBUF_FULL_RO        (PyBUF_INDIRECT | PyBUF_FORMAT)
#define PyBUF_RECORDS        (PyBUF_STRIDES | PyBUF_WRITABLE | PyBUF_FORMAT)
#define PyBUF_RECORDS_RO     (PyBUF_STRIDES | PyBUF_FORMAT)
#define PyBUF_STRIDED        (PyBUF_STRIDES | PyBUF_WRITABLE)
#define PyBUF_STRIDED_RO     (PyBUF_STRIDES)
#define PyBUF_CONTIG         (PyBUF_ND | PyBUF_WRITABLE)
#define PyBUF_CONTIG_RO      (PyBUF_ND)

struct bufferinfo;
typedef struct bufferinfo Py_buffer;

typedef int (*getbufferproc)(PyObject *, Py_buffer *, int);
typedef void (*releasebufferproc)(PyObject *, Py_buffer *);

typedef struct {
    getbufferproc     bf_getbuffer;
    releasebufferproc bf_releasebuffer;
} PyBufferProcs;

/* Complex number matching CPython */
typedef struct Py_complex {
    double real;
    double imag;
} Py_complex;

typedef struct bufferinfo {
    void *buf;
    PyObject *obj;
    Py_ssize_t len;
    Py_ssize_t itemsize;
    int readonly;
    int ndim;
    char *format;
    Py_ssize_t *shape;
    Py_ssize_t *strides;
    Py_ssize_t *suboffsets;
    void *internal;
} Py_buffer;

/* Number Methods Protocol */
typedef struct {
    PyObject *(*nb_add)(PyObject *, PyObject *);
    PyObject *(*nb_subtract)(PyObject *, PyObject *);
    PyObject *(*nb_multiply)(PyObject *, PyObject *);
    PyObject *(*nb_remainder)(PyObject *, PyObject *);
    PyObject *(*nb_divmod)(PyObject *, PyObject *);
    PyObject *(*nb_power)(PyObject *, PyObject *, PyObject *);
    PyObject *(*nb_negative)(PyObject *);
    PyObject *(*nb_positive)(PyObject *);
    PyObject *(*nb_absolute)(PyObject *);
    int (*nb_bool)(PyObject *);
    PyObject *(*nb_invert)(PyObject *);
    PyObject *(*nb_lshift)(PyObject *, PyObject *);
    PyObject *(*nb_rshift)(PyObject *, PyObject *);
    PyObject *(*nb_and)(PyObject *, PyObject *);
    PyObject *(*nb_xor)(PyObject *, PyObject *);
    PyObject *(*nb_or)(PyObject *, PyObject *);
    PyObject *(*nb_int)(PyObject *);
    void *nb_reserved;
    PyObject *(*nb_float)(PyObject *);
    PyObject *(*nb_inplace_add)(PyObject *, PyObject *);
    PyObject *(*nb_inplace_subtract)(PyObject *, PyObject *);
    PyObject *(*nb_inplace_multiply)(PyObject *, PyObject *);
    PyObject *(*nb_true_divide)(PyObject *, PyObject *);
    PyObject *(*nb_floor_divide)(PyObject *, PyObject *);
} PyNumberMethods;

/* Sequence Methods Protocol */
typedef struct {
    Py_ssize_t (*sq_length)(PyObject *);
    PyObject *(*sq_concat)(PyObject *, PyObject *);
    PyObject *(*sq_repeat)(PyObject *, Py_ssize_t);
    PyObject *(*sq_item)(PyObject *, Py_ssize_t);
    void *was_sq_slice;
    int (*sq_ass_item)(PyObject *, Py_ssize_t, PyObject *);
    void *was_sq_ass_slice;
    int (*sq_contains)(PyObject *, PyObject *);
    PyObject *(*sq_inplace_concat)(PyObject *, PyObject *);
    PyObject *(*sq_inplace_repeat)(PyObject *, Py_ssize_t);
} PySequenceMethods;

/* Mapping Methods Protocol */
typedef struct {
    Py_ssize_t (*mp_length)(PyObject *);
    PyObject *(*mp_subscript)(PyObject *, PyObject *);
    int (*mp_ass_subscript)(PyObject *, PyObject *, PyObject *);
} PyMappingMethods;

/* PyTypeObject definition */
struct _typeobject {
    Py_ssize_t ob_refcnt;
    struct _typeobject *ob_type;
    const char *tp_name;
    Py_ssize_t tp_basicsize;
    Py_ssize_t tp_itemsize;
    void (*tp_dealloc)(PyObject *);
    void *tp_print;
    void *tp_getattr;
    void *tp_setattr;
    void *tp_as_async;
    void *tp_repr;
    PyNumberMethods *tp_as_number;
    PySequenceMethods *tp_as_sequence;
    PyMappingMethods *tp_as_mapping;
    void *tp_hash;
    PyObject *(*tp_call)(PyObject *, PyObject *, PyObject *);
    void *tp_str;
    PyObject *(*tp_getattro)(PyObject *, PyObject *);
    int (*tp_setattro)(PyObject *, PyObject *, PyObject *);
    void *tp_as_buffer;
    unsigned long tp_flags;
    const char *tp_doc;
    void *tp_traverse;
    void *tp_clear;
    PyObject *(*tp_richcompare)(PyObject *, PyObject *, int);
    Py_ssize_t tp_weaklistoffset;
    PyObject *(*tp_iter)(PyObject *);
    PyObject *(*tp_iternext)(PyObject *);
    PyMethodDef *tp_methods;
    void *tp_members;
    void *tp_getset;
    struct _typeobject *tp_base;
    PyObject *tp_dict;
    void *tp_descr_get;
    void *tp_descr_set;
    Py_ssize_t tp_dictoffset;
    int (*tp_init)(PyObject *, PyObject *, PyObject *);
    void *tp_alloc;
    PyObject *(*tp_new)(struct _typeobject *, PyObject *, PyObject *);
    void *tp_free;
};

/* Slice structure */
typedef struct {
    PyObject *start;
    PyObject *stop;
    PyObject *step;
} PySliceObject;

/* Stream structure for native io.BytesIO without CPython */
typedef struct {
    uint8_t *buffer;
    Py_ssize_t size;
    Py_ssize_t capacity;
    Py_ssize_t pos;
    int is_readonly;
} PyStreamObject;

/* Capsule structure */
typedef void (*PyCapsule_Destructor)(PyObject *);
typedef struct {
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    void *pointer;
    const char *name;
    void *context;
    PyCapsule_Destructor destructor;
} PyCapsuleObject;

/* Tagged union PyObject */
struct _object {
    Py_ssize_t ob_refcnt;
    PyTypeObject *ob_type;
    PyTag tag;
    int buf_locks;
    union {
        int64_t i_val;
        double f_val;
        struct {
            char *data;
            Py_ssize_t size;
        } str_val;
        struct {
            PyObject **items;
            Py_ssize_t size;
        } seq_val;
        struct {
            void *ptr;
            Py_ssize_t size;
        } buf_val;
        PySliceObject slice_val;
        PyStreamObject stream_val;
        void *module_def;
    } as;
};

/* Rich comparison constants */
#define Py_LT 0
#define Py_LE 1
#define Py_EQ 2
#define Py_NE 3
#define Py_GT 4
#define Py_GE 5

/* PyMethodDef flags */
#define METH_VARARGS  0x0001
#define METH_KEYWORDS 0x0002
#define METH_NOARGS   0x0004
#define METH_O        0x0008

/* Global Types */
extern EXPORT PyTypeObject Base_Type;
extern EXPORT PyTypeObject PyType_Type;
extern EXPORT PyTypeObject PyLong_Type;
extern EXPORT PyTypeObject PyFloat_Type;
extern EXPORT PyTypeObject PyUnicode_Type;
extern EXPORT PyTypeObject PyBytes_Type;
extern EXPORT PyTypeObject PyTuple_Type;
extern EXPORT PyTypeObject PyList_Type;
extern EXPORT PyTypeObject PyDict_Type;
extern EXPORT PyTypeObject PyBool_Type;
extern EXPORT PyTypeObject PySlice_Type;
extern EXPORT PyTypeObject PyStream_Type;
extern EXPORT PyTypeObject PyCapsule_Type;

extern EXPORT PyTypeObject PyBaseObject_Type;
extern EXPORT PyTypeObject PyComplex_Type;
extern EXPORT PyTypeObject PyCFunction_Type;
extern EXPORT PyTypeObject PyDictProxy_Type;
extern EXPORT PyTypeObject PyGetSetDescr_Type;
extern EXPORT PyTypeObject PyMemberDescr_Type;
extern EXPORT PyTypeObject PyMethodDescr_Type;
extern EXPORT PyTypeObject PyMemoryView_Type;
extern EXPORT PyTypeObject PySet_Type;
extern EXPORT PyTypeObject PyFrozenSet_Type;

/* Singletons */
extern EXPORT PyObject _Py_NotImplementedStruct;
extern EXPORT PyObject _Py_EllipsisObject;
#define Py_NotImplemented (&_Py_NotImplementedStruct)
#define Py_Ellipsis (&_Py_EllipsisObject)

/* Character classification array */
extern EXPORT const unsigned char _Py_ascii_whitespace[256];


/* Global Singletons */
extern EXPORT PyObject _Py_NoneStruct;
extern EXPORT PyObject _Py_TrueStruct;
extern EXPORT PyObject _Py_FalseStruct;

/* Exception Singletons */
extern EXPORT PyObject *PyExc_BaseException;
extern EXPORT PyObject *PyExc_Exception;
extern EXPORT PyObject *PyExc_BufferError;
extern EXPORT PyObject *PyExc_IndexError;
extern EXPORT PyObject *PyExc_MemoryError;
extern EXPORT PyObject *PyExc_OSError;
extern EXPORT PyObject *PyExc_OverflowError;
extern EXPORT PyObject *PyExc_RuntimeError;
extern EXPORT PyObject *PyExc_SystemError;
extern EXPORT PyObject *PyExc_TypeError;
extern EXPORT PyObject *PyExc_ValueError;
extern EXPORT PyObject *PyExc_AttributeError;
extern EXPORT PyObject *PyExc_KeyError;
extern EXPORT PyObject *PyExc_NameError;
extern EXPORT PyObject *PyExc_NotImplementedError;
extern EXPORT PyObject *PyExc_RecursionError;
extern EXPORT PyObject *PyExc_UserWarning;
extern EXPORT PyObject *PyExc_DeprecationWarning;
extern EXPORT PyObject *PyExc_FutureWarning;
extern EXPORT PyObject *PyExc_RuntimeWarning;
extern EXPORT PyObject *PyExc_FloatingPointError;
extern EXPORT PyObject *PyExc_IOError;
extern EXPORT PyObject *PyExc_ImportError;
extern EXPORT PyObject *PyExc_ImportWarning;
extern EXPORT PyObject *PyExc_UnicodeDecodeError;
extern EXPORT PyObject *PyExc_UnicodeEncodeError;
extern EXPORT PyObject *PyExc_ZeroDivisionError;

#define Py_None  (&_Py_NoneStruct)
#define Py_True  (&_Py_TrueStruct)
#define Py_False (&_Py_FalseStruct)

/* Core Object API */
EXPORT PyObject* alloc_pyobject(PyTag tag, PyTypeObject *type);
EXPORT PyObject* _PyObject_New(PyTypeObject *tp);
EXPORT void _Py_Dealloc(PyObject *o);
EXPORT void PyObject_Free(void *ptr);
EXPORT int PyObject_Print(PyObject *op, FILE *fp, int flags);
EXPORT int PyType_IsSubtype(PyTypeObject *a, PyTypeObject *b);
EXPORT void* PyEval_SaveThread(void);
EXPORT void PyEval_RestoreThread(void *tstate);
EXPORT int PyOS_snprintf(char *str, size_t size, const char *format, ...);
EXPORT void Py_IncRef(PyObject *o);
EXPORT void Py_DecRef(PyObject *o);
EXPORT int PyObject_IsTrue(PyObject *o);
EXPORT PyObject* PyObject_Type(PyObject *o);
EXPORT PyObject* PyObject_GetIter(PyObject *o);
EXPORT PyObject* PyObject_SelfIter(PyObject *o);
EXPORT PyObject* PyObject_Str(PyObject *o);
EXPORT const char* PyUnicode_AsUTF8(PyObject *o);

/* Primitive Constructors & Accessors */
EXPORT PyObject* PyLong_FromLongLong(long long v);
EXPORT PyObject* PyLong_FromLong(long v);
EXPORT PyObject* PyLong_FromSize_t(size_t v);
EXPORT long long PyLong_AsLongLong(PyObject *o);
EXPORT long PyLong_AsLong(PyObject *o);

EXPORT PyObject* PyFloat_FromDouble(double v);
EXPORT double PyFloat_AsDouble(PyObject *o);

EXPORT PyObject* PyBool_FromLong(long v);

EXPORT PyObject* PyUnicode_FromStringAndSize(const char *s, Py_ssize_t size);
EXPORT PyObject* PyUnicode_FromString(const char *s);
EXPORT const char* PyUnicode_AsUTF8AndSize(PyObject *o, Py_ssize_t *size);
EXPORT const char* PyUnicode_AsUTF8(PyObject *o);

EXPORT PyObject* PyBytes_FromStringAndSize(const char *s, Py_ssize_t size);
EXPORT char* PyBytes_AsString(PyObject *o);
EXPORT Py_ssize_t PyBytes_Size(PyObject *o);

/* Sequence Protocol API */
EXPORT PyObject* PyTuple_New(Py_ssize_t len);
EXPORT Py_ssize_t PyTuple_Size(PyObject *o);
EXPORT PyObject* PyTuple_GetItem(PyObject *o, Py_ssize_t idx);
EXPORT int PyTuple_SetItem(PyObject *o, Py_ssize_t idx, PyObject *item);

EXPORT PyObject* PyList_New(Py_ssize_t len);
EXPORT Py_ssize_t PyList_Size(PyObject *o);
EXPORT PyObject* PyList_GetItem(PyObject *o, Py_ssize_t idx);
EXPORT int PyList_SetItem(PyObject *o, Py_ssize_t idx, PyObject *item);
EXPORT int PyList_Append(PyObject *op, PyObject *newitem);
EXPORT int PyList_GetItemRef(PyObject *op, Py_ssize_t index, PyObject **result);

EXPORT Py_ssize_t PySequence_Size(PyObject *s);
EXPORT PyObject* PySequence_GetItem(PyObject *s, Py_ssize_t i);
EXPORT int PySequence_SetItem(PyObject *s, Py_ssize_t i, PyObject *o);
EXPORT int PySequence_Check(PyObject *s);
EXPORT PyObject* PySequence_Fast(PyObject *o, const char *m);
EXPORT PyObject* PySeqIter_New(PyObject *seq);
EXPORT int PyIndex_Check(PyObject *o);
EXPORT int PyNumber_Check(PyObject *o);
EXPORT Py_ssize_t PyNumber_AsSsize_t(PyObject *item, PyObject *err);
EXPORT Py_ssize_t PyLong_AsSsize_t(PyObject *pylong);

/* Mapping & Subscript Protocol API */
EXPORT PyObject* PyDict_New(void);
EXPORT int PyDict_SetItemString(PyObject *dp, const char *key, PyObject *item);
EXPORT PyObject* PyDict_GetItemString(PyObject *dp, const char *key);
EXPORT Py_ssize_t PyDict_Size(PyObject *dp);
EXPORT int PyDict_GetItemRef(PyObject *p, PyObject *key, PyObject **result);

EXPORT PyObject* PySlice_New(PyObject *start, PyObject *stop, PyObject *step);
EXPORT int PySlice_Unpack(PyObject *r, Py_ssize_t *start, Py_ssize_t *stop, Py_ssize_t *step);
EXPORT Py_ssize_t PySlice_AdjustIndices(Py_ssize_t length, Py_ssize_t *start, Py_ssize_t *stop, Py_ssize_t step);
EXPORT PyObject* PyObject_GetItem(PyObject *o, PyObject *key);
EXPORT int PyObject_SetItem(PyObject *o, PyObject *key, PyObject *v);
EXPORT int PyObject_DelItem(PyObject *o, PyObject *key);
EXPORT int PyMapping_Check(PyObject *o);

/* Number & Comparison Protocol API */
EXPORT PyObject* PyObject_RichCompare(PyObject *v, PyObject *w, int op);
EXPORT int PyObject_RichCompareBool(PyObject *v, PyObject *w, int op);

/* Type & Attribute Protocol API */
EXPORT int PyType_Ready(PyTypeObject *type);
EXPORT PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name);
EXPORT int PyObject_SetAttrString(PyObject *o, const char *attr_name, PyObject *v);
EXPORT int PyObject_HasAttrString(PyObject *o, const char *attr_name);
EXPORT PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs);
EXPORT PyObject* PyObject_CallObject(PyObject *callable, PyObject *args);

/* Stream / BytesIO Protocol API */
EXPORT PyObject* PyStream_New(Py_ssize_t initial_capacity);
EXPORT PyObject* PyStream_FromBytes(const void *data, Py_ssize_t size);
EXPORT Py_ssize_t PyStream_Read(PyObject *stream, void *dest, Py_ssize_t size);
EXPORT Py_ssize_t PyStream_Write(PyObject *stream, const void *src, Py_ssize_t size);
EXPORT Py_ssize_t PyStream_Seek(PyObject *stream, Py_ssize_t offset, int whence);
EXPORT Py_ssize_t PyStream_Tell(PyObject *stream);
EXPORT const uint8_t* PyStream_GetBuffer(PyObject *stream, Py_ssize_t *size);

/* Buffer Protocol API */
EXPORT int PyObject_GetBuffer(PyObject *obj, Py_buffer *view, int flags);
EXPORT void PyBuffer_Release(Py_buffer *view);
EXPORT int PyObject_CheckBuffer(PyObject *obj);
EXPORT int PyBytes_AsStringAndSize(PyObject *obj, char **s, Py_ssize_t *len);
EXPORT int _PyBytes_Resize(PyObject **pv, Py_ssize_t newsize);
EXPORT PyObject* PyUnicode_AsLatin1String(PyObject *unicode);

/* Module & Argument Parsing API */
EXPORT PyObject* PyModule_Create2(PyModuleDef *def, int apiver);
EXPORT PyObject* PyModuleDef_Init(PyModuleDef *def);
EXPORT PyObject* PyModule_GetDict(PyObject *mod);
EXPORT int PyModule_AddObjectRef(PyObject *mod, const char *name, PyObject *value);
EXPORT int PyModule_AddIntConstant(PyObject *mod, const char *name, long value);
EXPORT Py_ssize_t PyObject_Size(PyObject *o);
EXPORT PyObject* Py_BuildValue(const char *format, ...);
EXPORT PyObject* PyObject_CallFunction(PyObject *callable, const char *format, ...);
EXPORT PyObject* PyObject_CallMethod(PyObject *o, const char *name, const char *format, ...);
EXPORT int PyArg_ParseTuple(PyObject *args, const char *fmt, ...);
EXPORT int PyArg_ParseTupleAndKeywords(PyObject *args, PyObject *kwargs, const char *fmt, char **kwlist, ...);

/* Error Handling API */
EXPORT void PyErr_SetString(PyObject *type, const char *message);
EXPORT PyObject* PyErr_Occurred(void);
EXPORT void PyErr_Clear(void);
EXPORT PyObject* PyErr_Format(PyObject *exception, const char *format, ...);
EXPORT PyObject* PyErr_NoMemory(void);
EXPORT PyObject* PyErr_SetFromErrno(PyObject *exc);
EXPORT int PyErr_ExceptionMatches(PyObject *exc);
EXPORT void _PyErr_BadInternalCall(const char *filename, int lineno);

/* Capsule API */
EXPORT PyObject* PyCapsule_New(void *pointer, const char *name, PyCapsule_Destructor destructor);
EXPORT int PyCapsule_IsValid(PyObject *op, const char *name);
EXPORT void* PyCapsule_GetPointer(PyObject *op, const char *name);
EXPORT void* PyCapsule_GetContext(PyObject *op);
EXPORT int PyCapsule_SetContext(PyObject *op, void *context);

/* PEP 3118 Multi-Dimensional Buffer Functions (Phase 33) */
EXPORT int PyBuffer_FillInfo(Py_buffer *view, PyObject *o, void *buf, Py_ssize_t len, int readonly, int flags);
EXPORT int PyBuffer_FillContiguousStrides(int ndims, Py_ssize_t *shape, Py_ssize_t *strides, int itemsize, char fort);
EXPORT int PyBuffer_IsContiguous(const Py_buffer *view, char fort);
EXPORT Py_ssize_t PyBuffer_SizeFromFormat(const char *format);

/* Dual-Ownership GC Synchronization API (Phase 33) */
EXPORT void luthon_gc_register(void *cdata_ptr, PyObject *py_obj, int is_owned);
EXPORT void luthon_gc_unregister(void *cdata_ptr);
EXPORT PyObject* luthon_gc_lookup(void *cdata_ptr);
EXPORT void luthon_gc_dec_ref(PyObject *py_obj);

/* Lifecycle API */
EXPORT int Py_IsInitialized(void);
EXPORT void Py_Initialize(void);
EXPORT void Py_Finalize(void);

#ifdef __cplusplus
}
#endif

#endif /* LUTHON_CAPI_H */
