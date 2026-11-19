#include "luthon_stdlib.h"
#include "yyjson.h"
#include <ctype.h>
#include <errno.h>

typedef struct LuthonJsonArenaChunk {
    struct LuthonJsonArenaChunk *next;
    size_t cap;
    size_t used;
    char data[];
} LuthonJsonArenaChunk;

typedef struct LuthonJsonContext {
    LuthonJsonArenaChunk *chunk;
} LuthonJsonContext;

static void *arena_alloc(LuthonJsonContext *ctx, size_t size) {
    size = (size + 7) & ~((size_t)7);
    LuthonJsonArenaChunk *c = ctx->chunk;
    if (!c || c->used + size > c->cap) {
        size_t next_cap = c ? (c->cap * 2) : 4096;
        if (next_cap < size + 1024) next_cap = size + 1024;
        LuthonJsonArenaChunk *nc = (LuthonJsonArenaChunk *)malloc(sizeof(LuthonJsonArenaChunk) + next_cap);
        if (!nc) return NULL;
        nc->cap = next_cap;
        nc->used = 0;
        nc->next = c;
        ctx->chunk = nc;
        c = nc;
    }
    void *ptr = c->data + c->used;
    c->used += size;
    return ptr;
}

#define LUTHON_JSON_MAX_DEPTH 512

static inline const char *skip_ws(const char *p, const char *end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) {
        p++;
    }
    return p;
}

