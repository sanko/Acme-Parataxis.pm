use v5.40;
use experimental qw[class];
use blib;
use Test2::V1 -ipP;
use Time::HiRes      qw[time];
use IO::Socket::INET ();
use Acme::Parataxis  qw[async fiber await_sleep await_read await_write with_timeout];
#
plan skip_all => 'IO::Async::Loop not installed' unless eval { require IO::Async::Loop; 1 };
#
sub socket_pair {
    my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1 ) or die "listen: $!";
    my $client = IO::Socket::INET->new( PeerAddr  => '127.0.0.1:' . $server->sockport )                         or die "connect: $!";
    my $conn   = $server->accept or die "accept: $!";
    return ( $client, $conn );
}
subtest 'attach / detach bookkeeping' => sub {
    ok !Acme::Parataxis->loop,                                'no driver before any attach';
    ok !Acme::Parataxis->attach_loop( IO::Async::Loop->new ), 'first attach returns undef';
    my $drv = Acme::Parataxis->loop;
    ok ref($drv) && $drv->isa('Acme::Parataxis::Driver'), 'loop() is the wrapped driver';
    ok $drv->isa('Acme::Parataxis::Driver::IOAsync'),     'it is the IO::Async driver';
    is Acme::Parataxis->attach_loop( IO::Async::Loop->new ), $drv, 'reattaching returns the previous driver';

    # Reattaching installs a *fresh* driver (there is no singleton to fall back on), so compare detach against the
    # driver that is current right now rather than the $drv stashed before the reattach.
    my $current = Acme::Parataxis->loop;
    is Acme::Parataxis->detach_loop(), $current, 'detach_loop returns the current driver';
    ok !Acme::Parataxis->loop, 'no driver after detach';
    like dies { Acme::Parataxis->attach_loop('garbage') }, qr[requires an event-loop object], 'attach_loop rejects a non object';
    like dies {
        Acme::Parataxis::run( sub { Acme::Parataxis->attach_loop( IO::Async::Loop->new ) } )
    }, qr[cannot run while a run is already active], 'attach inside a run is refused';
};
subtest 'a parked driver read wakes when the peer writes' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( IO::Async::Loop->new );
    my $e;
    my $t0 = time;
    Acme::Parataxis::run(
        sub {
            my $w = fiber { await_sleep(30); syswrite $a, 'ping' };
            $e .= 'ready=' . await_read( $b, 2000 );
            my $buf = '';
            sysread $b, $buf, 4;
            $e .= " buf=$buf";
        }
    );
    my $ms = ( time - $t0 ) * 1000;
    Acme::Parataxis->detach_loop;
    is $e, 'ready=1 buf=ping', 'the parked read woke with the written bytes';
    ok $ms >= 15 && $ms < 1500, 'it woke on the write, not on the long deadline (ms)';
};
subtest 'a short driver deadline returns -1 without throwing' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( IO::Async::Loop->new );
    my $got;
    my $t0 = time;
    Acme::Parataxis::run( sub { $got = await_read( $b, 60 ) } );
    my $ms = ( time - $t0 ) * 1000;
    Acme::Parataxis->detach_loop;
    is $got, -1, 'own driver deadline returned -1 (resumed, not thrown)';
    ok $ms >= 40 && $ms < 7200, 'the deadline really waited before firing (ms, IO::Async loop granules are coarse)';
};
subtest 'an enclosing with_timeout still interrupts a driver read' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( IO::Async::Loop->new );
    my ( $err, $after );
    Acme::Parataxis::run(
        sub {
            eval {
                with_timeout( 30, sub { await_read( $b, 4000 ) } );
            };
            $err   = $@;
            $after = 'ran-on';
        }
    );
    Acme::Parataxis->detach_loop;
    ok ref($err) && $err->isa('Acme::Parataxis::Error::Timeout'), 'enclosing ::Timeout propagated';
    is $err->kind, 'timeout', 'kind is timeout';
    is $after,     'ran-on',  'the fiber continued after catching it';
};
done_testing;
