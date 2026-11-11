# nexus request performance vs a Rust baseline (2026-11-11)

**What prompted it:** in the debug console a `SELECT … FROM posts LIMIT 10` on an empty table showed 6–7 ms, and `/health` felt slow next to a Rust app.

**How the evidence was gathered:** everything ran on one Mac against the `scripts/dev.sh` MySQL 8.0 container (Docker Desktop, published port).
- **Servers:**
  - the dev server: `--debug --optimize none`
  - a `--release` build of the blog, run in four variants
  - a bare libhttp hello server with no nexus
  - axum 0.7 with mysql_async, running the same query as a prepared statement
- **Load:** `wrk` for `/health`.
- **Query timings:**
  - nexus: from the debug console timelines
  - Rust: from its own `Server-Timing: db;dur`
  - libmysql alone: a probe that runs the query 200 times on one connection

The scratch code is not in the repo.

## What we measured

### `/health`, wrk, keep-alive

| Server | c=1 req/s | c=1 p50 | c=64 req/s |
|---|---|---|---|
| Rust (axum, release) | 45k | 20 µs | 169k |
| libhttp alone (release) | 33k | 30 µs | 166k |
| nexus release, no console, `NEXUS_LOG=warn` | 26k | 37 µs | 148k |
| nexus release, access log on (`info`) | 21k | 44 µs | 63k |
| nexus release, debug console on | 15k | 64 µs | 56k |
| nexus release, both on | 12k | 77 µs | 46k |
| nexus debug build, both on (what `dev.sh` runs) | 2.9k | 289 µs | 22k |

For the access-log rows, stderr went to a file. In `dev.sh` it goes to a terminal, which is slower.

### The posts query, p50

| Path | p50 |
|---|---|
| MySQL itself (`SHOW PROFILES`) | 0.14 ms |
| libmysql alone, back to back | 0.41 ms |
| Rust (mysql_async), back to back | 0.64–0.71 ms |
| nexus release, curl loop | 0.85 ms |
| nexus debug build, curl loop | 1.16 ms |
| Rust, 10 ms between requests | 1.9 ms |
| Rust, 200 ms between requests | 4.2 ms (p90 6.1 ms) |

## What it means

1. **The 6–7 ms query is the Docker Desktop VM going idle, not our code.** Rust pays the same penalty when requests are spaced like a person clicking. The query path is already at Rust's level: libmysql streams, caches prepared statements, sets TCP_NODELAY and makes one round trip per statement.
2. **libhttp is not the bottleneck.** Under load it matches axum (166k vs 169k). At c=1 it is about 10 µs behind, which is the reactor → worker handoff.
3. **The nexus kernel is cheap.** It costs 7 µs per request and about 10% of throughput.
4. **The debug console and the access log are each a serialization point.** Each one alone caps throughput around 56–63k, a third of what the stack can do. Together, with the debug build on top, they are why the dev server feels slow.
5. **The debug build multiplies everything by about 4.** Numbers seen while running `dev.sh` are not performance numbers.

## Plan, in order of payoff

### 1. Make the numbers honest (small)

- Time the whole request in `HttpTransport`/`Kernel::handle` and show that total in the console and in `Server-Timing` as `total;dur`.
  - Today the blog's `ServerTiming` middleware covers only the inner chain. The recorder, the kernel prologue, the access log, render and the scope drop are all outside it.
- Show the build mode (debug/release) in the console's overview, so a reading from the debug build is labelled as one.
- Add `scripts/bench.sh` to the blog: build `--release` into its own dir, start the servers, run `wrk` on `/health` and a signed `/v1/posts`, and print the table above. Every change below is measured with it.

### 2. Access log off the request path (biggest win when the log is on)

- **Problem:** `log::Stream::write` (`src/log/Stream.eco`) renders the line, then holds a mutex while it prints to stderr. The code map says the stdlib printer flushes all of stdio and makes two `write(2)` calls per line; check that in the stdlib before relying on it.
- **Change:** make `serve` log asynchronously by default. The queue already exists behind `NEXUS_LOG_ASYNC` (`src/cli/Console.eco`). Write each line with one `write(2)` and no global flush.
- **Target:** with logging on, within 5% of the no-log numbers, about 140k req/s.

### 3. A cheaper debug console recorder

