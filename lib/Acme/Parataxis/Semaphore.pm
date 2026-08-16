use v5.40;

=head1 NAME

Acme::Parataxis::Semaphore - counting semaphores

=head1 SYNOPSIS

    use Acme::Parataxis;
    use Acme::Parataxis::Semaphore;

    my $sem = Acme::Parataxis::Semaphore->new;   # unlocked by default

    async {
        fiber { $sem->down };   # wait for a signal
        $sem->up;
    };

=head1 DESCRIPTION

A counting semaphore with the same interface and behaviour as
L<Coro::Semaphore>: a simple integer counter that optionally blocks fibers
when it reaches zero.  There is no owner associated with a semaphore, so
one fiber can C<down> it while another can C<up> it, C<up> may be called
before C<down>, and so on.

Blocked fibers are parked (they do not busy-wait) and are resumed in FIFO
order as permits become available, exactly like the futures used by
C<await>.

=head1 METHODS

=over 4

=item C<< $sem = Acme::Parataxis::Semaphore->new( [ $initial ] ) >>

Creates a new semaphore.  The default count is C<1> (unlocked); zero or a
negative value leaves it locked.

=item C<< $sem->count >>

Returns the current count.  C<down> can succeed without blocking only when
this is strictly greater than zero.

=item C<< $sem->down >>

Decrements the counter, blocking the current fiber until a permit is
available if the counter is zero or less.  Returns true.

=item C<< $sem->try >>

Like C<down>, but returns false immediately instead of blocking when no
permit is available.

=item C<< $sem->up >>

Increments the counter and wakes up a single waiting fiber if the count
became positive.

=item C<< $sem->adjust( $diff ) >>

Atomically adds C<$diff> to the count.  If the count becomes positive,
wakes up as many waiting fibers as there are permits available (each
resumed fiber consumes one permit).

=item C<< $sem->wait >>

Blocks until the count is positive but does I<not> decrement it.  After it
returns, the next C<down> or C<try> is guaranteed to succeed until the next
fiber switch.

=item C<< $sem->waiters >>

In scalar context, the number of fibers currently blocked on this
semaphore.

=item C<< $guard = $sem->guard >>

Calls C<down> and returns a guard object that calls C<up> when destroyed.

=back

=head1 SEE ALSO

L<Acme::Parataxis>, L<Acme::Parataxis::Channel>

=cut

package Acme::Parataxis::Semaphore {
    # Object layout: [ count, waiters ].  Waiters are stored as fiber ids,
    # in FIFO order, and re-enqueued via the scheduler when woken.
    use constant {
        _COUNT   => 0,
        _WAITERS => 1,
    };

    sub new {
        my ( $class, $count ) = @_;
        return $class->_alloc( defined $count ? $count : 1 );
    }

    # Internal constructor used by Channel; mirrors Coro::Semaphore::_alloc.
    sub _alloc {
        my ( $class, $count ) = @_;
        return bless [ $count // 1, [] ], $class;
    }

    sub count   { $_[0][_COUNT] }
    sub waiters { scalar @{ $_[0][_WAITERS] } }

    # Park the current fiber until a permit is available.  On wake we
    # re-check the count (the resumed fiber consumes its permit itself),
    # exactly like Coro's woken waiters do.
    sub _block_until_available ($self) {
        while ( $self->[_COUNT] <= 0 ) {
            push @{ $self->[_WAITERS] }, Acme::Parataxis->current_fid;
            Acme::Parataxis->yield('WAITING');
        }
        return 1;
    }

    sub down {
        my $self = shift;
        $self->_block_until_available;
        $self->[_COUNT]--;
        return 1;
    }

    sub try {
        my $self = shift;
        return 0 if $self->[_COUNT] <= 0;
        $self->[_COUNT]--;
        return 1;
    }

    sub up {
        my $self = shift;
        $self->[_COUNT]++;
        if ( $self->[_COUNT] > 0 && @{ $self->[_WAITERS] } ) {
            Acme::Parataxis::_scheduler_enqueue_by_id( shift @{ $self->[_WAITERS] } );
        }
        return 1;
    }

    sub adjust {
        my ( $self, $diff ) = @_;
        $self->[_COUNT] += $diff;
        my $n = $self->[_COUNT];
        my $waiting = scalar @{ $self->[_WAITERS] };
        $n = $waiting if $waiting < $n;
        while ( $n-- > 0 ) {
            Acme::Parataxis::_scheduler_enqueue_by_id( shift @{ $self->[_WAITERS] } );
        }
        return 1;
    }

    sub wait {
        my $self = shift;
        return $self->_block_until_available;
    }

    sub guard {
        my $self = shift;
        $self->down;
        return bless [ $self ], 'Acme::Parataxis::Semaphore::Guard';
    }
}

package Acme::Parataxis::Semaphore::Guard {
    sub DESTROY {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        $_[0][0]->up;
    }
}

1;
