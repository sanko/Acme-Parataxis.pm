use v5.40;
use Acme::Parataxis::Semaphore;

=head1 NAME

Acme::Parataxis::Channel - message queues

=head1 SYNOPSIS

    use Acme::Parataxis;
    use Acme::Parataxis::Channel;

    my $q = Acme::Parataxis::Channel->new( 4 );

    async {
        fiber { $q->put( $_ ) for 1 .. 8 };      # producers
        say $q->get for 1 .. 8;                  # consumer
    };

=head1 DESCRIPTION

A Coro::Channel-style message queue: the equivalent of a unix pipe.  You
put things in one end and read them out of the other.  If the channel is
full, writers block; if it is empty, readers block.  Both ends can be used
by as many fibers as you want concurrently.

A channel of size C<1> is a rendezvous point (no buffering: C<put> waits
for a matching C<get>); to buffer one element use size C<2>, and so on.

=head1 METHODS

=over 4

=item C<< $q = Acme::Parataxis::Channel->new( [ $maxsize ] ) >>

Creates a new channel with the given capacity.  The default (or zero) is
practically unlimited.

=item C<< $q->put( $scalar ) >>

Puts the given scalar into the queue, blocking the current fiber until
there is room if the channel is full.

=item C<< $q->get >>

Returns the next element from the queue, waiting if necessary.  After
C<shutdown>, returns C<undef> once the buffered data has been drained.

=item C<< $q->shutdown >>

Wakes up any pending C<get> calls and makes C<get> return C<undef> when
the queue is (or becomes) empty, as if infinitely many C<undef> elements
had been queued.  Useful to signal end-of-data to consumers, like EOF on a
socket.  Calls to C<put> still work normally and their data is still
returned by subsequent C<get> calls.

=item C<< $q->size >>

The number of elements waiting to be consumed (may include elements whose
writers are still blocked on a full channel, but not the shutdown
condition).

=back

=head1 SEE ALSO

L<Acme::Parataxis>, L<Acme::Parataxis::Semaphore>

=cut

package Acme::Parataxis::Channel {
    # Object layout mirrors Coro::Channel: a data array plus two counting
    # semaphores - SGET counts stored elements, SPUT counts free space.
    # Writers push their element *before* blocking on SPUT so that size()
    # (the data array length) matches Coro's semantics.
    use constant {
        DATA => 0,
        SGET => 1,
        SPUT => 2,
    };

    sub new {
        my ( $class, $maxsize ) = @_;
        my $space = defined $maxsize && $maxsize > 0 ? $maxsize : 2_000_000_000;
        return bless [
            [],
            Acme::Parataxis::Semaphore->_alloc(0),
            Acme::Parataxis::Semaphore->_alloc( $space - 1 ),
        ], $class;
    }

    sub put {
        my ( $self, $value ) = @_;
        push @{ $self->[DATA] }, $value;
        $self->[SGET]->up;
        $self->[SPUT]->down;
        return 1;
    }

    sub get {
        my ($self) = @_;
        $self->[SGET]->down;
        $self->[SPUT]->up;
        return shift @{ $self->[DATA] };
    }

    sub shutdown {
        my ($self) = @_;
        $self->[SGET]->adjust(1_000_000_000);
        return 1;
    }

    sub size {
        my ($self) = @_;
        return scalar @{ $self->[DATA] };
    }

    # Undocumented, like Coro's: if it breaks, you get to keep the pieces.
    sub adjust {
        my ( $self, $diff ) = @_;
        return $self->[SPUT]->adjust($diff);
    }
}

1;
