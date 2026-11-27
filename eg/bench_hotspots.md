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
- `maybe_yield`: `400 * --count` disabled-preemption FFI calls.

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

Optimization steps: pending.
