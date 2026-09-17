# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

This started as a silly little diversion in February but I'm using this in actual projects now. I've even used it to shake out bugs in Affix.

I might move it out of the Acme namespace...

Anyway, the major win is that fiber hot path has been moved from Perl into C and roughly tripled context swapping throughput with no change to the public API.

### Added

- `Acme::Parataxis::Channel`: a buffered FIFO message queue for producer/consumer patterns between fibers. Writers block when full, readers when empty; a capacity of `1` makes it a rendezvous point. Built on two semaphores.
- `Acme::Parataxis::Future`: a one-shot placeholder for an eventual computation result. A producer fires `set_result`/`set_error` exactly once; consumers pick it up with `await`/`result` or register an `on_ready` callback.
- `Acme::Parataxis::Semaphore`: a counting semaphore with no ownership: blocked fibers are parked (no busy-wait) and resumed FIFO as permits become available.
- `Acme::Parataxis::Signal`: a two-state flag with a FIFO queue of waiters. `send` latches the signal so a later `wait` consumes it immediately, while `broadcast` wakes every queued waiter at once (and drops if nobody is waiting).
- Waiter introspection and removal (the foundation for cancellation): blocking waits now park through a single `_park`/`_resume_hooks` path that records a `wait_reason` (a label plus the calling file/line, readable via `$fiber->wait_reason`) and fires `on_wake` hooks exactly once when a parked fiber is resumed. `Semaphore`, `Signal`, `Future`, and `Channel` each gained `remove_waiter` to un-register a parked waiter.
- Cancellation tokens: `Acme::Parataxis::CancellationToken` lets any fiber register for cooperative cancellation. `cancel` is idempotent and interrupts every parked, registered fiber by throwing `Acme::Parataxis::Error::Cancelled` at the park site; a fiber registered against an already-cancelled token has its next park aborted immediately, and `unregister` opts a fiber back out.
- `with_timeout( $ms, [ $token, ] $code )`: runs a block as a child fiber and throws `Acme::Parataxis::Error::Timeout` in the caller if it doesn't finish in time, cleaning up the child and anything it was blocked on while the scheduler keeps running. An optional token cancels the block early (`Error::Cancelled`); a pre-cancelled token fails fast; a bound of `0` means no deadline.
- `Acme::Parataxis::Error`, `Acme::Parataxis::Error::Cancelled`, and `Acme::Parataxis::Error::Timeout`: the exceptions interruption throws, with `message`/`kind` and the `wait_reason` of the interrupted wait.
- `Acme::Parataxis::Local`: per-fiber storage slots for ambient state that must not leak across fibers (tracing ids, span context, per-fiber handles). Each `Local` is one slot; values are isolated per fiber, survive `yield`/`await`, and are released with their fiber, with no scheduler or C changes needed.
- `Acme::Parataxis::Sync`: the synchronization-primitive family, sharing one park/wake mechanism where an interrupted wait unregisters itself from the primitive it was parked on:
    - `Acme::Parataxis::Sync::Mutex`: a non-reentrant lock with true owner tracking (`lock`/`try_lock`/`unlock`/`guard`, plus `owner`/`waiters`). Releasing from a non-owner, relocking the same fiber, or releasing a free lock all croak; a contended `lock` parks and is handed directly to the next FIFO waiter, so nobody can cut in line.
    - `Acme::Parataxis::Sync::WaitGroup`: a job counter shared across fibers. `add($n)`/`done()` adjust it (over-done and non-integer adds croak) and `wait()` parks until it reaches zero.
    - `Acme::Parataxis::Sync::Barrier`: a reusable rendezvous for `parties` fibers. `arrive_and_wait` releases exactly `parties` at the phase boundary (the last arriver included) and re-arms for the next round.
    - `Acme::Parataxis::Sync::Once`: an initializer run exactly once across racing fibers. The first caller runs it (and gets the return value), concurrent callers park until it finishes, and late callers no-op; an initializer that dies still leaves the Once done.
