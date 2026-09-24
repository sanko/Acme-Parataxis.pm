# TODO

If you're reading this, [#7](https://github.com/sanko/Acme-Parataxis.pm/discussions/7), [#9](https://github.com/sanko/Acme-Parataxis.pm/discussions/9), and [#10](https://github.com/sanko/Acme-Parataxis.pm/discussions/10) shipped in full across the first chapter's Milestones M1-M8 and Cards 1-10. Everything the articles spelled out is done: nursery, cooperative cancellation and deadlines, CSP channel multiplexing, stackful generators, actors, the sync-primitive family, deadlock tracing, event-loop drivers, supervision trees, STM, async streams, the ticker, the rate limiter, and gevent-style transparent unblocking.

This file holds the running plan for the next chapter. Each entry below was either trailed off in an article ("I have another handful of ideas but I need to turn random phrases into actual explanations") or deliberately left in the Backlog because it was waiting on API design or more thought. Cards are numbered continuing the first chapter (11+); Cards 11-12 shipped in full (see below), everything else in here is not shipped yet.

## Progress

- [x] **Card 11** - Future combinators `wait_all` / `wait_any`
- [x] **Card 12** - `pmap` (bounded-pool parallel map)
- [x] **Card 13** - cancellation scopes (`with_cancel`)
- [ ] **Card 14** - `defer` (run cleanup on every fiber exit)
- [x] **Card 15** - monitor & linked death
- [ ] **Card 16** - actor hot-code swap + named registry
- [ ] **Card 17** - `with_timeout` re-entrancy polish
- [ ] **Card 18** - `Channel->new( timeout => $ms )`
- [ ] **Card 19** - deterministic mock time
- [ ] **Card 20** - `spawn_blocking`
- [ ] **Card 21** - trace propagation
- [ ] **Card 22** - graceful shutdown

## Chapter 2: ergonomics, observability, and scaling out

Future combinators, deterministic testing, CPU-heavy execution contexts, and application lifecycle.

### Future Combinators & Parallel Map (`pmap`) - shipped

For everyday Futures/Promises you want to wait on several *discrete* outcomes at once, not just one. Nursery and `Channel->select` cover structure and races; this covers plain result collection.

- **Card 11 - `Future->wait_all(@futures)` / `wait_any`**: `Promise.all` / `Promise.race` equivalents. *Shipped:* exported `wait_all(@futures)` and `wait_any(@futures)` (also class-callable as `Acme::Parataxis->wait_all(...)`), each returning an aggregate `Acme::Parataxis::Future`; t/060.
- **Card 12 - `pmap`**: a bounded-pool parallel map, `my @results = Parataxis->pmap({ concurrency => 5 }, \&download, @urls)`. *Shipped:* t/061.

### Deterministic Testing / "Mock Time"

A 1-hour `await_sleep`/`Ticker` deadline cannot be unit-tested without waiting an hour. A virtual-time scheduler mode makes the impossible testable in milliseconds.

- **Card 19 - Mock time**: when every fiber is parked on timers, advance the scheduler's virtual clock instead of the wall clock.

### Execution Contexts / CPU-bound Pools

Blocking C jobs (sleep, socket I/O) already offload to the OS thread pool, but heavy *Perl* math (image processing, huge JSON) stalls cooperative fibers. Ship it to a dedicated background interpreter instead.

- **Card 20 - `spawn_blocking`**: Loom/`worker_threads`-style offload of a Perl closure to a background Perl interpreter thread (thread-enabled Perl only), returning a `Future`.

### Observability and Trace Propagation

`Acme::Parataxis::Local` is per-fiber ambient state, but distributed contexts (OpenTelemetry trace IDs, span context) must flow into children when a fiber spawns.

- **Card 21 - trace propagation**: an opt-in `spawn` hook that copies selected `Local` slots from parent to child.

### Graceful Shutdown & Application Lifecycle

`Supervisor->stop` and C-level `cleanup()` cover managed trees; a daemon needs a coordinated whole-process shutdown on `SIGINT`/`SIGTERM`.

