use v5.40;
no warnings 'experimental::class';
use feature 'class';

class Acme::Parataxis::Channel {
    field $capacity : param //= 2_000_000_000;
    field $sem_get = Acme::Parataxis::Semaphore->new( count => 0 );
    field $sem_put = Acme::Parataxis::Semaphore->new( count => $capacity - 1 );
    field @data : reader;

    method put ($value) {
        push @data, $value;
        $sem_get->up;
        $sem_put->down;
        1;
    }

    method get () {
        $sem_get->down;
        $sem_put->up;
        shift @data;
    }
    method size ()        { scalar @data }
    method shutdown ()    { $sem_get->adjust(1_000_000_000); 1 }
    method adjust ($diff) { $sem_put->adjust($diff) }
};
1;
