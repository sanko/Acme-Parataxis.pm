# Hot-path benchmark harness

`eg/bench_hotspots.pl` is the repeatable gate for the scheduler/offload
optimizations derived from the Perl core fiber-context experiment. It runs an
untimed warm-up round, then reports median wall-clock time over N timed rounds:

```sh
perl -Mblib eg/bench_hotspots.pl --count 300 --rounds 5 \
    --compare "$BASELINE" --save "$CURRENT"
```

`--compare` reads a TSV written by a previous `--save` and adds a ratio column,
so every step is measured against the same baseline. `--only NAME` restricts the
run to one or more workloads. Workloads:

- `startup`: `--count` empty `run(sub {})` calls, isolating scheduler startup bookkeeping.
- `series`: `--count` sequential spawn/await cycles.
- `parallel`: `--count` fibers spawned, then awaited.
- `semaphore`: `--count` real parks/wakes through a zero-count gate.
- `channel`: `--count` size-1 channel rendezvous hand-offs.
- `offload`: `--count` `await_core_id()` C worker-pool submissions.
- `sleep`: `--count` one-millisecond real `await_sleep()` waits, exercising the worker pool's timed waits.
- `cancel_sleep`: `--count` long `await_sleep()` waits cancelled immediately, exercising sleep-job recall.
- `virtual`: `--count` virtual-clock sleeps, accelerated by the idle scheduler.
- `maybe_yield`: `400 * --count` direct C calls, measuring the C counter itself.
- `maybe_yield_public`: `400 * --count` calls through the exported Perl wrapper.

Only source changes that keep the normal workloads at or below baseline noise
are accepted. Each step also reruns the full test suite plus the stress/soak
tests; benchmark gains never justify weakening a correctness test.

### Testbed noise floor

An unchanged-versus-unchanged interleaved control on the current pair (20 pairs
at `--count 300 --rounds 1`, 12 for `cancel_sleep`, 8 for `sleep`) measured
median ratios of 1.002x series, 0.961x parallel, 1.002x semaphore, 0.995x
channel, 1.072x offload (1.132x by mean), 1.021x cancel_sleep and 0.981x sleep.
Small swings are noise; `offload` has a wider spread than the fiber-only paths,
so only consistently larger offload improvements are accepted.

## Recorded results

Baseline (v0.1.7, before hot-path work), `--count 300 --rounds 5`, Windows
v5.42.3, median seconds:

| workload | median_s |
| --- | ---: |
| series | 0.00666 |
| parallel | 0.00492 |
| semaphore | 0.02925 |
| channel | 0.01522 |
| offload | 0.09426 |
| virtual | 0.00657 |
| maybe_yield | 0.00542 |

### Step 1 — always-on bookkeeping

- Default-priority enqueue appends instead of scanning the run queue; the scan
  stays for programs that actually call `priority()`.
- `maybe_yield()` returns before FFI when preemption is disabled.
- `get_live_fiber_count()` returns an incrementally maintained count instead of
  scanning the whole fiber table on idle ticks.
- The diagnostic swap counter increments only when `PARA_DIAG` is enabled.

`--count 300 --rounds 5`, medians against the baseline above:

| workload | median_s | ratio |
| --- | ---: | ---: |
| series | 0.00553 | 0.831x |
| parallel | 0.00505 | 1.028x |
| semaphore | 0.02998 | 1.025x |
| channel | 0.01489 | 0.978x |
| offload | 0.05627 | 0.597x |
| virtual | 0.00652 | 0.993x |
| maybe_yield (C) | 0.00564 | 1.041x |
| maybe_yield_public | 0.00811 | 0.549x |

The public `maybe_yield()` ratio is against the old wrapper measured from
`bd19134` (`0.01478s`) with the same C library; the direct C workload confirms
that the C counter itself is unchanged. Full suite after the step: 74 files,
1055 tests, PASS (the two TODO-pass blocks are the known optional HTTP tests).

### Step 2 — job-pool pending count

`submit_c_job()` scanned all 1024 job slots a second time just to count `JOB_NEW`
entries before deciding whether to grow the worker pool. The count is now
maintained incrementally (incremented on submit, decremented when a worker claims
the job), so the scan under `queue_lock` is gone. The free-slot scan stays as it
is: it is O(1) in normal use, and changing it to a rotating cursor or LIFO made
the benchmark worse (cold slot cache lines) and broke `t/501_saturation.t`'s
lowest-free-slot expectation. An attempted signal-instead-of-broadcast wakeup
also failed that test (jobs stranded with no worker woken), so the broadcast is
unchanged.

`--count 300 --rounds 7`, medians against the original baseline:

