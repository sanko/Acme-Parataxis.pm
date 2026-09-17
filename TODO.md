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
| **M3 — Sync family (WaitGroup/Mutex/Barrier/Once)** | **[x] done** | **`751820d`** | **t/036–t/039** |
| **M4 — Nursery (structured concurrency)** | **[x] done** | **`751820d`** | **t/040, t/042** |
| **M5 — Channel select** | **[x] done** | **`aafac21`** | **t/041** |
| **M6 — Generator** | **[x] done** | **`2198148`** | **t/043** |
| **M7 — Thin actors** | **[x] done** | **`7c3ae27`** | **t/044** |
| **M8 — Diagnostics & deadlock tracing** | **[x] done** | **this commit** | **t/045** |
| M9 — Scalable I/O (epoll/kqueue/IOCP) | not in core plan | — | — |
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

**Known boundary (fixed):** destroying a fiber that is *currently parked* (suspended
inside `yield('WAITING')`) then allocating a new fiber used to crash the process
(reproduced against pristine HEAD; 0xC0000005 — the parked fiber's live activation
slots in shared PadLists / the global CvDEPTH counters were freed, corrupting the next
fiber that entered the same sub). `destroy_coro` now skips the unsafe pad unwalk when
the fiber's context stack is not exhausted (`si_cxix < 0`), making destroy-while-parked
safe (t/046). Tests that abandon a parked waiter keep the fiber's object alive until
global destruction anyway, via `cleanup()` and the `@parked` stash.

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

## Milestone 3 — Sync family: WaitGroup, Mutex, Barrier, Once (**done** — `751820d`)

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

## Milestone 4 — Nursery (structured concurrency) (**done** — `751820d`)

Landed: `Acme::Parataxis::Nursery` (new file), `nursery()` in Parataxis.pm,
t/040 (10 subtests) and t/042 (3 subtests: R2 re-park regression). The M1 interrupt
machinery is what makes teardown safe: an aborted child that is still parked is
interrupted (not destroyed mid-park), unwinds and dies from inside its own resume — so the
M0 "do not destroy mid-park fibers" crash is now fixed in the C layer: destroy_coro only
unwinds pads when the fiber's context stack is exhausted (si_cxix < 0), so a parked
fiber leaves its shared PadList/CvDEPTH slots alone (see t/046).

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
- [x] t/040 subtest 2 — **"a failing child cancels its siblings".** De-flaked test-side:
      the `die 'boom'` child now fails immediately instead of `await_sleep(1)` first.
      Because `spawn` birth-parks, an immediate `die` still surfaces through the scheduler
      (never inline into the block), and the two 50ms sleepers are guaranteed to be parked
      when the cancel lands — no dependency on sleep-timer granularity (R1). 10/10 green;
      the underlying C latency stays logged as R1.
- [x] t/040 subtest 9 — no orphan fibers on success or failure exit path (live_fiber_count
      back to baseline).
- [x] t/040 subtest 10 — `nursery()` and `->spawn` croak outside a scheduled fiber.

Acceptance from the plan: all-children-join ✅; failure cancels siblings and rethrows ✅
(de-flaked test-side); cancellation propagated to nested tokens ✅; destructors run ✅;
no orphan fibers on any exit path ✅.

- [x] t/042 — direct regression for the R2 re-park branch (see R2 below): a nursery
      cancelling a child parked in a `with_timeout` await, and an enclosing `with_timeout`
      deadline firing while the child is parked in an inner nursery join. Both verify the
      still-parked coroutine is reaped without crashing and no fiber leaks. Retained for
      unwind semantics (the child dies through its own resume rather than being yanked);
      the crash guard is now covered by the M0 C fix and witnessed in t/046.

**Note:** nursery teardown of aborted children that are still parked hits the C-level M0
"do not destroy mid-park fibers" crash, which has since been fixed: destroy_coro now
skips the unsafe pad unwalk for a parked fiber (its context stack is not exhausted),
letting the shared PadList/CvDEPTH slots remain for normal later reuse (see t/046).

