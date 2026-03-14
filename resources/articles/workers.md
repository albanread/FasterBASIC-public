# Workers: Safe Concurrency in FasterBASIC

FasterBASIC's WORKER feature brings modern concurrency to BASIC — without the pain. Inspired by Web Workers and the actor model, workers are **isolated functions that run on background threads**. They enforce a strict no-shared-state design: data goes in by copy, a single result comes out, and nothing in between can corrupt your program. No locks, no races, no surprises.

## The Core Idea

Traditional threading is notoriously error-prone. Shared mutable state, locks, deadlocks, and data races have ruined countless programs. FasterBASIC takes a different approach: **isolation by design**.

A worker is a pure computation. It receives its inputs as copied values, does its work using only local variables, and returns a result. It cannot touch global variables, perform I/O, draw graphics, or interact with any shared state. The compiler enforces all of this at compile time — not as a convention, but as a hard rule.

```basic
WORKER Multiply(a AS DOUBLE, b AS DOUBLE) AS DOUBLE
    RETURN a * b
END WORKER

DIM future AS DOUBLE
future = SPAWN Multiply(6, 7)
DIM result AS DOUBLE
result = AWAIT future
PRINT result   ' 42
```

That's it. `SPAWN` launches the worker on a new OS thread and immediately returns a **future handle**. `AWAIT` blocks until the worker finishes and retrieves the result. The handle is then consumed and freed — you cannot await it twice.

## Syntax Reference

### Defining a Worker

```basic
WORKER Name(param1 AS Type, param2 AS Type, ...) AS ReturnType
    ' computation using only local variables
    RETURN expression
END WORKER
```

Workers look like functions, but with the `WORKER` keyword. `END WORKER` (or `ENDWORKER`) closes the block.

### Spawning

```basic
DIM f AS DOUBLE
f = SPAWN WorkerName(arg1, arg2, ...)
```

`SPAWN` copies all arguments, creates a new thread, and returns a future handle stored as a `DOUBLE`.

### Awaiting

```basic
DIM result AS DOUBLE
result = AWAIT f
```

`AWAIT` blocks until the worker completes, returns the result, and destroys the future handle. After `AWAIT`, the handle is invalid.

### Polling with READY

```basic
IF READY(f) THEN
    result = AWAIT f
ELSE
    PRINT "Still working..."
END IF
```

`READY(future)` is a non-blocking check: it returns 1 if the worker has finished, 0 if it's still running. This lets you build responsive main loops that don't freeze while waiting for background computation.

### Marshalling Complex Data

Scalar values (doubles, integers) are passed directly as arguments. But what about arrays and user-defined types? They need to be **marshalled** — serialized into a portable blob that can safely cross the thread boundary.

```basic
' Passing an array into a worker
DIM blob AS MARSHALLED
blob = MARSHALL(myArray)
future = SPAWN ProcessData(blob)

' Inside the worker
WORKER ProcessData(data AS MARSHALLED) AS DOUBLE
    DIM numbers(10) AS DOUBLE
    UNMARSHALL numbers, data
    ' now work with the local copy
    DIM total AS DOUBLE
    FOR i = 1 TO 10
        total = total + numbers(i)
    NEXT i
    RETURN total
END WORKER
```

`MARSHALL(variable)` creates a deep copy of an array or UDT as a self-contained blob. `UNMARSHALL target, source` reconstructs the data on the other side. The blob is automatically freed after unmarshalling.

This also works with user-defined types:

```basic
TYPE Vec3
    x AS DOUBLE
    y AS DOUBLE
    z AS DOUBLE
END TYPE

DIM v AS Vec3
v.x = 10 : v.y = 20 : v.z = 30

DIM blob AS MARSHALLED
blob = MARSHALL(v)
future = SPAWN SumVector(blob)
result = AWAIT future
PRINT result   ' 60

WORKER SumVector(data AS MARSHALLED) AS DOUBLE
    DIM vec AS Vec3
    UNMARSHALL vec, data
    RETURN vec.x + vec.y + vec.z
END WORKER
```

## What Workers Can Do

Workers have full access to:

- **Local variables** — `DIM`, assignments, `SWAP`, `INC`/`DEC`
- **Control flow** — `IF`, `FOR`, `WHILE`, `REPEAT`, `DO`, `SELECT CASE`, `EXIT`
- **Arithmetic and logic** — all expressions, comparisons, operators
- **Function calls** — `CALL` to other functions and subs
- **Array operations** — `REDIM`, `ERASE`, `DELETE` (on local arrays)
- **Data reconstruction** — `UNMARSHALL`
- **Return values** — `RETURN expression`
- **Thread-safe output** — `PRINT`, `CONSOLE` (protected by a statement-level mutex so lines never interleave)
- **Timers** — `AFTER ... SEND`, `EVERY ... SEND`, `TIMER STOP` (timers are just message producers)

