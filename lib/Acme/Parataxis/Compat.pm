use v5.40;
use Errno       qw[EAGAIN EWOULDBLOCK];
use Carp        qw[croak];
use Time::HiRes ();                       # loaded only: the overrides call Time::HiRes::time() fully qualified, never bare time()

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

    # The readiness budget, in ms, that the read/sysread overrides give each await_read probe, plus the fraction of
    # that budget a probe must return short of to count as "select() cannot watch this handle" rather than "a real
    # wait timed out". See the read override for why that has to be timed on a high-resolution clock.
    my $PROBE_MS  = 5000;
    my $UNWATCHED = 0.9;

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

    sub install : prototype() {
        return 1 if $INSTALLED;
        {
            no strict 'refs';
            push @SAVED, [ sleep   => \*{'CORE::GLOBAL::sleep'} ];
            push @SAVED, [ read    => \*{'CORE::GLOBAL::read'} ];
            push @SAVED, [ sysread => \*{'CORE::GLOBAL::sysread'} ];

            # sleep [;$] maps to await_sleep. Fractional seconds are honored as
            # milliseconds (CORE::sleep truncates them away) and are impossible to
            # signal-interrupt inside a fiber, so the return value is the requested
            # duration. The $_ default is reproduced by hand: a CORE::GLOBAL override
            # does not get the builtin's implicit argument.
            *{'CORE::GLOBAL::sleep'} = sub : prototype(;$) {
                my $secs = @_ ? $_[0] : $_;
                $secs = 0 if !defined $secs || $secs < 0;
                return $secs              if 0 == $secs;
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
            *{'CORE::GLOBAL::read'} = sub {
                my $off = defined $_[3] ? $_[3] : 0;
                if ( 'Acme::Parataxis'->current_fid < 0 ) {
                    my $buf = '';
                    my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                    return _store( \$_[1], $off, $rc, $buf );
                }
                while (1) {
                    my $t0    = Time::HiRes::time();
                    my $ready = 'Acme::Parataxis'->await_read( $_[0], $PROBE_MS );
                    if ( $ready < 0 ) {

                        # A probe that came back well short of its own budget means select() cannot watch this handle
                        # at all (a regular file, a pipe), not that a real wait timed out. Fall back to a raw blocking
                        # read there, which is instant for files, instead of spinning forever.
                        #
                        # Two things this comparison has to get right, both of which used to be wrong and made a
                        # regular-file read inside a fiber hang until the caller's deadline killed it:
                        #   - it must be timed on a high-resolution clock. `time` here was plain CORE::time, so the
                        #     whole-second answer made a sub-50ms probe read as 0 or 1, and any probe that happened to
                        #     cross a second boundary was misread as a genuine timeout;
                        #   - it must be per round, not a one-shot on the first. The flag used to be cleared whether or
                        #     not the fallback was taken, so one slow round cost the fallback permanently and the loop
                        #     then spun a 5s probe at a time forever.
                        # A round that really did burn the budget is a real timeout, so keep waiting instead of
                        # blocking the whole process on a raw read of a socket that has nothing yet.
                        if ( Time::HiRes::time() - $t0 < $PROBE_MS / 1000 * $UNWATCHED ) {
                            my $buf = '';
                            my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                            return _store( \$_[1], $off, $rc, $buf );
                        }
                        next;
                    }
                    my $buf = '';
                    my $rc  = CORE::read( $_[0], $buf, $_[2], 0 );
                    return _store( \$_[1], $off, $rc, $buf ) if defined $rc;
                    return undef unless $!{EAGAIN} || $!{EWOULDBLOCK};
                }
            };
            *{'CORE::GLOBAL::sysread'} = sub {
                my $off = defined $_[3] ? $_[3] : 0;
                if ( 'Acme::Parataxis'->current_fid < 0 ) {
                    my $buf = '';
                    my $rc  = CORE::sysread( $_[0], $buf, $_[2], 0 );
                    return _store( \$_[1], $off, $rc, $buf );
                }
                while (1) {
                    my $t0    = Time::HiRes::time();
                    my $ready = 'Acme::Parataxis'->await_read( $_[0], $PROBE_MS );
                    if ( $ready < 0 ) {

                        # See the read override: a probe that gave up short of its budget means the handle cannot
                        # be select()ed, so read it raw rather than spin. Same high-resolution timing, same per-round
                        # (not one-shot) test, same refusal to raw-block a socket that merely timed out.
                        if ( Time::HiRes::time() - $t0 < $PROBE_MS / 1000 * $UNWATCHED ) {
                            my $buf = '';
                            my $rc  = CORE::sysread( $_[0], $buf, $_[2], 0 );
                            return _store( \$_[1], $off, $rc, $buf );
                        }
                        next;
                    }
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

    sub disable : prototype() {
        return 1 unless $INSTALLED;
        {
            no strict 'refs';
            *{ 'CORE::GLOBAL::' . $_->[0] } = $_->[1] for @SAVED;
        }
        @SAVED     = ();
        $INSTALLED = 0;
        return 1;
    }
    sub installed : prototype() { return $INSTALLED ? 1 : 0 }
}
