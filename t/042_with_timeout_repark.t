use v5.40;
use blib;
use Acme::Parataxis qw[async nursery await_sleep with_timeout];
use Acme::Parataxis::Nursery;
use Test2::V1 -ipP;
$|++;

# R2 regression: with_timeout's re-park branch (Parataxis.pm "parent interrupted mid-await while the child is still
# parked"). The parent must not unwind its frame while the child's coroutine is mid-park -- the runtime cannot destroy
# a parked coroutine without crashing. with_timeout instead re-parks the parent registered for the child's death, so
# the scheduler reaps the coroutine before the frame unwinds. Two interrupt sources exercise the branch:
#   (a) a nursery cancelling a child that is parked in a with_timeout await (deterministic, no timing);
#   (b) an enclosing with_timeout deadline firing while the child is parked in an inner nursery join.
subtest 'a nursery cancelling a child parked in a with_timeout await reaps the grandchild' => sub {
    my ( $err, $inner_done ) = ( undef, 0 );
    my $base = Acme::Parataxis::get_live_fiber_count();
    async {
        eval {
            nursery(
                sub ($n) {
                    $n->spawn(
                        sub {
                            with_timeout( 0, sub { await_sleep(300); $inner_done = 1 } );
                        }
                    );
                    $n->spawn( sub { die 'boom' } );
                }
            );
        };
        $err = $@;
    };
    ok ref($err) && $err->isa('Acme::Parataxis::Error::Nursery'), 'the nursery aggregate is thrown';
    like "$err", qr/^nursery failure: boom\b/, 'the real failure is the primary';
    ok !$inner_done, 'the grandchild inside the with_timeout was cancelled, not run to completion';
    is Acme::Parataxis::get_live_fiber_count(), $base, 'no fiber leaked: the still-parked grandchild coroutine was reaped without crashing';
};
subtest 'the enclosing deadline fires while the child is parked in an inner nursery join' => sub {
    my ( $err, $done ) = ( undef, 0 );
    my $base = Acme::Parataxis::get_live_fiber_count();
    async {
        eval {
            with_timeout(
                20,
                sub {    # outer deadline: fires while the inner child is still parked
                    with_timeout(
                        0,
                        sub {    # inner frame: exists only to be interrupted out from under
                            nursery(
                                sub ($n) {
                                    $n->spawn( sub { await_sleep(300); $done = 1 } );
                                    $n->spawn( sub { await_sleep(300) } );
                                }
                            );
                        }
                    );
                }
            );
        };
        $err = $@;
    };
    ok ref($err) && $err->isa('Acme::Parataxis::Error::Timeout'), 'the outer timeout propagates to the caller';
    ok !$done,                                                    'the deepest grandchild was cancelled and drained by the teardown';
    is Acme::Parataxis::get_live_fiber_count(), $base, 'no fiber leaked: the still-parked grandchild coroutine was reaped without crashing';
};
subtest 'the scheduler is clean afterwards: a later with_timeout runs normally' => sub {
    my $second;
    async {
        eval {
            with_timeout(
                20,
                sub {
                    with_timeout(
                        0,
                        sub {
                            nursery(
                                sub ($n) {
                                    $n->spawn( sub { await_sleep(300) } );
                                }
                            );
                        }
                    );
                }
            );
        };
        $second = eval {
            with_timeout( 300, sub { await_sleep(2); 'still-works' } );
        };
    };
    is $second, 'still-works', 'with_timeout works after a re-park teardown';
};
#
done_testing;
