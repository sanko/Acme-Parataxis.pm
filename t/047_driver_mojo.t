use v5.40;
use experimental qw[class];
use blib;
use Test2::V1 -ipP;
use IO::Socket::INET ();
use Time::HiRes      qw[time];
use Acme::Parataxis  qw[async fiber await_sleep await_read await_write with_timeout];
#
# Fibers run on separate heap stacks; Perl's C-stack-depth heuristic can misfire and falsely report "Deep recursion"
# once more than ~100 of them park inside the same sub (the high-volume subtest below does exactly that). Lexical
# 'no warnings' is ignored once a framework such as Test2 is loaded, so filter it here as t/028/029/030 do. Genuine
# runaway recursion inside a fiber surfaces as a hang or a croak the harness already catches.
BEGIN {
    $SIG{__WARN__} = sub { return if $_[0] =~ /^Deep recursion on subroutine/; warn @_ }
}
plan skip_all => 'Mojo::IOLoop not installed' unless eval { require Mojo::IOLoop; 1 };

# A fresh connected loopback socket pair. The driver flips the fd being watched to non-blocking, so (as the pool
# path does) the waiter end is the $b we park on; the peer end stays a plain blocking socket we write from.
sub socket_pair {
    my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1 ) or die "listen: $!";
    my $client = IO::Socket::INET->new( PeerAddr  => '127.0.0.1:' . $server->sockport )                         or die "connect: $!";
    my $conn   = $server->accept or die "accept: $!";
    return ( $client, $conn );
}

# $n connected loopback pairs off a single listener. Connect and accept are interleaved so the listen backlog is
# never asked to hold more than one pending connection, which keeps hundreds of pairs cheap to build.
sub socket_pairs ($n) {
    my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 64, ReuseAddr => 1 ) or die "listen: $!";
    my ( @writers, @waiters );
    for ( 1 .. $n ) {
        my $client = IO::Socket::INET->new( PeerAddr => '127.0.0.1:' . $server->sockport ) or die "connect: $!";
        my $conn   = $server->accept                                                       or die "accept: $!";
        push @writers, $client;
        push @waiters, $conn;
    }
    return ( \@writers, \@waiters );
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

# -- Card 2 acceptance: high-volume readiness on the loop, and proof that the worker pool does none of it. ------
# Count every pool submission. _submit_job is the only gate onto submit_c_job (await_sleep, await_core_id,
# await_read and await_write all route through it) and run() never submits on its own, so a zero count while a
# loop is attached means no worker thread was ever asked to provide readiness or a sleep.
my $submits         = 0;
my $orig_submit_job = \&Acme::Parataxis::_submit_job;
{
    no warnings 'redefine';
    *Acme::Parataxis::_submit_job = sub ( $type, $arg, $timeout ) { $submits++; $orig_submit_job->( $type, $arg, $timeout ) };
}

# Windows: stock Strawberry perl builds without d_poll, so Mojo::Reactor::Poll drives IO::Poll::_poll through its
# select fallback. The limit there is the descriptor NUMBER, not the watch count: winsock FD_SETSIZE truncates the
# fd_set at 64, so the reactor goes silent as soon as any watched fd reaches 64 (5 watches woke 5/5 at maxfd 13,
# 5 watches after 70 dummy fds woke 0/5), IO::Select never crashes but reports at most 64 ready handles, and the
# pure-Mojo stack crashes the interpreter above 128 pairs on perl 5.42.3. 24 pairs keep every fd under 64, which
# is enough to exercise the whole driver path on Windows; other platforms keep the full 300.
my $N = $^O eq 'MSWin32' ? 24 : 300;
subtest "high-volume: $N concurrent await_read wake on loopback" => sub {
    my ( $writers, $waiters ) = socket_pairs($N);
    Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
    $submits = 0;
    my @got;
    my $t0 = time;
    Acme::Parataxis::run(
        sub {
            # Park every fiber on its own descriptor first; the writer only fires once all $N watches are armed, so
            # this exercises N descriptors parked at once rather than N reads that were ready from the start.
            my @fibers = map {
                my $i = $_;
                fiber { $got[$i] = await_read( $waiters->[$i], 5000 ) }
            } 0 .. $N - 1;
            await_sleep(50);
            syswrite $writers->[$_], 'x' for 0 .. $N - 1;
            $_->await for @fibers;
        }
    );
    my $ms              = ( time - $t0 ) * 1000;
    my $attached_submit = $submits;
    Acme::Parataxis->detach_loop;
    my $woke = grep { defined $_ && $_ == 1 } @got;
    is $woke,            $N, "all $N parked reads woke with their byte";
    is $attached_submit, 0,  "no worker-pool job was submitted for any of the $N reads";
    ok $ms < 15000, sprintf( 'the whole batch completed in %.0fms', $ms );
};
subtest 'the pool-submission counter is live, not vacuous' => sub {

    # Same workload shape with no loop attached. If the counter never increments here, the zero above would prove
    # nothing at all, so this is the control that keeps the assertion honest.
    my ( $writers, $waiters ) = socket_pairs(1);
    $submits = 0;
    my $got;
    Acme::Parataxis::run(
        sub {
            my $f = fiber { await_sleep(30); syswrite $writers->[0], 'ping' };
            $got = await_read( $waiters->[0], 2000 );
            $f->await;
        }
    );
    my $pool_submit = $submits;
    is $got, 1, 'the pool path completed the same workload';
    cmp_ok $pool_submit, '>=', 2, "the pool path submitted for both the read and the sleep ($pool_submit)";
    {
        no warnings 'redefine';
        *Acme::Parataxis::_submit_job = $orig_submit_job;
    }
};
done_testing;
