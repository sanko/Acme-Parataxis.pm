use v5.40;
use feature 'class';
no warnings 'experimental::class', 'recursion';
use Carp;
use Acme::Parataxis qw[fiber await_sleep];
class Acme::Parataxis::Channel v0.1.0 {
    use Acme::Parataxis qw[fiber await_sleep];
    use Acme::Parataxis::CancellationToken;
    use Acme::Parataxis::Semaphore;
    use Carp qw[croak];
    field $capacity : param //= 2_000_000_000;
    field $sem_get = Acme::Parataxis::Semaphore->new( count => 0 );
    field $sem_put = Acme::Parataxis::Semaphore->new( count => $capacity );
    field @data : reader;
    field @select_waiters;    # [fid, op] pairs parked here by select(); op is 'get' or 'put'
    ADJUST {
        $capacity >= 1 or die "Channel capacity must be >= 1 (got $capacity)\n";
    }

    method put ($value) {
        $sem_put->down( 'Channel put', 3 );
        push @data, $value;
        $sem_get->up;
        $self->_wake_select_waiters('get');
        1;
    }

    method put_priority ($value) {
        push @data, $value;
        $sem_get->up;
        $self->_wake_select_waiters('get');
        1;
    }

    method try_put ($value) {
        return 0 unless $sem_put->try;
        push @data, $value;
        $sem_get->up;
        $self->_wake_select_waiters('get');
        return 1;
    }

    method get () {
        $sem_get->down( 'Channel get', 3 );
        $sem_put->up;
        my $v = shift @data;
        $self->_wake_select_waiters('put');
        return $v;
    }

    method try_get () {
        return ( 0, undef ) unless $sem_get->try;
        $sem_put->up;
        my $v = shift @data;
        $self->_wake_select_waiters('put');
        return ( 1, $v );
    }
    method size () { scalar @data }

    method shutdown () {
        $sem_get->adjust(1_000_000_000);
        $self->_wake_select_waiters('get');
        1;
    }

    method adjust ($diff) {
        $sem_put->adjust($diff);
        $self->_wake_select_waiters('put');
        1;
    }
    method select_waiters () { scalar @select_waiters }    # introspection: how many fibers are parked in select() here

    method remove_waiter ($fid) {    # Unregisters the fiber from any internal wait queue; returns the number of entries removed.
        $sem_get->remove_waiter($fid) + $sem_put->remove_waiter($fid) + $self->_unregister_select_waiter($fid);
    }
    method _register_select_waiter ( $fid, $op ) { push @select_waiters, [ $fid, $op ]; return $fid; }

    method _unregister_select_waiter ($fid) {
        my $before = @select_waiters;
        @select_waiters = grep { $_->[0] != $fid } @select_waiters;
        return $before - @select_waiters;
    }

    method _wake_select_waiters ($op) {    # Wakes the select waiters waiting for $op, dropping stale fids
        return unless @select_waiters;
        my @still;
        for my $ent (@select_waiters) {
            my ( $fid, $want ) = @$ent;
            next if !defined Acme::Parataxis->by_id($fid);    # stale: dropped, not retained for the next wake
            if   ( $want eq $op ) { Acme::Parataxis::_scheduler_enqueue_by_id($fid) }
            else                  { push @still, $ent }
        }
        @select_waiters = @still;
        return;
    }
};

