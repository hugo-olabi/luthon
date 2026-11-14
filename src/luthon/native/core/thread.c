/*
 * Native POSIX Thread Pool & Worker Runtime (thread.c)
 * ====================================================
 * POSIX pthread worker pool with per-thread isolated lua_State* instances,
 * dedicated OS threads, task scheduling, and synchronization primitives.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "luthon_thread.h"
#include <dlfcn.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <stdatomic.h>

/* -------------------------------------------------------------------------
 * Dynamic Lua 5.1 / LuaJIT API Bindings
 * ------------------------------------------------------------------------- */

typedef struct lua_State lua_State;
typedef lua_State*  (*pfn_luaL_newstate)(void);
typedef void        (*pfn_luaL_openlibs)(lua_State *L);
typedef void        (*pfn_lua_close)(lua_State *L);
typedef int         (*pfn_luaL_loadstring)(lua_State *L, const char *s);
typedef int         (*pfn_luaL_loadbuffer)(lua_State *L, const char *buff, size_t sz, const char *name);
typedef int         (*pfn_lua_pcall)(lua_State *L, int nargs, int nresults, int errfunc);
typedef const char* (*pfn_lua_tolstring)(lua_State *L, int idx, size_t *len);
typedef double      (*pfn_lua_tonumber)(lua_State *L, int idx);
typedef void*       (*pfn_lua_touserdata)(lua_State *L, int idx);
typedef void        (*pfn_lua_pushnumber)(lua_State *L, double n);
typedef void        (*pfn_lua_pushlightuserdata)(lua_State *L, void *p);
typedef void        (*pfn_lua_getfield)(lua_State *L, int idx, const char *k);
typedef void        (*pfn_lua_settop)(lua_State *L, int idx);
typedef int         (*pfn_lua_type)(lua_State *L, int idx);

static struct {
    pfn_luaL_newstate         luaL_newstate;
    pfn_luaL_openlibs         luaL_openlibs;
    pfn_lua_close             lua_close;
    pfn_luaL_loadstring       luaL_loadstring;
    pfn_luaL_loadbuffer       luaL_loadbuffer;
    pfn_lua_pcall             lua_pcall;
    pfn_lua_tolstring         lua_tolstring;
    pfn_lua_tonumber          lua_tonumber;
    pfn_lua_touserdata        lua_touserdata;
    pfn_lua_pushnumber        lua_pushnumber;
    pfn_lua_pushlightuserdata lua_pushlightuserdata;
    pfn_lua_getfield          lua_getfield;
    pfn_lua_settop            lua_settop;
    pfn_lua_type              lua_type;
    bool                      initialized;
} g_lua;

