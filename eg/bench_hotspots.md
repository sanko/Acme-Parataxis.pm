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
