#include "luthon_simd.h"
#include <math.h>
#include <string.h>

#if defined(__x86_64__) || defined(_M_X64)
  #if defined(__AVX2__) && defined(__FMA__)
    #include <immintrin.h>
    #define LUTHON_USE_AVX2 1
  #endif
#elif defined(__aarch64__) || defined(__ARM_NEON)
  #include <arm_neon.h>
  #define LUTHON_USE_NEON 1
#endif

int luthon_simd_get_vector_width(void) {
#if defined(LUTHON_USE_AVX2)
    return 4; /* 4 doubles (256-bit) or 8 floats */
#elif defined(LUTHON_USE_NEON)
    return 2; /* 2 doubles (128-bit) or 4 floats */
#else
    return 2; /* Fallback 128-bit emulation */
#endif
}

const char* luthon_simd_get_backend_name(void) {
#if defined(LUTHON_USE_AVX2)
    return "AVX2+FMA (256-bit)";
#elif defined(LUTHON_USE_NEON)
    return "ARM NEON (128-bit)";
#else
    return "Scalar / Portable Fallback";
#endif
}

bool luthon_simd_has_avx2(void) {
#if defined(LUTHON_USE_AVX2)
    return true;
#else
    return false;
#endif
}

bool luthon_simd_has_fma(void) {
#if defined(__FMA__)
    return true;
#else
    return false;
#endif
}

bool luthon_simd_has_neon(void) {
#if defined(LUTHON_USE_NEON)
    return true;
#else
    return false;
#endif
}

/* =========================================================================
 * 1. Low-Level Chunk Operations (v4df: 4 doubles)
 * ========================================================================= */

luthon_v4df luthon_simd_v4df_load(const double *ptr, int64_t offset) {
    luthon_v4df r;
    const double *src = ptr + offset;
#if defined(LUTHON_USE_AVX2)
    __m256d m = _mm256_loadu_pd(src);
    _mm256_storeu_pd(r.v, m);
#else
    r.v[0] = src[0];
    r.v[1] = src[1];
    r.v[2] = src[2];
    r.v[3] = src[3];
#endif
    return r;
}

void luthon_simd_v4df_store(double *ptr, int64_t offset, luthon_v4df val) {
    double *dst = ptr + offset;
#if defined(LUTHON_USE_AVX2)
    __m256d m = _mm256_loadu_pd(val.v);
    _mm256_storeu_pd(dst, m);
#else
    dst[0] = val.v[0];
    dst[1] = val.v[1];
    dst[2] = val.v[2];
    dst[3] = val.v[3];
#endif
}

luthon_v4df luthon_simd_v4df_broadcast(double scalar) {
    luthon_v4df r;
#if defined(LUTHON_USE_AVX2)
    __m256d m = _mm256_set1_pd(scalar);
    _mm256_storeu_pd(r.v, m);
#else
    r.v[0] = scalar;
    r.v[1] = scalar;
    r.v[2] = scalar;
    r.v[3] = scalar;
#endif
    return r;
}

luthon_v4df luthon_simd_v4df_add(luthon_v4df a, luthon_v4df b) {
    luthon_v4df r;
#if defined(LUTHON_USE_AVX2)
    __m256d ma = _mm256_loadu_pd(a.v);
    __m256d mb = _mm256_loadu_pd(b.v);
    __m256d mr = _mm256_add_pd(ma, mb);
    _mm256_storeu_pd(r.v, mr);
#else
    r.v[0] = a.v[0] + b.v[0];
    r.v[1] = a.v[1] + b.v[1];
    r.v[2] = a.v[2] + b.v[2];
    r.v[3] = a.v[3] + b.v[3];
#endif
    return r;
}

luthon_v4df luthon_simd_v4df_sub(luthon_v4df a, luthon_v4df b) {
    luthon_v4df r;
#if defined(LUTHON_USE_AVX2)
    __m256d ma = _mm256_loadu_pd(a.v);
    __m256d mb = _mm256_loadu_pd(b.v);
    __m256d mr = _mm256_sub_pd(ma, mb);
    _mm256_storeu_pd(r.v, mr);
#else
    r.v[0] = a.v[0] - b.v[0];
    r.v[1] = a.v[1] - b.v[1];
    r.v[2] = a.v[2] - b.v[2];
    r.v[3] = a.v[3] - b.v[3];
#endif
    return r;
}