static const char *parse_string(LuthonJsonContext *ctx, const char *p, const char *end, const char **out_str, size_t *out_len) {
    if (p >= end || *p != '"') return NULL;
    p++;
    const char *start = p;
    bool has_escape = false;
    while (p < end && *p != '"') {
        if (*p == '\\') {
            has_escape = true;
            p++;
            if (p >= end) return NULL;
        }
        p++;
    }
    if (p >= end || *p != '"') return NULL;

    if (!has_escape) {
        *out_str = start;
        *out_len = (size_t)(p - start);
        return p + 1;
    }

    size_t max_len = (size_t)(p - start);
    char *buf = (char *)arena_alloc(ctx, max_len + 1);
    if (!buf) return NULL;

    const char *src = start;
    size_t dst_idx = 0;
    while (src < p) {
        if (*src == '\\') {
            src++;
            switch (*src) {
                case '"':  buf[dst_idx++] = '"'; break;
                case '\\': buf[dst_idx++] = '\\'; break;
                case '/':  buf[dst_idx++] = '/'; break;
                case 'b':  buf[dst_idx++] = '\b'; break;
                case 'f':  buf[dst_idx++] = '\f'; break;
                case 'n':  buf[dst_idx++] = '\n'; break;
                case 'r':  buf[dst_idx++] = '\r'; break;
                case 't':  buf[dst_idx++] = '\t'; break;
                case 'u': {
                    if (src + 4 >= p) return NULL;
                    unsigned int codepoint = 0;
                    for (int i = 1; i <= 4; i++) {
                        char h = src[i];
                        codepoint <<= 4;
                        if (h >= '0' && h <= '9') codepoint |= (h - '0');
                        else if (h >= 'a' && h <= 'f') codepoint |= (h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') codepoint |= (h - 'A' + 10);
                        else return NULL;
                    }
                    src += 4;
                    /* Check UTF-16 surrogate pairs */
                    if (codepoint >= 0xD800 && codepoint <= 0xDBFF) {
                        if (src + 6 < p && src[1] == '\\' && src[2] == 'u') {
                            unsigned int low = 0;
                            bool low_ok = true;
                            for (int i = 3; i <= 6; i++) {
                                char h = src[i];
                                low <<= 4;
                                if (h >= '0' && h <= '9') low |= (h - '0');
                                else if (h >= 'a' && h <= 'f') low |= (h - 'a' + 10);
                                else if (h >= 'A' && h <= 'F') low |= (h - 'A' + 10);
                                else { low_ok = false; break; }
                            }
                            if (low_ok && low >= 0xDC00 && low <= 0xDFFF) {
                                codepoint = 0x10000 + (((codepoint - 0xD800) << 10) | (low - 0xDC00));
                                src += 6;
                            }
                        }
                    }
                    if (codepoint <= 0x7F) {
                        buf[dst_idx++] = (char)codepoint;
                    } else if (codepoint <= 0x7FF) {
                        buf[dst_idx++] = (char)(0xC0 | ((codepoint >> 6) & 0x1F));
                        buf[dst_idx++] = (char)(0x80 | (codepoint & 0x3F));
                    } else if (codepoint <= 0xFFFF) {
                        buf[dst_idx++] = (char)(0xE0 | ((codepoint >> 12) & 0x0F));
                        buf[dst_idx++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
                        buf[dst_idx++] = (char)(0x80 | (codepoint & 0x3F));
                    } else if (codepoint <= 0x10FFFF) {
                        buf[dst_idx++] = (char)(0xF0 | ((codepoint >> 18) & 0x07));
                        buf[dst_idx++] = (char)(0x80 | ((codepoint >> 12) & 0x3F));
                        buf[dst_idx++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
                        buf[dst_idx++] = (char)(0x80 | (codepoint & 0x3F));
                    } else {
                        return NULL;
                    }
                    break;
                }
                default:
                    buf[dst_idx++] = *src;
                    break;
            }
            src++;
        } else {
            buf[dst_idx++] = *src++;
        }
    }
    buf[dst_idx] = '\0';
    *out_str = buf;
    *out_len = dst_idx;
    return p + 1;
}

static const char *parse_number(const char *p, const char *end, double *out_num) {
    if (p >= end) return NULL;
    /* Reject leading zeros like 0123, -0123 */
    if (*p == '0' && p + 1 < end && p[1] >= '0' && p[1] <= '9') return NULL;
    if (*p == '-' && p + 1 < end && p[1] == '0' && p + 2 < end && p[2] >= '0' && p[2] <= '9') return NULL;
    char *endptr = NULL;
    double num = strtod(p, &endptr);
    if (endptr == p || endptr > end) return NULL;
    *out_num = num;
    return endptr;
}

static const char *parse_value(LuthonJsonContext *ctx, const char *p, const char *end, int depth, LuthonJsonVal **out_val);

static const char *parse_array(LuthonJsonContext *ctx, const char *p, const char *end, int depth, LuthonJsonVal **out_val) {
    if (p >= end || *p != '[' || depth > LUTHON_JSON_MAX_DEPTH) return NULL;
    p++;
    p = skip_ws(p, end);

    LuthonJsonVal *arr_val = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
    if (!arr_val) return NULL;
    memset(arr_val, 0, sizeof(LuthonJsonVal));
    arr_val->type = LUTHON_JSON_ARRAY;

    if (p < end && *p == ']') {
        *out_val = arr_val;
        return p + 1;
    }

    LuthonJsonVal *head = NULL;
    LuthonJsonVal *tail = NULL;

    while (p < end) {
        LuthonJsonVal *elem = NULL;
        p = parse_value(ctx, p, end, depth + 1, &elem);
        if (!p || !elem) return NULL;

        if (!head) {
            head = elem;
            tail = elem;
        } else {
            tail->next = elem;
            tail = elem;
        }

        p = skip_ws(p, end);
        if (p < end && *p == ',') {
            p++;
            p = skip_ws(p, end);
        } else if (p < end && *p == ']') {
            p++;
            break;
        } else {
            return NULL;
        }
    }

    arr_val->child = head;
    *out_val = arr_val;
    return p;
}

static const char *parse_object(LuthonJsonContext *ctx, const char *p, const char *end, int depth, LuthonJsonVal **out_val) {
    if (p >= end || *p != '{' || depth > LUTHON_JSON_MAX_DEPTH) return NULL;
    p++;
    p = skip_ws(p, end);

    LuthonJsonVal *obj_val = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
    if (!obj_val) return NULL;
    memset(obj_val, 0, sizeof(LuthonJsonVal));
    obj_val->type = LUTHON_JSON_OBJECT;

    if (p < end && *p == '}') {
        *out_val = obj_val;
        return p + 1;
    }

    LuthonJsonVal *head = NULL;
    LuthonJsonVal *tail = NULL;

    while (p < end) {
        const char *k_str = NULL;
        size_t k_len = 0;
        p = parse_string(ctx, p, end, &k_str, &k_len);
        if (!p) return NULL;

        p = skip_ws(p, end);
        if (p >= end || *p != ':') return NULL;
        p++;
        p = skip_ws(p, end);

        LuthonJsonVal *v_val = NULL;
        p = parse_value(ctx, p, end, depth + 1, &v_val);
        if (!p || !v_val) return NULL;

        v_val->key = k_str;
        v_val->key_len = k_len;

        if (!head) {
            head = v_val;
            tail = v_val;
        } else {
            tail->next = v_val;
            tail = v_val;
        }

        p = skip_ws(p, end);
        if (p < end && *p == ',') {
            p++;
            p = skip_ws(p, end);
        } else if (p < end && *p == '}') {
            p++;
            break;
        } else {
            return NULL;
        }
    }

    obj_val->child = head;
    *out_val = obj_val;
    return p;
}

static const char *parse_value(LuthonJsonContext *ctx, const char *p, const char *end, int depth, LuthonJsonVal **out_val) {
    p = skip_ws(p, end);
    if (p >= end || depth > LUTHON_JSON_MAX_DEPTH) return NULL;

    char c = *p;
    if (c == '{') {
        return parse_object(ctx, p, end, depth, out_val);
    } else if (c == '[') {
        return parse_array(ctx, p, end, depth, out_val);
    } else if (c == '"') {
        const char *s = NULL;
        size_t slen = 0;
        const char *next_p = parse_string(ctx, p, end, &s, &slen);
        if (!next_p) return NULL;
        LuthonJsonVal *v = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
        if (!v) return NULL;
        memset(v, 0, sizeof(LuthonJsonVal));
        v->type = LUTHON_JSON_STRING;
        v->str_val = s;
        v->str_len = slen;
        *out_val = v;
        return next_p;
    } else if (c == 't') {
        if (end - p >= 4 && memcmp(p, "true", 4) == 0) {
            LuthonJsonVal *v = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
            if (!v) return NULL;
            memset(v, 0, sizeof(LuthonJsonVal));
            v->type = LUTHON_JSON_BOOL;
            v->bool_val = true;
            *out_val = v;
            return p + 4;
        }
        return NULL;
    } else if (c == 'f') {
        if (end - p >= 5 && memcmp(p, "false", 5) == 0) {
            LuthonJsonVal *v = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
            if (!v) return NULL;
            memset(v, 0, sizeof(LuthonJsonVal));
            v->type = LUTHON_JSON_BOOL;
            v->bool_val = false;
            *out_val = v;
            return p + 5;
        }
        return NULL;
    } else if (c == 'n') {
        if (end - p >= 4 && memcmp(p, "null", 4) == 0) {
            LuthonJsonVal *v = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
            if (!v) return NULL;
            memset(v, 0, sizeof(LuthonJsonVal));
            v->type = LUTHON_JSON_NULL;
            *out_val = v;
            return p + 4;
        }
        return NULL;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        double num = 0;
        const char *next_p = parse_number(p, end, &num);
        if (!next_p) return NULL;
        LuthonJsonVal *v = (LuthonJsonVal *)arena_alloc(ctx, sizeof(LuthonJsonVal));
        if (!v) return NULL;
        memset(v, 0, sizeof(LuthonJsonVal));
        v->type = LUTHON_JSON_NUMBER;
        v->num_val = num;
        *out_val = v;
        return next_p;
    }
    return NULL;
}

LuthonJsonVal *luthon_json_parse(const char *dat, size_t len, size_t *out_consumed, void **out_ctx) {
    if (!dat || len == 0) return NULL;
    LuthonJsonContext *ctx = (LuthonJsonContext *)calloc(1, sizeof(LuthonJsonContext));
    if (!ctx) return NULL;

    const char *end = dat + len;
    LuthonJsonVal *root = NULL;
    const char *p = parse_value(ctx, dat, end, 0, &root);
    if (!p || !root) {
        luthon_json_free(ctx);
        return NULL;
    }

    if (out_consumed) {
        *out_consumed = (size_t)(p - dat);
    }
    if (out_ctx) {
        *out_ctx = ctx;
    }
    return root;
}

void luthon_json_free(void *ctx) {
    if (!ctx) return;
    LuthonJsonContext *c = (LuthonJsonContext *)ctx;
    LuthonJsonArenaChunk *chunk = c->chunk;
    while (chunk) {
        LuthonJsonArenaChunk *next = chunk->next;
        free(chunk);
        chunk = next;
    }
    free(c);
}

const char *luthon_json_read(const char *dat, size_t len, size_t *out_val_count) {
    void *ctx = NULL;
    size_t consumed = 0;
    LuthonJsonVal *root = luthon_json_parse(dat, len, &consumed, &ctx);
    if (!root) return NULL;
    if (out_val_count) *out_val_count = consumed;
    luthon_json_free(ctx);
    return dat;
}

char *luthon_json_write(const void *val, size_t *out_len) {
    (void)val;
    if (out_len) *out_len = 0;
    return NULL;
}
