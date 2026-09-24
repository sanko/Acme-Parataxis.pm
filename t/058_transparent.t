use v5.40;
use blib;
use Test2::V1 -ipP;
use Time::HiRes  qw[time];
use File::Temp ();
use IO::Socket::INET ();
use Acme::Parataxis  qw[async fiber await_sleep with_timeout];
#
# Transparent unblocking is opt-in, per-process, compile-time. The overrides
# affect only code compiled AFTER enable_transparent_unblocking ran, so they are
# installed here in BEGIN, before the test bodies below are compiled. Everything at
# the top level (current_fid < 0) must delegate to the raw CORE:: builtins, and every
# call from inside a scheduled fiber frames on the scheduler's await_sleep/await_read
# so no OS thread is parked. Nothing is monkey-patched on other threads: a fresh
# interpreter starts with unmodified builtins.
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
    is Acme::Parataxis->enable_transparent_unblocking(), 1, 'installing reports success';
    is Acme::Parataxis->enable_transparent_unblocking(), 1, 'second install is idempotent, not an error';
    is Acme::Parataxis->transparent_unblocking(),        1, 'transparent_unblocking() reflects the install';
    is Acme::Parataxis->current_fid,                    -1, 'top level is outside the scheduler (fid -1)';
};
subtest 'top-level sleep keeps raw CORE::sleep semantics' => sub {
    my $t0 = time;
    my $rc = sleep 0.05;
    my $ms = ( time - $t0 ) * 1000;
    is $rc, 0, 'fractional seconds truncate to zero seconds, exactly like CORE::sleep';
    ok( $ms < 50, "it returned immediately ($ms ms), never parking an OS thread" );
};
subtest 'sleep inside a fiber is cooperative and yields' => sub {
    my ( @slow, $prog );
    async {
        my $t0 = time;
        my $slow = fiber { push @slow, [ sleep( 0.05 ), time - $t0 ] };
        my $ticks = fiber { await_sleep(1); my $p = 0; $prog += ++$p for 1 .. 40; 1 };
        $slow->await;
        $ticks->await;
    };
    ok( $slow[0][0] > 0.04 && $slow[0][0] < 0.5, 'the sleep returned the requested seconds, not a truncated zero' );
    ok( $slow[0][1] >= 0.045,                     'the fiber actually waited ~50ms' );
    ok $prog > 0, 'a sibling fiber made progress while the sleeper was parked';
};
subtest 'the $_ default and fractional precision reach the scheduler' => sub {
    my ( $rc, $el );
    $_ = 0.04;
    async {
        my $t0 = time;
        $rc = sleep;    # implicit $_
        $el = time - $t0;
    };
    ok( $rc > 0.03 && $rc < 0.5, 'sleep() with no argument used $_ (returned the requested duration)' );
    ok( $el >= 0.03,             "it actually waited ($el s)" );
};
subtest 'top-level read/sysread still fill the caller buffer' => sub {
    for my $builtin (qw[read sysread]) {
        my ( $a, $b ) = socket_pair();
        syswrite $a, $builtin eq 'read' ? 'hihi' : 'yo!';
        my ( $buf, $rc );
        if ( $builtin eq 'read' )   { $rc = read(    $b, $buf, 4 ) }
        else                        { $rc = sysread( $b, $buf, 3 ) }
        is $rc, 4,   "$builtin at the top level returned the byte count" if $builtin eq 'read';
        is $rc, 3,   "$builtin at the top level returned the byte count" if $builtin eq 'sysread';
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
                if ( $builtin eq 'read' )   { $rc = read(    $a, $buf, 7 ) }
                else                        { $rc = sysread( $a, $buf, 7 ) }
            };
            my $writer = fiber { await_sleep( 30 ); syswrite $b, 'framed!' };
            $reader->await;
            $writer->await;
        };
        my $ms = ( time - $t0 ) * 1000;
        is $rc, 7,   "$builtin framed the payload written after the read parked";
        is $buf, 'framed!', "$builtin wrote the result back into the caller buffer";
        ok( $ms < 4000, "the $builtin returned promptly ($ms ms) once the peer wrote" );
    }
};
subtest 'a regular file read inside a fiber falls back to the raw builtin' => sub {
    my $dir   = File::Temp->newdir();
    my $path  = File::Spec->catfile( $dir->dirname, 'x.txt' );
    open my $wr, '>', $path or die "write $path: $!";
    print $wr 'file read works';    # length 15
    close $wr;
    for my $builtin (qw[read sysread]) {
        my ( $buf, $rc );
        open my $fh, '<', $path or die "open $path: $!";
        async {
            with_timeout(
                5000,
                sub {
                    if ( $builtin eq 'read' )   { $rc = read(    $fh, $buf, 15 ) }
                    else                        { $rc = sysread( $fh, $buf, 15 ) }
                }
            );
        };
        is $rc, 15, "$builtin on a regular file inside a fiber returned the byte count";
        is $buf, 'file read works', "$builtin on a regular file read the content (raw fallback, no spin)";
        close $fh;
    }
};
subtest 'disable restores the raw globals for freshly compiled code' => sub {
    is Acme::Parataxis->disable_transparent_unblocking(), 1, 'disabling reports success';
    is Acme::Parataxis->transparent_unblocking(),        0, 'no longer installed';
    my $first = eval 'package X1; use Time::HiRes qw[time]; my $t0 = time; my $rc = sleep(0.05); [ $rc, (time - $t0) * 1000 ]';
    ok( ref $first eq 'ARRAY', 'freshly compiled sleep(0.05) ran' );
    is $first->[0], 0,   '...and returned the truncated-to-integer CORE::sleep result, not the requested duration';
    ok( $first->[1] < 50, '...returning immediately via the raw builtin, not the scheduler' );
    is Acme::Parataxis->enable_transparent_unblocking(), 1, 're-enabling works';
    is Acme::Parataxis->transparent_unblocking(),        1, 'and is reported installed again';
};
done_testing();