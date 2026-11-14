/*
 * Luthon WebAssembly & WASI Preview 1 Platform Abstraction Layer (Phase 41)
 *
 * Provides POSIX syscall emulation and platform runtime shims compatible
 * with WASI Preview 1 (wasi_snapshot_preview1) for standalone WASI runtimes
 * and browser WebAssembly engines.
 */

#ifndef LUTHON_WASI_H
#define LUTHON_WASI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* WASI Preview 1 Types */
typedef uint32_t __wasi_size_t;
typedef uint64_t __wasi_filesize_t;
typedef uint64_t __wasi_timestamp_t;
typedef uint32_t __wasi_clockid_t;
typedef int64_t  __wasi_filedelta_t;
typedef uint8_t  __wasi_whence_t;
typedef uint32_t __wasi_exitcode_t;
typedef uint16_t __wasi_errno_t;

#define __WASI_ERRNO_SUCCESS 0
#define __WASI_ERRNO_BADF    8
#define __WASI_ERRNO_INVAL   28
#define __WASI_ERRNO_IO      29
#define __WASI_ERRNO_NOMEM   48

#define __WASI_CLOCKID_REALTIME           0
#define __WASI_CLOCKID_MONOTONIC          1
#define __WASI_CLOCKID_PROCESS_CPUTIME_ID 2
#define __WASI_CLOCKID_THREAD_CPUTIME_ID  3

#define __WASI_WHENCE_SET 0
#define __WASI_WHENCE_CUR 1
#define __WASI_WHENCE_END 2

typedef struct __wasi_ciovec_t {
    const void *buf;
    __wasi_size_t buf_len;
} __wasi_ciovec_t;

typedef struct __wasi_iovec_t {
    void *buf;
    __wasi_size_t buf_len;
} __wasi_iovec_t;

/* WASI Preview 1 Host Imports */
#if defined(__wasm__) || defined(__wasm32__)
#define WASI_IMPORT(name) __attribute__((import_module("wasi_snapshot_preview1"), import_name(name)))
#else
#define WASI_IMPORT(name)
#endif

WASI_IMPORT("fd_write")
extern __wasi_errno_t __wasi_fd_write(int fd, const __wasi_ciovec_t *iovs, size_t iovs_len, __wasi_size_t *nwritten);

WASI_IMPORT("fd_read")
extern __wasi_errno_t __wasi_fd_read(int fd, const __wasi_iovec_t *iovs, size_t iovs_len, __wasi_size_t *nread);

WASI_IMPORT("fd_seek")
extern __wasi_errno_t __wasi_fd_seek(int fd, __wasi_filedelta_t offset, __wasi_whence_t whence, __wasi_filesize_t *newoffset);

WASI_IMPORT("fd_close")
extern __wasi_errno_t __wasi_fd_close(int fd);

WASI_IMPORT("clock_time_get")
extern __wasi_errno_t __wasi_clock_time_get(__wasi_clockid_t id, __wasi_timestamp_t precision, __wasi_timestamp_t *time);

WASI_IMPORT("environ_sizes_get")
extern __wasi_errno_t __wasi_environ_sizes_get(__wasi_size_t *environ_count, __wasi_size_t *environ_buf_size);

WASI_IMPORT("environ_get")
extern __wasi_errno_t __wasi_environ_get(uint8_t **environ, uint8_t *environ_buf);

WASI_IMPORT("random_get")
extern __wasi_errno_t __wasi_random_get(void *buf, __wasi_size_t buf_len);

WASI_IMPORT("proc_exit")
extern void __wasi_proc_exit(__wasi_exitcode_t rval);

/* Luthon POSIX Syscall Shims */
int luthon_wasi_write(int fd, const void *buf, size_t count);
int luthon_wasi_read(int fd, void *buf, size_t count);
int64_t luthon_wasi_seek(int fd, int64_t offset, int whence);
int luthon_wasi_close(int fd);
uint64_t luthon_wasi_time_now_ns(void);
int luthon_wasi_random_bytes(void *buf, size_t len);
void luthon_wasi_exit(int code);

/* Console and String I/O Helpers */
int luthon_wasi_print(const char *str);
int luthon_wasi_println(const char *str);
int luthon_wasi_print_int(int64_t val);
int luthon_wasi_print_double(double val, int precision);

/* Linear Memory Allocator for WebAssembly */
void* luthon_wasi_malloc(size_t size);
void* luthon_wasi_calloc(size_t nmemb, size_t size);
void* luthon_wasi_realloc(void *ptr, size_t size);
void luthon_wasi_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* LUTHON_WASI_H */