luthon_v4df luthon_simd_v4df_mul(luthon_v4df a, luthon_v4df b) {
    luthon_v4df r;
#if defined(LUTHON_USE_AVX2)
    __m256d ma = _mm256_loadu_pd(a.v);
    __m256d mb = _mm256_loadu_pd(b.v);
    __m256d mr = _mm256_mul_pd(ma, mb);
    _mm256_storeu_pd(r.v, mr);
#else
    r.v[0] = a.v[0] * b.v[0];
    r.v[1] = a.v[1] * b.v[1];
    r.v[2] = a.v[2] * b.v[2];
    r.v[3] = a.v[3] * b.v[3];
#endif
    return r;
}

luthon_v4df luthon_simd_v4df_fma(luthon_v4df a, luthon_v4df b, luthon_v4df c) {
    luthon_v4df r;
#if defined(LUTHON_USE_AVX2)
    __m256d ma = _mm256_loadu_pd(a.v);
    __m256d mb = _mm256_loadu_pd(b.v);
    __m256d mc = _mm256_loadu_pd(c.v);
    __m256d mr = _mm256_fmadd_pd(ma, mb, mc);
    _mm256_storeu_pd(r.v, mr);
#else
    r.v[0] = fma(a.v[0], b.v[0], c.v[0]);
    r.v[1] = fma(a.v[1], b.v[1], c.v[1]);
    r.v[2] = fma(a.v[2], b.v[2], c.v[2]);
    r.v[3] = fma(a.v[3], b.v[3], c.v[3]);
#endif
    return r;
}

double luthon_simd_v4df_reduce_sum(luthon_v4df a) {
#if defined(LUTHON_USE_AVX2)
    __m256d ma = _mm256_loadu_pd(a.v);
    __m128d hi = _mm256_extractf128_pd(ma, 1);
    __m128d lo = _mm256_castpd256_pd128(ma);
    __m128d sum2 = _mm_add_pd(lo, hi);
    __m128d shuf = _mm_shuffle_pd(sum2, sum2, 1);
    __m128d sum1 = _mm_add_sd(sum2, shuf);
    return _mm_cvtsd_f64(sum1);
#else
    return a.v[0] + a.v[1] + a.v[2] + a.v[3];
#endif
}

/* =========================================================================
 * 2. Low-Level Chunk Operations (v8sf: 8 floats)
 * ========================================================================= */

luthon_v8sf luthon_simd_v8sf_load(const float *ptr, int64_t offset) {
    luthon_v8sf r;
    const float *src = ptr + offset;
#if defined(LUTHON_USE_AVX2)
    __m256 m = _mm256_loadu_ps(src);
    _mm256_storeu_ps(r.v, m);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = src[i];
#endif
    return r;
}

void luthon_simd_v8sf_store(float *ptr, int64_t offset, luthon_v8sf val) {
    float *dst = ptr + offset;
#if defined(LUTHON_USE_AVX2)
    __m256 m = _mm256_loadu_ps(val.v);
    _mm256_storeu_ps(dst, m);
#else
    for (int i = 0; i < 8; ++i) dst[i] = val.v[i];
#endif
}

luthon_v8sf luthon_simd_v8sf_broadcast(float scalar) {
    luthon_v8sf r;
#if defined(LUTHON_USE_AVX2)
    __m256 m = _mm256_set1_ps(scalar);
    _mm256_storeu_ps(r.v, m);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = scalar;
#endif
    return r;
}

luthon_v8sf luthon_simd_v8sf_add(luthon_v8sf a, luthon_v8sf b) {
    luthon_v8sf r;
#if defined(LUTHON_USE_AVX2)
    __m256 ma = _mm256_loadu_ps(a.v);
    __m256 mb = _mm256_loadu_ps(b.v);
    __m256 mr = _mm256_add_ps(ma, mb);
    _mm256_storeu_ps(r.v, mr);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = a.v[i] + b.v[i];
#endif
    return r;
}

