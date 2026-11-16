---
description: What happens from the moment the app binary starts until a request has its answer, step by step.
---

# The request lifecycle

Any tool feels more comfortable once you know how it works underneath. This page walks one nexus app from the moment its binary starts to the moment a request gets its answer, so that nothing later in the docs feels "magical."

If not every term clicks on the first read, don't worry. Each step links to the page that covers it in full, and most of it will feel obvious once you have built an endpoint or two.

## The big picture

A nexus app is **a list of extensions**. The HTTP server is an extension, the database is an extension, and your app is an extension too, listed last. Here is the blog's, trimmed:

```echo title="src/Extensions.eco"
public function extensions() : array<nexus::Extension>
{
    array<nexus::Extension> $all = [
        nexus::http::Extension(),
        nexus::carbon::Extension((nexus::carbon::DatabaseConfig $config) => Blog::DB::open($config), Blog::DB::migrations()),
        nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),
        nexus::auth::carbon::Extension(),
        nexus::work::Extension(),
        // ...
        Blog::App(),
    ];
    return $all;
}
```

And `main.eco` is one line:

```echo title="src/main.eco"
nexus::Kernel::main(Blog::extensions());
```

Everything else follows from those two files. Think of the kernel as a black box: hand it the extensions, and it hands back a command line whose `serve` command answers requests.

## Starting the process

`nexus::Kernel::main` hands the process to the app's command line. It reads two options that every command shares:

- `--mode <dev|test|prod>`, or `NEXUS_MODE`: what the process is for. `dev` logs pretty lines and shows problem details; `prod` logs JSON lines and keeps internal error causes to itself.
- `--env-file <path>`, `.env` by default: extra settings, read after the real environment.

Then it runs the command you asked for: `serve`, `routes`, `doctor`, `env`, or one an extension or your app added, such as `migrate` or `posts:show`. The [commands](./commands.md) page lists them all.

## Booting the kernel

Every command that needs the app boots it first. The boot runs once, in this order:

### 1. Configuration is loaded

Each `#[nexus::config]` struct, in your app and in every module, is filled from the environment, then the `.env` file, then its defaults, and bound in the container. A malformed value stops the boot here, with the variable's name. That is why `services()` may already read a config: `$s->get<DatabaseConfig>()` just works. See [configuration](./configuration.md).

### 2. Commands are collected

Each extension's `commands()` hook records its commands. Nothing is built yet; the command line only needs the names.

### 3. Extensions wire the app

Each extension's `services()` hook runs, in list order. This is where bindings go into the container and actions onto routes. Because your app comes last, its bindings may replace anything an earlier extension bound. [Extensions and wiring](./extensions.md) covers this hook in detail.

### 4. The container is sealed and checked

Now the container is sealed, and the kernel checks everything it can before a single request arrives:

- every route's action is bound, and `nexus gen` wrote a dispatcher for it;
- every middleware a route or an action names is bound;
- every rule class an input names is bound;
- every binding is built once, in a throwaway request, so a missing dependency, a cycle, or a shared service that takes a per-request one stops the boot with its whole chain.

So, what happens if you forget to bind something? The process refuses to start and says exactly what is missing. You never learn about it from a 500 in production.

### 5. Middleware and boot hooks

Each extension adds its global middleware through `middleware()`, then each `boot()` hook runs. The blog uses `boot()` to load its German translations, for example.

## Serving

`serve` asks the first extension that brings a transport (nexus-http) to listen. Before it does, each extension's `start()` hook runs: this is where nexus-work starts its workers and the scheduler, and where the blog starts its live stats feed.

From then on the transport calls `Kernel::handle()` for every request, from many threads at once.

## Inside one request

Let's follow `POST /v1/posts` through `handle()`.

### The request gets an id and a scope

The request is given an id: the client's `X-Request-Id` if it sent a sane one, a fresh one otherwise. It goes back in the response's `X-Request-Id` header and onto every log line of the request.

Next, the request gets its own **child container**. Everything bound with `scoped:` (a database session, the repositories on it, the action itself) is built in that container, lives as long as the request, and is dropped with it. This is why actions and per-request services need no locking.

### The route is found first

The router matches the method and path before any middleware runs, so a global middleware can already tell which action it is guarding. Path parameters are captured here. If nothing matches, the request carries on anyway; it is answered `404` or `405` at the end of the chain, after middleware such as CORS has had its say.

### Middleware, outside in

The request then passes through middleware in four layers, from the outside in:

1. the extensions' global middleware;
2. the app's middleware around every request (`$app->middleware<ServerTiming>()`);
3. the route's own middleware;
4. the action's `#[nexus::through]`, such as the blog's `RequireUser`.

Each layer may answer early (a `401` for a missing session, say) or put what it learned into the payload for the action to read. [Middleware](./middleware.md) has the details.

### The action runs

The dispatcher `nexus gen` wrote for this action now does the boring part: it decodes the body into a `NewPost`, checks every rule on it, converts path parameters, builds the action from its factory, and calls `handle()`. A body that fails validation is answered with one `422` and the action never runs.

Whatever `handle()` returns becomes the response: a `nexus::Response` as it is, JSON as JSON, a `nexus::Problem` as an RFC 9457 document. See [actions](./actions.md) and [problems](./problems.md).

### Finishing up

On the way out, the kernel stamps `X-Request-Id`, strips the body of a `HEAD` response, writes one access log line (`POST /v1/posts 201` with its duration and action), and drops the request's container, which hands the database connection back to its pool.

We have now traced the whole path of a request.

## Stopping

When the process is asked to stop, the transport stops accepting connections and lets the requests in flight finish. Then each extension's `drain()` hook runs, in reverse order, so workers finish their tasks and streams close cleanly. Finally `shutdown()` runs, also in reverse. The [deployment](./deployment.md) page shows how to give that drain enough time.

## Where the generated code fits

You may be wondering where the "generated" part comes in. Two halves meet at boot:

- **Registration by hand.** Where each action answers, which commands exist, which tools are offered: you write that in code, in `services()`, where you can read it.
- **Generation by type.** How each action is called, how each input is decoded and checked, how each config is loaded: `nexus gen` writes that into `.nexus/nexus.eco` from the types alone, before every build.

The kernel finds the generated tables at compile time, keyed by type, and checks at boot that the two halves agree. [nexus gen](./generator.md) explains what it writes and why.

## Where to next

- [Extensions and wiring](./extensions.md): the hooks you just met, and how to write your own.
- [Actions](./actions.md): the code at the very center of a request.
- [Middleware](./middleware.md): the four layers around it.
