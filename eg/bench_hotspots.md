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
