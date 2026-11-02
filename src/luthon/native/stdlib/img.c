/*
 * Luthon Native C Image Processing (img.c)
 * ========================================
 * High-performance PNG decoding/encoding directly in C without crossing
 * FFI callback boundaries, plus vectorized texture processing.
 */

#include "luthon_stdlib.h"
#include <png.h>

/* Memory buffer reading state for libpng */
typedef struct {
    const uint8_t *data;
    size_t size;
    size_t offset;
} MemReader;

static void mem_read_fn(png_structp png_ptr, png_bytep out_bytes, png_size_t byte_count_to_read) {
    MemReader *reader = (MemReader *)png_get_io_ptr(png_ptr);
    if (!reader) return;
    if (reader->offset + byte_count_to_read > reader->size) {
        png_error(png_ptr, "Unexpected end of memory stream");
        return;
    }
    memcpy(out_bytes, reader->data + reader->offset, byte_count_to_read);
    reader->offset += byte_count_to_read;
}

/* Memory buffer writing state for libpng */
typedef struct {
    uint8_t *buffer;
    size_t size;
    size_t capacity;
} MemWriter;

static void mem_write_fn(png_structp png_ptr, png_bytep in_bytes, png_size_t byte_count_to_write) {
    MemWriter *writer = (MemWriter *)png_get_io_ptr(png_ptr);
    if (!writer) return;
    if (writer->size + byte_count_to_write > writer->capacity) {
        size_t new_cap = (writer->capacity == 0) ? 16384 : writer->capacity * 2;
        while (new_cap < writer->size + byte_count_to_write) {
            new_cap *= 2;
        }
        uint8_t *new_buf = (uint8_t *)realloc(writer->buffer, new_cap);
        if (!new_buf) {
            png_error(png_ptr, "Out of memory in mem_write_fn");
            return;
        }
        writer->buffer = new_buf;
        writer->capacity = new_cap;
    }
    memcpy(writer->buffer + writer->size, in_bytes, byte_count_to_write);
    writer->size += byte_count_to_write;
}

static void mem_flush_fn(png_structp png_ptr) {
    (void)png_ptr;
}

/*
 * Reads PNG from memory buffer entirely in C.
 * Returns true on success, false on failure.
 * Output buffer is allocated via malloc() and must be freed with luthon_png_free().
 */
EXPORT bool luthon_png_read_mem(
    const uint8_t *data,
    size_t size,
    int *out_w,
    int *out_h,
    int *out_channels,
    uint8_t **out_buf
) {
    if (!data || size < 8 || !out_w || !out_h || !out_channels || !out_buf) {
        return false;
    }

    if (png_sig_cmp(data, 0, 8) != 0) {
        return false;
    }

    png_structp png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) return false;

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_read_struct(&png_ptr, NULL, NULL);
        return false;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return false;
    }

    MemReader reader;
    reader.data = data;
    reader.size = size;
    reader.offset = 8; /* skipped signature */

    png_set_read_fn(png_ptr, &reader, mem_read_fn);
    png_set_sig_bytes(png_ptr, 8);
    png_read_info(png_ptr, info_ptr);

    png_uint_32 width = 0, height = 0;
    int bit_depth = 0, color_type = 0;
    png_get_IHDR(png_ptr, info_ptr, &width, &height, &bit_depth, &color_type, NULL, NULL, NULL);

    if (bit_depth == 16) {
        png_set_strip_16(png_ptr);
    }
    if (color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_palette_to_rgb(png_ptr);
    }
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) {
        png_set_expand_gray_1_2_4_to_8(png_ptr);
    }
    if (png_get_valid(png_ptr, info_ptr, PNG_INFO_tRNS)) {
        png_set_tRNS_to_alpha(png_ptr);
    }

    /* Standardize to RGBA (4 channels) for consistency */
    if (color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_filler(png_ptr, 0xFF, PNG_FILLER_AFTER);
    } else if (color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GA) {
        png_set_gray_to_rgb(png_ptr);
        if (color_type == PNG_COLOR_TYPE_GRAY) {
            png_set_filler(png_ptr, 0xFF, PNG_FILLER_AFTER);
        }
    }

    png_read_update_info(png_ptr, info_ptr);

    int channels = 4;
    size_t row_bytes = width * channels;
    uint8_t *buf = (uint8_t *)malloc(row_bytes * height);
    if (!buf) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return false;
    }

    png_bytep *row_pointers = (png_bytep *)malloc(sizeof(png_bytep) * height);
    if (!row_pointers) {
        free(buf);
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return false;
    }

    for (png_uint_32 y = 0; y < height; y++) {
        row_pointers[y] = buf + y * row_bytes;
    }

    png_read_image(png_ptr, row_pointers);
    png_read_end(png_ptr, NULL);

    free(row_pointers);
    png_destroy_read_struct(&png_ptr, &info_ptr, NULL);

    *out_w = (int)width;
    *out_h = (int)height;
    *out_channels = channels;
    *out_buf = buf;
    return true;
}

