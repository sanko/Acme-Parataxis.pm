# NAME

Acme::Parataxis - Perl Coroutines Using Real OS Fibers via FFI

# SYNOPSIS

```perl
use v5.40;
use Acme::Parataxis qw[:all];
$|++;

async {
    say 'Main task started';

    my $f1 = fiber {
        say '  Task 1: Sleeping...';
        await_sleep(1000);
        return 'Coffee!';
    };

    my $f2 = fiber {
        say '  Task 2: Calculating... (simulated CPU work)';
        my $sum = 0;
        for ( 1 .. 100 ) {
            $sum += $_;
            maybe_yield();    # Be a good neighbor
        }
        say '  Task 2: Complete. Will return ' . $sum;
        return $sum;
    };

    # 'await' works on fibers and futures
    say 'Result 1: ' . await($f1);
    say 'Result 2: ' . await($f2);
};
```

# DESCRIPTION

`Acme::Parataxis` implements a hybrid concurrency model for Perl, greatly inspired by the concurrency system for the
[Wren](https://wren.io/concurrency.html) programming language. It combines cooperative multitasking (fibers) with a
preemptive native thread pool.

Fibers are modern hardware's mechanism for lightweight concurrency. They are similar to threads but are cooperatively
scheduled. While the OS may switch between threads at any time, a fiber only passes control when explicitly told to do
so. This makes concurrency deterministic and easier to reason about. You (probably) don't have to worry about random
context switches clobbering your data. Each fiber has its own stack and context, but they don't use OS thread
resources. You can easily create thousands of them without stalling your system.

While this module lives in the `Acme::` namespace due to its highly experimental origins (it manually manipulates
Perl's internal stacks and C context via FFI), it is designed to be a robust and highly functional concurrency
framework.

# Core Concepts

## Creating Fibers

All Perl code in this system runs within a fiber. When you start your script or call `Acme::Parataxis::run`, a "main"
fiber is active. You can create new fibers using `spawn` or by manually instantiating an `Acme::Parataxis` object:

```perl
my $fiber = Acme::Parataxis->new(code => sub {
    say "I'm in a fiber!";
});
```

Creating a fiber does not run it immediately. It simply prepares the context and waits to be invoked.

## Invoking Fibers

To run a fiber, you "call" it. This suspends the current fiber and executes the called one until it finishes or yields.

```
$fiber->call();
```

When the called fiber finishes, control returns to the fiber that called it. It is an error to call a fiber that is
already done.

## Yielding

Yielding is the "secret sauce" of fibers.

A yielded fiber passes control back to its caller but remembers its exact state, including all variables and the
current instruction pointer. The next time it's called, it resumes exactly where it left off.

```
Acme::Parataxis->yield();
```

## Communication (Passing Values)

Fibers can pass data back and forth through `call` and `yield`:

- **Resuming with a value**: Arguments passed to `$fiber->call(@args)` are returned by the `yield()` call that
suspended the fiber.
- **Yielding with a value**: Arguments passed to `Acme::Parataxis->yield(@args)` are returned to the caller by
the `call()` that resumed the fiber.

## Full Coroutines

Fibers in Parataxis are "full coroutines." This means they can suspend from anywhere in the callstack. You can call
`yield()` from deeply nested functions, and the entire fiber stack will be suspended until the fiber is resumed.

## Transferring Control

While `call()` and `yield()` manage a stack-like chain of execution, `transfer()` provides an unstructured way to
switch between fibers. When you transfer to a fiber, the current one is suspended, and the target fiber resumes. Unlike
`call()`, transferring does not establish a parent/child relationship. It's more like a `goto` for execution
contexts.

```
$other_fiber->transfer();
```

## Fibers vs. Threads

In Parataxis, your Perl code always runs on a single OS thread. However, when you call an `await_*` function, the
current fiber is suspended, and the actual blocking work is performed on a **different** OS thread in a native pool.
Once the task completes, your fiber is automatically queued for resumption on the main thread.

# API

While the classic object-oriented API is always available, `Acme::Parataxis` exports a set of functions (via the
`:all` tag) that provide a more modern, concise way to write concurrent code.

## `async { ... }`

A convenience wrapper around `run()`. It starts the scheduler, executes the provided block as the main fiber, and
automatically calls `stop()` when the block completes.

```
async {
    say "The scheduler is running!";
};
```

## `fiber { ... }`

An alias for `spawn()`. It creates a new fiber and returns an `Acme::Parataxis` fiber object that can be awaited with
`await()` or `->await()`, and also provides Future-style methods (`result`, `on_ready`).

```perl
my $f = fiber {
    say "Hello from fiber!";
};
```

## `await( $thing )`

A generic await function. It accepts either an `Acme::Parataxis` fiber object or an `Acme::Parataxis::Future` and
suspends the current fiber until the target is ready.

```perl
my $result = await($f);
```

## `await_sleep( $ms )`

Suspends the current fiber for `$ms` milliseconds. This is a non-blocking operation that allows other fibers to run
while the current one is paused.

```
async {
    say "Taking a nap...";
    await_sleep(1000);
    say "I'm awake!";
};
```

## `await_read( $fh, $timeout = 5000 )`

Suspends the current fiber until the provided filehandle is ready for reading, or the timeout is reached.

```perl
async {
    await_read($socket);
    my $data = <$socket>;
    say "Received: $data";
};
```

## `await_write( $fh, $timeout = 5000 )`

Suspends the current fiber until the provided filehandle is ready for writing, or the timeout is reached.

```
async {
    await_write($socket);
    syswrite($socket, $message);
};
```

## `await_core_id()`

Returns the ID of the CPU core currently executing the background task. This is a non-blocking operation that offloads
the request to the thread pool and suspends the fiber until the result is ready.

```perl
async {
    my $core = await_core_id();
    say "Background task handled by CPU core: $core";
};
```

# Cancellation

Cooperative cancellation is built on three pieces: a deadline helper (`with_timeout`), a token you can hand out
(`Acme::Parataxis::CancellationToken`), and a pair of exceptions that both of them raise.

## `with_timeout( $ms, [ $token, ] $code )`

Runs `$code` in a child fiber and makes sure it finishes within `$ms` milliseconds. Calls from outside the scheduler
croak. When the deadline trips, `with_timeout` throws
[`Acme::Parataxis::Error::Timeout`](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AError%3A%3ATimeout) in the calling fiber; the child fiber and
anything it was blocked on are cleaned up and the scheduler keeps running.

If you pass an optional [`Acme::Parataxis::CancellationToken`](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ACancellationToken), that token can
cancel the block early, in which case `Acme::Parataxis::Error::Cancelled` is thrown instead. A pre-cancelled token
fails fast without running `$code` at all. With no token, the deadline alone is used; a bound of `0` means no
deadline.

```perl
async {
    my $value = eval { with_timeout( 250, sub { $client->request } ) }
        or die 'request timed out';

    my $cancel = Acme::Parataxis::CancellationToken->new;
    fiber { sleep 1; $cancel->cancel } ;
    eval { with_timeout( 10_000, $cancel, sub { $worker->run } ) }
        or die 'worker cancelled';
};
```

## `Acme::Parataxis::CancellationToken`

See [Acme::Parataxis::CancellationToken](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ACancellationToken): `register`, `unregister`, `cancel`, `cancelled`, `kind`, `waiters`.

## What gets thrown

Both `with_timeout` and a cancelled token interrupt a blocking wait by throwing an exception into the parked fiber at
its park site. The two classes, both subclasses of `Acme::Parataxis::Error`, are:

- [`Acme::Parataxis::Error::Timeout`](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AError%3A%3ATimeout) - kind `'timeout'`, thrown when a
deadline expires.
- [`Acme::Parataxis::Error::Cancelled`](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AError%3A%3ACancelled) - kind `'cancelled'`, thrown when a
token fires.

Both expose `message()` and `wait_reason()`; `wait_reason()` returns `[ reason, file, line ]` describing the wait
that was interrupted (see the `wait_reason` section). A fiber that dies while another fiber is awaiting it no longer
kills the whole run: the error is delivered to the awaiting fiber's `await` call instead.

## Bare `nursery( sub ($n) { ... } )`

`nursery( )` is Acme::Parataxis's structured-concurrency block ([Acme::Parataxis::Nursery](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ANursery)). Everything you
`-`spawn> inside it is a child of that block: `nursery( )` does not return until every child is done, the moment any
child fails **all** of its siblings are cancelled and drained before it returns, and the block value (when successful)
is whatever the block returned.

```perl
async {
    nursery( sub ($n) {
        $n->spawn( sub { await_sleep( 50 ); $s1_done = 1 } );
        $n->spawn( sub { await_sleep( 50 ); $s2_done = 1 } );
        $n->spawn( sub { die 'boom' } );    # cancels its siblings, then the nursery rethrows
    } );
};
```

On failure the aggregate croaks with [`Acme::Parataxis::Error::Nursery`](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AError%3A%3ANursery):
`-`failures> lists every child's error (the real one plus the `Cancelled` unwinds of the siblings it cancelled) and
`-`primary> is the first real failure. A block error is rethrown unchanged after the children are drained; a
user-fibre token can cancel the whole group (call `-`token->cancel>), and cancellation propagates into nested waits
and tokens (M4 subtest 6, [Acme::Parataxis::with\_timeout](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3Awith_timeout)) via the `_join`
parent-interrupt branch. Children are not adopted by a nested nursery in the same block - they are owned by the nursery
they were spawned into and the inner nursery's `_join` awaits them as long as they stay registered.

# Scheduler Functions

The following functions are the primary interface for the integrated cooperative scheduler.

## `run( $code )`

Starts the event loop and executes `$code` as the initial fiber. The loop continues to run as long as there are active
fibers or pending background tasks.

```perl
Acme::Parataxis::run(sub {
    say 'The scheduler is running!';
});
```

## `spawn( $code )`

Creates a new fiber and runs it. Returns an `Acme::Parataxis` fiber object that can be awaited with `await()` or `->await()` and will eventually contain the fiber's return value.

```perl
my $future = Acme::Parataxis->spawn(sub {
    return 'Hello from fiber #' . Acme::Parataxis->current_fid;
});
```

## `yield( @args )`

Pauses the current fiber and returns control to the scheduler. If `@args` are provided, they are passed to the context
that next resumes this fiber. Arguments can be of any Perl data type.

## `$fiber->priority( [ $prio ] )`

Get or set the scheduler priority of a fiber, Coro-style. Higher numbers are resumed first; fibers with equal priority
keep the FIFO order they were enqueued in. The default priority is 0. Setting the priority of a fiber that is already
queued immediately moves it to its new position in the run queue.

```perl
my $fast = Acme::Parataxis->spawn(sub { ... });
$fast->priority(10);   # runs before any priority-0 fiber
```

## `stop()`

Tells the scheduler to exit the loop after the current iteration. Note that this does not immediately terminate other
fibers; it simply prevents the scheduler from starting new ones.

## `on_wake( $code )`

Register a callback to run the next time the current fiber is resumed from a blocking wait. The callback receives the
fiber object as its only argument. Call it immediately before the call that will block the fiber (`await_sleep`, a
semaphore `down`, `Signal->wait`, a Channel `get`/`put`, an `await`); it fires exactly once, when that wait
completes, and is cleared afterwards.

```perl
fiber {
    Acme::Parataxis->on_wake(sub ($f) { say "Woke up! fid=" . $f->fid });
    await_sleep(500);
};
```

## Fiber-local storage

See [Acme::Parataxis::Local](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ALocal). A `Local` object is one per-fiber slot: each fiber reads and writes its own copy,
isolated from siblings and the main fiber, and the value is untouched by `yield` or `await`. It follows the fiber,
not the dynamic scope.

```perl
my $span = Acme::Parataxis::Local->new;
async {
    $span->set('request-121');
    fiber { say $span->get };   # undef/default - a new fiber starts empty
    say $span->get;             # 'request-121'
};
```

Hooks fire in registration order, before the fiber itself resumes, from scheduling context. They must not block or park
the fiber. If the fiber is never actually parked, the hook is silently dropped.

## Event-loop drivers

By default `await_read`/`await_write`/`await_sleep` submit work to the OS worker pool. Attaching an existing event
loop instead lets that loop own readiness (epoll/kqueue/IOCP come for free) while Parataxis keeps its scheduler, fibers
and parks unchanged. Two reference drivers ship with the distribution:
[Acme::Parataxis::Driver::Mojo](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ADriver%3A%3AMojo) (`Mojo::IOLoop`) and
[Acme::Parataxis::Driver::IOAsync](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ADriver%3A%3AIOAsync) (`IO::Async::Loop`).

- `Acme::Parataxis->attach_loop( $loop )` - wrap `$loop` in a driver and make it current. Returns the
driver that was attached before (so the first attach returns a false value). Croaks on a non-object and while a run
is active.
- `Acme::Parataxis->detach_loop()` - drop the current driver, unwinding every watch and timer it still
held, and return it. Safe to call when nothing is attached.
- `Acme::Parataxis->loop()` - the currently attached driver, or a false value while the worker-pool path
is in effect.

While a loop is attached, `run` hands the processor to the loop whenever every fiber is parked; the loop's callbacks
only enqueue fibers, never run them, so the scheduler cannot be re-entered. The public contract of the `await_*`
family is unchanged - readiness still reports the pool path's values, a timeout still resumes `-1`, and an enclosing
`with_timeout`/`nursery` still throws. Keep a driver session short: attach, run, detach.

```perl
Acme::Parataxis->attach_loop( Mojo::IOLoop->new );
Acme::Parataxis::run( sub { await_read( $fh, 2000 ) } );
Acme::Parataxis->detach_loop;
```

## Sync primitives

The [Acme::Parataxis::Sync](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync) family gives cooperative fibers the classic synchronization tools, all built on the same
park/wake machinery as everything else:

- [Acme::Parataxis::Sync::Mutex](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync%3A%3AMutex) - a non-reentrant lock with true owner tracking
(`lock`, `try_lock`, `unlock`, `guard`); releasing from a non-owner croaks.
- [Acme::Parataxis::Sync::RwLock](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync%3A%3ARwLock) - a writer-preferring read/write lock: any number
of readers xor one writer, with `read_lock`/`write_lock` and matching guards. Once a writer is queued, new readers
are held back so a steady read stream cannot starve writers.
- [Acme::Parataxis::Sync::WaitGroup](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync%3A%3AWaitGroup) - a job counter; `add`/`done` adjust it and
`wait` parks until it reaches zero.
- [Acme::Parataxis::Sync::Barrier](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync%3A%3ABarrier) - `$n` parties meeting via `arrive_and_wait`;
all proceed at the phase boundary, and the barrier re-arms for the next round.
- [Acme::Parataxis::Sync::Once](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASync%3A%3AOnce) - an initializer run exactly once across racing
fibers; late callers wait for the runner instead of re-running the action.

Every one of these waits is a scheduled park, so `with_timeout` and cancellation tokens abort it cleanly and the
waiter unregisters itself from the primitive first. Example:

```perl
async {
    my $m = Acme::Parataxis::Sync::Mutex->new;
    with_timeout( 200, sub { $m->lock } );   # a timeout instead of a forever-wait
};
```

## `Ticker`

[Acme::Parataxis::Ticker](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ATicker) is a drift-free interval timer. A `while (1) { do_work(); await_sleep($ms) }` loop runs
every `$ms` _plus_ however long `do_work` took, so it slides later and later; a `Ticker` measures every period
against an absolute tick boundary and sleeps only the remainder, so ticks land on the boundary:

```perl
my $tick = Acme::Parataxis::Ticker->new( interval => 1000 );
while ( my $t = $tick->wait_next ) { do_work() }    # every 1000ms, whatever do_work costs
```

A background fiber publishes each tick into a capacity-1 [Acme::Parataxis::Channel](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AChannel) after draining anything
unread, so at most one tick is ever outstanding and it is always the newest: a slow consumer silently loses whole
periods instead of queueing a stale backlog. `stop` releases any fiber parked in `wait_next` with `undef`,
interrupts the ticker fiber, and recalls the sleep job it armed, so a stopped ticker never keeps `run` alive or
leaves a fiber behind.

## `RateLimiter`

[Acme::Parataxis::RateLimiter](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ARateLimiter) is a token bucket for
apps that hit rate-limited APIs. The bucket starts holding `burst` tokens, every request spends one, and a background
refill puts tokens back at `rate` per second; when the bucket runs dry, `acquire` parks the calling fiber and hands it
a token the moment one comes free:

```perl
my $rl = Acme::Parataxis::RateLimiter->new( rate => 5, burst => 10 );
for ( 1 .. 1000 ) { fiber { $rl->acquire(1); fetch_url(...) } }
```

The bucket is an ordinary [Acme::Parataxis::Semaphore](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3ASemaphore), so
`acquire` is a plain `down` and inherits the scheduler's whole park path for free: a blocked acquire is interruptible
by `with_timeout` and cancellation tokens, unregisters itself when interrupted, and never busy-waits. Refills come
from a `Ticker` firing `rate` times a second, each tick returning exactly one token and only while the bucket sits
below its ceiling, so nothing accumulates while the limiter sits idle.

`burst` decides how smooth the traffic looks. With `burst = 1` requests are spaced strictly evenly and even the first
one waits its turn; a larger `burst` lets the first `burst` requests through immediately before the limiter settles
to exactly `rate` per second. Over any window no more than `rate x window + burst` requests get through, so a bigger
`burst` never raises the long-run average - it only decides how much of it can arrive at once. See the perldoc's
`BURST VS. STRICT RATE` section for how to choose it.

# Thread Pool Configuration

`Acme::Parataxis` uses a native thread pool to handle blocking tasks. While it manages itself automatically, you can
tune its behavior using these functions.

## `set_max_threads( $count )`

Sets the maximum number of worker threads the pool is allowed to spawn. By default, this is set to the number of
logical CPU cores detected on your system (up to a hard limit of 64).

```
# Limit the pool to 4 threads
set_max_threads(4);
```

## `max_threads()`

Returns the currently configured maximum thread pool size.

# Manual Fiber Management

Advanced users can manage context switching themselves without using the integrated scheduler.

## `new( code => $sub )`

Instantiates a new fiber. The `code` argument must be a subroutine reference.

```perl
my $fiber = Acme::Parataxis->new(code => sub {
    my $arg = Acme::Parataxis->yield("Initial data");
    return "Done with $arg";
});
```

## `call( @args )`

Explicitly switches control to the fiber and passes `@args`. Arguments can be scalars, hash/array references, or
objects. This establishes a parent/child relationship: when the fiber yields or completes, control returns to the
caller.

## `transfer( @args )`

A "symmetric" switch. Suspends the current context and moves directly to the target fiber. No parent/child relationship
is established. Like `call`, it supports passing arbitrary Perl data via `@args`.

# Preemption

If you really must interrupt the normal flow of things, these functions will come in handy.

## `maybe_yield()`

Increments an internal operation counter for the current fiber. If the counter reaches the threshold set by
`set_preempt_threshold`, the fiber automatically yields.

```perl
while (my $row = $sth->fetch) {
    process($row);
    Acme::Parataxis->maybe_yield(); # Cooperatively prevent starvation
}
```

## `set_preempt_threshold( $val )`

Sets the number of `maybe_yield` increments before a forced yield occurs. Default is 0 (preemption disabled).

# Class Methods

## `tid()`

Returns the unique OS Thread ID of the main interpreter thread.

## `current_fid()`

Returns the unique numeric ID of the currently executing fiber, or -1 if called from the "root" (main) context.

## `root()`

Returns a proxy object representing the initial execution context. This is useful for `transfer()`ing control back to
the main thread from a symmetric coroutine.

## `fid()`

Returns the unique numeric ID of the fiber object.

## `is_done()`

Returns true if the fiber has finished execution (either by returning or dying). Once a fiber is done, its internal ID
is released and it can no longer be called.

## `$fiber->wait_reason()`

While a fiber is suspended inside a blocking wait (`await_sleep`, `await`, `await_read`, a semaphore `down`, a
`Signal->wait`, a Channel `get`/`put`, or a busy `wait` for a child), returns a 3-element arrayref recording
how it parked: `[ $reason, $file, $line ]` where `$reason` is a short label and `$file`/`$line` are the caller's
location that entered the wait. Returns `undef` for a fiber that is running, finished, or merely cooperatively
yielded.

```perl
my $r = $fiber->wait_reason;    # e.g. [ 'Semaphore down', 'worker.pl', 42 ]
```

This is read-only diagnostic metadata; workers waiting on the same primitive are unaffected by it.

# Integrating with Synchronous Code

To use synchronous modules (like `HTTP::Tiny`) in a non-blocking way, you can subclass their handle or transport
methods and use a `while` loop combined with `yield('WAITING')`. This ensures the fiber yields control until the
underlying I/O is ready.

```perl
# Example: A cooperative HTTP::Tiny subclass
{
    package My::HTTP;
    use parent 'HTTP::Tiny';
    sub _open_handle {
        my ($self, $request, $scheme, $host, $port, $peer) = @_;
        return My::HTTP::Handle->new(
            timeout            => $self->{timeout},
            keep_alive         => $self->{keep_alive},
            keep_alive_timeout => $self->{keep_alive_timeout}
        )->connect($scheme, $host, $port, $peer);
    }
    sub request {
        my ($self, $method, $url, $args) = @_;
        my %new_args = %{ $args // {} };
        my $orig_cb = $new_args{data_callback};
        my $content = '';
        $new_args{data_callback} = sub {
            my ($data, $response) = @_;
            if ($orig_cb) { return $orig_cb->($data, $response) }
            $content .= $data;
            return 1;
        };
        my $res = $self->SUPER::request($method, $url, \%new_args);
        $res->{content} = $content unless $orig_cb;
        return $res;
    }
}
{
    package My::HTTP::Handle;
    use parent -norequire, 'HTTP::Tiny::Handle';
    use Time::HiRes qw[time];
    sub _do_timeout {
        my ($self, $type, $timeout) = @_;
        $timeout //= $self->{timeout} // 60;
        my $start = time;
        while (1) {
            # Check for readiness NOW (0 timeout)
            return 1 if $self->SUPER::_do_timeout($type, 0);
            # Check for overall timeout
            my $elapsed = time - $start;
            return 0 if $elapsed > $timeout;
            # Suspend fiber and wait for background I/O check
            my $wait = ($timeout - $elapsed) > 0.5 ? 0.5 : ($timeout - $elapsed);
            if ($type eq 'read') {
                Acme::Parataxis->await_read($self->{fh}, int($wait * 1000));
            } else {
                Acme::Parataxis->await_write($self->{fh}, int($wait * 1000));
            }
        }
    }
}
```

# Examples

These are useful samples that should be modules in their own right but find their home here in documentation instead
for now.

## Cooperative Parallelism

This example demonstrates how to perform multiple HTTP requests concurrently on a single interpretation thread.

```perl
use Acme::Parataxis;
# ... (See My::HTTP implementation above) ...

Acme::Parataxis::run(sub {
    my $http = My::HTTP->new(verify_SSL => 0);
    my @urls = qw[http://example.com http://perl.org];

    # Spawn tasks for each URL
    my @futures = map {
        my $url = $_;
        Acme::Parataxis->spawn(sub { $http->get($url)->{status} })
    } @urls;

    # Collect results as they become ready
    say "Status for $urls[$_]: " . $futures[$_]->await() for 0..$#urls;
});
```

## Symmetric Producer/Consumer

A low-level example of passing control sideways between fibers.

```perl
my ($p, $c);

$p = Acme::Parataxis->new(code => sub {
    for my $item (qw[Apple Banana Cherry]) {
        say "Producer: Sending $item";
        $c->transfer($item);
    }
    $c->transfer('DONE');
});

$c = Acme::Parataxis->new(code => sub {
    my $item = Acme::Parataxis->yield(); # Initial wait
    while (1) {
        last if $item eq 'DONE';
        say "Consumer: Eating $item";
        $item = $p->transfer();
    }
});

$c->call(); # Prime consumer
$p->call(); # Start producer
```

## Futures

A common pattern for lightweight concurrency abstractions.

```perl
use Acme::Parataxis::Future;

my $future = Acme::Parataxis::Future->new;

# Register a callback
$future->on_ready(sub ($f) {
    say 'Result: ' . $f->result;
});

# Set the result (from another fiber)
$future->set_result(42);

# Await in a fiber (suspends until ready)
my $value = $future->await;
```

A future represents a value that will be available at some point in the future. Futures are used to coordinate between
fibers: one fiber produces a result via `set_result` or `set_error`, and one or more consumers retrieve it via
`result` or `await`.

## Semaphore

A simple integer counter that optionally blocks fibers when it reaches zero. There is no owner associated with a
semaphore, so one fiber can `down` it while another can `up` it, `up` may be called before `down`, and so on.

Blocked fibers are parked (they do not busy-wait) and are resumed in FIFO order as permits become available, exactly
like the futures used by `await`.

```perl
use Acme::Parataxis;
use Acme::Parataxis::Semaphore;

my $sem = Acme::Parataxis::Semaphore->new;   # unlocked by default

async {
    fiber { $sem->down };   # wait for a signal
    $sem->up;
};
```

## Channels

A simple message queue that allows you to send and receive data. If the channel is full, writers block; if it is empty,
readers block. Both ends can be used by as many fibers as you want concurrently.

A channel of size `1` is a rendezvous point (no buffering: `put` waits for a matching `get`); to buffer one element
use size `2`, and so on.

```perl
use Acme::Parataxis;
use Acme::Parataxis::Channel;

my $q = Acme::Parataxis::Channel->new( 4 );

async {
    fiber { $q->put( $_ ) for 1 .. 8 };      # producers
    say $q->get for 1 .. 8;                  # consumer
};
```

## Signals

An object with a two-state flag and a FIFO queue of waiters. A fiber parked in `wait` does not busy-wait; it is
resumed by the scheduler when the signal fires.

```perl
use Acme::Parataxis;
use Acme::Parataxis::Signal;

my $sig = Acme::Parataxis::Signal->new;

async {
    fiber { $sig->wait; say 'I rise!' };
    $sig->send;
};
```

## Lazy Iterators

An [Acme::Parataxis::Generator](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AGenerator) is a stackful, lazily-pulled sequence: the body runs in a private fiber and `yield`s
values one at a time, each `->next` resuming it from where it left off. The fiber never enters the scheduler run
queue, so the body is plain synchronous code and the generator works from any fiber or from the main context.

```perl
use Acme::Parataxis::Generator;

my $fib = Acme::Parataxis::Generator->new( sub ($y) {
    my ( $a, $b ) = ( 0, 1 );
    while ( $a < 100 ) {
        $y->($a);
        ( $a, $b ) = ( $b, $a + $b );
    }
} );

while ( defined( my $n = $fib->next ) ) { say $n }   # 0 1 1 2 3 5 ...
```

## Actors

An [Acme::Parataxis::Actor](https://metacpan.org/pod/Acme%3A%3AParataxis%3A%3AActor) is a fiber that owns a mailbox and runs one handler per message, with request/reply built
in. `ask( $msg )` returns a future that resolves with the handler's return value (or fails with its error); `send` is
fire-and-forget.

```perl
use Acme::Parataxis::Actor;

my $echo = Acme::Parataxis::Actor->spawn( sub ($self, $msg) {
    return ref $msg ? uc( $msg->{text} ) : "unknown: $msg";
} );

my $reply = $echo->ask( { text => 'hello' } );
say $reply->await;        # HELLO
$echo->send( 'log' );
$echo->stop;
```

Because the mailbox is a bounded channel, slow handlers provide backpressure to senders, and `ask` works with
`with_timeout` and cancellation just like any other block. Supervision (restart-on-failure, OTP-style) is out of
scope; a handler die fails its own ask (or warns, for a `send`) and the actor keeps going.

## Diagnostics

Every fiber that parks in a wait records where and why (M0's wait\_reason), and `dump_fibers` exposes it: each live
fiber with its state (`WAITING` / `READY` / `RUNNING` / `RUNNABLE`) and, when parked, the wait reason together with
the source site where it yielded.

```perl
my $fibers = Acme::Parataxis->dump_fibers;       # data only
Acme::Parataxis->dump_fibers( \*STDERR );        # also print a human-readable report
```

`dump_fibers()` returns an arrayref of `{ fid, state, reason => [ reason, file, line ] }` records. It is safe to
call at any time, including top level; outside a run it reports fibers leaked by an earlier deadlocked run. The
scheduler's fatal deadlock message ("no runnable work and no outstanding jobs") is the same report, listing every
parked fiber of the deadlocked run with its reason and site.

# Best Practices & Gotchas

- **Avoid Blocking Syscalls**: Never call blocking `sleep()` or `sysread()` on the main interpretation thread. Always use the `await_*` equivalents to offload work to the pool.
- **Thread Safety**: While Perl code remains single-threaded, background tasks run on separate OS threads. Shared C-level data (if accessed via FFI) must be mutex-protected.
- **Stack Limits**: Each fiber is allocated a virtual stack backed by mmap with a guard page. Physical memory is only consumed for pages the fiber actually touches, so this is cheap even for thousands of fibers. On Linux and FreeBSD the reservation is 64MB and made with \`MAP\_NORESERVE\`; on macOS (which has no \`MAP\_NORESERVE\`, so every mapping counts against the process memory budget) the reservation is 8MB -- still ample for deep recursion.
- **Efficiency**: The native thread pool is initialized dynamically upon the first asynchronous request. It starts with a small "seed" pool and grows on demand up to the configured limit. Worker threads use condition variables to sleep efficiently when idle, ensuring near-zero CPU usage when no background tasks are pending.
- **Reference Cycles**: Be careful when passing fiber objects into their own closures, as this can create memory leaks.

# Gory Technical Details

## Architectural Inspiration

The core concurrency model in Parataxis is heavily inspired by the **Wren** programming language, specifically its
treatment of fibers as the primary unit of execution and its deterministic cooperative scheduling.

## Stack Virtualization

On Unix-like systems, we use `ucontext.h` to manage stack and register state. On Windows, we leverage the native
`Fiber API`. In both cases, we perform heart surgery on the Perl interpreter by manually teleporting its internal
global pointers (the `PL_*` variables) between contexts.

## Shared CVs and Pad Virtualization

A significant challenge in Perl green threads is the shared nature of PadLists and the global `CvDEPTH` counter. In
debug builds of Perl, calling a shared subroutine from multiple fibers can trigger internal assertions (like
`AvFILLp(av) == -1` and `!AvREAL(av)`). Parataxis includes a specialized workaround that surgically prepares the next
landing pad before every context switch, restoring each `@_` slot to Perl's canonical REIFY-only, empty state, to
satisfy these assertions without clobbering active lexical state.

## `eval` vs. `try/catch`

While `feature 'try'` is available in modern Perl, manually teleporting interpreter state can occasionally confuse the
compiler's expectations for stack unwinding. Standard `eval { ... }` remains the most predictable way to handle
exceptions within fibers.

## Signal Handling

Not to be confused with `Acme::Parataxis::Signal`, true OS-level signals (like `SIGINT`) are delivered to the main
process thread. Perl handles these at 'safe points,' which in this module typically occur during a context switch
(yield, transfer, or call). If you receive an OS signal while a fiber is suspended, it will generally be processed when
the fiber is resumed and hits its next internal Perl opcode.

## The 'Final Transfer' Requirement

In a symmetric coroutine model (using `transfer()`), fibers don't have a natural 'parent' to return to. I've added
fallback logic to return to the `last_sender` or the main thread on exit, but it's good practice to explicitly
`transfer()` back to a partner fiber or the `root()` context to ensure your application logic remains predictable.
Leaving a fiber to just 'fall off the end' is like walking out of a room without closing the door; eventually, the
draft will bother someone.

## `is_done()` vs. Destruction

A fiber being `is_done()` simply means its Perl code has finished executing. The underlying C-level memory (stacks,
context, etc.) is not immediately freed until the `Acme::Parataxis` object is destroyed or the runtime performs its
final `cleanup()`. This is why you might see memory usage stay flat even after a fiber finishes, until the garbage
collector finally catches up with the object.

# AUTHOR

Sanko Robinson [https://github.com/sanko](https://github.com/sanko)

# LICENSE

Copyright (C) Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms found in the Artistic License
2.
