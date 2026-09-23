# TODO - Next-Gen Concurrency Roadmap

This file is the new roadmap, rebuilt from three brainstorming discussions:

- [Parataxis in the Near Future · #7](https://github.com/sanko/Acme-Parataxis.pm/discussions/7) where some of my completed tasks began (nursery, cancellation, CSP select, generators, actors, sync primitives, deadlock tracing).
- [Parataxis in the Not Too Distant Future · #9](https://github.com/sanko/Acme-Parataxis.pm/discussions/9) which covers event loop integration, supervisor trees, STM, async streams.
- [Parataxis, Eventually · #10](https://github.com/sanko/Acme-Parataxis.pm/discussions/10) which has my plan for more borrowed concepts like a ticker, rate limiter, and transparent unblocking.

This file is the next chapter before I rename the project. Every complete task gets me closer to graduation from Acme.

## What the discussions asked for, and where it already landed

| Idea (discussion)                                         | Status        | Where it lives |
| ---                                                       | ---           | --- |
| Nursery / structured concurrency (#7)                     | [x] done      | M4 - `Acme::Parataxis::Nursery`, `nursery()`, t/040, t/042 |
| Cancellation tokens (#7)                                  | [x] done      | M1 - `Acme::Parataxis::CancellationToken`, t/033 |
| Deadlines / `with_timeout` + `Error::Timeout` (#7)        | [x] done      | M1, t/034 |
| CSP channel multiplexing - `Channel->select` (#7)         | [x] done      | M5 - `select`, `try_get`/`try_put`, t/041 |
| Stackful iterators - `Generator` (#7)                     | [x] done      | M6, t/043 |
| Actors - `ask`/`send`, bounded mailbox, backpressure (#7) | [x] done      | M7, t/044 (supervision deferred → Card 3) |
| Sync primitives - Mutex / WaitGroup / Barrier (#7)        | [x] done      | M3, t/036–t/039 |
| Read/write locks (#7)                                     | [x] done      | Card 1 - `Sync::RwLock`, t/049 |
| Deadlock tracing - `dump_fibers`, wait_reason (#7)        | [x] done      | M8, t/045 (full backtrace deferred → Card 9) |
| Event-loop integration - Mojo / IO::Async (#9)            | [x] done      | Card 2 - `attach_loop`, `Driver::{Mojo,IOAsync}`, t/047, t/048 |
| Supervisor trees - OTP restart strategies (#9)            | [x] done      | Card 3 - `Supervisor`, t/054, t/055 |
| Software transactional memory - TVar / `atomically` (#9)  | [x] done      | Card 4 - `TVar`, t/056 |
| Async Streams - FRP over channels (#9)                    | [x] done      | Card 5 - `Stream`, t/057 |
| Drift-free `Ticker` (#10)                                 | [x] done      | Card 6 - `Ticker`, t/050 |
| Token-bucket `RateLimiter` (#10)                          | [x] done      | Card 7 - `RateLimiter`, t/051 |
| Transparent unblocking - `CORE::GLOBAL` overrides (#10)   | [x] done      | Card 8 - `Compat`, t/058 |
| Full park-site backtrace - `dump_fibers` depth (#7)       | [ ] pending   | Card 9 |

## Carried over from the previous roadmap

- **OTP-grade supervision** was M7's explicit guardrail ("deliberately out of scope"). Discussion #9 asks for it directly - no longer out of scope, now Card 3.
- **Scalable I/O (epoll/kqueue/IOCP)** was M9, marked "not part of the core plan" because it meant rewriting the readiness path. Discussion #9 proposes the kinder form - drive Parataxis from an existing CPAN event loop - which is Card 2.
- **Full park-site backtrace** was M8's deferred nice-to-have ("wait_reason's single [file, line] is not a full backtrace"). Discussion #7's deadlock-tracing section wants exactly this - Card 9.
- Regressions R1–R4 are resolved; R4's `pp_entersub` pad fix landed in `ee1e440`/`86a0ef0` (its Stress-CI confirmation rides along with routine CI). The related shared-pad wipe (CvDEPTH dipping below a parked frame's depth, so the next entry landed on that frame's pad and erased its lexicals) is fixed in the C core alongside Card 3 by the per-CV parked-depth registry in `_activate_current_depths`, regression-tested in t/055.

## Known issues

- **`perl -c lib/Acme/Parataxis.pm` prints `syntax OK` then segfaults (exit 139).** Diagnosed but *not fixed* - out of
  scope for Cards 1 and 2. It reproduces on an unmodified HEAD, on untouched sibling modules, and on a trivial
  `use Acme::Parataxis;` file, so it is not caused by the scheduler changes. It is not a CHECK/END problem: `-c`
  runs `CHECK` but never `END`, yet adding `CHECK { cleanup() if $^C }` did not help. Loading `Affix` alone is clean,
  and `PERL_DESTRUCT_LEVEL=2` suppresses it, which points at interpreter destruction rather than compile. Nothing in
  the shipped workflow is affected: `perl Build`, `perl Build test` (49 files, 390 tests) and normal execution are
  all clean.

## Backlog

Leftover half-formed concepts and implementations from the first discussion. Keeping them here so nothing is lost.

- `with_cancel` - cancellation *scopes* (register/unregister groups of waits as one unit).
- `defer` - run-cleanup-on-every-exit (like Go's `defer` for fiber exit paths).
- Monitor & linked death notification (observe another fiber's death without owning it).
- Actor hot-code swap + named registry.
- `with_timeout` re-entrancy polish.
- `Channel->new( timeout => $ms )` - per-channel default wait timeout for `get`/`put`, straight from #7's CSP sketch
  (`Channel->new( capacity => 1024, timeout => 500, ... )`). Never implemented; today the only channel timeout is
  `select`'s `timeout` option (M5). A channel-level `timeout` would park `get`/`put`/`try_*` with that deadline and
  croak `Error::Timeout` on expiry.
- Note: `select`'s `default` arm and the main-loop driver hook shipped - `default` is in M5/`Channel->select` and
  the driver hook is Card 2. "Channel combinators (map/filter/merge)" is subsumed by Card 5.

---

## Cards

### 1 Read/write lock (Sync::RwLock) - done

**Shipped:** `lib/Acme/Parataxis/Sync/RwLock.pm` + `Sync/RwLock.pod`, tested by t/049 (11 subtests). All four
acceptance bullets below are covered: concurrent readers, no writer starvation, FIFO writer handoff with `try_*`
never stealing, non-owner unlock croak, guard release on scope end and on exception, interrupted waits unregister,
and every op croaks outside a scheduled fiber.

Source: #7, "More Primitives". The Mutex paragraph calls for a lock that "tracks fiber ownership... and enables
read-heavy concurrency with a **shared or exclusive** read/write lock." Mutex landed in M3; RwLock did not.

Sketch:

    my $rw = Acme::Parataxis::Sync::RwLock->new;
    $rw->read_lock; ... $rw->read_unlock;      # shared
    $rw->write_lock; ... $rw->write_unlock;    # exclusive
    { my $g = $rw->read_guard; ... }           # scope guard (like Mutex::guard)

Design notes:

- Many readers **xor** one writer; writer-preferring (block new readers once a writer is waiting, Go-style) so a
  steady read stream can't starve writers.
- Write side inherits Mutex's owner tracking + FIFO handoff; read side is a count plus a FIFO waiter list. Reuse the
  `Sync` base (`_fid`/`_park`/`_wake`) so every wait parks with a dereg closure.
- Same rules as Mutex: non-reentrant write side; interrupted waits (deadline/cancel) unregister and transfer any
  hand-off (the M1 fix in `Sync::Mutex::lock`).

Acceptance (t/0XX):

- Concurrent readers proceed together; a writer's turn excludes new readers and readers wait behind it (no writer
  starvation);
- FIFO writer handoff like Mutex; `try_*` never steals;
- non-owner write unlock croaks; guard auto-releases on scope end and on exception;
- an interrupted `write_lock`/`read_lock` unregisters cleanly and the lock stays usable; all ops croak outside a
  scheduled fiber.


### 2 Event-loop driver hook (Mojo / IO::Async) - done

**Shipped:** `attach_loop`/`detach_loop`/`loop` on `Acme::Parataxis`, `Acme::Parataxis::Driver` plus
`Driver::Mojo` and `Driver::IOAsync` (all with POD), tested by t/047 (Mojo) and t/048 (IO::Async).

All four acceptance bullets below are now covered:

- mixed sleep + socket-read workload per driver: t/047's and t/048's `run` subtests;
- an awaited filehandle waking on readiness, and an enclosing `with_timeout` still interrupting: both files;
- high-volume smoke (hundreds of concurrent `await_read` on loopback): both files park **300** descriptors at once
  and require every one to wake with its byte, finishing in well under a second;
- no worker thread does readiness while a loop is attached: both files count pool submissions through
  `_submit_job` (the only gate onto `submit_c_job`, and `run()` never submits on its own) and require **0** across
  that 300-descriptor run, with a no-loop control that must submit >= 2 so the counter cannot pass vacuously;
- the untouched `select()` path: the rest of the suite runs with no loop attached.

Measured on this machine, the reason the card exists: with the default `max_threads` of 16, **150** concurrent
pool-path `await_read` calls woke only **6** of them - the other **144** expired their own 5s deadline, because
each queued read waits for one of 16 threads blocked in `select()`, and the run took **46s**. The same 150 (and
300) reads through an attached loop all wake in roughly **90ms**. Pool behaviour at that volume is inherent to one
thread per watched descriptor, not a regression, and is not covered by a test.

Source: #9 - "An Ecosystem Hook: Event Loop Integration". Today `await_read`/`await_write` offload to OS threads
via `select()`, which caps at `FD_SETSIZE` (1024) and burns a whole thread per watched socket. Instead, let Parataxis
be **driven by** an existing CPAN loop so `epoll`/`kqueue`/`io_uring` come for free. This is M9 resurrected in a
kinder form.

Sketch:

    Acme::Parataxis->attach_loop( $mojo_loop );     # or run(..., driver => $loop)
    my $fh  = $socket->accept;
    my $req = await_read( $fh );    # loop watches $fh; its callback enqueues the fiber

Design notes:

- Define a driver role: `watch_read($fh, $cb)`, `watch_write($fh, $cb)`, `unwatch($fh)`, plus a way to run until
  the scheduler is empty. Two reference drivers: `Mojo::IOLoop` and `IO::Async::Loop`.
- The loop owns readiness; Parataxis keeps its scheduler, fibers and park machinery unchanged. `await_read`/
  `await_write` route through the driver when attached and fall back to the worker pool otherwise.
- Close the lost-wakeup window ("register, then arm" ordering, same care as `Channel->select`'s deadline).

Acceptance (t/0XX):

- A Mojo::IOLoop and an IO::Async::Loop driver each run a mixed workload (sleeps + socket reads) to completion with
  no worker threads doing readiness;
- an awaited filehandle wakes exactly once on readiness; an enclosing `with_timeout` still interrupts the wait;
- high-volume smoke: hundreds of concurrent `await_read` hooks on loopback sockets;
- with no driver attached, the current `select()` path behaves exactly as today.


### 3 Supervisor tree (OTP restart strategies) - done

**Shipped:** `lib/Acme/Parataxis/Supervisor.pm` + `Supervisor.pod`, plus `supervised`/`on_death`/`respawn` on
`Actor` and the `Error::Supervisor` aggregate, tested by t/054 (12 subtests) and t/055 (the shared-pad corruption the
tree's nesting flushed out). All four acceptance bullets below are covered: every strategy restarts the right set with
untouched siblings as controls, budget exhaustion produces the aggregate error and stops the tree (with the
same crash loop under a budget nobody can exhaust as the control), nested supervisors restart their own children and
are rebuilt from above when their budget runs out, and actors restart with a clean mailbox while in-flight asks fail
and the live-fiber count returns to baseline.

Source: #9 - "Erlang-ish Supervisor Trees (Transaction healing)". Fail-fast (`::Nursery`, M4) isn't enough for
long-running apps; they need *heal-fast*. This lifts M7's "supervision is deliberately out of scope" guardrail.

Sketch:

    my $sup = Acme::Parataxis::Supervisor->new(
        strategy     => OneForOne,        # OneForAll | RestForOne
        max_restarts => 5,
        within       => 60,
    );
    $sup->supervise( $some_actor );
    $sup->run();

Semantics:

- **OneForOne**: a dying child restarts alone.
- **OneForAll**: a dying child kills and restarts the whole set (children share broken state).
- **RestForOne**: a dying child kills and restarts it plus everything started after it.
- Restart budget (`max_restarts` within `within` seconds); exhausting it fails the supervisor with an aggregated
  error in the style of `Error::Nursery` (`->primary`, `->failures`).

Design notes:

- The natural supervised unit is the M7 `Actor` (it already owns a fiber + mailbox). Supervisors supervise
  supervisors; this is a pure-Perl layer on the existing park/wake machinery.
- A supervised actor restart gets a fresh mailbox; asks in flight at the moment of death are failed, never hung or
  silently dropped.

Acceptance (t/0XX):

- a dying supervised child restarts per strategy; OneForOne never touches siblings, OneForAll restarts all,
  RestForOne restarts the suffix;
- restart-budget exhaustion produces the aggregate error and stops the tree;
- nested supervisor trees propagate restarts correctly;
- actors restart with a clean mailbox; in-flight asks fail; live-fiber count returns to baseline.


### 4 STM (TVar + atomically) - done

**Shipped:** `lib/Acme/Parataxis/TVar.pm` + `TVar.pod`, plus `Acme::Parataxis::Error::STM_Retry` and the
`atomically`/`retry` exports on the main module (with an `&` prototype so the POD synopsis's bare-block form is
truthful; a runtime CODE-ref guard keeps the non-block-value error honest), tested by t/056 (7 subtests). The four
acceptance bullets below are covered: a single-writer transfer commits exactly once (the re-run counter proves no
spurious restarts); the classic opposite-transfers deadlock (A→B vs B→A) resolves with neither side hanging - one
transfer commits, the loser's commit fails under the global commit lock and rolls back + re-runs, while the ledger
stays conserved (t/036's Mutex counterpart, inverted); writes are invisible until commit, so a reader never observes
a half-applied transfer and a loser's rollback leaves the shared state untouched (t/034's staged-write subtest is the
mutex-only control); `retry()` parks the fiber on its read set and wakes exactly when a read TVar commits, while
nested `atomically` blocks join the outer log (read-your-writes) so the inner block sees staged writes and the whole
write set commits as one transaction - it never deadlocks on itself. A timeout interrupts a retry-parked transaction
cleanly, unregistering it from every watcher and leaving the TVars untouched (t/056 subtest 6).

Source: #9 - "Software Transactional Memory (STM)". Mutexes are hard to compose and deadlock-prone; STM makes shared
state feel lock-free and atomic. The article even sketches a workable `atomically`.

Sketch:

    my $a = Acme::Parataxis::TVar->new( value => 100 );
    my $b = Acme::Parataxis::TVar->new( value => 100 );

    Acme::Parataxis->atomically(sub {
        my $bal_a = $a->get;
        $a->set($bal_a - 50);
        $b->set($b->get + 50);
    });

Semantics (from the article):

- `atomically` opens a fiber-local transaction log. Reads record `(value, version)` in the read set; writes land in
  the write set only - real TVars are untouched.
- Commit holds a global lock: if every read-set version still matches, flush the write set, bump versions, wake
  parked `retry`-waiters; otherwise discard and re-run the block from the top.
- `retry` parks the fiber on its read-set TVars and resumes when any of them changes (an internal
  `Error::STM_Retry` exception, per the article's sketch).
- Document loudly: the block may run many times - no irreversible side effects inside a transaction.

Design notes:

- The fiber-local log maps naturally onto M2's `Acme::Parataxis::Local` or a dedicated fiber-local slot.
- The commit lock is a plain Perl-side Mutex under the scheduler - no C changes expected.
- Long-term goal from the article: replace Mutex/Semaphore/condvar for *shared state*, leaving the sync family for
  signaling.

Acceptance (t/0XX):

- a single-writer transfer commits exactly once;
- the classic deadlock (A→B vs B→A transfers) resolves: one commits, the loser rolls back and retries, neither hangs
  (t/036's Mutex counterpart, inverted);
- writes are invisible until commit; a reader never sees a partial transaction;
- `retry` parks and wakes on TVar change; nested `atomically` nests logs;
- side-effect warning documented in the POD.


### 5 Async Streams (Channel-backed FRP) - done

**Shipped:** `lib/Acme/Parataxis/Stream.pm` + `Stream.pod`, tested by t/057 (4 subtests). All four acceptance bullets
below are covered: map/filter/batch produce only transformed/filtered/grouped items in order (t/057's ordered-prefix
checks, including a map that yields arrayrefs and a consume that spreads them like a batch), backpressure is verified
directly by counting parked puts on the upstream channel while a slow consume drains a bounded stage, batch fires on
count and on deadline (the deadline branch uses `Channel->select` get-with-deadline, so a lone item after the last
flush still trips its `batch_time` timer - the reason t/057 had to drive a stage whose input stalled), throttle caps
the rate (a measured wall-clock spacing with the `await_sleep`-only remainder, never a "catch up" burst after
backpressure), and quitting the source channel ends the chain with the live-fiber count back at its baseline - each
stage's fiber sees the shutdown as `undef` from `get`, flushes a partial final batch, shuts its own output down, and
unwinds fiber-by-fiber to the source, leaving zero leaked fibers.

Source: #9 - "Async Streams (Functional Reactive Programming)". Channels (M5) + fibers + generators (M6) are the
recipe; a `Stream` wraps a channel in a chainable pipeline. Subsumes the old planner's "Channel combinators".

Sketch:

    Acme::Parataxis::Stream->from_channel( $raw_ch )
        ->map(    sub ($line) { decode_json($line)            } )
        ->filter( sub ($msg)  { $msg->{status} >= 500         } )
        ->throttle( 100 )        # at most 100/s
        ->batch_time( 1000 )     # group every 1000ms
        ->batch( 100 )           # or wait for 100 items
        ->consume( sub ($batch) { db_bulk_insert($batch) } );

Design notes:

- Every stage is a factory: create an output `Channel`, spawn a background fiber that loops the input, applies the
  callback, and `put`s to the output, return a new `Stream` wrapping it. Backpressure is free - a full bounded
  channel parks the stage's producer all the way upstream (no OOM).
- `throttle`/`batch_time` can start on `await_sleep` and upgrade to Card 6's `Ticker` when it lands.
- Teardown: the stream ends when its source channel shuts down; `consume`'s fiber exits and the live-fiber count
  returns to baseline (no orphan fibers - M4's closing argument).

Acceptance (t/0XX) - all covered by t/057:

- map/filter/batch produce only transformed/filtered/grouped items, in order;
- backpressure verified directly: a slow `consume` blocks the upstream producer (count parked fibers);
- batch fires on count and on deadline; throttle caps the rate;
- quitting the source channel ends the chain; zero leaked fibers.


### 6 Ticker - done

**Shipped:** `lib/Acme/Parataxis/Ticker.pm` + `Ticker.pod`, tested by t/050 (5 subtests). All three acceptance
bullets below are covered:

- strict cadence under load: t/050 takes 30 ticks at a 100ms interval with 30ms of `do_work` per cycle and requires
  the mean period to hold between 90 and 110ms with the 29 periods spanning 2.70-3.10s. A control runs the naive
  `await_sleep(30); await_sleep(100)` loop the card exists to replace and must come out measurably slower per cycle,
  so the cadence assertion cannot pass vacuously;
- a slow consumer drops ticks instead of queueing them up: with nobody listening for 300ms at a 40ms interval,
  `pending` never exceeds 1 while `dropped` reaches 3 or more, ticks only ever move forward, and consecutive
  receipts jump over whole periods rather than draining them one by one;
- `->stop` leaves no fiber behind: stopping a ticker whose consumer is parked on a 5s period releases that wait with
  `undef` promptly and returns the live-fiber count to its pre-run baseline, and the same holds for a ticker stopped
  before it ever ticked, and for one built outside `run()`.

Feeds Card 7 (`RateLimiter` composes a `Semaphore` with a ticker that `try_up`s tokens) and Card 5's
`throttle`/`batch_time`, which no longer needs to grow its own drift-free sleep.

Source: #10 - "The Ticker". A `while (1) { do_work(); await_sleep(1000) }` loop drifts - if `do_work()` takes 200ms
the loop runs every 1200ms. A Ticker compensates by sleeping only the *remainder* of each interval.

Sketch:

    my $tick = Acme::Parataxis::Ticker->new( interval => 1000 );
    while (my $t = $tick->wait_next) { do_work() }   # fires every 1000ms regardless of do_work length

Design notes:

- A background fiber records `time()`, sleeps for the remaining time to the *absolute* next tick, and `try_put`s the
  tick time into a small channel. A slow consumer silently drops ticks - no stale-tick backlog (the article's
  explicit requirement).
- Reuses the R1-fixed timed-wait machinery; feeds Card 7 (`RateLimiter`) and Card 5's `throttle`/`batch_time`.

Acceptance (t/0XX):

- strict cadence under load: 100ms ticks still fire every ~100ms while `do_work` takes 30ms (no drift over several
  seconds);
- a slow consumer drops ticks instead of queueing them up;
- `->stop`/abandon leaves no worker or fiber behind (live-fiber baseline).


### 7 RateLimiter (token bucket) - done

**Shipped:** `lib/Acme/Parataxis/RateLimiter.pm` + `RateLimiter.pod`, tested by t/051 (5 subtests). All four
acceptance bullets below are covered:

- thousands of concurrent `acquire` never exceed `rate x wall-time + burst` against a real clock: t/051 saturates the
  fiber table with 800 workers and has each acquire three times, giving 2400 acquisitions contending for one bucket at
  `rate => 1000, burst => 100` (`MAX_FIBERS` used to be a hard 1024 in `Parataxis.c`; the table now grows on demand
  under `set_max_fibers`, so 800 is a deliberate load shape - the thousands come from workers acquiring again as
  tokens refill). Every timestamp is checked against the bound: the
  request numbered `k` may not have completed before `(k - burst)/rate`. Not one of the 2400 beat it, the measured
  worst overshoot being 0.0ms, while the run still cost at least the theoretical 2.30s and finished near the
  requested rate instead of stalling;
- acquires park when the bucket is empty and resume as tokens refill, with no busy-wait: after spending the lone
  `burst => 1` token, the next `acquire` is shown parked with `waiters == 1` and `dump_fibers` reporting state
  `WAITING` and the reason `RateLimiter acquire` - a spinning fiber would instead show `RUNNABLE` or `RUNNING` - and
  it does not complete until the ~100ms refill lands, then leaves the waiter list;
- a deadline interrupts a parked `acquire` and the waiter unregisters: `with_timeout(80, sub { $rl->acquire })` on an
  empty bucket throws `Acme::Parataxis::Error::Timeout`, `waiters` drops from 1 back to 0 so no later refill can wake
  a fiber that no longer wants a token, and the bucket still hands out tokens afterwards;
- documents the burst-vs-strict-rate tradeoff: t/051 pairs a behavioural check (20 `burst` tokens are spent back to
  back with no wait between them, then 5 more at `rate => 50` cost at least 4 refill periods, so the burst really is
  instant while the sustained rate really is `rate`) with a read of `RateLimiter.pod` requiring a
  `BURST VS. STRICT RATE` section, so the documentation cannot be dropped without failing the suite.

**Composition:** the bucket is a plain `Semaphore` sized to `burst`, and a Card-6 `Ticker` waking `rate` times a second
credits every whole token accrued since the previous wake while the bucket sits below its ceiling. That is what keeps `acquire` a plain
`down`: the park path, cancellation and unregister-on-interrupt all come with it rather than being reimplemented.
`stop()` halts refills and lets a parked acquirer through rather than stranding it, while a later `acquire` croaks
instead of parking forever with nobody left to refill.

Source: #10 - "The Rate Limiter (Token Bucket)". Apps that hit rate-limited APIs need an app-wide speed limit.

Sketch:

    my $rl = Acme::Parataxis::RateLimiter->new( rate => 5, burst => 10 );
    for (1..1000) { fiber { $rl->acquire(1); fetch_url(...) } }

Design notes:

- **_Composition first:_** bucket = a `Semaphore` initialized to `$burst`; a Card-6 `Ticker` (firing `rate`/s)
  `try_up`s tokens back up to `burst`. `acquire($n)` is a semaphore `down` - cooperative park for free.
- **_Math upgrade:_** compute the exact microsecond the next request is allowed and `await_sleep` the delta (the
  approach behind the author's `Algorithm::RateLimiter::TokenBucket` / `AnyEvent::Handle::Throttle`). Only if the
  timer-queue cost matters at high `rate`.
- Either way it parks through `_park`, so it composes with `with_timeout`/cancellation.

Acceptance (t/0XX):

- thousands of concurrent `acquire` never exceed `rate × wall-time + burst` (measured against a real clock);
- acquires park when the bucket is empty and resume as tokens refill; no busy-wait;
- a deadline/cancel interrupts a parked `acquire` and the waiter unregisters;
- documents the burst-vs-strict-rate tradeoff.


### 8 Transparent unblocking (CORE::GLOBAL overrides) - done

**Shipped:** `lib/Acme/Parataxis/Compat.pm` + `Compat.pod`, plus `enable_transparent_unblocking` /
`disable_transparent_unblocking` / `transparent_unblocking` on `Acme::Parataxis`, tested by t/058 (8 subtests). All
three acceptance bullets below are covered:

- `sleep` inside a fiber yields: t/058 runs a fiber doing `sleep 0.05` beside a sibling fiber ticking counters and
  requires the sleeper to come back after ~0.05s with the sibling having made progress, and the implicit `$_`
  argument form is covered too;
- `CORE::sleep` and the raw builtins are unchanged outside the scheduler: at the top level `sleep 0.05` truncates
  and returns immediately, top-level `read`/`sysread` fill their caller buffers, and after
  `disable_transparent_unblocking` a freshly compiled `sleep 0.05` shows the truncated-integer CORE:: result;
- documented coverage and non-coverage: `sleep`, `read`, `sysread` are covered - `read`/`sysread` park the fiber on
  `await_read` readiness and perform one real read, and the overrides are deliberately unprototyped because the
  compiler passes the builtin's second argument BY VALUE to a prototyped `CORE::GLOBAL` override (so the result is
  written back through the aliased slot). `select`, `alarm`, `time`, `DBI` (C-level), and other threads are not
  covered: `CORE::GLOBAL` is a per-interpreter mechanism, so a spawned thread starts with unmodified builtins, and a
  read on a handle select() cannot watch (a regular file, a pipe) falls back to the raw builtin instead of spinning.

Source: #10 - "Gevent-style Transparent Unblocking". Intercept blocking builtins so existing synchronous CPAN
modules (`LWP::UserAgent`, `DBI`) become cooperative without rewrites. `sleep 5` → `await_sleep(5000)`; `read` →
readiness-framed reads.

Design notes (as shipped):

- Opt-in only, via an explicit class method: `Acme::Parataxis->enable_transparent_unblocking()` (no import flag, no
  env). Never default (dark magic) - `disable_transparent_unblocking`/`transparent_unblocking` manage/report it.
- Mechanism per the article: `CORE::GLOBAL::sleep`/`read`/`sysread`, delegating to `CORE::` when NOT inside a
  scheduled fiber (top level, other interpreters) so nothing outside the scheduler changes; installs happen at
  compile time, so code must be compiled after the call to be affected (install in `BEGIN`).
- Honest expectations per builtin: `sleep` maps to `await_sleep` (ms-accurate, returns the requested duration);
  `read`/`sysread` are `await_read`-framed loops that fall back to the raw builtin for handles select() cannot
  watch; `DBI` is mostly C and stays blocking.

Acceptance (now t/058):

- `sleep` inside a fiber yields: two fibers, one blocked in a legacy module's `sleep`, the other makes progress;
- `CORE::sleep` and the raw builtins are unchanged outside the scheduler;
- no interception on other threads; docs list which builtins are covered and which are not.


### 9 Diagnostics depth (full park-site backtraces)

Source: #7's "Deadlock tracing" + M8's deferred nice-to-have. `dump_fibers` (M8) gives `{ fid, state, reason =>
[reason, file, line] }` and prints each parked fiber's reason and *site* - the frame that entered the wait, not a
backtrace. #7 asked for "the perl-level stack trace where they called `yield`."

Design notes:

- Capture a bounded callchain at the `_park` site (a few `caller` frames / `Devel::Callsite` when available) and hang
  it off the wait-reason record - or compute lazily on request to keep the per-park cost at zero. Benchmark
  `spawn`/`await` before and after; keep the delta bounded.
- Keep `dump_fibers` returning structured data by default (the existing contract); the FATAL deadlock report and the
  human `$fh` form add the backtrace section.
- No weak-reference layer needed: C already holds the strong `self_ref` for every fiber (Article 2), so parked
  fibers stay alive long enough to inspect.

Acceptance (t/0XX):

- wait_reason records gain an optional backtrace (default depth configurable);
- per-park overhead stays bounded (compare against the M5-era micro-benchmarks);
- deadlock diagnostics show each parked fiber's chain back to user code - the point of #7's tracing.


### 10 Strip the roadmap labels (Card N / M#) from shipped files - deferred until the roadmap is done

Source: housekeeping, not a discussion. The codebase is organized around milestones (M1-M8) and roadmap cards;
comments in `lib/*.pm` and prose in `lib/**/*.pod` still say "M5's Channel", "Card 4 STM", "see Card 2" and the
like. Those pointers mean nothing to someone who installs the dist without this repo, where TODO.md is not
shipped. Stripping them is the last thing we do, after cards 4-9, because the labels are load-bearing while the
roadmap is live (they tell a reviewer where each feature came from).

Acceptance (a grep, no new tests):

- no `Card \d` or `M\d+` milestone reference remains in `lib/`, `eg/`, or `t/`;
- POD prose reads standalone: plain feature descriptions replace roadmap pointers; cross-feature relationships
  are named directly ("Channel->select can multiplex ..." instead of "M5's select");
- the navigational milestone comments in `lib/Acme/Parataxis.pm` (the M0/M8 slot-layout and diagnostics notes)
  are either dropped or rewritten as architecture notes with no milestone names;
- public API names are untouched - this card is documentation and comments only.
