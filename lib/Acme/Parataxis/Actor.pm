use v5.40;
use Acme::Parataxis;
use Acme::Parataxis::Channel;
use Acme::Parataxis::Future;
use Carp qw[croak];

package Acme::Parataxis::Actor v0.1.0 {
    our @ISA = ();
    use Acme::Parataxis qw[fiber];
    use Acme::Parataxis::Channel;
    use Acme::Parataxis::Future;
    use Carp qw[croak];

    # Thin actors: a dedicated fiber owns a Channel mailbox and runs one user handler per message.
    # `ask` tags a message with a Future so the handler's return value (or die) travels back to the
    # caller; `send` is fire-and-forget. The mailbox is a plain bounded channel, so a slow handler
    # gives the *sender* backpressure instead of growing a queue without bound (M7, supervision is
    # deliberately out of scope -- see TODO.md).
    my $STOP = \do { my $x = 1 };    # envelope value that tells the loop to shut down gracefully

    sub spawn ( $class, $code, $capacity = 16 ) {
        croak 'Actor->spawn() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'Actor->spawn() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        croak "Actor->spawn() mailbox capacity must be >= 1 (got $capacity)" unless $capacity >= 1;
        my $self = bless {
            code     => $code,
            cap      => $capacity,
            mailbox  => Acme::Parataxis::Channel->new( capacity => $capacity ),
            stopping => 0,
            done     => 0,
            fiber    => undef,
        }, $class;
        my $weak = $self;    # the fiber body captures this weak copy, so a done actor is collectable
        builtin::weaken($weak);
        my $mb = $self->{mailbox};    # put a pin in it for a sec...
        $self->{fiber} = fiber {
            while (1) {
                my $env = $mb->get;    # Park it here without holding $self
                my ( $reply, $value ) = @$env;
                last if defined $value && ref $value && $value == $STOP;
                #
                my $actor = $weak;
                last unless defined $actor;    # Handle was dropped by user
                $actor->_dispatch( $reply, $value );
            }

            # Drain remaining asks on stop...
            while (1) {
                my ( $ok, $env ) = $mb->try_get;
                last unless $ok;
                my ( $reply, $value ) = @$env;
                $reply->set_error('actor stopped before this message was handled!') if defined $reply;
            }
            if ( my $actor = $weak ) { $actor->{done} = 1 }
        };
        return $self;
    }

    sub _dispatch ( $self, $reply, $value ) {
        my $err;
        my $ok = eval {
            my $rv = $self->{code}->( $self, $value );
            $reply->set_result($rv) if defined $reply;
            1;
        };
        if ( !$ok ) {
            $err = $@;
            if ( defined $reply ) {
                eval { $reply->set_error($err); 1 }
            }
            else { warn "Acme::Parataxis::Actor: handler died: $err" }
        }
        return;
    }

    sub send ( $self, $value ) {
        $self->_check_alive;
        $self->{mailbox}->put( [ undef, $value ] );
        return 1;
    }

    sub ask ( $self, $value ) {
        $self->_check_alive;
        my $reply = Acme::Parataxis::Future->new;
        $self->{mailbox}->put( [ $reply, $value ] );
        return $reply;
    }

    sub stop ($self) {
        return if $self->{done};
        $self->{stopping} = 1;

        # Non-blocking enqueue so DESTROY never yields or parks:
        $self->{mailbox}->put_priority( [ undef, $STOP ] );
        return $self;
    }
    sub is_alive ($self) { return !$self->{done} }
    sub fid      ($self) { return $self->{fiber}->fid }

    sub _check_alive ($self) {
        croak 'send()/ask(): this actor is no longer running' if $self->{done};
        croak 'send()/ask(): this actor is shutting down'     if $self->{stopping};
        return;
    }

    sub DESTROY ($self) {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        $self->stop unless $self->{done};
    }
}
#
1;