| workload | median_s | ratio |
| --- | ---: | ---: |
| series | 0.00523 | 0.785x |
| parallel | 0.00471 | 0.959x |
| semaphore | 0.02894 | 0.989x |
| channel | 0.01491 | 0.980x |
| offload | 0.05578 | 0.592x |
| virtual | 0.00648 | 0.987x |
| maybe_yield (C) | 0.00565 | 1.042x |
| maybe_yield_public | 0.00784 | - |

Interleaved A/B runs of the offload workload showed 1.0x–1.2x spread in both
directions on this machine, so the offload ratio against the much earlier
baseline is not attributed solely to this step; the structural change (one
fewer locked 1024-slot scan per submission) is the reason to keep it. Full suite
after the step: 74 files, 1055 tests, PASS, including the saturation and soak
gates.

### Step 3 — parked/queued flags in fiber slots

`%PARKED`, `%PARK_REGS` and `%SCHEDULER_QUEUED` were hashes keyed by fiber id and
consulted on every park, wake and enqueue. They are now slots on the flat fiber
arrayref (`F_PARKED`, `F_PARK_DEREG`, `F_QUEUED`), so the hot paths do array
indexing instead of hash lookups. The run loop clears `F_QUEUED` as it drains
the queue; the cold teardown paths clear it for all live fibers.

Interleaved A/B medians against `HEAD` (`4f9aa40`) on the same machine:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| series | 0.00457 | 0.00493 | 1.078x |
| parallel | 0.00505 | 0.00441 | 0.873x |
| semaphore | 0.03042 | 0.02756 | 0.906x |
| channel | 0.01473 | 0.01464 | 0.993x |

The park-heavy workloads (`parallel`, `semaphore`) improved; `series` is within
noise. Full suite after the step: 74 files, 1055 tests, PASS.

### Step 4 — one locked drain for completed jobs

`drain_jobs()` used to take `queue_lock` three times per completed job: once in
`check_for_completion()` to pop the ring, once in `get_job_result()` to copy the
result, and once in `free_job_slot()` to release the slot. It now pops the whole
done ring under one lock, copies each job's owner and result while the slot is
still reserved, frees the slots, then builds the Perl result pairs and defers
fiber-id release outside the lock.

Interleaved A/B medians against the `b5d443d` DLL (12 pairs at `--count 300 --rounds 1`; `sleep` used 8 pairs at `--count 200`):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| series | 0.00499 | 0.00469 | 0.940x |
| parallel | 0.00473 | 0.00453 | 0.958x |
| semaphore | 0.02769 | 0.02776 | 1.003x |
| channel | 0.01563 | 0.01586 | 1.015x |
| offload | 0.07396 | 0.06652 | 0.899x |
| sleep | 3.57816 | 3.52582 | 0.985x |

The job-heavy `offload` workload improved, the park-heavy workloads stayed
within noise, and the full suite still passed: 74 files, 1055 tests, PASS.
Direct reruns of `t/450_parallel.t`, `t/500_stress_fuzz.t`,
`t/501_saturation.t` and `t/502_soak.t` also returned 0 with no failing tests.

### Step 5 — free-slot bitmap

`submit_c_job()` still walked up to 1024 `job_t` structs to find the lowest
`JOB_FREE` slot. A 16-word bitmap now records free slots, and claiming the
lowest set bit preserves the exact allocation order `t/501_saturation.t`
expects. Both reclaim paths (`drain_jobs()` and the public `free_job_slot()`)
set the bit back under the same lock; init seeds every valid bit.

Interleaved A/B medians against the `a37b08f` DLL (12 pairs at `--count 300 --rounds 1`; `sleep` used 8 pairs at `--count 200`):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| series | 0.00459 | 0.00469 | 1.022x |
| parallel | 0.00441 | 0.00460 | 1.043x |
| semaphore | 0.02714 | 0.02760 | 1.017x |
| channel | 0.01425 | 0.01398 | 0.981x |
| offload | 0.06787 | 0.06163 | 0.908x |
| sleep | 3.70962 | 3.74838 | 1.010x |

The offload path improved; the other workloads stayed within noise. Full suite
after the step: 74 files, 1055 tests, PASS, with the direct stress, saturation
and soak reruns also clean.

### Step 6 — pending-job bitmap

Workers had the mirror image of the submission scan: every claim walked the 1024
`job_t` structs looking for `JOB_NEW`. A second bitmap records pending work, and
claiming its lowest set bit keeps the same lowest-slot order. The worker now
takes the bit under `queue_lock` and leaves the existing `JOB_BUSY` and
`pending_job_count` updates in place.

