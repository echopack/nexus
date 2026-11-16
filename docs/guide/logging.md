---
description: Structured logs with typed fields, request ids, spans and typed records, written as pretty lines, logfmt or JSON. Plus the per-request timeline the debug console draws.
---

# Logging and tracing

A log is only worth what you can find in it later. A line like `post created 12 by 3` reads fine in a terminal, but the day you need every post a certain user created in the last hour, from a JSON log in production, you want `post` and `user` to be real fields, and you want every line of the request that created it to carry the same id.

`nexus::Logger` is built for that. Every entry is a message plus typed key/value fields, every request gets a logger stamped with its own id, and the same entry comes out as a coloured line on your terminal, as logfmt, or as one JSON object per line, depending only on where the app runs. You write the log call once.

## Writing to the log

In an action, the request's logger is on the payload:

```echo
public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
{
    $payload->log->info('listing posts');
    // ...
}
```

Anywhere else, take a `nexus::Logger` through the constructor like any other service. The blog's `PostService` does:

```echo title="src/Providers/PostsProvider.eco"
$app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>(), $c->get<UserRepository>(), $c->get<nexus::Logger>()));
```

The kernel puts the request's own logger in each request's container, so a service bound `scoped:` gets a logger that already knows which request it is logging for. A service bound `shared:` gets the root logger, without a request id.

There is a method per level, from least to most important: `trace`, `debug`, `info`, `warn` and `error`. A logger drops anything below its minimum level, which is `info` unless you configure otherwise.

### Adding fields

The second argument is the fields, written as a map literal of plain values:

```echo
$log->info('post created', ['post' => $post->id, 'user' => $u->id]);
$log->warn('comment broadcast failed', ['channel' => $channel, 'event' => $event, 'error' => $e->message()]);
```

The fields keep their types. Strings, integers, `float64`, `bool`, `time::duration` and `time::timestamp` values may all go in directly, and a `json::Value` is written as embedded JSON. A field whose value is a null `string?` or `int64?` is simply left out, so you do not need an `if` around optional values.

### Adding context with `with`

Sometimes every line from one piece of work should carry the same fields. Rather than repeating them, you may make a child logger with `with`. Everything it writes carries the extra fields, and the parent is unchanged:

```echo
nexus::Logger $log = $k->log->with(['work' => 'scheduler']);
$log->info('due', ['task' => $name]);
```

This is exactly how the request id gets onto every line: the kernel takes `$this->log->with(['req' => $id])` for each request. Children are cheap, and they share their parent's sinks, so you may make one wherever it helps.

## Timing work with spans

When you want to know how long a stretch of work took, open a span. Its logger stamps the span's name and fields on every entry written through it, and when the span goes out of scope it writes `<name> closed` with the time it was open in `ms`:

```echo title="src/Services/PostService.eco"
public function createAll(const User& $author, const array<NewPost>& $in) : result<array<Post>, nexus::Problem>
{
    // the span closes when this returns, and logs `batch closed`
    $span = $this->log->span('batch', ['posts' => $in->count()]);
    // ...
}
```

Write through `$span->log` to have an entry show up inside the span. Spans nest: a span opened from `$span->log` is a child of it, and the logfmt and JSON formats write `span_id` and `parent_id` so you can put the tree back together. The closing line is written at `info`; pass `$close: .debug` when a span is too chatty for that.

Spans are also marks on the request's [timeline](#the-request-timeline), whatever the log level lets through.

## Typed log records

A log line that matters (one you alert on, or count on a dashboard) should not drift because somebody reworded the message. You may give it a type instead: a struct tagged `#[nexus::log]`, whose fields are what it logs.

```echo title="src/Logs/PostPublished.eco"
namespace Blog::Logs;

/**
 * A post went live: written to the log as `post published` with the post, its author and how many
 * tags it has.
 */
#[nexus::log: { level: "info", message: "post published" }]
public struct PostPublished
{
    public int64 $post;
    public int64 $author;
    public usize $tags;
}
```

Write one with `emit`, which takes the struct's fields as its arguments:

```echo title="src/Services/PostService.eco"
$this->log->emit<PostPublished>($made->id, $author->id, $made->tags->count());
```

The level, the message and the field names now live in one place, and the compiler checks every call. `nexus gen` writes the code that turns the struct into an entry. A field of a type the log cannot hold (anything but strings, integers, `float64`, `bool`, durations, timestamps, `json::Value` and their nullables) is refused there, with the file and line.

## Configuring the log

You don't have to set anything up to get a useful log. The command line builds the root logger from the mode the app runs in:

| Mode | Where the log goes |
|:--|:--|
| `dev` | pretty lines on stderr, coloured on a terminal |
| `prod` | JSON lines on stdout |
| `testing` | nowhere |

