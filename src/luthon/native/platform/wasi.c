/*
 * Luthon WebAssembly & WASI Preview 1 Platform Abstraction Layer (Phase 41)
 *
 * Implements POSIX syscall shims compatible with WASI Preview 1
 * (fd_read, fd_write, fd_seek, clock_time_get, environ_sizes_get, environ_get, random_get)
 * and lightweight linear memory management for standalone WASI & browser runtimes.
 */

#include "wasi.h"

#if defined(__wasm__) || defined(__wasm32__)

/* WebAssembly symbol for start of dynamic linear heap */
extern unsigned char __heap_base;
static uintptr_t s_heap_bump = 0;

/* Freestanding standard memory & string functions */
void* memcpy(void *dest, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dest;
}

void* memset(void *s, int c, size_t n) {
    uint8_t *p = (uint8_t *)s;
    for (size_t i = 0; i < n; i++) p[i] = (uint8_t)c;
    return s;
}

size_t strlen(const char *s) {
    size_t len = 0;
    while (s && s[len]) len++;
    return len;
}

/* WASI Preview 1 Syscall Shims */
int luthon_wasi_write(int fd, const void *buf, size_t count) {
    if (!buf || count == 0) return 0;
    __wasi_ciovec_t iov = { buf, (__wasi_size_t)count };
    __wasi_size_t nwritten = 0;
    __wasi_errno_t err = __wasi_fd_write(fd, &iov, 1, &nwritten);
    if (err != __WASI_ERRNO_SUCCESS) return -1;
    return (int)nwritten;
}

int luthon_wasi_read(int fd, void *buf, size_t count) {
    if (!buf || count == 0) return 0;
    __wasi_iovec_t iov = { buf, (__wasi_size_t)count };
    __wasi_size_t nread = 0;
    __wasi_errno_t err = __wasi_fd_read(fd, &iov, 1, &nread);
    if (err != __WASI_ERRNO_SUCCESS) return -1;
    return (int)nread;
}

int64_t luthon_wasi_seek(int fd, int64_t offset, int whence) {
    __wasi_whence_t w = __WASI_WHENCE_SET;
    if (whence == 1) w = __WASI_WHENCE_CUR;
    else if (whence == 2) w = __WASI_WHENCE_END;

    __wasi_filesize_t newoffset = 0;
    __wasi_errno_t err = __wasi_fd_seek(fd, (__wasi_filedelta_t)offset, w, &newoffset);
    if (err != __WASI_ERRNO_SUCCESS) return -1;
    return (int64_t)newoffset;
}

int luthon_wasi_close(int fd) {
    __wasi_errno_t err = __wasi_fd_close(fd);
    return (err == __WASI_ERRNO_SUCCESS) ? 0 : -1;
}

uint64_t luthon_wasi_time_now_ns(void) {
    __wasi_timestamp_t time_ns = 0;
    __wasi_errno_t err = __wasi_clock_time_get(__WASI_CLOCKID_REALTIME, 1000, &time_ns);
    if (err != __WASI_ERRNO_SUCCESS) return 0;
    return (uint64_t)time_ns;
}

int luthon_wasi_random_bytes(void *buf, size_t len) {
    if (!buf || len == 0) return 0;
    __wasi_errno_t err = __wasi_random_get(buf, (__wasi_size_t)len);
    return (err == __WASI_ERRNO_SUCCESS) ? 0 : -1;
}

void luthon_wasi_exit(int code) {
    __wasi_proc_exit((__wasi_exitcode_t)code);
}

/* Linear Memory Bump Allocator with 16-byte alignment */
typedef struct {
    uint32_t size;
    uint32_t magic;
} AllocHeader;

#define ALLOC_MAGIC 0x4C555448 /* "LUTH" */

void* luthon_wasi_malloc(size_t size) {
    if (size == 0) return (void*)0;

    if (s_heap_bump == 0) {
        s_heap_bump = (uintptr_t)&__heap_base;
    }

    size_t total_size = sizeof(AllocHeader) + size;
    /* Align to 16 bytes */
    uintptr_t aligned_start = (s_heap_bump + 15) & ~15;
    uintptr_t next_bump = aligned_start + total_size;

    uint32_t current_pages = __builtin_wasm_memory_size(0);
    uint32_t required_pages = (uint32_t)((next_bump + 65535) / 65536);

    if (required_pages > current_pages) {
        uint32_t delta = required_pages - current_pages;
        if (__builtin_wasm_memory_grow(0, delta) == (uint32_t)-1) {
            return (void*)0;
        }
    }

    s_heap_bump = next_bump;
    AllocHeader *hdr = (AllocHeader *)aligned_start;
    hdr->size = (uint32_t)size;
    hdr->magic = ALLOC_MAGIC;

    return (void *)(aligned_start + sizeof(AllocHeader));
}

void* luthon_wasi_calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *ptr = luthon_wasi_malloc(total);
    if (!ptr) return (void*)0;
    uint8_t *b = (uint8_t *)ptr;
    for (size_t i = 0; i < total; i++) b[i] = 0;
    return ptr;
}

