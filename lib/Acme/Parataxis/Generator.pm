use v5.40;
no warnings 'recursion';
use Acme::Parataxis;

package Acme::Parataxis::Generator v0.1.1 {
    our @ISA = ();
    our $RESERVED;
    our $DRAIN = \do { my $x = 1 };    # an opaque scalar ref, so no user yield/die value can collide with the marker
    use Carp qw[croak];

    # Stackful lazy iterator backed by a private fiber (online note: the producer never enters the scheduler run queue;
    # each ->next resumes it via coro_call, i.e. it parks in the same way a coroutine parks, and exhaustion/error
    # finish the fiber normally). Windows longjmp across the very first fiber allocated in a process (fid 0) is
    # unreliable (the body's die escapes every anchored JMPENV -> "uncaught die" or 0xC0000005), so a generator must
    # never land on fid 0, a slot the resume-die path is not exercised on until much later in the suite.
    #
    # On the mainline nothing else has allocated a fiber yet, so one permanently parked reserved fiber takes fid 0 and
    # every generator then lands on fid >= 1. Inside a run the run's own main fiber already holds fid 0 before the body
    # executes, so a generator built there is on fid >= 1 regardless and reserving again buys nothing: all it adds is a
    # fiber parked for the lifetime of the process, which the scheduler's deadlock detector counts as run work and
    # trips over when that run ends. (Acme::Parataxis snapshots %PRESET_FIBERS when a run starts, so a fiber born
    # *during* the run is not excluded from that count the way a fiber from an earlier run is.)
    sub _ensure_reserved_fiber {
        return if $RESERVED;
        return if Acme::Parataxis->current_fid >= 0;    # a run already owns fid 0; do not add a permanent fiber
        my $fiber = Acme::Parataxis->new(
            code => sub {
                Acme::Parataxis::coro_yield( [] );
                return;
            }
        );
        Acme::Parataxis::coro_call( $fiber->fid, [] );
        $RESERVED = $fiber;
        return;
    }

    sub new ( $class, $code ) {
        croak 'Generator->new() requires a CODE ref' unless ref $code eq 'CODE';
        _ensure_reserved_fiber();

        # The body's yield: suspends the private fiber and returns the next value to ->next.
        # When DESTROY resumes the fiber to drain it, coro_yield returns our drain marker and
        # the closure dies with it so the body stops on the next suspension boundary.
        my $yield = sub ($value) {
            my $got = Acme::Parataxis::coro_yield( [$value] );
            die $got->[0] if ref $got eq 'ARRAY' && @$got == 1 && ref( $got->[0] ) eq 'SCALAR' && $got->[0] == $DRAIN;
            return;
        };

        # The fiber runs the body inside a fiber-local eval. A die raised by the body on a
        # resumed trip is caught here (the scheduler's own G_EVAL can miss it on resume, see
        # fid-0 note above) and the error string is parked in an outer lexical that ->next
        # dereferences and rethrows on the caller's stack, so no die ever crosses a transfer.
        my $err;
        my $driver = sub {
            my $ok = eval { $code->($yield); 1 };
            $err = $@ if !$ok;
            return;
        };
        my $gen_fiber = Acme::Parataxis->new( code => $driver );
        return bless { fiber => $gen_fiber, err_ref => \$err }, $class;
    }

    sub next ($self) {
        my $fiber = $self->{fiber};
        return undef if $fiber->is_done;
        my $rv = Acme::Parataxis::coro_call( $fiber->fid, [] );
        return ( ref $rv eq 'ARRAY' ) ? $rv->[0] : undef unless $fiber->is_done;
        my $err = ${ $self->{err_ref} };
        die $err if defined $err && !( ref($err) eq 'SCALAR' && $err == $DRAIN );
        return undef;
    }
    sub is_done ($self) { $self->{fiber}->is_done }

    # An unexhausted (suspended) fiber is drained to its natural exit instead of being torn
    # down in mid-shot: resuming it with the drain marker makes the yield closure die, the
    # fiber-local eval absorbs it, and the fiber finishes normally (perl unwinds its own
    # scopes), after which coro_call reaps it. (destroy_coro mid-eval became safe with the
    # the C-level fix that made destroying a parked fiber safe, but draining is retained so the body can run its own finalization.)
    sub DESTROY ($self) {
        my $fiber = $self->{fiber};
        return if !defined $fiber;
        my $fid = $fiber->fid;
        return if !defined $fid || $fid < 0;
        if ( !$fiber->is_done ) {
            local $@;
            eval { Acme::Parataxis::coro_call( $fid, [$DRAIN] ); 1 };
        }
        return if $fiber->is_done;
        Acme::Parataxis::destroy_coro($fid);
        $fiber->[Acme::Parataxis::F_FID]     = -1;
        $fiber->[Acme::Parataxis::F_IS_DONE] = 1;
        return;
    }
};
#
1;
