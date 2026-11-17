---
description: A small key/value cache with lifetimes, in the process or in Redis, that never fails a request.
---

# Cache

Some answers are expensive to work out and change rarely: the list of recent posts, a count across a big table, the reply of a slow third-party API. Working them out again on every request makes your app slower than it needs to be. A cache keeps the answer for a while so the next request gets it for free.

nexus-cache is a small key/value cache for exactly that. Keys and values are strings, each entry has a lifetime, and it keeps its entries in the process or in Redis. Better still, a cache that is down never takes your app with it: it just makes it slower.

To add it, require the module in your app's `module.eco`, plus the Redis module if the cache may live in Redis:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/cache" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/cache/redis" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list their extensions, the Redis one after the cache one:

```echo title="src/Extensions.eco"
nexus::cache::Extension(),
nexus::cache::redis::Extension(),
```

## Getting or making a value

The extension binds one `nexus::cache::Cache` for the whole process. The call most code wants is `get` with a callback: it returns the cached value, or runs the callback, keeps what it made, and returns that:

```echo
$cache = $payload->get<nexus::cache::Cache>();
string $recent = $cache->get('posts:recent', .expires(.mins(5)), () => recentPosts($posts));
```

Here `recentPosts()` stands for whatever your app does to work the value out. The first request in five minutes runs it, and every one after it gets the kept string until the entry expires. The lifetime always comes before the value or the callback.

Since values are strings, you will usually cache something you have already written out, like a JSON document. Keeping the cache to strings means it works the same in memory and in Redis, with no surprises about what survives the trip.

### Lifetimes

Every entry has a `nexus::cache::Lifetime`:

```echo
string $flags = $cache->get('flags', .forever, () => loadFlags($settings));
string $stats = $cache->get('stats:posts', .expires(.hours(1)), () => countPosts($posts));
```

`.forever` keeps the entry until it is forgotten, flushed or evicted. `.expires(...)` drops it once the duration has passed. A lifetime of zero or less keeps nothing at all.

If you leave the lifetime out, `NEXUS_CACHE_TTL` applies, an hour by default:

```echo
string $recent = $cache->get('posts:recent', () => recentPosts($posts));
```

### A callback that may fail

Sometimes making the value can fail, like a query that errors out. You don't want that failure cached, and you do want to hear about it. You may give `get` a callback that returns a `result`: its value is kept, its error comes back to you as it is, and nothing is kept:

```echo
string $recent = try $cache->get('posts:recent', .expires(.mins(5)), function[$posts]() : result<string, nexus::Problem> {
    return $posts->recentJson();
});
```

Here `recentJson()` stands for any method of your own that may fail. The next call simply tries again.

## When the cache fails

So, what happens when Redis goes away in the middle of the day? With the callback `get`, nothing your users will notice: a read that fails counts as a miss, so the callback runs, and a write that fails is a warning in the log. The request is answered either way, only slower.

That is the point of a cache: it is there to make things fast, not to be another thing that can break your app. A slow Redis is a miss too, since each command may only take `NEXUS_CACHE_TIMEOUT` (500ms by default).

## Reading and writing directly

You may also read and write entries yourself. These calls do report failures, so you decide what to do with them:

```echo
result<string?, nexus::cache::CacheError> $hit = $cache->get('posts:recent');
status<nexus::cache::CacheError> $kept = $cache->put('posts:recent', .expires(.mins(5)), $json);

$cache->forget('posts:recent');
$cache->flush();
```

`get` without a callback answers `null` for a key that is not there, and `put` without a lifetime uses the default one. `forget` drops one entry, which is what you want right after the data behind it changed, like a new post being published. `flush` drops every entry of the cache, and `nexus::cache::CacheError` says why any of these failed.

You may clear the cache from the command line too:

```sh
blog cache:clear
```

## Where entries are kept

`NEXUS_CACHE_URL` picks the store:

- `memory:` keeps entries in the process. This is the default. They are gone when it stops, and each server has its own, so it suits one server, development and tests. Past `NEXUS_CACHE_MAX_ENTRIES`, expired entries go first, then the ones that expire soonest, a tenth of the limit at once.
- `redis://user:pass@host:6379/db` keeps them in Redis, shared by every server and every restart. Needs nexus-cache-redis.

In Redis, every key starts with `NEXUS_CACHE_PREFIX`, so the cache may share a database with other data. `flush` and `cache:clear` forget only the keys under that prefix, never the whole database. That is why an empty `NEXUS_CACHE_PREFIX` stops the boot with Redis.

nexus-cache-redis pings the server once at boot, and one that does not answer stops the boot with a message. With any URL other than `redis://`, it steps aside, so your tests may run on `memory:` with the same extension list.

> [!NOTE]
> `rediss://` is refused for now: the Redis client has no TLS yet. Reach a remote Redis over a private network or a tunnel.

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_CACHE_URL` | `memory:` | Where entries are kept: `memory:` or `redis://user:pass@host:6379/db`. |
| `NEXUS_CACHE_TTL` | `1h` | How long an entry is kept when the code names no lifetime. |
| `NEXUS_CACHE_PREFIX` | `cache:` | For Redis: what every key starts with. |
| `NEXUS_CACHE_TIMEOUT` | `500ms` | For Redis: how long one command may take, connecting included. |
| `NEXUS_CACHE_MAX_ENTRIES` | `100000` | For memory: how many entries are kept at most. |

[Configuration](./configuration.md) covers how these are read.

## Testing with the cache

In tests, `memory:` is what you want, and it is already the default. If you would like to see how your code behaves when the cache is down, you may hand the extension a store of your own, a class conforming to `nexus::cache::Store`, with `nexus::cache::Extension(store: ...)`. The module's own tests do exactly that with a store whose every call fails, and check that the request is still answered and the warnings are logged. [Testing](./testing.md) has the rest.

Every cache call on a request is also marked on that request's timeline in the [debug console](./debug.md), with whether it was a hit or a miss.

## Where to next

- [Database](./database.md): where the values you cache usually come from.
- [Debug console](./debug.md): watching hits and misses on a request.
- [Deployment](./deployment.md): running Redis next to several servers.
