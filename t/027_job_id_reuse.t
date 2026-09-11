use v5.40;
use blib;
use Acme::Parataxis qw[async fiber yield stop await_sleep];
use Test2::V1 -ipP;
$|++;

# Regression test for the fiber-id reuse hazard: if a fiber is destroyed while
# one of its submitted jobs is still in flight, its id must stay reserved until
# that job is reclaimed. Otherwise the stale completion is delivered to whatever
# fiber later reuses the id.
#
# TASK_SLEEP is 0; submit_c_job(type, arg, timeout) is the fire-and-forget path.
subtest 'Destroyed fiber id stays reserved until its jobs drain' => sub {
    my ( $fidA, $A2 );

    # Run 1: spawn a fiber that fires a 120ms sleep it never awaits, then
    # finishes immediately. The id must be captured from inside the body,
    # because the object's fid slot is invalidated (-1) once it finishes.
    async {
        $A2 = fiber {
            $fidA = Acme::Parataxis->current_fid;
            Acme::Parataxis::submit_c_job( 0, 120, 0 );
            return 'stale';
        };
        yield for 1 .. 2;
        stop;
    };
    ok defined $fidA, "fiber A fired an un-awaited 120ms job and finished (fid $fidA)";

    # Destroy the finished fiber while its job is still pending. This is the
    # operation is_done/DESTROY perform once a discard/bundle feature exists;
    # the job must keep the id reserved.
    Acme::Parataxis::destroy_coro($fidA);

    # Run 2, right after: a new fiber must not inherit A's id, and it must be
    # woken only by its own sleep -- not by A's stale completion at ~120ms.
    my ( $fidX, $tX );
    async {
        my $X = fiber {
            $tX = await_sleep(150);    # long enough that A's stale job drains mid-run
            return 'X-value';
        };
        $fidX = $X->fid;
        my $gotX = $X->await;
        is $gotX, 'X-value', 'X ran cleanly, unmatched stale wake did not touch it';
    };
    ok $fidX != $fidA, "id held while job pending ($fidX != $fidA)";
    ok $tX >= 150,     "X slept its full 150ms ($tX), not the stale 120ms";

    # Run 3: after the stale job is reclaimed the id is released and can be
    # handed out safely again.
    my $fidC;
    async {
        my $D = fiber { await_sleep(200); return 'D' };    # keeps PENDING_JOBS > 0 across the stale drain
        await_sleep(1);                                    # let D submit before we claim slots
        my $C = fiber { await_sleep(5); return 'C' };
        $fidC = $C->fid;
        $C->await;
        $D->await;
    };
    ok $fidC == $fidA, "id released for reuse once jobs drained ($fidC == $fidA)";
};
done_testing;