- **Card 22 - graceful shutdown**: a global cancellation token fired from `run()`'s signal handling, cancelling the top-level nursery, letting `DESTROY`/`defer` finish, and exiting cleanly instead of dying instantly.

---

## Roster (Cards 11+)

### Card 11 - Future combinators: `wait_all` / `wait_any`

**Source**: the chapter plan and #7's "wait on multiple discrete outcomes." **Status**: shipped (exported `wait_all`/`wait_any` subs, also callable as `Acme::Parataxis->wait_all( ... )` / `Acme::Parataxis->wait_any( ... )`; each returns an aggregate `Acme::Parataxis::Future`).

**API** (exported functions, class-callable on `Acme::Parataxis`, not `Future` class methods):

```perl
my $all = wait_all( $f1, $f2, $f3 );            # arrayref of results, in input order
my $all = Acme::Parataxis->wait_all( $f1, $f2 );# same, class-callable form
my $any = wait_any( $f1, $f2, $f3 );            # the first future to settle, copied
```

**Semantics / decisions**:

- `wait_all`: the aggregate future resolves when every input has resolved. `->await`/`->result` returns an **arrayref of each input's result, in input order** (`Promise.all` style), or the stored error of the first input to fail (`Promise.all` rejects fast). Inputs are not cancelled on rejection - they are independent and keep running; their later results are discarded.
- `wait_all` with **zero futures** resolves immediately with `[]` (matches `Promise.all([])`).
- `wait_any` aggregates the **first future to settle** - success or failure - copying its result *or* its error wholesale (`Promise.race`). The losing futures are untouched.
- An input that is already resolved fires `on_ready` synchronously, so both combinators work on already-done futures without a scheduler.
- Both must croak on non-`Future` inputs; both are pure-Perl on the existing `on_ready`/`set_result`/`set_error` machinery - no scheduler or C changes, no fiber required to *construct*.

**Acceptance** (t/060_future_combined.t): the input-order result list; reject-fast on the first failure; `[]` for an empty `wait_all`; `wait_any` copying the first winner (success and failure each); pre-resolved inputs; mixed already-resolved/pending inputs; croaks on a non-future.

### Card 12 - `pmap` (parallel map over a bounded fiber pool)

**Source**: chapter plan + #7's "provide it as a one-liner". **Status**: shipped (exported `pmap`, also class-callable as `Acme::Parataxis->pmap(...)`).

**API** (exported, class-callable):

```perl
my @results = Parataxis->pmap( { concurrency => 5 }, sub ($url) { download($url) }, @urls );
my @results = Parataxis->pmap( sub ($x) { $x * 2 }, 1 .. 1_000 );        # concurrency defaults to @items
```

**Semantics / decisions**:

- Bounded fiber pool: at most `concurrency` mappers in flight at once (default: one fiber per item). Built on `WaitGroup` + `Channel` (the `#7` note): a shared job channel feeds the workers, a `WaitGroup` bars the caller until every worker drains, and results land in `@results[$original_index]` so the **return is always in input order** even when items finish out of order.
- Mapper code runs in a fiber, so it may `await`, park, or use any primitive. A mapper that dies **cancels the pool and the error is rethrown** once every worker has stopped - mirroring nursery's fail-fast, with the first error winning; the `Error::Cancelled` unwinds from cancelled workers are swallowed (the siblings are stopped at their next item boundary, not collected into an aggregate).
- Must run inside a scheduled fiber (the caller parks while the pool works). Croaks on the mainline, like `nursery`.
- Empty item list: returns immediately with `()`. `concurrency` must be a positive integer.
- Needs no C changes: `WaitGroup`, `Channel`, and `spawn` cover it.

**Acceptance** (t/061_pmap.t): input order under out-of-order completion; the concurrency cap is honored (observe max in-flight == the bound); per-item park/await works; first error cancels siblings and is rethrown; empty list; mainline croak; non-integer concurrency croak.

### Card 13 - cancellation scopes (`with_cancel`)

