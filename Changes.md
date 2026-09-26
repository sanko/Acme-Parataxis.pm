# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No real changes to the Parataxis core, but I'm bundling a lot of 'real world' applications of concurrent systems. Borrowing a lot from Rust, Erlang, and even Java.

### Added

  - `Acme::Parataxis::Actor` runs one handler per message on a dedicated fiber behind a bounded `Channel` mailbox, so a slow handler backpressures its senders instead of buffering. `ask` returns a `Future` carrying the handler's return value or its error; `send` is fire-and-forget and only warns on a handler die. `stop` drains what is already queued and fails anything that arrived behind the stop marker. An unnamed actor whose last strong handle is dropped asks its mailbox fiber to stop and is collected, because that fiber only holds the handle weakly.

- `Acme::Parataxis::CancellationToken` lets any fiber register for cooperative cancellation. `cancel` interrupts every parked, registered fiber by throwing by throwing an exception at the park site.
- `Acme::Parataxis::Local` provides a per-fiber storage slot for ambient state that must not leak across fibers (tracing ids, span context, per-fiber handles).
- `Acme::Parataxis::Generator` is a stackful, lazily-pulled iterator.
- `Acme::Parataxis::Supervisor` implements OTP-style supervision trees, the heal-fast counterpart to `nursery`'s fail-fast. `supervise( $thing, name => $name )` registers an `Actor`, a nested `Supervisor`, or a factory, and `run` supervises until `stop` or an exhausted restart budget, draining every child either way. The strategy decides who restarts: `OneForOne` touches only the dead child, `OneForAll` restarts the whole set, `RestForOne` restarts the dead child plus everything started after it. `max_restarts` deaths inside `within` seconds trip the budget, and the next one dies with `Acme::Parataxis::Error::Supervisor` carrying `->failures`, `->primary`, and `->child`; `within => 0` keeps nothing in the window. Restarts build fresh instances, so a restarted supervisor is rebuilt from its configuration and a restarted actor gets a new mailbox, with any ask still in flight against the dead one failed there rather than left hanging.
- `Acme::Parataxis::Sync::Mutex` is a non-reentrant lock with real owner tracking: `lock`/`try_lock`/`unlock`/`guard`, plus `owner`/`waiters`. Releasing from a non-owner, relocking from the fiber that already holds it, and releasing a free lock all croak, and a contended `lock` is handed straight to the next waiter so nobody cuts the line.
- `Acme::Parataxis::Sync::WaitGroup` is a job counter shared across fibers: `add( $n )`/`done()` adjust it and `wait` parks until it reaches zero, with over-done and non-integer adds croaking.
- `Acme::Parataxis::Sync::Barrier` is a reusable rendezvous for `parties` fibers. `arrive_and_wait` releases exactly `parties` at the phase boundary, the last arriver included, and re-arms for the next round.
- `Acme::Parataxis::Sync::Once` runs an initializer exactly once across racing fibers. The first caller runs it and gets the return value, concurrent callers park until it finishes, and late callers no-op; an initializer that dies still leaves the `Once` done.
- `Acme::Parataxis::Sync::RwLock` is a writer-preferring read/write lock - any number of readers xor one writer. The read side (`read_lock`/`read_unlock`/`try_read_lock`/`read_guard`) is reentrant, releasing one hold per `read_unlock`; the write side takes the exclusive lock with the same owner tracking and strict FIFO hand-off `Mutex` uses. Once a writer queues, new readers are held back so a steady read stream cannot starve writers, and the `try_*` forms never park and never cut ahead of a queued waiter. A read-to-write upgrade croaks rather than deadlocking.
- `nursery( sub ($n) { ... } )` is structured concurrency. The block spawns children with `$n->spawn`, the call returns only once every child is done, and the first failure cancels and drains the rest. The failure is rethrown as `Acme::Parataxis::Error::Nursery`, whose `->primary` is the first real (non-cancellation) failure and whose `->failures` is every child error in spawn order. A block error cancels and drains the children, then propagates unchanged, and the group's `CancellationToken` is public as `$n->token` so a nested `with_timeout` or the caller can cancel the lot. A bare `fiber`/`spawn` inside the block is not adopted.
- `pmap( { concurrency => $n, }, sub ( $item ) { ... }, @items )` maps in parallel over a bounded fiber pool, handing at most `$n` items to workers at a time and returning the results in input order as a list or arrayref per `wantarray`. When a mapper dies, that error is recorded, the pool is cancelled, and it is rethrown once every worker has drained.
- `with_timeout( $ms, [ $token, ] $code )` runs a block as a child fiber and throws `Acme::Parataxis::Error::Timeout` in the caller if it doesn't finish in time, cleaning up the child and whatever it was blocked on while the scheduler keeps running. An optional token cancels the block early (`Error::Cancelled`) and a pre-cancelled one fails fast; a bound of `0` means no deadline. The bound is re-derived at every park the child enters rather than measured against the block's start, so work that spends its time parked in a primitive still gets the full budget, and a cancelled scope token fails the next park immediately instead of drifting.
- `with_cancel( $code )` wraps a block in a cancellation scope. The block runs on the calling fiber - no child is spawned - and every wait it enters is automatically interruptible by the single token `with_cancel` returns, so callers stop threading a token into each primitive. Cancelling it interrupts a wait parked right now and stamps the fiber so the next wait inside the scope fails fast. Scopes nest LIFO, share the park with an enclosing `with_timeout` deadline or nursery token, and unregister their waits on every exit. The return value is context aware: the token alone in scalar or void context, prepended to the block's values in list context.
- `Acme::Parataxis::Monitor` observes another fiber's death without owning it.
- `Acme::Parataxis::Channel::select` is CSP-style waiting on the first ready case among any number of channels. `Acme::Parataxis::Channel->select( [ $ch, 'get' ], [ $ch2, 'put', $v ], timeout => 1000, default => sub {...} )` probes the cases without yielding, parks on the first open one otherwise, and returns `( $channel, $value )`, or `( undef, undef )` on timeout, or the default block's value when nothing is ready. Cases are tried in random order so none can starve.
- `Acme::Parataxis::Channel::try_get` / `Acme::Parataxis::Channel::try_put` are the non-blocking forms, returning `( $ok, $value )` and `$ok` immediately instead of parking, and `select_waiters` reports how many fibers are parked in select on a channel.
- `Acme::Parataxis::Channel->new( ..., timeout => $ms )` gives every `get` and `put` a deadline without threading one in by hand, dying with `Acme::Parataxis::Error::Timeout` when it expires and recalling the timer on every exit so an early wake leaves nothing sleeping out the bound. `timeout => 0` (the default) and `timeout => undef` disable it, `select` honours the per-case channel default unless given an explicit `timeout` of its own, and the `try_*` forms stay non-blocking.
- `Acme::Parataxis::Ticker` is a drift-free interval timer. `Ticker->new( interval => $ms )` measures each period against an absolute tick boundary and sleeps only the remainder, so `while (my $t = $tick->wait_next) { do_work() }` fires on the boundary whatever `do_work` costs. Each tick is published into a capacity-1 channel after anything unread is drained, so at most one is ever outstanding and it is always the newest: a slow consumer loses periods rather than queueing a stale backlog. `stop` releases anything parked in `wait_next` with `undef` and recalls the sleep job, so a stopped ticker never keeps `run` alive. Introspection: `running`, `interval`, `pending`, `fired`, `dropped`, and `skipped` (boundaries the ticker leapfrogged rather than ticked).
- `Acme::Parataxis::RateLimiter` is a token bucket for rate-limited services. `RateLimiter->new( rate => $n, burst => $m )` starts full and refills at `rate` per second, and `acquire($n)` spends tokens, parking the calling fiber while the bucket cannot cover them. The bucket is an ordinary `Semaphore`, so a blocked acquire inherits the whole park path: interruptible by `with_timeout` and cancellation tokens, unregistering itself when interrupted so no later refill wakes a fiber that no longer wants a token, and never busy-waiting. Refills are driven by a `Ticker` and credit every whole token accrued since the previous wake on the wall clock, so the delivered rate holds even where timers are coarse, and stop refilling once the bucket is back at its ceiling. `stop` lets a parked acquirer through rather than stranding it and makes a later `acquire` croak. Introspection: `tokens`, `waiters`, `running`, `rate`, and `burst`.
- `Acme::Parataxis::Stream` is a chainable pipeline over bounded channels. `Stream->from_channel( $ch, stage_capacity => $n )` wraps a `Channel` as the head, and each of `map`, `filter`, `batch`, `batch_time`, and `throttle` is a factory that allocates a fresh bounded output channel, spawns one fiber looping the input, and returns a new `Stream` over the output, so the stages read in the order they compose. Backpressure is free: a full output channel parks the stage and the park propagates upstream, so a slow consumer throttles the raw producer instead of buffering without bound. The chain unwinds when its source shuts down, each stage flushing any partial batch and shutting its own output down. `batch_time` groups by an absolute deadline re-armed on every get, so a batch fires even when nothing further arrives, and `throttle` paces to at most `$per_s` items a second by sleeping only the remainder of the current slot. `consume` is the terminal stage, spreading arrayref batches into the callback's `@items` and passing anything else whole, and returns a fiber to await. `shutdown` releases a parked consumer end to end; `chain` and `cap` introspect the pipeline.
- Software transactional memory: `Acme::Parataxis::TVar` is a versioned cell, and `Acme::Parataxis->atomically( sub { ... } )` (also importable as a bare, `&`-prototyped block) runs a block as one transaction on the calling fiber. Reads are journaled, writes stay in a write set, and the commit is all-or-nothing: it first validates that every `TVar` the transaction read still holds its committed value and re-runs the block from the top on any conflict, so two opposite transfers between the same two `TVar`s resolve by one rolling back rather than deadlocking. `retry()` aborts and parks until a `TVar` it read changes (and croaks on an empty read set, which could never wake). Nested `atomically` blocks join the enclosing transaction and commit together, `with_timeout` and cancellation interrupt a parked transaction cleanly, and the usual STM warning applies - the block may run many times, so it must not have irreversible side effects.
- Future combinators: `wait_all( @futures )` and `wait_any( @futures )` aggregate any number of `Acme::Parataxis::Future` objects into a single future without awaiting on your behalf, and work outside the scheduler too. `wait_all` resolves once every input has settled - with no failures its value is one arrayref of every result in input order, and on any failure it settles with a wholesale copy of the first error without cancelling the losers. `wait_any` resolves the moment the first input settles, success or failure. Both are callable as exported functions or as class calls, both reject a non-future input, and `wait_all` with no inputs resolves immediately with `[]`. `Acme::Parataxis::Future` gained an `error()` accessor to tell a success from a failure without croaking.
- `dump_fibers()` reports the live fibers, their state (`WAITING`/`READY`/`RUNNING`/`RUNNABLE`), and - when parked - the reason and source site they yielded at, and prints the same as a human report when handed a filehandle. The scheduler's fatal deadlock message now carries that report, naming the parked participants instead of printing a bare `FATAL: deadlock detected`.
- Every park now hangs a bounded, user-side callchain off its `wait_reason`, so the record reads `[ $reason, $file, $line, $backtrace ]` with `$backtrace` an arrayref of `[ pkg, file, line, sub ]` frames running from just below the wait back to the fiber body, library frames filtered out. `dump_fibers` exposes the chain in its records and prints it as indented `at` lines, and the deadlock message lists each parked fiber's chain back to user code. The capture is a short `caller()` walk at every park, so it is bounded and configurable: `backtrace_depth( $n )` sets the cap, `backtrace_depth(0)` disables the capture entirely.
- Blocking waits now park through a single `_park`/`_resume_hooks` path that records a `wait_reason` readable via `$fiber->wait_reason` and fires `on_wake` hooks exactly once per resume, and `Semaphore`, `Signal`, `Future`, and `Channel` each gained `remove_waiter` to un-register a parked waiter. Every primitive above builds on it, so a wait interrupted by a token or deadline unregisters from whatever it was parked on.
- Event-loop integration: `Acme::Parataxis->attach_loop( $loop )`, `detach_loop()`, and `loop()` route `await_read`/`await_write`/`await_sleep` onto an existing CPAN event loop instead of the OS worker pool, so epoll, kqueue, and select come for free while the scheduler, fibers, and parks stay as they are. `Acme::Parataxis::Driver` dispatches on the attached loop's class and tracks every watch and timer it armed, and `detach_loop` - or the end of any `run` - unwinds them all. Two reference drivers ship: `Acme::Parataxis::Driver::Mojo` (`Mojo::IOLoop`) and `Acme::Parataxis::Driver::IOAsync` (`IO::Async::Loop`). The loop's callbacks only ever enqueue fibers, never run them, so there is no re-entry into the scheduler, and the `await_*` contract is unchanged: readiness values, `-1` on a wait's own timeout, and a throw from an enclosing `with_timeout`/`nursery`.
- Transparent unblocking: `Acme::Parataxis::Compat` installs `CORE::GLOBAL` overrides for `sleep`, `read`, and `sysread` so legacy synchronous code becomes cooperative without rewrites. It is opt-in - `Acme::Parataxis->enable_transparent_unblocking()` installs it, and only code compiled after the call is affected - and every override delegates to the raw `CORE::` builtin outside the scheduler, so top-level code and worker threads are unchanged. `sleep` maps to `await_sleep`. `read`/`sysread` park on `await_read` until the handle is readable, then perform one non-blocking read and write the result back through the caller's argument. That read is non-blocking on purpose: a raw blocking read on a stream handle waits for the I<whole> requested count rather than the first byte, and such a wait belongs to the OS thread and not to the fiber, so asking for more bytes than have arrived would stall every fiber in the run with no deadline or token able to interrupt it. Short reads are therefore the normal outcome, and the handle's original mode is put back before the override returns so code compiled before installation still gets the raw blocking read it expects. A handle with nothing to say keeps waiting rather than risk a raw read, so a `read` for data that never arrives parks its fiber indefinitely instead of stalling the process. `disable_transparent_unblocking` restores the saved globs and `transparent_unblocking()` reports the state. `select`, `alarm`, `time`, and C-level calls such as `DBI` are not covered, so code that needs those should reach for `await_read`/`await_write` or a worker thread explicitly.
- Deterministic mock time: `run( virtual => 1, code => sub { ... } )` puts every timer-based wait in the run on a virtual clock the test drives, so an hour-long timeout runs in microseconds. While it is on, `await_sleep`, `with_timeout` deadlines, `select` timeouts, channel wait bounds, `Ticker`, `RateLimiter`, and `Stream` all consult `Acme::Parataxis->mock_time()` / `->virtual_now()` and arm virtual timers instead of kernel sleeps, and the scheduler fast-forwards to the earliest pending deadline only when nothing is runnable and no jobs are outstanding, so real work always runs first. The test nudges time with `Acme::Parataxis->advance( $ms )`, and the clock is scoped to the outermost virtual run - nested runs ignore the flag, the clock starts at zero each time, and it is torn down at the end.
- Graceful shutdown: `run( on_shutdown => $opt )` has the outermost run install `SIGINT`/`SIGTERM` handlers for its lifetime and restore the previous ones afterwards. The first signal fires the run's `CancellationToken` and interrupts every fiber the run created, so they unwind and run their own cleanup; once everything drains, `run` returns the conventional status (130 for `SIGINT`, 143 for `SIGTERM`) instead of rethrowing the cancellations, and a second signal restores the old handlers and re-raises so a second Ctrl+C still kills the process. The option takes a plain true value, a code ref called with the fired token, or a ready-made `CancellationToken` whose `cancel()` begins the same drain in-process with no OS signal at all.
- Perl's `defer` keyword verified to work from within a fiber
- New exceptions: `Acme::Parataxis::Error`, `Acme::Parataxis::Error::Cancelled`, and `Acme::Parataxis::Error::Timeout`
- `fd_setsize()` reports the highest descriptor number this platform's `fd_set` can name: 1024 on Linux, macOS and FreeBSD, 256 on NetBSD, and 64 for the `winsock` `fd_set` on Win32. It bounds the descriptor *number* rather than how many handles you watch, so a process holding 300 sockets may be watching descriptor 605. Read it in C, because perl has no way to ask - `getconf FD_SETSIZE` is not a valid symbol and answers `20`, and `Fcntl::FD_SETSIZE()` dies at runtime.

