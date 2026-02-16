use v5.40;
use Test2::V1 -ipP;
use blib;
use Acme::Parataxis;
use experimental 'class';
#
subtest 'Die inside coroutine, catch outside' => sub {
    my $coro = Acme::Parataxis->new(
        code => sub {
            die "Death in coro";
        }
    );
    eval { $coro->call(); };
    like( $@, qr/Death in coro/, 'Caught exception from coroutine' );
    ok( $coro->is_done, 'Coroutine is marked as done after die' );
};
subtest 'Eval inside coroutine' => sub {
    my $coro = Acme::Parataxis->new(
        code => sub {
            eval { die "Inner death"; };
            return "Survived: $@";
        }
    );
    my $res = $coro->call();
    like( $res, qr/Survived: Inner death/, 'Inner eval caught the death' );
    ok( $coro->is_done, 'Coroutine finished normally' );
};
subtest 'Nested coroutines exceptions' => sub {
    my $coro1 = Acme::Parataxis->new(
        code => sub {
            my $coro2 = Acme::Parataxis->new(
                code => sub {
                    die "Deep death";
                }
            );
            $coro2->call();
            return "Coro2 survived?";
        }
    );
    eval { $coro1->call(); };
    like( $@, qr/Deep death/, 'Caught deep death' );
};
done_testing();
