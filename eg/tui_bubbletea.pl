use v5.40;
use blib;
$|++;
use Acme::Parataxis qw[:all];
use Acme::Parataxis::Channel;
use Acme::Parataxis::Signal;
use POSIX qw[:termios_h];

#
# A bubbletea-inspired TUI using Acme::Parataxis fibers.
#
# No Term::ReadKey -- raw sysread + termios only.
# SIGWINCH support on POSIX, Win32::Console polling on Windows.
#
# Architecture (Elm-like / bubbletea-style):
#   - input fiber:   await_read(STDIN) -> parse raw bytes -> MsgKey
#   - resize fiber:  $SIG{WINCH} or Win32 polling -> MsgResize
#   - tick fiber:    await_sleep(1000) -> MsgTick
#   - main loop:     Channel.get() -> Update(model, msg) -> render via View()
#

# -----------------------------------------------------------------------
# Terminal raw mode -- pure termios, no Term::ReadKey
# -----------------------------------------------------------------------

my $ORIG_TERMIOS;

sub save_termios {
    my $t = POSIX::Termios->new();
    $t->getattr(0);    # STDIN
    $ORIG_TERMIOS = $t;
}

sub enable_raw_mode {
    save_termios() unless defined $ORIG_TERMIOS;

    my $t = POSIX::Termios->new();
    $t->getattr(0);

    my $lflag = $t->getlflag();
    my $iflag = $t->getiflag();
    my $oflag = $t->getoflag();

    # Turn off: echo, canonical (line-buffered) mode, signal chars (ISIG
    # catches Ctrl+C/SUSP before we see the raw byte), newline echo.
    $lflag &= ~( ECHO | ICANON | ISIG | ECHONL );

    # Turn off: CR->NL translation, XON/XOFF flow control, break interrupt.
    $iflag &= ~( ICRNL | IXON | BRKINT );

    # Turn off: output processing (NL -> CRNL).
    $oflag &= ~( OPOST );

    $t->setlflag($lflag);
    $t->setiflag($iflag);
    $t->setoflag($oflag);

    # Minimum 1 byte, no timeout for reads
    $t->setcc( VMIN,  1 );
    $t->setcc( VTIME, 0 );

    $t->setattr(0);
}

sub disable_raw_mode {
    if ( defined $ORIG_TERMIOS ) {
        $ORIG_TERMIOS->setattr(0);
        undef $ORIG_TERMIOS;
    }
}

# -----------------------------------------------------------------------
# Terminal size -- platform-aware
# -----------------------------------------------------------------------

sub get_terminal_size {
    if ( $^O eq 'MSWin32' ) {
        return _win32_terminal_size();
    }
    else {
        return _posix_terminal_size();
    }
}

