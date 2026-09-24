use v5.40;

package Acme::Parataxis::Monitor v0.1.1 {
    our @ISA = ();
    use Acme::Parataxis;
    use Acme::Parataxis::Future;
    use Carp         qw[croak];
    use Scalar::Util qw[blessed weaken];

    # A monitor is pure observation, like an Erlang monitor: it resolves exactly once, when the
    # target fiber exits, to undef for a clean end or to the fiber's death error for a crash. It
    # rides the target's existing on_ready/on_death slot, so it needs no scheduler change and
    # never owns the target (no stop, no join-without-error semantics). Watching an already-dead
    # target fires immediately, because the underlying Future resolves inline during ->new.
    #
    # The target is held strongly so a monitor never loses its subject; reapability is about the
    # C coroutine slot (driven by the fiber's own completion), which the monitor cannot delay.
    # The reverse edge is cut: the completion callback captures the monitor weakly, so dropping
    # a monitor lets it (and its strong target ref) dissolve instead of lingering in the target's
    # callback list.
    sub new ( $class, @args ) {
        my ( $target, $fid );
        if ( @args == 1 ) {
            my $arg = $args[0];
            if    ( ref $arg )                          { $target = $arg }
            elsif ( defined $arg && $arg =~ /^-?\d+$/ ) { $fid = $arg }
            else                                        { croak 'Monitor->new() expects a fiber object or a numeric fiber id' }
        }
        else {
            my %spec    = @args;
            my @unknown = grep { $_ ne 'target' && $_ ne 'fid' } keys %spec;
            croak 'Monitor->new() got unknown arguments: ' . join ', ', @unknown if @unknown;
            $target = $spec{target};
            $fid    = $spec{fid};
        }
        croak 'Monitor->new() takes a target or a fid, not both' if defined $target && defined $fid;
        if ( defined $fid ) {
            croak "Monitor->new() expects a numeric fiber id (got '$fid')" unless $fid =~ /^-?\d+$/;
            $target = Acme::Parataxis->by_id( 0 + $fid );
            croak "Monitor->new() couldn't find a fiber with id $fid" unless defined $target;
        }
        croak 'Monitor->new() requires a target to watch'                          unless defined $target;
        croak 'Monitor->new() requires a blessed target (fibers, futures, actors)' unless blessed $target;
        if ( !$target->can('on_ready') && !$target->can('on_death') ) {
            croak 'Monitor->new() cannot watch this target: it has neither on_ready() (fibers, futures) nor on_death() (actors)';
        }
        my $self = bless { target => $target, fid => $target->can('fid') ? $target->fid : $fid, future => Acme::Parataxis::Future->new, }, $class;
        my $weak = $self;
        weaken $weak;
        if ( $target->can('on_ready') ) {
            $target->on_ready( sub { $weak->_resolve( $weak->{target}->error ) if $weak } );
        }
        else {
            $target->on_death( sub { $weak->_resolve( $_[1] ) if $weak } );
        }
        return $self;
    }

    # Resolve exactly once. $err is the target's death error, or undef for a clean end; it becomes
    # the monitor's *result* (never set_error), so ->await/->result return it instead of throwing.
    sub _resolve ( $self, $err ) {
        return $self if $self->{future}->is_ready;
        $self->{future}->set_result($err);
        return $self;
    }
    sub await    ($self) { $self->{future}->await }                                         # parks until the target exits
    sub result   ($self) { $self->{future}->result }                                        # the resolution value; croaks until ready
    sub error    ($self) { $self->{future}->is_ready ? $self->{future}->result : undef }    # death error (or undef), ready or not
    sub is_ready ($self) { $self->{future}->is_ready }
    sub is_done  ($self) { $self->{future}->is_ready }                                      # resolved == done, mirroring the fiber-side naming
    sub target   ($self) { $self->{target} }                                                # the watched fiber/future/actor object
    sub fid      ($self) { $self->{fid} }    # the target's fiber id at watch time (undef for non-fiber targets)

    sub on_ready ( $self, $cb ) {
        croak 'on_ready() requires a CODE ref' unless ref $cb eq 'CODE';
        my $weak = $self;
        weaken $weak;
        $self->{future}->on_ready( sub { $cb->($weak) if $weak } );    # hand the caller the monitor, not the inner future
        return $self;
    }
}
#
1;
