use v5.40;
no warnings 'experimental::class';
use feature 'class';

class Acme::Parataxis::Semaphore {
    field $count : reader : param //= 1;
    field @waiters : reader;    # fiber ids in FIFO order and re-enqueued via the scheduler when woken

    method _block_until_available () {    # Park the current fiber until a permit is available then recheck the count
        while ( $count <= 0 ) {
            push @waiters, Acme::Parataxis->current_fid;
            Acme::Parataxis->yield('WAITING');
        }
        1;
    }

    method down () {
        $self->_block_until_available;
        $count--;
        1;
    }

    method try () {
        return 0 if $count <= 0;
        $count--;
        1;
    }

    method up () {
        $count++;
        Acme::Parataxis::_scheduler_enqueue_by_id( shift @waiters ) if $count > 0 && @waiters;
        1;
    }

    method adjust ($diff) {
        $count += $diff;
        my $n       = $count;
        my $waiting = scalar @waiters;
        $n = $waiting if $waiting < $n;
        Acme::Parataxis::_scheduler_enqueue_by_id( shift @waiters ) while $n-- > 0;
        1;
    }
    method wait () { $self->_block_until_available }

    method guard () {
        $self->down;
        Acme::Parataxis::Semaphore::Guard->new( semaphore => $self );
    }
};

class Acme::Parataxis::Semaphore::Guard {    # Util
    field $semaphore : param;

    method DESTROY {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        $semaphore->up;
    }
};
1;
