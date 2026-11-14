/*
 * Lock-Free MPMC Ring Buffer Channel (channel.c)
 * ===============================================
 * Multi-producer multi-consumer lock-free bounded circular queue
 * utilizing atomic sequence counters for sub-microsecond message dispatch.
 */

#include "luthon_thread.h"
#include <stdatomic.h>

typedef struct {
    _Atomic size_t sequence;
    LuthonMessage  message;
} ChannelCell;

struct LuthonChannel {
    size_t       capacity;
    size_t       mask;
    ChannelCell *buffer;
    _Atomic size_t head __attribute__((aligned(64)));
    _Atomic size_t tail __attribute__((aligned(64)));
};

static size_t next_pow2(size_t n) {
    if (n < 2) return 2;
    n--;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n |= n >> 32;
    return n + 1;
}

LuthonChannel* luthon_channel_create(size_t capacity) {
    size_t actual_cap = next_pow2(capacity);
    LuthonChannel *chan = (LuthonChannel*)malloc(sizeof(LuthonChannel));
    if (!chan) return NULL;

    chan->buffer = (ChannelCell*)malloc(sizeof(ChannelCell) * actual_cap);
    if (!chan->buffer) {
        free(chan);
        return NULL;
    }

    chan->capacity = actual_cap;
    chan->mask = actual_cap - 1;
    atomic_init(&chan->head, 0);
    atomic_init(&chan->tail, 0);

    for (size_t i = 0; i < actual_cap; i++) {
        atomic_init(&chan->buffer[i].sequence, i);
        chan->buffer[i].message.data = NULL;
        chan->buffer[i].message.size = 0;
        chan->buffer[i].message.type_tag = 0;
        chan->buffer[i].message.tag = 0;
    }

    return chan;
}

bool luthon_channel_push(LuthonChannel *chan, const LuthonMessage *msg) {
    if (!chan || !msg) return false;

    ChannelCell *cell;
    size_t pos = atomic_load_explicit(&chan->tail, memory_order_relaxed);

    for (;;) {
        cell = &chan->buffer[pos & chan->mask];
        size_t seq = atomic_load_explicit(&cell->sequence, memory_order_acquire);
        intptr_t diff = (intptr_t)seq - (intptr_t)pos;

        if (diff == 0) {
            if (atomic_compare_exchange_weak_explicit(&chan->tail, &pos, pos + 1,
                                                      memory_order_relaxed, memory_order_relaxed)) {
                break;
            }
        } else if (diff < 0) {
            /* Queue is full */
            return false;
        } else {
            pos = atomic_load_explicit(&chan->tail, memory_order_relaxed);
        }
    }

    cell->message = *msg;
    atomic_store_explicit(&cell->sequence, pos + 1, memory_order_release);
    return true;
}

bool luthon_channel_pop(LuthonChannel *chan, LuthonMessage *out_msg) {
    if (!chan) return false;

    ChannelCell *cell;
    size_t pos = atomic_load_explicit(&chan->head, memory_order_relaxed);

    for (;;) {
        cell = &chan->buffer[pos & chan->mask];
        size_t seq = atomic_load_explicit(&cell->sequence, memory_order_acquire);
        intptr_t diff = (intptr_t)seq - (intptr_t)(pos + 1);

        if (diff == 0) {
            if (atomic_compare_exchange_weak_explicit(&chan->head, &pos, pos + 1,
                                                      memory_order_relaxed, memory_order_relaxed)) {
                break;
            }
        } else if (diff < 0) {
            /* Queue is empty */
            return false;
        } else {
            pos = atomic_load_explicit(&chan->head, memory_order_relaxed);
        }
    }

    if (out_msg) {
        *out_msg = cell->message;
    }
    atomic_store_explicit(&cell->sequence, pos + chan->mask + 1, memory_order_release);
    return true;
}

size_t luthon_channel_size(const LuthonChannel *chan) {
    if (!chan) return 0;
    size_t head = atomic_load_explicit(&chan->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&chan->tail, memory_order_relaxed);
    return (tail >= head) ? (tail - head) : 0;
}

bool luthon_channel_is_empty(const LuthonChannel *chan) {
    return luthon_channel_size(chan) == 0;
}

void luthon_channel_destroy(LuthonChannel *chan) {
    if (!chan) return;
    if (chan->buffer) {
        free(chan->buffer);
    }
    free(chan);
}