luthon_v8sf luthon_simd_v8sf_sub(luthon_v8sf a, luthon_v8sf b) {
    luthon_v8sf r;
#if defined(LUTHON_USE_AVX2)
    __m256 ma = _mm256_loadu_ps(a.v);
    __m256 mb = _mm256_loadu_ps(b.v);
    __m256 mr = _mm256_sub_ps(ma, mb);
    _mm256_storeu_ps(r.v, mr);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = a.v[i] - b.v[i];
#endif
    return r;
}

luthon_v8sf luthon_simd_v8sf_mul(luthon_v8sf a, luthon_v8sf b) {
    luthon_v8sf r;
#if defined(LUTHON_USE_AVX2)
    __m256 ma = _mm256_loadu_ps(a.v);
    __m256 mb = _mm256_loadu_ps(b.v);
    __m256 mr = _mm256_mul_ps(ma, mb);
    _mm256_storeu_ps(r.v, mr);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = a.v[i] * b.v[i];
#endif
    return r;
}

luthon_v8sf luthon_simd_v8sf_fma(luthon_v8sf a, luthon_v8sf b, luthon_v8sf c) {
    luthon_v8sf r;
#if defined(LUTHON_USE_AVX2)
    __m256 ma = _mm256_loadu_ps(a.v);
    __m256 mb = _mm256_loadu_ps(b.v);
    __m256 mc = _mm256_loadu_ps(c.v);
    __m256 mr = _mm256_fmadd_ps(ma, mb, mc);
    _mm256_storeu_ps(r.v, mr);
#else
    for (int i = 0; i < 8; ++i) r.v[i] = fmaf(a.v[i], b.v[i], c.v[i]);
#endif
    return r;
}

float luthon_simd_v8sf_reduce_sum(luthon_v8sf a) {
#if defined(LUTHON_USE_AVX2)
    __m256 ma = _mm256_loadu_ps(a.v);
    __m128 hi = _mm256_extractf128_ps(ma, 1);
    __m128 lo = _mm256_castps256_ps128(ma);
    __m128 sum4 = _mm_add_ps(lo, hi);
    __m128 shuf = _mm_movehl_ps(sum4, sum4);
    __m128 sum2 = _mm_add_ps(sum4, shuf);
    shuf = _mm_shuffle_ps(sum2, sum2, 1);
    __m128 sum1 = _mm_add_ss(sum2, shuf);
    return _mm_cvtss_f32(sum1);
#else
    float s = 0.0f;
    for (int i = 0; i < 8; ++i) s += a.v[i];
    return s;
#endif
}

/* =========================================================================
 * 3. High-Performance Block Array Operations
 * ========================================================================= */

void luthon_simd_add_f64(double *out, const double *a, const double *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d va = _mm256_loadu_pd(a + i);
        __m256d vb = _mm256_loadu_pd(b + i);
        _mm256_storeu_pd(out + i, _mm256_add_pd(va, vb));
    }
#elif defined(LUTHON_USE_NEON)
    for (; i + 2 <= n; i += 2) {
        float64x2_t va = vld1q_f64(a + i);
        float64x2_t vb = vld1q_f64(b + i);
        vst1q_f64(out + i, vaddq_f64(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] + b[i];
    }
}

void luthon_simd_add_f32(float *out, const float *a, const float *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_add_ps(va, vb));
    }
#elif defined(LUTHON_USE_NEON)
    for (; i + 4 <= n; i += 4) {
        float32x4_t va = vld1q_f32(a + i);
        float32x4_t vb = vld1q_f32(b + i);
        vst1q_f32(out + i, vaddq_f32(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] + b[i];
    }
}

void luthon_simd_sub_f64(double *out, const double *a, const double *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d va = _mm256_loadu_pd(a + i);
        __m256d vb = _mm256_loadu_pd(b + i);
        _mm256_storeu_pd(out + i, _mm256_sub_pd(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] - b[i];
    }
}

