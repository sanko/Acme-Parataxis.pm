use v5.40;
use Test2::V1 -ipP;
use blib;
use Acme::Parataxis;
use experimental 'class';
#
skip_all 'Signals on Windows? Ha!', 2 if $^O eq 'MSWin32';
subtest 'Signal handled inside coroutine' => sub {
    my $signaled = 0;
    local $SIG{INT} = sub { $signaled++ };
    my $coro = Acme::Parataxis->new(
        code => sub {
            kill 'INT', $$;
            return "Done";
        }
    );
    $coro->call();
    is( $signaled, 1, 'Signal was caught and handled' );
};
subtest 'Signal during yield/resume' => sub {
    my $signaled = 0;
    local $SIG{USR1};

    # USR1 is not on Windows, let's use HUP or something else if available
    # Actually let's just use INT.
    local $SIG{INT} = sub { $signaled++ };
    my $coro = Acme::Parataxis->new(
        code => sub {
            Acme::Parataxis->yield('READY');
            return "Finished";
        }
    );
    $coro->call();
    kill 'INT', $$;
    $coro->call();
    is( $signaled, 1, 'Signal handled between yield and resume' );
};
done_testing();
