use v5.40;
use Test2::V1 -ipP;
use blib;
use Acme::Parataxis;
use HTTP::Tiny;
use IO::Socket::INET;
use Time::HiRes qw[time];
use POSIX       ();
$|++;
#
package Acme::Parataxis::Test::HTTP {
    use parent 'HTTP::Tiny';

    sub _open_handle {
        my ( $self, $request, $scheme, $host, $port, $peer ) = @_;
        my $handle = Acme::Parataxis::Test::HTTP::Handle->new(
            timeout     => $self->{timeout},
            SSL_options => $self->{SSL_options},
            verify_SSL  => $self->{verify_SSL},
        );
        return $handle->connect( $scheme, $host, $port, $peer );
    }

    sub request {
        my ( $self, $method, $url, $args ) = @_;
        $args //= {};
        my $orig_cb = $args->{data_callback};
        my $content = '';
        $args->{data_callback} = sub {
            my ( $data, $response ) = @_;

            # diag 'Progress: Received ' . length($data) . " bytes for $url";
            if ($orig_cb) {
                return $orig_cb->( $data, $response );
            }
            $content .= $data;
            return 1;
        };
        my $res = $self->SUPER::request( $method, $url, $args );
        $res->{content} = $content unless $orig_cb;
        return $res;
    }
}
{

    package Acme::Parataxis::Test::HTTP::Handle;
    use parent -norequire, 'HTTP::Tiny::Handle';

    sub _do_timeout {
        my ( $self, $type, $timeout ) = @_;
        $timeout //= $self->{timeout};
        if ( $self->{fh} ) {
            my $start = time();
            while (1) {

                # Immediate check using original select (0 timeout)
                return 1 if $self->SUPER::_do_timeout( $type, 0 );

                # Check for overall timeout
                return 0 if ( time() - $start ) > $timeout;

                # Suspend fiber and wait for background I/O check.
                # await_* submits a job and yields 'WAITING'.
                if ( $type eq 'read' ) {
                    Acme::Parataxis->await_read( $self->{fh}, 500 );
                }
                else {
                    Acme::Parataxis->await_write( $self->{fh}, 500 );
                }
            }
        }
        return $self->SUPER::_do_timeout( $type, 0 );
    }
}
Acme::Parataxis::run(
    sub {
        # Start a mock HTTP server in a fiber
        my $server_port = 0;
        my $listener    = IO::Socket::INET->new( LocalAddr => '127.0.0.1', Listen => 5, Reuse => 1, Blocking => 0 ) or
            die 'Could not create listener: ' . $!;
        $server_port = $listener->sockport;
        diag "Mock server listening on port $server_port";
        Acme::Parataxis->spawn(
            sub {
                while (1) {

                    # Wait for a client connection using non-blocking await
                    Acme::Parataxis->await_read( $listener, 1000 );
                    my $client = $listener->accept();
                    next unless $client;
                    $client->blocking(0);

                    # Respond with a simple HTTP 200
                    my $response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nHI";

                    # Cooperative write loop
                    my $offset = 0;
                    my $len    = length($response);
                    while ( $offset < $len ) {
                        Acme::Parataxis->await_write( $client, 1000 );
                        my $written = syswrite( $client, $response, $len - $offset, $offset );
                        if ( defined $written ) {
                            $offset += $written;
                        }
                        elsif ( $! != POSIX::EAGAIN && $! != POSIX::EWOULDBLOCK ) {
                            last;
                        }
                    }
                    $client->shutdown(1);    # Signal we are done writing
                    $client->close();
                }
            }
        );

        # Run multiple concurrent clients
        my $http = Acme::Parataxis::Test::HTTP->new( timeout => 2 );
        my @urls = ("http://127.0.0.1:$server_port/") x 3;
        my @futures;
        for my $url (@urls) {
            push @futures, Acme::Parataxis->spawn(
                sub {
                    my $res = $http->get($url);
                    return $res;
                }
            );
        }

        # Verify results
        for my $i ( 0 .. $#urls ) {
            my $res = $futures[$i]->await();
            is( $res->{status},  200,  'Request ' . ( $i + 1 ) . ' status is 200' );
            is( $res->{content}, 'HI', 'Request ' . ( $i + 1 ) . ' content is correct' );
        }
        $listener->close();
        Acme::Parataxis::stop();
    }
);
done_testing();