void luthon_simd_sub_f32(float *out, const float *a, const float *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_sub_ps(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] - b[i];
    }
}

void luthon_simd_mul_f64(double *out, const double *a, const double *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d va = _mm256_loadu_pd(a + i);
        __m256d vb = _mm256_loadu_pd(b + i);
        _mm256_storeu_pd(out + i, _mm256_mul_pd(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] * b[i];
    }
}

void luthon_simd_mul_f32(float *out, const float *a, const float *b, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_mul_ps(va, vb));
    }
#endif
    for (; i < n; ++i) {
        out[i] = a[i] * b[i];
    }
}

void luthon_simd_fma_f64(double *out, const double *a, const double *b, const double *c, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d va = _mm256_loadu_pd(a + i);
        __m256d vb = _mm256_loadu_pd(b + i);
        __m256d vc = _mm256_loadu_pd(c + i);
        _mm256_storeu_pd(out + i, _mm256_fmadd_pd(va, vb, vc));
    }
#endif
    for (; i < n; ++i) {
        out[i] = fma(a[i], b[i], c[i]);
    }
}

void luthon_simd_fma_f32(float *out, const float *a, const float *b, const float *c, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        __m256 vc = _mm256_loadu_ps(c + i);
        _mm256_storeu_ps(out + i, _mm256_fmadd_ps(va, vb, vc));
    }
#endif
    for (; i < n; ++i) {
        out[i] = fmaf(a[i], b[i], c[i]);
    }
}

/* =========================================================================
 * 4. Benchmarked Numerical Kernels (SAXPY/DAXPY, Dot Product, Distance, Poly)
 * ========================================================================= */

void luthon_simd_saxpy(size_t n, float alpha, const float *x, float *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256 valpha = _mm256_set1_ps(alpha);
    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vy = _mm256_loadu_ps(y + i);
        _mm256_storeu_ps(y + i, _mm256_fmadd_ps(valpha, vx, vy));
    }
#elif defined(LUTHON_USE_NEON)
    float32x4_t valpha = vdupq_n_f32(alpha);
    for (; i + 4 <= n; i += 4) {
        float32x4_t vx = vld1q_f32(x + i);
        float32x4_t vy = vld1q_f32(y + i);
        vst1q_f32(y + i, vmlaq_f32(vy, valpha, vx));
    }
#endif
    for (; i < n; ++i) {
        y[i] = alpha * x[i] + y[i];
    }
}

void luthon_simd_daxpy(size_t n, double alpha, const double *x, double *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256d valpha = _mm256_set1_pd(alpha);
    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vy = _mm256_loadu_pd(y + i);
        _mm256_storeu_pd(y + i, _mm256_fmadd_pd(valpha, vx, vy));
    }
#endif
    for (; i < n; ++i) {
        y[i] = alpha * x[i] + y[i];
    }
}

double luthon_simd_dot_f64(size_t n, const double *x, const double *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256d acc = _mm256_setzero_pd();
    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vy = _mm256_loadu_pd(y + i);
        acc = _mm256_fmadd_pd(vx, vy, acc);
    }
    __m128d hi = _mm256_extractf128_pd(acc, 1);
    __m128d lo = _mm256_castpd256_pd128(acc);
    __m128d sum2 = _mm_add_pd(lo, hi);
    __m128d shuf = _mm_shuffle_pd(sum2, sum2, 1);
    __m128d sum1 = _mm_add_sd(sum2, shuf);
    double total = _mm_cvtsd_f64(sum1);
#else
    double total = 0.0;
#endif
    for (; i < n; ++i) {
        total += x[i] * y[i];
    }
    return total;
}