### Fixed

- A fiber that completed after one or more yields could longjmp into freed stack memory (0xC0000005) while dispatching its completion callbacks: the jump environment pushed around the body was popped before the callbacks ran, so a callback that died made perl longjmp to the caller's `PL_top_env` on a different stack. The fiber-entry jump environment is now held for the fiber's whole lifetime and each fiber's `top_env` is saved and restored across context switches.
- A blessed exception raised by a fiber body - `Acme::Parataxis::Error::Timeout`, whose overloaded `""` stringifies to the empty string, being the easy case - was misread as a successful completion, because the completion check tested `SvTRUE($@)`. Completion now treats any blessed exception object as an error.
- `run()` no longer dies with a bare `Died at ... line N` after a clean exit. The scheduler loop sat inside an eval whose return value was taken as the success flag, so a normal run whose last expression was false left a defined-but-empty `$@` that was then rethrown as a fiber error. The eval now ends with an explicit success marker, and the attached driver's watches and timers are reset before any error is rethrown, so a blown-up run cannot wedge every later one.
- A `run` that dies with `FATAL: deadlock detected` now leaves the scheduler reusable: `$IS_RUNNING` is cleared and the run queues emptied before the message is thrown. The deadlock detector also snapshots the fibers alive before the run starts, so fibers leaked by an earlier deadlocked run can no longer make a healthy later run look deadlocked.
- A scheduled fiber that dies while another fiber is awaiting it, or has an `on_ready` callback registered, no longer takes down the whole run loop: the error is delivered to the awaiting fiber's `await` instead, matching Coro's rethrow behaviour.
- `await_sleep` now sleeps the full requested duration instead of inflating it. The worker's `TASK_SLEEP` branch waits on the queue condition variable with a timed wait - `SleepConditionVariableCS` on Windows, `pthread_cond_timedwait` on POSIX - rather than polling in 4ms quanta, so `await_sleep(1000)` returns in about a second where Windows previously took about four (each 4ms `Sleep` rounding up to the ~15.6ms timer tick), and 20ms deadline timers now fire near their bound. `recall_sleep_jobs_for_fiber` broadcasts the queue condvar, so an interrupted sleep aborts in sub-millisecond time rather than within one quantum.
- Destroying a fiber while it was still parked freed its live activation slots in the shared padlists and touched the global `CvDEPTH` counters of the subs it was inside (`yield`, the wait helpers), corrupting the *next* fiber that activated one of those subs and crashing the interpreter in `Perl_clear_defarray` - usually one id-reuse round later. `destroy_coro` now unwinds pads only when the fiber's context stack has been exhausted (`si_cxix < 0`, i.e. it was reaped after finishing); a parked fiber's shared slots are left for normal later reuse and its closures release their pads with the body CV. The `with_timeout` re-park branch that guarded against this is retained, so an abandoned child still dies through its own cancellation path.
- Perl's canonical REIFY-only state for `@_` landing pads is restored during fiber context switches: the activation pass uses `AvREIFY_only` instead of the bare `AvREAL_off` it had flipped since v0.0.9. Flipping only `AvREAL_off` left slot 0 in perl's invalid neither-REAL-nor-REIFY state, which a later `Perl_av_store` could re-turn REAL and make a `DEBUGGING` build abort in `Perl_pp_entersub` - the intermittent `t/040_nursery.t` stress failure seen on every recent push.
- A worker pool can no longer starve on an idle queue: `submit_c_job` now broadcasts rather than signals the job-queue condition variable, so a worker parked inside its timed sleep wait - which only re-checks its absolute deadline - wakes immediately to claim a freshly submitted job instead of sleeping out the rest of its bound.
- Fiber-parking subs (`yield`, the `await_*` family, `await_sleep`, `with_timeout`, `spawn`, `nursery`) no longer leave a reified `@_` behind when they park: each resolves its first argument's offset through `_arg_offset`, which reads the slot without reifying the caller's pad, empties `@_` before parking, and only pulls the sub itself out of the array when it was actually invoked with one. A reified `@_` left in a parked frame would later trip `Perl_pp_entersub`'s invariants when a different fiber activated the same sub at the same depth.
- `exit()` from a fiber that had already yielded, for example after `await_sleep`, no longer segfaults in `__longjmp`: the fiber's saved `top_env` pointed at the previous resume's already-popped guard, so the raw longjmp jumped to freed stack memory. The fiber-aware `exit()` interception - an opcode hook, a fiber-stack catch in `para_entry_point`, and a re-raise on the caller stack in `coro_call` - previously existed only on Windows and now applies on every platform.
- The thread pool no longer stalls a freshly submitted job behind unrelated long sleeps. `submit_c_job` grew the pool before counting jobs that were *already* pending and before inserting the job it was submitting, so a lone submission against a pool whose every worker sat in a long `TASK_SLEEP` saw `pending == 0`, spawned nothing, and queued until one of those sleeps ended - which is what made `with_timeout` look broken whenever a third fiber happened to be sleeping. Growth now runs after the insertion and spawns exactly the deficit (`pending - idle`, with a worker counted busy from the moment it claims a job), and the default pool size gained a floor of 8 so a machine reporting one or two cores can no longer pin it at the two-worker seed.
- A shared subroutine no longer loses its lexicals when one fiber parks inside it while another parks deeper.
- The worker pool's read and write jobs no longer write off the end of a stack `fd_set`. `FD_SET` is a bare array index with no bounds check, and the two `fd_set`s live in `worker_thread`'s own frame, so a descriptor at or past `FD_SETSIZE` landed in the neighbouring set and then in the frame's stack canary - which is a silent stack corruption, not a wrong answer, and only surfaces as an abort at some unrelated later point. `FD_SETSIZE` is not the same everywhere: 1024 on Linux and the BSDs that inherited it, 256 on NetBSD, and a 64-entry bitmask on Win32. `select()` would have rejected the oversized `nfds` with `EINVAL` regardless, so an unrepresentable descriptor is now refused up front and reported as not ready, the same answer a deadline produces. glibc used to abort on the spot with its own `FD_SET` assertion; libcs without one wrote past the set quietly. Parking reads on more descriptors than the platform's `FD_SETSIZE` can name is the way to reach this, which is why it went unnoticed.
- `get_cpu_count` no longer returns an indeterminate core count when `sysctl` fails on the BSDs, including NetBSD. The `uint32_t` was left uninitialized and the return value unchecked, and the caller divides by the result (`thread_id % cpu_count`); a failure is now treated as one core and clamped by the pool as before.
- `await_read` and `await_write` on an attached event loop no longer register a watch for a descriptor the loop's `fd_set` cannot name. The pool path already refused these (see above), but the driver path handed the handle straight to the loop library, and there is nothing to widen there: the `fd_set` belongs to the loop, and the descriptor is the loop's to bind. A watch registered anyway either never fires - parking the fiber until its deadline, with the data sitting readable the whole time - or corrupts the loop's own state. Both are now refused up front and answer `-1`, the same value a deadline produces, with one warning per process naming the descriptor and the ceiling so a workload sized on another OS is visible rather than silent.

