use v5.40;
no warnings 'experimental::class', 'recursion';
use feature 'class';
#
class Acme::Parataxis::RateLimiter v0.1.1 {
    use Carp qw[croak];
    use Acme::Parataxis qw[fiber];
    use Acme::Parataxis::Semaphore;
    use Acme::Parataxis::Ticker;

    # A token bucket. The bucket is an ordinary Semaphore holding `burst` permits: acquire() is a `down`, so a fiber
    # with nothing left to spend parks through the usual _park path and inherits cancellation, with_timeout and
    # unregister-on-interrupt for free. A Card-6 Ticker fires `rate` times a second and the refill fiber puts exactly
    # one token back, but only while the bucket sits below its ceiling - so an idle limiter tops itself up to `burst`
    # and then stops, and a busy one hands out tokens at a steady `rate` per second forever.
    #
    # The Semaphore count therefore never needs a separate counter, and `Semaphore::adjust` already sizes its wake
    # budget to min(tokens added, waiters), so one refill wakes exactly one waiter and an empty bucket wakes nobody
    # until there is actually something to spend.
    field $rate  : reader : param;
    field $burst : reader : param;
    field $bucket;    # Semaphore: count is the tokens currently available, always 0 .. $burst
    field $ticker;    # Card-6 Ticker firing `rate` times a second
    field $running = false;
    ADJUST {
        croak 'RateLimiter->new( rate => $per_second ) requires a positive rate' unless defined $rate  && $rate > 0;
        croak 'RateLimiter->new( burst => $n ) requires a positive burst'        unless defined $burst && $burst >= 1;
        $bucket  = Acme::Parataxis::Semaphore->new( count => $burst );
        $ticker  = Acme::Parataxis::Ticker->new( interval => 1000 / $rate );
        $running = true;
        Acme::Parataxis::fiber {
            while ($running) {
                last unless $ticker->wait_next;
                $bucket->adjust(1) if $bucket->count < $burst;
            }
            ();
        };
    }

    # Take $n tokens, parking while the bucket cannot cover them and resuming as refills arrive. Must run inside a
    # scheduled fiber. An interrupted (timed-out or cancelled) acquire unregisters itself from the bucket through the
    # semaphore's own park dereg, so it is never woken later by a refill it no longer cares about.
    method acquire ( $n = 1 ) {
        my $fid = Acme::Parataxis->current_fid;
        croak 'acquire() must be called from inside a scheduled fiber' if $fid < 0;
        croak 'acquire($n) requires a positive integer' unless defined $n && $n =~ /\A[1-9][0-9]*\z/;
        croak 'RateLimiter has been stopped'            unless $running;
        $bucket->down('RateLimiter acquire') for 1 .. $n;
        1;
    }

    # Halt refills. Anyone already parked in acquire is let through rather than stranded (a stopped limiter must never
    # wedge the run), but a later acquire croaks instead of parking forever with nobody left to refill. Idempotent and
    # safe from inside or outside a fiber.
    method stop () {
        return 0 unless $running;
        $running = false;
        $ticker->stop;
        my $waiting = scalar $bucket->waiters;
        $bucket->adjust($waiting) if $waiting > 0;
        return 1;
    }
    method running () {$running}

    # Tokens currently available to spend (0 .. burst).
    method tokens () { $bucket->count }

    # Fibers currently parked waiting for a token.
    method waiters () { scalar $bucket->waiters }
    }
    #
    1;
