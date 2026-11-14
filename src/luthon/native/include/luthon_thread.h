/*
 * Luthon Native Multi-Threading Runtime (luthon_thread.h)
 * ========================================================
 * POSIX pthread worker pool, lock-free ring buffer channel,
 * dedicated OS threads, and synchronization primitives for GIL-free parallel execution.
 */

#ifndef LUTHON_THREAD_H
#define LUTHON_THREAD_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <pthread.h>
#include <semaphore.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define EXPORT __declspec(dllexport)
#else
  #define EXPORT __attribute__((visibility("default")))
#endif

/* -------------------------------------------------------------------------
 * 1. Lock-Free SPSC/MPMC Ring Buffer Channel
 * ------------------------------------------------------------------------- */

typedef struct {
    void     *data;
    size_t    size;
    int32_t   type_tag;
    uint64_t  tag;
} LuthonMessage;

typedef struct LuthonChannel LuthonChannel;

EXPORT LuthonChannel* luthon_channel_create(size_t capacity);
EXPORT bool           luthon_channel_push(LuthonChannel *chan, const LuthonMessage *msg);
EXPORT bool           luthon_channel_pop(LuthonChannel *chan, LuthonMessage *out_msg);
EXPORT size_t         luthon_channel_size(const LuthonChannel *chan);
EXPORT bool           luthon_channel_is_empty(const LuthonChannel *chan);
EXPORT void           luthon_channel_destroy(LuthonChannel *chan);

/* -------------------------------------------------------------------------
 * 2. Native POSIX Thread Pool & Worker Runtime
 * ------------------------------------------------------------------------- */

typedef void* (*luthon_task_fn)(void *arg);

typedef struct LuthonThreadPool LuthonThreadPool;

EXPORT LuthonThreadPool* luthon_threadpool_create(int num_workers);
EXPORT int               luthon_threadpool_worker_count(const LuthonThreadPool *pool);
EXPORT void              luthon_threadpool_set_init_script(LuthonThreadPool *pool, const char *script);
EXPORT uint64_t          luthon_threadpool_submit(LuthonThreadPool *pool, luthon_task_fn fn, void *arg);
EXPORT uint64_t          luthon_threadpool_submit_lua(LuthonThreadPool *pool, const char *code, const char *entry_func, void *arg);
EXPORT uint64_t          luthon_threadpool_submit_bytecode(LuthonThreadPool *pool, const char *bytecode, size_t bytecode_len, int has_arg_num, double arg_num, void *arg_ptr);
EXPORT bool              luthon_threadpool_is_done(LuthonThreadPool *pool, uint64_t task_id);
EXPORT void*             luthon_threadpool_wait(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
EXPORT double            luthon_threadpool_wait_number(LuthonThreadPool *pool, uint64_t task_id, int *out_error);
EXPORT const char*       luthon_threadpool_get_error(LuthonThreadPool *pool, uint64_t task_id);
EXPORT void              luthon_threadpool_destroy(LuthonThreadPool *pool);

/* -------------------------------------------------------------------------
 * 3. Dedicated OS Threads (threading.Thread)
 * ------------------------------------------------------------------------- */

EXPORT void* luthon_dedicated_thread_create(const char *bytecode, size_t len, double arg_num, void *arg_ptr);
EXPORT void  luthon_dedicated_thread_join(void *handle);
EXPORT bool  luthon_dedicated_thread_is_alive(void *handle);

/* -------------------------------------------------------------------------
 * 4. Thread Synchronization Primitives
 * ------------------------------------------------------------------------- */

typedef struct LuthonMutex LuthonMutex;
typedef struct LuthonEvent LuthonEvent;
typedef struct LuthonSemaphore LuthonSemaphore;

/* Mutex (Normal and Recursive) */
EXPORT LuthonMutex* luthon_mutex_create(bool recursive);
EXPORT bool         luthon_mutex_lock(LuthonMutex *m);
EXPORT bool         luthon_mutex_trylock(LuthonMutex *m);
EXPORT bool         luthon_mutex_unlock(LuthonMutex *m);
EXPORT void         luthon_mutex_destroy(LuthonMutex *m);

/* Event */
EXPORT LuthonEvent* luthon_event_create(bool initial_state);
EXPORT void         luthon_event_set(LuthonEvent *e);
EXPORT void         luthon_event_clear(LuthonEvent *e);
EXPORT bool         luthon_event_is_set(LuthonEvent *e);
EXPORT bool         luthon_event_wait(LuthonEvent *e, double timeout_sec);
EXPORT void         luthon_event_destroy(LuthonEvent *e);

/* Semaphore */
EXPORT LuthonSemaphore* luthon_semaphore_create(int initial_value);
EXPORT bool             luthon_semaphore_acquire(LuthonSemaphore *s, double timeout_sec);
EXPORT void             luthon_semaphore_release(LuthonSemaphore *s);
EXPORT int              luthon_semaphore_get_value(LuthonSemaphore *s);
EXPORT void             luthon_semaphore_destroy(LuthonSemaphore *s);

#ifdef __cplusplus
}
#endif

#endif /* LUTHON_THREAD_H */