## Milestone 5 — Channel `select` (CSP multiplexing) (`[x] done`, `aafac21`)

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

## Milestone 6 — Generator (stackful iterator) (**done** — t/043)

API shipped as sketched: `Acme::Parataxis::Generator->new( sub ($yield) { ... } )`,
`->next`, `->is_done`. Acceptance all green in t/043.

As-built design (deviates from the original sketch, each change empirically driven):

- Pull is *asymmetric*: each `->next` resumes the private fiber with the C `coro_call`
  (not `coro_transfer`), and each `$yield->(...)` parks it back; the producer never
  enters the scheduler run queue. Exhaustion and body errors finish the fiber through
  the normal scheduler teardown.
- Errors are relayed, never thrown across a resume boundary: the fiber runs the body
  inside a fiber-local `eval {}` (the scheduler's own `G_EVAL` trap provably misses a
  die that fires on a resumed trip), and the caught `$@` is parked in a lexical that
  `next` dereferences and rethrows on the caller's stack.
- **Every generator lands on a non-first fiber slot.** Windows longjmp across the very
  first fiber a process allocates (fid 0) defeats every anchored JMPENV: a resume-die
  escapes as an uncaught die (exit 255) or 0xC0000005, in a code-shape-dependent way
  (any perl-visible store/return escapes; `print`/no-op work). The `coro_call` C guard
  does not help (the longjmp bypasses the anchored chain entirely). Fix: the first
  `Generator->new` parks one permanently parked reserved fiber (fid 0) and generators
  always start at fid >= 1, where the resume-die path has been stable since the M1
  suite. The underlying JMPENV/Windows-fiber mechanism was never fully explained —
  documented in Generator.pm/pod.
- **Abandoned generators drain, they do not get torn down mid-eval.** Calling
  `destroy_coro` on a suspended generator whose fiber carries an in-flight perl
  `eval{}`/closure frame poisons the perl state of *later* generators (0xC0000005);
  a plain suspended fiber destroys cleanly, and the original leak design never
  poisoned anything. DESTROY therefore resumes the fiber with a one-element arrayref
  drain marker; the yield closure `die`s on it; the fiber-local eval swallows it; the
  fiber finishes normally (perl unwinds its own scopes); `coro_call` reaps it. Vetted
  by torture probes (3x full run, destroyed-suspended, postdestroy). Residual risk,
  unexplored: the `destroy_coro` fallback in DESTROY for a drain that somehow fails.
- The reserved fiber makes `get_live_fiber_count()` read 1 (not 0) once any generator
  has been created; t/043's leak checks account for it.
- Known cosmetic: during process-wide global destruction a drain die can surface as
  "(in cleanup)" noise unless absorbed; DESTROY wraps the resume in `eval { ...; 1 }`
  which silences it while exit code stays 0.

## Milestone 7 — Thin actors (supervision deferred) (**done** in `7c3ae27` — t/044)

API shipped as sketched: `Actor->spawn( sub ($self, $msg) { ... }, [$capacity] )`,
`->ask($msg)` (returns a reply `Future`), `->send($msg)` (fire-and-forget),
`->stop`, `->is_alive`, `->fid`. All green in t/044 (9 subtests).

As-built notes:

- The actor is a dedicated fiber owning a bounded `Channel` mailbox (default capacity
  16); the loop is `get` -> dispatch -> repeat. `ask` tags the envelope with a reply
  `Future` and returns it; the handler's return value is `set_result` on it, a handler
  die is `set_error` on it (the actor keeps running). A `send`'s handler die is surfaced
  with `warn`. Since the actor parks on the channel semaphore, every scheduler nicety
  (with_timeout, cancellation, nursery) works around an `ask` unchanged.
- Backpressure is free: the bounded mailbox makes a too-fast sender park like any other
  blocked fiber.
- Graceful `stop` puts a unique stop marker into the mailbox; the loop keeps answering
  everything queued before the marker, then fails any asks that slipped in after it
  (so an awaiter never hangs on a dead actor) and finishes. `send`/`ask` croak while
  shutting down and after death. The marker is a scalar-ref sentinel compared by
  `ref && ==`, so arbitrary string/number/ref messages never collide with it.