static void init_lua_bindings(void) {
    if (g_lua.initialized) return;

    void *h = RTLD_DEFAULT;
    g_lua.luaL_newstate         = (pfn_luaL_newstate)dlsym(h, "luaL_newstate");
    g_lua.luaL_openlibs         = (pfn_luaL_openlibs)dlsym(h, "luaL_openlibs");
    g_lua.lua_close             = (pfn_lua_close)dlsym(h, "lua_close");
    g_lua.luaL_loadstring       = (pfn_luaL_loadstring)dlsym(h, "luaL_loadstring");
    g_lua.luaL_loadbuffer       = (pfn_luaL_loadbuffer)dlsym(h, "luaL_loadbuffer");
    g_lua.lua_pcall             = (pfn_lua_pcall)dlsym(h, "lua_pcall");
    g_lua.lua_tolstring         = (pfn_lua_tolstring)dlsym(h, "lua_tolstring");
    g_lua.lua_tonumber          = (pfn_lua_tonumber)dlsym(h, "lua_tonumber");
    g_lua.lua_touserdata        = (pfn_lua_touserdata)dlsym(h, "lua_touserdata");
    g_lua.lua_pushnumber        = (pfn_lua_pushnumber)dlsym(h, "lua_pushnumber");
    g_lua.lua_pushlightuserdata = (pfn_lua_pushlightuserdata)dlsym(h, "lua_pushlightuserdata");
    g_lua.lua_getfield          = (pfn_lua_getfield)dlsym(h, "lua_getfield");
    g_lua.lua_settop            = (pfn_lua_settop)dlsym(h, "lua_settop");
    g_lua.lua_type              = (pfn_lua_type)dlsym(h, "lua_type");

    /* If not found in process image, try dlopening libluajit */
    if (!g_lua.luaL_newstate) {
        void *lib = dlopen("libluajit-5.1.so.2", RTLD_NOW | RTLD_GLOBAL);
        if (!lib) lib = dlopen("libluajit-5.1.so", RTLD_NOW | RTLD_GLOBAL);
        if (lib) {
            g_lua.luaL_newstate         = (pfn_luaL_newstate)dlsym(lib, "luaL_newstate");
            g_lua.luaL_openlibs         = (pfn_luaL_openlibs)dlsym(lib, "luaL_openlibs");
            g_lua.lua_close             = (pfn_lua_close)dlsym(lib, "lua_close");
            g_lua.luaL_loadstring       = (pfn_luaL_loadstring)dlsym(lib, "luaL_loadstring");
            g_lua.luaL_loadbuffer       = (pfn_luaL_loadbuffer)dlsym(lib, "luaL_loadbuffer");
            g_lua.lua_pcall             = (pfn_lua_pcall)dlsym(lib, "lua_pcall");
            g_lua.lua_tolstring         = (pfn_lua_tolstring)dlsym(lib, "lua_tolstring");
            g_lua.lua_tonumber          = (pfn_lua_tonumber)dlsym(lib, "lua_tonumber");
            g_lua.lua_touserdata        = (pfn_lua_touserdata)dlsym(lib, "lua_touserdata");
            g_lua.lua_pushnumber        = (pfn_lua_pushnumber)dlsym(lib, "lua_pushnumber");
            g_lua.lua_pushlightuserdata = (pfn_lua_pushlightuserdata)dlsym(lib, "lua_pushlightuserdata");
            g_lua.lua_getfield          = (pfn_lua_getfield)dlsym(lib, "lua_getfield");
            g_lua.lua_settop            = (pfn_lua_settop)dlsym(lib, "lua_settop");
            g_lua.lua_type              = (pfn_lua_type)dlsym(lib, "lua_type");
        }
    }
    g_lua.initialized = true;
}

/* -------------------------------------------------------------------------
 * Task Structures & Thread Pool
 * ------------------------------------------------------------------------- */

typedef enum {
    LUTHON_TASK_C = 0,
    LUTHON_TASK_LUA = 1,
    LUTHON_TASK_BYTECODE = 2
} TaskKind;

typedef struct TaskRecord TaskRecord;
struct TaskRecord {
    uint64_t        id;
    TaskKind        kind;
    luthon_task_fn  c_fn;
    void           *arg;
    char           *lua_code;
    char           *lua_entry;
    char           *bytecode;
    size_t          bytecode_len;
    int             has_arg_num;
    double          arg_num;
    void           *result;
    double          num_result;
    int             is_num_result;
    int             error_code;
    char            error_msg[256];
    _Atomic int     done;
    pthread_mutex_t done_mutex;
    pthread_cond_t  done_cond;
    TaskRecord     *next;
};

typedef struct {
    pthread_t        thread;
    int              worker_id;
    LuthonThreadPool *pool;
    lua_State       *L;
} WorkerThread;

struct LuthonThreadPool {
    int              num_workers;
    WorkerThread    *workers;
    pthread_mutex_t  queue_mutex;
    pthread_cond_t   queue_cond;
    TaskRecord      *queue_head;
    TaskRecord      *queue_tail;
    bool             stop;
    _Atomic uint64_t next_task_id;
    char            *init_script;

    /* Task history / registry for completion queries */
    pthread_mutex_t  history_mutex;
    TaskRecord     **history;
    size_t           history_capacity;
    size_t           history_count;
};

