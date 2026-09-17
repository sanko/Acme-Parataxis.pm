# TODO — Concurrency Toolkit Roadmap

A living plan for taking Acme::Parataxis from a low-level coroutine primitive to an
ergonomic, production-grade concurrency toolkit.

This file is the **checkpoint**: every milestone's tasks and acceptance criteria live
here as checkboxes, ticked as they land. Status legend: `[x]` done, `[ ]` pending.
A milestone's status line names the commit where it landed on `dev`.

## Progress

| Milestone | Status | Landed | Tests |
| --- | --- | --- | --- |
| M0 — waiter removal, wait_reason, on_wake | [x] done | `7a57be5` | t/031, t/032 |
| **M1 — cancellation tokens & with_timeout** | **[x] done** | **`a9713df`** | **t/033, t/034** |
| M2 — fiber-local storage | [x] done | `4540ed0` | t/035 |
| **M3 — Sync family (WaitGroup/Mutex/Barrier/Once)** | **[x] done** | **uncommitted (user commits)** | **t/036–t/039** |
| M4 — Nursery (structured concurrency) | blocked (R1) | — | t/040 (R1 flake) |
| **M5 — Channel select** | **[x] done** | **uncommitted (this commit)** | **t/041** |
| M6 — Generator | deferred | — | — |
| M7 — Thin actors | deferred | — | — |
| M8 — Diagnostics & deadlock tracing | deferred | — | — |
| M9 — Scalable I/O (epoll/kqueue/IOCP) | long-term | — | — |
| Explicitly out of scope | keep list stable | — | — |

## Principles (decisions that shape everything below)

1. **Cancellation is fiber-cooperative only.** A fiber parked at a suspension point
   (`yield('WAITING')`) can be offered an interrupt; a fiber executing *inside* a
   worker-thread job (compute, blocking FS) cannot — no OS-thread cancellation, ever.
   Cancellation points are the re-entry points after `yield('WAITING')`.
2. **Waiter removal is the foundation.** `Semaphore.@waiters`, `Signal.@waiters`, and
   `Future` awaiters have no way to unregister a waiter. select, `with_timeout`, and
   cancellation all need it. Do Milestone 0 first and land it separately.
3. **Everything on the main interpretation thread is cooperative and atomic between
   yields** — non-blocking probes (`try_get`/`try_put`) need no locks against other
   fibers. Concurrency hazards only appear across a worker-thread boundary.
4. **No Java-isms.** No built-in `ExceptionGroup` cargo-cult: nursery failure is a
   wrapped/aggregated error that dies in the parent, with the failure list reachable.
5. **Ship bundles, not a zoo.** Small primitives (WaitGroup/Barrier/Once) live under one
   `Acme::Parataxis::Sync` family rather than ten freestanding classes.
6. **Keep the deadlock detector honest.** A wait that can never fire and has no timeout
   must still trip `FATAL: deadlock detected` (Parataxis.pm:315). Timeout/cancellation
   jobs count as outstanding work, so they naturally suppress a false positive.
7. **Fiber locals key off the fiber *object*, not the fid.** An inline-completed fiber's
   fid is recycled in C with no Perl-side completion hook, so a fid key would survive into
   the recycled id and leak stale state (verified during M2). The object is the fiber's
   identity for as long as it lives; entries are pruned on completion and DESTROY.

## Milestone 0 — Enabling changes (`[x] done`, `7a57be5`)

- [x] `remove_waiter($fid)` (and callback-form removal) on `Semaphore`, `Signal`,
      `Future`, `Channel`. Semantically: drop the waiter from the FIFO without consuming
      a permit/signal. Test: wait, remove while parked, `up`/`send`, assert the waiter is
      not resumed and a later real waiter is woken instead. (t/031)
- [x] **Wait-reason attribution.** Record a human-readable reason + caller site at every
      parked wait on the currently running fiber (an attribute on the fiber object).
      Consumed by diagnostics and the deadlock report. Implemented as `_park` /
      `_resume_hooks` + `$fiber->wait_reason`; every blocking wait in the toolkit parks
      through it. (t/032)
