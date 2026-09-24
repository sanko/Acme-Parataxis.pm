use v5.40;
use Acme::Parataxis;
use Acme::Parataxis::Channel;
use Acme::Parataxis::Future;
use Carp qw[croak];

package Acme::Parataxis::Actor v0.1.1 {
    our @ISA = ();
    use Acme::Parataxis qw[fiber];
    use Acme::Parataxis::Channel;
    use Acme::Parataxis::Future;
    use Carp qw[croak];

    # Thin actors: a dedicated fiber owns a Channel mailbox and runs one user handler per message.
    # `ask` tags a message with a Future so the handler's return value (or die) travels back to the
    # caller; `send` is fire-and-forget. The mailbox is a plain bounded channel, so a slow handler
    # gives the *sender* backpressure instead of growing a queue without bound. Spawned with
    # supervised => 1, a handler die kills the actor instead of only failing that one ask, which is
    # what Acme::Parataxis::Supervisor supervises.
    my $STOP = \do { my $x = 1 };    # envelope value that tells the loop to shut down gracefully

    sub spawn ( $class, $code, $capacity = 16, %opts ) {
        croak 'Actor->spawn() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'Actor->spawn() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        croak "Actor->spawn() mailbox capacity must be >= 1 (got $capacity)" unless $capacity >= 1;
        my %unknown = %opts;
        delete @unknown{qw[supervised]};
        croak 'Actor->spawn(): unknown options: ' . join ', ', sort keys %unknown if %unknown;
        my $self = bless {
            code       => $code,
            cap        => $capacity,
            opts       => {%opts},
            supervised => $opts{supervised} ? 1 : 0,
            mailbox    => Acme::Parataxis::Channel->new( capacity => $capacity ),
            stopping   => 0,
            done       => 0,
            error      => undef,
            on_death   => [],
            fiber      => undef,
        }, $class;
        my $weak = $self;    # the fiber body captures this weak copy, so a done actor is collectable
        builtin::weaken($weak);
        my $mb = $self->{mailbox};    # put a pin in it for a sec...
        $self->{fiber} = fiber {
            my $crash;

            # The loop is guarded so teardown is reached on *every* exit path: an interrupt (a
            # cancellation token or a with_timeout deadline landing on this fiber) thrown from a
            # parked wait inside a handler escapes the loop and must not skip the drain below.
            my $ok = eval {
                while (1) {
                    my $env = $mb->get;    # Park it here without holding $self
                    my ( $reply, $value ) = @$env;
                    last if defined $value && ref $value && $value == $STOP;
                    #
                    my $actor = $weak;
                    last unless defined $actor;    # Handle was dropped by user
                    my $err = $actor->_dispatch( $reply, $value );
                    if ( defined $err && $actor->{supervised} ) { $crash = $err; last }
                }
                1;
            };
            $crash = $@ unless $ok;
            if ( my $actor = $weak ) { $actor->_finish($crash) }
        };
        return $self;
    }

    # Teardown, on every exit path. Refuses new messages first (so nothing can be queued after the
    # drain below), fails everything still outstanding, then tells whoever is watching that this
    # actor is gone. A defined $crash is what killed us; undef means a graceful stop.
    sub _finish ( $self, $crash ) {
        return if $self->{done};
        $self->{done}  = 1;
        $self->{error} = $crash if defined $crash;

        # The drain is best effort: a watcher must learn about this death even if an interrupt lands
        # on this fiber mid-teardown, or whoever is waiting for the report waits forever.
        my $msg = defined $crash ? "$crash" : 'actor stopped before this message was handled!';
        eval { $self->_fail_queued($msg); 1 } or warn "Acme::Parataxis::Actor: drain failed: $@";
        my $hooks = delete $self->{on_death} // [];
        for my $cb (@$hooks) {
            warn "Acme::Parataxis::Actor: death hook died: $@" unless eval { $cb->( $self, $self->{error} ); 1 };
        }
        return;
    }

    # Fail every ask still outstanding: whatever sits in the mailbox, plus any sender parked in
    # put() that an earlier take released. Each take frees one mailbox slot, which is what releases
    # a parked sender, so one yield per idle stretch lets a released sender land its envelope before
    # the mailbox is declared empty. Nothing new can arrive meanwhile: done is already set, so
    # _check_alive refuses it, and a sender between that check and the push never yields.
    sub _fail_queued ( $self, $msg ) {
        my $mb   = $self->{mailbox};
        my $idle = 0;
        while ( $idle < 3 ) {
            my ( $ok, $env ) = $mb->try_get;
            if ($ok) {
                $idle = 0;
                my ($reply) = @$env;
                next unless defined $reply;
                next if $reply->is_ready;
                eval { $reply->set_error($msg); 1 } or warn "Acme::Parataxis::Actor: failed to fail a queued ask: $@";
                next;
            }
            $idle++;
            Acme::Parataxis->yield if $idle == 1;
        }
        return;
    }

    # Fires exactly once when this actor is gone: $err is what killed it, or undef for a graceful
    # stop. An actor that is already done calls back immediately, so a watcher never has to check.
    sub on_death ( $self, $cb ) {
        croak 'on_death() requires a CODE ref' unless ref $cb eq 'CODE';
        if ( $self->{done} ) { $cb->( $self, $self->{error} ); return $self }
        push $self->{on_death}->@*, $cb;
        return $self;
    }
    sub error ($self) { $self->{error} }    # why it died, or undef if it stopped gracefully

    # A fresh, already-running actor with the same handler, mailbox size and options: what a
    # supervisor starts in place of this one. The new actor owns a new mailbox, so asks still
    # outstanding here are failed here rather than answered there.
    sub respawn ($self) {
        return ref($self)->spawn( $self->{code}, $self->{cap}, $self->{opts}->%* );
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
            elsif ( !$self->{supervised} ) {    # a supervised actor reports this death to its supervisor instead
                warn "Acme::Parataxis::Actor: handler died: $err";
            }
        }
        return $err;                            # undef when the handler returned normally; the caller turns it into a crash if supervised
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
        return $self if $self->{done} || $self->{stopping};
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
