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
