use v5.40;
no warnings 'recursion';    # fibers run on separate heap stacks; Perl's C-stack-depth heuristic misfires there
use experimental qw[class try];

package Acme::Parataxis v0.1.1 {
    use Affix;
    use Config;
    use File::Spec;
    use File::Basename qw[dirname];
    use Time::HiRes    qw[usleep];
    use Exporter       qw[import];
    use Carp           qw[croak];
    use Scalar::Util   qw[refaddr];
    use Acme::Parataxis::Error;
    our %EXPORT_TAGS = (
        all => [
            our @EXPORT_OK
                = qw[
                run spawn yield await stop async fiber
                await_sleep await_read await_write await_core_id
                current_fid tid root maybe_yield on_wake with_timeout nursery
                set_max_threads max_threads set_max_fibers max_fibers dump_fibers
                atomically retry
                ]
        ]
    );
    #
    our @IPC_BUFFER;
    my $lib;
    my @SCHEDULER_QUEUE;
    my %SCHEDULER_QUEUED;
    my $IS_RUNNING = 0;
    my $DRIVER;           # the attached Acme::Parataxis::Driver (undef = the worker-pool fallback path), see attach_loop
    my %PARKED;           # fid => true, while the fiber is suspended in a blocking wait (see _park / _resume_hooks)
    my %PARK_REGS;        # fid => coderef that removes a parked fiber from its waiter list when its park is interrupted
    our %FIBER_LOCALS;    # fiber-object refaddr => { local-id => value }; stashes for Acme::Parataxis::Local

    # Fiber object layout: a flat arrayref of slots rather than perlclass objects (array access is much cheaper than
    # classes and even hash lookup on the hot spawn/await path).
    use constant {
        F_CODE        => 0,
        F_IS_DONE     => 1,
        F_ERROR       => 2,
        F_RESULT      => 3,
        F_FID         => 4,
        F_IS_READY    => 5,
        F_CALLBACKS   => 6,
        F_WAITER      => 7,
        F_LAST_STATUS => 8,
        F_PRIORITY    => 9,
        F_WAIT_REASON => 10,
        F_WAKE_HOOKS  => 11,
        F_INTERRUPT   => 12
    };

    # Scheduler run queue. Kept sorted by descending priority (stable for equal priorities, so a group of same-priority fibers stays FIFO).
    sub _enqueue ($fiber) {
        my $fid = $fiber->[F_FID];
        return if $SCHEDULER_QUEUED{$fid};
        $SCHEDULER_QUEUED{$fid} = 1;
        my $prio = $fiber->[F_PRIORITY] // 0;
        my $i    = 0;
        $i++ while $i < @SCHEDULER_QUEUE && ( $SCHEDULER_QUEUE[$i]->[F_PRIORITY] // 0 ) >= $prio;
        splice @SCHEDULER_QUEUE, $i, 0, $fiber;
    }

    # All C fiber ids that are currently live. Used by run() to snapshot the fibers that predate a run so its
    # deadlock detector only considers fibers the run actually created (fibers leaked by a prior deadlocked run stay
    # parked forever and would otherwise poison every later run).
    sub _live_fiber_ids () {
        my @ids;
        for ( my $fid = 0; $fid < 1024; $fid++ ) {
            my $obj = Acme::Parataxis::get_fiber_by_id($fid);
            push @ids, $fid if defined $obj && ( ref $obj || '' ) ne '';
        }
        return @ids;
    }

    # M8 diagnostics. A snapshot of every live fiber, riding entirely on M0's wait_reason: _park records
    # [reason, file, line] on the fiber before it yields and _resume_hooks clears it on a natural wake, so a
    # live fiber that still carries a reason (or is in %PARKED) is blocked, not merely preempted. WAITING =
    # parked on a wait; READY = in the scheduler run queue; RUNNING = the fiber calling the snapshot (only
    # when taken from inside a run); RUNNABLE = live but neither parked nor queued (e.g. a generator's body
    # or a fiber surrendered mid-quantum). A Perl-level stack capture of the yield site is a later nice-to-have;
    # for now the recorded site is the wait_reason site (the user's call for direct waits like await_sleep, the
    # wait's own method for Sync/Channel waits whose level targeting is tuned for their error messages).
    sub _fiber_snapshot () {
        my $current = get_current_parataxis_id();
        my @rows;
        for my $fid ( _live_fiber_ids() ) {
            my $fiber = Acme::Parataxis::get_fiber_by_id($fid);
            next unless $fiber && ref $fiber;
            my $reason = $fiber->[F_WAIT_REASON];    # undef once the fiber is woken normally
            my $state
                = ( defined $reason || $PARKED{$fid} ) ? 'WAITING' :
                $SCHEDULER_QUEUED{$fid}                ? 'READY' :
                ( $current >= 0 && $fid == $current )  ? 'RUNNING' :
                'RUNNABLE';
            push @rows, { fid => $fid, state => $state, reason => $reason };
        }
        return [ sort { $a->{fid} <=> $b->{fid} } @rows ];
    }

    # Dumps every live fiber. Returns the arrayref of { fid, state, reason (wait_reason site) } records and, when
    # called with a filehandle, also prints a human-readable report there (dump_fibers() with no argument only
    # returns the data). Safe to call from anywhere: top-level (outside a run) reports fibers leaked by an earlier
    # deadlocked run, inside a run it classifies each live fiber exactly.
    sub dump_fibers {
        my $invocant = shift;
        if ( !defined $invocant ||
            ( ( ref $invocant || $invocant ) ne __PACKAGE__ && !( builtin::blessed($invocant) && $invocant->isa(__PACKAGE__) ) ) ) {
            unshift @_, $invocant if defined $invocant;
            $invocant = __PACKAGE__;
        }
        my $fh   = shift;
        my $rows = _fiber_snapshot();
        return $rows unless $fh;
        say $fh 'Acme::Parataxis live fiber dump';
        say $fh '  fid   state    wait reason       where';
        for my $r (@$rows) {
            my ( $file, $line ) = $r->{reason} ? @{ $r->{reason} }[ 1, 2 ] : ( '-', '-' );
            say $fh sprintf '  %-4d %-8s %-17s %s:%s', $r->{fid}, $r->{state}, ( $r->{reason} && $r->{reason}[0] ) // '-', $file, $line;
        }
        return $rows;
    }

    sub _bind_functions ($l) {
        affix $l, 'init_system',                       [],                             Int;
        affix $l, 'create_fiber',                      [ Pointer [SV], Pointer [SV] ], Int;
        affix $l, 'spawn_fiber',                       [ Pointer [SV], Pointer [SV] ], Pointer [SV];
        affix $l, 'coro_call',                         [ Int, Pointer [SV] ],          Pointer [SV];
        affix $l, 'run_fiber_checked',                 [ Int, Pointer [SV] ],          Int;
        affix $l, 'coro_transfer',                     [ Int, Pointer [SV] ],          Pointer [SV];
        affix $l, 'coro_yield',                        [ Pointer [SV] ],               Pointer [SV];
        affix $l, 'is_finished',                       [Int],                          Int;
        affix $l, 'get_fiber_by_id',                   [Int],                          Pointer [SV];
        affix $l, 'get_live_fiber_count',              [],                             Int;
        affix $l, 'destroy_coro',                      [Int],                          Void;
        affix $l, 'force_depth_zero',                  [ Pointer [SV] ],               Void;
        affix $l, 'cleanup',                           [],                             Void;
        affix $l, 'get_os_thread_id_export',           [],                             Int;
        affix $l, 'get_current_parataxis_id',          [],                             Int;
        affix $l, 'submit_c_job',                      [ Int, LongLong, Int ],         Int;
        affix $l, 'drain_jobs',                        [ Pointer [SV] ],               Void;
        affix $l, 'check_for_completion',              [],                             Int;
        affix $l, 'get_outstanding_jobs',              [],                             Int;
        affix $l, 'recall_sleep_jobs_for_fiber',       [Int],                          Int;
        affix $l, 'get_job_result',                    [Int],                          Pointer [SV];
        affix $l, 'get_job_coro_id',                   [Int],                          Int;
        affix $l, 'free_job_slot',                     [Int],                          Void;
        affix $l, 'get_thread_pool_size',              [],                             Int;
        affix $l, 'get_max_thread_pool_size',          [],                             Int;
        affix $l, 'set_max_threads',                   [Int],                          Void;
        affix $l, 'get_max_fibers',                    [],                             Int;
        affix $l, 'set_max_fibers',                    [Int],                          Void;
        affix $l, 'set_preempt_threshold',             [LongLong],                     Void;
        affix $l, [ 'maybe_yield' => '_maybe_yield' ], [],                             Pointer [SV];
        affix $l, 'get_preempt_count',                 [],                             LongLong;

        # Capture the main interpreter context
        init_system();
        if ( $^O eq 'MSWin32' ) {
            my $perl_dll = $Config{libperl};
            $perl_dll =~ s/^lib//;
            $perl_dll =~ s/\.a$//;
            $perl_dll .= '.' . $Config{so};
            my $p = Affix::load_library($perl_dll);
            affix $p, 'win32_get_osfhandle', [Int], LongLong;
        }
    }

    BEGIN {
        my $lib_name = ( $^O eq 'MSWin32' ? '' : 'lib' ) . 'parataxis.' . $Config{so};
        my @paths;
        push @paths, File::Spec->catfile( dirname(__FILE__), $lib_name );
        push @paths, File::Spec->catfile( dirname(__FILE__), '..',   'arch', 'auto',      'Acme', 'Parataxis', $lib_name );
        push @paths, File::Spec->catfile( dirname(__FILE__), '..',   '..',   'arch',      'auto', 'Acme', 'Parataxis', $lib_name );
        push @paths, File::Spec->catfile( dirname(__FILE__), 'auto', 'Acme', 'Parataxis', $lib_name );
        for my $inc (@INC) {
            next if ref $inc;
            push @paths, File::Spec->catfile( $inc, 'auto', 'Acme', 'Parataxis', $lib_name );
        }
        for my $path (@paths) {
            if ( -e $path ) {
                $lib = Affix::load_library($path);
                last if $lib;
            }
        }
        die 'Could not find or load ' . $lib_name unless $lib;
        _bind_functions($lib);
    }

    # API aliases and wrappers
    sub fiber : prototype(&) ($code) { spawn( __PACKAGE__, $code ) }
    sub async : prototype(&) ($code) { return run($code) }

    # Index at which user arguments start in @_: 0 when it is a plain call, 1 when $_[0] is a self (package name or
    # blessed object). This mirrors the shift/unshift invocant dance used elsewhere, but reads $_[0] instead of
    # shifting, so calling it never reifies the caller's pad @_. A reified @_ left behind in a parked frame trips
    # pp_entersub's assert(!AvREAL(av))/assert(AvFILLp(av) == -1) when a different fiber later enters the same sub at
    # the same depth.
    sub _arg_offset {
        my $self = $_[0];
        return ( defined $self && ( ( ref $self || $self ) eq __PACKAGE__ || ( builtin::blessed($self) && $self->isa(__PACKAGE__) ) ) ) ? 1 : 0;
    }

    sub yield {
        my $is_self = _arg_offset( $_[0] );
        my @deposit;
        push @deposit, $_[$_] for ( $is_self ? 1 : 0 ) .. $#_;
        if ( !$is_self && @deposit && !defined $deposit[0] ) {
            shift @deposit;
        }
        @_ = ();
        my $result = coro_yield( \@deposit );
        return unless defined $result;
        return ( ref $result eq 'ARRAY' ) ? ( wantarray ? @$result : $result->[-1] ) : $result;
    }

    # Park the current fiber in a blocking wait, recording why and where (for diagnostics and cancellation).
    # $level is the caller stack depth (relative to _park) of the *user* frame whose location should be attributed:
    # 1 for direct wait sites, 2 for a Semaphore down(), 3 for a Channel get()/put().
    #
    # On the *re-entry* after the yield returns, a pending interrupt (set by _interrupt) is consumed and thrown, so a
    # cancelled wait unwinds with Acme::Parataxis::Error::Cancelled (or ::Timeout) right here the caller of the wait
    # sees the parked wait's own reason in the error's wait_reason.
    #
    # $dereg, when given, is a coderef that removes the *parking* fiber from whatever waiter list it is parked on
    # (Semaphore/Signal/Future/child-await). It runs only when this park is interrupted, before the error is thrown, so
    # a cancelled fiber never leaves a stale id behind that a later wake could fire at a reused fiber.
    sub _park ( $reason, $level = 1, $dereg = undef ) {
        my $fid = Acme::Parataxis->current_fid;
        croak '_park() must be called from inside a scheduled fiber' if $fid < 0;
        my $fiber = Acme::Parataxis->by_id($fid);
        return unless $fiber;    # already finished; nothing to park

        # Fail fast: a fiber that was interrupted while it was running (not parked), then reached a wait point, throws
        # at the park entry instead of parking, so a cancellation never gets stranded until some unrelated wake. The
        # C job table may still have armed the sleep/read this wait was about to submit, so the run can stay alive
        # until those fire - but no wait is entered after its cancellation.
        if ( defined( my $pre = $fiber->[F_INTERRUPT] ) ) {
            my ( $pfile, $pline ) = ( caller($level) )[ 1, 2 ];
            my $pre_site = [ $pre, $pfile, $pline ];
            warn sprintf "PARATAXIS_TRACE t=%.0fms fid=%d ENTRY failfast pre=%s site=%s\n", ( time - $^T ) * 1000, $fid, $pre, "$pfile:$pline"
                if $ENV{PARATAXIS_TRACE};
            $fiber->[F_INTERRUPT] = undef;
            delete $PARKED{$fid};
            if ( my $dereg = delete $PARK_REGS{$fid} ) { $dereg->() }
            warn "PARATAXIS_TRACE park RE-ENTRY fail-fast fid=$fid reason=$reason pre=$pre\n" if $ENV{PARATAXIS_TRACE};
            my $err = $pre eq 'timeout' ? Acme::Parataxis::Error::Timeout->new( wait_reason => $pre_site ) :
                Acme::Parataxis::Error::Cancelled->new( wait_reason => $pre_site );
            die $err;
        }
        my ( $file, $line ) = ( caller($level) )[ 1, 2 ];
        my $site = [ $reason, $file, $line ];
        $fiber->[F_WAIT_REASON] = $site;
        $PARKED{$fid}           = 1;
        $PARK_REGS{$fid}        = $dereg if defined $dereg;
        my $res = yield('WAITING');
        if ( defined( my $kind = $fiber->[F_INTERRUPT] ) ) {
            my $wsite = $fiber->[F_WAIT_REASON] // [ 'undef', 'undef', 'undef' ];
            warn sprintf "PARATAXIS_TRACE t=%.0fms fid=%d re-entry interrupt consumed kind=%s wait_reason=%s wait_site=%s park_site=%s\n",
                ( time - $^T ) * 1000, $fid, $kind, $wsite->[0] // 'undef', $wsite->[1] . ':' . $wsite->[2],
                ( defined $site ? $site->[1] . ':' . $site->[2] : 'n/a' )
                if $ENV{PARATAXIS_TRACE};
            $fiber->[F_INTERRUPT] = undef;
            delete $PARKED{$fid};
            if ( my $dereg = delete $PARK_REGS{$fid} ) { $dereg->() }
            my $err = $kind eq 'timeout' ? Acme::Parataxis::Error::Timeout->new( wait_reason => $site ) :
                Acme::Parataxis::Error::Cancelled->new( wait_reason => $site );
            die $err;
        }
        return $res;
    }

    # Marks a fiber as interrupted and, if it is currently parked, wakes it so the interrupt is observed at the park's
    # re-entry. A fiber that is not parked keeps the marker and the first park it (re)enters afterwards throws. $kind is
    # 'cancel' or 'timeout' and selects which error the fiber throws.
    sub _interrupt ( $fid, $kind ) {
        my $fiber = Acme::Parataxis->by_id($fid);
        return unless $fiber;
        return                        if $fiber->[F_IS_DONE];
        $fiber->[F_INTERRUPT] = $kind if $kind eq 'cancel' || $kind eq 'timeout';
        recall_sleep_jobs_for_fiber($fid);
        _scheduler_enqueue_by_id($fid) if $PARKED{$fid};
        return $fiber;
    }

    # On a natural wake the park's deregistrations are dropped (the park is over); on an interrupt wake they are kept
    # for the throw in _park, which runs them before the fiber unwinds.
    sub _resume_hooks ($fiber) {
        return unless delete $PARKED{ $fiber->[F_FID] };
        $fiber->[F_WAIT_REASON] = undef;
        delete $PARK_REGS{ $fiber->[F_FID] } unless defined $fiber->[F_INTERRUPT];
        my $hooks = $fiber->[F_WAKE_HOOKS];
        $fiber->[F_WAKE_HOOKS] = undef;
        if ($hooks) { $_->($fiber) for @$hooks }
    }

    # The per-fiber stash behind Acme::Parataxis::Local, created lazily. Keyed by the fiber OBJECT (not its fid):
    # a spawned fiber that finishes inline has its fid recycled in C with no Perl-side completion hook, so a fid key
    # would survive into the recycled id and leak state into the next fiber. The object is the fiber's identity for
    # as long as it lives; entries are pruned where the object's fid is released (_mark_done, is_done) and on DESTROY.
    sub _fiber_locals ($fiber) { return $FIBER_LOCALS{ refaddr($fiber) } //= {} }

    sub on_wake {
        my $invocant = shift;
        if ( !defined $invocant ||
            ( ( ref $invocant || $invocant ) ne __PACKAGE__ && !( builtin::blessed($invocant) && $invocant->isa(__PACKAGE__) ) ) ) {
            unshift @_, $invocant if defined $invocant;
            $invocant = __PACKAGE__;
        }
        my $code = shift;
        croak 'on_wake() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        croak 'on_wake() requires a CODE ref' unless ref $code eq 'CODE';
        my $fiber = Acme::Parataxis->by_id( Acme::Parataxis->current_fid );
        push @{ $fiber->[F_WAKE_HOOKS] }, $code;
        return $code;
    }

    # Runs $code as a child fiber with a deadline of $ms milliseconds and returns its value, or throws
    # Acme::Parataxis::Error::Timeout when the deadline fires first. An optional Acme::Parataxis::CancellationToken
    # before $code cancels the block like an external deadline. A 0 or undef $ms means no deadline.
    #
    # The block runs as a child fiber in the same scheduler, so cooperative waits inside it (await_sleep, ->await,
    # ->wait, semaphore/signal/channel ops) suspend only the block's fiber. When a token fires, the child's parked wait
    # is interrupted at its park re-entry and the child unwinds (unregistering from the tokens as it goes);
    # with_timeout rethrows the resulting error (::Timeout or ::Cancelled) in this fiber, so it can be caught with
    # eval/try. The deadline timer registers on its own token, so the moment the block finishes (or is itself
    # interrupted) teardown recalls the timer's armed sleep and the worker is freed instead of staying occupied for
    # the whole bound; the timer is not armed at all when the block finishes inline (never parks) or when $ms is 0.
    sub with_timeout {
        my $o = _arg_offset( $_[0] );
        $o++ if $o == 0 && !defined $_[0];
        my $ms = $_[$o];
        croak 'with_timeout() requires a duration in milliseconds' unless defined $ms && $ms >= 0;
        my $tok;
        my $code;
        if ( ref $_[ $o + 1 ] eq 'Acme::Parataxis::CancellationToken' ) {
            $tok  = $_[ $o + 1 ];
            $code = $_[ $o + 2 ];
        }
        else {
            $code = $_[ $o + 1 ];
        }
        croak 'with_timeout() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'with_timeout() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        @_ = ();
        if ( $tok && $tok->cancelled ) {    # the user already cancelled: fail without running the block
            die Acme::Parataxis::Error::Cancelled->new;
        }
        state $have_token = do { require Acme::Parataxis::CancellationToken; 1; };
        my $deadline = Acme::Parataxis::CancellationToken->new( kind => 'timeout' );
        $tok = $deadline unless $tok;       # no explicit token: the deadline alone governs the block
        my $child = fiber {
            $deadline->register;
            $tok->register if $tok ne $deadline;
            my $val = eval { $code->() };
            my $err = $@;
            $deadline->unregister;
            $tok->unregister if $tok ne $deadline;
            die $err         if $err;                # the ::Timeout/::Cancelled throw (or any real error) unwinds out of the child
            return $val;
        };

        # The block finished synchronously: the value (or an inline error, already rethrown by spawn) is final. Skipping
        # the deadline also means a quick inlined block never pins its run.
        if ( $child->is_done ) {
            die $child->error if defined $child->error;
            return $child->result;
        }
        if ( $ms > 0 && !$tok->cancelled ) {

            # Deadline timer. Registering this fiber on the deadline token lets teardown's $deadline->cancel interrupt it
            # and recall its armed sleep job immediately (the C recall broadcasts the queue condvar), so an abandoned
            # block no longer leaves a worker sleeping out the full bound. The eval swallows the ::Timeout the interrupt
            # throws at the timer's park re-entry, so the timer completes normally and never unwinds the run.
            fiber {
                $deadline->register;
                eval { await_sleep($ms); $deadline->cancel };
            };
        }
        my $rv;
        my $ok  = eval { $rv = $child->await; 1 };
        my $err = $@;
        warn "with_timeout teardown: ok=$ok child_done=" .
            $child->is_done .
            " child_error=" .
            ( defined $child->error ? ref( $child->error || '' ) || 'plain:' . $child->error : 'undef' ) .
            " deadline_cancelled=" .
            $deadline->cancelled .
            " deadline_waiters=" .
            $deadline->waiters .
            " tok_waiters=" .
            ( $tok->waiters // 'undef' ) . " err=" .
            ( ref( $err || '' ) || 'plain:' . $err ) . "\n"
            if $ENV{PARATAXIS_TRACE};

        # The child is final, so nothing else may keep waiting under these tokens. Even if *this* fiber was just
        # cancelled out from under the await (an enclosing nursery/with_timeout interrupted us, or a user token fired):
        # cancel the deadline now so a still-registered grandchild (a nested block, our own deadline timer) is itself
        # interrupted instead of outliving its parent and running to completion. The recall now wakes the worker
        # immediately, so the abandoned sleep jobs abort in sub-millisecond time and no live work continues past its
        # parent.
        # A grandchild woken this way dies observer-gated (its parent's await had registered _wake_waiter on it), so it
        # unwinds silently rather than killing the run.
        $deadline->cancel;
        $tok->cancel if $tok ne $deadline;
        warn sprintf "with_timeout re-park branch: fid=%d child_done=%d err=%s\n", Acme::Parataxis->current_fid, $child->is_done,
            ref( $err || '' ) || 'plain:' . $err
            if $ENV{PARATAXIS_TRACE};
        if ( !$ok && !$child->is_done ) {

            # We were cancelled out of the await while the child is still parked. It is interrupted and will die on its
            # next resume. Re-park here, registered for the child's death, so the scheduler lets the child run its own
            # unwind (unregistering from its tokens and running destructors) and reaps it before this frame unwinds and
            # frees $child. The M0 fix in the C layer means freeing the child mid-park would no longer crash, so this
            # branch is no longer load-bearing for safety - it is kept so an abandoned child dies by unwinding rather
            # than being yanked. The interrupt marker on this fiber was consumed by the throwing await, so returning
            # from this park (rather than throwing again) is certain.
            my $fid = Acme::Parataxis->current_fid;
            $child->on_ready( sub { Acme::Parataxis::_scheduler_enqueue_by_id($fid) } );
            Acme::Parataxis::_park('fiber await');
            $child->is_done;    # reap the coroutine now that its death has been observed
        }
        die $err unless $ok;
        return $rv;
    }

    # Card 4 STM. atomically() runs $code as one transaction on the calling fiber: reads are
    # journaled, writes stay in a write set until the outermost atomically commits (validating
    # every read first, re-running on conflict), and retry() parks the fiber until a TVar it
    # read changes. The block may run many times - no irreversible side effects inside it.
    # See Acme::Parataxis::TVar for the semantics and the SIDE EFFECTS warning.
    sub atomically : prototype(&) {
        my $o    = _arg_offset( $_[0] );
        my $code = $_[$o];
        croak 'atomically() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'atomically() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        @_ = ();
        require Acme::Parataxis::TVar;
        return Acme::Parataxis::TVar::_atomically($code);
    }

    # Card 4 STM. Aborts the enclosing atomically block and re-runs it once a TVar the
    # transaction has read changes; croaks anywhere else.
    sub retry {
        my $o = _arg_offset( $_[0] );
        croak 'retry() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        @_ = ();
        require Acme::Parataxis::TVar;
        Acme::Parataxis::TVar::_retry();
    }

    # Structured concurrency (M4). $code runs in the calling fiber with an Acme::Parataxis::Nursery
    # as its argument; every child spawned through $n->spawn is guaranteed to finish before nursery()
    # returns, and the first child that dies cancels all of its siblings. Children never run inline
    # into the block (Nursery::spawn parks each at birth), so a child failure always surfaces through
    # the scheduler and is aggregated as Acme::Parataxis::Error::Nursery rather than thrown here.
    # If $code itself dies, its children are cancelled and drained before its error is rethrown.
    sub nursery {
        my $o = _arg_offset( $_[0] );
        $o++ if $o == 0 && !defined $_[0];
        my $code = $_[$o];
        croak 'nursery() requires a CODE ref' unless ref $code eq 'CODE';
        croak 'nursery() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
        @_ = ();
        state $have_nursery = do { require Acme::Parataxis::Nursery; 1 };
        my $nursery = Acme::Parataxis::Nursery->new;
        my $rv;
        my $ok  = eval { $rv = $code->($nursery); 1 };
        my $err = $@;

        # The block died: its children must not be orphaned, so cancel them and drain below.
        $nursery->token->cancel unless $ok;

        # All-children-join. A child failure has already cancelled the rest via the observer,
        # so the drain is fast; it unwinds every sibling before control returns to the parent.
        my @failures = $nursery->_join;
        die $err if !$ok;    # the block's own error wins over its children's
        if (@failures) {
            die Acme::Parataxis::Error::Nursery->new( failures => \@failures );
        }
        return $rv;
    }

    sub spawn {
        my $class = $_[0];
        my $code;
        if ( ref $class eq 'CODE' ) {
            $code  = $class;
            $class = __PACKAGE__;
        }
        else {
            $code = $_[1];
        }
        @_ = ();
        my $fiber = Acme::Parataxis::spawn_fiber( $code, $class );
        if ( !ref $fiber ) {
            croak defined $fiber && $fiber == -3
                ? 'could not allocate a fiber: this platform has no MAP_NORESERVE and the process has hit its address-space / data-segment budget (raise RLIMIT_DATA or lower set_max_fibers)'
                : 'could not allocate a fiber: the fiber table is full (destroy some fibers first, or raise the limit with set_max_fibers)';
        }
        my $status = $fiber->[F_LAST_STATUS];
        if ( $status == 1 ) {
            my $err = $fiber->[F_ERROR];
            die $err if defined $err;
        }
        elsif ( $status == 0 ) {
            $fiber->[F_PRIORITY] //= 0;
            _enqueue($fiber);
        }
        return $fiber;
    }

    sub _submit_job ( $type, $arg, $timeout ) {
        my $rc = submit_c_job( $type, $arg, $timeout );
        if ( $rc < 0 ) {

            # The 1024-slot job queue is full. Yield once so the scheduler can drain completed jobs, then retry.
            Acme::Parataxis->yield;
            $rc = submit_c_job( $type, $arg, $timeout );
            croak "job queue full: could not submit the job after a scheduler tick (submit_c_job returned $rc)" if $rc < 0;
        }
        return 0;
    }

    # -- event-loop driver (Card 2). When an event loop is attached (attach_loop), await_read / await_write /
    # -- await_sleep stop submitting blocking OS-thread-pool jobs per filehandle/sleep and instead register watches
    # -- and timers on the loop; run() hands control to the loop whenever every fiber is parked. The public contract
    # -- is unchanged (readiness with the pool path's result values; timeout resumes -1; an enclosing with_timeout /
    # -- nursery interrupt still throws), only the backing mechanism differs.
    sub attach_loop {
        my $o     = _arg_offset( $_[0] );
        my $thing = $_[$o];
        croak 'attach_loop() requires an event-loop object (Mojo::IOLoop, Mojo::Reactor or IO::Async::Loop)' unless defined $thing && ref $thing;
        @_ = ();
        croak 'attach_loop() cannot run while a run is already active' if $IS_RUNNING;
        require Acme::Parataxis::Driver;
        my $driver = Acme::Parataxis::Driver::wrap($thing);
        my $old    = $DRIVER;
        $DRIVER = $driver;
        return $old;
    }

    # Detach the event-loop driver, returning it and unwinding every watch/timer it still held (loops attached to a
    # shared scheduler are racy at best, so a driver session is always short: attach, run, detach).
    sub detach_loop {
        my $o = _arg_offset( $_[0] );
        @_ = ();
        croak 'detach_loop() cannot run while a run is already active' if $IS_RUNNING;
        my $old = $DRIVER;
        $old->reset if $old;
        $DRIVER = undef;
        return $old;
    }

    # The currently attached driver (undef when the pool path is in effect). Mostly for diagnostics.
    sub loop {
        my $o = _arg_offset( $_[0] );
        @_ = ();
        return $DRIVER;
    }

    sub _driver_sleep ( $driver, $ms ) {
        my $fid = Acme::Parataxis->current_fid;
        croak 'await_sleep() must be called from inside a scheduled fiber' if $fid < 0;
        my $fired = 0;
        my $id    = $driver->timer( $ms, sub { $fired = 1; Acme::Parataxis::_scheduler_enqueue_by_id($fid) } );
        my $dereg = sub { $driver->cancel_timer($id) unless $fired };
        return _park( 'await_sleep', 1, $dereg );
    }

    # Register a read/write watch on the attached loop, arm the wait's own deadline timer, and park. Natural wake
    # returns 1; the wait's own deadline swallows its ::Timeout and returns -1 like the pool path does; an *enclosing*
    # with_timeout / nursery interrupt did not cancel our deadline token, so it propagates by dying.
    #
    sub _driver_wait ( $driver, $fh, $dir, $timeout, $reason ) {
        my $fid = Acme::Parataxis->current_fid;
        croak "$reason() must be called from inside a scheduled fiber" if $fid < 0;
        my $wake = sub { Acme::Parataxis::_scheduler_enqueue_by_id($fid) };
        if ( $dir eq 'read' ) { $driver->watch_read( $fh, $wake ) }
        else                  { $driver->watch_write( $fh, $wake ) }
        my $deadline;
        my $timer_id;
        $timeout //= 5000;    # match the worker-pool default, which also maps 0/negative to 5000
        $timeout = 5000 if $timeout <= 0;

        if ( $timeout > 0 ) {
            my $have_ct = do { require Acme::Parataxis::CancellationToken; 1 };
            $deadline = Acme::Parataxis::CancellationToken->new( kind => 'timeout' ) if $have_ct;
            $deadline->register;
            $timer_id = $driver->timer( $timeout, sub { $deadline->cancel } );
        }
        my $out = 1;
        my $dying;
        my $dereg = sub {
            $driver->unwatch($fh);
            $driver->cancel_timer($timer_id) if defined $timer_id;
            $deadline->unregister            if defined $deadline;
        };
        my $ok = eval { Acme::Parataxis::_park( $reason, 1, $dereg ); 1 };
        $dereg->();    # idempotent: on an interrupt _park already ran it, on a natural wake this is the cleanup
        my $err = $@;
        if ( !$ok ) {
            if ( defined $deadline && $deadline->cancelled && ref($err) && $err->isa('Acme::Parataxis::Error::Timeout') ) {
                $out = -1;    # this wait's own deadline expired; the pool path resumes (not throws) on timeout
            }
            else { $dying = $err }
        }
        $deadline->unregister if defined $deadline;
        $deadline->cancel     if defined $deadline;
        die $dying            if defined $dying;
        return $out;
    }

    sub await_sleep {
        my $o = _arg_offset( $_[0] );
        $o++ if $o == 0 && !defined $_[0];
        my $ms = $_[$o] // 0;
        @_ = ();
        if ( $DRIVER && $ms > 0 ) {
            return _driver_sleep( $DRIVER, $ms );
        }
        _submit_job( 0, $ms, 0 );
        return _park('await_sleep');
    }

    sub await_core_id {
        @_ = ();
        _submit_job( 1, 0, 0 );
        return _park('await_core_id');
    }

    sub await_read {
        my $o = _arg_offset( $_[0] );
        $o++ if $o == 0 && !defined $_[0];
        my $fh      = $_[$o];
        my $timeout = $_[ $o + 1 ] // 5000;
        @_ = ();
        my $fileno = fileno($fh);
        die 'Not a valid filehandle' unless defined $fileno;
        if ($DRIVER) {
            return _driver_wait( $DRIVER, $fh, 'read', $timeout, 'await_read' );
        }
        my $handle = $^O eq 'MSWin32' ? win32_get_osfhandle($fileno) : $fileno;
        _submit_job( 2, $handle, $timeout );
        return _park('await_read');
    }

    sub await_write {
        my $o = _arg_offset( $_[0] );
        $o++ if $o == 0 && !defined $_[0];
        my $fh      = $_[$o];
        my $timeout = $_[ $o + 1 ] // 5000;
        @_ = ();
        my $fileno = fileno($fh);
        die 'Not a valid filehandle' unless defined $fileno;
        if ($DRIVER) {
            return _driver_wait( $DRIVER, $fh, 'write', $timeout, 'await_write' );
        }
        my $handle = $^O eq 'MSWin32' ? win32_get_osfhandle($fileno) : $fileno;
        _submit_job( 3, $handle, $timeout );
        return _park('await_write');
    }

    sub maybe_yield {
        @_ = ();
        my $result = Acme::Parataxis::_maybe_yield();
        return unless defined $result;
        return wantarray ? @$result : $result->[-1];
    }
    sub tid            { get_os_thread_id_export() }
    sub current_fid    { get_current_parataxis_id() }
    sub root           { state $root //= Acme::Parataxis::Root->new() }
    sub max_threads () { Acme::Parataxis::get_max_thread_pool_size() }
    sub max_fibers ()  { Acme::Parataxis::get_max_fibers() }

    # Scheduler internals
    sub _scheduler_enqueue_by_id ($fid) {
        return if $SCHEDULER_QUEUED{$fid};
        if ( my $fiber = Acme::Parataxis->by_id($fid) ) {
            _enqueue($fiber);
        }
    }

    sub poll_io {
        my @ready;
        while (1) {
            my $job_idx = check_for_completion();
            last if $job_idx == -1;
            my $fid = get_job_coro_id($job_idx);
            my $res = get_job_result($job_idx);
            push @ready, [ $fid, $res ];
            free_job_slot($job_idx);
        }
        return @ready;
    }

    sub _handle_run ( $fiber, $status ) {
        if ( $status == 1 ) {
            Acme::Parataxis::_mark_done($fiber);
            my $err = $fiber->[F_ERROR];

            # A scheduled fiber that dies unwinds the whole run *unless* it has an observer (an awaiting parent, an
            # on_ready callback). With an observer the error is deliberately left for the observer to rethrow at the
            # await/call site, which lets a cancelled wait surface to its own awaiter without killing the block (M1).
            die $err if defined $err && !@{ $fiber->[F_CALLBACKS] || [] };
            $fiber->[F_CALLBACKS] = [];    # one-shot, already fired by set_result/set_error; dropping the refs lets
            return 1;                      # a callback that captured the fiber (e.g. a nursery observer) cycle out
        }
        if ( $status == 0 ) {
            $fiber->[F_PRIORITY] //= 0;
            _enqueue($fiber);
        }
        return $status;
    }

    sub run ($code) {
        if ($IS_RUNNING) {

            # Nested run/async inside a shared global scheduler. Queue a fresh fiber for the block and park the current
            # fiber until it completes.
            my $fiber = __PACKAGE__->new( code => $code );
            _enqueue($fiber);
            return $fiber->await;
        }
        @SCHEDULER_QUEUE  = ();
        %SCHEDULER_QUEUED = ();
        $IS_RUNNING       = 1;

        # Snapshot the fibers that were already alive before this run. A fiber parked by a *previous* deadlocked run
        # can never be woken again, but the C table still counts it as live; the deadlock detector below must only
        # consider fibers that actually belong to this run, otherwise any run after a deadlock would be misread as
        # another deadlock. (Leaked fibers keep their C slot occupied, so their fids cannot be reused in between.)
        my %PRESET_FIBERS = map { $_ => 1 } _live_fiber_ids();
        my $main_fiber    = __PACKAGE__->new( code => $code );
        _enqueue($main_fiber);
        my $run_ok = eval {
            while ($IS_RUNNING) {
                my @ready;
                if ( get_outstanding_jobs() ) {
                    my $out = [];
                    drain_jobs($out);
                    @ready = @$out;
                }
                for my $ready (@ready) {
                    my ( $fid, $res ) = @$ready;
                    my $fiber = __PACKAGE__->by_id($fid);
                    next unless $fiber;
                    _resume_hooks($fiber);
                    my $yield_val = $fiber->call($res);
                    if ( defined $fiber && !$fiber->is_done ) {
                        _enqueue($fiber) unless defined $yield_val && $yield_val eq 'WAITING';
                    }
                }
                if (@SCHEDULER_QUEUE) {
                    my @work = @SCHEDULER_QUEUE;
                    @SCHEDULER_QUEUE  = ();
                    %SCHEDULER_QUEUED = ();
                    for my $current (@work) {
                        next unless $current;
                        _resume_hooks($current);
                        _handle_run( $current, run_fiber_checked( $current->fid, undef ) );
                    }
                }
                my $active_count = get_live_fiber_count();
                if ( $IS_RUNNING && !@SCHEDULER_QUEUE && !@ready ) {
                    if ( get_outstanding_jobs() ) {
                        $DRIVER->poll_ready() if $DRIVER;    # fire any already-live driver events, best effort
                        usleep(1000);                        # Wait for background jobs to finish
                    }
                    elsif ( $DRIVER && $DRIVER->pending ) {

                        # Every fiber is parked and the attached event loop still has live watches/timers: hand the
                        # processor to the loop. Its readiness callbacks only ever enqueue fibers (_scheduler_enqueue_by_id),
                        # never run them, so no re-entrancy into the scheduler is possible; the outer loop runs them back
                        # on the next iteration.
                        $DRIVER->drive();
                    }
                    else {
                        if ( $active_count > scalar( keys %PRESET_FIBERS ) ) {

                            # A live fiber is stuck with nothing to do and no one to wake it and no timer to fire: this
                            # run is deadlocked.  Leave the scheduler in a clean, reusable state: stop this run, clear the
                            # queues, and do NOT treat it as a nested inner run (that path requires an enclosing scheduled
                            # fiber). Preset (leaked) fibers from a previously deadlocked run are excluded from the count
                            # above so they cannot make a later healthy run look deadlocked; they stay parked forever in
                            # the C table but are harmless because the count below only ever triggers on fibers created
                            # by this run.
                            $IS_RUNNING       = 0;
                            @SCHEDULER_QUEUE  = ();
                            %SCHEDULER_QUEUED = ();
                            my $rows = _fiber_snapshot();
                            my @mine = grep { !$PRESET_FIBERS{ $_->{fid} } } @$rows;
                            my $body = '';
                            for my $r (@mine) {
                                $body .= sprintf(
                                    "  fiber #%-3d %-8s %-17s %s\n",
                                    $r->{fid}, $r->{state},
                                    $r->{reason} ? $r->{reason}[0]                               : '-',
                                    $r->{reason} ? sprintf( '%s:%d', @{ $r->{reason} }[ 1, 2 ] ) : '-'
                                );
                            }
                            $body .= "  (no live fibers from this run)\n" unless @mine;
                            my $leaked = @$rows - @mine;
                            $body .= "  ($leaked previously leaked fiber(s) from an older deadlocked run, omitted)\n" if $leaked;
                            die 'FATAL: deadlock detected: no runnable work and no outstanding jobs, but ' .
                                $active_count .
                                " live fiber(s). Parked in this run:\n" .
                                $body;
                        }
                        $IS_RUNNING = 0 if defined $main_fiber && $main_fiber->is_done;
                    }
                }
            }

            # Explicit success marker. Without it the eval yields the while loop's own last expression, which is
            # perfectly capable of being false on a *clean* exit; that made $run_failure a defined-but-empty string
            # and turned every normal run into die '' ("Died at ...").
            1;
        };
        my $run_failure = $run_ok ? undef : $@;
        $IS_RUNNING = 0;                             # always leave the scheduler reusable, even when a fiber blew up
        $DRIVER->reset   if $DRIVER;                 # unwind every watch/timer this run left on the attached loop
        die $run_failure if defined $run_failure;    # rethrow a fiber's uncaught error only after cleaning up
        return $main_fiber->[F_RESULT];
    }
    sub stop () { $IS_RUNNING = 0 }

    sub new ( $class, %args ) {
        my $self = bless [ $args{code}, 0, undef, undef, undef, 0, [], undef, undef, 0, undef, undef, undef ], $class;
        my $fid  = Acme::Parataxis::create_fiber( $args{code}, $self );
        croak $fid == -3
            ? 'could not allocate a fiber: this platform has no MAP_NORESERVE and the process has hit its address-space / data-segment budget (raise RLIMIT_DATA or lower set_max_fibers)'
            : 'could not allocate a fiber: the fiber table is full (destroy some fibers first, or raise the limit with set_max_fibers)'
            if $fid < 0;
        $self->[F_FID] = $fid;
        return $self;
    }
    sub fid   ($self) { $self->[F_FID] }
    sub code  ($self) { $self->[F_CODE] }
    sub error ($self) { $self->[F_ERROR] }

    # Higher numbers run first; ties are broken in the FIFO order they were enqueued in. The default is 0.
    sub priority {
        my $self = shift;
        my $prio = $self->[F_PRIORITY] // 0;
        return $prio unless @_;
        my $n = shift;
        $self->[F_PRIORITY] = $n;
        my $fid = $self->[F_FID];
        if ( delete $SCHEDULER_QUEUED{$fid} ) {
            @SCHEDULER_QUEUE = grep { $_->[F_FID] != $fid } @SCHEDULER_QUEUE;
            _enqueue($self);
        }
        return $n;
    }
    sub is_ready ($self) { $self->[F_IS_READY] }

    sub set_result {
        my ( $self, $val ) = @_;
        return if $self->[F_IS_READY];
        $self->[F_RESULT]   = $val;
        $self->[F_IS_READY] = 1;
        $_->($self) for @{ $self->[F_CALLBACKS] };
    }

    sub set_error ( $self, $err ) {
        return if $self->[F_IS_READY];
        $self->[F_ERROR]    = $err;
        $self->[F_IS_READY] = 1;
        $_->($self) for @{ $self->[F_CALLBACKS] };
    }

    sub _result ($self) {
        croak 'Future not ready' unless $self->[F_IS_READY];
        return $self->[F_RESULT];
    }
    sub result ($self) { return _result($self) }

    sub _clear_result ($self) {
        $self->[F_RESULT] = undef;
        $self->[F_ERROR]  = undef;
    }

    sub _mark_done ($self) {
        return if $self->[F_IS_DONE];
        $self->[F_IS_DONE] = 1;
        if ( defined $self->[F_FID] && $self->[F_FID] >= 0 ) {
            delete $PARKED{ $self->[F_FID] };
            delete $PARK_REGS{ $self->[F_FID] };
            delete $FIBER_LOCALS{ refaddr($self) };
            $self->[F_FID] = -1;
        }
    }

    sub call ( $self, @args ) {
        croak 'Cannot call a finished fiber' if $self->[F_IS_DONE];
        my $rv = Acme::Parataxis::coro_call( $self->[F_FID], \@args );
        return unless defined $self;
        if ( $self->is_done ) {
            my $err = $self->[F_ERROR];

            # Observer-gated rethrow, like _handle_run: a fiber that died while watched (an awaiting parent or an
            # on_ready callback) keeps its error for the observer to rethrow at its await/call site instead of
            # killing the run loop. This is the wake-by-job-completion path (@ready), whose deaths were the one
            # observer-gated hole left open (M4: a child that dies right after its own sleep job must not kill run()).
            die $err if defined $err && !@{ $self->[F_CALLBACKS] || [] };
        }
        return unless defined $rv;
        return ( ref $rv eq 'ARRAY' ) ? ( wantarray ? @$rv : $rv->[-1] ) : $rv;
    }

    sub transfer ( $self, @args ) {
        croak 'Cannot transfer to a finished fiber' if $self->is_done;
        my $rv = Acme::Parataxis::coro_transfer( $self->[F_FID], \@args );
        if ( $self->is_done ) {
            my $err = $self->[F_ERROR];
            die $err if defined $err;
        }
        return unless defined $rv;
        return ( ref $rv eq 'ARRAY' ) ? ( wantarray ? @$rv : $rv->[-1] ) : $rv;
    }

    sub is_done ($self) {
        if ( $self->[F_IS_DONE] ) {
            delete $FIBER_LOCALS{ refaddr($self) };
            return 1;
        }
        if ( defined $self->[F_FID] && $self->[F_FID] >= 0 && Acme::Parataxis::is_finished( $self->[F_FID] ) ) {
            $self->[F_IS_DONE] = 1;
            my $old_fid = $self->[F_FID];
            delete $PARKED{$old_fid};
            delete $PARK_REGS{$old_fid};
            delete $FIBER_LOCALS{ refaddr($self) };
            $self->[F_FID] = -1;
            Acme::Parataxis::destroy_coro($old_fid);
            return 1;
        }
        return 0;
    }
    sub wait_reason ($self) { $self->[F_WAIT_REASON] }    # [reason, file, line] while parked, undef otherwise

    sub wait ($self) {
        if ( !$self->is_done && Acme::Parataxis->current_fid < 0 ) {
            croak 'wait() must be called from inside the scheduler, or the fiber must already be done';
        }
        my $fid    = Acme::Parataxis->current_fid;
        my $waiter = $fid >= 0 ? Acme::Parataxis->by_id($fid) : undef;    # the fiber doing the busy-wait
        $waiter->[F_WAIT_REASON] = [ 'fiber wait', (caller)[ 1, 2 ] ] if $waiter;
        Acme::Parataxis->yield('WAITING_FOR_CHILD') until $self->is_done;
        $waiter->[F_WAIT_REASON] = undef if $waiter;
        return _result($self);
    }

    sub on_ready ( $self, $cb ) {
        if   ( $self->[F_IS_READY] ) { $cb->($self) }
        else                         { push @{ $self->[F_CALLBACKS] }, $cb }
    }

    sub await ($target) {

        # await() is exported as a plain function; await($fut) must delegate to the await-capable receiver's own
        # method (e.g. Future), while fiber objects (which ARE Acme::Parataxis) keep the arrayref-slot path.
        # The signature keeps @_ unreified here: await() parks and is resumed on this same pad.
        if ( builtin::blessed($target) && $target->can('await') && !$target->isa(__PACKAGE__) ) {
            return $target->await;
        }
        my $self  = $target;
        my $ready = $self->[F_IS_READY];
        if ( !$ready ) {
            croak 'await() must be called from inside a scheduled fiber' if Acme::Parataxis->current_fid < 0;
            my $fid = Acme::Parataxis->current_fid;
            $self->[F_WAITER] = $fid;
            $self->on_ready( \&_wake_waiter );
            _park( 'fiber await', 1, sub { $self->[F_WAITER] = undef if defined $self->[F_WAITER] && $self->[F_WAITER] == $fid } );
            $ready = $self->[F_IS_READY];
        }
        croak 'Future not ready' unless $ready;
        delete $FIBER_LOCALS{ refaddr($self) };    # the fiber is done now; its locals die with it (no-op for Futures)
        die $self->[F_ERROR] if defined $self->[F_ERROR];
        $self->[F_RESULT];
    }

    sub _wake_waiter ($self) {
        return unless defined $self->[F_WAITER];
        Acme::Parataxis::_scheduler_enqueue_by_id( $self->[F_WAITER] );
        $self->[F_WAITER] = undef;
    }

    sub DESTROY($self) {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        delete $FIBER_LOCALS{ refaddr($self) };
        if ( defined $self->[F_FID] && $self->[F_FID] >= 0 ) {
            delete $PARKED{ $self->[F_FID] };
            delete $PARK_REGS{ $self->[F_FID] };
            Acme::Parataxis::destroy_coro( $self->[F_FID] );
            $self->[F_FID] = -1;
        }
    }
    sub by_id ( $class, $fid ) { Acme::Parataxis::get_fiber_by_id($fid) }

    sub _dispatch_callbacks ($self) {
        $_->($self) for @{ $self->[F_CALLBACKS] };
    }
    class    #
        Acme::Parataxis::Root {
        field $fid : reader = -1;    # For now

        method transfer (@args) {
            my $rv = Acme::Parataxis::coro_transfer( -1, \@args );
            return unless defined $rv;
            return ( ref $rv eq 'ARRAY' ) ? ( wantarray ? @$rv : $rv->[-1] ) : $rv;
        }
    }
    END { cleanup() unless ${^GLOBAL_PHASE} eq 'DESTRUCT' }
}
1;
