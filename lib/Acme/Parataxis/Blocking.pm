use v5.40;

package Acme::Parataxis::Blocking v0.0.1 {
    use Config;
    use Exporter        qw[import];
    use Carp            qw[croak];
    use Acme::Parataxis qw[fiber await_sleep];
    use Acme::Parataxis::Future;
    use Acme::Parataxis::Semaphore;
    our %EXPORT_TAGS = ( all => [ our @EXPORT_OK = qw[spawn_blocking set_max_blocking_threads max_blocking_threads] ] );

    # spawn_blocking interpreter pool: at most $SB_MAX background interpreters run closures at once, bounded by an
    # Acme::Parataxis::Semaphore created on first use (PARATAXIS_SB_THREADS overrides the default 4).
    my $SB_MAX = do { my $e = $ENV{PARATAXIS_SB_THREADS}; ( defined $e && $e =~ /\A[1-9][0-9]*\z/ ) ? int($e) : 4 };
    my $SB_PERMITS;    # Acme::Parataxis::Semaphore, capacity $SB_MAX; down() before a thread spawn, up() at reap

    # Index at which user arguments start in @_: 0 when it is a plain call, 1 when $_[0] is a self (package name or
    # blessed object). Mirrors the dance in Acme::Parataxis: read $_[0] instead of shifting, so calling this never
    # reifies the caller's pad @_. A reified @_ left behind in a parked frame trips pp_entersub's invariants when a
    # different fiber later enters the same sub at the same depth.
    sub _arg_offset {
        my $self = $_[0];
        return ( defined $self && ( ( ref $self || $self ) eq __PACKAGE__ || ( builtin::blessed($self) && $self->isa(__PACKAGE__) ) ) ) ? 1 : 0;
    }

    # Run a CPU-bound closure on a dedicated background Perl interpreter, with its result arriving as a normal Future.
    #
    # The C pool cannot do this: those workers execute C waits (sleep/read/write) only, so a real Perl closure needs a
    # real ithread. Each call therefore clones the interpreter with threads->create (the whole point of Loom's
    # worker_threads and the honest thread-per-task trade: the dense clone cost is paid per call, but the closure runs
    # in complete isolation and the scheduler is never touched while it does). The bounds and the copy-in/copy-back
    # rules are deliberate:
    #
    #   * capacity - at most set_max_blocking_threads() interpreters run at once (default 4, PARATAXIS_SB_THREADS or a
    #     call before first use change it). Excess spawn_blocking calls park the *calling* fiber on a Semaphore until
    #     a slot frees, so the bound is a true concurrency cap like the C pool's.
    #   * copy-in   - the closure sees only a snapshot of the caller's world taken at spawn: its args (threads->create
    #     args) and whatever its captured lexicals held at that instant. Threads share nothing, so in-place mutations
    #     and later writes to shared/holder state never leak back.
    #   * copy-back - the return value must survive threads::shared::shared_clone: plain scalars and nested
    #     arrays/hashes of them (blessed plain structures included) cross; an unshareable result (a CODE ref, a
    #     resource) becomes the Future's error instead. A die() in the closure likewise lands on the Future as its
    #     error.
    #   * no scheduler objects - the closure must not call back into Acme::Parataxis APIs (spawn_blocking or any
    #     blocking await) while it runs; the worker's interpreter is a copy and its scheduler state is read-only.
    #
    # The returned Future composes with await / with_timeout / with_cancel / wait_all exactly like any other, because
    # the harvest is a plain scheduler fiber resolving an Acme::Parataxis::Future. Cancelling the *await* does not
    # stop the closure (a real OS thread cannot be yanked); it only withdraws the waiter, and the slot is released
    # when the closure actually finishes. Wall-clock only: spawn_blocking croaks inside run(virtual => 1), since real
    # OS work cannot be fast-forwarded by the mock clock.
    sub spawn_blocking {
        my $o    = _arg_offset( $_[0] );
        my $code = $_[$o];
        my @args = @_[ $o + 1 .. $#_ ];
        @_ = ();
        croak 'spawn_blocking() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'spawn_blocking() requires a Perl built with thread support (useithreads)'
            unless defined $Config{useithreads} && $Config{useithreads} eq 'define';
        croak 'spawn_blocking() must be called from inside a scheduled fiber (inside run())' if Acme::Parataxis->current_fid < 0;
        croak 'spawn_blocking() is wall-clock only and cannot be driven by the mock clock of run(virtual => 1)'
            if defined Acme::Parataxis->virtual_now;
        state $loaded = do {
            require threads;
            require threads::shared;
            require Thread::Queue;
            1;
        };
        $SB_PERMITS //= Acme::Parataxis::Semaphore->new( count => $SB_MAX );
        my $fut = Acme::Parataxis::Future->new;
        my $q   = Thread::Queue->new;
        $SB_PERMITS->down('spawn_blocking capacity');
        my $thr = eval {
            threads->create(

                # The worker's whole world is the closure: run it, marshall the return value (or capture a die() as the
                # error) with shared_clone, and push one payload back. Anything unshareable fails the eval and comes
                # back as the error, never a crash in the caller.
                sub {
                    my ( $c, $a, $oq ) = @_;
                    my $payload = eval { [ 1, threads::shared::shared_clone( $c->(@$a) ), undef ] };
                    $payload = [ 0, undef, threads::shared::shared_clone($@) ] unless $payload;
                    $oq->enqueue($payload);
                    1;
                },
                $code,
                \@args,
                $q,
            );
        };
        if ( !$thr ) {
            my $err = $@ || 'thread creation failed';
            $SB_PERMITS->up;
            $fut->set_error($err);
            return $fut;
        }

        # The harvester keeps the run loop awake with a 1ms poll sleep (await_sleep rides the matching wall-clock path
        # - loop timers when a driver is attached, the worker poll otherwise - and the loop therefore never idles or
        # false-deadlocks while an interpreter is out), then reaps the payload, resolves the Future and hands the
        # capacity slot to the next waiting spawn_blocking caller. Independent of the caller's cancellation scopes, so
        # an abandoned await never strands a slot beyond the closure's own runtime. The payload is enqueued as the
        # worker's last act, so reaping it with $thr->join (instead of detach) returns immediately AND retires the
        # interpreter before global destruction - a detached thread still registered at exit trips threads.pm's
        # "Can't undef active subroutine during global destruction" on some builds and corrupts the exit status.
        eval {
            fiber {
                while ( $q->pending == 0 ) { await_sleep(1) }
                my $payload = $q->dequeue_nb;    # the one queued item: the [ok, result, error] payload
                $thr->join;
                $SB_PERMITS->up;
                if   ( $payload->[0] ) { $fut->set_result( $payload->[1] ) }
                else                   { $fut->set_error( $payload->[2] ) }
                1;
            };
            1;
        } or
            do {
            my $err = $@;
            $thr->join;
            $SB_PERMITS->up;
            $fut->set_error($err);
            };
        return $fut;
    }

    # Raise (or lower) the spawn_blocking concurrency cap. Only meaningful before the pool has been used - once a
    # Semaphore exists its capacity is live and this croaks rather than silently stealing slots from in-flight
    # closures. Mirrors set_max_threads() for the C pool.
    sub set_max_blocking_threads {
        my $o   = _arg_offset( $_[0] );
        my $max = $_[$o];
        @_ = ();
        croak 'set_max_blocking_threads() requires a positive integer' unless defined $max && $max =~ /\A[1-9][0-9]*\z/;
        croak 'set_max_blocking_threads() must be called before the first spawn_blocking() (the interpreter pool is already in use)' if $SB_PERMITS;
        $SB_MAX = int($max);
        return $SB_MAX;
    }

    # The configured spawn_blocking capacity (the default 4, PARATAXIS_SB_THREADS, or set_max_blocking_threads).
    sub max_blocking_threads () {$SB_MAX}
};
#
1;