float luthon_simd_dot_f32(size_t n, const float *x, const float *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256 acc = _mm256_setzero_ps();
    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vy = _mm256_loadu_ps(y + i);
        acc = _mm256_fmadd_ps(vx, vy, acc);
    }
    __m128 hi = _mm256_extractf128_ps(acc, 1);
    __m128 lo = _mm256_castps256_ps128(acc);
    __m128 sum4 = _mm_add_ps(lo, hi);
    __m128 shuf = _mm_movehl_ps(sum4, sum4);
    __m128 sum2 = _mm_add_ps(sum4, shuf);
    shuf = _mm_shuffle_ps(sum2, sum2, 1);
    __m128 sum1 = _mm_add_ss(sum2, shuf);
    float total = _mm_cvtss_f32(sum1);
#else
    float total = 0.0f;
#endif
    for (; i < n; ++i) {
        total += x[i] * y[i];
    }
    return total;
}

double luthon_simd_euclidean_f64(size_t n, const double *x, const double *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256d acc = _mm256_setzero_pd();
    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vy = _mm256_loadu_pd(y + i);
        __m256d diff = _mm256_sub_pd(vx, vy);
        acc = _mm256_fmadd_pd(diff, diff, acc);
    }
    __m128d hi = _mm256_extractf128_pd(acc, 1);
    __m128d lo = _mm256_castpd256_pd128(acc);
    __m128d sum2 = _mm_add_pd(lo, hi);
    __m128d shuf = _mm_shuffle_pd(sum2, sum2, 1);
    __m128d sum1 = _mm_add_sd(sum2, shuf);
    double total = _mm_cvtsd_f64(sum1);
#else
    double total = 0.0;
#endif
    for (; i < n; ++i) {
        double d = x[i] - y[i];
        total += d * d;
    }
    return sqrt(total);
}

float luthon_simd_euclidean_f32(size_t n, const float *x, const float *y) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    __m256 acc = _mm256_setzero_ps();
    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vy = _mm256_loadu_ps(y + i);
        __m256 diff = _mm256_sub_ps(vx, vy);
        acc = _mm256_fmadd_ps(diff, diff, acc);
    }
    __m128 hi = _mm256_extractf128_ps(acc, 1);
    __m128 lo = _mm256_castps256_ps128(acc);
    __m128 sum4 = _mm_add_ps(lo, hi);
    __m128 shuf = _mm_movehl_ps(sum4, sum4);
    __m128 sum2 = _mm_add_ps(sum4, shuf);
    shuf = _mm_shuffle_ps(sum2, sum2, 1);
    __m128 sum1 = _mm_add_ss(sum2, shuf);
    float total = _mm_cvtss_f32(sum1);
#else
    float total = 0.0f;
#endif
    for (; i < n; ++i) {
        float d = x[i] - y[i];
        total += d * d;
    }
    return sqrtf(total);
}

void luthon_simd_poly_eval_f64(size_t n, const double *x, double *out, const double *coeffs, size_t deg) {
    /* Horner's method: P(x) = (...((c[deg]*x + c[deg-1])*x + ...)*x + c[0] */
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d res = _mm256_set1_pd(coeffs[deg]);
        for (int64_t k = (int64_t)deg - 1; k >= 0; --k) {
            __m256d vc = _mm256_set1_pd(coeffs[k]);
            res = _mm256_fmadd_pd(res, vx, vc);
        }
        _mm256_storeu_pd(out + i, res);
    }
#endif
    for (; i < n; ++i) {
        double xi = x[i];
        double p = coeffs[deg];
        for (int64_t k = (int64_t)deg - 1; k >= 0; --k) {
            p = p * xi + coeffs[k];
        }
        out[i] = p;
    }
}

void luthon_simd_poly_eval_f32(size_t n, const float *x, float *out, const float *coeffs, size_t deg) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 res = _mm256_set1_ps(coeffs[deg]);
        for (int64_t k = (int64_t)deg - 1; k >= 0; --k) {
            __m256 vc = _mm256_set1_ps(coeffs[k]);
            res = _mm256_fmadd_ps(res, vx, vc);
        }
        _mm256_storeu_ps(out + i, res);
    }
