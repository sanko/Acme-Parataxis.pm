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
| M3 — Sync family (WaitGroup/Mutex/Barrier/Once) | next | — | — |
| M4 — Nursery (structured concurrency) | next | — | — |
| M5 — Channel select | next (after M1) | — | — |
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
7. **Fiber locals key off the fiber *fid*, not the object.** The stash dies when the fid
   is released (fiber completes or is destroyed), so a recycled fid can never inherit a
   dead fiber's state.

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

## Milestone 3 — Sync family: WaitGroup, Mutex, Barrier, Once (**next**)

API sketch:

    my $sem = Acme::Parataxis::Local->new;     # placeholder, see below

- [ ] `Mutex` — true owner tracking: `lock`/`unlock`/`guard`, `release` from a non-owner
      croaks, same-fiber relock croaks (or reentrant with depth count — decide).
- [ ] `WaitGroup` — `add($n)`, `done`, `wait` (parks the fiber until counter hits 0).
      Built on a count + Signal/Future.
- [ ] `Barrier` — `$n` fibers `arrive_and_wait`; all proceed at the phase boundary.
- [ ] `Once` — exactly-once init across racing fibers; late callers wait for the runner.

Acceptance: ownership/foreign-release tests; WaitGroup across pool-spawned `async` jobs;
Barrier releases exactly `$n`; Once runs the init exactly once and blocks till done.

## Milestone 4 — Nursery (structured concurrency) (**next**)

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
- Cancellation of children uses M1 tokens; children created *inside* the block are
  implicitly enrolled (no `->spawn` needed for run-blocks — decide whether nested plain
  `spawn`/`fiber` inside the block is adopted or rejected).

Acceptance: all-children-join; failure cancels siblings and rethrows; cancellation is
propagated to nested tokens; destructors for in-flight children run; no orphan fibers on
any exit path (verify live_fiber_count == 0 after).

**Note:** nursery teardown of aborted children that are still parked bumps into the M0
"do not destroy mid-park fibers" crash — plan to fix that here with the M1 interrupt
path (an interrupted fiber unwinds and dies from inside its own resume, which the runtime
already reaps).

## Milestone 5 — Channel `select` (CSP multiplexing) (**next**, after M1)

API sketch:

    my ($chosen, $val) = Acme::Parataxis::Channel->select(
        [ $metrics  => 'get' ],
        [ $jobs     => 'put', $job ],
        timeout => 500,                 # returns (undef, undef) on timeout
        default => sub { 'fallback' },  # non-blocking fast path (none ready)
    );

Design (corrected from the original sketch):

- **Phase 1 — probe, no yield:** shuffle cases, `try_get`/`try_put` on each, commit first
  match and return. `default` (if given) runs here when nothing is ready — never parks.
- **Phase 2 — register, then sleep:** if nothing ready and no `default`: register the
  current fid on every involved channel's private `@select_waiters`; *then* submit the
  deadline job (if any) — ordering matters, see below; then `yield('WAITING')`.
- **Wake:** any channel `put`/`get`/`shutdown` wakes *only* the select waiters it may have
  satisfied (per-channel waiter lists — no broadcast storm). On wake, deregister from all
  channels and the deadline token (M1), then re-run Phase 1. Guard re-entry with a
  one-shot flag so a spurious multi-channel wake re-polls once, not N times.
- **Timeout = M1 deadline, not a special sleep:** register first, then arm the deadline —
  avoids the lost-wakeup window an `await_sleep`-based timeout creates (yielding between
  probe and registration lets a `put` slip through).
- **Deadlock interplay:** with a timeout armed, the timeout job counts as outstanding work
  and suppresses the deadlock fatal; with neither timeout nor `default`, an all-idle
  select correctly deadlock-detects.

Acceptance: get-ready vs put-ready; random choice prevents starvation under repeated
contention; timeout; default; shutdown unblocks selectors with remaining items; waiter
lists empty after every return (no leaks via `awaited`/internal counts).

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