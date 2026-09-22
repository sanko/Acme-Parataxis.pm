use v5.40;
no warnings 'experimental::class', 'recursion';
use feature 'class';
class Acme::Parataxis::Driver v0.1.1 {
    use Carp qw[croak];
    use Scalar::Util qw[blessed];

    # Base class for the event-loop drivers behind Acme::Parataxis->attach_loop(). A driver wraps an existing CPAN
    # event loop (Mojo::IOLoop, IO::Async::Loop, ...) so that await_read / await_write / await_sleep are serviced by
    # epoll/kqueue/select readiness instead of burning an OS-thread pool job per filehandle. The scheduler keeps its
    # own park/wake machinery; the driver only *tells* the loop which filehandles to watch and hands control to the
    # loop when every fiber is parked.
    #
    # Subclasses implement the loop-specific bit (watch_read/watch_write/unwatch/timer/cancel_timer/drive/poll_ready);
    # this base owns the bookkeeping -- which watches and timers are still live -- that the scheduler uses to decide
    # whether the loop still needs control (pending) and to tear the whole thing down between runs (reset).
    field %watches;    # fileno => the filehandle being watched (one *multi-direction* slot per filehandle)
    field %timers;     # opaque timer id => 1, ids handed back by the subclass constructor

    # True while this driver still has registered watches or timers. The scheduler's idle branch hands control to the
    # loop only when this is true; with nothing pending a run would otherwise block forever in the loop instead of
    # deadlock-detecting.
    method pending {
        return scalar( keys %watches ) + scalar( keys %timers );
    }

    # Unwind every watch and timer this driver registered. Called by run() on teardown and by detach_loop(), so a
    # stale listener socket or deadline timer from an exited run can never leave the next run blocked in the loop.
    method reset {
        my @fhs = values %watches;
        $self->unwatch($_) for @fhs;
        my @ids = keys %timers;
        $self->cancel_timer($_) for @ids;
        return 1;
    }

    # -- shared bookkeeping helpers. Subclasses call these when they (de)register with the underlying loop. --
    method _track_watch ($fh) {
        my $fd = fileno($fh);
        $watches{$fd} = $fh;
        return $fd;
    }

    method _untrack_watch ($fh) {
        my $fd = fileno($fh);
        return 0 unless defined $fd && exists $watches{$fd};
        delete $watches{$fd};
        return 1;
    }

    method _track_timer ($id) {
        $timers{$id} = 1;
        return $id;
    }

    method _untrack_timer ($id) {
        return 0 unless exists $timers{$id};
        delete $timers{$id};
        return 1;
    }

    # True when $fh already has a live watch slot in this driver (both directions share one slot per filehandle).
    method has_watch ($fh) {
        my $fd = fileno($fh);
        return defined $fd && exists $watches{$fd} ? 1 : 0;
    }
    method watch_count () { return scalar( keys %watches ) }
    method timer_count () { return scalar( keys %timers ) }

    # -- required subclass interface --
    # watch_read($fh, $cb)                -- call $cb->() when $fh becomes readable
    # watch_write($fh, $cb)               -- call $cb->() when $fh becomes writable
    # unwatch($fh)                        -- stop watching $fh (both directions), 0 if nothing was watched
    # timer($ms, $cb)                     -- call $cb->() after $ms millseconds; returns an opaque id
    # cancel_timer($id)                   -- cancel a pending timer, 0 if unknown/already fired
    # drive()                             -- run the loop until at least one event fires (may block)
    # poll_ready()                        -- run the loop's readiness pass without blocking (best effort)
};

# Wrap (or pass through) an event-loop object as a Driver. attach_loop() routes everything through here, so callers
# may hand in a Mojo::IOLoop (or Mojo::Reactor) or an IO::Async::Loop and get the right reference driver for free.
# A plain package sub (perlclass only allows instance method dispatch); Acme::Parataxis::Driver::wrap($loop).
sub Acme::Parataxis::Driver::wrap ($loop) {
    Carp::croak 'wrap() requires an event-loop object' unless Scalar::Util::blessed($loop);
    return $loop if $loop->isa('Acme::Parataxis::Driver');
    my $pkg = ref $loop;
    if ( $pkg =~ /^Mojo::/ || $loop->isa('Mojo::IOLoop') || $loop->isa('Mojo::Reactor') ) {
        require Acme::Parataxis::Driver::Mojo;
        return Acme::Parataxis::Driver::Mojo->new( loop => $loop );
    }
    if ( $pkg =~ /^IO::Async::/ ) {
        require Acme::Parataxis::Driver::IOAsync;
        return Acme::Parataxis::Driver::IOAsync->new( loop => $loop );
    }
    Carp::croak "wrap() does not know how to drive a $pkg event loop";
}
1;
