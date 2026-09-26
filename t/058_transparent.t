use v5.40;
use blib;
use Test2::V1 -ipP;
use Time::HiRes      qw[time];
use File::Temp       ();
use Fcntl            qw[F_GETFL F_SETFL O_NONBLOCK];
use IO::Socket::INET ();
use Acme::Parataxis  qw[async fiber await_sleep with_timeout];

# Transparent unblocking is opt-in, per-process, compile-time. The overrides affect only code compiled AFTER
# enable_transparent_unblocking ran, so they are installed here in BEGIN, before the test bodies below are compiled.
# Everything at the top level (current_fid < 0) must delegate to the raw CORE:: builtins, and every call from inside a
# scheduled fiber frames on the scheduler's await_sleep/await_read so no OS thread is parked. Nothing is monkey-patched
# on other threads: a fresh interpreter starts with unmodified builtins.
BEGIN { Acme::Parataxis->enable_transparent_unblocking }
$|++;
#
sub socket_pair {
    my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1 ) or die "listen: $!";
    my $client = IO::Socket::INET->new( PeerAddr  => '127.0.0.1:' . $server->sockport )                         or die "connect: $!";
    my $conn   = $server->accept or die "accept: $!";
    return ( $client, $conn );
}
#
subtest 'opt-in install is explicit and reports' => sub {
    is Acme::Parataxis->enable_transparent_unblocking(),  1, 'installing reports success';
    is Acme::Parataxis->enable_transparent_unblocking(),  1, 'second install is idempotent, not an error';
    is Acme::Parataxis->transparent_unblocking(),         1, 'transparent_unblocking() reflects the install';
    is Acme::Parataxis->current_fid,                     -1, 'top level is outside the scheduler (fid -1)';
};
subtest 'top-level sleep keeps raw CORE::sleep semantics' => sub {
    my $t0 = time;
    my $rc = sleep 0.05;
    my $ms = ( time - $t0 ) * 1000;
    ok $rc == int $rc, 'fractional seconds truncate to whole seconds, exactly like CORE::sleep';
    ok $ms < 5000,     "it returned promptly ($ms ms), never parking an OS thread";
};
subtest 'sleep inside a fiber is cooperative and yields' => sub {
    my ( @slow, $prog );
    async {
        my $t0    = time;
        my $slow  = fiber { push @slow, [ sleep(0.05), time - $t0 ] };
        my $ticks = fiber { await_sleep(1); my $p = 0; $prog += ++$p for 1 .. 40; 1 };
        $slow->await;
        $ticks->await;
    };
    ok $slow[0][0] > 0.04 && $slow[0][0] < 0.5, 'the sleep returned the requested seconds, not a truncated zero';
    ok $slow[0][1] >= 0.045,                    'the fiber actually waited ~50ms';
    ok $prog > 0,                               'a sibling fiber made progress while the sleeper was parked';
};
subtest 'the $_ default and fractional precision reach the scheduler' => sub {
    my ( $rc, $el );
    $_ = 0.04;
    async {
        my $t0 = time;
        $rc = sleep;        # implicit $_
        $el = time - $t0;
    };
    ok $rc > 0.03 && $rc < 0.5, 'sleep() with no argument used $_ (returned the requested duration)';
    ok $el >= 0.03,             "it actually waited ($el s)";
};
subtest 'top-level read/sysread still fill the caller buffer' => sub {
    for my $builtin (qw[read sysread]) {
        my ( $a, $b ) = socket_pair();
        syswrite $a, $builtin eq 'read' ? 'hihi' : 'yo!';
        my ( $buf, $rc );
        if ( $builtin eq 'read' ) { $rc = read( $b, $buf, 4 ) }
        else                      { $rc = sysread( $b, $buf, 3 ) }
        is $rc,  4, "$builtin at the top level returned the byte count" if $builtin eq 'read';
        is $rc,  3, "$builtin at the top level returned the byte count" if $builtin eq 'sysread';
        is $buf, $builtin eq 'read' ? 'hihi' : 'yo!', "$builtin at the top level filled the caller buffer";
    }
};
subtest 'read/sysread inside a fiber frame until the peer writes' => sub {
    for my $builtin (qw[read sysread]) {
        my ( $a, $b ) = socket_pair();
        my ( $buf, $rc );
        my $t0 = time;
        async {
            my $reader = fiber {
                if ( $builtin eq 'read' ) { $rc = read( $a, $buf, 7 ) }
                else                      { $rc = sysread( $a, $buf, 7 ) }
            };
            my $writer = fiber { await_sleep(30); syswrite $b, 'framed!' };
            $reader->await;
            $writer->await;
        };
        my $ms = ( time - $t0 ) * 1000;
        is $rc,  7,         "$builtin framed the payload written after the read parked";
        is $buf, 'framed!', "$builtin wrote the result back into the caller buffer";
        ok $ms < 4000, "the $builtin returned promptly ($ms ms) once the peer wrote";
    }
};
subtest 'a read asked for more than the peer sends returns the short count' => sub {
    # Every socket case above asks for exactly the number of bytes the peer sends, which is the one shape a blocking
    # read cannot get wrong. Ask for one more than arrives and the old override froze the entire run: await_read only
    # promises that *something* is readable, but a raw read on a blocking stream handle waits for the whole requested
    # count, so the fiber sat in a syscall where no deadline, no token and no sibling could reach it.
    for my $builtin (qw[read sysread]) {
        my ( $a, $b ) = socket_pair();
        syswrite $b, 'hello';    # five bytes down the wire to $a, then silence
        my ( $buf, $rc, $ticked );
        my $t0 = time;
        async {
            # The deadline below does NOT rescue this one if the override regresses: a fiber wedged in the read
            # syscall cannot be interrupted, because the timer fiber that would raise the deadline never gets
            # scheduled. It is here to catch a *spin* regression, which a deadline can stop. A return to plain
            # blocking reads stalls the run outright, so that failure mode is a stall to be read, not a red test.
            with_timeout(
                5000,
                sub {
                    my $ticks = fiber { await_sleep(30); $ticked = 1; 1 };
                    if ( $builtin eq 'read' ) { $rc = read( $a, $buf, 10 ) }
                    else                      { $rc = sysread( $a, $buf, 10 ) }
                    $ticks->await;
                }
            );
        };
        my $ms = ( time - $t0 ) * 1000;
        is $rc,  5,       "$builtin asked for 10, got 5, and returned the short count instead of waiting";
        is $buf, 'hello', "$builtin filled the caller buffer with the bytes that had arrived";
        ok $ms < 2000,    "the $builtin returned promptly ($ms ms) instead of parking the OS thread";
        ok $ticked,       "a sibling fiber ran during the $builtin, so the rest of the run kept going";
    }
};
subtest 'the caller handle is handed back in the mode it arrived in' => sub {
    # The override makes the handle non-blocking only for the duration of its own read, then puts the flags back.
    # Anything else would break the gevent-style contract in reverse: code compiled *before* installation still gets a
    # raw blocking read from that same handle, and would start failing with EAGAIN if we left it flipped.
    my ( $a, $b ) = socket_pair();
    unless ( defined eval { fcntl( $a, F_GETFL, 0 ) } ) {
        SKIP: { skip 'this platform does not report a descriptor mode for a socket', 2 }
    }
    for my $want ( 0, 1 ) {    # 0 = the socket default, 1 = the caller set O_NONBLOCK itself
        my $flags = fcntl( $a, F_GETFL, 0 );
        fcntl( $a, F_SETFL, $want ? ( $flags | O_NONBLOCK ) : ( $flags & ~O_NONBLOCK ) );
        my $before = fcntl( $a, F_GETFL, 0 ) & O_NONBLOCK ? 1 : 0;
        syswrite $b, 'ok';
        my ( $buf, $rc );
        async { $rc = read( $a, $buf, 2 ) };
        my $after = fcntl( $a, F_GETFL, 0 ) & O_NONBLOCK ? 1 : 0;
        my $was   = $before ? 'non-blocking' : 'blocking';
        my $now   = $after  ? 'still non-blocking' : 'still blocking';
        is $rc,    2,        "an exact read on a handle the caller left $was worked";
        is $after, $before, "...and the handle is $now afterwards";
    }
};
subtest 'a pipe parks the fiber instead of freezing the thread' => sub {
    pipe( my $r, my $w ) or die "pipe: $!";
    my ( $buf, $rc, $ticked );
    my $t0 = time;
    async {
        with_timeout(
            5000,
            sub {
                my $ticks = fiber { await_sleep(30); $ticked = 1; 1 };
                my $late  = fiber { await_sleep(150); syswrite $w, 'piped' };
                $rc = read( $r, $buf, 5 );
                $late->await;
                $ticks->await;
            }
        );
    };
    my $ms = ( time - $t0 ) * 1000;
    is $rc,  5,       'the read on a pipe returned the byte count once the writer got there';
    is $buf, 'piped', '...and filled the caller buffer';
    ok $ms >= 140,    "the read waited for the late writer ($ms ms) rather than spinning or returning early";
    ok $ms < 3000,    "...and returned promptly once the data arrived ($ms ms)";
    ok $ticked,       'a sibling fiber ran while the pipe read was parked';
};
subtest 'a regular file read inside a fiber falls back to the raw builtin' => sub {
    my $dir  = File::Temp->newdir( CLEANUP => 0 );
    my $path = File::Spec->catfile( $dir->dirname, 'x.txt' );
    open my $wr, '>', $path or die "write $path: $!";
    print $wr 'file read works';    # length 15
    close $wr;
    for my $builtin (qw[read sysread]) {
        my ( $buf, $rc );
        open my $fh, '<', $path or die "open $path: $!";
        async {
            with_timeout(
                15000,
                sub {
                    # Many reads, not one. The override times its readiness probe against the wall clock to tell
                    # "select() cannot watch this handle" (fall back to a raw read) from "a real wait timed out"
                    # (keep waiting), and a probe landing across a clock-second boundary used to be misread as the
                    # latter, after which the read spun until the deadline below killed it. A single read misses
                    # that most of the time, so it took a loaded machine and a full test run to notice; 150 reads
                    # inside one deadline hit it reliably. Rewind each time, since 15 bytes then hits EOF.
                    for ( 1 .. 150 ) {
                        seek( $fh, 0, 0 );
                        if ( $builtin eq 'read' ) { $rc = read( $fh, $buf, 15 ) }
                        else                      { $rc = sysread( $fh, $buf, 15 ) }
                    }
                }
            );
        };
        is $rc,  15,                "$builtin on a regular file inside a fiber returned the byte count, every time";
        is $buf, 'file read works', "$builtin on a regular file read the content (raw fallback, no spin)";
        close $fh;
    }
};
subtest 'disable restores the raw globals for freshly compiled code' => sub {
    is Acme::Parataxis->disable_transparent_unblocking(), 1, 'disabling reports success';
    is Acme::Parataxis->transparent_unblocking(),         0, 'no longer installed';
    my $first = eval 'package X1; use Time::HiRes qw[time]; my $t0 = time; my $rc = sleep(0.05); [ $rc, (time - $t0) * 1000 ]';
    is ref $first,  'ARRAY',            'freshly compiled sleep(0.05) ran';
    is $first->[0], int( $first->[0] ), '...and returned the truncated-to-integer CORE::sleep result, not the requested duration';
    ok $first->[1] < 5000, sprintf '...returned via the raw builtin (%f ms), not the scheduler', $first->[1];
    is Acme::Parataxis->enable_transparent_unblocking(), 1, 're-enabling works';
    is Acme::Parataxis->transparent_unblocking(),        1, 'and is reported installed again';
};
#
done_testing();
