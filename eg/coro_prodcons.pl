{
    use v5.40;
    use blib;
    use Acme::Parataxis qw[async fiber yield];

    # A bounded channel built from fibers - the classic producer/consumer
    # demonstration first popularised by Coro (eg/prodcons). "get" blocks
    # while the channel is empty, "put" blocks while it is full; both just
    # cede control to other fibers.
    package ProdCons::Channel {
        sub new {
            my ( $class, $cap ) = @_;
            return bless { buf => [], cap => $cap || 0 }, $class;
        }
        sub put {
            my ( $self, $v ) = @_;
            while ( $self->{cap} && @{ $self->{buf} } >= $self->{cap} ) {
                Acme::Parataxis::yield();
            }
            push @{ $self->{buf} }, $v;
        }
        sub get {
            my ($self) = @_;
            while ( !@{ $self->{buf} } ) {
                Acme::Parataxis::yield();
            }
            return shift @{ $self->{buf} };
        }
        sub size { scalar @{ $_[0]{buf} } }
    }

    package main;

    my $chan = ProdCons::Channel->new(4);

    async {
        # Producers
        fiber {
            $chan->put("apple-$_") for 1 .. 4;
        };
        fiber {
            $chan->put("pear-$_") for 1 .. 4;
        };

        # Consumer
        for ( 1 .. 8 ) {
            my $item = $chan->get;
            say "consumed $item (queue now " . $chan->size . ')';
        }
    };

    say 'done';
}
