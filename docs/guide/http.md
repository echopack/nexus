---
description: nexus-http serves your app over HTTP/1.1. Where it listens, how many threads answer, the limits and timeouts it enforces, the proxy in front, and how it stops.
---

# The HTTP server

Your app needs something that takes a connection, reads a request off it and writes the answer back. In nexus that is a transport, and the HTTP/1.1 one lives in the `nexus-http` module. Add it to your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/http" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list it first in your app's extensions:

```echo title="src/Extensions.eco"
// the HTTP/1.1 server behind `serve`; nexus itself routes every request
nexus::http::Extension(),
```

That is all the wiring there is. The extension brings the transport `serve` answers through, and without it `serve` stops right away with `no extension brings a transport; add nexus::http::Extension() to main.eco`. Every other command (`migrate`, `routes`, your own) runs without it, so a worker image that never serves HTTP may leave it out.

Under the hood the server is [libhttp](https://github.com/echolang/libhttp). nexus-http keeps libhttp's own router empty and hands every request, through one wrap, straight to the kernel. That means nexus owns routing, the `404`, the `405` and `HEAD`, exactly as the [request lifecycle](./lifecycle.md) describes, and nothing about your routes depends on the server underneath.

## Serving your app

Build your app and run its binary with `serve`:

```sh
./ecobuild/blog serve
```

It listens on `127.0.0.1:3246` and answers until you press Ctrl-C. `127.0.0.1` is reachable from your own machine only, which is the safe default while you develop. To listen somewhere else, pass `--listen`, or set `NEXUS_LISTEN` once for every run:

```sh
./ecobuild/blog serve --listen 0.0.0.0:8080
NEXUS_LISTEN=0.0.0.0:8080 ./ecobuild/blog serve
```

`--listen` wins when both are given. It accepts `host:port`, `:port` (the default host), a bare port, and `[ipv6]:port`. An IPv6 address always goes in brackets: `1::2:3` is an address of its own, not `[1::2]:3`, so nexus refuses it rather than guess.

`serve` warns you about two settings that are fine on your machine and risky anywhere else: dev mode on an address other machines reach (clients would see the cause of every error), and a missing `NEXUS_APP_URL` outside dev. [Deployment](./deployment.md) covers both.

### Worker threads

Requests are answered on worker threads, and by default there is one per CPU core. You may choose the count yourself with `--workers`:

```sh
./ecobuild/blog serve --workers 8
```

`0` means one per core. A worker runs one request at a time from start to finish, database queries included, so an app that spends most of a request waiting on its database may want more workers than cores.

Every request runs on its own [container](./extensions.md) scope, so your actions never share per-request state across threads and need no locking of their own.

## How a request reaches your app

Each request goes through the same few steps on its way in:

- The method is read. `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD` and `OPTIONS` are routed; a verb nexus does not know gets `501 Not Implemented`.
- The client's address is worked out, behind a proxy too (see below), and lands on `$payload->request->peer`.
- The kernel matches the route. No route at that path is a `404`; a route at the path but not for this method is a `405` with an `Allow` header; an `OPTIONS` request for a known path gets `204` with `Allow`.
- `HEAD` falls back to the `GET` route, and the body is dropped before it goes out.
- Every answer carries an `X-Request-Id`: the one the client sent, if it looks sane, or a fresh one.

The answer itself may be plain, streamed in chunks, a file sent straight from disk (with `sendfile` where the system has it), an event stream, or a websocket upgrade. [Responses](./responses.md) shows how an action asks for each.

## Behind a reverse proxy

nexus-http speaks plain HTTP/1.1. TLS belongs to the reverse proxy or load balancer in front of it (nginx, Caddy, HAProxy, your cloud's balancer), which terminates HTTPS and forwards the request.

That raises a question: once a proxy forwards every request, every request seems to come from the proxy. So, how does the app learn who the client is? Proxies add `X-Forwarded-For` and `X-Forwarded-Proto` headers, but a client may send those too, so nexus only believes them from addresses you name in `NEXUS_HTTP_TRUSTED_PROXIES`:

```sh
NEXUS_HTTP_TRUSTED_PROXIES=10.0.0.2,10.0.0.3
```

Each entry is an address or a range, which helps with load balancers whose addresses change:

```sh
NEXUS_HTTP_TRUSTED_PROXIES=10.0.0.0/8,fd00::/8
```

With that in place, a request from a trusted proxy comes from the client its `X-Forwarded-For` names. The header is read from the right, and the first address that is not one of your proxies is the client, so whatever a client wrote at the start of the header is never believed. `X-Forwarded-Proto: https` from a trusted proxy marks the request as `https`, which is what `$payload->request->scheme` and `$payload->request->origin()` report.

A request from anywhere else keeps its socket address, and its forwarding headers are ignored. This matters for more than logs: the sign-in throttle in [authentication](./auth.md) keys on the client's address, so you should list your proxies, or every client shares the one throttle of the proxy.

::: tip
Links your app builds for other services (an OAuth issuer, a sign in callback) should not depend on a `Host` header at all. Set `NEXUS_APP_URL` to your public origin; [deployment](./deployment.md) explains when it is required.
:::

## Limits and timeouts

A server on the open internet meets slow clients, huge uploads and connections that never close. nexus-http has a limit for each, all with sensible defaults, all read from `NEXUS_HTTP_*` variables.

### Request size

A request body larger than `NEXUS_HTTP_MAX_BODY` (8 MiB by default) is answered with `413` before it is read, so a client can't fill your memory with one upload. Raise it if your app takes large files:

```sh
NEXUS_HTTP_MAX_BODY=67108864   # 64 MiB
```

### Slow clients

A client has `NEXUS_HTTP_HEADER_TIMEOUT` (10 s) to send the request line and headers, and then `NEXUS_HTTP_BODY_TIMEOUT` (60 s) to send the body. A client that takes longer gets a `408`. These keep a slow or stalled client from holding a connection open forever.

### Keep-alive

A connection may wait `NEXUS_HTTP_IDLE_TIMEOUT` (75 s) between requests before it is closed, and makes at most `NEXUS_HTTP_MAX_REQUESTS` (1000) requests before nexus closes it.

> [!WARNING]
> Keep the idle timeout longer than the keep-alive of the load balancer in front of you (60 s on most). Otherwise the balancer reuses a connection your app has just closed and answers the client with a `502`.

### Connections

At most `NEXUS_HTTP_MAX_CONNECTIONS` (1024) connections are open at once, counting idle ones, event streams and websockets; past it a new one gets a `503`. Each connection is a file descriptor, so keep this under the process's `ulimit -n`.

## Websockets and event streams

Long-lived connections have settings of their own. An open websocket that stays quiet for `NEXUS_HTTP_WS_PING` (30 s) is pinged, and another interval of silence closes it. A client may send messages up to `NEXUS_HTTP_WS_MAX_MESSAGE` bytes (64 KiB); a bigger one closes the socket with code `1009`.

An open event stream gets a heartbeat comment every `NEXUS_HTTP_SSE_BEAT` (15 s), which keeps proxies from timing out a stream that has nothing to say. Set either to `0` to turn it off.

[Realtime channels](./realtime.md) is where your app actually uses websockets; this page only sets the limits they run under.

## CORS and security headers

nexus-http ships two middleware that most APIs want sooner or later.

When a browser app on another origin calls your API, the browser asks first. `nexus::http::Cors` answers those preflight requests itself and adds the allow headers to every response for an origin you allow. `nexus::http::SecureHeaders` adds the headers every API response should carry: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and `Referrer-Policy: no-referrer`, plus HSTS when you turn it on. A header your action set itself is left alone.

You may add both in your app extension's `middleware` hook:

```echo title="src/App.eco"
public function middleware(nexus::Pipeline& $p, Container $services) : void
{
    array<string> $origins = ['https://blog.example.com'];
    $p->add(nexus::http::Cors($origins));

    $headers = nexus::http::SecureHeaders();
    // served over HTTPS by the proxy in front
    $headers->hsts = true;
    $p->add($headers);
}
```

Middleware from the `middleware` hook runs before anything added with `$app->middleware<M>()`, so `Cors` answers a preflight before a guard such as `nexus::auth::RequireSession` can refuse it. That ordering matters: a preflight never carries credentials, so a guard in front of `Cors` would refuse every one.

`Cors` allows the origins you give it exactly; `'*'` allows any origin, and then never sends credentials. Its public fields (`methods`, `headers`, `expose`, `credentials`, `maxAge`) let you widen or narrow the rest. [Middleware](./middleware.md) has the full story on ordering.

## Stopping cleanly

When `serve` gets `SIGINT` or `SIGTERM`, it stops in order rather than dropping everything at once:

1. The server stops taking connections. Idle connections close at once; requests in flight are left to finish.
2. Once the last one has answered, every extension's `drain` hook runs, last listed first, so task workers and streams stop after the requests that may have fed them.
3. The process exits with `0`.

Requests in flight get `NEXUS_SHUTDOWN_GRACE` (30 s by default) to finish. If one is still running then, or a second signal arrives, the process logs `stopping took too long: quitting with requests still running` and exits, so one stuck request can never hold a deploy hostage.

```sh
NEXUS_SHUTDOWN_GRACE=10s ./ecobuild/blog serve
```

Make your orchestrator's stop timeout a little longer than this grace, so it never kills the process mid-drain. [Deployment](./deployment.md) walks through rolling restarts.

## Settings

| Variable | Default | What it does |
|:--|:--|:--|
| `NEXUS_LISTEN` | `127.0.0.1:3246` | Where `serve` listens; `--listen` wins. |
| `NEXUS_SHUTDOWN_GRACE` | `30s` | How long requests in flight get to finish once `serve` is stopped. |
| `NEXUS_HTTP_TRUSTED_PROXIES` | empty | Proxies whose `X-Forwarded-For` and `X-Forwarded-Proto` are believed; addresses or ranges, comma separated. |
| `NEXUS_HTTP_MAX_BODY` | `8388608` | The largest request body in bytes; a bigger one is a `413`. |
| `NEXUS_HTTP_HEADER_TIMEOUT` | `10s` | Time to send the request line and headers; a `408` after that. |
| `NEXUS_HTTP_BODY_TIMEOUT` | `60s` | Time to send the body once the headers are in; a `408` after that. |
| `NEXUS_HTTP_IDLE_TIMEOUT` | `75s` | How long a connection may wait between requests. |
| `NEXUS_HTTP_MAX_REQUESTS` | `1000` | Requests one connection may make before it is closed. |
| `NEXUS_HTTP_MAX_CONNECTIONS` | `1024` | Open connections at once; past it a new one gets a `503`. |
| `NEXUS_HTTP_WS_PING` | `30s` | Quiet time before an open websocket is pinged; `0` never pings. |
| `NEXUS_HTTP_WS_MAX_MESSAGE` | `65536` | The largest websocket message in bytes; a bigger one closes with `1009`. |
| `NEXUS_HTTP_SSE_BEAT` | `15s` | How often an event stream gets a heartbeat; `0` sends none. |

The worker thread count has no variable; pass `--workers` to `serve`. Durations are written like `30s` or `2m`. [Configuration](./configuration.md) explains how settings are read and checked at boot.

## Where to next

- [Deployment](./deployment.md): running the binary in production, behind a proxy, on several servers.
- [Middleware](./middleware.md): writing your own and ordering them.
- [Realtime channels](./realtime.md): websockets and channels on top of this server.
