use v5.40;
use blib;
use Time::HiRes     qw[time];
use Acme::Parataxis qw[async fiber yield await_sleep with_timeout];
use Acme::Parataxis::Semaphore;
use Acme::Parataxis::Signal;
use Acme::Parataxis::Future;
use Acme::Parataxis::CancellationToken;
use Test2::V1 -ipP;
$|++;
sub sem_block () { my $s = Acme::Parataxis::Semaphore->new( count => 0 );  $s->down }
sub sig_block () { my $s = Acme::Parataxis::Signal->new( count => false ); $s->wait }
subtest 'an inline block returns immediately, no deadline armed' => sub {
    my $ran = 0;
    my $start;
    my $got = async {
        $start = time;
        my $v       = with_timeout( 2000, sub { $ran++; 55 } );
        my $elapsed = time - $start;
        [ $v, $elapsed ];
    }
    ->[0];
    is $got, 55, 'block value returned';
    is $ran, 1,  'block ran exactly once';
};
subtest 'a parking block that finishes under the deadline returns its value' => sub {
    my $got = async {
        with_timeout( 400, sub { await_sleep(1); 'fast' } )
    };
    is $got, 'fast', 'parked-but-fast block returned';
};
subtest 'deadline fires: Error::Timeout is thrown in the caller and the run continues' => sub {
    my ( $caught, $after );
    async {
        eval {
            with_timeout( 20, sub { sem_block() } );
        };
        $caught = $@;
        $after  = 'ran-on';
    };
    ok ref($caught) && $caught->isa('Acme::Parataxis::Error::Timeout'), '::Timeout thrown by with_timeout';
    is $caught->kind,             'timeout',        'kind() is "timeout"';
    is $caught->wait_reason->[0], 'Semaphore down', 'wait_reason names the blocked wait';
    is $after,                    'ran-on',         'the async block continued after catching the timeout';
    ok eval {1}, 'run untouched by the timeout';
};
subtest 'with_timeout runs inside a spawned fiber' => sub {
    my $got;
    async {
        my $f = fiber {
            my $c = fiber { await_sleep(5); 7 };
            $c->await;
            with_timeout( 2000, sub {7} );
        };
        eval { $got = $f->await };
    };
    is $got, 7, 'nested fiber can apply a timeout';
};
subtest 'repeated timeouts after catching one still work' => sub {
    my @errors;
    async {
        for my $i ( 1 .. 3 ) {
            my $bound = ( $i % 2 ) ? 20  : 2000;
            my $inner = ( $i % 2 ) ? 100 : 1;
            eval {
                with_timeout(
                    $bound,
                    sub {
                        await_sleep($inner);
                        "ok-$i";
                    }
                );
            };
            push @errors, $@;
        }
    };
    ok $errors[0] && $errors[0]->isa('Acme::Parataxis::Error::Timeout'), 'first too-short bound timed out';
    ok !( $errors[1] && ref $errors[1] ),                                'second bound returned cleanly';
    ok $errors[2] && $errors[2]->isa('Acme::Parataxis::Error::Timeout'), 'third too-short bound timed out again';
};
subtest 'an explicit token cancels the block with Error::Cancelled' => sub {
    my $caught;
    async {
        my $tok  = Acme::Parataxis::CancellationToken->new;
        my $fire = fiber { await_sleep(10); $tok->cancel; 1 };
        try {
            with_timeout( 2000, $tok, sub { sem_block() } );
        }
        catch ($e) { $caught = $e; }
    };
    ok ref($caught) && $caught->isa('Acme::Parataxis::Error::Cancelled'), '::Cancelled thrown when the token fires';
};
subtest 'a pre-cancelled token fails fast without running the block' => sub {
    my ( $ran, $caught );
    async {
        my $tok = Acme::Parataxis::CancellationToken->new;
        $tok->cancel;
        eval {
            with_timeout( 2000, $tok, sub { $ran++; 'no' } );
        };
        $caught = $@;
    };
    ok !$ran,                                                             'block not run';
    ok ref($caught) && $caught->isa('Acme::Parataxis::Error::Cancelled'), 'fast-fail ::Cancelled';
};
subtest 'genuine errors from the block propagate unchanged' => sub {
    my $caught;
    async {
        eval {
            with_timeout( 2000, sub { die 'real-bug' } );
        };
        $caught = $@;
    };
    like $caught, qr[real-bug], 'the block die is not mistaken for a timeout';
    ok !( ref $caught && $caught->isa('Acme::Parataxis::Error::Timeout') ), 'not a ::Timeout';
};
subtest 'a zero bound means no deadline' => sub {
    my $got = async {
        with_timeout( 0, sub { await_sleep(3); 'no-bound' } )
    };
    is $got, 'no-bound', 'ms == 0 runs the block to completion';
};
subtest 'a timed-out Future await then a working one' => sub {
    my ( $err, $later );
    async {
        my $f = Acme::Parataxis::Future->new;
        eval {
            with_timeout( 20, sub { $f->await; 'f' } );
        };
        $err = $@;
        my $g = Acme::Parataxis::Future->new;
        my $w = fiber { $g->await };
        $g->set_result('now');
        $later = $w->await;
    };
    ok ref($err) && $err->isa('Acme::Parataxis::Error::Timeout'), 'Future await timed out';
    is $later, 'now', 'a new Future await completes normally afterwards';
};
subtest 'with_timeout requires a fiber context and a non-negative bound' => sub {
    like dies {
        with_timeout( 50, sub {1} )
    }, qr[must be called from inside a scheduled fiber], 'croaks outside a scheduled fiber';
    async {
        like dies {
            with_timeout( -1, sub {1} )
        }, qr[requires a duration in milliseconds], 'croaks on a negative duration';
        like dies { with_timeout(50) }, qr[requires a CODE ref], 'croaks without a block';
    };
};
#
done_testing;