Interleaved A/B medians against the `e6d09ff` DLL (12 pairs at `--count 300 --rounds 1`; `sleep` used 8 pairs at `--count 200`):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| series | 0.00470 | 0.00438 | 0.932x |
| parallel | 0.00437 | 0.00437 | 1.000x |
| semaphore | 0.02552 | 0.02599 | 1.018x |
| channel | 0.01501 | 0.01525 | 1.016x |
| offload | 0.07895 | 0.05026 | 0.637x |
| sleep | 3.41904 | 3.36047 | 0.983x |

Offload improved substantially; the remaining workloads stayed within noise.
Full suite after the step: 74 files, 1055 tests, PASS, with direct stress,
saturation and soak reruns clean.

### Step 7 — pre-size fiber objects through the new flag slots

The fiber-slot change added `F_PARKED`, `F_PARK_DEREG` and `F_QUEUED` (up to
slot 18), but `spawn_fiber()` still pre-sized the object to slot 8 and the Perl
constructor still built a 14-element array. The first park/queue write therefore
grew the AV. Both construction paths now allocate through slot 18.

Interleaved A/B medians against the `b7ef1df` pair (12 pairs at `--count 300 --rounds 1`; `sleep` used 8 pairs at `--count 200`):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| series | 0.00565 | 0.00491 | 0.869x |
| parallel | 0.00510 | 0.00488 | 0.957x |
| semaphore | 0.03190 | 0.03372 | 1.057x |
| channel | 0.01511 | 0.01489 | 0.985x |
| offload | 0.05555 | 0.05067 | 0.912x |
| sleep | 3.38159 | 3.37038 | 0.997x |

The semaphore result was noise: a 20-pair rerun measured 0.02999s old versus
0.02970s new (0.990x). Full suite after the step: 74 files, 1055 tests, PASS,
with direct parallel, stress, saturation and soak reruns clean.

### Step 8 — target sleep recall

`recall_sleep_jobs_for_fiber()` walked all 1024 job slots on every cancel or
timeout. A third bitmap records slots with an armed `TASK_SLEEP` job (NEW or
BUSY), set at submission and cleared when the slot is reclaimed, so recall now
visits only armed sleeps. Cancellation still re-checks fiber id, type and status
under the same lock.

Interleaved A/B medians against the `a8f5668` DLL (12 pairs at `--count 300 --rounds 1`; `sleep` used 8 pairs):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| cancel_sleep | 0.03157 | 0.03087 | 0.978x |
| sleep | 5.22165 | 5.16935 | 0.990x |
| offload | 0.07498 | 0.07242 | 0.966x |
| semaphore | 0.03175 | 0.02890 | 0.910x |

The new cancellation workload improved slightly; the other changes are within
this machine's noise. Full suite after the step: 74 files, 1055 tests, PASS.
Direct cancellation/timeout tests (`t/154`–`t/158`), stress, saturation and
soak all returned 0 with no failing tests.

### Step 9 — flat completed-job drain

`drain_jobs()` built a fresh `[fiber_id, result]` AV, RV and two result SVs for
every finished job, only for `run()` to unpack them immediately. It now appends
alternating fiber ids and results to one flat AV, and the scheduler consumes
that buffer with scalar indexing. No per-job array objects remain on the drain
path.

Interleaved A/B medians against the `99222b8` pair (30 pairs at `--count 300 --
rounds 1` unless noted):

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| offload (300) | 0.04501 | 0.03585 | 0.796x |
| offload (500, 20 pairs) | 0.05991 | 0.03808 | 0.636x |
| sleep (200, 8 pairs) | 3.36892 | 3.37097 | 1.001x |
| cancel_sleep (300, 12 pairs) | 0.02984 | 0.02965 | 0.994x |

Offload improved consistently (mean ratios 0.831x and 0.800x; new version
faster in 18/30 and 16/20 pairs). The jobless paths moved within testbed noise:
an unchanged-versus-unchanged control run over the same pair produced a 0.949x
median ratio for `parallel` and a 1.182x median ratio for `offload`, so the
1.143x `parallel` sample was not attributed to this change. Full suite after
the step: 74 files, 1055 tests, PASS. Direct cancellation, timeout, HTTP,
parallel, stress, saturation and soak reruns were clean.

### Step 10 — one startup fiber-table scan

`run()` cleared stale `F_QUEUED` flags with one full fiber-table scan, then
immediately built `%PRESET_FIBERS` with a second one, re-fetching every object
both times. `_clear_queued_flags()` now does one pass and returns the live-id
snapshot; `run()` reuses it for the deadlock detector. A new `startup` workload
calls `run(sub {})` repeatedly so this cost is measured directly.

Interleaved A/B against `0c9e6a2`, 20 pairs at `--count 400 --rounds 1`:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| startup | 0.10119 | 0.05780 | 0.571x |

