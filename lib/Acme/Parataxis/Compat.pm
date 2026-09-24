use v5.40;
use Errno    qw[EAGAIN EWOULDBLOCK];
use Carp     qw[croak];

package Acme::Parataxis::Compat v0.1.1 {
#
# Transparent unblocking (CORE::GLOBAL overrides). This module is an opt-in
# convenience: Acme::Parataxis->enable_transparent_unblocking() installs overrides
# that make the blocking builtins `sleep`, `read` and `sysread` cooperative inside
# scheduled fibers, and delegate to the raw CORE:: builtin everywhere else (top
# level, foreign threads), so nothing outside the scheduler changes.
#
# The override subs are installed, not compiled with the module, so only code that
# is *compiled after installation* is affected - exactly the gevent-style contract.
# Every override calls the real builtin through its CORE:: name, so none of them can
# recurse into themselves.
#

my $INSTALLED = 0;
my @SAVED;    # [ name, saved-glob ] per installed override, for disable()

# Write the framed read's result back into the caller's scalar (a reference to its
# @_ slot), mimicking the builtin: undef (error) and 0 (EOF) leave the caller's
# buffer alone; otherwise bytes before OFFSET are preserved and the read data is
# placed at OFFSET.
sub _store ( $slot, $off, $rc, $buf ) {
    return undef unless defined $rc;
    return 0 if 0 == $rc;
    $$slot = ( $off ? substr( $$slot // '', 0, $off ) : q{} ) . $buf;
    return $rc;
}

sub install :prototype() {
    return 1 if $INSTALLED;
    {
        no strict 'refs';
        push @SAVED, [ sleep   => \*{ 'CORE::GLOBAL::sleep' } ];
        push @SAVED, [ read    => \*{ 'CORE::GLOBAL::read' } ];
        push @SAVED, [ sysread => \*{ 'CORE::GLOBAL::sysread' } ];

        # sleep [;$] maps to await_sleep. Fractional seconds are honored as
        # milliseconds (CORE::sleep truncates them away) and are impossible to
        # signal-interrupt inside a fiber, so the return value is the requested
        # duration. The $_ default is reproduced by hand: a CORE::GLOBAL override
        # does not get the builtin's implicit argument.
        *{ 'CORE::GLOBAL::sleep' } = sub :prototype(;$) {
            my $secs = @_ ? $_[0] : $_;
            $secs = 0 if !defined $secs || $secs < 0;
            return $secs if 0 == $secs;
            return CORE::sleep($secs) if 'Acme::Parataxis'->current_fid < 0;
            'Acme::Parataxis'->await_sleep( $secs * 1000 );
            return $secs;
        };

        # read/sysread frame a single CORE:: read on await_read readiness. A blocking
        # handle that select() marks readable hands over whatever is already buffered
        # (at least one byte, or 0 at EOF) without parking the OS thread, so one
        # readiness probe then one blocking read is cooperative. If the read races
        # EAGAIN/EWOULDBLOCK anyway, the loop re-waits; a read with no data cycles
        # the 5s await_read default forever, matching a blocking read.
        #
        # Note: the compiler passes the builtin's second argument BY VALUE to a
        # CORE::GLOBAL override (an lvalue like read()/sysread() accept is not
        # aliased), so the overrides are deliberately left WITHOUT a prototype and
        # read into a private $buf, then write the result back through _store. That
        # also keeps the `read $fh, $buf, 8` (no-parens) form working.
        *{ 'CORE::GLOBAL::read' } = sub {
            my $off = defined $_[3] ? $_[3] : 0;
            if ( 'Acme::Parataxis'->current_fid < 0 ) {
                my $buf = '';
                my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                return _store( \$_[1], $off, $rc, $buf );
            }
            my ( $t0, $first ) = ( time, 1 );
            while (1) {
                my $ready = 'Acme::Parataxis'->await_read( $_[0], 5000 );
                if ( $ready < 0 ) {
                    # A readiness probe that fails instantly instead of cycling its
                    # 5s timeout means select() cannot watch this handle at all (a
                    # regular file, a pipe). Fall back to a raw blocking read there,
                    # which is instant for files, instead of spinning forever.
                    if ( $first && time - $t0 < 0.05 ) {
                        my $buf = '';
                        my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                        return _store( \$_[1], $off, $rc, $buf );
                    }
                    $first = 0;
                    next;
                }
                $first = 0;
                my $buf = '';
                my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                return _store( \$_[1], $off, $rc, $buf ) if defined $rc;
                return undef unless $!{EAGAIN} || $!{EWOULDBLOCK};
            }
        };
        *{ 'CORE::GLOBAL::sysread' } = sub {
            my $off = defined $_[3] ? $_[3] : 0;
            if ( 'Acme::Parataxis'->current_fid < 0 ) {
                my $buf = '';
                my $rc  = CORE::sysread( $_[0], $buf, $_[2], 0 );
                return _store( \$_[1], $off, $rc, $buf );
            }
            my ( $t0, $first ) = ( time, 1 );
            while (1) {
                my $ready = 'Acme::Parataxis'->await_read( $_[0], 5000 );
                if ( $ready < 0 ) {
                    # See the read override: a probe that fails instantly means the
                    # handle cannot be select()ed, so read it raw rather than spin.
                    if ( $first && time - $t0 < 0.05 ) {
                        my $buf = '';
                        my $rc  = CORE::sysread( $_[0], $buf, $_[2], 0 );
                        return _store( \$_[1], $off, $rc, $buf );
                    }
                    $first = 0;
                    next;
                }
                $first = 0;
                my $buf = '';
                my $rc  = CORE::sysread( $_[0], $buf, $_[2], 0 );
                return _store( \$_[1], $off, $rc, $buf ) if defined $rc;
                return undef unless $!{EAGAIN} || $!{EWOULDBLOCK};
            }
        };
    }
    $INSTALLED = 1;
    return 1;
}

sub disable :prototype() {
    return 1 unless $INSTALLED;
    {
        no strict 'refs';
        *{ 'CORE::GLOBAL::' . $_->[0] } = $_->[1] for @SAVED;
    }
    @SAVED    = ();
    $INSTALLED = 0;
    return 1;
}

sub installed :prototype() { return $INSTALLED ? 1 : 0 }
}