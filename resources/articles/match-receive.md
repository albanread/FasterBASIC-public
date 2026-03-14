# MATCH RECEIVE — Typed Message Dispatch for Workers

*Handle different message types from a worker without manual type-checking.*

---

## What It Does

When a worker sends messages of different types, `MATCH RECEIVE` pops the next message, checks its type, and runs the first matching CASE arm. The value is bound to a typed variable, ready to use. For UDTs, unmarshalling is automatic.

It works just like `MATCH TYPE` for lists — but on worker messages instead of list elements.

---

## Scalar Messages

A worker sends a double, an integer, and a string. The main program handles each one:

```
WORKER Sender() AS DOUBLE
    DIM d AS DOUBLE = 3.14
    SEND PARENT, d
    DIM i AS INTEGER = 42
    SEND PARENT, i
    DIM s AS STRING = "hello"
    SEND PARENT, s
    DIM ret AS DOUBLE = 0.0
    RETURN ret
END WORKER

DIM f AS DOUBLE
f = SPAWN Sender()

DIM count AS INTEGER = 0

WHILE count < 3
    MATCH RECEIVE(f)
        CASE DOUBLE x
            PRINT "Got double: "; x
            count = count + 1
        CASE INTEGER n%
            PRINT "Got integer: "; n%
            count = count + 1
        CASE STRING s$
            PRINT "Got string: "; s$
            count = count + 1
        CASE ELSE
            PRINT "Unknown message"
            count = count + 1
    END MATCH
WEND

DIM result AS DOUBLE
result = AWAIT f
PRINT "Done"
```

Output:

```
Got double: 3.14
Got integer: 42
Got string: hello
Done
```

No manual type checks, no separate RECEIVE calls. Each message lands in the right arm.

---

## UDT Messages

MATCH RECEIVE can tell different user-defined types apart. A `CASE Point` arm will never accidentally match a `Box` — the compiler tracks each UDT's unique type ID.

```
TYPE Point
    x AS DOUBLE
    y AS DOUBLE
END TYPE

TYPE Box
    lx AS DOUBLE
    ty AS DOUBLE
    w AS DOUBLE
    h AS DOUBLE
END TYPE

WORKER ShapeSender() AS DOUBLE
    DIM p AS Point
    p.x = 10
    p.y = 20
    SEND PARENT, p

    DIM r AS Box
    r.lx = 1
    r.ty = 2
    r.w = 100
    r.h = 200
    SEND PARENT, r

    DIM ret AS DOUBLE = 0.0
    RETURN ret
END WORKER

DIM f AS DOUBLE
f = SPAWN ShapeSender()

DIM count AS INTEGER = 0

WHILE count < 2
    MATCH RECEIVE(f)
        CASE Point pt
            PRINT "Got Point: "; pt.x; " "; pt.y
            count = count + 1
        CASE Box rc
            PRINT "Got Box: "; rc.lx; " "; rc.ty; " "; rc.w; " "; rc.h
            count = count + 1
        CASE ELSE
            PRINT "Unknown message"
            count = count + 1
    END MATCH
WEND

DIM result AS DOUBLE
result = AWAIT f
PRINT "Done"
```

Output:

```
Got Point: 10 20
Got Box: 1 2 100 200
Done
```

UDT data is automatically unmarshalled — you don't need to call `UNMARSHALL` yourself. String fields inside UDTs are deep-copied.

---

## Inside a Worker

Workers use `MATCH RECEIVE(PARENT)` to dispatch on messages from the main program. A typical pattern is a loop that accepts typed commands and uses an integer signal to shut down:

```
TYPE WorkItem
    id AS INTEGER
    value AS DOUBLE
END TYPE

WORKER Accumulator() AS DOUBLE
    DIM total AS DOUBLE = 0.0
    DIM running AS INTEGER = 1

    WHILE running
        MATCH RECEIVE(PARENT)
            CASE WorkItem task
                total = total + task.value

            CASE INTEGER signal%
                IF signal% = -1 THEN running = 0

            CASE ELSE
                ' ignore unknown messages
        END MATCH
    WEND

    RETURN total
END WORKER

DIM f AS DOUBLE
f = SPAWN Accumulator()

DIM w AS WorkItem
w.id = 1
w.value = 10.5
SEND f, w
w.id = 2
w.value = 20.0
SEND f, w

DIM shutdown AS INTEGER = -1
SEND f, shutdown

DIM total AS DOUBLE
total = AWAIT f
PRINT "Total: "; total   ' 30.5
```