The improvement was 20/20 pairs (mean 0.575x). The normal workloads stayed
inside the recorded noise: series 1.025x, parallel 0.987x, virtual 0.996x,
semaphore 0.994x, channel 0.996x medians; the offload sample was 0.774x, but
the change touches no job path, so that was not treated as a gain. Full suite
after the step: 74 files, 1055 tests, PASS. Scheduler-scope, fiber-table-growth,
job-id-reuse, destroyed-fiber, parallel, stress, saturation and soak reruns
were clean.

### Step 11 — merge job publication and next claim

A worker used to publish `JOB_DONE`, release `queue_lock`, then immediately
reacquire it to claim the next job. It now claims the next pending slot before
releasing the lock that published the completion, saving one lock/unlock pair
per job. The wake policy is unchanged (submitters still broadcast, and an empty
worker still waits on `queue_cond`), and `take_pending_job_slot()` still chooses
the lowest free slot.

Interleaved A/B against `8ae6709` at `--count 300 --rounds 1` was noisy but not
a regression: 30-pair offload samples were 1.016x median / 1.003x mean and then
0.690x / 0.774x (22/30 faster); 30-pair `--count 500` samples were 0.812x and
0.980x median. A fresh unchanged A/A control on the new pair was 1.047x median
and 0.963x median for offload at 300 and 500. Sleep improved to 0.945x median
and cancel-sleep to 0.983x; fiber-only paths stayed inside the recorded noise.
Preemption, cancellation/timeout, HTTP, ticker, transparent-unblock, parallel,
stress, saturation, soak and shutdown reruns were clean. Full suite after the
step: 74 files, 1055 tests, PASS.

### Step 12 — bounded fast idle polling

On tick-quantized platforms a 1 ms `usleep()` can cost a full 15 ms timer tick,
so short C jobs finished long before the scheduler looked again. `run()` now
uses up to four 200 µs polls after the outstanding-job count changes or a
completion arrives, then falls back to the normal 1 ms sleep. The budget is
reset only on new job activity, so a long wait does not become a busy loop.

Interleaved A/B against `d9560eb` at `--count 300 --rounds 1`:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| offload | 0.07212 | 0.02055 | 0.285x |
| offload (500) | 0.12146 | 0.03153 | 0.260x |
| sleep (200) | 3.26168 | 3.22066 | 0.987x |
| cancel_sleep | 0.03078 | 0.03019 | 0.981x |

Offload was faster in 28/30 pairs at 300 and 20/20 at 500. The fiber-only paths
stayed inside noise over 40 pairs (series 1.051x median / 1.006x mean, parallel
0.975x / 0.987x). A five-second wall-clock sleep probe used 0.109 s CPU with the
new pair versus 0.141 s before, confirming the fast polls stop. Cancellation,
timeout, repark, ticker, transparent-unblock, parallel, stress, saturation, soak
and shutdown reruns were clean. Full suite after the step: 74 files, 1055 tests,
PASS.

### Step 13 — sub-tick Windows sleeps

`SleepConditionVariableCS` rounds short timed waits up to the platform timer
tick (~15.6 ms on Windows), so `await_sleep(1)` took ~16 ms. For Windows sleeps
of 8 ms or less, the worker now yield-spins against `QueryPerformanceCounter`
for at most the requested duration. It briefly takes `queue_lock` every 32
yields (and once more at the end) to observe recall or shutdown, so cancellation
stays prompt and no submitter is blocked while it spins. Longer sleeps keep the
condition-variable wait unchanged.

Interleaved A/B against `73ca64e`, `--count 200 --rounds 1` for sleep:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| sleep | 3.49167 | 2.04146 | 0.585x |
| sleep repeat | 3.31689 | 2.01093 | 0.606x |

Each sleep sample was faster in 10/10 pairs. A direct process probe for 200
one-millisecond sleeps went from 3.491 s wall / 0.094 s CPU to 2.110 s /
0.266 s, so the extra work is bounded by the short sleep duration. Cancellation,
timeout/repark, defer, monitor, nursery, mock-time, sync, parallel, stress,
saturation, soak and shutdown reruns were clean. Offload was unchanged in code
path and noisy (1.036x then 1.735x median, with an unchanged A/A median of
0.809x on the same machine). Full suite after the step: 74 files, 1055 tests,
PASS.

### Step 14 — one-call live-fiber snapshot

`_clear_queued_flags()` used to scan the whole fiber table and call
`get_fiber_by_id()` once per slot, both when `run()` starts and on the deadlock
cleanup path. A new C helper now returns the live wrapper objects and their fids
as one flat array, so the Perl side makes a single FFI call and walks only live
fibers.