- The marker check must guard `ref $value` before the `==` (a plain string message would
  otherwise warn under numeric eq).
- A deadlock hazard to document (not a bug): a handler that `ask`s *its own* actor and
  awaits the reply blocks forever, because the actor is busy inside that handler.
- An actor keeps the enclosing scheduler run alive until it stops (its loop fiber stays
  parked on the mailbox `get`); tests always `->stop` before their `async` block ends and
  assert the live-fiber count returns to baseline.
- `spawn` croaks outside a scheduled fiber (a parked-to-never-run actor would hang the
  process if created at top level).

Scope guardrail unchanged: no OTP-style supervision (restart strategies, links, exit
signals) — that stays a separate project. A handler failure is message-scoped by design.

## Milestone 8 — Diagnostics & deadlock tracing (**done** — t/045)

All three bullets shipped. As-built notes:

- `dump_fibers([$fh])` (exported): snapshot of every live fiber as
  `{ fid, state, reason => [reason, file, line] }` records; state is WAITING (parked, carries its wait_reason),
  READY (in the scheduler run queue), RUNNING (the fiber taking the snapshot), or RUNNABLE
  (live but neither parked nor queued — a fiber surrendered mid-quantum). With a filehandle the same
  report is printed (default: data only). Safe at top level: it reports fibers leaked by an earlier
  deadlocked run, which is the post-mortem entry point.
- The `FATAL: deadlock detected` branch of `run()` now dies with the same report restricted to fibers
  of the current run (preset/leaked fibers from older deadlocked runs are counted but omitted):
  path in `run()` builds the body from `_fiber_snapshot()` filtered by `%PRESET_FIBERS`.
- The cheap-first-cut stance paid off: the entire milestone rides on M0's wait_reason, no C changes,
  no stack capture. `wait_reason` sites are exact for direct waits (`await_sleep`, `await_read`,
  `await_write`, `fiber await`, `Future await`, `Channel get/put`, `Channel select`, semaphore down...)
  because the `_park` level targeting was tuned so the recorded frame is the *user's* call site
  (`Channel get` and `Semaphore down` land on the user line, not the module line — verified in t/045).
- A fiber that parks inline inside `fiber { ... }` (spawn runs its body until the first park) records its
  wait_reason with the fiber body's *source* line, not the spawn site — `caller(0)` inside the body lies
  (it is the spawn frame), so t/045 asserts the site by `__LINE__` arithmetic instead.
- Leaked fibers from a deadlocked run keep their wait_reason forever, which is what makes the post-mortem
  dump useful; DESTROY does not reap them (the design M0 made to keep the C table stable). Nice-to-have for
  later (explicitly deferred in the bullet): a Perl-level stack capture of the yield site — wait_reason's
  single [file, line] is the frame where the *wait* was entered, not a full backtrace.
- Coverage: t/045 (4 subtests) — sem-blocked + sleep-blocked classification with exact sites, RUNNING for
  the dumping fiber, READY for a yielded-back fiber, clean empty top-level state, the deadlock report's
  contents, and the post-mortem dump of the leaked fiber.

## Milestone 9 — Scalable I/O: epoll / kqueue / IOCP (**not part of the core plan**)

Kept on the list for context only. Will **not** be implemented in this project (own
decision, 2026-09-17): it is effectively a rewrite of the readiness path, and the current
`select()`-based scheduler with worker-thread FALLBACK covers the project's goals. Do not
schedule or block on this; treat its bullets as informational.

## Explicitly out of scope (don't build unless asked)

- OS-thread-level cancellation / forcibly killing fibers mid-execution.
- OTP-grade actor supervision and restart strategies.
- `ExceptionGroup` compatibility hacks (aggregation is a plain error object instead).
- Replacing the scheduler just to support select (select sits on Channel waiters).

## Regressions & known issues

Pre-existing bugs that must be fixed before a public release. They block suite-level
green and affect correctness or resource safety; unrelated to the milestones that
introduced them.

### R1 — C scheduler sleep-latency: `await_sleep` wakes late under load (RESOLVED)

