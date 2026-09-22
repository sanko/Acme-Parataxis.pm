use v5.40;
use experimental qw[class];
use blib;
use Test2::V1 -ipP;
use IO::Socket::INET ();
use Time::HiRes      qw[time];
use Acme::Parataxis  qw[async fiber await_sleep await_read await_write with_timeout];
#
plan skip_all => 'Mojo::IOLoop not installed' unless eval { require Mojo::IOLoop; 1 };

# A fresh connected loopback socket pair. The driver flips the fd being watched to non-blocking, so (as the pool
# path does) the waiter end is the $b we park on; the peer end stays a plain blocking socket we write from.
sub socket_pair {
    my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1 ) or die "listen: $!";
    my $client = IO::Socket::INET->new( PeerAddr  => '127.0.0.1:' . $server->sockport )                         or die "connect: $!";
    my $conn   = $server->accept or die "accept: $!";
    return ( $client, $conn );
}
ok !Acme::Parataxis->loop,                             'no driver before any attach';
ok !Acme::Parataxis->attach_loop( Mojo::IOLoop->new ), 'attach_loop returns undef the first time';
my $drv = Acme::Parataxis->loop;
ok ref($drv) && $drv->isa('Acme::Parataxis::Driver'), 'current loop is a wrapped driver';
ok $drv->isa('Acme::Parataxis::Driver::Mojo'),        'it is the Mojo driver';
is Acme::Parataxis->attach_loop( Mojo::IOLoop->new ), $drv, 'reattaching returns the previous driver';

# Reattaching installs a *fresh* driver, so compare detach against the driver that is current right now rather than
# the $drv stashed before the reattach (a stashed one is stale for every driver, Mojo included).
my $current = Acme::Parataxis->loop;
is Acme::Parataxis->detach_loop(), $current, 'detach_loop returns the current driver';
ok !Acme::Parataxis->loop, 'no driver after detach';
like dies { Acme::Parataxis->attach_loop('garbage') }, qr[requires an event-loop object], 'attach_loop rejects a non object';
ok !dies { Acme::Parataxis->detach_loop() }, 'a detached handle has no effect';
subtest 'a parked driver read wakes when the peer writes' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
    my $e;
    my $t0 = time;
    Acme::Parataxis::run(
        sub {
            my $f = fiber { await_sleep(30); syswrite $a, 'ping' };
            $e .= 'rc=' . await_read( $b, 2000 );
            my $buf = '';
            sysread $b, $buf, 4;
            $e .= " buf=$buf";
        }
    );
    my $ms = ( time - $t0 ) * 1000;
    Acme::Parataxis->detach_loop;
    is $e, 'rc=1 buf=ping', 'the parked read returned 1 with the bytes available';
    ok $ms >= 20 && $ms < 1200, 'it woke on the write, not on its deadline (ms)';
};
subtest 'a short driver deadline returns -1 (resumed, not thrown)' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
    my $got;
    my $t0 = time;
    Acme::Parataxis::run( sub { $got = await_read( $b, 60 ) } );
    my $ms = ( time - $t0 ) * 1000;
    Acme::Parataxis->detach_loop;
    is $got, -1, 'own deadline returned -1 like the pool path';
    ok $ms >= 40 && $ms < 1100, 'the deadline really waited before firing (ms)';
};
subtest 'an enclosing with_timeout still interrupts a driver read' => sub {
    my ( $a, $b ) = socket_pair();
    Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
    my ( $err, $after );
    Acme::Parataxis::run(
        sub {
            eval {
                with_timeout( 30, sub { await_read( $b, 2000 ) } );
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
subtest 'a driver sleep mixes with a concurrent pool job' => sub {
    Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
    my ( $pool, $ms );
    my $t0 = time;
    Acme::Parataxis::run(
        sub {
            my $pw = fiber { await_sleep(20); 'pool-writer' };
            await_sleep(40);
            $pool = $pw->await;
        }
    );
    $ms = ( time - $t0 ) * 1000;
    Acme::Parataxis->detach_loop;
    is $pool, 'pool-writer', 'the driver sleep ran the run while the pool fiber completed';
    ok $ms >= 30 && $ms < 600, 'the sleep actually slept ~40ms (ms)';
};
done_testing;
