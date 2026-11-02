/*
 * Luthon Native C Builtins (builtins.c)
 * =====================================
 * High-performance C implementations of core Python builtins:
 * range iterators, integer math, slice calculations, and memory comparisons.
 */

#include "luthon_stdlib.h"

LuthonRange luthon_range_init(int64_t start, int64_t stop, int64_t step) {
    LuthonRange r;
    r.current = start;
    r.stop = stop;
    r.step = (step == 0) ? 1 : step;

    if (r.step > 0 && start < stop) {
        r.length = 1 + (stop - 1 - start) / r.step;
    } else if (r.step < 0 && start > stop) {
        r.length = 1 + (start - 1 - stop) / (-r.step);
    } else {
        r.length = 0;
    }
    return r;
}

bool luthon_range_next(LuthonRange *r, int64_t *out_val) {
    if (!r || r->length <= 0) {
        return false;
    }
    if (out_val) {
        *out_val = r->current;
    }
    r->current += r->step;
    r->length--;
    return true;
}

int64_t luthon_range_len(const LuthonRange *r) {
    return r ? r->length : 0;
}

int64_t luthon_math_ipow(int64_t base, int64_t exp) {
    if (exp < 0) return 0;
    int64_t result = 1;
    while (exp > 0) {
        if (exp & 1) result *= base;
        base *= base;
        exp >>= 1;
    }
    return result;
}

void luthon_math_divmod(int64_t a, int64_t b, int64_t *out_div, int64_t *out_mod) {
    if (b == 0) {
        if (out_div) *out_div = 0;
        if (out_mod) *out_mod = 0;
        return;
    }
    int64_t q = a / b;
    int64_t r = a % b;
    /* Python floor division semantics */
    if ((r != 0) && ((r < 0) != (b < 0))) {
        q -= 1;
        r += b;
    }
    if (out_div) *out_div = q;
    if (out_mod) *out_mod = r;
}

LuthonSlice luthon_slice_calc(int64_t length, int64_t start, int64_t stop, int64_t step,
                              bool has_start, bool has_stop, bool has_step) {
    LuthonSlice s;
    s.step = has_step ? step : 1;
    if (s.step == 0) s.step = 1;

    if (s.step > 0) {
        s.start = has_start ? start : 0;
        s.stop = has_stop ? stop : length;

        if (s.start < 0) {
            s.start += length;
            if (s.start < 0) s.start = 0;
        } else if (s.start > length) {
            s.start = length;
        }

        if (s.stop < 0) {
            s.stop += length;
            if (s.stop < 0) s.stop = 0;
        } else if (s.stop > length) {
            s.stop = length;
        }

        if (s.start < s.stop) {
            s.length = 1 + (s.stop - 1 - s.start) / s.step;
        } else {
            s.length = 0;
        }
    } else {
        s.start = has_start ? start : length - 1;
        s.stop = has_stop ? stop : -1;

        if (s.start < 0) {
            s.start += length;
            if (s.start < -1) s.start = -1;
        } else if (s.start >= length) {
            s.start = length - 1;
        }

        if (s.stop < 0) {
            s.stop += length;
            if (s.stop < -1) s.stop = -1;
        } else if (s.stop >= length) {
            s.stop = length - 1;
        }

        if (s.start > s.stop) {
            s.length = 1 + (s.start - 1 - s.stop) / (-s.step);
        } else {
            s.length = 0;
        }
    }

    return s;
}

int luthon_fast_memcmp(const void *s1, size_t n1, const void *s2, size_t n2) {
    if (s1 == s2 && n1 == n2) return 0;
    size_t min_n = (n1 < n2) ? n1 : n2;
    if (min_n > 0) {
        int cmp = memcmp(s1, s2, min_n);
        if (cmp != 0) return cmp;
    }
    return (n1 < n2) ? -1 : ((n1 > n2) ? 1 : 0);
}

int64_t luthon_memfind(const void *haystack, size_t h_len, const void *needle, size_t n_len) {
    if (n_len == 0) return 0;
    if (h_len < n_len || !haystack || !needle) return -1;

    const uint8_t *h = (const uint8_t *)haystack;
    const uint8_t *n = (const uint8_t *)needle;
    uint8_t first = n[0];

    const uint8_t *end = h + (h_len - n_len + 1);
    while (h < end) {
        const uint8_t *p = (const uint8_t *)memchr(h, first, end - h);
        if (!p) return -1;
        if (n_len == 1 || memcmp(p, n, n_len) == 0) {
            return (int64_t)(p - (const uint8_t *)haystack);
        }
        h = p + 1;
    }
    return -1;
}
