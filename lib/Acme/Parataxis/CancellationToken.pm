use v5.40;
no warnings 'experimental::class', 'recursion';
use feature 'class';
#
class Acme::Parataxis::CancellationToken v0.1.0 {
    use Acme::Parataxis;
    use Carp qw[croak];

    # $kind selects which error an interrupted waiter throws. Public tokens use 'cancel'; with_timeout's internal
    # deadline token uses 'timeout' so the same mechanism raises Timeout instead of Cancelled.
    field $cancelled : reader : param = false;
    field $kind : param = 'cancel';

    # Fiber ids currently parked under this token, in registration order. cancel() wakes them; unregister()/the
    # on_wake( { ... } ) cleanup removes them when their wait finishes normally.
    field @registered;

    method register () {
        my $fid = Acme::Parataxis->current_fid;
        croak 'register() must be called from inside a scheduled fiber' if $fid < 0;
        if ($cancelled) {    # too late to wait in vain: the next parked wait throws immediately on its wake
            Acme::Parataxis::_interrupt( $fid, $kind );
            return $fid;
        }
        push @registered, $fid if !grep { $_ == $fid } @registered;
        return $fid;
    }

    method unregister () {    # Remove the current fiber from the token. Safe to call any number of times.
        my $fid = Acme::Parataxis->current_fid;
        @registered = grep { $_ != $fid } @registered;
        return $fid;
    }

    method cancel () {        # Idempotent: flips the flag, wakes every registered (parked) fiber with an interrupt.
        return if $cancelled;
        $cancelled = true;
        my @fids = @registered;
        @registered = ();
        Acme::Parataxis::_interrupt( $_, $kind ) for @fids;
        return true;
    }
    method waiters () { return scalar @registered }
    }
    #
    1;