- `nursery( sub ($n) { ... } )`: structured concurrency. The enclosed block spawns child fibers with `$n->spawn`; the call returns only once every child is done, and the moment any child fails the rest are cancelled and drained. The first failure (together with the `Error::Cancelled` unwinds of the siblings it cancelled) is rethrown in the caller as `Acme::Parataxis::Error::Nursery`, whose `->primary` and `->failures` expose the aggregate. The block value comes back on success; a block error cancels and drains the children, then propagates unchanged; the nursery's `CancellationToken` is public as `$n->token`, so user code or a nested `with_timeout` can cancel the whole group like a failed sibling. A bare `fiber`/`spawn` inside the block is not adopted by the nursery (it is an independent fiber the block owns).
- `Acme::Parataxis::Channel::select`: CSP-style waiting on the first ready case among any number of channels. `Acme::Parataxis::Channel->select( [ $ch, 'get' ], [ $ch2, 'put', $v ], timeout => 1000, default => sub {...} )` probes ready cases without yielding, parks on the first open case otherwise, and returns `( $channel, $value )` (or `( undef, undef )` on timeout, or the default block's value when nothing is ready). Cases are tried in random order so none can starve; each case channel parks the select on its own waiter list, woken by the matching operation.
- `Acme::Parataxis::Channel::try_get` / `Acme::Parataxis::Channel::try_put`: non-blocking channel operations. They return `( $ok, $value )` / `$ok` immediately instead of parking, waking channels select-parks just like their blocking siblings.
- `Acme::Parataxis::Channel::select_waiters`: reports how many fibers are currently parked in select on a channel (introspection, for tests).
- `Acme::Parataxis::Generator`: a stackful, lazily-pulled iterator (like Cro's `Supply`-less cousin of `Iterator`/Python generators). `Generator->new( sub ($y) { ... } )` runs the body in a private fiber that never enters the scheduler run queue; each `->next` resumes it exactly where it left off, so the body is plain synchronous code and can yield from any depth of calls. Exhaustion returns `undef` and finishes the fiber through the normal scheduler teardown; a body die is rethrown at the `next` that provokes it and the generator is done afterwards. Discarding a suspended (unexhausted) generator drains the fiber to a natural exit instead of tearing it down mid-eval (which previously poisoned later fibers with a 0xC0000005 crash), and the first generator created parks one reserved fiber so every generator lands on a stable slot.
- `Acme::Parataxis::Actor`: a thin actor — a dedicated fiber owning a bounded `Channel` mailbox that runs one handler per message. `Actor->spawn( sub ($self, $msg) { ... } )` returns immediately; `ask($msg)` queues the message with a reply `Future` and hands it back, so the handler's return value (or die) travels to the caller through `->await` or `->on_ready`; `send($msg)` is fire-and-forget. The bounded mailbox gives slow handlers backpressure to senders, `ask` composes with `with_timeout`/cancellation like any fiber wait, and `stop` shuts down gracefully (draining pre-stop messages, failing anything that slipped past the marker). A handler die fails its own ask (or warns for a `send`) and the actor keeps running; supervision is deliberately out of scope.
- `dump_fibers()`: M8 diagnostics. Returns every live fiber, its state (WAITING/READY/RUNNING/RUNNABLE) and — when parked — the wait reason and the source site where it yielded (M0's wait_reason), and prints the same as a human report when given a filehandle. The scheduler's fatal deadlock message now carries the report: each parked fiber of the deadlocked run with reason and site, instead of a bare `FATAL: deadlock detected...`, so deadlocks name their participants at a glance.

### Fixed

- Fixed crash (double-free / use-after-free) when fibers call Affix'd functions on non-threaded Perl. The bug was in Affix's `SAVEVPTR`/`SAVEDESTRUCTOR_X` arena pattern, which was not fiber-safe; now fixed upstream in Affix v1.2.5+.
- Fixed SIGSEGV on macOS and FreeBSD caused by fiber stacks being only 512KB (via `posix_memalign`). All POSIX platforms now use a 64MB `mmap`-backed stack with a PROT_NONE guard page, matching the Linux path. The SIGSEGV guard handler is also available on macOS/FreeBSD now.
- Fixed FreeBSD compilation: added `MAP_ANONYMOUS` w/ `MAP_ANON` fallback.
- Fixed macOS SIGBUS: the guard region size is now derived from `sysconf(_SC_PAGESIZE)` at runtime so it always covers at least one full page (16 KiB on Apple Silicon). Also fixed `cleanup()` to use `munmap()` instead of `free()` on non-Linux POSIX platforms.
- `is_finished()` now rejects fiber ids of `MAX_FIBERS` or greater instead of reading out of bounds of the fiber table.
- Closed a busy-spin footgun: `wait`, fiber `await`, `Semaphore` waits, and `Signal->wait` now croak instead of burning 100% CPU when called from outside the scheduler, and `->new` croaks when the 1024-slot fiber table is exhausted rather than creating a fiber that can never run.
- A fiber that yields during its initial run is now re-enqueued by the scheduler instead of being dropped, which previously could hang a regex-heavy workload.
- The scheduler no longer hangs when a fiber object is created but never spawned (`->new` without `spawn`): live-fiber tracking only counts fibers that have actually started, matching Coro's ready-queue semantics.
- `async`/`run` is now re-entrant: a nested `async` inside another `async` or inside a fiber shares the one run loop (like Coro's single global scheduler) and returns the block's value, instead of clobbering the outer scheduler and deadlocking.
- A destroyed fiber's id is kept out of the free list until every job it submitted has been reclaimed, so a stale completion can never be misdelivered to a (or corrupt) fiber that later reuses the id.
- Pending-job tracking now reads the C-side outstanding job count instead of a run-local counter, so jobs left over from a `stop`ped run are drained and handled by the next run instead of tripping `FATAL: deadlock detected` or sitting in the done-queue forever.
- `Semaphore` `up`/`adjust` skip stale (already destroyed) waiters instead of consuming a wake that should go to a live fiber.
- Channel constructors now reject a capacity below 1 instead of deadlocking on it at load time.
- The 1024-slot job queue is no longer fatal on the first try: `_submit_job` yields once and retries before croaking.
- `Future::set_result`/`set_error` wake awaiters exactly once instead of appending a duplicate `_wake_waiters` callback on every `await`.
- A `run` that dies with `FATAL: deadlock detected` now leaves the scheduler reusable: `$IS_RUNNING` is cleared and the run queues emptied before the message is thrown, instead of poisoning every subsequent `run`/`async`. The deadlock detector also snapshots the fibers alive before the run starts, so fibers leaked by an earlier deadlocked run can no longer make a healthy later run look deadlocked.
- `nursery` teardown no longer destroys a still-parked coroutine. When a child is cancelled while parked inside a nested wait (a `with_timeout` whose deadline fires mid-join, or an inner nursery cancelled out from under it), the child is reaped from inside its own resumed frame instead of being freed mid-park, which previously crashed the process (0xC0000005). Also fixed the nursery join's parent-interrupt branch, which was dead code (`eval { ...; undef }` never yielded the caught error) and silently swallowed an enclosing `with_timeout` timeout instead of cancelling the children.
- `await_sleep` now sleeps the full requested duration instead of inflating it: the worker's `TASK_SLEEP` branch waits on the queue condition variable with a timed wait (`SleepConditionVariableCS` on Windows, `pthread_cond_timedwait` on POSIX) rather than polling in 4ms quanta, so `await_sleep(1000)` returns in ~1s (Windows previously ~4s, because each `Sleep(4)` rounded up to the ~15.6ms timer tick) and 20ms deadline timers fire near their bound. `recall_sleep_jobs_for_fiber` now broadcasts the queue condvar, so an interrupted sleep aborts in sub-millisecond time instead of within one quantum.
- `with_timeout`'s deadline timer now registers on its own deadline token, so an early-finishing block recalls the timer's armed sleep job immediately instead of leaving a worker occupied for the full bound — the starvation that surfaced as t/034 subtest 5 failing intermittently once sleeps became accurate.
- An `Acme::Parataxis::Sync::Mutex` `lock()` that was handed ownership by `unlock()` at the same moment an interrupt (deadline/cancel) fired no longer strands ownership on the dying fid: the interrupted waiter passes its un-collected hand-off on to the next FIFO waiter, so a later fiber reusing that fid cannot be misread as the lock owner.

### Changed

- Spawned fibers run inline at spawn time.
- A scheduled fiber that dies while another fiber is awaiting it (or has an `on_ready` callback) no longer takes down the whole run loop: the error is delivered to the awaiting fiber's `await` instead, matching Coro-style rethrows.
- Interrupted waits deregister themselves from the sync primitive they were parked on before re-entering, so an id freed by cancellation can be safely reused by a later fiber without spurious wakes.
- The fiber registry is replaced by strong references to each fiber object in C.
- Fiber completion moved from a Perl method into C: the entry point writes state directly into the object's slots with `av_store`, and only dispatches callbacks when callbacks were actually registered.
- To save time on FFI boundary crossings, `spawn` now performs the whole create run sequence in a single call and builds the fiber object in C.
- Fiber objects are incrementally-filled AV*s instead of HV*s.
- On x86_64 ELF, context switching uses a hand written trampoline that only saves the callee-saved registers and stack pointer, avoiding `swapcontext`'s signal-mask syscall.
- `spawn` and `await` hot paths flattened by inlining helpers.
- Worker threads block on `select()` for the full `await_read`/`await_write` timeout instead of polling every 10ms, cutting idle syscalls by ~50x. On POSIX a shutdown pipe wakes any worker blocked in `select()` during `cleanup()`.

## [v0.0.10] - 2026-02-22

This version comes with a dynamic thread pool and an improved API.

### Added
- New ergonomic API using exported functions like `async { ... }`, `fiber { ... }`, and `await( $target )`.

### Changed
- Refactored native thread pool to use cond vars (`PARA_COND_*`) instead of busy polling, reducing idle CPU usage to near zero.
- Switched to a global job queue for the thread pool for better load balancing across worker threads.
- Reduced default fiber stack size from 4MB to 512K.
- Worker threads are now only spawned when the first asynchronous job is submitted.
- Increased `MAX_FIBERS` limit to 1024.
- Expose thread pool config with `set_max_threads` and `max_threads`.

## [v0.0.9] - 2026-02-21

Asynchronous HTTP::Tiny is basically a semi-automatic footgun.

### Fixed
- Resolved `AvFILLp(av) == -1` and `!AvREAL(av)` assertion failures in `Perl_pp_entersub` on `DEBUGGING` builds of Perl. This was fixed by ensuring Slot 0 (the argument array) of the next pad depth is correctly initialized during fiber context switches.

### Changed
- Increased fiber stack size to 4MB to provide better support for deep Perl calls and regex operations. This is a temp solution.

## [v0.0.8] - 2026-02-19

All the remaining failing smokers all had old versions of Affix and sure enough when I installed v1.0.6, I saw the same failure. Always the most obvious thing...

### Changed
- Require Affix v1.0.7

## [v0.0.7] - 2026-02-18

Another dist targetting a specific CPAN smoker. I cannot replicate the failure in https://www.cpantesters.org/cpan/report/f0ca1d14-0cfa-11f1-9988-e7d94c615303, so I'm just trying different things...

### Fixed?
- Arguments passed to a fiber might not be released until the fiber object was destroyed.

## [v0.0.6] - 2026-02-18

### Fixed
- Resolved assertion failures in `Perl_cx_popsub_args` and `Perl_pp_entersub` when running on a `DEBUGGING` build of Perl. This was fixed by ensuring `CvDEPTH` and pads are correctly restored during context switches. (I hope...)

### Added
- Added `--debug` build to GitHub Actions matrix to ensure future compatibility with Perl debugging builds.

### Changed
- Refactored `swap_perl_state` to be more robust regarding Perl's internal stack management.

## [v0.0.5] - 2026-02-18

### Changed
- I'm honeslty just throwing stuff at the wall. Between my local machines and GH CI workflows, I cannot replicate some of the failures I'm seeing from smokers which makes them virtually impossible to resolve.

## [v0.0.4] - 2026-02-17

### Changed

  - Attempt to only spawn max X threads in `t/006_parallel.t` where X is 3 or the `get_thread_pool_size()`? See https://www.cpantesters.org/cpan/report/ecf1410e-0c46-11f1-8628-aee76d8775ea
  - Recalculate `PL_curpad = AvARRAY(PL_comppad)` in `swap_perl_state`? See https://www.cpantesters.org/cpan/report/e7244bd8-0c44-11f1-b3ab-94362698fc84

## [v0.0.3] - 2026-02-17

### Changed
  - Adding an optional timeout to `await_read` and `await_write`.
  - Allow fibers to return complex data (AV*, HV*).

## [v0.0.2] - 2026-02-17

### Fixed
  - Fixed segfault in `coro_yield` by adding NULL checks for destroyed or missing fibers.
  - Resolved stall in exception handling by introducing `last_sender` tracking to prevent `parent_id` cycles.

### Changed
  - Made unit tests a lot more noisy

## [v0.0.1] - 2026-02-16

### Changes
  - It exists! It shouldn't but it does.

[Unreleased]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.10...HEAD
[v0.0.10]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.9...v0.0.10
[v0.0.9]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.8...v0.0.9
[v0.0.8]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.7...v0.0.8
[v0.0.7]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.6...v0.0.7
[v0.0.6]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.5...v0.0.6
[v0.0.5]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.4...v0.0.5
[v0.0.4]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.3...v0.0.4
[v0.0.3]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.2...v0.0.3
[v0.0.2]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.1...v0.0.2
[v0.0.1]: https://github.com/sanko/Acme-Parataxis.pm/releases/tag/v0.0.1