static void* worker_loop(void *arg) {
    WorkerThread *self = (WorkerThread*)arg;
    LuthonThreadPool *pool = self->pool;

    /* Initialize worker thread's isolated Lua state */
    init_lua_bindings();
    if (g_lua.luaL_newstate) {
        self->L = g_lua.luaL_newstate();
        if (self->L && g_lua.luaL_openlibs) {
            g_lua.luaL_openlibs(self->L);
        }
        if (self->L) {
            pthread_mutex_lock(&pool->queue_mutex);
            const char *init = pool->init_script;
            char *init_copy = init ? strdup(init) : NULL;
            pthread_mutex_unlock(&pool->queue_mutex);
            if (init_copy) {
                if (g_lua.luaL_loadstring && g_lua.lua_pcall) {
                    if (g_lua.luaL_loadstring(self->L, init_copy) == 0) {
                        g_lua.lua_pcall(self->L, 0, 0, 0);
                    }
                }
                free(init_copy);
            }
        }
    }

    while (1) {
        pthread_mutex_lock(&pool->queue_mutex);
        while (!pool->stop && pool->queue_head == NULL) {
            pthread_cond_wait(&pool->queue_cond, &pool->queue_mutex);
        }

        if (pool->stop && pool->queue_head == NULL) {
            pthread_mutex_unlock(&pool->queue_mutex);
            break;
        }

        TaskRecord *task = pool->queue_head;
        if (task) {
            pool->queue_head = task->next;
            if (pool->queue_head == NULL) {
                pool->queue_tail = NULL;
            }
        }
        pthread_mutex_unlock(&pool->queue_mutex);

        if (!task) continue;

        /* Execute task */
        if (task->kind == LUTHON_TASK_C) {
            if (task->c_fn) {
                task->result = task->c_fn(task->arg);
                task->error_code = 0;
            } else {
                task->error_code = -1;
                snprintf(task->error_msg, sizeof(task->error_msg), "Null function pointer");
            }
        } else if (task->kind == LUTHON_TASK_BYTECODE) {
            if (self->L && g_lua.luaL_loadbuffer && g_lua.lua_pcall) {
                lua_State *L = self->L;
                int status = g_lua.luaL_loadbuffer(L, task->bytecode, task->bytecode_len, "task");
                if (status == 0) {
                    int nargs = 0;
                    if (task->has_arg_num) {
                        g_lua.lua_pushnumber(L, task->arg_num);
                        nargs++;
                    }
                    if (task->arg) {
                        g_lua.lua_pushlightuserdata(L, task->arg);
                        nargs++;
                    }
                    status = g_lua.lua_pcall(L, nargs, 1, 0);
                }
                if (status == 0) {
                    int rtype = g_lua.lua_type(L, -1);
                    if (rtype == 3 /* LUA_TNUMBER */) {
                        task->num_result = g_lua.lua_tonumber(L, -1);
                        task->is_num_result = 1;
                        task->result = (void*)(intptr_t)(int64_t)task->num_result;
                    } else if (rtype == 2 /* LUA_TLIGHTUSERDATA */ || rtype == 7 /* LUA_TUSERDATA */) {
                        task->result = g_lua.lua_touserdata(L, -1);
                    }
                    task->error_code = 0;
                } else {
                    task->error_code = status;
                    const char *err = g_lua.lua_tolstring(L, -1, NULL);
                    snprintf(task->error_msg, sizeof(task->error_msg), "%s", err ? err : "Bytecode execution failed");
                }
                g_lua.lua_settop(L, 0);
            } else {
                task->error_code = -1;
                snprintf(task->error_msg, sizeof(task->error_msg), "Lua runtime not initialized");
            }
        } else if (task->kind == LUTHON_TASK_LUA) {
            if (self->L && g_lua.luaL_loadstring && g_lua.lua_pcall) {
                lua_State *L = self->L;
                int status = 0;
                if (task->lua_code && strlen(task->lua_code) > 0) {
                    status = g_lua.luaL_loadstring(L, task->lua_code);
                    if (status == 0) {
                        status = g_lua.lua_pcall(L, 0, 0, 0);
                    }
                }
                if (status == 0 && task->lua_entry) {
                    g_lua.lua_getfield(L, -10002 /* LUA_GLOBALSINDEX */, task->lua_entry);
                    if (g_lua.lua_type(L, -1) == 6 /* LUA_TFUNCTION */) {
                        if (task->arg) {
                            g_lua.lua_pushlightuserdata(L, task->arg);
                            status = g_lua.lua_pcall(L, 1, 1, 0);
                        } else {
                            status = g_lua.lua_pcall(L, 0, 1, 0);
                        }
                        if (status == 0) {
                            task->num_result = g_lua.lua_tonumber(L, -1);
                            task->is_num_result = 1;
                            task->result = (void*)(intptr_t)(int64_t)task->num_result;
                            task->error_code = 0;
                        }
                    } else {
                        status = -2;
                        snprintf(task->error_msg, sizeof(task->error_msg),
                                 "Entry function '%s' not found", task->lua_entry);
                    }
                }
                if (status != 0 && task->error_msg[0] == '\0') {
                    task->error_code = status;
                    const char *err = g_lua.lua_tolstring(L, -1, NULL);
                    snprintf(task->error_msg, sizeof(task->error_msg), "%s", err ? err : "Lua execution failed");
                }
                g_lua.lua_settop(L, 0);
            } else {
                task->error_code = -1;
                snprintf(task->error_msg, sizeof(task->error_msg), "Lua runtime not initialized");
            }
        }

        /* Mark task done and signal waiters */
        pthread_mutex_lock(&task->done_mutex);
        atomic_store(&task->done, 1);
        pthread_cond_broadcast(&task->done_cond);
        pthread_mutex_unlock(&task->done_mutex);
    }

    if (self->L && g_lua.lua_close) {
        g_lua.lua_close(self->L);
        self->L = NULL;
    }
    return NULL;
}

