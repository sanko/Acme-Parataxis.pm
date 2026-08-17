use v5.40;
no warnings 'experimental::class';
use feature 'class';

class Acme::Parataxis::Future {
    use Carp qw[croak];
    field $is_ready : reader = 0;
    field $result;
    field $error;
    field @callbacks;
    field $waiter;

    method result () {    # Returns the task result immediately. Croaks if the future is not yet ready.
        croak 'Future not ready' unless $is_ready;
        return $result;
    }

    method set_result ($val) {
        die 'Future already ready' if $is_ready;
        $result   = $val;
        $is_ready = 1;
        $_->($self) for @callbacks;
    }

    method set_error ($err) {
        die 'Future already ready' if $is_ready;
        $error    = $err;
        $is_ready = 1;
        $_->($self) for @callbacks;
    }

    method clear_result () {
        $result = undef;
        $error  = undef;
    }

    method on_ready ($cb) {
        if   ($is_ready) { $cb->($self) }
        else             { push @callbacks, $cb }
    }

    method await () {

        # Suspends the current fiber until the future is ready. Returns the result or dies if the task encountered an error
        return $self->result if $is_ready;
        $waiter = Acme::Parataxis->current_fid;
        $self->on_ready( \&_wake_waiter );
        Acme::Parataxis->yield('WAITING');
        $self->result;
    }

    method _wake_waiter () {
        return unless defined $waiter;
        Acme::Parataxis::_scheduler_enqueue_by_id($waiter);
        $waiter = undef;
    }
};
1;