sub _posix_terminal_size {
    # ioctl(fd, TIOCGWINSZ, &winsize)  --  TIOCGWINSZ = 0x5413 on Linux
    my $TIOCGWINSZ = 0x5413;

    # struct winsize { unsigned short ws_row; ws_col; ws_xpixel; ws_ypixel; }
    my $buf = "\0" x 8;
    if ( ioctl( \*STDOUT, $TIOCGWINSZ, $buf ) ) {
        my ( $rows, $cols, $xpix, $ypix ) = unpack( 'S4', $buf );
        return ( $rows, $cols ) if $rows > 0 && $cols > 0;
    }

    # Fallback: environment (often set by screen/tmux)
    my $h = $ENV{LINES}  // $ENV{COLUMNS};
    my $w = $ENV{COLUMNS} // $ENV{LINES};
    return ( $h // 24, $w // 80 );
}

sub _win32_terminal_size {
    # Bubbletea's approach on Windows: Win32::Console gives us the screen
    # buffer dimensions directly, and console input buffer events deliver
    # WINDOW_BUFFER_SIZE_EVENT when the window resizes.  (See note below.)
    if ( eval { require Win32::Console; 1 } ) {
        my $con = Win32::Console->new(STD_OUTPUT_HANDLE());
        if ($con) {
            my ( $l, $t, $r, $b ) = $con->Info();
            my $cols = $r - $l + 1;
            my $rows = $b - $t + 1;
            return ( $rows, $cols ) if $rows > 0 && $cols > 0;
        }
    }

    # Fallback: environment or sensible defaults
    my $rows = $ENV{LINES}  // 24;
    my $cols = $ENV{COLUMNS} // 80;
    return ( $rows, $cols );
}

# -----------------------------------------------------------------------
# ANSI helpers
# -----------------------------------------------------------------------

sub hide_cursor  { print "\e[?25l" }
sub show_cursor  { print "\e[?25h" }
sub clear_screen { print "\e[H\e[2J" }
sub move_to      { my ( $r, $c ) = @_; print "\e[${r};${c}H" }

# -----------------------------------------------------------------------
# Message types (plain hashrefs -- bubbletea-style)
# -----------------------------------------------------------------------

sub MsgKey    { { type => 'key',    key    => $_[0] } }
sub MsgTick   { { type => 'tick',   count  => $_[0] } }
sub MsgResize { { type => 'resize', width  => $_[0], height => $_[1] } }
sub MsgQuit   { { type => 'quit' } }

# -----------------------------------------------------------------------
# Update / View  (pure functions over model)
# -----------------------------------------------------------------------

sub Update ( $model, $msg ) {
    my %m = %$model;

    if ( $msg->{type} eq 'key' ) {
        my $key = $msg->{key};

        if ( !defined $key || $key eq "\cC" || $key eq 'q' ) {
            return \%m, MsgQuit();
        }
        elsif ( $key eq 'j' || $key eq "\e[B" ) {
            $m{cursor} = $m{cursor} < $#{ $m{items} } ? $m{cursor} + 1 : $m{cursor};
        }
        elsif ( $key eq 'k' || $key eq "\e[A" ) {
            $m{cursor} = $m{cursor} > 0 ? $m{cursor} - 1 : 0;
        }
        elsif ( $key eq ' ' || $key eq "\r" || $key eq "\n" ) {
            my $i = $m{cursor};
            $m{toggled}{$i} = !$m{toggled}{$i};
        }
    }
    elsif ( $msg->{type} eq 'resize' ) {
        $m{width}  = $msg->{width};
        $m{height} = $msg->{height};
    }
    elsif ( $msg->{type} eq 'tick' ) {
        $m{ticks} = $msg->{count};
    }

    return \%m, undef;
}

sub View ( $model ) {
    my $w    = $model->{width};
    my $h    = $model->{height};
    my $buf  = '';
    my $list = '';

    # -- title bar --
    my $title = 'Parataxis TUI Demo (bubbletea-style)';
    $buf .= "\e[1;36m$title\e[0m\r\n";
    $buf .= "\e[2m${w}x${h}\e[0m\r\n";
    $buf .= "\r\n";

    # -- list items --
    for my $i ( 0 .. $#{ $model->{items} } ) {
        my $item   = $model->{items}[$i];
        my $mark   = $model->{toggled}{$i} ? "\e[32m[x]\e[0m" : "[ ]";
        my $cursor = $i == $model->{cursor} ? "\e[1;33m>\e[0m" : ' ';
        $list .= "$cursor $mark $item\r\n";
    }
    $buf .= $list;

    # -- status bar (pad to fill width) --
    $buf .= "\r\n";
    my $status = sprintf 'ticks: %-5d | j/k move  space toggle  q quit', $model->{ticks};
    my $pad    = $w - length($status) - 2;
    $pad       = 0 if $pad < 0;
    $buf .= "\e[7m ${status}\e[0m" . ( ' ' x $pad ) . "\r\n";

    # -- center a box to prove we see the real terminal size --
    my $box_w = 32;
    my $box_h = 5;
    my $bx    = int( ( $w - $box_w ) / 2 );
    my $by    = int( ( $h - $box_h ) / 2 );
    $bx       = 1 if $bx < 1;
    $by       = 4 if $by < 4;    # below the list

    $buf .= "\e[${by};${bx}H\e[1;35m+\e[0m" . ( '-' x ( $box_w - 2 ) ) . "\e[1;35m+\e[0m\r\n";
    for my $row ( 1 .. $box_h - 2 ) {
        my $inner = $row == 2 ? ' Resize the terminal! ' : '';
        my $pad2  = $box_w - 2 - length($inner);
        $pad2     = 1 if $pad2 < 1;
        $buf .= "\e[" . ( $by + $row ) . ";${bx}H\e[1;35m|\e[0m${inner}" . ( ' ' x $pad2 ) . "\e[1;35m|\e[0m\r\n";
    }
    $buf .= "\e[" . ( $by + $box_h - 1 ) . ";${bx}H\e[1;35m+\e[0m" . ( '-' x ( $box_w - 2 ) ) . "\e[1;35m+\e[0m\r\n";

    return $buf;
}

# -----------------------------------------------------------------------
# Fiber: raw keyboard input  (sysread + escape sequence parsing)
# -----------------------------------------------------------------------

sub input_fiber ( $ch, $quit ) {
    my $STDIN = \*STDIN;

    while ( !$quit->count ) {
        # await_read uses select() on a background thread -- fiber suspends
        my $ready = Acme::Parataxis->await_read( $STDIN, 200 );
        next unless $ready > 0;

        my $bytes = '';
        my $n    = sysread( $STDIN, $bytes, 32 );
        if ( !defined $n || $n == 0 ) {
            $ch->put( MsgQuit() );
            last;
        }

        my $i = 0;
        while ( $i < length $bytes ) {
            my $ch1 = substr( $bytes, $i, 1 );
            $i++;

            if ( $ch1 eq "\e" ) {
                # Collect the rest of this escape sequence.
                # CSI sequences are "\e[...", SS3 are "\eO..."
                # We read with a short timeout to collect the trailing bytes.
                my $seq = $ch1;
                if ( $i < length $bytes ) {
                    # More bytes already in buffer -- grab them
                    while ( $i < length $bytes ) {
                        my $c = substr( $bytes, $i, 1 );
                        $i++;
                        $seq .= $c;
                        last if $c =~ /[A-HJKLZcffhlm]/;    # common final bytes
                    }
                }
                else {
                    # Wait briefly for trailing bytes of the escape sequence.
                    # CSI sequences (\e[...) are typically 3-6 bytes.
                    Acme::Parataxis->await_read( $STDIN, 20 );
                    my $extra = '';
                    sysread( $STDIN, $extra, 8 );
                    $seq .= $extra;

                    # Drain any remaining queued bytes
                    while (1) {
                        Acme::Parataxis->await_read( $STDIN, 5 );
                        my $more = '';
                        my $n = sysread( $STDIN, $more, 8 );
                        last unless $n && $n > 0;
                        $seq .= $more;
                    }
                }

                # Map known sequences
                if    ( $seq eq "\e[A" )  { $ch->put( MsgKey("\e[A") ) }    # Up
                elsif ( $seq eq "\e[B" )  { $ch->put( MsgKey("\e[B") ) }    # Down
                elsif ( $seq eq "\e[C" )  { $ch->put( MsgKey("\e[C") ) }    # Right
                elsif ( $seq eq "\e[D" )  { $ch->put( MsgKey("\e[D") ) }    # Left
                elsif ( $seq eq "\e[H" )  { $ch->put( MsgKey("home") ) }    # Home
                elsif ( $seq eq "\e[F" )  { $ch->put( MsgKey("end")  ) }    # End
                elsif ( $seq =~ /^\e\[5~$/ )  { $ch->put( MsgKey("pgup") ) }
                elsif ( $seq =~ /^\e\[6~$/ )  { $ch->put( MsgKey("pgdn") ) }
                else { $ch->put( MsgKey($seq) ) }    # pass through for debugging
            }
            elsif ( $ch1 eq "\cC" ) {
                $ch->put( MsgKey("\cC") );
            }
            elsif ( $ch1 eq "\cD" ) {
                $ch->put( MsgQuit() );
                last;
            }
            else {
                $ch->put( MsgKey($ch1) );
            }
        }
    }
}

# -----------------------------------------------------------------------
# Fiber: terminal resize detection
# -----------------------------------------------------------------------

my $RESIZE_FLAG = 0;

sub resize_fiber ( $ch, $quit, $init_w, $init_h ) {
    my $prev_w = $init_w;
    my $prev_h = $init_h;

    if ( $^O eq 'MSWin32' ) {
        while ( !$quit->count ) {
            Acme::Parataxis->await_sleep(250);    # 4 Hz polling
            my ( $w, $h ) = get_terminal_size();
            if ( $w != $prev_w || $h != $prev_h ) {
                ( $prev_w, $prev_h ) = ( $w, $h );
                $ch->put( MsgResize( $w, $h ) );
            }
        }
    }
    else {
        $SIG{WINCH} = sub { $RESIZE_FLAG = 1 };

        while ( !$quit->count ) {
            Acme::Parataxis->await_sleep(250);    # 4 Hz polling
            if ($RESIZE_FLAG) {
                $RESIZE_FLAG = 0;
                my ( $w, $h ) = get_terminal_size();
                if ( $w != $prev_w || $h != $prev_h ) {
                    ( $prev_w, $prev_h ) = ( $w, $h );
                    $ch->put( MsgResize( $w, $h ) );
                }
            }
        }
    }
}

# -----------------------------------------------------------------------
# Fiber: periodic tick (1 Hz)
# -----------------------------------------------------------------------

sub tick_fiber ( $ch, $quit ) {
    my $count = 0;
    while ( !$quit->count ) {
        Acme::Parataxis->await_sleep(1000);
        $count++;
        $ch->put( MsgTick($count) );
    }
}

# -----------------------------------------------------------------------
# Main runtime
# -----------------------------------------------------------------------

async {
    enable_raw_mode();
    hide_cursor();

    my $messages = Acme::Parataxis::Channel->new( capacity => 64 );

    # Shared quit signal -- broadcast() wakes all fibers checking it
    my $quit = Acme::Parataxis::Signal->new( count => 0 );

    # Query initial terminal size
    my ( $init_w, $init_h ) = get_terminal_size();

    # Initial model
    my $model = {
        cursor  => 0,
        ticks   => 0,
        toggled => {},
        width   => $init_w,
        height  => $init_h,
        items   => [
            'Async I/O via thread pool',
            'Fibers with cooperative scheduling',
            'Nonblocking reads on STDIN',
            'Concurrent tick timers',
            'Channel-based message passing',
            'SIGWINCH resize support',
            'No Term::ReadKey dependency',
        ],
    };

    # Spawn concurrent fibers (use `fiber` -- it has the & prototype)
    fiber { input_fiber( $messages, $quit ) };
    fiber { tick_fiber( $messages, $quit ) };
    fiber { resize_fiber( $messages, $quit, $init_w, $init_h ) };

    # Event loop
    clear_screen();
    while (1) {
        my $msg = $messages->get();

        my $cmd;
        ( $model, $cmd ) = Update( $model, $msg );

        if ( $cmd && $cmd->{type} eq 'quit' ) {
            last;
        }

        # Render
        my $view = View($model);
        Acme::Parataxis->await_write( \*STDOUT, 50 );
        clear_screen();
        print $view;
    }

    # Cleanup: signal all fibers to exit, then restore terminal
    $quit->send();    # sets $count = true so all fiber loops see it
    $messages->shutdown();

    show_cursor();
    clear_screen();
    move_to( 1, 1 );
    disable_raw_mode();
    print "Goodbye!\r\n";

    Acme::Parataxis::stop();
};
