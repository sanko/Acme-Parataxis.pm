use v5.40;
use blib;
use Acme::Parataxis;
use Test2::V1 -ipP;
#
diag '$Acme::Parataxis::VERSION = ' . $Acme::Parataxis::VERSION;
subtest 'Asymmetric Coroutines' => sub {
    my $f = Acme::Parataxis->new(
        code => sub ($name) {
            is( $name, 'Alice', 'Received arg' );
            my $val = Acme::Parataxis->yield( 'Hello ' . $name );
            is( $val, 'Bob', 'Received resume arg' );
            return 'Goodbye ' . $name;
        }
    );
    is( $f->call('Alice'), 'Hello Alice',   'First call result' );
    is( $f->call('Bob'),   'Goodbye Alice', 'Second call result' );
    ok( $f->is_done, 'Parataxis finished' );
};
done_testing();