LuthonThreadPool* luthon_threadpool_create(int num_workers) {
    if (num_workers <= 0) num_workers = 4;

    LuthonThreadPool *pool = (LuthonThreadPool*)calloc(1, sizeof(LuthonThreadPool));
    if (!pool) return NULL;

    pool->num_workers = num_workers;
    pool->workers = (WorkerThread*)calloc(num_workers, sizeof(WorkerThread));
    if (!pool->workers) {
        free(pool);
        return NULL;
    }

    pthread_mutex_init(&pool->queue_mutex, NULL);
    pthread_cond_init(&pool->queue_cond, NULL);
    pthread_mutex_init(&pool->history_mutex, NULL);

    pool->history_capacity = 256;
    pool->history = (TaskRecord**)calloc(pool->history_capacity, sizeof(TaskRecord*));
    atomic_init(&pool->next_task_id, 1);
    pool->init_script = strdup("package.path = 'src/luthon/lua/?.lua;./src/luthon/lua/?.lua;' .. package.path; pcall(require, 'bootstrap')");

    for (int i = 0; i < num_workers; i++) {
        pool->workers[i].worker_id = i;
        pool->workers[i].pool = pool;
        pool->workers[i].L = NULL;
        pthread_create(&pool->workers[i].thread, NULL, worker_loop, &pool->workers[i]);
    }

    return pool;
}

void luthon_threadpool_set_init_script(LuthonThreadPool *pool, const char *script) {
    if (!pool) return;
    pthread_mutex_lock(&pool->queue_mutex);
    if (pool->init_script) free(pool->init_script);
    pool->init_script = script ? strdup(script) : NULL;
    pthread_mutex_unlock(&pool->queue_mutex);
}

int luthon_threadpool_worker_count(const LuthonThreadPool *pool) {
    return pool ? pool->num_workers : 0;
}

