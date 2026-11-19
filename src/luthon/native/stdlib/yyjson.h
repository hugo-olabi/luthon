#ifndef YYJSON_H
#define YYJSON_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    YYJSON_TYPE_NONE = 0,
    YYJSON_TYPE_RAW  = 1,
    YYJSON_TYPE_NULL = 2,
    YYJSON_TYPE_BOOL = 3,
    YYJSON_TYPE_NUM  = 4,
    YYJSON_TYPE_STR  = 5,
    YYJSON_TYPE_ARR  = 6,
    YYJSON_TYPE_OBJ  = 7,
} yyjson_type;

typedef struct yyjson_val yyjson_val;
typedef struct yyjson_doc yyjson_doc;

yyjson_doc *yyjson_read(const char *dat, size_t len, uint32_t flg);
yyjson_val *yyjson_doc_get_root(yyjson_doc *doc);
void yyjson_doc_free(yyjson_doc *doc);

yyjson_type yyjson_get_type(yyjson_val *val);
const char *yyjson_get_str(yyjson_val *val);
size_t yyjson_get_len(yyjson_val *val);
double yyjson_get_num(yyjson_val *val);
bool yyjson_get_bool(yyjson_val *val);
size_t yyjson_arr_size(yyjson_val *val);
size_t yyjson_obj_size(yyjson_val *val);

#ifdef __cplusplus
}
#endif

#endif /* YYJSON_H */
