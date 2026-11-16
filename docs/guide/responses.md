---
description: Building nexus::Response by hand. JSON, text and HTML, headers, redirects, file downloads with ranges, streamed bodies, server-sent events and websockets.
---

# Responses

Most actions answer with a model, and a [transformer](./transformers.md) turns it into a response: the JSON document, the status, the includes. That covers the bulk of an API. But sooner or later an endpoint needs to answer with something else: a page of HTML, a redirect, an image with the right caching headers, or a feed of live numbers that stays open.

For all of those you build a `nexus::Response` yourself. This page walks through each kind, from a line of text to a stream that outlives the request.

## Basic responses

A `nexus::Response` is a status, headers and a body. You will rarely set those one by one, since each common kind of body has a constructor that sets the `Content-Type` for you:

```echo plain
$r = nexus::Response(json: $doc);                  // application/json
$r = nexus::Response(text: 'ok');                  // text/plain; charset=utf-8
$r = nexus::Response(html: $page);                 // text/html; charset=utf-8
$r = nexus::Response(201, $csv, type: 'text/csv'); // any type you name
$r = nexus::Response(202);                         // a status, no body
$r = nexus::Response::noContent();                 // 204
```

The `json:`, `text:` and `html:` forms answer `200` unless you pass `status:`, as in `nexus::Response(json: $doc, status: 201)`.

Here is the blog's home page, a single HTML file embedded into the binary at build time:

```echo title="src/Actions/Home.eco"
public class Home : nexus::Action
{
    public function handle() : nexus::Response
    {
        $r = nexus::Response(html: std::embed::text('../../resources/web/index.html'));
        $r->header('Cache-Control', 'no-cache');
        return $r;
    }
}
```

Because `handle()` here cannot fail, it returns a plain `nexus::Response`. When it can, return `result<nexus::Response, nexus::Problem>` and wrap the answer in `.ok(...)`. [Actions](./actions.md) lists every return type `handle()` may have, including the shortcuts for JSON and text.

## Headers

`header()` sets a header, replacing any earlier one of the same name. Names compare without regard to case:

```echo
$r->header('Cache-Control', 'private, max-age=60');
```

A few headers may appear more than once, `Set-Cookie` being the usual one. For those, add a line to `headers` instead of replacing:

```echo
$r->headers->add('Set-Cookie', 'theme=dark; Path=/; SameSite=Lax');
$r->headers->add('Set-Cookie', 'lang=de; Path=/; SameSite=Lax');
```

You may read one back with `$r->header('Cache-Control')`, which gives you the first value or `null`.

A few headers are set for you on every answer. `X-Request-Id` carries the request's id, so a client can quote it in a bug report and you can find the matching lines in the log. A `HEAD` request gets the headers and status of the `GET` answer with the body dropped. [Middleware](./middleware.md) is the place for headers that belong on every response, like the blog's `Server-Timing`.

## Redirects

To send the client somewhere else, answer with `redirect:`. It is a `302` unless you choose another status:

```echo
return nexus::Response(redirect: '/signed-in');
return nexus::Response(redirect: '/v1/posts', status: 303);
```