# CSP select: wait on the first ready case and return its (channel, value). A plain package sub (perlclass only
# allows instance invocations), called as Acme::Parataxis::Channel->select(...). Two probe/register phases as
# designed in TODO/Milestone 5 -- probe without yielding first, fall back to registering on every involved
# channel's private @select_waiters, arming the shared deadline *after* registration, then parking.
sub Acme::Parataxis::Channel::select ( $class, @args ) {
    my ( $timeout, $default );
    my @cases;
    while (@args) {
        my $arg = shift @args;
        if ( ref $arg eq 'ARRAY' && @$arg >= 2 ) {
            my ( $ch, $op, @rest ) = @$arg;
            Carp::croak 'select() case channel must be an Acme::Parataxis::Channel' unless ref($ch) && $ch->isa('Acme::Parataxis::Channel');
            Carp::croak 'select() case op must be "get" or "put"'                   unless $op eq 'get' || $op eq 'put';
            Carp::croak 'select() "put" case requires a value' if $op eq 'put' && @$arg < 3;
            push @cases, [ $ch, $op, $rest[0] ];
        }
        elsif ( $arg eq 'timeout' ) {
            $timeout = shift @args;
            Carp::croak 'select() timeout must be a non-negative number of milliseconds' unless defined $timeout && $timeout >= 0;
        }
        elsif ( $arg eq 'default' ) {
            $default = shift @args;
            Carp::croak 'select() default must be a CODE ref' unless ref $default eq 'CODE';
        }
        else {
            Carp::croak 'select() arguments must be [ $channel, "get" | "put", $value? ] cases, with timeout/default options';
        }
    }
    Carp::croak 'select() needs at least one case' unless @cases;
    my $fid = Acme::Parataxis->current_fid;
    Carp::croak 'select() must be called from inside a scheduled fiber' if $fid < 0;

    # The timeout deadline is armed once on the first park and reused across re-parks, so a spurious wake can
    # never stack timers. "Register, then arm" (token.register before the sleep job) closes the lost-wakeup
    # window an await_sleep-only timeout would leave between the probe step and registration.
    my $deadline;
    my $timer_armed;
    my ( $out_ch, $out_val, $out_die ) = ( undef, undef, undef );
OUTER: while (1) {

        # Phase 1 -- probe, no yield: shuffle so no ordering starves a case, commit the first match, and let
        # default run only when nothing is ready (it never parks).
        my @order = 0 .. $#cases;
        for ( my $i = $#order; $i > 0; $i-- ) {
            my $j = int rand( $i + 1 );
            @order[ $i, $j ] = @order[ $j, $i ];
        }
        for my $i (@order) {
            my ( $ch, $op, $v ) = @{ $cases[$i] };
            if ( $op eq 'get' ) {
                my ( $ok, $got ) = $ch->try_get;
                if ($ok) { ( $out_ch, $out_val ) = ( $ch, $got ); last OUTER; }
            }
            else {
                if ( $ch->try_put($v) ) { ( $out_ch, $out_val ) = ( $ch, $v ); last OUTER; }
            }
        }
        if ( defined $default ) { ( $out_ch, $out_val ) = ( undef, $default->() ); last OUTER; }

        # Phase 2 -- register on every involved channel, arm the shared deadline, then park. On wake the
        # park's deregistrations were already dropped (_resume_hooks) or the per-channel wake skipped the
        # fiber, so re-probe exactly once and fall back to re-registering; the one-shot re-poll per wake is
        # natural here because registering happens before the next park.
        for my $case (@cases) { $case->[0]->_register_select_waiter( $fid, $case->[1] ); }
        if ( defined $timeout && $timeout > 0 ) {
            $deadline //= Acme::Parataxis::CancellationToken->new( kind => 'timeout' );
            $deadline->register;
            unless ($timer_armed) {
                my $ms = $timeout;

                # The timer registers on the shared deadline and swallows its own interrupt, so teardown can
                # recall it when a case commits first instead of leaving a worker parked for the full $ms.
                Acme::Parataxis::fiber {
                    $deadline->register;
                    eval { Acme::Parataxis::await_sleep($ms); $deadline->cancel; 1 };
                };
                $timer_armed = 1;
            }
        }
        my $dereg = sub {
            for my $case (@cases) { $case->[0]->_unregister_select_waiter($fid) }
            $deadline->unregister if defined $deadline;
        };
        my $ok = eval { Acme::Parataxis::_park( 'Channel select', 1, $dereg ); 1 };
        $dereg->();    # idempotent: on interrupt _park already ran it; on a natural wake this is the cleanup
        my $err = $@;
        if ( !$ok ) {

            # Our own deadline fired -> the API is (undef, undef) on timeout. A timeout sent by an *enclosing*
            # with_timeout/nursery did not cancel our token, so it propagates instead of being swallowed.
            if ( defined $deadline && $deadline->cancelled && ref($err) && $err->isa('Acme::Parataxis::Error::Timeout') ) {
                ( $out_ch, $out_val ) = ( undef, undef );
                last OUTER;
            }
            $out_die = $err;
            last OUTER;
        }
    }

    # Every exit funnels through here so the armed timeout helper is never orphaned: drop the select fiber off
    # the token first (a running fiber must not receive its own interrupt), then cancel to recall the timer's
    # sleep job. A deadline that already fired makes both steps no-ops.
    $deadline->unregister if defined $deadline;
    $deadline->cancel     if defined $deadline;
    die $out_die          if defined $out_die;
    return ( $out_ch, $out_val );
}
#
1;
