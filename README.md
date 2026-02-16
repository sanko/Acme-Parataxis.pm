# NAME

Acme::Parataxis - High-concurrency Green Threads and Hybrid Thread Pool for Perl

# SYNOPSIS

```perl
use Acme::Parataxis;

Acme::Parataxis::run(sub {
    say "Main started";

    # Spawn a new green thread
    my $c1 = Acme::Parataxis->spawn(sub {
        say "  Worker 1: Sleeping...";
        Acme::Parataxis->await_sleep(1000);
        say "  Worker 1: Woke up!";
        return "Result from C1";
    });

    # Another one
    my $c2 = Acme::Parataxis->spawn(sub {
        say "  Worker 2: Checking CPU core...";
        my $core = Acme::Parataxis->await_core_id();
        return "Ran on core $core";
    });

    # Wait for them and get results
    say "C1 returned: " . $c1->await();
    say "C2 returned: " . $c2->await();
});
```

# DESCRIPTION

`Acme::Parataxis` provides a hybrid concurrency model for Perl, combining cooperative multitasking (Green
Threads/Fibers) with a preemptive native thread pool.

## Key Features

- **User-Mode Stack Switching:** Efficient context switches using native OS primitives.
- **Hybrid Concurrency:** Offload blocking C operations to a native thread pool.
- **Modern Perl API:** Leverages Perl 5.40+ features like `class` and `try/catch`.
- **Asynchronous IO:** Built-in support for non-blocking socket operations.

# PACKAGE METHODS

## run( $code )

Starts the parataxis runtime and executes the provided coderef in the main coroutine. This method handles the event
loop and thread pool initialization/cleanup automatically.

## spawn( $code )

Creates and enqueues a new parataxis. Returns an `Acme::Parataxis::Future` object which can be used to wait for the
result.

## yield( @args )

Suspends the current parataxis and returns control (and `@args`) to the scheduler.

## maybe\_yield()

If a preemption threshold is set (via `set_preempt_threshold`), this method increments an internal counter. If the
threshold is reached, it yields back to the scheduler. This is useful for preventing long-running loops from starving
other coroutines.

## set\_preempt\_threshold( $count )

Sets the number of calls to `maybe_yield()` allowed before a context switch is triggered. Set to 0 to disable.

## await\_sleep( $ms )

Suspends the current parataxis for `$ms` milliseconds. The sleep is performed in a background worker thread.

## await\_core\_id()

Suspends the current parataxis until it can retrieve the ID of the CPU core it is currently running on (via a
background thread).

## await\_read( $fh ) / await\_write( $fh )

Suspends the current parataxis until the provided filehandle is ready for reading or writing.

## tid()

Returns the Operating System thread ID (TID) of the current thread.

## fid()

Returns the unique internal ID of the current parataxis (Fiber ID).

## stop()

Signals the runtime to stop once all current coroutines have finished.

# CLASS METHODS

## root()

Returns the root parataxis context, which can be used to transfer control back to the main thread.

## init\_system()

Manually initializes the parataxis system. Usually called automatically by `run()`.

## poll\_io()

Checks for completed background tasks. Returns a list of `[id, result]` pairs.

# OBJECT METHODS

## await()

Suspends the current coroutine until this coroutine completes, then returns its result.

## call( @args )

Manually resumes this coroutine with the provided arguments.

## transfer( @args )

Directly transfers control to this coroutine, suspending the current one.

## is\_done()

Returns true if the coroutine has finished execution.

# CLASSES

## Acme::Parataxis::Future

An object representing a value that may not yet be available.

### await()

Suspends the current coroutine until the future is ready, then returns the result.

### is\_ready()

Returns true if the result or error has been set.

### result()

Returns the result if available, or throws the stored error.

# AUTHOR

Sanko Robinson <sanko@cpan.org>

# LICENSE

Copyright (C) Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms found in the Artistic License
2.