Interleaved A/B against `c5a9e14`, `--count 400 --rounds 1` for startup and
`--count 300 --rounds 1` for the others:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| startup | 0.05582 | 0.00904 | 0.162x |
| series | 0.00491 | 0.00449 | 0.914x |
| parallel | 0.00511 | 0.00435 | 0.851x |
| offload | 0.01893 | 0.02155 | 1.138x |

Startup was faster in 30/30 pairs; A/A controls were flat (old 1.005x median /
1.000x mean, new 1.007x / 1.022x). Series and parallel improved as expected
from the same per-run scan. Offload, which only performs this scan once, stayed
inside its recorded noise (10/20 pairs, 1.138x median / 1.199x mean against an
unchanged code path). Nested-run, scheduler-scope, diagnostics, wait-reason,
fiber-table-growth, backtrace, generator, channel deadlock, parallel, stress,
saturation, soak and shutdown reruns were clean. Full suite after the step:
74 files, 1055 tests, PASS.

### Rejected — unconditional 200 µs idle polling

Replacing the scheduler's `usleep(1000)` with `usleep(200)` made offload appear
10x faster (0.099x median), but on this Windows Perl `usleep(200)` degenerates
to `Sleep(0)`: 5000 calls took 0.0013 s wall and 0.031 s CPU, while 5000
`usleep(1000)` calls took 50.39 s wall. It would spin the scheduler for the
whole duration of a long job. Reverted in favor of the bounded fast-poll in
Step 12.

### Rejected — one-call current-fiber object in `_park()`

`_park()` used to cross FFI twice per wait: once for the current fid and once to
fetch that fiber's wrapper. Two variants were tried against `17e6c69`: a
`[fid, object]` snapshot (one call plus a tiny AV allocation) and an object-only
helper that read `F_FID` from the wrapper and only called `current_fid()` on the
rare missing-object path. Correctness gates passed for both, including
cancellation, timeout/repark, waiter removal, destroyed-parked-fiber, deadlock
diagnostics, parallel, stress, saturation, soak and shutdown.

Neither variant survived interleaved A/B. The tuple was neutral (semaphore
1.016x median / 1.013x mean, channel 1.001x / 0.995x). The object-only variant
looked promising once (semaphore 0.957x / 0.947x) but its repeat was 1.019x /
1.006x, with A/A controls of 1.010x / 1.009x; channel, series and parallel were
also neutral on repeat. Reverted; full suite remains PASS (74 files, 1055
tests).

### Rejected — fuse the idle scheduler counters

The idle checkpoint read `get_live_fiber_count()` and `get_outstanding_jobs()`
back-to-back. Two one-call variants were tried against `31f6494`: a small array
of the two ints and a packed 64-bit value (`live << 32 | outstanding`). Both
kept the sampling point unchanged and passed targeted scheduler, cancellation,
parallel, stress, saturation, soak and shutdown gates.

Neither variant helped. The array version was neutral on fiber paths (series
0.943x median / 0.964x mean, parallel 0.993x / 1.031x) and worse on offload
(1.774x / 1.288x). The packed version was similarly neutral at best (series
0.983x / 0.986x, parallel 0.983x / 0.951x) and worse on offload (1.397x /
1.235x); sleep and cancel_sleep were unchanged. Reverted; full suite remains
PASS (74 files, 1055 tests).

### Step 15 — ordered virtual timers with a fired prefix

Virtual timers used to be appended and the whole array resorted on every arm,
then shifted from the front when they fired. `_arm_virtual_timer()` now does a
binary insertion, and `_fire_virtual()` advances a head index and compacts only
when the consumed prefix is large. The `virtual_burst` workload was added to
the harness to arm many timers before firing any of them.

Interleaved A/B against `e82a6e1`, `--count 300/500 --rounds 1`:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| virtual_burst (300) | 0.02625 | 0.02102 | 0.801x |
| virtual_burst (300) repeat | 0.02459 | 0.02093 | 0.851x |
| virtual_burst (500) | 0.04993 | 0.03677 | 0.736x |
| virtual_burst (500) repeat | 0.04906 | 0.04020 | 0.819x |

The 500-timer case was faster in 20/20 and 19/20 pairs; A/A controls were flat
(old 0.953x median / 0.955x mean, new 1.006x / 0.993x and 1.014x / 0.997x).
The existing sequential `virtual` workload was unchanged (0.998x / 0.999x),
as expected for one timer at a time. Timeout, repark, cancel scope, ticker,
rate limiter, mock time, diagnostics, channel-select deadlock, parallel, stress,
saturation, soak and shutdown reruns were clean. Full suite after the step:
74 files, 1055 tests, PASS.

### Step 16 — lazy `maybe_yield()` argument-pad clear

