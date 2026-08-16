use v5.40;
use blib;
use Acme::Parataxis;
use Test2::V1 -ipP;
$|++;
#
diag '$Acme::Parataxis::VERSION = ' . $Acme::Parataxis::VERSION;
diag 'Testing exit() propagation out of fibers (subprocess) ...';

my $perl = $^X;

sub run_exit_code {
    my ($code) = @_;
    system( $perl, '-Mblib', '-e', $code );
    return $? >> 8;
}

subtest 'exit(0) from a nested fiber' => sub {
    my $rc = run_exit_code( 'use Acme::Parataxis qw[async yield fiber]; async { fiber { exit 0 }; yield; }' );
    is( $rc, 0, 'nested fiber exit(0) terminates cleanly with status 0' );
};

subtest 'exit(7) from the top-level async block' => sub {
    my $rc = run_exit_code( 'use Acme::Parataxis qw[async]; async { exit 7; }' );
    is( $rc, 7, 'async top-level exit(7) propagates the requested status' );
};

subtest 'exit(3) after yielding and being resumed' => sub {
    my $rc = run_exit_code( 'use Acme::Parataxis qw[async yield fiber]; async { my $f = fiber { 1 }; yield; exit 3; }' );
    is( $rc, 3, 'exit(3) after a yield/resume cycle propagates the requested status' );
};

subtest 'exit() does not double-free scheduler scopes' => sub {
    # Before the parent-state restore fix, the rethrow dounwound main's
    # savestack (scheduler XSUB arena destructors) and perl_run re-popped
    # them: the Affix arena was freed twice -> "panic: free from wrong pool",
    # exit code 255.  A clean status 255-free exit proves the scopes were
    # popped exactly once.
    my $rc = run_exit_code( 'use Acme::Parataxis qw[async yield fiber]; async { fiber { exit 0 }; yield; }' );
    isnt( $rc, 255, 'no wrong-pool panic (exit != 255)' );
};

done_testing();