static void register_task(LuthonThreadPool *pool, TaskRecord *task) {
    pthread_mutex_lock(&pool->history_mutex);
    if (pool->history_count >= pool->history_capacity) {
        size_t new_cap = pool->history_capacity * 2;
        TaskRecord **new_hist = (TaskRecord**)realloc(pool->history, sizeof(TaskRecord*) * new_cap);
        if (new_hist) {
            pool->history = new_hist;
            pool->history_capacity = new_cap;
        }
    }
    if (pool->history_count < pool->history_capacity) {
        pool->history[pool->history_count++] = task;
    }
    pthread_mutex_unlock(&pool->history_mutex);
}

static TaskRecord* find_task(LuthonThreadPool *pool, uint64_t task_id) {
    pthread_mutex_lock(&pool->history_mutex);
    for (size_t i = 0; i < pool->history_count; i++) {
        if (pool->history[i] && pool->history[i]->id == task_id) {
            TaskRecord *found = pool->history[i];
            pthread_mutex_unlock(&pool->history_mutex);
            return found;
        }
    }
    pthread_mutex_unlock(&pool->history_mutex);
    return NULL;
}

uint64_t luthon_threadpool_submit(LuthonThreadPool *pool, luthon_task_fn fn, void *arg) {
    if (!pool || !fn) return 0;

    TaskRecord *task = (TaskRecord*)calloc(1, sizeof(TaskRecord));
    if (!task) return 0;

    task->id = atomic_fetch_add(&pool->next_task_id, 1);
    task->kind = LUTHON_TASK_C;
    task->c_fn = fn;
    task->arg = arg;
    atomic_init(&task->done, 0);
    pthread_mutex_init(&task->done_mutex, NULL);
    pthread_cond_init(&task->done_cond, NULL);

    register_task(pool, task);

    pthread_mutex_lock(&pool->queue_mutex);
    if (pool->queue_tail) {
        pool->queue_tail->next = task;
        pool->queue_tail = task;
    } else {
        pool->queue_head = task;
        pool->queue_tail = task;
    }
    pthread_cond_signal(&pool->queue_cond);
    pthread_mutex_unlock(&pool->queue_mutex);

    return task->id;
}

uint64_t luthon_threadpool_submit_bytecode(LuthonThreadPool *pool, const char *bytecode, size_t bytecode_len, int has_arg_num, double arg_num, void *arg_ptr) {
    if (!pool || !bytecode || bytecode_len == 0) return 0;

    TaskRecord *task = (TaskRecord*)calloc(1, sizeof(TaskRecord));
    if (!task) return 0;

    task->id = atomic_fetch_add(&pool->next_task_id, 1);
    task->kind = LUTHON_TASK_BYTECODE;
    task->bytecode = (char*)malloc(bytecode_len);
    if (task->bytecode) {
        memcpy(task->bytecode, bytecode, bytecode_len);
    }
    task->bytecode_len = bytecode_len;
    task->has_arg_num = has_arg_num;
    task->arg_num = arg_num;
    task->arg = arg_ptr;
    atomic_init(&task->done, 0);
    pthread_mutex_init(&task->done_mutex, NULL);
    pthread_cond_init(&task->done_cond, NULL);

    register_task(pool, task);

    pthread_mutex_lock(&pool->queue_mutex);
    if (pool->queue_tail) {
        pool->queue_tail->next = task;
        pool->queue_tail = task;
    } else {
        pool->queue_head = task;
        pool->queue_tail = task;
    }
    pthread_cond_signal(&pool->queue_cond);
    pthread_mutex_unlock(&pool->queue_mutex);

    return task->id;
}