The Perl `maybe_yield()` wrapper cleared `@_` before checking the mirrored
preemption threshold. Since a disabled threshold returns without crossing FFI
and without parking a fiber, clearing the pad was unnecessary on that path.
The check now runs first and `@_` is cleared only when a real C call can yield.
A `maybe_yield_public_enabled` harness workload was added to verify that the
enabled path stays neutral (a very high threshold forces the FFI call without
actually yielding).

Interleaved A/B against `b44cf3b`, `--count 300/500 --rounds 1`:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| maybe_yield_public (300) | 0.00770 | 0.00514 | 0.668x |
| maybe_yield_public (300) repeat | 0.00782 | 0.00520 | 0.665x |
| maybe_yield_public (500) | 0.01294 | 0.00876 | 0.677x |
| maybe_yield_public_enabled (300) | 0.01583 | 0.01580 | 0.998x |
| maybe_yield_public_enabled (500) | 0.02648 | 0.02637 | 0.996x |

The disabled wrapper was faster in 30/30, 30/30 and 19/20 pairs; A/A controls
were flat (old 1.008x median / 1.004x mean, new 0.998x / 0.951x and 1.001x /
0.990x). The enabled wrapper and direct-C workloads were neutral. Preemption,
priority, scheduler-scope, parallel, stress and saturation reruns were clean.
Full suite after the step: 74 files, 1055 tests, PASS.

### Rejected — binary insertion into the priority queue

When any fiber has used a non-default priority, `_enqueue()` linearly scans the
sorted run queue for the insertion point. Replacing that scan with an upper-bound
binary search preserves stable FIFO order for equal priorities and passed the
priority, scheduler-scope, cancellation, parallel, stress, saturation, soak and
shutdown gates.

It was not faster. Interleaved A/B against `0d09970`: priority_parallel at 300
was 1.023x median / 1.003x mean, at 500 it was 1.001x / 1.000x, and
priority_series was 1.109x / 1.032x; series and parallel controls were within
noise. The remaining cost is the `splice` itself, which dominates the saved
comparisons here. Reverted; full suite remains PASS (74 files, 1055 tests).

### Rejected — deduplicating `current_fid()` in await/wait

`await()` and `wait()` each read `current_fid()` twice: once for the croak test
and once for the park bookkeeping. Caching the first read is behaviorally safe
because no yield occurs between the two reads, and the targeted Future,
WaitGroup, semaphore, channel, cancellation, waiter-removal and parallel gates
passed.

There was no measurable gain. Interleaved A/B against `ad521f3` was neutral or
slightly worse: semaphore 1.036x median / 1.035x mean, channel 1.001x / 1.005x,
cancel_sleep 0.985x / 0.998x, series 1.041x / 1.013x, parallel 1.040x / 1.029x.
Reverted; full suite remains PASS (74 files, 1055 tests).

### Step 17 — longer bounded scheduler fast polling

Step 12 capped the post-activity fast-poll budget at four `usleep(200)` calls
before falling back to `usleep(1000)`. On this Windows Perl the former is
`Sleep(0)` and the latter costs a full timer tick, so short jobs were often
finished well before the scheduler looked again. The budget is now 64 polls.
The cap still bounds CPU use on long jobs; it is only reset by new job activity
or a completion.

Interleaved A/B against `b2a6de4`, `--count 300/500 --rounds 1`:

| workload | old_s | new_s | ratio |
| --- | ---: | ---: | ---: |
| offload (300) | 0.01544 | 0.00696 | 0.451x |
| offload (300) repeat | 0.02225 | 0.00724 | 0.325x |
| offload (500) | 0.02414 | 0.01214 | 0.503x |
| offload (500) repeat | 0.02311 | 0.01277 | 0.553x |
| sleep (200) | 2.27558 | 2.31795 | 1.019x |
| cancel_sleep (300) | 0.03115 | 0.03191 | 1.024x |

Offload was faster in 25/30, 19/20, 20/30 and 17/20 pairs. Offload A/A controls
were noisy (0.953x–1.702x median), but the interleaved gain repeated at both
counts. Sleep and cancel_sleep stayed inside their A/A noise; a five-second
long-sleep probe used 0.031 s CPU with 64 polls versus 0.000 s at the resolution
of `times` with the old cap, so long waits still stop spinning. Raising the cap
to 128 gave no further gain (offload 300 1.018x median / 0.927x mean, offload
500 0.961x / 0.887x), so 64 was kept.

One full-suite run hit the known host-sensitive `t/300_ticker.t` fired/dropped
timing margins; both old and new builds then passed 10/10 targeted reruns and
an immediate full rerun was PASS. Cancellation, timeout/repark, ticker, rate
limiter, mock time, diagnostics, parallel, stress, saturation, soak and shutdown
reruns were clean. Full suite after the step: 74 files, 1055 tests, PASS.

