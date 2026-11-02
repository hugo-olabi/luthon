/*
 * Luthon Native C Standard Library (luthon_stdlib.h)
 * ===================================================
 * High-performance C implementations of Python standard library builtins,
 * collections, memory slices, codecs, and filesystem operations designed
 * to be called with zero Lua garbage-collection overhead via LuaJIT FFI.
 */

#ifndef LUTHON_STDLIB_H
#define LUTHON_STDLIB_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define EXPORT __declspec(dllexport)
#else
  #define EXPORT __attribute__((visibility("default")))
#endif

/* -------------------------------------------------------------------------
 * 1. Fast Range Iterator & Math Primitives
 * ------------------------------------------------------------------------- */

typedef struct {
    int64_t current;
    int64_t stop;
    int64_t step;
    int64_t length;
} LuthonRange;

EXPORT LuthonRange luthon_range_init(int64_t start, int64_t stop, int64_t step);
EXPORT bool        luthon_range_next(LuthonRange *r, int64_t *out_val);
EXPORT int64_t     luthon_range_len(const LuthonRange *r);

/* Fast integer power and divmod */
EXPORT int64_t     luthon_math_ipow(int64_t base, int64_t exp);
EXPORT void        luthon_math_divmod(int64_t a, int64_t b, int64_t *out_div, int64_t *out_mod);

/* -------------------------------------------------------------------------
 * 2. High-Performance Base64 and Hex Codecs
 * ------------------------------------------------------------------------- */

EXPORT size_t luthon_b64_decoded_size(const char *src, size_t src_len);
EXPORT size_t luthon_b64_decode(const char *src, size_t src_len, uint8_t *dst);
EXPORT size_t luthon_b64_encode(const uint8_t *src, size_t src_len, char *dst);

EXPORT size_t luthon_hex_decode(const char *src, size_t src_len, uint8_t *dst);
EXPORT size_t luthon_hex_encode(const uint8_t *src, size_t src_len, char *dst);

/* -------------------------------------------------------------------------
 * 3. Fast File System & Path Manipulation
 * ------------------------------------------------------------------------- */

/* Normalizes path in-place or into dst buffer, resolving relative separators */
EXPORT size_t luthon_path_join(const char *p1, const char *p2, char *dst, size_t max_len);
EXPORT const char* luthon_path_basename(const char *path);
EXPORT size_t luthon_path_dirname(const char *path, char *dst, size_t max_len);
EXPORT bool   luthon_path_exists(const char *path);
EXPORT bool   luthon_path_isdir(const char *path);
EXPORT size_t luthon_path_getsize(const char *path);

/* -------------------------------------------------------------------------
 * 4. Fast Slices and Memory Searches
 * ------------------------------------------------------------------------- */

typedef struct {
    int64_t start;
    int64_t stop;
    int64_t step;
    int64_t length;
} LuthonSlice;

EXPORT LuthonSlice luthon_slice_calc(int64_t length, int64_t start, int64_t stop, int64_t step, bool has_start, bool has_stop, bool has_step);

/* Branchless string and memory comparison */
EXPORT int luthon_fast_memcmp(const void *s1, size_t n1, const void *s2, size_t n2);
EXPORT int64_t luthon_memfind(const void *haystack, size_t h_len, const void *needle, size_t n_len);

#ifdef __cplusplus
}
#endif

#endif /* LUTHON_STDLIB_H */
