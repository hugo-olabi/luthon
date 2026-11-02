/*
 * Luthon Native C Codecs (codec.c)
 * ================================
 * High-performance C implementations of Base64 and Hex encoding/decoding
 * optimized for binary asset processing pipelines.
 */

#include "luthon_stdlib.h"

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static const int8_t b64_rev_table[256] = {
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
    52,53,54,55,56,57,58,59,60,61,-1,-1,-1, 0,-1,-1,
    -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
    15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
    -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
    41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
};

size_t luthon_b64_decoded_size(const char *src, size_t src_len) {
    if (!src || src_len == 0) return 0;
    size_t pad = 0;
    if (src_len >= 1 && src[src_len - 1] == '=') pad++;
    if (src_len >= 2 && src[src_len - 2] == '=') pad++;
    return (src_len * 3) / 4 - pad;
}

size_t luthon_b64_decode(const char *src, size_t src_len, uint8_t *dst) {
    if (!src || !dst || src_len == 0) return 0;

    size_t in_idx = 0;
    size_t out_idx = 0;

    while (in_idx < src_len) {
        /* Skip whitespace */
        while (in_idx < src_len && (src[in_idx] == ' ' || src[in_idx] == '\t' || src[in_idx] == '\r' || src[in_idx] == '\n')) {
            in_idx++;
        }
        if (in_idx >= src_len) break;

        uint32_t buf = 0;
        int bits = 0;

        for (int i = 0; i < 4 && in_idx < src_len; i++) {
            char c = src[in_idx++];
            if (c == '=') break;
            int8_t val = b64_rev_table[(uint8_t)c];
            if (val >= 0) {
                buf = (buf << 6) | (uint32_t)val;
                bits += 6;
            }
        }

        while (bits >= 8) {
            bits -= 8;
            dst[out_idx++] = (uint8_t)((buf >> bits) & 0xFF);
        }
    }

    return out_idx;
}

size_t luthon_b64_encode(const uint8_t *src, size_t src_len, char *dst) {
    if (!src || !dst) return 0;
    size_t out_idx = 0;
    size_t i = 0;

    while (i + 2 < src_len) {
        uint32_t b = ((uint32_t)src[i] << 16) | ((uint32_t)src[i + 1] << 8) | src[i + 2];
        dst[out_idx++] = b64_table[(b >> 18) & 0x3F];
        dst[out_idx++] = b64_table[(b >> 12) & 0x3F];
        dst[out_idx++] = b64_table[(b >> 6) & 0x3F];
        dst[out_idx++] = b64_table[b & 0x3F];
        i += 3;
    }

    if (i < src_len) {
        size_t rem = src_len - i;
        uint32_t b = (uint32_t)src[i] << 16;
        if (rem == 2) {
            b |= (uint32_t)src[i + 1] << 8;
        }
        dst[out_idx++] = b64_table[(b >> 18) & 0x3F];
        dst[out_idx++] = b64_table[(b >> 12) & 0x3F];
        dst[out_idx++] = (rem == 2) ? b64_table[(b >> 6) & 0x3F] : '=';
        dst[out_idx++] = '=';
    }

    dst[out_idx] = '\0';
    return out_idx;
}

static const char hex_digits[] = "0123456789abcdef";

size_t luthon_hex_encode(const uint8_t *src, size_t src_len, char *dst) {
    if (!src || !dst) return 0;
    for (size_t i = 0; i < src_len; i++) {
        dst[i * 2]     = hex_digits[(src[i] >> 4) & 0x0F];
        dst[i * 2 + 1] = hex_digits[src[i] & 0x0F];
    }
    dst[src_len * 2] = '\0';
    return src_len * 2;
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

size_t luthon_hex_decode(const char *src, size_t src_len, uint8_t *dst) {
    if (!src || !dst || (src_len % 2) != 0) return 0;
    size_t out_len = src_len / 2;
    for (size_t i = 0; i < out_len; i++) {
        int hi = hex_nibble(src[i * 2]);
        int lo = hex_nibble(src[i * 2 + 1]);
        if (hi < 0 || lo < 0) return 0;
        dst[i] = (uint8_t)((hi << 4) | lo);
    }
    return out_len;
}
