/**
 * @file Parataxis.c
 * @brief Low-level Green Threads (Fibers) and Hybrid Thread Pool for Perl.
 *
 * @section Overview
 * This file implements a cooperative multitasking system (Fibers) integrated
 * with a preemptive native thread pool. It allows Perl to run thousands of
 * user-mode fibers that can offload blocking C-level tasks to background
 * OS threads without stalling the main interpreter.
 *
 * @section Architecture
 * - **Fibers**: The primitive unit of execution. Each fiber has its own OS context
 *   and a complete set of Perl interpreter stacks (Argument, Mark, Scope, Save, Mortal).
 * - **Coroutines**: The execution pattern (yield/call/transfer) used by fibers to
 *   pass control.
 * - **Thread Pool**: A fixed pool of worker threads that poll a job queue for
 *   blocking operations like sleep, I/O, or heavy computation.
 * - **Context Switching**: The `swap_perl_state` function manually saves and restores
 *   the global state of the Perl interpreter (`PL_*` variables) to allow disjoint
 *   execution flows.
 *
 * @section Caveats
 * Shared subroutines (CVs) with re-entrant yielding calls are handled by a
 * specialized pad-clearing mechanism in `_activate_current_depths` to satisfy
 * Perl's internal `AvFILLp` assertions in debug builds.
 */

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#else
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif
#endif

#define PERL_NO_GET_CONTEXT
#define NO_XSLOCKS
#include "EXTERN.h"
#include "XSUB.h"
#include "perl.h"

#ifdef _WIN32
/** @brief Export macro for Windows DLLs */
#define DLLEXPORT __declspec(dllexport)
/** @brief Handle for the underlying OS fiber context */
typedef LPVOID coro_handle_t;
/** @brief Handle for a native OS thread */
typedef HANDLE para_thread_t;
/** @brief Mutex type for queue synchronization */
typedef CRITICAL_SECTION para_mutex_t;
#define LOCK(m) EnterCriticalSection(&m)
#define UNLOCK(m) LeaveCriticalSection(&m)
#define LOCK_INIT(m) InitializeCriticalSection(&m)
#else
#include <pthread.h>
#include <sched.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>
#if defined(__APPLE__) || defined(__FreeBSD__)
#include <sys/sysctl.h>
#include <sys/types.h>
#endif
/** @brief Export macro for Unix systems */
#define DLLEXPORT __attribute__((visibility("default")))
/** @brief Handle for the underlying OS fiber context (ucontext_t) */
typedef ucontext_t coro_handle_t;
/** @brief Handle for a native OS thread (pthread_t) */
typedef pthread_t para_thread_t;
/** @brief Mutex type for queue synchronization (pthread_mutex_t) */
typedef pthread_mutex_t para_mutex_t;
#define LOCK(m) pthread_mutex_lock(&m)
#define UNLOCK(m) pthread_mutex_unlock(&m)
#define LOCK_INIT(m) pthread_mutex_init(&m, NULL)
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Forward declarations
DLLEXPORT SV * coro_yield(SV * ret_val);
DLLEXPORT SV * coro_transfer(int fiber_id, SV * args);
DLLEXPORT void destroy_coro(int fiber_id);

/*
 * Assembly-based coroutine context switching.
 *
 * glibc's swapcontext() saves/restores the signal mask (rt_sigprocmask) on
 * every context switch which dominates the cost of fiber switches.  On
 * x86_64 we instead switch with a tiny assembly routine that only saves the
 * callee-saved registers and the stack pointer, avoiding the syscall
 * entirely.  All other platforms keep the portable ucontext path.
 */
#if defined(__x86_64__) && !defined(_WIN32) && defined(__ELF__)
#define USE_ASM_CORO 1
#endif

typedef struct para_fiber_t para_fiber_t;

/* C-level entry point invoked when a freshly created fiber starts running. */
void para_entry_point(para_fiber_t * c);

#if defined(USE_ASM_CORO)
/**
 * @brief Raw register-only context switch.
 *
 * Saves the callee-saved registers and the current stack pointer into
 * *from, restores them from *to, then returns (popping the return address
 * off the target stack).  A freshly created fiber's stack is pre-arranged
 * so that the return address lands in para_trampoline.
 *
 * @param from Pointer to the storage slot holding the current stack pointer.
 * @param to   Pointer to the storage slot holding the target stack pointer.
 */
extern void para_coro_switch(void ** from, void ** to);
/** @brief Initial jump target for brand-new fiber stacks. */
extern void para_trampoline(void);

__asm__(
    ".text\n"
    ".p2align 4\n"
    ".globl para_coro_switch\n"
    ".type para_coro_switch, @function\n"
    "para_coro_switch:\n"
    "    pushq %rbx\n"
    "    pushq %rbp\n"
    "    pushq %r12\n"
    "    pushq %r13\n"
    "    pushq %r14\n"
    "    pushq %r15\n"
    "    movq %rsp, (%rdi)\n"
    "    movq (%rsi), %rsp\n"
    "    popq %r15\n"
    "    popq %r14\n"
    "    popq %r13\n"
    "    popq %r12\n"
    "    popq %rbp\n"
    "    popq %rbx\n"
    "    ret\n"
    ".size para_coro_switch, .-para_coro_switch\n"
    ".p2align 4\n"
    ".globl para_trampoline\n"
    ".type para_trampoline, @function\n"
    "para_trampoline:\n"
    "    popq %rdi\n"
    "    call para_entry_point\n"
    "    ud2\n"
    ".size para_trampoline, .-para_trampoline\n"
);
#endif /* USE_ASM_CORO */

/**
 * @brief Get the Operating System's unique Thread ID.
 *
 * Useful for debugging to prove that background tasks are running on
 * different OS threads than the main Perl interpreter.
 *
 * @return int The TID (Windows) or LWP ID (Linux/BSD/macOS).
 */
int get_os_thread_id() {
#ifdef _WIN32
    return (int)GetCurrentThreadId();
#elif defined(__APPLE__)
    uint64_t tid;
    pthread_threadid_np(NULL, &tid);
    return (int)tid;
#elif defined(SYS_gettid)
    return (int)syscall(SYS_gettid);
#else
    return (int)(intptr_t)pthread_self();
#endif
}

/**
 * @brief Pin the current thread to a specific CPU core.
 *
 * Used by the Thread Pool to ensure worker threads are distributed
 * across available hardware cores for maximum parallelism.
 *
 * @param core_id The zero-based index of the CPU core.
 */
void pin_to_core(int core_id) {
#ifdef _WIN32
    DWORD_PTR mask = (1ULL << core_id);
    SetThreadAffinityMask(GetCurrentThread(), mask);
#elif defined(__linux__)
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
#else
    (void)core_id; /* Not supported on macOS/BSD standard APIs */
#endif
}

/**
 * @brief Get the index of the CPU core currently executing this thread.
 *
 * @return int Core ID (0..N) or -1 if unsupported.
 */
int get_current_cpu() {
#ifdef _WIN32
    return GetCurrentProcessorNumber();
#elif defined(__linux__)
    return sched_getcpu();
#else
    return -1;
#endif
}

/**
 * @brief Detects the number of logical cores available on the system.
 *
 * @return int CPU count (minimum 1).
 */
int get_cpu_count() {
#ifdef _WIN32
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    int count = sysinfo.dwNumberOfProcessors;
    return (count > 0) ? count : 1;
#elif defined(__APPLE__) || defined(__FreeBSD__)
    int nm[2];
    size_t len = 4;
    uint32_t count;
    nm[0] = CTL_HW;
    nm[1] = HW_NCPU;
    sysctl(nm, 2, &count, &len, NULL, 0);
    return (count > 0) ? (int)count : 1;
#else
    long count = sysconf(_SC_NPROCESSORS_ONLN);
    return (count > 0) ? (int)count : 1;
#endif
}

/**
 * @struct para_fiber_t
 * @brief The complete execution context of a Perl Fiber.
 *
 * This structure encapsulates both the OS-level register state (via context)
 * and the entire internal state of the Perl interpreter required to pause
 * and resume execution of Perl code.
 */