## What Workers Cannot Do

The compiler rejects workers that attempt any of the following:

| Forbidden | Reason |
|---|---|
| `INPUT` | Reading stdin from a background thread is not meaningful |
| `GLOBAL`, `SHARED` variables | Workers are isolated — no shared state |
| `OPEN`, `CLOSE` (file I/O) | File I/O not allowed in workers |
| `CLS`, `PSET`, `LINE`, `CIRCLE` | Graphics commands not allowed |
| `SPRLOAD`, sprite commands | Sprite commands not allowed |
| `PLAY`, audio commands | Audio commands not allowed |
| Accessing global variables | Isolation violation |
| `SPAWN` inside a worker | No nested workers |
| Nested `WORKER` definitions | Cannot nest WORKER inside WORKER |

These aren't runtime errors — they're **compile-time errors**. The semantic analyzer catches every violation before any code is generated.

Note: `PRINT` and `CONSOLE` **are** allowed inside workers. Each `PRINT` statement is wrapped in a mutex so that an entire line (all items + newline) appears atomically — no garbled output from concurrent threads. `AFTER ... SEND` and `EVERY ... SEND` are also allowed, since timers are just lightweight threads that push messages onto queues.

## Workers + VoiceScript (VS)

Workers are a great companion to VS, but they do different jobs:

- use workers for heavy CPU tasks (generation, analysis, simulation)
- keep `VS` control-rate events in your main update loop

You generally do **not** use workers to make VS "more real-time" — VS audio already runs continuously in the audio callback.

Related reading:

- [Audio System Guide (Friendly Quickstart)](audio-system-guide.md)
- [Introduction to VoiceScript](introduction_voicescript.md)
- [Advanced VoiceScript Guide](advanced_voicescript.md)

## Running Multiple Workers

Workers are most powerful when you run several in parallel:

```basic
WORKER ComputeSum(a AS DOUBLE, b AS DOUBLE) AS DOUBLE
    RETURN a + b
END WORKER

WORKER ComputeProduct(a AS DOUBLE, b AS DOUBLE) AS DOUBLE
    RETURN a * b
END WORKER

DIM f1 AS DOUBLE
DIM f2 AS DOUBLE
f1 = SPAWN ComputeSum(100, 200)
f2 = SPAWN ComputeProduct(10, 20)

DIM sum AS DOUBLE
DIM product AS DOUBLE
sum = AWAIT f1
product = AWAIT f2

PRINT "Sum: "; sum        ' 300
PRINT "Product: "; product ' 200
```

Both workers run simultaneously on separate OS threads. The main program spawns them both, then awaits each result. The total wall-clock time is the duration of the *slowest* worker, not the sum of both.

## A Practical Example: Parallel Statistics

Workers returning marshalled UDTs enable richer result types:

```basic
TYPE Stats
    min AS DOUBLE
    max AS DOUBLE
    avg AS DOUBLE
END TYPE

WORKER ComputeStats(data AS MARSHALLED) AS MARSHALLED
    DIM values(5) AS DOUBLE
    UNMARSHALL values, data

    DIM s AS Stats
    s.min = values(1)
    s.max = values(1)
    DIM total AS DOUBLE

    FOR i = 1 TO 5
        IF values(i) < s.min THEN s.min = values(i)
        IF values(i) > s.max THEN s.max = values(i)
        total = total + values(i)
    NEXT i
    s.avg = total / 5

    RETURN MARSHALL(s)
END WORKER

DIM arr(5) AS DOUBLE
arr(1) = 5 : arr(2) = 50 : arr(3) = 10 : arr(4) = 40 : arr(5) = 32.5

DIM blob AS MARSHALLED
blob = MARSHALL(arr)
DIM future AS DOUBLE
future = SPAWN ComputeStats(blob)

DIM resultBlob AS MARSHALLED
resultBlob = AWAIT future
DIM result AS Stats
UNMARSHALL result, resultBlob

PRINT "Min: "; result.min   ' 5
PRINT "Max: "; result.max   ' 50
PRINT "Avg: "; result.avg   ' 27.5
```

## Under the Hood

### Threading Model

Each `SPAWN` creates a new POSIX thread via `pthread_create`. There is no thread pool — one worker, one thread. This is simple and predictable. For compute-heavy tasks that benefit from parallelism, this is ideal. For thousands of tiny tasks, the thread creation overhead would dominate; workers are designed for coarse-grained parallelism.

### Future Handles

A future handle is a pointer to a `FutureHandle` structure containing:

- A pthread handle for joining
- A mutex and condition variable for signaling completion
- A `done` flag (0 = running, 1 = complete)
- The result value (stored as a 64-bit double)

