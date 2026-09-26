use v5.40;
use blib;
use Acme::Parataxis qw[async await_read await_sleep];
use IO::Socket::INET;

# Diagnostic, not a test: deliberately outside MANIFEST and not named t/*.t.
#
# Isolates the NetBSD SIGABRT that ends t/047_driver_mojo.t and t/048_driver_ioasync.t. Both of those run every
# assertion to green and then abort with Wstat 134 during process teardown, so the question is not whether the
# scheduler works but what is still alive when the process tries to leave. Each phase below is a strict superset of
# the one before it, so the smallest phase that reproduces the abort is the answer, and the last MARK line printed
# before the process dies says how far it got. Output is flushed per line because a hard abort prints nothing itself.
#
# Both loops are built the way t/047 and t/048 build theirs (`Mojo::IOLoop->new`, `IO::Async::Loop->new`) so the
# object graph under test is theirs and not a convenient approximation.
#
#   usage: perl -Mblib diagnostics/driver-teardown-probe.pl <phase> <mojo|ioasync>
#
#     attach       attach a loop and exit, never running the scheduler
#     run          run the scheduler with NO loop attached (the path the other 66 tests take)
#     attach_run   attach, run a fiber that only sleeps, exit with the driver still attached
#     detach_run   as attach_run, but detach_loop before exit
#     read         as attach_run, but the fiber waits on a real socket read
#
# The abort is intermittent - t/047 passed on one CI run and aborted on the next with byte-identical code - so a
# single clean run proves nothing and the caller is expected to repeat each phase.
#
# Exit status is the interesting part: 0 means the process left cleanly, anything else is a reproduction. That is
# the whole contract; the markers are only there to say how far it got.

my ( $phase, $which ) = @ARGV;
$| = 1;

sub marker { print "MARK $phase/$which: $_[0]\n" }

sub socket_pair {
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 8,
        ReuseAddr => 1,
    ) or die "listen: $!";
    my $client = IO::Socket::INET->new( PeerAddr => '127.0.0.1:' . $server->sockport ) or die "connect: $!";
    my $conn   = $server->accept or die "accept: $!";
    return ( $client, $conn );
}

marker('start');

my $loop
    = $which eq 'mojo'
    ? do { require Mojo::IOLoop; Mojo::IOLoop->new }
    : do { require IO::Async::Loop; IO::Async::Loop->new };
marker('loop built');

# The control phase. If this one ever aborts, the driver is irrelevant and the problem is the worker pool's own
# teardown, which 66 other tests exercise without incident - so it is here to catch that misdiagnosis.
if ( $phase eq 'run' ) {
    marker('running with no driver attached at all');
    Acme::Parataxis::run( sub { async { await_sleep(1) } } );
    marker('ran; exiting');
    exit 0;
}

marker('attaching');
Acme::Parataxis->attach_loop($loop);
marker('attached');

# The narrowest possible reproduction: a driver object exists and is reachable, and the process leaves.
if ( $phase eq 'attach' ) {
    marker('exiting with the driver still attached, scheduler never run');
    exit 0;
}

my $body = sub { async { await_sleep(1) } };
if ( $phase eq 'read' ) {
    my ( $client, $server ) = socket_pair();
    $body = sub { async { await_read( $server, 5000 ) } };
}

marker('running with the driver attached');
Acme::Parataxis::run($body);
marker('ran');

# attach_run leaves $DRIVER populated on purpose: Parataxis.pm unwinds the driver's watches at the end of a run
# but does not clear the reference, so the last reference to the loop is dropped during global destruction. If this
# phase aborts and detach_run does not, that ordering is the thing to look at.
if ( $phase eq 'detach_run' ) {
    marker('detaching');
    Acme::Parataxis->detach_loop;
    marker('detached');
}

marker('exiting normally');
exit 0;
