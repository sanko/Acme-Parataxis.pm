use v5.40;

=head1 NAME

Acme::Parataxis::Signal - binary semaphores / event flags

=head1 SYNOPSIS

    use Acme::Parataxis;
    use Acme::Parataxis::Signal;

    my $sig = Acme::Parataxis::Signal->new;

    async {
        fiber { $sig->wait; say 'woken' };
        $sig->send;
    };

=head1 DESCRIPTION

A signal, binary semaphore, or event flag: an object with a two-state
flag and a FIFO queue of waiters.  A fiber parked in C<wait> does not
busy-wait; it is resumed by the scheduler when the signal fires.

The semantics mirror L<Coro::Signal> exactly:

=over 4

=item * C<send> wakes up I<one> waiter, or remembers the signal if nobody
is waiting.

=item * C<broadcast> wakes up I<all> waiters; if nobody is waiting the
signal is I<lost>.

=item * C<wait> consumes a remembered signal (returns immediately), or
parks until one is sent.

=back

=head1 METHODS

=over 4

=item C<< $sig = Acme::Parataxis::Signal->new >>

Create a new, unsignalled signal.

=item C<< $sig->wait >>

Wait for the signal to occur.  Returns immediately if the signal has
already been sent (consuming it), otherwise parks the current fiber until
a C<send> or C<broadcast> wakes it.

=item C<< $sig->wait( $callback ) >>

Does not wait: registers C<$callback> and returns immediately.  The
callback is invoked (in the sending fiber's context) when the signal is
sent or broadcast.  If the signal is already set, the callback is invoked
before C<wait> returns.

=item C<< $sig->send >>

Wake up one waiter, or remember the signal if nobody is waiting.

=item C<< $sig->broadcast >>

Wake up all waiters.  If nobody is waiting the signal is lost.

=item C<< $sig->awaited >>

True when at least one fiber is currently waiting on the signal.

=item C<< $sig->count >>

The remembered-signal state: C<1> if a C<send> is pending, else C<0>
(inherited from L<Acme::Parataxis::Semaphore>; the object shares its
C<[ state, waiters ]> layout).

=back

=head1 SEE ALSO

L<Acme::Parataxis>, L<Acme::Parataxis::Semaphore>, L<Acme::Parataxis::Channel>

=cut

package Acme::Parataxis::Signal {
    use parent 'Acme::Parataxis::Semaphore';

    # Same layout as a semaphore: [ state, waiters ].  Waiters are fiber
    # ids (integers) or callback coderefs, in FIFO order.  The state is a
    # binary flag: 1 = a send is remembered, 0 = not.  count() is inherited
    # and reads slot 0, exactly like Coro::Semaphore::count on a signal.
    use constant {
        _COUNT   => 0,
        _WAITERS => 1,
    };

    sub new {
        my $class = shift;
        return bless [ 0, [] ], $class;
    }

    sub _wake_one ($self) {
        my $waiter = shift @{ $self->[_WAITERS] };
        $self->[_COUNT] = 0;    # a woken waiter consumes the signal
        if ( ref $waiter eq 'CODE' ) {
            $waiter->();
        }
        else {
            Acme::Parataxis::_scheduler_enqueue_by_id($waiter);
        }
        return $waiter;
    }

    sub send {
        my $self = shift;
        if ( @{ $self->[_WAITERS] } ) {
            $self->_wake_one;
        }
        else {
            $self->[_COUNT] = 1;    # remember the signal
        }
        return 1;
    }

    sub broadcast {
        my $self = shift;
        my $waiters = $self->[_WAITERS];
        my $n = scalar @$waiters;   # fixed wake budget, like coro_signal_wake
        $self->[_COUNT] = 0;        # signal lost if nobody is waiting
        while ( $n-- > 0 && @$waiters ) {
            $self->_wake_one;
        }
        return 1;
    }

    sub wait {
        my $self = shift;
        if (@_) {
            push @{ $self->[_WAITERS] }, $_[0];    # callback form
            $self->send if $self->[_COUNT];        # already signalled: fire now
            return;
        }
        if ( $self->[_COUNT] ) {
            $self->[_COUNT] = 0;                   # consume the remembered signal
            return;
        }
        push @{ $self->[_WAITERS] }, Acme::Parataxis->current_fid;
        Acme::Parataxis->yield('WAITING');
        return;
    }

    sub awaited {
        my $self = shift;
        return scalar @{ $self->[_WAITERS] };    # 0 when nobody is waiting
    }
}

1;