**Source**: #7's "cancellation points that can immediately throw a catchable exception" + Backlog ("register/unregister groups of waits as one unit"). **Status**: API designed; waiting on a slot.

The missing cancel ergonomic is *threading* a token everywhere. Today `with_timeout`/tokens interrupt one explicit wait at a time; a scope makes **every wait entered inside it** interruptible by one token, automatically.

```perl
my $tok = Acme::Parataxis::with_cancel( sub {
    $ch->get;            # both parks auto-register on $tok; cancel() kills each one
    $sem->down;
});
# normal exit: all interior waits were deregistered; $tok is inert
```

**Semantics / decisions**:

- `with_cancel` runs its block on the current fiber and returns the scope token (and the block's value, list-context aware). While the block is active, `_park` consults the fiber's **cancel-scope stack** and registers every interior wait with the innermost scope token - at no explicit cost to the caller.
- Cancelling the scope token mid-block interrupts every wait currently parked on it (each throws `Error::Cancelled` at its park site). Interior code that nests `with_timeout` keeps its own deadline semantics; the scope token composes (both might fire; the wait ends at whichever comes first, and teardown unregisters it from the other).
- Nesting: scopes stack LIFO; leaving a scope pops its auto-registration state. `nursery`'s token, `with_timeout`'s deadline, and a scope token can all share one park - cancellation unregisters the waiter from each.
- Implementation hooks the existing fiber struct: a new slot for the scope stack, and `_park` reads it (level-2 `wait_reason` site attribution is unaffected). Pure-Perl on `CancellationToken`; the only scheduler touch is the park-time stack read.
- Return convention stays consistent with `with_timeout`: block value on success, the normal error on failure, `Error::Cancelled` when the scope itself is cancelled by an outer scope.

**Acceptance** (new `t/062_cancel_scope.t`): every interior park is interruptible by the scope token; a wait finished *before* cancel stays done; cancelling after normal exit is a no-op; nested scopes (inner cancel only kills inner waits); composition with `with_timeout` (deadline beats scope and vice versa); no stale registrations leaked by normal or thrown exits.

### Card 14 - `defer` (run cleanup on every fiber exit)

**Source**: Backlog ("like Go's `defer` for fiber exit paths"). **Status**: API designed; needs a teardown slot.

A fiber body that allocates a lock, a token registration, or a file handle needs it released on *every* exit - return or throw, normal or cancelled.

```perl
fiber {
    my $m = Sync->lock;
    defer { $m->unlock };
    ... body ...     # unlock runs whether this returns or dies
};
```

**Semantics / decisions**:

- `defer { ... }` records a block on the **current fiber**, run when the fiber exits: after the body returns *and* when the body dies (including `Error::Cancelled` from a token). Blocks run **LIFO** (inner-most first), each in the fiber, on the exit path before the coroutine is reaped.
- A `defer` block that itself dies is folded into the exiting error: if the body already died, the first `defer` death chains; if the body returned, the first `defer` death is what the fiber throws to its `await`-er.
- Owning the exit path is the tricky part, shared with `cleanup()` at the C level: the fiber must run pending `defer`s from *both* the normal-return path *and* the rethrow path after `eval`/catch inside the body, before the coro is destroyed. This is a fiber-struct field (an arrayref pushed by `defer`), drained in the scheduler's fiber-finish code.
- `run { defer {...} ... }` and nursery children inherit the guarantee for free because it rides the universal fiber teardown.
- A `defer` named the same as fiber-exit cleanup must not conflict with Actor `stop`/`on_death` or Supervisor drain - it is strictly per-fiber, LIFO, always-ran.

**Acceptance** (new `t/063_defer.t`): LIFO order; runs on normal return; runs on die; runs on cancellation; a dying `defer` folds into the body error / becomes the error after a normal body; a single `defer` registered twice runs twice; `run`-level and nursery-child fibers both run them; zero leaked-fiber reports in `dump_fibers`.

### Card 15 - monitor & linked death (observe a fiber's death without owning it)

**Source**: #9's "Erlang/OTP" note + Backlog ("observe another fiber's death without owning it"). **Status**: API designed; needs a lightweight watcher.

Actors have `on_death`; plain fibers do not. A monitor lets any code learn when an arbitrary fiber ends - normally or crashed - and pass the reason on.

```perl
my $mon = Acme::Parataxis::Monitor->new( $fiber );   # or track by fid
$mon->await;                                          # value: undef (clean) or the death error
# or
Acme::Parataxis->link( $f };                         # linked pair die together, like Erlang links
```

**Semantics / decisions**:

- `Monitor->new($target)` returns a `Future`-like handle that resolves exactly once, when the target fiber exits: `undef` for a clean end, the death error for a crash. It never owns the target (no `stop`, no join-without-error semantics); it just reports.
- Backed by the fiber's existing `F_CALLBACKS`/`on_ready` slot, so it needs no scheduler change - a monitor is just an `on_ready` that observes `is_done`/`error` after the target finishes. Watching an already-dead fiber fires immediately.
- **Link** is a distinct beast: `link` pairs two fibers so when one dies, the other is cancelled too (with a `Error::LinkedDeath` carrying the first's error) - the Erlang `link` one-way kill, not the monitor's observation. Links need a tiny C-level (or fiber-table) registry per fiber of linked peers and a cancel on death.
- Scope: start with **monitor** (pure Perl, high value for supervisors/tests) and ship **link** as a follow-up card if the registry stays simple. Do not conflate them: observe vs. die-with.

**Acceptance** (new `t/064_monitor.t`): resolves `undef` on a clean target; resolves with the error on a crash; already-dead target fires immediately; fires exactly once; monitor does not affect the target's lifetime (target still reapable); works on nursery/actor/root fibers.

### Card 16 - actor hot-code swap + named registry

**Source**: #9's "Erlang/OTP" note + Backlog. **Status**: API designed; needs an `Actor` slot + a name table.

```perl
my $actor = Acme::Parataxis::Actor->spawn( sub ($self, $msg) { ... }, name => 'worker-1' );
my $by_name = Acme::Parataxis::actor('worker-1');       # registry lookup, undef when gone
# hot code swap: replace the handler for subsequent messages atomically
$actor->swap( sub ($self, $msg) { ...new handler... } );
```

**Semantics / decisions**:

- **Named registry**: `Actor->spawn( ..., name => $name )` registers the actor; `Parataxis->actor($name)` (or `whereis`) returns the handle or `undef`. Registration is removed when the actor stops/dies, `DESTROY` included, so a dead actor never answers a lookup. The name is a process-wide unique key (like `Local`'s monotonic id), never a refaddr. Need to decide: colliding name on spawn - croak, or replace (Erlang `register` croaks).
- **Hot swap**: `$actor->swap($code)` replaces the handler atomically at the next message boundary. An in-flight handler finishes with the old code; the swap is visible to every message dispatched after it returns. No Erlang fully-sync-and-verify dance needed for a v1 - just a field swap on the actor object (and the fiber body already reads `$self->{code}` per message, so it is a one-word change). `respawn`/supervisor already rebuild actors; swap merely avoids the rebuild when the *behavior*, not the resource, changed.
- Both are pure Perl on `Actor` - no scheduler or C involvement.

**Acceptance** (new `t/065_actor_registry.t`): `actor($name)` finds a registered actor; `undef` after death; spawn name collision policy; a swapped handler runs for messages arriving after the swap while the in-flight one uses the old code; double swap; registry cleanup after `stop` and after a crash.

### Card 17 - `with_timeout` re-entrancy polish

**Source**: Backlog. **Status**: mostly defined by t/042; refines it.

Nested `with_timeout` and an inner wait that re-parks after an interrupt must keep one deadline, not stack timers, and the outer bound must keep applying after the inner one fires.

```perl
with_timeout( 2000, sub {
    with_timeout( 20, sub { $ch->get } );   # inner wins at ~20ms
    $ch->get;                               # outer deadline still armed: must now fire at ~2000ms
});
```

**Semantics / decisions**:

- A wait that re-parks after an interrupt (`_resume_hooks` repark) must re-apply the *same* enclosing deadlines - the current path already re-arms the shared deadline token, so the polish is: **derive each new park's effective deadline from the enclosing `with_timeout`s**, honored in order (innermost wins; the outermost is the backstop), with no timer armed twice for the same bound.
- Interaction with **Card 13** (cancel scopes): the scope token and the deadline coexist on one park; whichever fires first tears the wait down and the other's registration is dropped.
- Reference: t/042 (`with_timeout_repark`) already locks the repark shape; this card widens it to *nested* timeouts and out-of-order re-arms. Purely a `_park`/`with_timeout` adjustment, no C.

**Acceptance** (extend `t/042`): nested deadlines honored innermost-first; after the inner fires, the outer bound still kills the re-parked wait; a re-park never arms a second timer for the same bound (observe `get_outstanding_jobs()`); interplay with a cancel scope's token.

### Card 18 - `Channel->new( timeout => $ms )`

**Source**: #7's own channel sketch (`Channel->new( capacity => 1024, timeout => 500, ... )`); today only `Channel->select`'s `timeout` option ships. **Status**: API designed.

```perl
my $ch = Acme::Parataxis::Channel->new( capacity => 16, timeout => 500 );
$ch->get;    # parks at most 500ms, then throws Error::Timeout
$ch->put($v);# same bound on the send side
```

**Semantics / decisions**:

- A channel-level default deadline for `get`/`put`/`select` when the call doesn't pass its own. `get`/`put` park through the existing `_park` path with a shared deadline token, armed once and re-used across re-parks, exactly like `select`'s deadline - `Error::Timeout` on expiry, unregistered from the semaphore when interrupted.
- `select` on a channel whose cases carry defaults: the `select` option, when given, wins; otherwise each case's own default applies and `select` parks until the earliest fires. `try_get`/`try_put` stay non-blocking (a `timeout` field is irrelevant to them).
- `timeout => 0` means no bound (match `with_timeout`'s convention). Right now the field would need a small plumbing touch inside `Channel` (`get`/`put` read `$self->{timeout}` when no explicit bound is in play); no scheduler/C change.

**Acceptance** (extend `t/018_coro_channel.t` + `t/041_channel_select.t`): channel `get`/`put` time out at the bound; `with_timeout`/cancellation still interrupt an unexpired channel wait; `select` honors a channel default when no option is given; `try_*` unaffected; `timeout => 0` disables.

### Card 19 - deterministic mock time *(chapter plan "Mock Time")*

**Source**: chapter plan + #10's timing theme. **Status**: design in progress - the big one.

**Goal**: a scheduler mode where `await_sleep`, `Ticker`, `RateLimiter`, deadlines, and `select` timeouts advance against a **virtual clock the test drives**, so a 1-hour timeout is exercised in microseconds.

```perl
run( virtual => 1, code => sub {
    fiber { eval { my $v = $ch->get } ; is $@->isa('Error::Timeout'), T() };
    Parataxis->advance( 60_000 );   # skip the clock forward: the parked wait fires now
});
```

**Semantics / decisions**:

- When **every** live fiber is parked on a timer (nothing runnable, no job-queue work), `run` fast-forwards the virtual clock to the earliest pending deadline and dispatches those timers, instead of sleeping on the wall clock. `Parataxis->advance($ms)` nudges the virtual clock from inside a fiber for the "advance and observe" test choreography; `await_sleep`/Ticker/limiter/select all read the virtual clock while the mode is on.
- This is the scheduler-level card: the timer queue (`TASK_SLEEP` jobs and the deadline mechanism) must learn "virtual" - likely a `run` flag that makes timer jobs pass through a virtual-time table rather than the thread pool, plus a fast-forward detector watching `get_outstanding_jobs() == 0` while fibers sit on timers. Highest C/blib risk of the chapter; plan a pure-Perl *simulation* harness first (a `::MockClock` the timer path consults), then optionally push it into the C queue.
- Scope guard: virtual time only inside a `virtual => 1` run; real `run`s are untouched. Time source decoupling is the shared seam (`with_timeout` deadlines, `Ticker->next_at`, `RateLimiter` refill tick, `Channel`/`select` bounds, `time` reads in stream `throttle`).

**Acceptance** (new `t/066_mock_time.t`): `await_sleep(3_600_000)` returns without a real second passing; a 1h `with_timeout` fires under `advance`; `Ticker` ticks on the virtual boundary; a `select` timeout fires on advance; a fiber that does *real* work still runs, only the clock is virtual; a normal `run` is untouched.

### Card 20 - execution contexts: `spawn_blocking`

**Source**: chapter plan + #9's "heavy Perl math". **Status**: design pending on threaded-Perl constraints.

**Goal**: a closure that does CPU-bound Perl work runs on a **dedicated background Perl interpreter**, its result arriving as a `Future`, so the cooperative fibers are not stalled by a second of `JSON::XS`/image code.

```perl
my $f = Acme::Parataxis->spawn_blocking( sub { heavy_parse($blob) } );
my $parsed = $f->await;    # main fibers kept running while $blob was parsed
```

**Semantics / decisions**:

- Requires `$Config{useithreads}`; croaks with a clear message on a non-threaded perl. A small pool of background interpreters (bounded, like the C pool) executes closures; each result is marshalled back as a `Future::set_result`/`set_error`, so the future composes with `await`, `with_timeout`, and cancellation exactly like any other.
- Hard limits to document up front: the closure runs in its own interpreter, so it sees only what is copy-in/back (integer/string/blessed-ref marshalling - closures cannot close over a shared stash, threads share nothing), and it must not touch `Acme::Parataxis` scheduler objects (or any blocking API) while there. That is the honest Loom/`worker_threads` trade and the main thing to get right.
- This is a distinct feature from the OS thread pool for `await_sleep`/I/O: that pool runs *C waits*; this runs *Perl code*. It needs a new C(ish) shuttle or a serialized queue + `threads` plumbing - the second-highest risk card. A v1 can be pure PDL via `threads` + `threads::shared` with chunky messages, no scheduler changes, if the marshalling story holds.

**Acceptance** (new `t/067_spawn_blocking.t`, skipped on non-threaded perl): the heavy closure finishes; the caller fiber kept running meanwhile; result arrives through a normal `Future`; die inside the closure becomes `Future` error; pool bounded; croaks on non-threaded perl.

### Card 21 - trace propagation (`Local` inheritance on spawn)

**Source**: chapter plan, building on #9's OTel thread and the shipped `Acme::Parataxis::Local`. **Status**: API drafted.

```perl
my $trace_id = Acme::Parataxis::Local->new( inherit => 1 );   # opt-in slot
fiber { $trace_id->set( make_id() ) };
async { my $id = $trace_id->get; ... };    # child sees the parent's value at spawn time
```

**Semantics / decisions**:

- A `Local` created with `inherit => 1` has its current value **copied from the spawning fiber into the child at `spawn` time** (a shallow copy at the spawn point, then the child owns it exclusively - writes never leak back, exactly today's isolation, only seeded). Non-inherited slots keep strict isolation.
- Alternative acceptance of the chapter wording ("automatically copies or inherits specific `Local` keys"): also accept explicit `spawn( inherit => \@locals )` to pick slots per-spawn without a global flag. Decide: **flag wins for the v1** (less API surface, no per-spawn list).
- Implementation is a small slice of the existing `%FIBER_LOCALS` machinery: the spawn path currently starts a child with an empty stash; `inherit` slots seed it from the parent's stash at that moment. No scheduler/C change (the stash is already fiber-keyed); the only wrinkle is *whose* fiber is the parent at `spawn` (it is the calling fiber - the same one the `spawn` args are resolved in) and the nursery/actor birth park must not lose the seed.
- Plays with the rest of the chapter: `spawn_blocking` (Card 20) explicitly does **not** inherit (separate interpreter); a monitor (Card 15) reports across the boundary without sharing.

**Acceptance** (new `t/068_trace_propagation.t`): value present in the child at first read; child writes invisible to the parent; plain `Local` stays isolated; the value follows `nursery` children and actor fiber birth; a pre-spawn parent value is the seed (post-spawn parent writes do not propagate).

### Card 22 - graceful shutdown & application lifecycle

**Source**: chapter plan + #9's lifecycle hint + Backlog. **Status**: API drafted; needs `run()`'s signal seam.

```perl
Acme::Parataxis->run( on_shutdown => sub ($tok) { ... } );   # top-level run wires SIGINT/SIGTERM
# Ctrl+C: $tok fires, the root nursery cancels, defers/DESTROYs finish, run() returns 130
# (or a status you pick), the process exits cleanly instead of dying mid-wait.
```

**Semantics / decisions**:

- `run( ... )` installs `SIGINT`/`SIGTERM` handlers for the duration of the run (and restores them after). The first signal fires the run's shutdown `CancellationToken`; a second signal forces the default (``: the handler must not block a second Ctrl+C).
- The token cancels the **top-level nursery** (the run's root fiber is wrapped in one), so child fibers throw `Error::Cancelled`, unwind, run their `defer`s (Card 14) and `DESTROY`s, and `run` returns after a clean drain with a conventional interrupted status (130/143). `Supervisor` trees and atomic blocks drain like any other child.
- The seam is `run()`'s `%SIG` handling + the nursery wrapper. Only touches `Acme::Parataxis.pm` and (since defers ride there too) the fiber-finish path - no C, but it must be tested with real `kill`-style signals on a subprocess, plus a `kill 0`/exit-status claim.
- Non-interactive guard: only the *top-level* run installs handlers, and only when the caller opts in (a `run( on_shutdown => ... )` option, or a default on the outermost `run` - decide by how the test suite runs). `await`-based normalization on CI must not hang.

**Acceptance** (new `t/069_shutdown.t`, a subprocess harness): SIGINT during a long `await_sleep` returns 130 and prints a drained log; `defer`s ran; `DESTROY` blocks ran; a second signal kills hard; a plain `run` without the option leaves `%SIG` untouched.

---

## Deferred (needs a decision before rostering)

- **`Channel` combinators `map`/`filter`/`merge`**: the shipped `Stream` covers `map`/`filter`/`batch`; `merge` (fan-in of several channels) is the remaining CSP-style join and is still described only in `Stream`'s terms in the Backlog note.
- **`integer under STM`**: the STM validaition/retry story is shipped; making `retry()` useful outside a pure TVar read/write block (e.g., blocking on a derived value) is a possible follow-up.
- **Erlang-style fully-synchronized code swap** (validate the swap against in-flight messages before committing) is deliberately out of scope for Card 15's v1; revisit only if a real workload needs it.

## Room notes from the articles

- #9 closed with "another handful of ideas but I need to turn random phrases into actual explanations" - the Backlog entries above (scopes, `defer`, monitor/link, hot swap, name registry, channel timeout) are how we reify that thread. Erlang/OTP surfaced monitors, links, registration, and code swapping; Clojure's persistent-data angle and ZIO's fiber interruption/scopes shaped the cancellation cards.

## Original Backlog (kept verbatim for provenance)

- `with_cancel` - cancellation *scopes* (register/unregister groups of waits as one unit). -> Card 13
- `defer` - run-cleanup-on-every-exit (like Go's `defer` for fiber exit paths). -> Card 14
- Monitor & linked death notification (observe another fiber's death without owning it). -> Card 15
- Actor hot-code swap + named registry. -> Card 16
- `with_timeout` re-entrancy polish. -> Card 17
- `Channel->new( timeout => $ms )` - per-channel default wait timeout for `get`/`put`, straight from #7's CSP sketch (`Channel->new( capacity => 1024, timeout => 500, ... )`). Never implemented; today the only channel timeout is `select`'s `timeout` option. A channel-level `timeout` would park `get`/`put`/`try_*` with that deadline and croak `Error::Timeout` on expiry. -> Card 18
- Note: `select`'s `default` arm, the main-loop driver hook, and channel combinators (map/filter/merge) all shipped.