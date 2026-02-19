use v5.40;
use Test::More;
use blib;
use Acme::Parataxis;
Acme::Parataxis::run(
    sub {
        my $fiber = Acme::Parataxis->spawn(
            sub {
                my $val = 'hello world';
                Acme::Parataxis->yield('yielding');
                if ( $val =~ /hello/ ) {
                    return 'matched';
                }
                return 'not matched';
            }
        );
        my $res = $fiber->await();
        is( $res, 'matched', 'Regex match after yield works' );
        Acme::Parataxis::stop();
    }
);
done_testing();