- [x] A public `current_fid`-safe helper for scoped cleanup on wake (used by select,
      timeout, cancellation): "on wake, run an unwind closure". Implemented as
      `on_wake` (hooks fire exactly once on resume from a park; guarded by `%PARKED` so
      cooperative `yield` does not fire them).

**Known boundary (pre-existing, still open):** destroying a fiber that is *currently
parked* (suspended inside `yield('WAITING')`) then allocating a new fiber crashes the
process (reproduced against pristine HEAD; 0xC0000005 on teardown). Destroying *finished*
fibers is fine. Do not destroy mid-park fibers until [M4] needs it; tests that abandon a
waiter keep the parked fiber's object alive until global destruction instead
(`cleanup()` reaps them; keep parked fibers in a `@parked` stash).

## Milestone 1 — Cancellation tokens & `with_timeout` (`[x] done`, `a9713df`)

Landed: `Acme::Parataxis::CancellationToken`, `with_timeout`, `Acme::Parataxis::Error`
(+ `::Cancelled`, `::Timeout`), the per-fiber `F_INTERRUPT` slot, `%PARK_REGS` dereg
registry, and the observer-gated rethrow in `_handle_run`. Full suite 34 files / 271 green.

- [x] `Acme::Parataxis::CancellationToken`: `register`/`unregister`/`cancel` (idempotent)/
      `cancelled`/`kind`/`waiters`; register-against-cancelled marks the next park for
      interrupt (fail-fast semantics).
- [x] `with_timeout( $ms, [ $token, ] $code )`: child-fiber block with a deadline token;
      throws `::Timeout` (or `::Cancelled` for a user token) in the caller; `ms == 0` =
      no deadline; pre-cancelled token fails fast without running the block.
- [x] Per-fiber `F_INTERRUPT` slot: interrupt = set marker + enqueue the parked fid;
      the marker persists until the fiber's next `_park` re-entry throws
      `Error::Cancelled`/`Error::Timeout` (wait_reason carried), and is dropped if the
      wait completes naturally first.
- [x] `%PARK_REGS` dereg registry: `_park` registers a callback that removes the fiber
      from its primitive waiter list; run only on interrupt-throw (natural wakes drop
      it), closing the fid-reuse stale-wake hazard.
- [x] Observer-gated death: a scheduled fiber that dies while watched (awaited or
      `on_ready` callbacks) no longer kills the run loop — the error is rethrown at the
      parent's `await`/`call` instead.
- [x] Error classes with `message`/`kind`/`wait_reason` (`::Timeout` adds `seconds`).
- [x] Tests t/033 (token: bookkeeping, wake parked, running-fiber next-park, idempotence,
      unregister protection, wait_reason/kind, stale-id reuse, destructors during unwind,
      Channel blocked-getter) and t/034 (timeout: inline fast-path, parked-fast,
      ::Timeout catchable + run continues, nested fiber, repeated timeouts, token cancel,
      pre-cancelled fast-fail, error pass-through, zero bound, Future then reuse,
      validation croaks).
- [x] Docs + changelog + MANIFEST; tidyall clean.

Implementation notes worth keeping:

- A bare `try { } finally { }` (no `catch`) is a **syntax error** on perl 5.42.3 — the
  child body uses `eval { $code->() }` + `$@` capture for unwind cleanup instead.
- The C job table has no job cancellation, so an armed deadline timer pins the run until
  its sleep job completes; a cancelled child's in-flight sleep job holds its fid until
  the job finishes (run-pinning accepted and documented).

## Milestone 2 — Fiber-local storage (**done**, `4540ed0`)

API sketch:

    my $vl = Acme::Parataxis::Local->new;     # one slot, readable/writable
    $vl->set(42);
    $vl->get;                                  # undef until set

    fiber { $vl->set('child'); ... $vl->get ... }

