use v5.40;
no warnings 'recursion';
use Acme::Parataxis;

package Acme::Parataxis::Generator v0.1.0 {
    our @ISA = ();
    our $RESERVED;
    our $DRAIN = '__PARATAXIS_GENERATOR_DRAIN__';
    use Carp qw[croak];

    # Stackful lazy iterator backed by a private fiber (online note: the producer never
    # enters the scheduler run queue; each ->next resumes it via coro_call, i.e. it parks in
    # the same way a coroutine parks, and exhaustion/error finish the fiber normally).
    # Windows longjmp across the very first fiber allocated in a process (fid 0) is
    # unreliable (the body's die escapes every anchored JMPENV -> "uncaught die" or
    # 0xC0000005). Keeping one permanently parked reserved fiber means generators always
    # land on fid >= 1, where the resume-die path is exercised by the whole test suite from
    # the first M1 scheduler tests on and has always been stable.
    sub _ensure_reserved_fiber {
        return if $RESERVED;
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
            die $got->[0] if ref $got eq 'ARRAY' && @$got == 1 && $got->[0] eq $DRAIN;
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
        die $err if defined $err && $err ne $DRAIN;
        return undef;
    }

    sub is_done ($self) {
        return $self->{fiber}->is_done;
    }

    # An unexhausted (suspended) fiber is drained to its natural exit instead of being torn
    # down in mid-shot: resuming it with the drain marker makes the yield closure die, the
    # fiber-local eval absorbs it, and the fiber finishes normally (perl unwinds its own
    # scopes), after which coro_call reaps it. Tearing a fiber down mid-eval with
    # destroy_coro instead poisons the perl state of later fibers (0xC0000005).
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
}
1;