uint64_t luthon_threadpool_submit_lua(LuthonThreadPool *pool, const char *code, const char *entry_func, void *arg) {
    if (!pool || !entry_func) return 0;

    TaskRecord *task = (TaskRecord*)calloc(1, sizeof(TaskRecord));
    if (!task) return 0;

    task->id = atomic_fetch_add(&pool->next_task_id, 1);
    task->kind = LUTHON_TASK_LUA;
    task->lua_code = code ? strdup(code) : NULL;
    task->lua_entry = strdup(entry_func);
    task->arg = arg;
    atomic_init(&task->done, 0);
    pthread_mutex_init(&task->done_mutex, NULL);
    pthread_cond_init(&task->done_cond, NULL);

    register_task(pool, task);

    pthread_mutex_lock(&pool->queue_mutex);
    if (pool->queue_tail) {
        pool->queue_tail->next = task;
        pool->queue_tail = task;
    } else {
        pool->queue_head = task;
        pool->queue_tail = task;
    }
    pthread_cond_signal(&pool->queue_cond);
    pthread_mutex_unlock(&pool->queue_mutex);

    return task->id;
}

bool luthon_threadpool_is_done(LuthonThreadPool *pool, uint64_t task_id) {
    if (!pool) return false;
    TaskRecord *task = find_task(pool, task_id);
    if (!task) return false;
    return atomic_load(&task->done) != 0;
}

void* luthon_threadpool_wait(LuthonThreadPool *pool, uint64_t task_id, int *out_error) {
    if (!pool) {
        if (out_error) *out_error = -1;
        return NULL;
    }
    TaskRecord *task = find_task(pool, task_id);
    if (!task) {
        if (out_error) *out_error = -1;
        return NULL;
    }

    pthread_mutex_lock(&task->done_mutex);
    while (atomic_load(&task->done) == 0) {
        pthread_cond_wait(&task->done_cond, &task->done_mutex);
    }
    pthread_mutex_unlock(&task->done_mutex);

    if (out_error) {
        *out_error = task->error_code;
    }
    return task->result;
}

double luthon_threadpool_wait_number(LuthonThreadPool *pool, uint64_t task_id, int *out_error) {
    if (!pool) {
        if (out_error) *out_error = -1;
        return 0.0;
    }
    TaskRecord *task = find_task(pool, task_id);
    if (!task) {
        if (out_error) *out_error = -1;
        return 0.0;
    }

    pthread_mutex_lock(&task->done_mutex);
    while (atomic_load(&task->done) == 0) {
        pthread_cond_wait(&task->done_cond, &task->done_mutex);
    }
    pthread_mutex_unlock(&task->done_mutex);

    if (out_error) {
        *out_error = task->error_code;
    }
    return task->num_result;
}

const char* luthon_threadpool_get_error(LuthonThreadPool *pool, uint64_t task_id) {
    if (!pool) return "Invalid pool";
    TaskRecord *task = find_task(pool, task_id);
    if (!task) return "Task not found";
    return task->error_msg[0] ? task->error_msg : NULL;
}

void luthon_threadpool_destroy(LuthonThreadPool *pool) {
    if (!pool) return;

    pthread_mutex_lock(&pool->queue_mutex);
    pool->stop = true;
    pthread_cond_broadcast(&pool->queue_cond);
    pthread_mutex_unlock(&pool->queue_mutex);

    for (int i = 0; i < pool->num_workers; i++) {
        pthread_join(pool->workers[i].thread, NULL);
    }

    free(pool->workers);
    pthread_mutex_destroy(&pool->queue_mutex);
    pthread_cond_destroy(&pool->queue_cond);

    pthread_mutex_lock(&pool->history_mutex);
    for (size_t i = 0; i < pool->history_count; i++) {
        TaskRecord *t = pool->history[i];
        if (t) {
            if (t->lua_code) free(t->lua_code);
            if (t->lua_entry) free(t->lua_entry);
            if (t->bytecode) free(t->bytecode);
            pthread_mutex_destroy(&t->done_mutex);
            pthread_cond_destroy(&t->done_cond);
            free(t);
        }
    }
    free(pool->history);
    pthread_mutex_unlock(&pool->history_mutex);
    pthread_mutex_destroy(&pool->history_mutex);

    if (pool->init_script) free(pool->init_script);
    free(pool);
}

