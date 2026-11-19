#include "yyjson.h"
#include <stdlib.h>
#include <string.h>

struct yyjson_val {
    yyjson_type type;
    const char *str;
    size_t len;
    double num;
    bool b;
    size_t size;
};

struct yyjson_doc {
    yyjson_val root;
};

yyjson_doc *yyjson_read(const char *dat, size_t len, uint32_t flg) {
    (void)flg;
    if (!dat || len == 0) return NULL;
    yyjson_doc *doc = (yyjson_doc *)calloc(1, sizeof(yyjson_doc));
    return doc;
}

yyjson_val *yyjson_doc_get_root(yyjson_doc *doc) {
    if (!doc) return NULL;
    return &doc->root;
}

void yyjson_doc_free(yyjson_doc *doc) {
    if (doc) free(doc);
}

yyjson_type yyjson_get_type(yyjson_val *val) {
    return val ? val->type : YYJSON_TYPE_NONE;
}

const char *yyjson_get_str(yyjson_val *val) {
    return val ? val->str : NULL;
}

size_t yyjson_get_len(yyjson_val *val) {
    return val ? val->len : 0;
}

double yyjson_get_num(yyjson_val *val) {
    return val ? val->num : 0.0;
}

bool yyjson_get_bool(yyjson_val *val) {
    return val ? val->b : false;
}

size_t yyjson_arr_size(yyjson_val *val) {
    return val ? val->size : 0;
}

size_t yyjson_obj_size(yyjson_val *val) {
    return val ? val->size : 0;
}
