use v5.40;

package Acme::Parataxis::Compat v0.1.1 {
    use Errno       qw[EAGAIN EWOULDBLOCK];
    use Carp        qw[croak];
    use Fcntl       qw[F_GETFL F_SETFL O_NONBLOCK];
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

    # The readiness budget, in ms, that the read/sysread overrides give each await_read probe. A probe that comes
    # back short of it means a real wait timed out, so the override keeps waiting rather than block the process.
    my $PROBE_MS = 5000;

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

    # Perform one read on a handle that is already known to be readable, WITHOUT letting a
    # short read park the OS thread.
    #
    # This is the whole point of the exercise. A blocking read on a stream socket does not
    # return when *one* byte is available, it returns when the *requested count* is - so
    # "await_read says ready, now read" froze the entire run the moment a caller asked for
    # more bytes than the peer had sent. Every fiber stalled, and because the fiber was
    # inside a syscall rather than parked in the scheduler, no deadline or token could
    # rescue it either.
    #
    # So the handle is flipped to O_NONBLOCK for the duration of the read and restored
    # afterwards. The read then returns whatever is there (>= 1 byte, or 0 at EOF) or
    # fails with EAGAIN, both of which the caller's loop already knows how to handle. A
    # regular file is unaffected: the worker's select() always reports one readable, and
    # O_NONBLOCK is a no-op there, so the read answers instantly.
    #
    # The flag save/restore is best-effort by design: if the handle cannot be interrogated
    # (an already-closed glob, a driver-supplied handle) we still attempt the read rather
    # than dying, preserving the old behaviour for anything we cannot measure.
    sub _read_nonblocking ( $fh, $len, $is_sys ) {

        # fcntl refuses dirhandles ("fcntl() on unopened filehandle") even though the descriptor behind one is
        # perfectly good, so the probe is silenced here. A handle we cannot interrogate is a "fall back to the raw
        # read" case, not something worth two diagnostics on top of the read's own.
        no warnings 'io';
        my $flags = fcntl( $fh, F_GETFL, 0 );
        if ( defined $flags && !( $flags & O_NONBLOCK ) ) {
            fcntl( $fh, F_SETFL, $flags | O_NONBLOCK );
        }
        my $buf = q{};
        my $rc  = $is_sys ? CORE::sysread( $fh, $buf, $len, 0 ) : CORE::read( $fh, $buf, $len, 0 );

        # The caller's original mode is what the handle looks like to every other bit of code that touches it,
        # including code compiled *before* installation, which still gets a raw blocking read from this same
        # handle. Restoring is what keeps transparent unblocking transparent.
        fcntl( $fh, F_SETFL, $flags ) if defined $flags;
        return ( $rc, $buf );
    }

    sub install ($class=()) {
        return 1 if $INSTALLED;
        {
            no strict 'refs';
            no warnings 'redefine';
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
                return CORE::sleep($secs) if Acme::Parataxis->current_fid < 0;
                Acme::Parataxis->await_sleep( $secs * 1000 );
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
                    my $ready = Acme::Parataxis->await_read( $_[0], $PROBE_MS );

                    # A probe that gave up short means a real wait timed out - the handle is watchable, it just had
                    # nothing to say. Keep waiting: a round with no data cycles the 5s await_read default forever,
                    # matching a blocking read, and parking this fiber is what stops that from stalling the process.
                    next if $ready < 0;
                    my ( $rc, $buf ) = _read_nonblocking( $_[0], $_[2], 0 );
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
                    my $ready = Acme::Parataxis->await_read( $_[0], $PROBE_MS );

                    # See the read override: a probe that gave up short means the handle had nothing to say, not
                    # that it is unwatchable, so keep waiting.
                    next if $ready < 0;
                    my ( $rc, $buf ) = _read_nonblocking( $_[0], $_[2], 1 );
                    return _store( \$_[1], $off, $rc, $buf ) if defined $rc;
                    return undef unless $!{EAGAIN} || $!{EWOULDBLOCK};
                }
            };
        }
        $INSTALLED = 1;
        return 1;
    }

    sub disable ($class=()) {
        return 1 unless $INSTALLED;
        {
            no strict 'refs';
            *{ 'CORE::GLOBAL::' . $_->[0] } = $_->[1] for @SAVED;
        }
        @SAVED     = ();
        $INSTALLED = 0;
        return 1;
    }
    sub installed ($class=()) { !!$INSTALLED }
};
#
1;