### Changed

- Fiber limits are now policy rather than a compile-time constant. Get and set the cap with `max_fibers()` and `set_max_fibers( $count )`.
- The default fiber limit is now 65536 rather than a hardcoded 1024, so a program that assumed spawning past 1024 would croak keeps going until it hits the new limit. The old behaviour is still available by pinning `set_max_fibers(1024)`.

## [v0.1.0] - 2026-09-21

This started as a silly little diversion in February but I'm using this in actual projects now. I've even used it to shake out bugs in Affix.

I might move it out of the Acme namespace...

Anyway, the major win is that fiber hot path has been moved from Perl into C and roughly tripled context swapping throughput with no change to the public API.

### Added

- `Acme::Parataxis::Channel`: a buffered FIFO message queue for producer/consumer patterns between fibers. Writers block when full, readers when empty; a capacity of `1` makes it a rendezvous point. Built on two semaphores.
- `Acme::Parataxis::Future`: a one-shot placeholder for an eventual computation result. A producer fires `set_result`/`set_error` exactly once; consumers pick it up with `await`/`result` or register an `on_ready` callback.
- `Acme::Parataxis::Semaphore`: a counting semaphore with no ownership: blocked fibers are parked (no busy-wait) and resumed FIFO as permits become available.
- `Acme::Parataxis::Signal`: a two-state flag with a FIFO queue of waiters. `send` latches the signal so a later `wait` consumes it immediately, while `broadcast` wakes every queued waiter at once (and drops if nobody is waiting).

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

### Changed

- Spawned fibers run inline at spawn time.
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

[Unreleased]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/sanko/Acme-Parataxis.pm/compare/v0.0.10...v0.1.0
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