---

## How Messages Flow

If you've read the examples above and the syntax makes sense, you can skip ahead to the [parallel pi calculator](#real-world-example-parallel-pi-calculator). This section explains what's happening behind the scenes — useful when you need to reason about message ordering or debug unexpected behavior.

### The Big Picture

When you `SPAWN` a worker, the runtime creates two one-way message queues — one for each direction. `SEND` puts a message on a queue; `MATCH RECEIVE` takes one off. The main program and the worker never touch the same memory directly.

```
    Main Program                              Worker
    ════════════                              ══════

                       outbox (main → worker)
    SEND f, data  ──▶ ┌───┬───┬───┬───┐ ──▶  MATCH RECEIVE(PARENT)
                       │ 1 │ 2 │ 3 │   │        CASE Point → ...
                       └───┴───┴───┴───┘        CASE INTEGER → ...
                              FIFO               CASE ELSE → ...

                       inbox (worker → main)
    MATCH RECEIVE(f) ◀── ┌───┬───┬───┬───┐ ◀──  SEND PARENT, result
      CASE WorkResult →  │ 1 │ 2 │   │   │
      CASE STRING →      └───┴───┴───┴───┘
                               FIFO
```

Each queue holds up to 256 messages. If a queue is full, `SEND` blocks until the other side consumes something. If a queue is empty, `MATCH RECEIVE` blocks until a message arrives. This back-pressure keeps fast producers from overwhelming slow consumers.

### What Happens Inside MATCH RECEIVE

`MATCH RECEIVE` always takes the **next message in line** — the one at the front of the queue. It checks the type, runs the first CASE arm that matches, and moves on. One message per `MATCH RECEIVE`, always from the front.

```
    Queue (front → back):  [ Point | INTEGER | STRING ]
                              │
                         pop front
                              │
                              ▼
                     ┌─────────────────┐
                     │  What type is   │
                     │  this message?  │
                     └──┬──────┬───────┘
                        │      │       │
                   Point?   INTEGER?  no match
                     │         │       │
                     ▼         ▼       ▼
                  CASE arm  CASE arm  CASE ELSE
                  runs      runs      runs
```

This is different from some other languages (like Erlang) where `receive` can scan the entire mailbox looking for a specific message type, skipping over non-matching messages until it finds one. That approach is flexible but can be a performance trap — if thousands of "Type A" messages pile up while you're waiting for a "Type B", every receive has to scan past all of them.

FasterBASIC keeps it simple: you always get the front message. No scanning, no skipping, no surprises. This means `MATCH RECEIVE` is always O(1) — constant time regardless of how many messages are in the queue.

### Message Ordering Matters

Because `MATCH RECEIVE` always takes the front message, sender and receiver need to agree on the order. If a worker sends a `Point` and then a `Box`:

```
' Worker sends in this order:
SEND PARENT, myPoint     ' goes in first
SEND PARENT, myBox       ' goes in second

' Main receives in the same order:
MATCH RECEIVE(f)          ' gets the Point
    CASE Point pt → ...
END MATCH

MATCH RECEIVE(f)          ' gets the Box
    CASE Box rc → ...
END MATCH
```

The messages arrive in the order they were sent. If you put both CASEs in a single `MATCH RECEIVE` inside a loop, it still works — each iteration pops the next message and dispatches it to whichever arm matches.

When you don't know the exact order, that's fine — just make sure every `MATCH RECEIVE` has arms for all the types you expect. The loop-and-dispatch pattern handles any ordering naturally:

```
WHILE count < total_expected
    MATCH RECEIVE(f)
        CASE Point pt
            ' might arrive first, second, or third — doesn't matter
        CASE Box rc
            ' handled whenever it shows up
        CASE ELSE
            ' catch anything unexpected
    END MATCH
    count = count + 1
WEND
```

### Always Include CASE ELSE

If the front message doesn't match any CASE arm, it is consumed and discarded. There's no error and no memory leak — the runtime frees it safely. But you lose the message silently, with no indication that anything went wrong.

