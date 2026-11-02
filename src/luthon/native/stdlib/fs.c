/*
 * Luthon Native C File System Primitives (fs.c)
 * =============================================
 * High-performance C implementations of file path operations,
 * directory inspection, and file status checks with zero Lua allocation.
 */

#include "luthon_stdlib.h"
#include <sys/stat.h>
#include <unistd.h>

size_t luthon_path_join(const char *p1, const char *p2, char *dst, size_t max_len) {
    if (!dst || max_len == 0) return 0;
    if (!p1 || p1[0] == '\0') {
        if (!p2) { dst[0] = '\0'; return 0; }
        size_t l2 = strlen(p2);
        if (l2 >= max_len) l2 = max_len - 1;
        memcpy(dst, p2, l2);
        dst[l2] = '\0';
        return l2;
    }
    if (!p2 || p2[0] == '\0') {
        size_t l1 = strlen(p1);
        if (l1 >= max_len) l1 = max_len - 1;
        memcpy(dst, p1, l1);
        dst[l1] = '\0';
        return l1;
    }

    /* If p2 is absolute, return p2 */
    if (p2[0] == '/' || (p2[0] != '\0' && p2[1] == ':')) {
        size_t l2 = strlen(p2);
        if (l2 >= max_len) l2 = max_len - 1;
        memcpy(dst, p2, l2);
        dst[l2] = '\0';
        return l2;
    }

    size_t l1 = strlen(p1);
    size_t l2 = strlen(p2);
    bool needs_sep = (p1[l1 - 1] != '/' && p1[l1 - 1] != '\\');

    size_t total = l1 + (needs_sep ? 1 : 0) + l2;
    if (total >= max_len) total = max_len - 1;

    size_t cur = (l1 < max_len) ? l1 : max_len - 1;
    memcpy(dst, p1, cur);

    if (needs_sep && cur + 1 < max_len) {
        dst[cur++] = '/';
    }

    size_t rem = (max_len > cur + 1) ? max_len - cur - 1 : 0;
    size_t copy_l2 = (l2 < rem) ? l2 : rem;
    if (copy_l2 > 0) {
        memcpy(dst + cur, p2, copy_l2);
        cur += copy_l2;
    }
    dst[cur] = '\0';
    return cur;
}

const char* luthon_path_basename(const char *path) {
    if (!path || path[0] == '\0') return "";
    size_t len = strlen(path);
    /* Trim trailing slashes */
    while (len > 1 && (path[len - 1] == '/' || path[len - 1] == '\\')) {
        len--;
    }
    for (size_t i = len; i > 0; i--) {
        char c = path[i - 1];
        if (c == '/' || c == '\\') {
            return path + i;
        }
    }
    return path;
}

size_t luthon_path_dirname(const char *path, char *dst, size_t max_len) {
    if (!dst || max_len == 0) return 0;
    if (!path || path[0] == '\0') {
        dst[0] = '.';
        dst[1] = '\0';
        return 1;
    }

    size_t len = strlen(path);
    while (len > 1 && (path[len - 1] == '/' || path[len - 1] == '\\')) {
        len--;
    }

    size_t last_sep = 0;
    bool found = false;
    for (size_t i = len; i > 0; i--) {
        char c = path[i - 1];
        if (c == '/' || c == '\\') {
            last_sep = i - 1;
            found = true;
            break;
        }
    }

    if (!found) {
        dst[0] = '.';
        dst[1] = '\0';
        return 1;
    }

    if (last_sep == 0) {
        /* Root / */
        dst[0] = '/';
        dst[1] = '\0';
        return 1;
    }

    size_t out_len = (last_sep < max_len - 1) ? last_sep : max_len - 1;
    memcpy(dst, path, out_len);
    dst[out_len] = '\0';
    return out_len;
}

bool luthon_path_exists(const char *path) {
    if (!path || path[0] == '\0') return false;
    struct stat st;
    return (stat(path, &st) == 0);
}

bool luthon_path_isdir(const char *path) {
    if (!path || path[0] == '\0') return false;
    struct stat st;
    if (stat(path, &st) != 0) return false;
    return S_ISDIR(st.st_mode);
}

size_t luthon_path_getsize(const char *path) {
    if (!path || path[0] == '\0') return 0;
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return (size_t)st.st_size;
}