typedef struct para_fiber_t {
    coro_handle_t context; /**< OS-specific context handle */

#ifndef _WIN32
    void * stack_p;  /**< Pointer to dynamically allocated fiber stack (Unix only) */
    size_t stack_sz; /**< Size of the allocated stack (Unix only) */
#ifdef USE_ASM_CORO
    void * rsp;      /**< Saved stack pointer for the assembly switch (Unix x86_64) */
#endif
#endif

    void * _stacks_block; /**< Single allocation holding the Perl control stacks */


    /*
     * Perl Interpreter State Pointers.
     * These must be saved and restored during every context switch.
     */
    PERL_SI * si;            /**< Current Stack Info (tracks recursion and eval frames) */
    AV * curstack;           /**< The active Argument Stack (AV*) */
    SSize_t stack_sp_offset; /**< Stack Pointer offset from stack base */

    I32 * markstack;     /**< Base of the Mark Stack (tracks list start points) */
    I32 * markstack_ptr; /**< Current pointer into the Mark Stack */
    I32 * markstack_max; /**< Limit of the Mark Stack */

    I32 * scopestack;   /**< Base of the Scope Stack (tracks block nesting) */
    I32 scopestack_ix;  /**< Current index in the Scope Stack */
    I32 scopestack_max; /**< Limit of the Scope Stack */

    ANY * savestack;   /**< Base of the Save Stack (tracks local/my variables for cleanup) */
    I32 savestack_ix;  /**< Current index in the Save Stack */
    I32 savestack_max; /**< Limit of the Save Stack */

    SV ** tmps_stack; /**< Base of the Mortal Stack (tracks SVs needing refcnt decrement) */
    I32 tmps_ix;      /**< Current index in the Mortal Stack */
    I32 tmps_floor;   /**< Current floor of the Mortal Stack */
    I32 tmps_max;     /**< Limit of the Mortal Stack */

    JMPENV * top_env;   /**< Pointer to the top exception environment (eval/die buffers) */
    COP * curcop;       /**< Current Op Pointer (location in the source/bytecode) */
    OP * op;            /**< Current Operation being executed */
    PAD * comppad;      /**< Current lexical Pad (variable storage) */
    SV ** curpad;       /**< Array pointer to the current lexical Pad */
    PMOP * curpm;       /**< Current pattern match state */
    PMOP * curpm_under; /**< Current pattern match state under */
    PMOP * reg_curpm;   /**< Current regex match state */

    GV * defgv;      /**< The $_ global */
    GV * last_in_gv; /**< GV used in last <FH> */
    SV * rs;         /**< The $/ global */
    GV * ofsgv;      /**< The $, global */
    SV * ors_sv;     /**< The $\ global */
    GV * defoutgv;   /**< The default output filehandle */
    HV * curstash;   /**< Current package stash */
    HV * defstash;   /**< Default package stash */
    SV * errors;     /**< Outstanding queued errors */

    SV * user_cv;  /**< The Perl sub/coderef this fiber is running */
    SV * self_ref; /**< The Acme::Parataxis Perl object wrapper */

    SV * transfer_data; /**< Arguments or return values passed during yield/transfer */

    int id;          /**< Numeric ID of this fiber */
    int finished;    /**< Flag: 1 if the fiber has completed its entry_point */
    int parent_id;   /**< ID of the fiber that 'called' this one (asymmetric) */
    int last_sender; /**< ID of the fiber that last switched control to this one */
} para_fiber_t;

/** @name Job Status Constants */
///@{
#define JOB_FREE 0 /**< Slot is available for new tasks */
#define JOB_NEW 1  /**< Task is submitted but not yet picked up by a worker */
#define JOB_BUSY 2 /**< Task is currently being processed by a worker thread */
#define JOB_DONE 3 /**< Task has completed and results are ready */
///@}

/** @name Task Type Constants */
///@{
#define TASK_SLEEP 0   /**< Sleep for N milliseconds */
#define TASK_GET_CPU 1 /**< Retrieve current core ID */
#define TASK_READ 2    /**< Wait for read-readiness on a file descriptor */
#define TASK_WRITE 3   /**< Wait for write-readiness on a file descriptor */
///@}

/**
 * @union value_t
 * @brief Generic container for task input/output data.
 */
typedef union {
    int64_t i; /**< Integer/Pointer storage */
    double d;  /**< Floating point storage */
    char * s;  /**< String storage */
} value_t;

/**
 * @struct job_t
 * @brief Represents a task in the background thread pool queue.
 */
typedef struct {
    int fiber_id;      /**< ID of the Fiber that submitted this task */
    int target_thread; /**< Index of the assigned worker thread */
    int type;          /**< Type of task to perform (TASK_*) */
    value_t input;     /**< Input data for the task */
    value_t output;    /**< Result data populated by the worker */
    int timeout_ms;    /**< Timeout duration for I/O tasks */
    int status;        /**< Current lifecycle state (JOB_*) */
} job_t;

// Global Registry and State

/** @brief Maximum number of concurrent fibers allowed */
#define MAX_FIBERS 1024
/** @brief Array of active fiber structures */
static para_fiber_t * fibers[MAX_FIBERS];
/** @brief LIFO of free fiber slot indexes (O(1) allocation) */
static int free_slots[MAX_FIBERS];
/** @brief Number of free slots currently on the free list */
static int free_slot_count = 0;
/** @brief Tracks whether the free list has been seeded with all slots */
static int free_slots_seeded = 0;
/** @brief The context representing the main Perl thread */
static para_fiber_t main_context;
/** @brief ID of the currently executing fiber (-1 for Main) */
static int current_fiber_id = -1;

/** @brief Size of the background job queue */
#define MAX_JOBS 1024
/** @brief Fixed-size array for background tasks */
static job_t job_slots[MAX_JOBS];
/** @brief Mutex protecting access to the job queue */
static para_mutex_t queue_lock;

/*
 * Completed-job notification ring.
 *
 * Workers push the index of every finished job into this ring so that
 * check_for_completion() can find completed work in O(1) instead of
 * scanning all MAX_JOBS slots under the lock on every scheduler tick.
 */
static int done_queue[MAX_JOBS + 1];
static int done_head = 0;
static int done_tail = 0;

/*
 * Number of jobs that have been submitted but not yet reclaimed by the
 * main thread via free_job_slot().  Only touched by the main thread, so it
 * needs no lock.  The scheduler uses it to skip polling entirely when no
 * background work is in flight.
 */
static int outstanding_jobs = 0;

#ifdef _WIN32
/** @brief Reuse cache for freed fiber stacks (Windows fibers allocate nothing) */
#define MAX_CACHED_STACKS 0
/** @brief Maximum number of fiber objects to park for reuse */
#define MAX_FIBER_CACHE 64
#else
/** @brief Maximum number of fiber stacks to keep around for reuse */
#define MAX_CACHED_STACKS 64
/** @brief LIFO cache of free fiber stack allocations */
static void * stack_cache[MAX_CACHED_STACKS];
/** @brief Number of stacks currently in the cache */
static int stack_cache_count = 0;

/** @brief Maximum number of whole fiber contexts to park for reuse */
#define MAX_FIBER_CACHE 64
/** @brief LIFO cache of idle fiber contexts (Perl stacks + OS stack included) */
static para_fiber_t * fiber_cache[MAX_FIBER_CACHE];
/** @brief Number of fiber contexts currently in the cache */
static int fiber_cache_count = 0;
#endif

#ifdef _WIN32
static CONDITION_VARIABLE queue_cond;
#else
static pthread_cond_t queue_cond;
#endif

static int threads_initialized = 0;
static int system_initialized = 0;

// Forward declarations for thread safety wrappers
#ifdef _WIN32
#define PARA_COND_WAIT(c, m) SleepConditionVariableCS(&c, &m, INFINITE)
#define PARA_COND_SIGNAL(c) WakeConditionVariable(&c)
#define PARA_COND_BROADCAST(c) WakeAllConditionVariable(&c)
#define PARA_COND_INIT(c) InitializeConditionVariable(&c)
#else
#define PARA_COND_WAIT(c, m) pthread_cond_wait(&c, &m)
#define PARA_COND_SIGNAL(c) pthread_cond_signal(&c)
#define PARA_COND_BROADCAST(c) pthread_cond_broadcast(&c)
#define PARA_COND_INIT(c) pthread_cond_init(&c, NULL)
#endif

/** @brief Threshold for automatic preemption (0 to disable) */
static long long preempt_threshold = 0;
/** @brief Count of operations since last preemption yield */
static long long preempt_count = 0;

/** @brief Maximum worker threads allowed in the pool */
#define MAX_THREADS 64
/** @brief Native OS handles for pool threads */
static para_thread_t thread_handles[MAX_THREADS];
/** @brief Maximum allowed threads in the pool */
static int max_thread_pool_size = 0;
/** @brief Number of currently running worker threads */
static int current_thread_count = 0;
/** @brief Flag to signal worker threads to terminate */
static volatile int threads_keep_running = 1;

#ifdef _WIN32
/** @brief Windows-only handle for the main thread converted to fiber */
static void * main_fiber_handle = NULL;
#endif

/** @brief Sets the maximum number of worker threads allowed in the pool. */
DLLEXPORT void set_max_threads(int max) {
    if (max > 0 && max <= MAX_THREADS)
        max_thread_pool_size = max;
}