**Fixed in C:** the worker's `TASK_SLEEP` branch (`lib/Acme/Parataxis.c`) now waits on the
queue condition variable with a timed wait instead of polling in 4ms quanta:
`SleepConditionVariableCS` on Windows (absolute `GetTickCount` deadline, wrap-safe) and
`pthread_cond_timedwait` on POSIX (`clock_gettime(CLOCK_REALTIME)` deadline, re-checking
`job->recall`/`threads_keep_running` per wake). `recall_sleep_jobs_for_fiber` broadcasts
the queue condvar, so an interrupted sleep aborts in sub-millisecond time.

Verified on Windows/Strawberry Perl: `await_sleep(1000)` ≈ 1.01s (was ~4s), `await_sleep(100)` = 100ms
(was ~400ms), `await_sleep(20)` ≈ 40ms (was 60–100ms; one OS tick granularity remains).
t/034 subtest 5 (deadline 20ms vs inner 100ms) passes 8/8 in loops and the full 45-test
suite is green when run without CPU contention. The t/040 subtest-2 flake and the t/006
baseline regression both trace to the same quantum cost and are resolved by it.

Two accompanying fixes keep the timing issue from resurfacing:

1. `with_timeout`'s deadline timer registers on its own deadline token
   (`lib/Acme/Parataxis.pm`), so an early-finishing block recalls the timer's armed sleep
   job immediately instead of leaving a worker occupied for the full bound — previously a
   subtle starvation race (the 2000ms bound in t/034 iteration 2 pinned a worker, leaving
   one free for iteration 3's two jobs). The timer swallows its own `Error::Timeout` via a
   local `eval`, so the run is never unwound.
2. A `Sync::Mutex` `lock()` handed ownership by `unlock()` at the same moment its deadline
   fires passes the hand-off on to the next FIFO waiter instead of dying with the lock
   owner field stuck on its (soon reused) fid ("Mutex is not reentrant" false positive).
   Semaphore was audited and needs no equivalent fix (its permit is consumed by the woken
   waiter at re-entry, never pre-transferred).

### R2 — with_timeout `re-park` branch: child still parked after interrupt (**resolved, retained**)

`lib/Acme/Parataxis.pm` (`with_timeout`, re-park branch): when the parent is
interrupted mid-`$child->await` while the child is still parked, the child is
interrupted and will die on its next resume. The re-park branch re-parks the parent,
registered for the child's death, so the scheduler lets the child run its own unwind
(unregistering from its tokens and running destructors) before this frame unwinds and
frees $child. The branch is no longer load-bearing for safety: the M0 crash it was
added to guard against (destroying a parked coroutine crashed the interpreter, fixed
in `t/046`) has been resolved at the C layer in `destroy_coro`. The branch is retained
so an abandoned child dies through its normal cancellation path rather than being
yanked — it is semantic correctness, not crash-prevention. **Covered by t/042** (three
subtests: nursery-cancel of a child parked in a `with_timeout` await; an enclosing
`with_timeout` deadline firing while the child is parked in an inner nursery join; and a
post-teardown sanity check that later `with_timeout` calls still work). Each asserts the
grandchild is cancelled, the still-parked coroutine is reaped, and the live-fiber count
returns to baseline. The crash itself is regression-tested in t/046.

### R3 — t/034 subtest 5 timing flake on macOS CI (**RESOLVED**)

t/034 subtest 5 ("repeated timeouts after catching one still work") failed intermittently
on macOS CI runners (both on `b524a96` gcc and `f84a6a2` clang, and historically):
iteration 1/3 arm a 20ms deadline timer while the block path slept 100ms, so a loaded
runner could let the block's `await_sleep(100)` finish before the timer fiber ran —
"third too-short bound timed out again" failed with no `$errors[2]`. Determined to be a
pure timing race, not a scheduler bug. **Fixed** by widening the "must timeout" inner sleep
from 100ms to 2000ms (the deadline interrupts the block at ~20ms, so the test costs no
extra time). Verified 8/8 loops and the full 46-file suite locally on Windows.

### R4 — Stress `pp_entersub` assert `!AvREAL(av)` aborts the fuzz (**FIX PENDING CI VERIFY**)

The debug-perl Stress workflow (`-DDEBUGGING` build, `PARATAXIS_STRESS_ITER=400
PARATAXIS_STRESS_SECONDS=30 cpanm -v .`) aborts with
`Assertion '!AvREAL(av)' failed, function Perl_pp_entersub, file pp_hot.c, line 6447`
(SIGABRT, Wstat 6) inside `t/040_nursery.t`. Fails on all four Stress jobs (macOS
a64-gcc, macOS x64-clang, Linux x64-clang, Linux x64-gcc), and is **pre-existing** (not
from R1/M0): the same assert failed on `a9713df` (M1, 2026-09-15); `7a57be59` (M0, same
day) passed. Local Windows (non-debug) perl can't hit the assert — t/040 with stress env
passes repeatedly — so verification requires a `-DDEBUGGING` perl (only the Stress CI
runner has one).

Root-cause theory (unverified): `_activate_current_depths` Pass 2
(`lib/Acme/Parataxis.c`, ~line 999) does `AvFILLp=-1; AvREAL_off()` on
`PadlistARRAY(pl)[CvDEPTH(cv)+1]` slot 0 — but `CvDEPTH`/PadLists are **global per CV,
shared across fibers**. If another fiber is concurrently active in a shared sub (yield,
wait helpers) at `CvDEPTH+1`, this clears a LIVE `@_` slot and flips `AvREAL`; a later
`pp_entersub` with args on that slot trips the assert. Same shared-PadList/global-CvDEPTH
corruption class as M0, located in `_activate_current_depths` instead of `destroy_coro`.

Evidence pinned from perl 5.42.3 source (non-`PERL_RC_STACK` builds, matching the Stress
perl — assert is the `#else` branch at pp_hot.c:6447):

- Perl *always* presents a `!AvREAL` `pad[0]` (`@_`) at a fresh `pp_entersub` with args:
  `pad_new`/`pad_push` create each depth's slot-0 AV with `AvREIFY_only`
  (pad.c L233, L2491), and `cx_popsub`→`Perl_clear_defarray` leaves it REIFY-only either
  by the simple clear + `AvREIFY_only` or by abandoning to a fresh `newAV_alloc_xz` that
  is also `AvREIFY_only` (pp_hot.c L6193-6201, L6207-6210). An `AvREAL` slot 0 therefore
  always means the fiber-switch bookkeeping desynced a shared PadList/CvDEPTH — slot 0 was
  left REAL by an interrupted reified `@_` (e.g. op-level `av_reify` from `\@_`/`for (@_)`)
  and then re-entered without the normal abandon-clean that a completed `cx_popsub` would
  have run.
- `_activate_current_depths` Pass 2 flips only `AvREAL_off` (leaving `AvREIFY` untouched).
  If the AV was REAL (REIFY already off), this produces perl's invalid "neither-REAL-nor-
  REIFY" state; a later op that stores into such an array re-turns it REAL
  (av.c `Perl_av_store`), so the flip is at best a partial repair of the invariant.

Debugging plan: (1) local Windows perl is not `-DDEBUGGING`, so the assert cannot fire
here — reproducing needs the Stress runner's debug perl (t/040 with stress env passes
locally). (2) Candidate fix: make Pass 2 restore the full `@_` invariant with
`AvREIFY_only` (not just `AvREAL_off`) — **APPLIED** (Parataxis.c Pass 2, committed with
the R3 fix; pending the next Stress run for verification on a `-DDEBUGGING` perl). It
flips a possibly-live shared slot's flags, so the deeper "PadList owned by other fibers"
hazard (M0-class) may still lurk; if Stress stays red after this, scope Pass 2 and
`_clear_pads_in_stack` to pads of the resuming/reaped fiber only. (3) Ship a
`DEBUGGING`-only resume-time check (verify each active shared-sub pad slot 0 is
`!AvREAL`, abort with the offending CV name) if more Stress failures need localization.