- **Problem:** per request, `nexus::debug::Recorder` does all of the following:
  - creates a `Capture`, a `Trace` and a traced logger
  - takes the global `Traces` mutex on enter and leave (`src/trace/Traces.eco`), and again for every query and span through `here()`, with a linear scan
  - builds two JSON documents and `json::dump`s them before the response leaves
  - puts them behind the `Timelines` and `Ring` mutexes
- **Changes:**
  - Keep the current trace in a thread-local instead of the mutex-guarded list. `here()` then becomes a load.
  - Record a plain struct, the summary row and the marks. Render JSON only when a panel asks for it.
  - Move the publish (Ring, Timelines) off the request thread, or make it a single short lock.
  - Optional: record only summaries while no console tab is open, and full timelines while one is.
- **Target:** console on costs under 10 µs per request, and under 15% of throughput at c=64.

### 4. Dev setup that doesn't lie about the database

- Explain the idle-VM effect in `dev.sh` and the console docs.
- Offer `DB=native` in `dev.sh` for a local `mysqld` (Homebrew). Then dev query timings match what a server sees.
- Optional: `dev.sh --release` for when someone is looking at performance.

### 5. Database path (already at Rust level; small items)

- **Session lookup:** it is consistently slower than the posts query (1.3 vs 0.85 ms p50) although both are single-row selects. Check whether it is just the first statement after an idle connection, or something on the lease.
- **`pingAfterIdle`:** the default of 1 s (libmysql `pool.eco`) adds a `COM_PING` round trip before almost every request when traffic is sparse. Raise it to around 30 s and rely on retry-on-broken.
- **Statement cache:** when it reaches 64 entries it is dropped entirely (libmysql `connection.eco` `prepared`), so apps with many distinct statements re-prepare in bursts. Evict one entry instead.

### 6. libhttp at low concurrency (optional, about 10 µs)

- Each request takes one futex hop from reactor to worker. Idle workers spin for only 50 µs (`SPIN_MICROS` in `src/queue.eco`), so sparse traffic always wakes a sleeping thread. Options:
  - run small requests on the reactor when the job queue is empty
  - spin adaptively
- Each accept wakes every reactor (shared listen fd, level-triggered). Try one listener per reactor with `SO_REUSEPORT`, or a single accepting reactor.
- **Target:** match axum's 20 µs p50 at c=1. Under load we are already level.

## Targets

| | Now | Goal |
|---|---|---|
| nexus release, dev defaults (log + console), c=64 | 46k req/s | ≥120k |
| nexus release, lean, c=64 | 148k | ≥160k |
| nexus release, lean, c=1 p50 | 37 µs | ≤25 µs |
| posts query, release, native MySQL | not measured | within 10% of Rust |

## Steps 1–3 done (2026-11-11)

What changed:
- **Honest numbers:** `Payload::started` is set at kernel entry, and the console's `ms` and the
  blog's `Server-Timing` count from it. `nexus::Build::checked()` detects a debug build: the
  console shows a Build stat and `serve` warns at boot. `examples/blog/scripts/bench.sh` measures
  all four variants; `BLOG=<binary>` benches a binary built elsewhere.
- **Access log:**
  - `serve` logs through `log::Async` by default (`NEXUS_LOG_ASYNC=8192`; `0` turns it off).
  - `Async` swaps out the whole waiting batch at once, and `flush` waits on a condition instead
    of sleeping. `flush` also waits until every dropped entry has been reported.
  - `Stream` writes each line in one write, and buffers behind `Async`.
  - The kernel builds the access line only when something will write it.
  - Work runs flush only their own sink.
- **Console recorder:**
  - `Traces` is split into 64 shards keyed by `pthread_self`.
  - Topics keep `Record`s and encode them when someone reads.
  - The timeline lives on the request's record, and `Timelines` is gone.
  - `LogTap` keeps the log entry and encodes it on read.
  - `Trace::finish` freezes the total.

`scripts/bench.sh`, `/health`, release build. Before is the binary built before the change; the
same script measured both.

| Variant | c=1 p50 before → after | c=64 req/s before → after |
|---|---|---|
| lean | 35 → 33 µs | 133k → 156k |
| log | 42 → 42 µs | 85k → 144k |
| console | 65 → 38 µs | 57k → 135k |
| both (dev defaults) | 71 → 39 µs | 48k → 125k |

`/v1/posts` is bound by the Docker MySQL round trip either way, at about 1.2k req/s with one
connection and 7–8k with 64.