/** @brief Forward declaration of worker_thread */
#ifdef _WIN32
DWORD WINAPI worker_thread(LPVOID arg);
#else
void * worker_thread(void * arg);
#endif

/** @brief Internal helper to spawn N threads into the pool */
static void _spawn_workers(int count) {
    for (int i = 0; i < count; i++) {
        if (current_thread_count >= max_thread_pool_size || current_thread_count >= MAX_THREADS)
            break;

        int tid = current_thread_count;
#ifdef _WIN32
        thread_handles[tid] = CreateThread(NULL, 0, worker_thread, (LPVOID)(intptr_t)tid, 0, NULL);
#else
        pthread_create(&thread_handles[tid], NULL, worker_thread, (void *)(intptr_t)tid);
        pthread_detach(thread_handles[tid]);
#endif
        current_thread_count++;
    }
}

/**
 * @brief Background Worker Thread Loop.
 *
 * Each thread pins itself to a core and continuously waits for jobs.
 *
 * @param arg Integer thread ID passed as a pointer.
 */
#ifdef _WIN32
DWORD WINAPI worker_thread(LPVOID arg) {
#else
void * worker_thread(void * arg) {
#endif
    int thread_id = (int)(intptr_t)arg;
    int cpu_count = get_cpu_count();
    pin_to_core(thread_id % cpu_count);

    while (threads_keep_running) {
        int found_idx = -1;

        LOCK(queue_lock);
        while (threads_keep_running) {
            for (int i = 0; i < MAX_JOBS; i++) {
                if (job_slots[i].status == JOB_NEW) {
                    job_slots[i].status = JOB_BUSY;
                    found_idx = i;
                    break;
                }
            }
            if (found_idx != -1 || !threads_keep_running)
                break;
            PARA_COND_WAIT(queue_cond, queue_lock);
        }
        UNLOCK(queue_lock);

        if (found_idx != -1 && threads_keep_running) {
            job_t * job = &job_slots[found_idx];
            // ... processing ...

            if (job->type == TASK_SLEEP) {
                int ms = (int)job->input.i;
#ifdef _WIN32
                Sleep(ms);
#else
                usleep(ms * 1000);
#endif
                job->output.i = ms;
            }
            else if (job->type == TASK_GET_CPU) {
                int cpu = get_current_cpu();
                job->output.i = cpu;
            }
            else if (job->type == TASK_READ || job->type == TASK_WRITE) {
                fd_set fds;
                FD_ZERO(&fds);
#ifdef _WIN32
                SOCKET s = (SOCKET)job->input.i;
                FD_SET(s, &fds);
#else
                int fd = (int)job->input.i;
                FD_SET(fd, &fds);
#endif
                struct timeval tv;
                int res;
                int elapsed_ms = 0;
                int timeout = job->timeout_ms > 0 ? job->timeout_ms : 5000;

                while (threads_keep_running) {
                    tv.tv_sec = 0;
                    tv.tv_usec = 10000;

                    fd_set work_fds = fds;
                    if (job->type == TASK_READ)
#ifdef _WIN32
                        res = select(0, &work_fds, NULL, NULL, &tv);
#else
                        res = select(fd + 1, &work_fds, NULL, NULL, &tv);
#endif
                    else
#ifdef _WIN32
                        res = select(0, NULL, &work_fds, NULL, &tv);
#else
                        res = select(fd + 1, NULL, &work_fds, NULL, &tv);
#endif

                    if (res != 0)
                        break;

                    elapsed_ms += 10;
                    if (elapsed_ms >= timeout)
                        break;
                }
                job->output.i = (res > 0) ? 1 : -1;
            }

            LOCK(queue_lock);
            job->status = JOB_DONE;
            done_queue[done_tail] = found_idx;
            done_tail = (done_tail + 1) % (MAX_JOBS + 1);
            UNLOCK(queue_lock);
        }
        else {
#ifdef _WIN32
            Sleep(1);
#else
            usleep(1000);
#endif
        }
    }
    return 0;
}

/**
 * @brief Initializes the background thread pool.
 *
 * Automatically detects the CPU count and spawns worker threads. This function
 * is called automatically by `init_system` and `submit_c_job`.
 */
DLLEXPORT void init_threads() {
    dTHX;
    if (threads_initialized)
        return;
    LOCK_INIT(queue_lock);
    PARA_COND_INIT(queue_cond);
    for (int i = 0; i < MAX_JOBS; i++)
        job_slots[i].status = JOB_FREE;

    if (max_thread_pool_size == 0) {
        max_thread_pool_size = get_cpu_count();
        if (max_thread_pool_size > MAX_THREADS)
            max_thread_pool_size = MAX_THREADS;
    }

    /* Start with a small "seed" pool of 2 threads */
    _spawn_workers(2);

    threads_initialized = 1;
}

/**
 * @brief Submits a C-level task to the background pool.
 *
 * @param type The task type constant (TASK_*).
 * @param arg Input integer or pointer data.
 * @param timeout_ms Timeout for I/O operations.
 * @return int The index of the submitted job, or -1 if the queue is full.
 */
DLLEXPORT int submit_c_job(int type, int64_t arg, int timeout_ms) {
    if (!threads_initialized)
        init_threads();
    int idx = -1;
    LOCK(queue_lock);

    /* Dynamic Scaling: If we have pending jobs and space in the pool, grow! */
    int pending_count = 0;
    for (int i = 0; i < MAX_JOBS; i++)
        if (job_slots[i].status == JOB_NEW)
            pending_count++;
    if (pending_count > 0 && current_thread_count < max_thread_pool_size)
        _spawn_workers(1); /* Grow by 1 on demand */

    for (int i = 0; i < MAX_JOBS; i++) {
        if (job_slots[i].status == JOB_FREE) {
            idx = i;
            break;
        }
    }
    if (idx != -1) {
        job_slots[idx].fiber_id = current_fiber_id;
        job_slots[idx].type = type;
        job_slots[idx].input.i = arg;
        job_slots[idx].timeout_ms = timeout_ms;
        job_slots[idx].status = JOB_NEW;
        outstanding_jobs++;
        PARA_COND_SIGNAL(queue_cond);
    }
    UNLOCK(queue_lock);
    return idx;
}

/**
 * @brief Polls the queue for any completed background jobs.
 *
 * @return int Index of a finished job, or -1 if none are ready.
 */
DLLEXPORT int check_for_completion() {
    if (!threads_initialized)
        init_threads();
    int job_idx = -1;
    LOCK(queue_lock);
    if (done_head != done_tail) {
        job_idx = done_queue[done_head];
        done_head = (done_head + 1) % (MAX_JOBS + 1);
    }
    UNLOCK(queue_lock);
    return job_idx;
}

/**
 * @brief Returns the number of background jobs not yet reclaimed.
 *
 * Only the main thread touches this counter, so it is a plain read.  The
 * scheduler uses it to skip polling entirely when no work is in flight.
 *
 * @return int Number of outstanding jobs.
 */
DLLEXPORT int get_outstanding_jobs() {
    return outstanding_jobs;
}

/**
 * @brief Retrieves the result of a completed job as a Perl SV.
 *
 * @param idx The job index in the queue.
 * @return SV* A mortalized Perl SV containing the result (IV).
 */
DLLEXPORT SV * get_job_result(int idx) {
    dTHX;
    if (idx < 0 || idx >= MAX_JOBS)
        return &PL_sv_undef;
    SV * res = &PL_sv_undef;
    LOCK(queue_lock);
    if (job_slots[idx].status == JOB_DONE || job_slots[idx].status == JOB_BUSY) {
        if (job_slots[idx].type == TASK_SLEEP || job_slots[idx].type == TASK_GET_CPU ||
            job_slots[idx].type == TASK_READ || job_slots[idx].type == TASK_WRITE) {
            res = newSViv(job_slots[idx].output.i);
            sv_2mortal(res);
        }
    }
    UNLOCK(queue_lock);
    return res;
}

/**
 * @brief Gets the ID of the Fiber that submitted a specific job.
 *
 * @param idx Job index.
 * @return int Fiber ID.
 */
DLLEXPORT int get_job_coro_id(int idx) {
    if (idx < 0 || idx >= MAX_JOBS)
        return -1;
    return job_slots[idx].fiber_id;
}

/**
 * @brief Frees a job slot in the queue after the result has been retrieved.
 *
 * @param idx Job index.
 */
DLLEXPORT void free_job_slot(int idx) {
    if (idx < 0 || idx >= MAX_JOBS)
        return;
    LOCK(queue_lock);
    job_slots[idx].status = JOB_FREE;
    outstanding_jobs--;
    UNLOCK(queue_lock);
}

/**
 * @brief Resets the call depth of a Perl CV to zero.
 *
 * Used to ensure that a newly created fiber starts its coderef with a
 * clean execution state.
 *
 * @param cv_ref SV reference to the coderef.
 */
DLLEXPORT void force_depth_zero(SV * cv_ref) {
    dTHX;
    CV * cv = NULL;
    if (SvROK(cv_ref))
        cv = (CV *)SvRV(cv_ref);
    else if (SvTYPE(cv_ref) == SVt_PVCV)
        cv = (CV *)cv_ref;
    if (cv && SvTYPE((SV *)cv) == SVt_PVCV)
        ((XPVCV *)MUTABLE_PTR(SvANY(cv)))->xcv_depth = 0;
}

/** @brief Returns the ID of the currently executing fiber. */
DLLEXPORT int get_current_parataxis_id() { return current_fiber_id; }
/** @brief Returns the OS-level thread ID of the main interpreter thread. */
DLLEXPORT int get_os_thread_id_export() { return get_os_thread_id(); }
/** @brief Returns the number of worker threads currently running in the pool. */
DLLEXPORT int get_thread_pool_size() { return current_thread_count; }
/** @brief Returns the maximum number of worker threads allowed in the pool. */
DLLEXPORT int get_max_thread_pool_size() { return max_thread_pool_size; }

/** @brief Sets the threshold for automatic yield-based preemption. */
DLLEXPORT void set_preempt_threshold(int64_t threshold) { preempt_threshold = threshold; }
/** @brief Returns the current count towards the preemption threshold. */
DLLEXPORT int64_t get_preempt_count() { return preempt_count; }

/**
 * @brief Checks if automatic preemption should occur.
 *
 * Increments the internal counter and triggers a `coro_yield` if the
 * threshold is reached.
 *
 * @return SV* Result of the yield, or undef if no yield occurred.
 */
DLLEXPORT SV * maybe_yield() {
    dTHX;
    preempt_count++;
    if (preempt_threshold > 0 && preempt_count >= preempt_threshold) {
        preempt_count = 0;
        return coro_yield(&PL_sv_undef);
    }
    return &PL_sv_undef;
}

/**
 * @brief Restores subroutine call depths and cleans argument pads.
 *
 * This function iterates the context stack and restores CvDEPTH for
 * active subroutines in two passes to safely handle recursive calls.
 *
 * Pass 1: Restores CvDEPTH for all active frames.
 * Pass 2: Surgicaly cleans Slot 0 of the *next* pad depth for each CV.
 *
 * @param to The fiber being resumed.
 */
static void _activate_current_depths(pTHX_ para_fiber_t * to) {
    PERL_SI * si = to->si;
    if (!si || !si->si_cxstack)
        return;

    /* Pass 1: Restore CvDEPTH for all active frames */
    for (I32 i = 0; i <= si->si_cxix; i++) {
        PERL_CONTEXT * cx = &(si->si_cxstack[i]);
        if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
            CV * cv = cx->blk_sub.cv;
            if (cv && SvTYPE((SV *)cv) == SVt_PVCV)
                CvDEPTH(cv) = cx->blk_sub.olddepth + 1;
        }
    }

    /* Pass 2: Clean the landing pads for the NEXT call in each CV */
    for (I32 i = 0; i <= si->si_cxix; i++) {
        PERL_CONTEXT * cx = &(si->si_cxstack[i]);
        if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
            CV * cv = cx->blk_sub.cv;
            if (cv && SvTYPE((SV *)cv) == SVt_PVCV) {
                PADLIST * pl = CvPADLIST(cv);
                I32 next_depth = CvDEPTH(cv) + 1;
                if (pl && next_depth <= PadlistMAX(pl)) {
                    AV * next_pad = (AV *)PadlistARRAY(pl)[next_depth];
                    if (next_pad && SvTYPE(next_pad) == SVt_PVAV) {
                        SV ** array = AvARRAY(next_pad);
                        if (array && AvMAX(next_pad) >= 0) {
                            SV * args = array[0];
                            if (args && SvTYPE(args) == SVt_PVAV) {
                                AvFILLp((AV *)args) = -1;
                                AvREAL_off((AV *)args);
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * @brief Swaps the internal Perl Interpreter state pointers.
 *
 * This is the core of the fiber implementation. It manually saves all
 * global pointers that define the "state" of the Perl virtual machine for
 * the current context and restores them for the target context.
 *
 * @param from Context being paused.
 * @param to Context being resumed.
 */
void swap_perl_state(para_fiber_t * from, para_fiber_t * to) {
    dTHX;
    /* Save current state into 'from' context */
    from->si = PL_curstackinfo;

    // The Argument Stack (Main Perl stack)
    from->curstack = PL_curstack;
    from->stack_sp_offset = PL_stack_sp - PL_stack_base;

    // The Mark Stack (Tracks where lists begin on the argument stack)
    from->markstack = PL_markstack;
    from->markstack_ptr = PL_markstack_ptr;
    from->markstack_max = PL_markstack_max;

    // The Scope Stack (Tracks block entry/exit for cleanup)
    from->scopestack = PL_scopestack;
    from->scopestack_ix = PL_scopestack_ix;
    from->scopestack_max = PL_scopestack_max;

    // The Save Stack (Tracks 'local' variables and destructors)
    from->savestack = PL_savestack;
    from->savestack_ix = PL_savestack_ix;
    from->savestack_max = PL_savestack_max;

    // The Mortal Stack (Tracks temporary SVs that need decrementing)
    from->tmps_stack = PL_tmps_stack;
    from->tmps_ix = PL_tmps_ix;
    from->tmps_floor = PL_tmps_floor;
    from->tmps_max = PL_tmps_max;

    // Exception Environment (setjmp/longjmp buffers for eval/die)
    from->top_env = PL_top_env;

    // Op and Pad pointers (Where we are in the bytecode)
    from->curcop = PL_curcop;
    from->op = PL_op;
    from->comppad = PL_comppad;
    from->curpad = PL_curpad;
    from->curpm = PL_curpm;
    from->curpm_under = PL_curpm_under;
    from->reg_curpm = PL_reg_curpm;
    from->defgv = PL_defgv;
    from->last_in_gv = PL_last_in_gv;
    from->rs = PL_rs;
    from->ofsgv = PL_ofsgv;
    from->ors_sv = PL_ors_sv;
    from->defoutgv = PL_defoutgv;
    from->curstash = PL_curstash;
    from->defstash = PL_defstash;
    from->errors = PL_errors;

    /* Load target state from 'to' context */
    PL_curstackinfo = to->si;
    PL_curstack = to->curstack;

    // Re-calculate stack bounds based on the new array (AV)
    PL_stack_base = AvARRAY(PL_curstack);
    PL_stack_max = PL_stack_base + AvMAX(PL_curstack);
    PL_stack_sp = PL_stack_base + to->stack_sp_offset;
    AvFILLp(PL_curstack) = to->stack_sp_offset;  // Keep stack AV metadata synced

    PL_markstack = to->markstack;
    PL_markstack_ptr = to->markstack_ptr;
    PL_markstack_max = to->markstack_max;

    PL_scopestack = to->scopestack;
    PL_scopestack_ix = to->scopestack_ix;
    PL_scopestack_max = to->scopestack_max;

    PL_savestack = to->savestack;
    PL_savestack_ix = to->savestack_ix;
    PL_savestack_max = to->savestack_max;

    PL_tmps_stack = to->tmps_stack;
    PL_tmps_ix = to->tmps_ix;
    PL_tmps_floor = to->tmps_floor;
    PL_tmps_max = to->tmps_max;

    PL_top_env = to->top_env;
    PL_curcop = to->curcop;
    PL_op = to->op;
    PL_comppad = to->comppad;
    PL_curpm = to->curpm;
    PL_curpm_under = to->curpm_under;
    PL_reg_curpm = to->reg_curpm;
    PL_defgv = to->defgv;
    PL_last_in_gv = to->last_in_gv;
    PL_rs = to->rs;
    PL_ofsgv = to->ofsgv;
    PL_ors_sv = to->ors_sv;
    PL_defoutgv = to->defoutgv;
    PL_curstash = to->curstash;
    PL_defstash = to->defstash;
    PL_errors = to->errors;

    if (PL_comppad)
        PL_curpad = AvARRAY(PL_comppad);
    else
        PL_curpad = to->curpad;

    // Restore CvDEPTH and clean landing pads
    _activate_current_depths(aTHX_ to);
}

/** @brief Number of 16-byte slots in each fiber control stack. */
#define FIBER_STACK_DEPTH 2048

/**
 * @brief Lays out a fiber's Perl control stacks inside a single allocation.
 *
 * All of the Mark, Scope, Save and Mortal stacks (plus the Stack Info
 * structure and its context stack) live in one contiguous 16-byte aligned
 * block so that a fiber only costs one malloc/free pair instead of seven.
 *
 * @param c The fiber context to initialize.
 * @param block The memory block to carve the stacks out of (may be NULL).
 * @param block_size Size of the block (out parameter).
 */
static void layout_perl_stacks(pTHX_ para_fiber_t * c, void * block, size_t * block_size) {
    I32 sz = FIBER_STACK_DEPTH;

    /* 16-byte aligned segment sizes */
    size_t si_sz = (sizeof(PERL_SI) + 15) & ~(size_t)15;
    size_t cx_sz = (sizeof(PERL_CONTEXT) * 64 + 15) & ~(size_t)15;
    size_t mk_sz = (sizeof(I32) * sz + 15) & ~(size_t)15;
    size_t sc_sz = (sizeof(I32) * sz + 15) & ~(size_t)15;
    size_t sv_sz = (sizeof(ANY) * sz + 15) & ~(size_t)15;
    size_t tm_sz = (sizeof(SV *) * sz + 15) & ~(size_t)15;

    size_t total = si_sz + cx_sz + mk_sz + sc_sz + sv_sz + tm_sz;
    if (!block) {
        *block_size = total;
        return;
    }
    char * p = (char *)block;

    /* Only the SI header needs zeroing; the control stacks are managed
     * through their own ix/count fields and never read beyond them. */
    memset(block, 0, si_sz);

    PERL_SI * si   = (PERL_SI *)(void *)p;                p += si_sz;
    PERL_CONTEXT * ctx_stack = (PERL_CONTEXT *)(void *)p;     p += cx_sz;
    I32 * markstack = (I32 *)(void *)p;                       p += mk_sz;
    I32 * scopestack = (I32 *)(void *)p;                      p += sc_sz;
    ANY * savestack = (ANY *)(void *)p;                       p += sv_sz;
    SV ** tmps_stack = (SV **)(void *)p;                      p += tm_sz;

    si->si_cxmax = 64;
    si->si_cxstack = ctx_stack;
    si->si_cxix = -1;
    si->si_type = PERLSI_MAIN;

    c->si = si;
    c->markstack = markstack;
    c->scopestack = scopestack;
    c->savestack = savestack;
    c->tmps_stack = tmps_stack;
    c->_stacks_block = block;
}

/**
 * @brief Resets a fiber's Perl control stacks back to their initial state.
 *
 * Called when a fiber is destroyed and its memory parked in the reuse
 * cache.  The single allocation block is kept and simply re-initialized.
 *
 * @param c The fiber context to reset.
 */
static void reset_perl_stacks(pTHX_ para_fiber_t * c) {
    I32 sz = FIBER_STACK_DEPTH;
    PERL_SI * si = c->si;

    /* Release any mortal SVs still parked on the tmps stack */
    if (c->tmps_stack) {
        for (I32 i = 0; i <= c->tmps_ix; i++) {
            SV * sv = c->tmps_stack[i];
            if (sv && sv != &PL_sv_undef)
                SvREFCNT_dec(sv);
        }
    }

    if (c->curstack) {
        /* Do NOT av_clear the fiber's argument stack here.  Slots below the
         * last-saved stack pointer may already have been popped and freed
         * during earlier resume/yield cycles, so clearing them would
         * double-decrement live SVs.  The AV is reused verbatim; new pushes
         * overwrite the stale slots before they are ever read. */
        AvARRAY(c->curstack)[0] = &PL_sv_undef;
        AvFILLp(c->curstack) = 0;
    }
    c->stack_sp_offset = 0;
    if (si) {
        si->si_cxix = -1;
        si->si_stack = c->curstack;
    }

    c->markstack_ptr = c->markstack;
    *c->markstack_ptr = 0;
    c->markstack_max = c->markstack + sz - 1;

    c->scopestack_ix = 0;
    c->scopestack_max = sz;

    c->savestack_ix = 0;
    c->savestack_max = sz;

    c->tmps_ix = -1;
    c->tmps_floor = -1;
    c->tmps_max = sz;

    /* Inherit globals from the current interpreter state */
    c->curcop = PL_curcop;
    c->op = PL_op;
    c->top_env = PL_top_env;
    c->curpm = PL_curpm;
    c->curpm_under = PL_curpm_under;
    c->reg_curpm = NULL;
    c->defgv = PL_defgv;
    c->last_in_gv = PL_last_in_gv;
    c->rs = PL_rs;
    c->ofsgv = PL_ofsgv;
    c->ors_sv = PL_ors_sv;
    c->defoutgv = PL_defoutgv;
    c->curstash = PL_curstash;
    c->defstash = PL_defstash;
    c->errors = PL_errors;
    c->comppad = NULL;
    c->curpad = NULL;
}

/**
 * @brief Allocates and initializes new Perl stacks for a fiber.
 *
 * Each fiber needs a complete set of independent stacks (Argument, Mark,
 * Scope, Save, Mortal) to function as a separate execution thread.  The
 * control stacks share a single allocation block for speed.
 *
 * @param c The fiber context to initialize.
 */
void init_perl_stacks(para_fiber_t * c) {
    dTHX;

    size_t block_size = 0;
    layout_perl_stacks(aTHX_ c, NULL, &block_size);
    void * block = malloc(block_size);
    if (!block) {
        c->_stacks_block = NULL;
        return;
    }
    layout_perl_stacks(aTHX_ c, block, &block_size);

    // Allocate Argument Stack (AV)
    c->curstack = newAV();
    AvREAL_off(c->curstack);  // Stacks do not 'own' their elements in the refcnt sense
    av_extend(c->curstack, 128);

    /* The block is uninitialized beyond the SI header, so mark the tmps
     * stack empty before reset runs its release loop. */
    c->tmps_ix = -1;
    c->tmps_floor = -1;

    reset_perl_stacks(aTHX_ c);
}

/**
 * @brief Frees the Perl stacks and the single allocation block.
 *
 * @param c The fiber context whose stacks should be released.
 */
static void free_perl_stacks(pTHX_ para_fiber_t * c) {
    if (c->curstack) {
        /* Skip av_clear: stale slots may already be freed (see reset_perl_stacks). */
        SvREFCNT_dec((SV *)c->curstack);
        c->curstack = NULL;
    }
    if (c->_stacks_block) {
        free(c->_stacks_block);
        c->_stacks_block = NULL;
    }
    c->si = NULL;
    c->markstack = NULL;
    c->scopestack = NULL;
    c->savestack = NULL;
    c->tmps_stack = NULL;
}

/**
 * @brief Initializes the fiber system and converts the main thread.
 *
 * This function must be called once before any other fiber operations.
 * It captures the state of the main Perl interpreter thread.
 *
 * @return int 0 on success.
 */
DLLEXPORT int init_system() {
    dTHX;
    if (system_initialized)
        return 0;
    if (!free_slots_seeded) {
        for (int i = 0; i < MAX_FIBERS; i++)
            free_slots[i] = MAX_FIBERS - 1 - i;
        free_slot_count = MAX_FIBERS;
        free_slots_seeded = 1;
    }
    if (max_thread_pool_size == 0) {
        max_thread_pool_size = get_cpu_count();
        if (max_thread_pool_size > MAX_THREADS)
            max_thread_pool_size = MAX_THREADS;
    }
    main_context.si = PL_curstackinfo;
    main_context.transfer_data = &PL_sv_undef;
    main_context.id = -1;
    main_context.finished = 0;
    main_context.last_sender = -1;
    main_context.curpm = PL_curpm;
    main_context.curpm_under = PL_curpm_under;
    main_context.reg_curpm = PL_reg_curpm;
    main_context.defgv = PL_defgv;
    main_context.last_in_gv = PL_last_in_gv;
    main_context.rs = PL_rs;
    main_context.ofsgv = PL_ofsgv;
    main_context.ors_sv = PL_ors_sv;
    main_context.defoutgv = PL_defoutgv;
    main_context.curstash = PL_curstash;
    main_context.defstash = PL_defstash;
    main_context.errors = PL_errors;
    system_initialized = 1;
#ifdef _WIN32
    /* Convert the main thread into a fiber so it can be switched out */
    if (!main_fiber_handle) {
        main_fiber_handle = ConvertThreadToFiber(NULL);
        if (!main_fiber_handle) {
            if (GetLastError() == ERROR_ALREADY_FIBER)
                main_fiber_handle = GetCurrentFiber();
        }
    }
#endif
    init_threads();
    return 0;
}

/**
 * @brief Performs the low-level OS context switch.
 *
 * Saves the Perl state and then uses OS primitives (SwitchToFiber or
 * swapcontext) to change execution flow.
 *
 * @param target_id ID of the target fiber (-1 for Main).
 */
void perform_switch(int target_id, int set_last_sender) {
    dTHX;
    if (target_id == current_fiber_id)
        return;
    para_fiber_t * from = (current_fiber_id == -1) ? &main_context : fibers[current_fiber_id];
    para_fiber_t * to = (target_id == -1) ? &main_context : fibers[target_id];
    if (set_last_sender)
        to->last_sender = current_fiber_id;
    current_fiber_id = target_id;
    swap_perl_state(from, to);
#ifdef _WIN32
    if (target_id == -1)
        SwitchToFiber(main_fiber_handle);
    else
        SwitchToFiber(to->context);
#elif defined(USE_ASM_CORO)
    para_coro_switch(&from->rsp, &to->rsp);
#else
    swapcontext(&from->context, &to->context);
#endif
}

/**
 * @brief Yields execution back to the caller or the main thread.
 *
 * Suspends the current fiber and returns a value to the context that
 * last resumed or called this fiber.
 *
 * @param ret_val The Perl SV to "return" to the caller.
 * @return SV* The value passed in when this fiber is eventually resumed.
 */
DLLEXPORT SV * coro_yield(SV * ret_val) {
    dTHX;
    if (current_fiber_id == -1)
        return &PL_sv_undef;
    para_fiber_t * self = fibers[current_fiber_id];
    int parent = self->parent_id;
    if (parent != -1 && (!fibers[parent] || fibers[parent]->finished))
        parent = self->last_sender;
    else if (parent == -1)
        parent = self->last_sender;
    if (parent >= 0 && (!fibers[parent] || fibers[parent]->finished))
        parent = -1;
    para_fiber_t * caller = (parent == -1) ? &main_context : fibers[parent];

    /* Pass return value to caller */
    if (caller->transfer_data != ret_val) {
        if (caller->transfer_data && caller->transfer_data != &PL_sv_undef)
            SvREFCNT_dec(caller->transfer_data);
        caller->transfer_data = ret_val;
        if (ret_val && ret_val != &PL_sv_undef)
            SvREFCNT_inc(ret_val);
    }

    perform_switch(parent, 0);

    /* Retrieve value passed back during resume */
    SV * res = self->transfer_data;
    self->transfer_data = &PL_sv_undef;
    if (res && res != &PL_sv_undef)
        sv_2mortal(res);
    return res;
}

/**
 * @brief Entry point function for all new fibers.
 *
 * Sets up the Perl environment (ENTER/SAVETMPS), unpacks arguments,
 * calls the user coderef, handles results/errors, and manages the
 * fiber's completion lifecycle.
 *
 * @param c Pointer to the fiber context being started.
 */
void para_entry_point(para_fiber_t * c) {
    dTHX;
    ENTER;
    SAVETMPS;
    dSP;
    PUSHMARK(SP);

    /* Unpack arguments passed during coro_call */
    if (c->transfer_data && SvROK(c->transfer_data) && SvTYPE(SvRV(c->transfer_data)) == SVt_PVAV) {
        AV * args = (AV *)SvRV(c->transfer_data);
        I32 len = av_top_index(args) + 1;
        for (I32 i = 0; i < len; i++) {
            SV ** svp = av_fetch(args, i, 0);
            if (svp)
                XPUSHs(*svp);
        }
    }
    PUTBACK;

    /* Execute the Perl sub */
    int count = call_sv(c->user_cv, G_SCALAR | G_EVAL);

    SPAGAIN;
    SV * ret_val = &PL_sv_undef;
    if (count == 1)
        ret_val = POPs;
    PUTBACK;

    c->finished = true;

    /* Cleanup transfer data and store result */
    if (c->transfer_data && c->transfer_data != &PL_sv_undef) {
        SvREFCNT_dec(c->transfer_data);
        c->transfer_data = &PL_sv_undef;
    }
    if (ret_val && ret_val != &PL_sv_undef) {
        SvREFCNT_inc(ret_val);
        c->transfer_data = ret_val;
    }

    /* Update the Perl-level Acme::Parataxis object.
     *
     * The object is a blessed flat arrayref; slot layout mirrors the
     * Perl-side constants F_ERROR=2, F_RESULT=3, F_IS_READY=5,
     * F_CALLBACKS=6.  Writing the result/error slots directly avoids a
     * method dispatch per fiber completion; the callback dispatch sub is
     * only invoked when callbacks were actually registered. */
    if (c->self_ref && SvROK(c->self_ref)) {
        AV * obj = (AV *)SvRV(c->self_ref);
        SV ** ready = av_fetch(obj, 5, 0);
        if (!(ready && *ready && SvTRUE(*ready))) {
            if (SvTRUE(ERRSV)) {
                av_store(obj, 2, newSVsv(ERRSV));
                av_store(obj, 5, &PL_sv_yes);
            }
            else {
                if (ret_val != &PL_sv_undef)
                    av_store(obj, 3, SvREFCNT_inc(ret_val));
                av_store(obj, 5, &PL_sv_yes);
            }
            /* F_IS_DONE=1, F_FID=-1: the fiber is finished, so the object
             * is marked done and must not touch the (already recycled)
             * C context from DESTROY/is_done. */
            av_store(obj, 1, &PL_sv_yes);
            SV ** fp = av_fetch(obj, 4, 0);
            if (fp && *fp)
                sv_setiv(*fp, -1);
            SV ** cbs = av_fetch(obj, 6, 0);
            if (cbs && *cbs && SvROK(*cbs) && SvTYPE(SvRV(*cbs)) == SVt_PVAV) {
                AV * cbav = (AV *)SvRV(*cbs);
                if (av_len(cbav) >= 0) {
                    dSP;
                    ENTER;
                    SAVETMPS;
                    PUSHMARK(SP);
                    XPUSHs(c->self_ref);
                    PUTBACK;
                    call_method("_dispatch_callbacks", G_DISCARD);
                    FREETMPS;
                    LEAVE;
                }
            }
        }
    }
    FREETMPS;
    LEAVE;

    /* Final yield back to caller */
    coro_yield(c->transfer_data ? c->transfer_data : &PL_sv_undef);

    /* Loop indefinitely if resumed after finish */
    while (1)
        coro_yield(&PL_sv_undef);
}

#ifdef _WIN32
/** @brief Windows fiber callback wrapper. */
static void WINAPI fiber_entry(void * param) { para_entry_point((para_fiber_t *)param); }
#else
/** @brief POSIX makecontext callback wrapper. */
static void posix_entry(int fiber_id) { para_entry_point(fibers[fiber_id]); }
#endif

#ifndef _WIN32
/**
 * @brief Obtains a fiber stack, reusing one from the cache when possible.
 *
 * @param sz Required stack size in bytes.
 * @return void* Pointer to a 16-byte aligned stack, or NULL on failure.
 */
static void * alloc_fiber_stack(size_t sz) {
    if (stack_cache_count > 0)
        return stack_cache[--stack_cache_count];
    void * p = NULL;
    if (posix_memalign(&p, 16, sz) != 0)
        return NULL;
    return p;
}

/** @brief Returns a fiber stack to the reuse cache or frees it. */
static void free_fiber_stack(void * p) {
    if (stack_cache_count < MAX_CACHED_STACKS)
        stack_cache[stack_cache_count++] = p;
    else
        free(p);
}
#endif

/**
 * @brief Arms the OS-level context for a (possibly recycled) fiber.
 *
 * Installs the entry trampoline on the fiber's stack so that the next
 * context switch resumes the fiber from scratch.
 *
 * @param c The fiber context to arm.
 * @param idx The fiber ID (used by the ucontext makecontext path).
 */
static void arm_fiber_context(para_fiber_t * c, int idx) {
#ifdef _WIN32
    c->context = CreateFiber(0, fiber_entry, c);
#else
#ifdef USE_ASM_CORO
    /*
     * Lay out the fresh stack for the assembly switch.  When the switch
     * routine resumes this context it first pops the six dummy saved
     * registers, then "returns" into para_trampoline.  The trampoline pops
     * the fiber pointer and tail-calls para_entry_point with the correct
     * ABI stack alignment.
     */
    void ** slot = (void **)((char *)c->stack_p + c->stack_sz);
    slot -= 8;  /* 6 saved regs + return address + fiber pointer */
    for (int i = 0; i < 6; i++)
        slot[i] = NULL;
    slot[6] = (void *)&para_trampoline;
    slot[7] = c;
    c->rsp = slot;
#else
    getcontext(&c->context);
    c->context.uc_stack.ss_sp = c->stack_p;
    c->context.uc_stack.ss_size = c->stack_sz;
    c->context.uc_link = &main_context.context;
    makecontext(&c->context, (void (*)())posix_entry, 1, idx);
#endif
#endif
}

/**
 * @brief Allocates and prepares a new Fiber context.
 *
 * @param user_code Coderef to execute in the fiber.
 * @param self_ref Acme::Parataxis object to notify on completion.
 * @return int Unique ID of the new fiber, or negative on error.
 */
DLLEXPORT int create_fiber(SV * user_code, SV * self_ref) {
    dTHX;
    if (!free_slots_seeded) {
        for (int i = 0; i < MAX_FIBERS; i++)
            free_slots[i] = MAX_FIBERS - 1 - i;
        free_slot_count = MAX_FIBERS;
        free_slots_seeded = 1;
    }
    int idx;
    if (free_slot_count > 0) {
        idx = free_slots[--free_slot_count];
    }
    else {
        /* Safety net: scan for a slot if the free list is ever exhausted. */
        idx = -1;
        for (int i = 0; i < MAX_FIBERS; i++) {
            if (fibers[i] == NULL) {
                idx = i;
                break;
            }
        }
    }
    if (idx == -1)
        return -2;

    para_fiber_t * c = NULL;
#ifndef _WIN32
    if (fiber_cache_count > 0)
        c = fiber_cache[--fiber_cache_count];
#endif
    if (c) {
        /* Recycle a parked fiber context: re-inherit globals, clear pads */
        reset_perl_stacks(aTHX_ c);
    }
    else {
        c = (para_fiber_t *)malloc(sizeof(para_fiber_t));
        if (!c)
            return -3;
        memset(c, 0, sizeof(para_fiber_t));
        /* Initialize Perl stacks */
        init_perl_stacks(c);
        if (!c->_stacks_block) {
            free(c);
            return -3;
        }
#ifndef _WIN32
        c->stack_sz = 512 * 1024;  // 512KB is plenty for Perl fibers
        c->stack_p = alloc_fiber_stack(c->stack_sz);
        if (!c->stack_p) {
            free_perl_stacks(aTHX_ c);
            free(c);
            return -3;
        }
#else
        c->context = NULL;
#endif
    }

    /* Reset the coderef's call depth so the fiber starts clean */
    if (user_code && user_code != &PL_sv_undef)
        force_depth_zero(user_code);

    c->user_cv = user_code;
    if (user_code && user_code != &PL_sv_undef)
        SvREFCNT_inc(user_code);
    c->self_ref = self_ref;
    if (self_ref && self_ref != &PL_sv_undef)
        SvREFCNT_inc(self_ref);
    c->id = idx;
    c->parent_id = -1;
    c->last_sender = -1;
    c->finished = 0;
    c->transfer_data = &PL_sv_undef;
    fibers[idx] = c;

    arm_fiber_context(c, idx);
    return idx;
}

/**
 * @brief Resumes a fiber (asymmetric call).
 *
 * Suspends the caller and switches execution to the specified fiber.
 * Sets the caller as the 'parent' for future yields.
 *
 * @param fiber_id Fiber ID to call.
 * @param args Perl SV (usually arrayref) to pass as arguments to the fiber.
 * @return SV* Result yielded by the fiber.
 */
DLLEXPORT SV * coro_call(int fiber_id, SV * args) {
    dTHX;
    if (fiber_id < 0 || fiber_id >= MAX_FIBERS || !fibers[fiber_id] || fibers[fiber_id]->finished)
        return &PL_sv_undef;
    if (fibers[fiber_id]->transfer_data != args) {
        if (fibers[fiber_id]->transfer_data && fibers[fiber_id]->transfer_data != &PL_sv_undef)
            SvREFCNT_dec(fibers[fiber_id]->transfer_data);
        fibers[fiber_id]->transfer_data = args;
        if (args && args != &PL_sv_undef)
            SvREFCNT_inc(args);
    }
    fibers[fiber_id]->parent_id = current_fiber_id;
    perform_switch(fiber_id, 1);
    if (fibers[fiber_id] && fibers[fiber_id]->finished) {
        if (fibers[fiber_id]->transfer_data && fibers[fiber_id]->transfer_data != &PL_sv_undef) {
            SvREFCNT_dec(fibers[fiber_id]->transfer_data);
            fibers[fiber_id]->transfer_data = &PL_sv_undef;
        }
        destroy_coro(fiber_id);
    }
    para_fiber_t * me = (current_fiber_id == -1) ? &main_context : fibers[current_fiber_id];
    SV * res = me->transfer_data;
    me->transfer_data = &PL_sv_undef;
    if (res && res != &PL_sv_undef)
        sv_2mortal(res);
    return res;
}

/**
 * @brief Runs a fiber to its next suspension point and cleans it up.
 *
 * Combines the scheduler's per-fiber work (resume, finish detection and
 * destruction) into a single call so the FFI overhead is paid once per
 * fiber instead of four times.
 *
 * @param fiber_id Fiber to resume.
 * @param args Argument arrayref to pass to the fiber, or NULL for none.
 * @return int -1 fiber not found, 0 still running (re-enqueue),
 *              1 finished and destroyed, 3 yielded 'WAITING'.
 */
DLLEXPORT int run_fiber_checked(int fiber_id, SV * args) {
    dTHX;
    if (fiber_id < 0 || fiber_id >= MAX_FIBERS || !fibers[fiber_id])
        return -1;
    para_fiber_t * c = fibers[fiber_id];
    if (c->finished) {
        destroy_coro(fiber_id);
        return 1;
    }
    SV * ret = coro_call(fiber_id, args);
    if (!fibers[fiber_id] || fibers[fiber_id]->finished) {
        destroy_coro(fiber_id);
        return 1;
    }
    if (ret && SvROK(ret) && SvTYPE(SvRV(ret)) == SVt_PVAV) {
        AV * av = (AV *)SvRV(ret);
        if (av_len(av) == 0) {
            SV ** svp = av_fetch(av, 0, 0);
            if (svp && *svp && SvPOK(*svp) && strEQ(SvPVX(*svp), "WAITING"))
                return 3;
        }
    }
    return 0;
}

/**
 * @brief Creates a fiber object, its C context, and runs it inline.
 *
 * Merges the Perl-side spawn sequence (bless, create_fiber, run_fiber_checked)
 * into a single FFI call.  Returns the blessed fiber object with the run
 * status stored at object slot 8 (F_LAST_STATUS):
 *   1 finished, 0 yielded (re-enqueue), 3 yielded 'WAITING', -1 not found.
 *
 * @param user_code Coderef to run as the fiber body.
 * @param class     Class name to bless the fiber object into.
 * @return SV* The blessed fiber object, or &PL_sv_undef on failure.
 */
DLLEXPORT SV * spawn_fiber(SV * user_code, SV * class) {
    dTHX;
    if (!user_code || user_code == &PL_sv_undef || !class || class == &PL_sv_undef)
        return &PL_sv_undef;
    char * cls = SvPV_nolen(class);
    static HV * own_stash = NULL;
    if (!own_stash)
        own_stash = gv_stashpv("Acme::Parataxis", GV_ADD);
    HV * stash = strEQ(cls, "Acme::Parataxis") ? own_stash : gv_stashpv(cls, GV_ADD);
    AV * obj = newAV();
    av_extend(obj, 8);  /* pre-size to fit every F_* slot in one allocation */
    SV * objrv = newRV_noinc((SV *)obj);
    sv_bless(objrv, stash);
    av_store(obj, 0, SvREFCNT_inc(user_code));  /* F_CODE */
    int fid = create_fiber(user_code, objrv);
    if (fid < 0) {
        SvREFCNT_dec(objrv);
        return &PL_sv_undef;
    }
    av_store(obj, 4, newSViv(fid));             /* F_FID */
    int st = run_fiber_checked(fid, &PL_sv_undef);
    av_store(obj, 8, newSViv(st));              /* F_LAST_STATUS */
    return objrv;
}

/**
 * @brief Reclaims all completed background jobs in a single call.
 *
 * Returns an arrayref of [fiber_id, result] pairs for every finished job,
 * freeing the job slots as it goes.
 *
 * @return SV* Arrayref of completed jobs (may be empty).
 */
DLLEXPORT void drain_jobs(SV * out_ref) {
    dTHX;
    if (!out_ref || !SvROK(out_ref) || SvTYPE(SvRV(out_ref)) != SVt_PVAV)
        return;
    AV * out = (AV *)SvRV(out_ref);
    av_clear(out);
    while (1) {
        int job_idx = check_for_completion();
        if (job_idx == -1)
            break;
        AV * pair = newAV();
        av_push(pair, newSViv(get_job_coro_id(job_idx)));
        SV * res = get_job_result(job_idx);
        /* get_job_result returns a mortal parked on the caller's tmps stack;
         * copy it so the pair owns its own SV instead of double-decrementing
         * the mortal when both the pair and FREETMPS release it. */
        av_push(pair, (res && res != &PL_sv_undef) ? newSVsv(res) : &PL_sv_undef);
        av_push(out, newRV_noinc((SV *)pair));
        free_job_slot(job_idx);
    }
}

/**
 * @brief Transfers control directly to another fiber (symmetric).
 *
 * Suspends the current fiber and switches directly to the target. No
 * parent/child relationship is established.
 *
 * @param target_id Fiber ID to transfer to.
 * @param args Arguments to pass to the target.
 * @return SV* Data eventually transferred back to this fiber.
 */
DLLEXPORT SV * coro_transfer(int target_id, SV * args) {
    dTHX;
    if (target_id < -1 || (target_id >= 0 && (target_id >= MAX_FIBERS || !fibers[target_id])))
        return &PL_sv_undef;
    if (target_id >= 0 && fibers[target_id]->finished)
        return &PL_sv_undef;
    para_fiber_t * target = (target_id == -1) ? &main_context : fibers[target_id];
    if (target->transfer_data != args) {
        if (target->transfer_data && target->transfer_data != &PL_sv_undef)
            SvREFCNT_dec(target->transfer_data);
        target->transfer_data = args;
        if (args && args != &PL_sv_undef)
            SvREFCNT_inc(args);
    }
    perform_switch(target_id, 1);
    if (target_id >= 0 && fibers[target_id] && fibers[target_id]->finished) {
        if (fibers[target_id]->transfer_data && fibers[target_id]->transfer_data != &PL_sv_undef) {
            SvREFCNT_dec(fibers[target_id]->transfer_data);
            fibers[target_id]->transfer_data = &PL_sv_undef;
        }
        destroy_coro(target_id);
    }
    para_fiber_t * me = (current_fiber_id == -1) ? &main_context : fibers[current_fiber_id];
    SV * res = me->transfer_data;
    me->transfer_data = &PL_sv_undef;
    if (res && res != &PL_sv_undef)
        sv_2mortal(res);
    return res;
}

/** @brief Returns 1 if the fiber has finished execution. */
DLLEXPORT int is_finished(int fiber_id) {
    if (fiber_id < 0)
        return 0;
    return (fibers[fiber_id] && fibers[fiber_id]->finished) ? 1 : 0;
}

/**
 * @brief Returns the Perl object bound to a live fiber, if any.
 *
 * Replaces the Perl-level %REGISTRY lookup: the C context already owns a
 * strong reference to the object via self_ref, so no separate registry or
 * weak-reference bookkeeping is needed on the Perl side.
 *
 * @param fiber_id The fiber ID to look up.
 * @return SV* The blessed fiber object (mortalized), or &PL_sv_undef.
 */
DLLEXPORT SV * get_fiber_by_id(int fiber_id) {
    dTHX;
    if (fiber_id < 0 || fiber_id >= MAX_FIBERS || !fibers[fiber_id])
        return &PL_sv_undef;
    SV * self_ref = fibers[fiber_id]->self_ref;
    if (!self_ref || self_ref == &PL_sv_undef)
        return &PL_sv_undef;
    SvREFCNT_inc(self_ref);
    return sv_2mortal(self_ref);
}

/** @brief Returns the number of currently live (non-destroyed) fibers. */
DLLEXPORT int get_live_fiber_count(void) {
    int count = 0;
    for (int i = 0; i < MAX_FIBERS; i++)
        if (fibers[i])
            count++;
    return count;
}

/** @brief Internal helper to reset subroutine depth for cleanup. */
static void recursive_depth_reset(pTHX_ CV * cv) {
    if (!cv || SvTYPE((SV *)cv) != SVt_PVCV)
        return;
    if (CvDEPTH(cv) > 0)
        CvDEPTH(cv) = 0;
}

/**
 * @brief Clears active pads in the fiber stack.
 *
 * Internal helper used during fiber destruction to ensure all active lexical
 * scopes are unwound and their variables freed.
 *
 * @param si The Stack Info structure of the fiber.
 */
static void _clear_pads_in_stack(pTHX_ PERL_SI * si) {
    if (!si || !si->si_cxstack)
        return;
    for (I32 i = si->si_cxix; i >= 0; i--) {
        PERL_CONTEXT * cx = &(si->si_cxstack[i]);
        if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
            CV * cv = cx->blk_sub.cv;
            if (cv && SvTYPE((SV *)cv) == SVt_PVCV) {
                PADLIST * padlist = CvPADLIST(cv);
                if (padlist) {
                    I32 depth = cx->blk_sub.olddepth + 1;
                    if (depth > 0 && depth <= PadlistMAX(padlist)) {
                        AV * pad = (AV *)PadlistARRAY(padlist)[depth];
                        if (pad && SvTYPE((SV *)pad) == SVt_PVAV)
                            av_clear(pad);
                    }
                }
                if (CvDEPTH(cv) > 0)
                    CvDEPTH(cv)--;
            }
        }
    }
}

/**
 * @brief Destroys a fiber and releases all associated memory.
 *
 * This includes freeing OS-level stacks and context, but also carefully
 * decrementing refcounts of Perl SVs stored within the fiber.
 *
 * @param fiber_id Fiber ID to destroy.
 */
DLLEXPORT void destroy_coro(int fiber_id) {
    dTHX;
    if (fiber_id < 0 || fiber_id >= MAX_FIBERS)
        return;
    para_fiber_t * c = fibers[fiber_id];
    if (!c)
        return;
    fibers[fiber_id] = NULL;
    if (free_slot_count < MAX_FIBERS)
        free_slots[free_slot_count++] = fiber_id;

    /* Unwind pads */
    if (c->si)
        _clear_pads_in_stack(aTHX_ c->si);

    /* Release Perl references */
    if (c->user_cv && c->user_cv != &PL_sv_undef) {
        SvREFCNT_dec(c->user_cv);
        c->user_cv = NULL;
    }
    if (c->self_ref && c->self_ref != &PL_sv_undef) {
        SvREFCNT_dec(c->self_ref);
        c->self_ref = NULL;
    }
    if (c->transfer_data && c->transfer_data != &PL_sv_undef) {
        SvREFCNT_dec(c->transfer_data);
        c->transfer_data = NULL;
    }

    /* Early exit if Perl is already shutting down */
    if (PL_dirty) {
#ifndef _WIN32
        if (c->stack_p)
            free(c->stack_p);
#endif
        free_perl_stacks(aTHX_ c);
        free(c);
        return;
    }

#ifdef _WIN32
    if (c->context)
        DeleteFiber(c->context);
#else
    /* Park the whole context (Perl stacks + OS stack) for reuse */
    if (fiber_cache_count < MAX_FIBER_CACHE) {
        reset_perl_stacks(aTHX_ c);
        fiber_cache[fiber_cache_count++] = c;
        return;
    }
    if (c->stack_p) {
        free_fiber_stack(c->stack_p);
        c->stack_p = NULL;
    }
#endif

    free_perl_stacks(aTHX_ c);
    free(c);
}

/**
 * @brief Global cleanup function for the fiber and thread pool system.
 *
 * Signals all worker threads to terminate and destroys all remaining
 * fibers. Should be called during global destruction or system shutdown.
 */
DLLEXPORT void cleanup() {
    dTHX;
    if (threads_initialized) {
        LOCK(queue_lock);
        threads_keep_running = 0;
        PARA_COND_BROADCAST(queue_cond);
        UNLOCK(queue_lock);

#ifdef _WIN32
        /* Wait for threads to finish and close handles */
        for (int i = 0; i < current_thread_count; i++) {
            if (thread_handles[i]) {
                WaitForSingleObject(thread_handles[i], 100);
                CloseHandle(thread_handles[i]);
                thread_handles[i] = NULL;
            }
        }
#else
        /* Give threads a moment to notice threads_keep_running = 0 */
        usleep(10000);
#endif
    }

    if (current_fiber_id != -1) {
        swap_perl_state(fibers[current_fiber_id], &main_context);
        current_fiber_id = -1;
    }
    for (int i = 0; i < MAX_FIBERS; i++)
        if (fibers[i])
            destroy_coro(i);
#ifndef _WIN32
    while (stack_cache_count > 0)
        free(stack_cache[--stack_cache_count]);
#endif
    if (main_context.transfer_data && main_context.transfer_data != &PL_sv_undef) {
        SvREFCNT_dec(main_context.transfer_data);
        main_context.transfer_data = &PL_sv_undef;
    }
}