The pointer is bit-cast into a `DOUBLE` for storage in BASIC variables. `AWAIT` casts it back, joins the thread, retrieves the result, and frees all resources.

### Argument Passing

Arguments are packed into a `WorkerArgs` block — a fixed array of 16 `double` slots. Integers and pointers are stored via type-punning into 64-bit doubles. The worker's thread entry function unpacks them and calls the compiled worker body with the correct number of arguments using C calling conventions.

### Marshalling Format

- **Arrays**: The blob contains a 64-byte `ArrayDescriptor` header followed by the raw element data. The internal data pointer is patched to reference the blob's own storage, making it fully self-contained.
- **UDTs**: A simple `memcpy` of the struct's bytes into a heap-allocated blob.

Both are freed automatically by `UNMARSHALL`.

## Design Philosophy

FasterBASIC's workers follow a clear philosophy:

1. **Safety over flexibility** — No shared state means no data races, ever. The compiler guarantees this.
2. **Simplicity over power** — The API is a small set of keywords: `WORKER`, `SPAWN`, `AWAIT`, `READY`, `MARSHALL`/`UNMARSHALL`, plus `SEND`/`RECEIVE`/`HASMESSAGE` for messaging. No channels, no mutexes, no atomics.
3. **Compile-time over runtime** — Isolation violations are caught during compilation, not as crashes at 3 AM.
4. **Value semantics** — Everything crossing the thread boundary is copied. The worker owns its data completely.

This makes workers accessible to BASIC programmers who may not have experience with concurrent programming, while still providing genuine OS-level parallelism for compute-bound tasks.

## Worker Messaging

While the core worker model communicates only through arguments and return values, **worker messaging** adds safe, marshalled bidirectional communication between a running worker and the main program. Messages are always deep-copied — no shared state, ever.

### Sending Messages

From inside a worker, use `SEND PARENT` to send a value back to the main program. From the main program, use `SEND` with the future handle to send a value to a running worker.

```basic
' Worker sends progress back to main
WORKER Crunch() AS DOUBLE
    DIM total AS DOUBLE = 0.0
    DIM i AS DOUBLE = 0.0
    DIM progress AS DOUBLE
    FOR i = 1.0 TO 1000.0
        total = total + SQR(i)
        IF i = 250.0 THEN
            progress = 25.0
            SEND PARENT, progress
        END IF
        IF i = 500.0 THEN
            progress = 50.0
            SEND PARENT, progress
        END IF
    NEXT i
    RETURN total
END WORKER

DIM f AS DOUBLE
f = SPAWN Crunch()

DIM pct AS DOUBLE
pct = RECEIVE(f)
PRINT "Progress: "; pct; "%"
pct = RECEIVE(f)
PRINT "Progress: "; pct; "%"

DIM result AS DOUBLE
result = AWAIT f
PRINT "Result: "; result
```

### Receiving Messages

`RECEIVE(handle)` blocks until a message is available from the other side. Inside a worker, use `RECEIVE(PARENT)` to receive messages sent by the main program.

```basic
' Main sends work items to a running worker
WORKER Summer() AS DOUBLE
    DIM total AS DOUBLE = 0.0
    DIM i AS INTEGER
    FOR i = 1 TO 10
        DIM val AS DOUBLE
        val = RECEIVE(PARENT)
        total = total + val
    NEXT i
    RETURN total
END WORKER

DIM f AS DOUBLE
f = SPAWN Summer()

DIM i AS INTEGER
DIM v AS DOUBLE
FOR i = 1 TO 10
    v = i
    SEND f, v
NEXT i

DIM result AS DOUBLE
result = AWAIT f
PRINT "Total: "; result    ' 55
```

### Polling with HASMESSAGE

`HASMESSAGE(handle)` is a non-blocking check that returns 1 if at least one message is queued, 0 otherwise. This lets you build responsive main loops.

```basic
DO WHILE NOT READY(f)
    IF HASMESSAGE(f) THEN
        DIM msg AS DOUBLE
        msg = RECEIVE(f)
        PRINT "Got: "; msg
    END IF
    SLEEP 10
LOOP
' Drain remaining messages after worker finishes
DO WHILE HASMESSAGE(f)
    DIM msg AS DOUBLE
    msg = RECEIVE(f)
    PRINT "Got: "; msg
LOOP
result = AWAIT f
```

### The PARENT Pseudo-Handle

Inside a `WORKER` body, `PARENT` is a keyword that refers to the message channel back to whoever spawned this worker. It is only valid inside a `WORKER` block — using it anywhere else is a compile-time error.

The direction of messages is swapped automatically:
- Worker's `SEND PARENT, value` → pushes to the inbox (worker→main)
- Worker's `RECEIVE(PARENT)` → pops from the outbox (main→worker)
- Main's `SEND f, value` → pushes to the outbox (main→worker)
- Main's `RECEIVE(f)` → pops from the inbox (worker→main)