/* -------------------------------------------------------------------------
 * 3. Dedicated OS Threads (threading.Thread)
 * ------------------------------------------------------------------------- */

typedef struct {
    pthread_t   thread;
    char       *bytecode;
    size_t      bytecode_len;
    double      arg_num;
    void       *arg_ptr;
    lua_State  *L;
    _Atomic int done;
} DedicatedThread;

static void* dedicated_worker(void *arg) {
    DedicatedThread *dt = (DedicatedThread*)arg;
    init_lua_bindings();
    if (g_lua.luaL_newstate) {
        dt->L = g_lua.luaL_newstate();
        if (dt->L) {
            if (g_lua.luaL_openlibs) g_lua.luaL_openlibs(dt->L);
            if (g_lua.luaL_loadstring && g_lua.lua_pcall) {
                const char *init = "package.path = 'src/luthon/lua/?.lua;./src/luthon/lua/?.lua;' .. package.path; pcall(require, 'bootstrap')";
                if (g_lua.luaL_loadstring(dt->L, init) == 0) {
                    g_lua.lua_pcall(dt->L, 0, 0, 0);
                }
            }
            if (dt->bytecode && g_lua.luaL_loadbuffer && g_lua.lua_pcall) {
                if (g_lua.luaL_loadbuffer(dt->L, dt->bytecode, dt->bytecode_len, "thread") == 0) {
                    int nargs = 0;
                    if (dt->arg_num != 0.0) {
                        g_lua.lua_pushnumber(dt->L, dt->arg_num);
                        nargs++;
                    }
                    if (dt->arg_ptr) {
                        g_lua.lua_pushlightuserdata(dt->L, dt->arg_ptr);
                        nargs++;
                    }
                    g_lua.lua_pcall(dt->L, nargs, 0, 0);
                }
            }
            if (g_lua.lua_close) {
                g_lua.lua_close(dt->L);
                dt->L = NULL;
            }
        }
    }
    atomic_store(&dt->done, 1);
    return NULL;
}

void* luthon_dedicated_thread_create(const char *bytecode, size_t len, double arg_num, void *arg_ptr) {
    DedicatedThread *dt = (DedicatedThread*)calloc(1, sizeof(DedicatedThread));
    if (!dt) return NULL;
    if (bytecode && len > 0) {
        dt->bytecode = (char*)malloc(len);
        if (dt->bytecode) memcpy(dt->bytecode, bytecode, len);
        dt->bytecode_len = len;
    }
    dt->arg_num = arg_num;
    dt->arg_ptr = arg_ptr;
    atomic_init(&dt->done, 0);
    pthread_create(&dt->thread, NULL, dedicated_worker, dt);
    return dt;
}

void luthon_dedicated_thread_join(void *handle) {
    if (!handle) return;
    DedicatedThread *dt = (DedicatedThread*)handle;
    pthread_join(dt->thread, NULL);
    if (dt->bytecode) free(dt->bytecode);
    free(dt);
}

bool luthon_dedicated_thread_is_alive(void *handle) {
    if (!handle) return false;
    DedicatedThread *dt = (DedicatedThread*)handle;
    return atomic_load(&dt->done) == 0;
}

/* -------------------------------------------------------------------------
 * 4. Thread Synchronization Primitives
 * ------------------------------------------------------------------------- */

struct LuthonMutex {
    pthread_mutex_t mutex;
    bool            recursive;
};