#endif
    for (; i < n; ++i) {
        float xi = x[i];
        float p = coeffs[deg];
        for (int64_t k = (int64_t)deg - 1; k >= 0; --k) {
            p = p * xi + coeffs[k];
        }
        out[i] = p;
    }
}

/* =========================================================================
 * 5. Vectorized Transcendental Approximations (sqrt, exp, sin, cos)
 * ========================================================================= */

void luthon_simd_sqrt_f64(double *out, const double *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        _mm256_storeu_pd(out + i, _mm256_sqrt_pd(vx));
    }
#endif
    for (; i < n; ++i) {
        out[i] = sqrt(x[i]);
    }
}

void luthon_simd_sqrt_f32(float *out, const float *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        _mm256_storeu_ps(out + i, _mm256_sqrt_ps(vx));
    }
#endif
    for (; i < n; ++i) {
        out[i] = sqrtf(x[i]);
    }
}

/* Vectorized exp(x) via range reduction and minimax polynomial */
void luthon_simd_exp_f64(double *out, const double *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    /* exp(x) = 2^k * exp(r) where k = round(x / ln2), r = x - k * ln2 */
    const double inv_ln2 = 1.4426950408889634073599;
    const double ln2_hi  = 0.6931471803691238;
    const double ln2_lo  = 1.9082149292705877e-10;
    __m256d vinv_ln2 = _mm256_set1_pd(inv_ln2);
    __m256d vln2_hi  = _mm256_set1_pd(ln2_hi);
    __m256d vln2_lo  = _mm256_set1_pd(ln2_lo);

    /* Coefficients for exp(r) ~ 1 + r + r^2/2 + ... + r^8/40320 */
    __m256d c8 = _mm256_set1_pd(1.0 / 40320.0);
    __m256d c7 = _mm256_set1_pd(1.0 / 5040.0);
    __m256d c6 = _mm256_set1_pd(1.0 / 720.0);
    __m256d c5 = _mm256_set1_pd(1.0 / 120.0);
    __m256d c4 = _mm256_set1_pd(1.0 / 24.0);
    __m256d c3 = _mm256_set1_pd(1.0 / 6.0);
    __m256d c2 = _mm256_set1_pd(0.5);
    __m256d c1 = _mm256_set1_pd(1.0);
    __m256d c0 = _mm256_set1_pd(1.0);

    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vk = _mm256_round_pd(_mm256_mul_pd(vx, vinv_ln2), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256d vr = _mm256_sub_pd(vx, _mm256_mul_pd(vk, vln2_hi));
        vr = _mm256_sub_pd(vr, _mm256_mul_pd(vk, vln2_lo));

        /* Horner polynomial evaluation for exp(r) */
        __m256d p = _mm256_fmadd_pd(c8, vr, c7);
        p = _mm256_fmadd_pd(p, vr, c6);
        p = _mm256_fmadd_pd(p, vr, c5);
        p = _mm256_fmadd_pd(p, vr, c4);
        p = _mm256_fmadd_pd(p, vr, c3);
        p = _mm256_fmadd_pd(p, vr, c2);
        p = _mm256_fmadd_pd(p, vr, c1);
        p = _mm256_fmadd_pd(p, vr, c0);

        /* Scale by 2^k */
        luthon_v4df kp, res;
        _mm256_storeu_pd(kp.v, vk);
        _mm256_storeu_pd(res.v, p);
        for (int l = 0; l < 4; ++l) {
            res.v[l] = ldexp(res.v[l], (int)kp.v[l]);
        }
        _mm256_storeu_pd(out + i, _mm256_loadu_pd(res.v));
    }
#endif
    for (; i < n; ++i) {
        out[i] = exp(x[i]);
    }
}