/*
 * Writes raw image buffer to PNG encoded memory.
 * Output buffer must be freed with luthon_png_free().
 */
EXPORT bool luthon_png_write_mem(
    const uint8_t *buf,
    int w,
    int h,
    int channels,
    uint8_t **out_data,
    size_t *out_size
) {
    if (!buf || w <= 0 || h <= 0 || !out_data || !out_size) {
        return false;
    }

    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) return false;

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, NULL);
        return false;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        return false;
    }

    MemWriter writer;
    writer.buffer = NULL;
    writer.size = 0;
    writer.capacity = 0;

    png_set_write_fn(png_ptr, &writer, mem_write_fn, mem_flush_fn);

    int color_type = PNG_COLOR_TYPE_RGBA;
    if (channels == 1) color_type = PNG_COLOR_TYPE_GRAY;
    else if (channels == 3) color_type = PNG_COLOR_TYPE_RGB;

    png_set_IHDR(
        png_ptr, info_ptr,
        (png_uint_32)w, (png_uint_32)h, 8,
        color_type,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    );

    png_write_info(png_ptr, info_ptr);

    size_t row_stride = (size_t)w * channels;
    png_bytep *row_pointers = (png_bytep *)malloc(sizeof(png_bytep) * h);
    if (!row_pointers) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        if (writer.buffer) free(writer.buffer);
        return false;
    }

    for (int y = 0; y < h; y++) {
        row_pointers[y] = (png_bytep)(buf + y * row_stride);
    }

    png_write_image(png_ptr, row_pointers);
    png_write_end(png_ptr, NULL);

    free(row_pointers);
    png_destroy_write_struct(&png_ptr, &info_ptr);

    *out_data = writer.buffer;
    *out_size = writer.size;
    return true;
}

EXPORT void luthon_png_free(void *ptr) {
    if (ptr) free(ptr);
}

/*
 * Vectorized MER -> ORM + Emission unpacker:
 * MER quad: [R=Occlusion, G=Emission, B=Roughness, A=Metallic]
 * ORM triplet: [R=Occlusion (MER[0]), G=Roughness (MER[2]), B=Metallic (MER[3])]
 * Emission scalar: [L=Emission (MER[1])]
 */
EXPORT void luthon_img_mer_to_orm_emission(
    const uint8_t *src_rgba,
    int w,
    int h,
    uint8_t *dst_orm_rgb,
    uint8_t *dst_em_l,
    bool *out_has_emission
) {
    if (!src_rgba || w <= 0 || h <= 0) return;

    size_t total_pixels = (size_t)w * (size_t)h;
    uint32_t emission_accum = 0;

    const uint8_t *src = src_rgba;
    uint8_t *dst_orm = dst_orm_rgb;
    uint8_t *dst_em = dst_em_l;

    for (size_t i = 0; i < total_pixels; i++) {
        uint8_t occ = src[0];
        uint8_t em  = src[1];
        uint8_t rgh = src[2];
        uint8_t met = src[3];

        if (dst_orm) {
            dst_orm[0] = occ;
            dst_orm[1] = rgh;
            dst_orm[2] = met;
            dst_orm += 3;
        }

        if (dst_em) {
            dst_em[0] = em;
            dst_em += 1;
        }

        emission_accum |= em;
        src += 4;
    }

    if (out_has_emission) {
        *out_has_emission = (emission_accum > 0);
    }
}

EXPORT void luthon_img_flip_vertical(
    uint8_t *data,
    int w,
    int h,
    int channels
) {
    if (!data || w <= 0 || h <= 1 || channels <= 0) return;
    size_t row_bytes = (size_t)w * (size_t)channels;
    uint8_t *top_row = data;
    uint8_t *bot_row = data + ((size_t)h - 1) * row_bytes;

    uint8_t stack_buf[4096];
    uint8_t *tmp = stack_buf;
    bool heap_allocated = false;
    if (row_bytes > sizeof(stack_buf)) {
        tmp = (uint8_t *)malloc(row_bytes);
        if (!tmp) return;
        heap_allocated = true;
    }

    size_t half_h = (size_t)h / 2;
    for (size_t y = 0; y < half_h; y++) {
        memcpy(tmp, top_row, row_bytes);
        memcpy(top_row, bot_row, row_bytes);
        memcpy(bot_row, tmp, row_bytes);
        top_row += row_bytes;
        bot_row -= row_bytes;
    }

    if (heap_allocated) {
        free(tmp);
    }
}