For a redirect to one of your own actions, let the [router](./routing.md#building-links-to-an-action) build the link rather than writing the path twice. `redirect:` takes a `nexus::Url` as well:

```echo
return .ok(nexus::Response(redirect: $this->router->url<ShowPost>(['id' => "{$post->id}"]), status: 303));
```

A relative `Location` is fine for browsers and most clients. When you need it absolute, put the link on the request's origin with `->on($payload->request->url())`, or on `NEXUS_APP_URL` with `absoluteUrl<A>()`.

## Files and downloads

Sending a file well is more work than it looks. A browser wants to resume a broken download with a `Range` header, skip one it already has with `If-None-Match`, and be told whether to show the file or save it. And a file someone uploaded must never run script on your app's origin. `nexus::Download` handles all of that.

You describe the file (its type, its size, and if you know them, its version and when it changed) and ask it to answer the request:

```echo
nexus::Download $d = nexus::Download('image/png', $stat->size, etag: $stat->etag, modified: $stat->modified);
$d->name = 'cover.png';
$d->inline = true;
return .ok($d->respond($payload->request, file: $path));
```

`respond()` picks the answer for you: the whole file (`200`), the part a `Range` asks for (`206`), a `304` when the client's copy is current, or a `416` for a range past the end. With `file:`, the transport sends the bytes straight from disk, with `sendfile` where it can. When the bytes are in memory already, pass `bytes:` instead:

```echo
nexus::Download $d = nexus::Download('text/markdown', 0);
$d->name = "post-{$post->id}.md";
return .ok($d->respond($payload->request, bytes: $markdown));
```

Their size stands over the one you stated, so `0` is fine when you only know it after reading them.

Every download says `X-Content-Type-Options: nosniff`, and every type but PDF is served under `Content-Security-Policy: sandbox`. `name` is the file name a browser saves it under. `inline` asks for it to be shown in the browser instead, which only happens for types a browser shows without running anything: common images, PDF, plain text, audio and video. SVG and HTML are always attachments.

In practice, you'll rarely build a `Download` yourself. A [disk](./files.md) does it for you, and the blog's covers are answered that way:

```echo title="src/Services/CoverService.eco"
string $ext = nexus::files::Keys::extension($key);
return $this->covers->respond($payload, $key, name: "post-{$id}-cover.{$ext}", inline: true);
```

On a local disk that is a `Download` from the file; on S3 it is a redirect to a link the store signed.

## Streamed bodies

Occasionally a body is not ready when the action returns: a large export written row by row, a report that takes a while. You may hand the response a function that writes the body as it goes:

```echo
array<string> $lines = try $this->exports->postsAsCsv();
return .ok(nexus::Response(stream: function[$lines](nexus::Writer $w) : void {
    foreach ($lines as const &$line) {
        if (!$w->write("{$line}\n")) {
            return;
        }
    }
    $w->flush();
}, type: 'text/csv; charset=utf-8'));
```

`write` queues bytes and `flush` sends them; both return `false` once nobody reads any more, which is your cue to stop. A writer that runs until it is told to stop should check `$w->open()` between writes.

> [!WARNING]
> The transport calls the function after the request has been answered, when the request's container has been dropped. Capture only what outlives the request: plain values, as above, or shared `#[atomic]` services. Never capture a scoped service such as a repository on the request's database session.

## Server-sent events

Sometimes a page wants a continuous, one-way feed from the server: a dashboard's numbers, the lines of a log as they come. Polling for that is wasteful, and a websocket is more than you need. Server-sent events are exactly this: one long response the server keeps writing events into, which a browser reads with `EventSource`.

The blog's admins watch the blog's numbers this way. The action answers with `nexus::Response(events:)`, handing over two hooks: one for when the stream opens and one for when it ends:

```echo title="src/Actions/Admin/StreamStats.eco"
#[nexus::through: [
    "Blog::Middleware::RequireUser",
    "Blog::Middleware::RequireAdmin"
]]
public class StreamStats : nexus::Action
{
    private StatsFeed $feed;

    public constructor(StatsFeed $feed)
    {
        $this->feed = $feed;
    }

    public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
    {
        $me = try $payload->state<Caller>();
        json::Value $now = try StatsFeed::snapshot($payload);
        StatsFeed $feed = $this->feed;
        nexus::auth::Identity $who = $me->identity;
        return .ok(nexus::Response(events: function[$feed, $now, $who](nexus::EventStream $s) : void {
            $feed->watch($s, $now, $who);
        }, closed: function[$feed](nexus::EventStream $s) : void {
            $feed->forget($s);
        }));
    }
}
```

The transport writes the head (`text/event-stream`, never cached), runs the open hook with the stream, and then keeps the connection without holding a thread for it. Whoever keeps the stream sends to it later, from any thread. The close hook runs once when the stream ends: the client left, someone closed it, or the server is stopping.

Notice that the action did its real work up front: it checked who is asking and read the first snapshot while the request's services were still there. The hooks capture only `$feed`, a shared `#[atomic]` service, and plain values. As with streamed bodies, the request's container is gone by the time they run.

### Sending events

A stream takes `nexus::ServerEvent`s. Each has data, and may have a name (what `EventSource` listens for) and an id (what a reconnecting browser sends back as `Last-Event-ID`):

```echo
$s->send(nexus::ServerEvent(json: $now, $event: 'stats', $id: "{$n}"));
```

The `json:` form writes the document as compact JSON on one line. `send` returns `false` once the stream is closed or the client is gone, `comment` writes a line clients ignore, and `close` ends the stream. Every open stream gets a heartbeat comment every `NEXUS_HTTP_SSE_BEAT` (15 seconds), so a proxy does not time out a quiet one.

### Feeding many streams

You'll usually send the same event to everyone watching. `nexus::EventStreams` is a set of streams for exactly that: `publish` queues an event, and a thread of the set's own writes it to every stream, so a slow client never holds up the others. Keep one per feed, in a shared service:

```echo title="src/Feeds/StatsFeed.eco"
#[atomic]
public class StatsFeed
{
    public nexus::EventStreams $streams = nexus::EventStreams();

    // ...

    public function publish(const json::Value& $now) : void
    {
        $this->streams->publish($this->event($now));
    }
}
```

`add` and `remove` put a stream in and take it out (the close hook calls `remove`). `join` adds a stream with a backlog of events it should get first, which is how `StatsFeed` sends a new watcher the current numbers at once and every snapshot after, never one twice. `closeAll` ends them all, for when the app stops.

When events belong to one thing (the watchers of one order, one chat) rather than one feed, `nexus::EventRooms` groups streams by a key. A write and a watch of the same key take that room's lock, so someone who joins gets the backlog and then everything new, never a gap.

::: tip Events or channels?
Server-sent events are for an explicit, one-way feed. When clients follow many things at once and the app broadcasts to whoever follows them, reach for [realtime channels](./realtime.md) instead.
:::

## Websockets

At the bottom of [realtime channels](./realtime.md) sits a plain websocket, and you may answer with one yourself. `nexus::Response(websocket:)` upgrades the connection and hands it to the hooks you give:

```echo
public function handle() : nexus::Response
{
    nexus::SocketHooks $hooks = nexus::SocketHooks()
        ->onMessage(function(nexus::Socket $s, nexus::SocketMessage $m) : void {
            // say every text message back
            match ($m) {
                nexus::SocketMessage::text($t) => {
                    $s->send($t);
                },
                else => {},
            }
        });
    return nexus::Response(websocket: $hooks);
}
```

`onOpen` runs once the upgrade is done, `onMessage` for each whole message, and `onClose` at the end. The transport calls them on its own threads, one at a time per socket, so keep each one short. A bad handshake is refused by the transport before any hook runs. The same rule as for streams applies: the hooks run after the request's container is dropped. Most apps never need this and use channels instead.

## Where to next

- [Transformers](./transformers.md): answering with your models as JSON, with includes and pagination.
- [Files](./files.md): disks, signed links, and answering with a stored file.
- [Problems and errors](./problems.md): answering when something went wrong.