From there, a handful of environment variables change it. The `env` [command](./commands.md) lists them, and whether each one is set.

| Variable | Default | What it does |
|:--|:--|:--|
| `NEXUS_LOG` | `info` | The lowest level written: `trace`, `debug`, `info`, `warn` or `error`. |
| `NEXUS_LOG_FORMAT` | by mode | `pretty`, `logfmt` or `json`. |
| `NEXUS_LOG_FILE` | | Also append the log to this file. |
| `NEXUS_LOG_ROTATE` | `never` | When the file rotates: `never`, `daily`, or a size like `64mb`. |
| `NEXUS_LOG_KEEP` | `5` | How many rotated files are kept. |
| `NEXUS_LOG_ASYNC` | `8192` under `serve` | A queue size; each sink then gets a writer thread. `0` turns it off. |
| `NEXUS_LOG_OVERFLOW` | `block` | What a full queue does: `block` or `drop`. |

A value that does not read stops the boot with a message naming the variable, such as `NEXUS_LOG_ROTATE must be never, daily or a size such as 64mb, not '64 megs'`.

### Formats

The three formats write the same entry. `pretty` is for people at a terminal, with each span and its fields before the message:

```txt
12:00:01.123 INFO  batch{posts=3}: batch closed req=3f9a1c0e8b7d2a41 ms=18.4
```

`logfmt` writes `key=value` pairs, quoted where needed:

```txt
t=2026-11-09T12:00:01.123Z level=info msg="post published" req=3f9a1c0e8b7d2a41 post=12 author=3 tags=2
```

`json` writes one object per line, with `t`, `lvl`, `msg`, the span keys, then the fields. Numbers and booleans stay numbers and booleans:

```txt
{"t":"2026-11-09T12:00:01.123Z","lvl":"info","msg":"post published","req":"3f9a1c0e8b7d2a41","post":12,"author":3,"tags":2}
```

### Log files

`NEXUS_LOG_FILE` adds a file next to the stream. It is written as JSON unless `NEXUS_LOG_FORMAT` says otherwise, and never coloured. With `NEXUS_LOG_ROTATE` set, `app.log` becomes `app.1.log` when it is full (or at the first entry of a new UTC day), `app.1.log` becomes `app.2.log`, and the file past `NEXUS_LOG_KEEP` is removed.

```sh
NEXUS_LOG_FILE=var/blog.log NEXUS_LOG_ROTATE=daily NEXUS_LOG_KEEP=14 echoc run -- serve
```

Every line is flushed as it is written, so a crash loses nothing.

### Writing on a separate thread

A terminal or a disk can be slow, and you don't want a request to wait on either. `serve` therefore hands every entry to a writer thread through a queue of 8192 entries unless you set `NEXUS_LOG_ASYNC` yourself. The writer takes everything waiting at once and writes it as one batch.

When the queue is full, `block` (the default) makes the logging thread wait for room, so nothing is lost. `drop` drops the entry instead and counts it; once the writer catches up it logs `log dropped entries` with the count. Choose `drop` when a burst of logging must never slow requests down.

Other commands, such as `migrate` or your own, write on the logging thread unless you set the variable, so their output appears in order with what they print.

## Request ids and the access log

Every request gets an id. When the client sends an `X-Request-Id` header of 1 to 64 letters, digits, `-`, `_` or `.`, the kernel adopts it, so a proxy's id follows the request into your log. Otherwise it makes one, sixteen hex characters of fresh randomness. Either way the id is:

- on every line the request logs, as `req`,
- sent back in the response's `X-Request-Id` header,
- in the body of every [problem](./problems.md) the request answers with.

When a user reports an error, ask for that id. It finds every line of their request.

Once a request is answered, the kernel writes one access line through the request's logger: the method, the path and the status, with the time it took and the action that answered.

```txt
12:00:01.140 INFO  GET /v1/posts 200 req=3f9a1c0e8b7d2a41 ms=4.2 action=Blog::Actions::Posts::ListPosts
```

A `5xx` is written at `warn` instead of `info`, so `NEXUS_LOG=warn` keeps the failures and leaves out the noise. The line is only built when some sink would take it.

Work that is not a request, such as a task or a scheduled run, logs with `work` and `id` fields instead of `req`.

## Building a logger yourself

The command line's root logger fits most apps, but you may assemble one yourself, for a tool of your own or a test. A logger is a list of sinks and a minimum level. A sink decides where lines go, a format decides what they look like, so any sink can write any format:

```echo
$file = guard nexus::log::File::open('var/blog.log', .json, $rotate: .daily, $keep: 7) else ($e) {
    // ...
};
array<nexus::log::Sink> $sinks = [
    nexus::log::Stream(.stderr, .pretty),
    nexus::log::Async($file, $capacity: 8192, $overflow: .drop),
];
$log = nexus::Logger(mv $sinks, .debug);
```

The sinks nexus brings:

| Sink | What it does |
|:--|:--|
| `nexus::log::Stream` | Lines on `.stdout` or `.stderr`. `buffered: true` holds lines until a flush, which is what you want behind `Async`. |
| `nexus::log::File` | Appends to a file and rotates it by size or by day. |
| `nexus::log::Async` | Wraps another sink and writes to it on a thread of its own. |
| `nexus::log::Memory` | Keeps entries in memory, for tests: `saw('post published')`, `find(...)`, `entries()`. |

Your own sink conforms to `nexus::log::Sink` and implements `write(const nexus::log::Entry&)`. Sinks are shared by every thread, so `write` must be safe to call concurrently. `Entry::all()` gives you every field, the context's and the call's, in order.

[Testing](./testing.md) boots the app with a `Memory` sink for you, so a test may assert on what was logged.

### The process logger

Now and then code runs where there is no payload and no container to ask, deep in a helper or before boot. `nexus::Logger::process()` reaches the app's root logger from anywhere. Before boot it is pretty lines on stderr from `info` up.

```echo
nexus::Logger::process()->warn('cover cache is cold', ['disk' => $name]);
```

Prefer a logger handed in through the constructor wherever you can: a scoped service's logger carries the request id, the process logger never does.

### Compiling levels away

`NEXUS_LOG` filters at run time, which costs a comparison per call. In a release build where you know `trace` and `debug` will never be wanted, you may compile them away completely:

```sh
echoc build --define NEXUS_LOG_MAX_INFO
```

`NEXUS_LOG_MAX_DEBUG`, `_WARN` and `_ERROR` set the cap at the other levels. One catch: the calls compile to nothing, but their arguments are still built. When a field is expensive to compute, guard it with `enabled`:

```echo
if ($log->enabled(.debug)) {
    $log->debug('plan', ['sql' => $q->render()]);
}
```

### Taps

Sometimes you want a sink added after the app has booted, reaching every logger, including the per-request children that already exist. That is a tap:

```echo
public function boot(nexus::Kernel $kernel) : status<nexus::BootError>
{
    $kernel->log->tap(AuditSink($this->store));
    return .ok;
}
```

A tapped sink sees everything the root logger's own sinks see, at the level `NEXUS_LOG` lets through. The [debug console](./debug.md) shows the app's log live this way. A tapped sink must never log through the logger it is tapped into, or each entry would write another.

Two relatives are useful here. `$log->also($sink)` gives a child that writes to one more sink, the way a task run writes into a channel of its own next to the app's log. `$log->untapped()` gives a child that skips the taps, so the debug console's own requests never show up in the console.

## The request timeline

A log tells you what happened. When a request is slow, you also want to know where the time went: which middleware, which query, which cache call. That is what the trace is for.

A `nexus::trace::Trace` is the timeline of one request. Each middleware, the action, every span the app opens, and every database query, cache call, mail and file read or write is a mark on it, placed in time from the start of the request and nested inside the mark that was open when it began. The [debug console](./debug.md) opens one for each request it records and draws it as a waterfall.

You don't need to do anything to fill it. The kernel marks the middleware and the action, nexus-carbon marks the queries, nexus-cache, nexus-mail and nexus-files mark their own calls, and your [spans](#timing-work-with-spans) show up as marks of kind `span`. When nobody watches, there is no trace at all, and each of those places costs a null check.

### Marking your own work

A span is the easy way to put your own work on the timeline. If you write a shared service that, like the cache, never sees a payload, you may mark its calls directly. Take `nexus::trace::Traces` from the container, ask it for the trace of the current thread, and hold a `nexus::trace::Timed` for as long as the work runs:

```echo
{
    nexus::trace::Timed $t = nexus::trace::Timed($this->traces->here(), .files, 'thumbnail', $key);
    guard $this->render($key) else ($e) {
        $t->fail();
        return .error($e);
    };
}
```

The mark closes when `$t` goes out of scope. `fail()` marks it failed and `note()` adds a word on how it went, such as `hit` or `miss`. Without a trace, `Timed` does nothing.

Two things never appear on a request's timeline: work on other threads, such as an async task the request pushed, and a streamed body, which is written after the request is answered. A trace keeps at most 2000 marks and counts the rest.

## Where to next

- [Debug console](./debug.md): the live log and the timeline, in a browser.
- [Problems and errors](./problems.md): what a failed request logs and answers.
- [Deployment](./deployment.md): log settings for production.