void* luthon_wasi_realloc(void *ptr, size_t size) {
    if (!ptr) return luthon_wasi_malloc(size);
    if (size == 0) {
        luthon_wasi_free(ptr);
        return (void*)0;
    }

    AllocHeader *hdr = (AllocHeader *)((uintptr_t)ptr - sizeof(AllocHeader));
    if (hdr->magic != ALLOC_MAGIC) return (void*)0;

    if (size <= hdr->size) return ptr;

    void *new_ptr = luthon_wasi_malloc(size);
    if (!new_ptr) return (void*)0;

    uint8_t *src = (uint8_t *)ptr;
    uint8_t *dst = (uint8_t *)new_ptr;
    for (size_t i = 0; i < hdr->size; i++) dst[i] = src[i];

    return new_ptr;
}

void luthon_wasi_free(void *ptr) {
    (void)ptr;
    /* Bump allocator reclaims linearly at process termination */
}

#else

/* Host (POSIX) fallback implementations for development and testing */
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int luthon_wasi_write(int fd, const void *buf, size_t count) {
    return (int)write(fd, buf, count);
}

int luthon_wasi_read(int fd, void *buf, size_t count) {
    return (int)read(fd, buf, count);
}

int64_t luthon_wasi_seek(int fd, int64_t offset, int whence) {
    return (int64_t)lseek(fd, (off_t)offset, whence);
}

int luthon_wasi_close(int fd) {
    return close(fd);
}

uint64_t luthon_wasi_time_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int luthon_wasi_random_bytes(void *buf, size_t len) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, len);
    close(fd);
    return (n == (ssize_t)len) ? 0 : -1;
}

void luthon_wasi_exit(int code) {
    exit(code);
}

void* luthon_wasi_malloc(size_t size) {
    return malloc(size);
}

void* luthon_wasi_calloc(size_t nmemb, size_t size) {
    return calloc(nmemb, size);
}

void* luthon_wasi_realloc(void *ptr, size_t size) {
    return realloc(ptr, size);
}

void luthon_wasi_free(void *ptr) {
    free(ptr);
}

#endif /* __wasm__ */

/* Shared Formatted I/O Utilities */
int luthon_wasi_print(const char *str) {
    if (!str) return 0;
    size_t len = 0;
    while (str[len]) len++;
    return luthon_wasi_write(1, str, len);
}

int luthon_wasi_println(const char *str) {
    int r1 = luthon_wasi_print(str);
    int r2 = luthon_wasi_write(1, "\n", 1);
    return (r1 >= 0 && r2 >= 0) ? (r1 + r2) : -1;
}

int luthon_wasi_print_int(int64_t val) {
    char buf[32];
    int idx = 31;
    buf[idx] = '\0';
    int is_neg = (val < 0);
    uint64_t uval = is_neg ? (uint64_t)(-val) : (uint64_t)val;

    if (uval == 0) {
        buf[--idx] = '0';
    } else {
        while (uval > 0) {
            buf[--idx] = (char)('0' + (uval % 10));
            uval /= 10;
        }
    }
    if (is_neg) {
        buf[--idx] = '-';
    }
    return luthon_wasi_print(&buf[idx]);
}

int luthon_wasi_print_double(double val, int precision) {
    if (precision < 0) precision = 6;
    if (precision > 12) precision = 12;

    int is_neg = (val < 0.0);
    if (is_neg) {
        luthon_wasi_print("-");
        val = -val;
    }

    int64_t int_part = (int64_t)val;
    luthon_wasi_print_int(int_part);
    luthon_wasi_print(".");

    double frac = val - (double)int_part;
    for (int i = 0; i < precision; i++) {
        frac *= 10.0;
        int digit = (int)frac;
        char d = (char)('0' + digit);
        luthon_wasi_write(1, &d, 1);
        frac -= (double)digit;
    }
    return 0;
}

/* Browser WebAssembly & JS Linear Memory Bridge (Phase 41) */
#if defined(__wasm__) || defined(__wasm32__)
__attribute__((export_name("luthon_malloc")))
void* exported_malloc(size_t size) {
    return luthon_wasi_malloc(size);
}

__attribute__((export_name("luthon_free")))
void exported_free(void *ptr) {
    luthon_wasi_free(ptr);
}

__attribute__((export_name("luthon_get_time_ns")))
uint64_t exported_time_ns(void) {
    return luthon_wasi_time_now_ns();
}

__attribute__((export_name("luthon_print")))
int exported_print(const char *str) {
    return luthon_wasi_print(str);
}

__attribute__((export_name("luthon_println")))
int exported_println(const char *str) {
    return luthon_wasi_println(str);
}

__attribute__((export_name("luthon_print_int")))
int exported_print_int(int64_t val) {
    return luthon_wasi_print_int(val);
}

__attribute__((export_name("luthon_print_double")))
int exported_print_double(double val, int precision) {
    return luthon_wasi_print_double(val, precision);
}

__attribute__((export_name("luthon_random_bytes")))
int exported_random_bytes(void *buf, size_t len) {
    return luthon_wasi_random_bytes(buf, len);
}
#endif