void luthon_simd_exp_f32(float *out, const float *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    const float inv_ln2 = 1.4426950408889634f;
    const float ln2_hi  = 0.69314718f;
    __m256 vinv_ln2 = _mm256_set1_ps(inv_ln2);
    __m256 vln2_hi  = _mm256_set1_ps(ln2_hi);
    __m256 c4 = _mm256_set1_ps(1.0f / 24.0f);
    __m256 c3 = _mm256_set1_ps(1.0f / 6.0f);
    __m256 c2 = _mm256_set1_ps(0.5f);
    __m256 c1 = _mm256_set1_ps(1.0f);
    __m256 c0 = _mm256_set1_ps(1.0f);

    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vk = _mm256_round_ps(_mm256_mul_ps(vx, vinv_ln2), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256 vr = _mm256_sub_ps(vx, _mm256_mul_ps(vk, vln2_hi));
        __m256 p = _mm256_fmadd_ps(c4, vr, c3);
        p = _mm256_fmadd_ps(p, vr, c2);
        p = _mm256_fmadd_ps(p, vr, c1);
        p = _mm256_fmadd_ps(p, vr, c0);

        luthon_v8sf kp, res;
        _mm256_storeu_ps(kp.v, vk);
        _mm256_storeu_ps(res.v, p);
        for (int l = 0; l < 8; ++l) {
            res.v[l] = ldexpf(res.v[l], (int)kp.v[l]);
        }
        _mm256_storeu_ps(out + i, _mm256_loadu_ps(res.v));
    }
#endif
    for (; i < n; ++i) {
        out[i] = expf(x[i]);
    }
}

/* Vectorized sin(x) via Taylor-Maclaurin expansion */
void luthon_simd_sin_f64(double *out, const double *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    /* Range reduction x_red = x - 2*pi * round(x / (2*pi)) */
    const double two_pi = 6.28318530717958647692;
    const double inv_two_pi = 0.15915494309189533576;
    __m256d vtwo_pi = _mm256_set1_pd(two_pi);
    __m256d vinv_two_pi = _mm256_set1_pd(inv_two_pi);

    /* sin(x) ~ x - x^3/6 + x^5/120 - x^7/5040 + x^9/362880 - x^11/39916800 + x^13/6227020800 */
    __m256d c13 = _mm256_set1_pd( 1.0 / 6227020800.0);
    __m256d c11 = _mm256_set1_pd(-1.0 / 39916800.0);
    __m256d c9  = _mm256_set1_pd( 1.0 / 362880.0);
    __m256d c7  = _mm256_set1_pd(-1.0 / 5040.0);
    __m256d c5  = _mm256_set1_pd( 1.0 / 120.0);
    __m256d c3  = _mm256_set1_pd(-1.0 / 6.0);
    __m256d c1  = _mm256_set1_pd( 1.0);

    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vk = _mm256_round_pd(_mm256_mul_pd(vx, vinv_two_pi), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256d vr = _mm256_sub_pd(vx, _mm256_mul_pd(vk, vtwo_pi));
        __m256d vr2 = _mm256_mul_pd(vr, vr);

        __m256d p = _mm256_fmadd_pd(c13, vr2, c11);
        p = _mm256_fmadd_pd(p, vr2, c9);
        p = _mm256_fmadd_pd(p, vr2, c7);
        p = _mm256_fmadd_pd(p, vr2, c5);
        p = _mm256_fmadd_pd(p, vr2, c3);
        p = _mm256_fmadd_pd(p, vr2, c1);
        __m256d res = _mm256_mul_pd(p, vr);
        _mm256_storeu_pd(out + i, res);
    }
#endif
    for (; i < n; ++i) {
        out[i] = sin(x[i]);
    }
}

void luthon_simd_sin_f32(float *out, const float *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    const float two_pi = 6.283185307f;
    const float inv_two_pi = 0.159154943f;
    __m256 vtwo_pi = _mm256_set1_ps(two_pi);
    __m256 vinv_two_pi = _mm256_set1_ps(inv_two_pi);
    __m256 c7 = _mm256_set1_ps(-1.0f / 5040.0f);
    __m256 c5 = _mm256_set1_ps( 1.0f / 120.0f);
    __m256 c3 = _mm256_set1_ps(-1.0f / 6.0f);
    __m256 c1 = _mm256_set1_ps( 1.0f);

    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vk = _mm256_round_ps(_mm256_mul_ps(vx, vinv_two_pi), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256 vr = _mm256_sub_ps(vx, _mm256_mul_ps(vk, vtwo_pi));
        __m256 vr2 = _mm256_mul_ps(vr, vr);
        __m256 p = _mm256_fmadd_ps(c7, vr2, c5);
        p = _mm256_fmadd_ps(p, vr2, c3);
        p = _mm256_fmadd_ps(p, vr2, c1);
        __m256 res = _mm256_mul_ps(p, vr);
        _mm256_storeu_ps(out + i, res);
    }
#endif
    for (; i < n; ++i) {
        out[i] = sinf(x[i]);
    }
}