Design: a Perl-side stash per fiber (`%FIBER_LOCALS`), so no C changes. Each `Local`
object owns a monotonic id (never a refaddr — a recycled refaddr must not alias a newer
Local's slot). The stash is keyed by the fiber **object**, not its fid: a spawned fiber
that finishes inline has its fid recycled in C with no Perl-side completion hook, so a fid
key would survive into the recycled id and inherit stale values (verified empirically).
The object is the fiber's identity for as long as it lives; the stash is pruned whenever
the fiber is observed done (`is_done`, the fiber `await`) and on `DESTROY`, so a fresh
fiber - even one reusing a recycled fid - always starts empty (Principle 7). Does *not*
follow dynamic scope the way `local` does — that is the point. Designed for tracing IDs,
span context, ambient DB handles that must not leak across fibers.

- [x] `Acme::Parataxis::Local` module: `new( default => ... )`, `get`, `set`; croaks
      outside the scheduler; `get` returns `default` when unset, the stored value (even
      `undef`) once set.
- [x] `%FIBER_LOCALS` (keyed by fiber object, not fid — an inline-completed fiber's fid
      is recycled in C with no Perl hook, so a fid key would leak into the recycled id)
      + `_fiber_locals` in `Acme::Parataxis`; stash pruned in `is_done`, the fiber
      `await`, `_mark_done`, and `DESTROY`.
- [x] t/035 acceptance:
      - [x] value is per-fiber; invisible to siblings and main (children never see a
            value the parent set, and vice versa);
      - [x] survives `await`/`yield` mid-block;
      - [x] main fiber readable/writable too (covered by the isolation subtest);
      - [x] stash entries pruned once a fiber is done (observed via `%FIBER_LOCALS`);
      - [x] a recycled fiber id never inherits a dead fiber's values (1024-spawn sweep).
- [x] Docs (`Local.pod`, `Parataxis.pod` section), Changes.md, MANIFEST.
- [x] Full suite green (35 files / 277) + tidyall clean; committed `4540ed0` on `dev`.

## Milestone 3 — Sync family: WaitGroup, Mutex, Barrier, Once (**done** — commit pending, user commits)

Landed: `Acme::Parataxis::Sync` (base: `_fid`/`_park`/`_wake`) plus `::Sync::Mutex`,
`::Sync::WaitGroup`, `::Sync::Barrier`, `::Sync::Once`, each with its own POD, and
t/036–t/039. Every wait parks through `_park` with a dereg closure, so `with_timeout`/tokens
abort it and the waiter unregisters itself first (M1 machinery). Not committed yet — the
user is handling commits once the work is finished.

API sketch:

    my $m  = Acme::Parataxis::Sync::Mutex->new;
    my $wg = Acme::Parataxis::Sync::WaitGroup->new;
    my $b  = Acme::Parataxis::Sync::Barrier->new( parties => 4 );
    my $o  = Acme::Parataxis::Sync::Once->new;

    async {
        $m->lock; ... $m->unlock;
        { my $guard = $m->guard; ... }
        $wg->add(1); fiber { ...; $wg->done }; $wg->wait;
        $b->arrive_and_wait;
        $o->do( sub { /* exactly once */ } );
    }

- [x] `Mutex` — true owner tracking: `lock`/`unlock`/`guard` (plus `try_lock`, `owner`,
      `waiters`). `release` from a non-owner croaks (`not the owner`), same-fiber relock
      croaks (`not reentrant` — decided non-reentrant, no depth count), `unlock` on a free
      lock croaks (`not locked`). The owner decides: `unlock` hands the lock directly to
      the next FIFO waiter (owner set at handoff), so a ready fiber can't cut in line.
- [x] `WaitGroup` — `add($n)`, `done`, `wait` (parks the fiber until counter hits 0).
      Worked out as a count + a FIFO waiter list (a Signal per se isn't needed): the last
      `done()` to reach zero wakes everyone parked in `wait`. `add` validates integers and
      croaks when the counter would go negative; since a cooperative scheduler never
      interleaves `add`/`wait`, the Go "no Add while positive-awaiting" rule is moot.
- [x] `Barrier` — `$n` fibers `arrive_and_wait`; all proceed at the phase boundary. The
      last arrival releases the parked parties *and itself* (it never enqueues itself,
      avoiding a self-run) and re-arms `remaining`/`generation` for the next round.
- [x] `Once` — exactly-once init across racing fibers; late callers wait for the runner.
      Runner gets the init's return value; waiters/late callers get nothing (Go-style). If
      the init dies, the owner gets the exception, the Once is still done, and the parked
      callers proceed. Non-reentrant (an init calling `do` again on its own fiber croaks).

Acceptance (all in t/036–t/039):

- [x] Mutex ownership/foreign-release tests: non-owner `unlock` croaks and leaves the lock
      usable; busy-wait-free FIFO handoff under contention; `try_lock` never steals; guard
      auto-releases on scope end *and* on exception; interrupted `lock` unregisters so the
      next holder is served; all operations croak outside a scheduled fiber.
- [x] WaitGroup across pool-spawned `async` jobs: a group shared across fibers/jobs where
      `wait` lifts only after every `done`; top-up-reuse; over-done / non-integer `add`
      croak; interrupted `wait` unregisters and later waits still work.
- [x] Barrier releases exactly `$n`: per-phase lockstep invariant (each party crosses each
      phase exactly once, never past the boundary alone); slow-party could not hold
      anyone; reusable across 3 generations; interrupted arrival unregisters without
      blocking the phase; `parties < 1` croaks at construction.
- [x] Once runs the init exactly once and blocks till done: 5 racing callers → 1 run;
      waiters blocked until completion, late callers no-op; dying init still completes; a
      later caller is never re-entered.

Implementation notes worth keeping:

- The fast path of `Mutex::lock` must *take* the lock (`if (!defined $owner) { $owner =
  $fid; return 1 }`), not just return on a free owner — the original sketch returned
  without claiming, which let every inlining fiber free-lock.
- Handoff is atomic in `unlock`: `$owner = $next` happens before the waiter is enqueued,
  so the lock is never owner-less while waiters exist.
- Barri last arriver must not push/enqueue itself: it releases the parked parties and
  returns; enqueuing itself would run the same fiber twice.
- A fiber `fiber {}` spawns and runs **inline** to its first park (Coro semantics): tests
  that want genuine contention make the first holder sleep *inside* the lock.
- `is_deeply` is not in this repo's Test2 import set (`Test2::V1 -ipP`) — use
  `is join(...)`-style comparisons.

## Milestone 4 — Nursery (structured concurrency) (**in progress**)

Landed: `Acme::Parataxis::Nursery` (new file, uncommitted), `nursery()` in Parataxis.pm,
t/040 with 10 subtests. The M1 interrupt machinery is what makes teardown safe: an aborted
child that is still parked is interrupted (not destroyed mid-park), unwinds and dies from
inside its own resume — so the M0 "do not destroy mid-park fibers" crash is sidestepped,
not fixed.

API sketch:

    Acme::Parataxis->nursery( sub ($n) {
        $n->spawn(sub { fetch_user_profile });
        $n->spawn(sub { fetch_user_orders });
    } );   # returns only when all children are done

Design:

- Nursery spawns child fibers; the block does not return until **all** children complete.
- On the first unhandled child exception: cancel all siblings (M1), then the nursery dies
  in the parent with an aggregated error (failure list reachable via an accessor — no
  Java ExceptionGroup; see Principle 4).
- Cancellation of children uses M1 tokens; children created *inside* the block run through
  the injected `$n->spawn` API (a bare `fiber`/`spawn` inside the block is **not** adopted
  — it is an independent fiber the block owns itself; covered by t/040 subtest 8).
- The nursery token is public (`$n->token`) so user code (or a nested with_timeout) can
  cancel the whole nursery like a failed sibling (t/040 subtest 4).

Progress:

- [x] t/040 subtest 1 — all children joined before the block returns; block value comes back.
- [x] t/040 subtest 3 — cancellation propagates into nested waits and tokens (nested
      `with_timeout` deadline token and user-registered tokens are both cancelled).
- [x] t/040 subtest 4 — the public nursery token cancels the children when user-cancelled.
- [x] t/040 subtest 5 — a block error cancels its children, drains them, rethrows the block error.
- [x] t/040 subtest 6 — **a nursery inside `with_timeout` propagates the timeout and drains
      its children.** Fixed a dead branch in `_join()`: the parent-interrupt path was
      unreachable because `my $e = eval { ...; undef }` always returned undef (the caught
      error is in `$@`, not the eval value), so `next unless $e` always fired. The timeout
      was swallowed, children never cancelled, `with_timeout` appeared to succeed. Rewrote
      `_join()` to split success/failure via `my $ok = eval { $child->await; 1 }; my $e = $@;`
      and moved `$c->is_done` outside the drain-loop `eval` (a second instance of the same
      trap that could leak a coroutine). Trace now shows: `join got parent-interrupt` →
      grandchildren interrupted with `kind=cancel` → `join draining done, rethrowing
      Error::Timeout`; probe: `t_err=Timeout done=0`. Verified against old code: only the
      fixed build exercises the parent-interrupt branch.
- [x] t/040 subtest 7 — destructors of in-flight children run during cancellation.
- [ ] t/040 subtest 2 — **flake: "a failing child cancels its siblings".** ~1-2 in 12 runs,
      both on the fixed *and* the pre-fix code (pre-existing, unrelated to the `_join`
      rewrite). Failure signature: `kinds=plain` (only the 'boom' error), `s1=1 s2=1` (both
      50ms sleepers ran to completion). Root trace: the 1ms `die 'boom'` child's sleep job
      fires ~156ms late under scheduler load — after the 50ms siblings have already
      completed and unregistered. The `_observe` token cancel then interrupts nothing
      (`fids=` empty) because no children remain registered. This is C scheduler sleep
      latency (armed sleep jobs wake late under load), not nursery join logic.
- [x] t/040 subtest 9 — no orphan fibers on success or failure exit path (live_fiber_count
      back to baseline).
- [x] t/040 subtest 10 — `nursery()` and `->spawn` croak outside a scheduled fiber.

Acceptance from the plan: all-children-join ✅; failure cancels siblings and rethrows ✅
(after the subtest-2 flake is de-flaked); cancellation propagated to nested tokens ✅;
destructors run ✅; no orphan fibers on any exit path ✅.

Open items before M4 is "done":

- [ ] **Subtest-2 flake (pre-existing):** make the C scheduler wake armed sleep jobs
      promptly even under load, so a 1ms `await_sleep` beats 50ms siblings deterministically
      (deadline timer observed firing at age 28-61ms vs the requested 10ms). Either fix in
      C (sleep quantum / job recall behaviour) or make the test thresholds robust to coarse
      sleeper granularity.

**Note:** nursery teardown of aborted children that are still parked bumps into the M0
"do not destroy mid-park fibers" crash — plan to fix that here with the M1 interrupt
path (an interrupted fiber unwinds and dies from inside its own resume, which the runtime
already reaps).

## Milestone 5 — Channel `select` (CSP multiplexing) (**done**, commit pending — this commit)

Landed: `select` as a plain package sub on `Acme::Parataxis::Channel` (perlclass keeps methods instance-bound),
`try_get`/`try_put` non-blocking ops, a private per-channel `@select_waiters` list, `select_waiters()` introspection,
and t/041 (11 subtests). Design matches the sketch below; one deviation: the one-shot re-poll flag is unnecessary —
after a wake each registration round is fresh, so the natural "re-probe then re-register" loop gives at most one
re-poll per wake already.

Implementation notes worth keeping:

- `select` is a plain sub (not a `method`) because perlclass methods can't be invoked on the class name; it croaks
  on bad cases, a missing `timeout` range, a non-CODE `default`, zero cases, and calling it outside a scheduled
  fiber. Cases are shuffled with `int rand` and committed in a single pass, so no ready case can starve.
- Timeout is an M1 deadline token armed once (`$deadline //= CancellationToken->new`, `$timer_armed` guard) and re-used
  across re-parks — a spurious wake can never stack timers. "Register, then arm" closes the lost-wakeup window.
- On an interrupt wake, `_park`'s dereg closure unregisters select waiters and the deadline token; the interrupt is
  thrown by `_park` itself. A deadline we own surfaces as `(undef, undef)`; an enclosing `with_timeout`/nursery
  timeout (which cancels *our* token nowhere) propagates as `Error::Timeout` instead of being swallowed.

Acceptance (all green in t/041): get-ready vs put-ready; random choice under repeated contention; timeout;
default; shutdown unblocks selectors with remaining items; waiter lists empty after every return; argument
validation. Subtests 9-10 cover the deadlock/share-the-channel cases.

## Milestone 6 — Generator (stackful iterator) (**deferred**)

API sketch:

    my $gen = Acme::Parataxis::Generator->new( sub ($yield) {
        $yield->($_) for @large_tree;
    });
    while (defined(my $v = $gen->next)) { ... }

Design: a producer fiber suspended by symmetric transfer. `coro_transfer` already exists,
so the mechanics are available — but the producer must be kept *out of the scheduler run
queue*, and interactions between transfer-based coroutines and the main loop need care.
Yields work deep inside nested subs without `yield from` — that's the selling point, not
bounded_depth iteration. Keep in mind it pulls against the scheduler model, so it lives
outside the nursery/cancellation world unless we teach it to park.

Acceptance: deep-nested yield; lazy pull (no work before first `next`); `next` after
exhaustion returns undef; DESTROY releases the fiber.

## Milestone 7 — Thin actors (supervision deferred) (**deferred**)

API sketch:

    my $actor = Acme::Parataxis::Actor->spawn( sub ($self, $msg) {
        return 'pong' if $msg->{cmd} eq 'ping';
    });
    my $reply = $actor->ask({ cmd => 'ping' })->await;   # Future
    $actor->send({ cmd => 'log' });                      # fire-and-forget

Scope guardrail: fiber + mailbox (`Channel`) + `send`/`ask`+timeout. **Out of scope for
now:** OTP-style supervision (restart strategies, links, exit signal propagation) — a
separate project that would dominate the roadmap. Revisit only if a concrete use-case
demands it.

## Milestone 8 — Diagnostics & deadlock tracing (**deferred**)

- [ ] `Acme::Parataxis->dump_fibers`: every living fiber, state (RUNNING/WAITING/…), the
      resource it's parked on (reason string from M0), and the caller site where it yielded.
- [ ] Enrich `FATAL: deadlock detected` (Parataxis.pm:315) into a report listing each
      waiting fiber + reason + site, e.g. "Fiber #4 waiting on Channel 0x… (worker.pl
      line 87)".
- [ ] Cheap first cut rides entirely on M0's wait-reason; a Perl-level stack capture at
      the yield site is a nice-to-have later.

## Milestone 9 — Scalable I/O: epoll / kqueue / IOCP (**long-term, not blocking**)

Honest framing: this is a rewrite of the readiness path, not a feature. `select()` caps at
`FD_SETSIZE` (~1024), which matches the current 1024-fiber cap — not yet a wall. Keep
worker threads for compute and blocking FS; move network readiness onto the main scheduler
via epoll/kqueue/IOCP, and/or ship an integration shim to drive/embed
AnyEvent/IO::Async/EV. Schedule after everything above; nothing gates on it.

## Explicitly out of scope (don't build unless asked)

- OS-thread-level cancellation / forcibly killing fibers mid-execution.
- OTP-grade actor supervision and restart strategies.
- `ExceptionGroup` compatibility hacks (aggregation is a plain error object instead).
- Replacing the scheduler just to support select (select sits on Channel waiters).

## Regressions & known issues

Pre-existing bugs that must be fixed before a public release. They block suite-level
green and affect correctness or resource safety; unrelated to the milestones that
introduced them.

### R1 — C scheduler sleep-latency: `await_sleep` wakes late under load

The C sleep job table dispatches armed sleeps in 4ms quanta via `usleep(slice * 1000)`
(`lib/Acme/Parataxis.c:617-632`). Under concurrent load (many fibers, heavy trace
output, or back-to-back test runs), the 4ms quantum stretches and `await_sleep(N)` can
wake at 5–10× the requested time. The `recall_sleep_jobs_for_fiber` fast-path (C:813)
works when an interrupt fires *while* the sleep is active, but a timer that is still
armed when its fiber completes (e.g. `with_timeout`'s deadline timer) stays in the table
until its natural expiry. Two concrete consequences:

1. **t/034 subtest 5 — deterministic failure (8/8):** third iteration of
   `with_timeout(20, sub { await_sleep(100) })` completes inline (child_done=1,
   deadline_cancelled=empty), meaning the 100ms sleep returned before the 20ms deadline
   timer's `await_sleep(20)` woke and cancelled the token. The deadline fires at
   `age=15ms` with `fids=` (no registered fibers) because the child already completed
   and unregistered. `with_timeout` returns normally instead of throwing
   `Error::Timeout`.

2. **t/040 subtest 2 — intermittent flake (~1-12/12):** `await_sleep(1)` for the
   `die 'boom'` child fires at ~156ms under load, long after both 50ms siblings have
   completed and unregistered. The `_observe` token cancel hits `fids=` (empty), so
   siblings were never cancelled. Failure list has only the boom error (`plain`) instead
   of `cancelled,cancelled,plain`. Confirmed present on both fixed and pre-fix code
   (same rate) — purely scheduler timing, not nursery logic.

3. **t/006_parallel.t test 2 — baseline sleep-timing regression:** `await_sleep(1000)`
   measures ~4s whenever an uncommitted scheduler experiment
   (`recall_sleep_jobs_for_fiber`, a 4ms-quantum `Sleep(slice)` dispatch loop in the C
   scheduler) is in the build. On Windows each `Sleep(4)` rounds up to the OS tick
   (~15.6ms), so the 4ms quantum actually costs 4x. This is the *experiment*, not the
   baseline: reverting `lib/Acme/Parataxis.c` restores 1.0-1.03s sleeps, and the failure
   is independent of the M5 run()-deadlock fix. Keep the experiment out of any release
   build until the quantum path is fixed or dropped.

**Fix:** either improve the C sleep dispatch (tighter quanta, or add a fast-path
recall when a token is cancelled that is not the timer's own token), or make the
affected tests robust to coarse granularity (e.g. increase deadlines relative to inner
sleeps, or remove timing-sensitive subtests from the critical path). Both require C
changes; note the `quantum` variable and the `usleep(slice * 1000)` loop in the C
source.

### R2 — with_timeout `re-park` branch: child still parked after interrupt

`lib/Acme/Parataxis.pm:319-328`: when the parent is interrupted mid-`$child->await`
while the child is still parked, the child is interrupted and will die on its next
resume, but its coroutine cannot be destroyed mid-park (the runtime crashes). The
re-park branch re-parks the parent, registered for the child's death, so the scheduler
reaps the child's coroutine before this frame unwinds. This branch needs a focused
test: a `with_timeout` whose deadline fires while the child is parked in an inner
`nursery { }` join, verifying the child's coroutine is reaped without crashing. (M4
subtest 6 exercises this indirectly but should be supplemented with a direct unit
test.)