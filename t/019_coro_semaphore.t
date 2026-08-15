use v5.40;
use blib;
use Acme::Parataxis qw[async fiber yield];
use Test2::V1 -ipP;
$|++;
#
diag 'Ported from Coro t/15_semaphore.t: a counting semaphore (with guard) on top of fibers.';
diag 'Unlike Coro we assert invariants (capacity respected, nothing leaked) rather than an';
diag 'exact scheduler-dependent count, since scheduling order differs between the two systems.';

package Acme::Parataxis::Test::Semaphore {
    sub new   { bless { count => $_[1] }, shift }
    sub count { $_[0]{count} }
    sub up {
        my ($self) = @_;
        $self->{count}++;
    }
    sub down {
        my ($self) = @_;
        while ( $self->{count} <= 0 ) {
            Acme::Parataxis::yield();    # no permits left: wait
        }
        $self->{count}--;
    }
    sub guard {
        my ($self) = @_;
        $self->down;
        return bless { sem => $self }, 'Acme::Parataxis::Test::Semaphore::Guard';
    }
}
package Acme::Parataxis::Test::Semaphore::Guard {
    sub DESTROY { $_[0]{sem}->up }
}

package main;

subtest 'Counting semaphore (capacity 2, 15 fibers x 100 iterations)' => sub {
    my $sem = Acme::Parataxis::Test::Semaphore->new(2);
    my ( $conc, $max_conc, $count_sum ) = ( 0, 0, 0 );

    async {
        for ( 1 .. 15 ) {
            fiber {
                for ( 1 .. 100 ) {
                    $count_sum += $sem->count;    # sample before acquiring
                    my $guard = $sem->guard;      # may block (via yield)
                    $conc++;
                    $max_conc = $conc if $conc > $max_conc;
                    yield; yield; yield; yield;   # hold the guard while ceding
                    $conc--;
                }
            };
        }
    };

    is( $max_conc,     2,   'at most 2 permits handed out at once (capacity respected)' );
    is( $conc,         0,   'all guards released' );
    is( $sem->count,   2,   'semaphore count restored to capacity' );
    cmp_ok( $count_sum, '>', 0, "count sampled $count_sum times while other fibers held it" );
};

subtest 'Semaphore blocks until released (single fiber)' => sub {
    my $sem = Acme::Parataxis::Test::Semaphore->new(0);
    my $done = 0;
    async {
        my $t = fiber { $sem->down; $done++ };
        ok( $done == 0, 'fiber parked: no permits yet' );
        $sem->up;    # release a permit
        yield;       # let the waiter run
        is( $done, 1, 'fiber resumed once a permit was released' );
    };
};
done_testing();