### Cooperative Cancellation

Workers cannot be forcefully killed — that would violate resource safety. Instead, the main program sends a cancellation signal and the worker checks for it:

```basic
WORKER LongTask() AS DOUBLE
    DIM result AS DOUBLE = 0.0
    DIM i AS DOUBLE = 0.0
    DO
        i = i + 1.0
        result = result + SQR(i)
        IF CANCELLED(PARENT) THEN
            RETURN result      ' early exit, clean return
        END IF
        IF i > 1000000.0 THEN EXIT DO
    LOOP
    RETURN result
END WORKER

DIM f AS DOUBLE
f = SPAWN LongTask()
CANCEL f                       ' request cancellation
DIM partial AS DOUBLE
partial = AWAIT f
PRINT "Partial result: "; partial
```

`CANCEL handle` sends a signal via an atomic flag — it does not go through the message queue, so it is never blocked by a full queue. `CANCELLED(PARENT)` is a non-blocking check that reads the flag.

### Zero Overhead for Non-Messaging Workers

The compiler detects whether a worker body references `PARENT`. If it doesn't, **no message queues are allocated, no hidden parameter is injected** — existing workers run with identical performance and memory footprint. The messaging infrastructure is purely additive.

### Messaging Syntax Reference

| Keyword | Context | Blocking? | Description |
|---------|---------|-----------|-------------|
| `SEND handle, expr` | Main or Worker | Semi¹ | Send a deep-copied message to the other side |
| `RECEIVE(handle)` | Main or Worker | Yes | Block until a message arrives, return it |
| `HASMESSAGE(handle)` | Main or Worker | No | Check if a message is available |
| `PARENT` | Worker only | — | Pseudo-handle referring to the spawner |
| `CANCEL handle` | Main only | No | Send cancellation signal to worker |
| `CANCELLED(PARENT)` | Worker only | No | Check if cancellation was requested |

¹ Non-blocking unless the queue is full (bounded back-pressure, 256-slot ring buffer).

### Messaging Design Rules

- Workers still cannot communicate directly with each other — the main program routes messages between workers if needed.
- All messages are deep copies. The sender and receiver never alias the same memory.
- `AWAIT` automatically drains and frees any unconsumed messages, so no memory is leaked regardless of how the conversation went.
- Message queues are bounded (256 slots). A fast producer is naturally throttled if the consumer falls behind.
- `RECEIVE` inside a worker that was not sent any messages will block until the main program sends one or the queue is closed.

## MATCH RECEIVE — Typed Message Dispatch

When a worker sends messages of different types — doubles, integers, strings, or specific user-defined types — the main program needs to figure out what arrived and handle it. `MATCH RECEIVE` does this automatically: it pops a message from the queue, checks its type, and jumps to the first matching CASE arm with a properly typed binding variable.

```basic
MATCH RECEIVE(f)
    CASE DOUBLE x
        PRINT "Got double: "; x
    CASE INTEGER n%
        PRINT "Got integer: "; n%
    CASE STRING s$
        PRINT "Got string: "; s$
    CASE Point pt
        PRINT "Got point: "; pt.x; " "; pt.y
    CASE ELSE
        PRINT "Unknown message"
END MATCH
```

MATCH RECEIVE works inside workers too — use `MATCH RECEIVE(PARENT)` to dispatch on messages sent by the main program.

For UDT arms, MATCH RECEIVE automatically unmarshalls the data from the message blob into the binding variable. You don't need to call `UNMARSHALL` yourself. The compiler tracks each UDT's unique type ID, so `CASE Point` will never accidentally match a `Rect` message — even though both are UDTs.

For full details, practical patterns (command/response protocols, state machines, progress reporting, mixing data with control signals), and a complete syntax reference, see the dedicated [MATCH RECEIVE article](match-receive.md).

---

## Limitations

- **Up to 8 arguments** per worker (up to 16 internally, but the call-site dispatch covers 0–9)
- **Single return value** — use `MARSHALL` to return complex results
- **No direct worker-to-worker messaging** — the main program must route messages between workers
- **Thread-per-worker** — no pooling; best for coarse-grained parallel work
- **`AWAIT` consumes the handle** — a future can only be awaited once
- **No nested spawning** — workers cannot spawn other workers

---

## Further Reading

- [MATCH RECEIVE — Typed Message Dispatch](match-receive.md) — full guide to dispatching on worker messages by type, including UDT and class matching
- [User-Defined Types](user-defined-types.md) — defining TYPEs, CREATE, and marshalling UDTs across thread boundaries
- [Lists and MATCH TYPE](lists-and-match-type.md) — the related MATCH TYPE construct for dispatching on list element types