### Rejected — reusing the interrupted fiber object for enqueue

`_interrupt()` resolved a fiber with `by_id()` and then called
`_scheduler_enqueue_by_id($fid)`, which resolved the same object again. Passing
the already-resolved object directly to `_enqueue()` is equivalent because the
enqueue path repeats the `F_QUEUED` guard. All cancellation, timeout, repark,
virtual-timer, waiter-removal, destroyed-parked-fiber, semaphore, channel,
parallel, stress, saturation, soak and shutdown gates passed.

The gain was not measurable: cancel_sleep 0.990x median / 0.987x mean,
virtual_burst 0.991x / 0.972x, semaphore 1.016x / 1.000x, channel 1.028x /
1.030x. Reverted; full suite remains PASS (74 files, 1055 tests).

### Rejected — deferring the live-fiber count read

`get_live_fiber_count()` was sampled on every scheduler pass even though the
value is only used in the idle/deadlock branch. Moving that FFI read into the
branch passed the deadlock-report, channel-select, cancellation, timeout/repark,
parallel, stress, saturation, soak and shutdown gates.

The benchmark did not support it. The first interleaved A/B was mixed (offload
300: 1.275x median / 1.044x mean; offload 500: 0.693x / 0.817x; series 0.952x /
0.971x; parallel 0.923x / 0.925x), and A/A controls showed those small gains
were noise. A repeat was worse across the board (offload 300 1.281x / 1.129x,
offload 500 1.417x / 1.187x, series 1.062x / 1.055x, parallel 1.043x / 1.026x).
Reverted; full suite remains PASS (74 files, 1055 tests).

### Rejected — unified job-resume status

The completed-job path used `by_id()`, `call()`, and `is_done()` to resume a
fiber and decide whether to enqueue it. Replacing the last two with one
`run_fiber_checked($fid, [$res])` and feeding its status through `_handle_run()`
passed the targeted future, cancellation, timeout/repark, channel-select,
waiter-removal, priority, parallel, thread-pool-growth, stress, saturation, soak
and shutdown gates.

It did not help. Interleaved A/B against `72ab02a` was mixed at 300 jobs
(0.926x median / 1.430x mean, 19/30 faster) and clearly worse at 500 jobs
(1.276x / 1.802x, 9/20 faster); a longer repeat was 1.214x / 1.155x and
1.625x / 1.458x. Offload A/A controls were already very noisy (0.784x–1.214x
median), so the extra work of building the argument arrayref and taking the
combined C path cannot be justified. Reverted; full suite remains PASS (74
files, 1055 tests).

### Rejected — lock-free flag reads in the sub-tick spin

The Windows sub-tick spin took `queue_lock` at entry and exit (and every 32
yields) only to read the already-`volatile` recall and shutdown flags. Removing
those acquisitions and reading the flags directly was safe in the targeted
cancellation, timeout/repark, ticker, stress, saturation, soak and shutdown
gates, and looked modestly better once (sleep 0.921x median / 0.946x mean).

The gain did not repeat: a second A/B was 0.993x / 0.962x, A/A controls were
0.983x / 1.007x (new) and 1.011x / 0.930x (old), and cancel_sleep and offload
were neutral. Reverted rather than carry a subtler memory-ordering assumption
for no measured gain. Full suite remains PASS (74 files, 1055 tests).

### Rejected — live queued-priority count

`$HAS_PRIORITIES` is sticky: once any fiber ever gets a non-default priority,
every later enqueue scans the run queue. The alternative counted only fibers
*currently queued* with a non-default priority, falling back to the FIFO push
when that count reached zero. The counter was updated on enqueue, queue drain,
`_clear_queued_flags()` and priority changes. `priority_series` and
`priority_parallel` workloads were added to the harness to gate this case.

Against `9858d57`, `priority_parallel` at count 500 looked better once (0.932x
median / 0.939x mean), but A/A controls on the same build showed the same noise
(0.934x / 0.966x), and count 300 was neutral (1.013x / 0.979x). Series and
parallel controls were also inside noise. `t/010_priority.t` and all targeted
gates passed; the harness workloads were kept, the runtime change reverted, and
the full suite remains PASS (74 files, 1055 tests).

### Rejected — pass known fiber objects into wakeups

`Semaphore` and `Channel` already resolved a waiter with `by_id()` to check for
staleness, then `_scheduler_enqueue_by_id()` looked it up again. Passing the
known object into the enqueue helper removed that second FFI call. Correctness
gates passed, but 30 interleaved pairs against `b2255de` were neutral: semaphore
0.996x median / 0.999x mean and channel 0.988x / 0.995x, inside the recorded
noise. Series and parallel were unchanged. Reverted; full suite remains PASS
(74 files, 1055 tests).