/* Vectorized cos(x) via Taylor-Maclaurin expansion */
void luthon_simd_cos_f64(double *out, const double *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    const double two_pi = 6.28318530717958647692;
    const double inv_two_pi = 0.15915494309189533576;
    __m256d vtwo_pi = _mm256_set1_pd(two_pi);
    __m256d vinv_two_pi = _mm256_set1_pd(inv_two_pi);

    /* cos(x) ~ 1 - x^2/2 + x^4/24 - x^6/720 + x^8/40320 - x^10/3628800 + x^12/479001600 */
    __m256d c12 = _mm256_set1_pd( 1.0 / 479001600.0);
    __m256d c10 = _mm256_set1_pd(-1.0 / 3628800.0);
    __m256d c8  = _mm256_set1_pd( 1.0 / 40320.0);
    __m256d c6  = _mm256_set1_pd(-1.0 / 720.0);
    __m256d c4  = _mm256_set1_pd( 1.0 / 24.0);
    __m256d c2  = _mm256_set1_pd(-0.5);
    __m256d c0  = _mm256_set1_pd( 1.0);

    for (; i + 4 <= n; i += 4) {
        __m256d vx = _mm256_loadu_pd(x + i);
        __m256d vk = _mm256_round_pd(_mm256_mul_pd(vx, vinv_two_pi), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256d vr = _mm256_sub_pd(vx, _mm256_mul_pd(vk, vtwo_pi));
        __m256d vr2 = _mm256_mul_pd(vr, vr);

        __m256d p = _mm256_fmadd_pd(c12, vr2, c10);
        p = _mm256_fmadd_pd(p, vr2, c8);
        p = _mm256_fmadd_pd(p, vr2, c6);
        p = _mm256_fmadd_pd(p, vr2, c4);
        p = _mm256_fmadd_pd(p, vr2, c2);
        p = _mm256_fmadd_pd(p, vr2, c0);
        _mm256_storeu_pd(out + i, p);
    }
#endif
    for (; i < n; ++i) {
        out[i] = cos(x[i]);
    }
}

void luthon_simd_cos_f32(float *out, const float *x, size_t n) {
    size_t i = 0;
#if defined(LUTHON_USE_AVX2)
    const float two_pi = 6.283185307f;
    const float inv_two_pi = 0.159154943f;
    __m256 vtwo_pi = _mm256_set1_ps(two_pi);
    __m256 vinv_two_pi = _mm256_set1_ps(inv_two_pi);
    __m256 c6 = _mm256_set1_ps(-1.0f / 720.0f);
    __m256 c4 = _mm256_set1_ps( 1.0f / 24.0f);
    __m256 c2 = _mm256_set1_ps(-0.5f);
    __m256 c0 = _mm256_set1_ps( 1.0f);

    for (; i + 8 <= n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vk = _mm256_round_ps(_mm256_mul_ps(vx, vinv_two_pi), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
        __m256 vr = _mm256_sub_ps(vx, _mm256_mul_ps(vk, vtwo_pi));
        __m256 vr2 = _mm256_mul_ps(vr, vr);
        __m256 p = _mm256_fmadd_ps(c6, vr2, c4);
        p = _mm256_fmadd_ps(p, vr2, c2);
        p = _mm256_fmadd_ps(p, vr2, c0);
        _mm256_storeu_ps(out + i, p);
    }
#endif
    for (; i < n; ++i) {
        out[i] = cosf(x[i]);
    }
}
