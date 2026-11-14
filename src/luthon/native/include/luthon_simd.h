#ifndef LUTHON_SIMD_H
#define LUTHON_SIMD_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Typed Vector Register Types (SIMD Chunks) */
typedef struct { double v[4]; } luthon_v4df;
typedef struct { float  v[8]; } luthon_v8sf;
typedef struct { double v[2]; } luthon_v2df;
typedef struct { float  v[4]; } luthon_v4sf;

/* Hardware Capability Diagnostics */
int         luthon_simd_get_vector_width(void);
const char* luthon_simd_get_backend_name(void);
bool        luthon_simd_has_avx2(void);
bool        luthon_simd_has_fma(void);
bool        luthon_simd_has_neon(void);

/* Low-level chunk operations (Double Precision - 4 lanes) */
luthon_v4df luthon_simd_v4df_load(const double *ptr, int64_t offset);
void        luthon_simd_v4df_store(double *ptr, int64_t offset, luthon_v4df val);
luthon_v4df luthon_simd_v4df_broadcast(double scalar);
luthon_v4df luthon_simd_v4df_add(luthon_v4df a, luthon_v4df b);
luthon_v4df luthon_simd_v4df_sub(luthon_v4df a, luthon_v4df b);
luthon_v4df luthon_simd_v4df_mul(luthon_v4df a, luthon_v4df b);
luthon_v4df luthon_simd_v4df_fma(luthon_v4df a, luthon_v4df b, luthon_v4df c);
double      luthon_simd_v4df_reduce_sum(luthon_v4df a);

/* Low-level chunk operations (Single Precision - 8 lanes) */
luthon_v8sf luthon_simd_v8sf_load(const float *ptr, int64_t offset);
void        luthon_simd_v8sf_store(float *ptr, int64_t offset, luthon_v8sf val);
luthon_v8sf luthon_simd_v8sf_broadcast(float scalar);
luthon_v8sf luthon_simd_v8sf_add(luthon_v8sf a, luthon_v8sf b);
luthon_v8sf luthon_simd_v8sf_sub(luthon_v8sf a, luthon_v8sf b);
luthon_v8sf luthon_simd_v8sf_mul(luthon_v8sf a, luthon_v8sf b);
luthon_v8sf luthon_simd_v8sf_fma(luthon_v8sf a, luthon_v8sf b, luthon_v8sf c);
float       luthon_simd_v8sf_reduce_sum(luthon_v8sf a);

/* Block Array Operations */
void   luthon_simd_add_f64(double *out, const double *a, const double *b, size_t n);
void   luthon_simd_add_f32(float *out, const float *a, const float *b, size_t n);
void   luthon_simd_sub_f64(double *out, const double *a, const double *b, size_t n);
void   luthon_simd_sub_f32(float *out, const float *a, const float *b, size_t n);
void   luthon_simd_mul_f64(double *out, const double *a, const double *b, size_t n);
void   luthon_simd_mul_f32(float *out, const float *a, const float *b, size_t n);
void   luthon_simd_fma_f64(double *out, const double *a, const double *b, const double *c, size_t n);
void   luthon_simd_fma_f32(float *out, const float *a, const float *b, const float *c, size_t n);

/* Numerical Kernels (Benchmarked) */
void   luthon_simd_saxpy(size_t n, float alpha, const float *x, float *y);
void   luthon_simd_daxpy(size_t n, double alpha, const double *x, double *y);
double luthon_simd_dot_f64(size_t n, const double *x, const double *y);
float  luthon_simd_dot_f32(size_t n, const float *x, const float *y);
double luthon_simd_euclidean_f64(size_t n, const double *x, const double *y);
float  luthon_simd_euclidean_f32(size_t n, const float *x, const float *y);
void   luthon_simd_poly_eval_f64(size_t n, const double *x, double *out, const double *coeffs, size_t deg);
void   luthon_simd_poly_eval_f32(size_t n, const float *x, float *out, const float *coeffs, size_t deg);

/* Transcendental Approximations (AVX2/FMA Accelerated) */
void   luthon_simd_sin_f64(double *out, const double *x, size_t n);
void   luthon_simd_cos_f64(double *out, const double *x, size_t n);
void   luthon_simd_exp_f64(double *out, const double *x, size_t n);
void   luthon_simd_sqrt_f64(double *out, const double *x, size_t n);

void   luthon_simd_sin_f32(float *out, const float *x, size_t n);
void   luthon_simd_cos_f32(float *out, const float *x, size_t n);
void   luthon_simd_exp_f32(float *out, const float *x, size_t n);
void   luthon_simd_sqrt_f32(float *out, const float *x, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* LUTHON_SIMD_H */