`CASE ELSE` catches anything that doesn't match a typed arm. During development, always include it:

```
MATCH RECEIVE(f)
    CASE Point pt
        PRINT "Got a point"
    CASE INTEGER n%
        PRINT "Got an integer"
    CASE ELSE
        PRINT "Unexpected message — check your protocol!"
END MATCH
```

This turns a silent discard into a visible warning. Once your protocol is stable and tested, you can remove the `CASE ELSE` if you prefer — unmatched messages are still handled safely, just silently.

### Cleanup at AWAIT

When you call `AWAIT` on a worker handle, any messages still sitting in either queue are freed automatically. The `Dropped (drained)` counter in the [diagnostics report](#message-memory-diagnostics) tells you how many were cleaned up this way. If that number is unexpectedly high, it means your receiver finished before consuming everything the sender sent — worth investigating.

---

## Real-World Example: Parallel Pi Calculator

Here's a complete program that uses workers to solve a real problem — computing π via numerical integration. The integral of `4/(1+x²)` over `[0, 1]` equals π exactly. We split the range across 4 workers, each computing its sub-range using the midpoint rectangle rule, then collect and sum the partial results.

```
TYPE WorkRange
    lo AS DOUBLE
    hi AS DOUBLE
    steps AS DOUBLE
END TYPE

TYPE WorkResult
    partial_sum AS DOUBLE
    range_lo AS DOUBLE
    range_hi AS DOUBLE
END TYPE

WORKER Integrator() AS DOUBLE
    DIM wr AS WorkRange
    DIM res AS WorkResult
    DIM sum AS DOUBLE = 0.0
    DIM dx AS DOUBLE
    DIM i AS DOUBLE
    DIM x AS DOUBLE

    MATCH RECEIVE(PARENT)
        CASE WorkRange wr
            dx = (wr.hi - wr.lo) / wr.steps
            i = 0
            WHILE i < wr.steps
                x = wr.lo + (i + 0.5) * dx
                sum = sum + 4.0 / (1.0 + x * x) * dx
                i = i + 1
            WEND
            res.partial_sum = sum
            res.range_lo = wr.lo
            res.range_hi = wr.hi
            SEND PARENT, res
    END MATCH
    DIM ret AS DOUBLE = 0.0
    RETURN ret
END WORKER
```

Each worker receives a `WorkRange` telling it which slice of `[0, 1]` to integrate, runs the computation in a tight loop, and sends back a `WorkResult` with its partial sum. The main program distributes work and collects results:

```
' Spawn 4 workers
DIM f1 AS DOUBLE
DIM f2 AS DOUBLE
DIM f3 AS DOUBLE
DIM f4 AS DOUBLE
f1 = SPAWN Integrator()
f2 = SPAWN Integrator()
f3 = SPAWN Integrator()
f4 = SPAWN Integrator()

' Distribute work — each worker gets 1/4 of [0, 1]
DIM steps_per AS DOUBLE = 20000000 / 4
DIM rng AS WorkRange

rng.lo = 0.0
rng.hi = 0.25
rng.steps = steps_per
SEND f1, rng

rng.lo = 0.25
rng.hi = 0.50
rng.steps = steps_per
SEND f2, rng

rng.lo = 0.50
rng.hi = 0.75
rng.steps = steps_per
SEND f3, rng

rng.lo = 0.75
rng.hi = 1.0
rng.steps = steps_per
SEND f4, rng

' Collect partial results
DIM par_sum AS DOUBLE = 0.0
DIM res AS WorkResult

MATCH RECEIVE(f1)
    CASE WorkResult res
        par_sum = par_sum + res.partial_sum
END MATCH

MATCH RECEIVE(f2)
    CASE WorkResult res
        par_sum = par_sum + res.partial_sum
END MATCH

MATCH RECEIVE(f3)
    CASE WorkResult res
        par_sum = par_sum + res.partial_sum
END MATCH

MATCH RECEIVE(f4)
    CASE WorkResult res
        par_sum = par_sum + res.partial_sum
END MATCH

' Reap workers
DIM dummy AS DOUBLE
dummy = AWAIT f1
dummy = AWAIT f2
dummy = AWAIT f3
dummy = AWAIT f4

PRINT "Pi = "; par_sum
```

This is real parallelism — with 20 million integration steps, the 4-worker version runs **3–4× faster** than the equivalent sequential loop. The results are accurate to ~10⁻¹³. All message memory is tracked and freed automatically.

A few things to notice:

- **Same worker function, multiple instances.** Each `SPAWN Integrator()` creates a separate thread with its own message queues. They share nothing.
- **UDTs carry structured data across threads.** `WorkRange` and `WorkResult` are marshalled and unmarshalled transparently — you just `SEND` and `MATCH RECEIVE`.
- **The `rng` variable is reused safely.** Each `SEND` marshals a copy, so mutating `rng` between sends doesn't affect previously sent messages.
- **No locks, no shared state.** Workers are fully isolated. The only communication channel is message passing.

---

## Zero-Copy Bounce Optimization

When a worker receives a UDT and sends the same variable back to the same handle, the compiler detects the **bounce pattern** and skips the marshal/unmarshal cycle. Instead of copying the payload out and then copying it back in, it modifies the payload in-place and forwards the original blob.

Here's what normally happens versus what the optimization does:

```
  Normal path (every receive + send = 4 allocations):

    Queue          Worker memory         Queue
    ┌─────┐        ┌─────────┐          ┌─────┐
    │ blob│──pop──▶│ unmarshal│          │     │
    │     │  free  │ into     │          │     │
    └─────┘  blob  │ local p  │          │     │
                   │          │          │     │
                   │ p.x=p.x+1│          │     │
                   │          │          │     │
                   │ marshal  │──push──▶│ new │
                   │ from p   │  alloc   │ blob│
                   └─────────┘  blob    └─────┘

    Cost: free old blob, alloc local, alloc new blob, free local
          = 2 malloc + 2 free + 2 memcpy per round trip


  Zero-copy path (0 allocations per bounce):

    Queue          Blob payload          Queue
    ┌─────┐        ┌──────────┐         ┌─────┐
    │ blob│──pop──▶│ modify   │──push──▶│same │
    │     │        │ in-place │         │blob!│
    └─────┘        │          │         └─────┘
                   │ p.x=p.x+1│
                   └──────────┘

    Cost: 0 malloc, 0 free, 0 memcpy
          The same blob survives the entire ping-pong
```

Here's the code that triggers the optimization:

```
TYPE Point
    x AS DOUBLE
    y AS DOUBLE
END TYPE

WORKER PingWorker() AS DOUBLE
    DIM i AS INTEGER = 0
    DIM p AS Point

    WHILE i < 3
        MATCH RECEIVE(PARENT)
            CASE Point p
                p.x = p.x + 1
                p.y = p.y + 1
                SEND PARENT, p    ' <— same variable, same handle
                i = i + 1
        END MATCH
    WEND

    DIM ret AS DOUBLE = 0.0
    RETURN ret
END WORKER
```

The compiler sees that the `CASE Point p` arm contains `SEND PARENT, p` — the binding variable sent back to the same handle — and automatically replaces the marshal→unmarshal→marshal cycle with a zero-copy forward. The blob's payload buffer is modified in-place and pushed back onto the queue without any allocation or copying.

This optimization is:

- **Automatic.** No special syntax needed. Write the natural ping-pong pattern and the compiler recognizes it.
- **Per-arm.** In a MATCH RECEIVE with multiple CASE arms, some can forward while others consume normally.
- **Safe for flat UDTs.** Types with only DOUBLE/INTEGER fields are forwarded without restriction.

**Note on STRING fields:** UDTs that contain STRING fields do *not* use zero-copy forwarding. Strings in FasterBASIC are managed by the SAMM memory system, and forwarding a blob that contains string pointers across thread boundaries would create ownership conflicts. For these types, the compiler automatically falls back to the standard marshal/unmarshal path, which deep-copies all string data safely. You don't need to do anything — the compiler makes the right choice based on the UDT's field types.

In the message memory diagnostics (see below), forwarded messages show up in the `Forwarded (0-cp)` counter.

---

## Message Memory Diagnostics

Every message allocation — blob envelopes, payloads, string clones, queue operations — is tracked by atomic counters in the runtime. This gives you complete visibility into message memory behavior and automatic leak detection.

### Automatic Leak Detection

At program exit, the runtime checks all message memory counters. If anything is unbalanced, it prints a warning to stderr:

```
⚠️  Message memory leaks detected:
    Blob envelopes: 4 created, 2 freed, 2 leaked
    Payloads: 4 allocated, 2 freed, 2 leaked
```

If everything balances, there's no output — your program runs silently.

### Full Diagnostics Report

Set the `BASIC_MEMORY_STATS` environment variable to see the complete dashboard:

```
$ BASIC_MEMORY_STATS=1 ./my_program
```

This prints a report alongside the existing SAMM and general memory statistics:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Message Memory Metrics
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Blob envelopes:
    Created:           8
    Freed:             8
    Forwarded (0-cp):  0
    Peak outstanding:  5
    ✓ No blob leaks
  Payloads:
    Allocated:         8
    Freed:             8
    Total bytes:       192
    ✓ No payload leaks
  Message strings:
    Cloned:            0
    Released:          0
    ✓ No string leaks
  By type:
    DOUBLE:    0
    INTEGER:   0
    STRING:    0
    UDT:       8
    CLASS:     0
    ARRAY:     0
    SIGNAL:    0
    MARSHALLED:0
  Queue traffic:
    Pushed:            8
    Popped:            8
    Dropped (drained): 0
    Push back-pressure waits: 0
    Pop empty waits:          4
  Queues:
    Created:           8
    Destroyed:         8
    ✓ No queue leaks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### What the Counters Tell You

| Counter | What it means |
|---|---|
| **Blob envelopes** | Created vs freed — should balance to zero at exit |
| **Forwarded (0-cp)** | How many blobs were reused via the bounce optimization |
| **Peak outstanding** | Maximum blobs alive at any one time — your high-water mark |
| **Payloads** | Heap allocations for UDT/CLASS/ARRAY message data |
| **Message strings** | String clones made for message passing (separate from SAMM) |
| **Push back-pressure waits** | Times a SEND blocked because the queue was full (capacity 256) |
| **Pop empty waits** | Times a RECEIVE blocked waiting for a message |
| **Dropped (drained)** | Messages freed during AWAIT cleanup — unconsumed messages |

The back-pressure counters are particularly useful for diagnosing performance: if `push_waits` is high, your producer is outrunning your consumer. If `pop_waits` is high, your consumer is starving.

---

## Things to Know

- **MATCH RECEIVE blocks** until a message arrives, just like `RECEIVE`. Use `HASMESSAGE(handle)` first if you don't want to block.
- **Always pops from the front.** There is no mailbox scanning — you get the next message in line, every time. See [How Messages Flow](#how-messages-flow) for details.
- **One message per MATCH RECEIVE.** Put it in a loop to process multiple messages.
- **Include CASE ELSE during development.** Without it, unmatched messages are consumed and silently discarded. `CASE ELSE` makes those visible. See [Always Include CASE ELSE](#always-include-case-else).
- **CASE ELSE must be last** when present.
- **Arms are tested in order.** The first match wins.
- **No DIM needed** for binding variables — the compiler allocates storage automatically.
- **You still need AWAIT** after you're done with messages, to join the thread and clean up. Any unconsumed messages are freed automatically.
- `END MATCH` and `ENDMATCH` are both accepted.

---

## When to Use It

Use plain `RECEIVE` when every message is the same type. Use `MATCH RECEIVE` when messages could be different types — it saves you from writing IF/ELSE chains with manual type inspection. For compute-heavy workloads, spawn multiple workers with the same function and distribute work via typed UDT messages (see the parallel pi example above).

---

## Further Reading

- [Workers](workers.md) — SPAWN, AWAIT, SEND, RECEIVE, MARSHALL, and cooperative cancellation
- [User-Defined Types](user-defined-types.md) — TYPE definitions, CREATE, and field access
- [Lists and MATCH TYPE](lists-and-match-type.md) — the same dispatch pattern for list elements
- [Classes and Objects](classes-and-objects.md) — CLASS types also work as CASE arms

---

*The parallel pi calculator is available as `tests/workers/test_worker_parallel_pi.bas` in the source tree.*