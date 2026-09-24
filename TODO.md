# TODO - Concurrency Roadmap

The previous roadmap is complete: discussions
[#7](https://github.com/sanko/Acme-Parataxis.pm/discussions/7),
[#9](https://github.com/sanko/Acme-Parataxis.pm/discussions/9), and
[#10](https://github.com/sanko/Acme-Parataxis.pm/discussions/10) were shipped in full across
Milestones M1-M8 and Cards 1-10 (nursery, cancellation, with_timeout, sync primitives,
RwLock, CSP select, generators, actors, deadlock tracing, event-loop drivers, supervisors,
STM, async streams, ticker, rate limiter, fiber limits, transparent unblocking, and
park-site backtraces). The completed plan is recorded in CI_PROGRESS.md; this file is
reset and ready for the next round of ideas.

## Known issues

- **`perl -c lib/Acme/Parataxis.pm` prints `syntax OK` then segfaults (exit 139).** Diagnosed but *not fixed* - out of
  scope so far. It reproduces on an unmodified HEAD, on untouched sibling modules, and on a trivial
  `use Acme::Parataxis;` file, so it is not caused by the scheduler changes. It is not a CHECK/END problem: `-c`
  runs `CHECK` but never `END`, yet adding `CHECK { cleanup() if $^C }` did not help. Loading `Affix` alone is clean,
  and `PERL_DESTRUCT_LEVEL=2` suppresses it, which points at interpreter destruction rather than compile. Nothing in
  the shipped workflow is affected: `perl Build`, `perl Build test` (59 files, 909 tests) and normal execution are
  all clean.

## Backlog

Leftover half-formed concepts and implementations from the first roadmap. Keeping them here so nothing is lost.

- `with_cancel` - cancellation *scopes* (register/unregister groups of waits as one unit).
- `defer` - run-cleanup-on-every-exit (like Go's `defer` for fiber exit paths).
- Monitor & linked death notification (observe another fiber's death without owning it).
- Actor hot-code swap + named registry.
- `with_timeout` re-entrancy polish.
- `Channel->new( timeout => $ms )` - per-channel default wait timeout for `get`/`put`, straight from #7's CSP sketch
  (`Channel->new( capacity => 1024, timeout => 500, ... )`). Never implemented; today the only channel timeout is
  `select`'s `timeout` option. A channel-level `timeout` would park `get`/`put`/`try_*` with that deadline and
  croak `Error::Timeout` on expiry.
- Note: `select`'s `default` arm, the main-loop driver hook, and channel combinators (map/filter/merge) all shipped.

## Next roadmap

- **TBD.** The blank slate above is the working space for the next discussion-driven round.