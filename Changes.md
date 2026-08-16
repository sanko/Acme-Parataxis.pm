# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The hot path has been moved from Perl into C and roughly tripled context swapping throughput with no change to the public API.

### Changed

- Spawned fibers run inline at spawn time: a body that completes without yielding never touches the scheduler queue at all.
- The fiber registry is replaced bye strong references to each fiber object in C.
- Fiber completion moved from a Perl method into C: the entry point writes state directly into the object's slots with `av_store`, and only dispatches callbacks when callbacks were actually registered.
- `spawn` now performs the whole create+run sequence in a single FFI call (`spawn_fiber`) instead of two FFI boundary crossings and builds the fiber object in C.
- Fiber objects are incrementally-filled arrayrefs instead of hashrefs, indexed via the `F_*` slot constants (cheaper to build and to index).
- On x86_64 ELF, context switching uses a hand written trampoline that only saves the callee-saved registers and stack pointer, avoiding `swapcontext`'s signal-mask syscall.
- `spawn` and `await` hot paths flattened by inlining helpers.

### Fixed

- A fiber that yields during its initial run is now re-enqueued by the scheduler instead of being dropped, which previously could hang a regex-heavy workload.
- The scheduler no longer hangs when a fiber object is created but never spawned (`->new` without `spawn`): live-fiber tracking only counts fibers that have actually started, matching Coro's ready-queue semantics.
- `async`/`run` is now re-entrant: a nested `async` inside another `async` or inside a fiber shares the one run loop (like Coro's single global scheduler) and returns the block's value, instead of clobbering the outer scheduler and deadlocking.
- The scheduler now reports a deadlock instead of spinning forever when every fiber is blocked (parked on a semaphore, channel, or future) and nothing is runnable: `FATAL: deadlock detected, N fibers blocked and nothing runnable`.

### Added

- `Acme::Parataxis::Channel` - Coro::Channel-style message queues built on counting semaphores: `new`, `put`, `get`, `shutdown`, `size` (and the undocumented `adjust`). Writers park while the queue is full, readers park while it is empty, and a size-`1` channel is a rendezvous point.
- `Acme::Parataxis::Semaphore` - Coro::Semaphore-style counting semaphores: `new`, `_alloc`, `count`, `down`, `up`, `try`, `adjust`, `wait`, `waiters`, `guard`. Blocked fibers park (no busy-waiting) and are resumed in FIFO order as permits become available.
- `Acme::Parataxis::Signal` - Coro::Signal-style binary semaphores / event flags: `new`, `wait` (with optional callback), `send`, `broadcast`, `awaited`. `send` wakes one waiter or remembers the signal; `broadcast` wakes everyone or loses it; a `wait` callback fires in the sending fiber's context.
- Unit tests ported from Coro's own suite, now running on the real modules: a producer/consumer bounded channel (`t/018_coro_channel.t`, from Coro `t/02_channel.t` + `eg/prodcons`), a counting semaphore with guards, parking, `try`, `adjust`, `wait` and `shutdown` (`t/019_coro_semaphore.t`, from Coro `t/15_semaphore.t`), and signals (`t/025_coro_signal.t`, from Coro `t/16_signal.t`).

### Fixed

- `exit()` inside a fiber now works on Windows x64. The CRT cannot `longjmp` across stacks, so a fiber's exit previously crashed the process with `0xC0000028` (`STATUS_BAD_STACK`, reported as status 40). The exit is now captured on the fiber stack by a fiber-aware `pp_exit`, recorded, and re-raised on the caller's stack where perl's whole JMPENV chain lives on one stack; nested fiber exits unwind one stack level at a time to the main stack.
- The exit-code subtests in `t/021_exit.t` now genuinely pass on Windows (previously they skipped when a Windows perl could not report a spawned child's status, and the child code now runs from a temp `.pl` file because `cmd.exe` mangles nested quotes in an inline `-e` command line). See perl5 GH #20081 for the broken spawn status reporting that motivated the `!errorlevel!` path.
- Standalone producer/consumer example `eg/coro_prodcons.pl`, modelled on Coro's `eg/prodcons`.

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