LuthonMutex* luthon_mutex_create(bool recursive) {
    LuthonMutex *m = (LuthonMutex*)malloc(sizeof(LuthonMutex));
    if (!m) return NULL;
    m->recursive = recursive;

    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    if (recursive) {
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    }
    pthread_mutex_init(&m->mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    return m;
}

bool luthon_mutex_lock(LuthonMutex *m) {
    if (!m) return false;
    return pthread_mutex_lock(&m->mutex) == 0;
}

bool luthon_mutex_trylock(LuthonMutex *m) {
    if (!m) return false;
    return pthread_mutex_trylock(&m->mutex) == 0;
}

bool luthon_mutex_unlock(LuthonMutex *m) {
    if (!m) return false;
    return pthread_mutex_unlock(&m->mutex) == 0;
}

void luthon_mutex_destroy(LuthonMutex *m) {
    if (!m) return;
    pthread_mutex_destroy(&m->mutex);
    free(m);
}

struct LuthonEvent {
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
    bool            flag;
};

LuthonEvent* luthon_event_create(bool initial_state) {
    LuthonEvent *e = (LuthonEvent*)malloc(sizeof(LuthonEvent));
    if (!e) return NULL;
    pthread_mutex_init(&e->mutex, NULL);
    pthread_cond_init(&e->cond, NULL);
    e->flag = initial_state;
    return e;
}

void luthon_event_set(LuthonEvent *e) {
    if (!e) return;
    pthread_mutex_lock(&e->mutex);
    e->flag = true;
    pthread_cond_broadcast(&e->cond);
    pthread_mutex_unlock(&e->mutex);
}

void luthon_event_clear(LuthonEvent *e) {
    if (!e) return;
    pthread_mutex_lock(&e->mutex);
    e->flag = false;
    pthread_mutex_unlock(&e->mutex);
}

bool luthon_event_is_set(LuthonEvent *e) {
    if (!e) return false;
    pthread_mutex_lock(&e->mutex);
    bool state = e->flag;
    pthread_mutex_unlock(&e->mutex);
    return state;
}

bool luthon_event_wait(LuthonEvent *e, double timeout_sec) {
    if (!e) return false;
    pthread_mutex_lock(&e->mutex);

    if (e->flag) {
        pthread_mutex_unlock(&e->mutex);
        return true;
    }

    if (timeout_sec <= 0.0) {
        while (!e->flag) {
            pthread_cond_wait(&e->cond, &e->mutex);
        }
        pthread_mutex_unlock(&e->mutex);
        return true;
    }

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long sec = (long)timeout_sec;
    long nsec = (long)((timeout_sec - sec) * 1e9);
    ts.tv_sec += sec;
    ts.tv_nsec += nsec;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    int rc = 0;
    while (!e->flag && rc == 0) {
        rc = pthread_cond_timedwait(&e->cond, &e->mutex, &ts);
    }
    bool state = e->flag;
    pthread_mutex_unlock(&e->mutex);
    return state;
}

void luthon_event_destroy(LuthonEvent *e) {
    if (!e) return;
    pthread_mutex_destroy(&e->mutex);
    pthread_cond_destroy(&e->cond);
    free(e);
}

struct LuthonSemaphore {
    sem_t sem;
};

LuthonSemaphore* luthon_semaphore_create(int initial_value) {
    if (initial_value < 0) initial_value = 0;
    LuthonSemaphore *s = (LuthonSemaphore*)malloc(sizeof(LuthonSemaphore));
    if (!s) return NULL;
    sem_init(&s->sem, 0, (unsigned int)initial_value);
    return s;
}

bool luthon_semaphore_acquire(LuthonSemaphore *s, double timeout_sec) {
    if (!s) return false;
    if (timeout_sec <= 0.0) {
        return sem_wait(&s->sem) == 0;
    }

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long sec = (long)timeout_sec;
    long nsec = (long)((timeout_sec - sec) * 1e9);
    ts.tv_sec += sec;
    ts.tv_nsec += nsec;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }
    return sem_timedwait(&s->sem, &ts) == 0;
}

void luthon_semaphore_release(LuthonSemaphore *s) {
    if (!s) return;
    sem_post(&s->sem);
}

int luthon_semaphore_get_value(LuthonSemaphore *s) {
    if (!s) return 0;
    int val = 0;
    sem_getvalue(&s->sem, &val);
    return val;
}

void luthon_semaphore_destroy(LuthonSemaphore *s) {
    if (!s) return;
    sem_destroy(&s->sem);
    free(s);
}
