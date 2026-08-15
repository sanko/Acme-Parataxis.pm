use v5.40;
use blib;
use Acme::Parataxis qw[async fiber yield];
use Test2::V1 -ipP;
$|++;
#
diag 'Ported from Coro t/02_channel.t + eg/prodcons: producer/consumer message queues built on fibers.';
diag 'A bounded channel: get blocks while empty, put blocks while full - expressed with plain yield.';

package Acme::Parataxis::Test::Channel {
    sub new {
        my ( $class, $cap ) = @_;
        return bless { buf => [], cap => $cap || 0 }, $class;
    }
    sub put {
        my ( $self, $v ) = @_;
        while ( $self->{cap} && @{ $self->{buf} } >= $self->{cap} ) {
            Acme::Parataxis::yield();    # channel full: wait for a consumer
        }
        push @{ $self->{buf} }, $v;
    }
    sub get {
        my ($self) = @_;
        while ( !@{ $self->{buf} } ) {
            Acme::Parataxis::yield();    # channel empty: wait for a producer
        }
        return shift @{ $self->{buf} };
    }
    sub size { scalar @{ $_[0]{buf} } }
}

package main;

subtest 'Single producer, single consumer (capacity 1, rendezvous)' => sub {
    my $q = Acme::Parataxis::Test::Channel->new(1);
    my @got;
    async {
        fiber { $q->put($_) for 1 .. 9 };    # producer
        push @got, $q->get for 1 .. 9;       # consumer
    };
    is( join( q{,}, @got ), '1,2,3,4,5,6,7,8,9', 'items arrive in order' );
    is( $q->size, 0, 'channel fully drained' );
};

subtest 'Capacity limit blocks the producer' => sub {
    my $q = Acme::Parataxis::Test::Channel->new(3);
    my @got;
    my $max_seen = 0;
    async {
        my $p = fiber {
            for ( 1 .. 10 ) {
                $q->put($_);
                $max_seen = $q->size if $q->size > $max_seen;
            }
        };
        push @got, $q->get for 1 .. 10;
    };
    is( $max_seen, 3, 'buffer never exceeds capacity' );
    is( join( q{,}, @got ), '1,2,3,4,5,6,7,8,9,10', 'all items delivered' );
};

subtest 'Multiple producers, one consumer (like eg/prodcons)' => sub {
    my $q = Acme::Parataxis::Test::Channel->new(4);
    my @got;
    async {
        fiber { $q->put("p1-$_") for 1 .. 5 };
        fiber { $q->put("p2-$_") for 1 .. 5 };
        push @got, $q->get for 1 .. 10;
    };
    is( scalar @got, 10, 'consumer received everything' );
    is( join( q{,}, sort @got ),
        'p1-1,p1-2,p1-3,p1-4,p1-5,p2-1,p2-2,p2-3,p2-4,p2-5',
        'all messages present, none lost or duplicated'
    );
};
done_testing();