### Rejected — deliver fiber objects from `drain_jobs()`

`drain_jobs()` could append a strong reference to each owner fiber instead of
its fid, letting `run()` skip the per-completion `by_id()` FFI call. The stale-id
fallback and deferred slot release were kept. Correctness gates passed, but the
extra refcount traffic and retained wrapper objects made offload slower: 30
interleaved pairs against `e7016b4` at `--count 300` were 1.696x median /
1.439x mean (9/30 faster), 1.404x median / 1.116x mean on a repeat, and 1.126x
median at `--count 500`. Sleep and cancel-sleep were neutral, and the fiber-only
paths stayed inside noise. Reverted; full suite remains PASS (74 files, 1055
tests).

### Rejected — reuse the scheduler's completed-job AV

Hoisting `@ready` above `run()`'s loop and clearing it each tick would keep the
flat drain buffer's AV allocation instead of freeing it between scheduler
passes. Correctness gates passed, but interleaved A/B against `9d00751` did not
hold up: offload was 0.900x median / 0.812x mean in one 30-pair run, then 1.060x
median / 1.179x mean on a repeat, and 1.479x median / 1.241x mean at
`--count 500`. The unchanged A/A control at 500 was only 1.084x median /
1.025x mean, so the repeat was a real regression. Fiber-only workloads were
neutral. Reverted; full suite remains PASS (74 files, 1055 tests).

### Rejected — splice the scheduler queue

Replacing `my @work = @SCHEDULER_QUEUE; @SCHEDULER_QUEUE = ()` with
`my @work = splice @SCHEDULER_QUEUE` kept the global AV's allocation between
enqueue bursts. It passed the parallel, stress, saturation and soak gates, but
30 interleaved A/B pairs against `c56d8d8` were neutral on every queue workload
(series 1.011x, parallel 0.989x, semaphore 0.986x, channel 1.011x medians) and
the 20-pair offload sample was 1.208x slower. The change was reverted; the full
suite still passes with 74 files and 1055 tests.

### Rejected — broadcast gate

`submit_c_job()` broadcasts `queue_cond` on every job submission. A waiter count
looked like a way to skip `WakeAllConditionVariable()` when every worker was
already busy. Two variants were tried against `cac0b1f`: one counted all
condition-wait parkers (main loop and timed sleeps), and a cheaper one counted
only timed sleepers while deriving main-loop waiters from `idle_count`. Both
passed the cancellation/timeout, HTTP, ticker, transparent, parallel, stress,
saturation and soak gates, but interleaved A/B results were unstable or worse:

| variant | workload | old_s | new_s | ratio |
| --- | --- | ---: | ---: | ---: |
| all waiters | offload (300) | 0.05761 | 0.06986 | 1.213x |
| all waiters | offload (500) | 0.10773 | 0.09012 | 0.837x |
| timed sleepers + idle | offload (300) | 0.06435 | 0.07034 | 1.093x |
| timed sleepers + idle | offload (500) | 0.08165 | 0.11021 | 1.350x |
| timed sleepers + idle | cancel_sleep (300) | 0.03104 | 0.03098 | 0.998x |
| timed sleepers + idle | sleep (200) | 3.44121 | 3.41125 | 0.991x |

With 30 pairs per offload point, the cheaper variant was faster in only 15/30
and 14/30 pairs. The gate was reverted; unconditional broadcast stays.

### Rejected — canonical waiting marker

Registering the literal `"WAITING"` as one canonical SV let `run_fiber_checked()`
recognize scheduler parks by pointer identity instead of parsing the string on
every handoff, with the string check kept as a fallback. The full suite passed,
but 12 interleaved A/B pairs against `4100be8` showed no gain (series 0.998x,
parallel 0.994x; semaphore 1.025x, channel 1.038x, offload 1.156x). The extra C
binding and Perl-side marker were reverted; the string check remains.

### Rejected — targeted worker wakeups

Counting workers actually parked in `queue_cond` and signalling only as many as
there are pending jobs passed the suite only after giving `TASK_SLEEP` its own
condition variable (a plain signal could otherwise be consumed by a timed-sleep
worker that just re-waits to its deadline). Even then, 20 interleaved A/B pairs
of the offload workload measured **3.41x slower** (old median 0.050s, new
median 0.170s): Windows wakes one signaled worker on a timer tick, while a
broadcast wakes the whole pool immediately. Splitting the condition variables
but keeping the broadcast was neutral (20 interleaved pairs: 1.02x on offload,
1.01x on the new `sleep` workload), so it was not kept either. Both C changes
were reverted; only the new `sleep` benchmark workload remains.
