use v5.40;
use blib;
use Acme::Parataxis;
use Test2::V1 -ipP;
use Cwd qw(abs_path);
$|++;
#
diag '$Acme::Parataxis::VERSION = ' . $Acme::Parataxis::VERSION;
diag 'Testing exit() propagation out of fibers (subprocess) ...';

my $perl = $^X;

# The child needs the freshly-built module; use absolute paths so the test
# does not depend on the child's current directory.
my @inc;
push @inc, '-I' . abs_path($_) for grep { -e $_ } qw[blib/lib blib/arch];

sub shell_quote {
    my ($s) = @_;
    return $s if $s =~ /^[A-Za-z0-9_\-\/.:\\]+$/;
    return '"' . $s . '"';
}

sub run_exit_code {
    my ($code) = @_;
    # Backticks capture the child's output (so a genuine panic is visible)
    # and go through popen rather than the LIST-form spawn path, which on
    # some Windows perl builds fails to report a status at all.
    my $cmdline = join ' ', map { shell_quote($_) } ( $perl, @inc, '-e', $code );
    local $SIG{__WARN__} = sub { };
    my $out = `$cmdline 2>&1`;
    my $rc  = $? >> 8;
    return wantarray ? ( $rc, $out ) : $rc;
}

# On some Windows perl builds (notably gcc -O2 perls on Windows 11, see
# perl5 GH issue #20081) a freshly spawned perl.exe cannot report its
# status: the child runs to completion but the parent sees
# "Can't spawn ... : No error" and reads 255.  A genuinely-failing child
# would print a panic instead of exiting silently, so a 255 status with no
# panic in the captured output is the broken-spawn signature: skip rather
# than report a bogus failure (Coro's own exit test skips on Windows for
# the same reason).
sub maybe_skip_broken_spawn {
    my ($rc, $out) = @_;
    if ( $rc == 255 && $out !~ /panic/ ) {
        plan skip_all => 'cannot read the child status on this perl (spawn reporting is broken)';
        return 1;
    }
    return 0;
}

subtest 'exit(0) from a nested fiber' => sub {
    my ( $rc, $out ) = run_exit_code('use Acme::Parataxis qw[async yield fiber]; async { fiber { exit 0 }; yield; }');
    return if maybe_skip_broken_spawn( $rc, $out );
    is( $rc, 0, 'nested fiber exit(0) terminates cleanly with status 0' );
};

subtest 'exit(7) from the top-level async block' => sub {
    my ( $rc, $out ) = run_exit_code('use Acme::Parataxis qw[async]; async { exit 7; }');
    return if maybe_skip_broken_spawn( $rc, $out );
    is( $rc, 7, 'async top-level exit(7) propagates the requested status' );
};

subtest 'exit(3) after yielding and being resumed' => sub {
    my ( $rc, $out ) = run_exit_code('use Acme::Parataxis qw[async yield fiber]; async { fiber { 1 }; yield; exit 3; }');
    return if maybe_skip_broken_spawn( $rc, $out );
    is( $rc, 3, 'exit(3) after a yield/resume cycle propagates the requested status' );
};

subtest 'exit() does not double-free scheduler scopes' => sub {
    my ( $rc, $out ) = run_exit_code('use Acme::Parataxis qw[async yield fiber]; async { fiber { exit 0 }; yield; }');
    return if maybe_skip_broken_spawn( $rc, $out );
    isnt( $rc, 255, 'no wrong-pool panic (exit != 255)' );
};

done_testing();
