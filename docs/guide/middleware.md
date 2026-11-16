---
description: Code that runs around actions. The four places middleware can go, the order they run in, and how middleware hands what it learned to the action.
---

# Middleware

Some work belongs to many endpoints at once. Every answer should say how long it took. Nothing under `/v1` should answer without a session. Every endpoint that writes needs a signed in user. You could repeat that code in every action, but then one forgotten line becomes a hole.

Middleware is code that wraps request handling. It sees the request before the action does, may answer early (a `401`, a `403`), and may adjust the response on the way out. Think of it as layers around the action: each layer decides whether to call the next one, and gets the response back when it does.

nexus lets you put middleware in four places, from "around everything" to "around this one action". Let's write one first, then look at where it can go.

## Writing middleware

A middleware is a class conforming to `nexus::Middleware`, with one `handle()` method. It gets the request's payload and `$next`, the rest of the chain. Here is the blog's simplest one, which adds a `Server-Timing` header to every answer:

```echo title="src/Middleware/ServerTiming.eco"
namespace Blog::Middleware;

/**
 * Says how long the app took on every answer, in a `Server-Timing` header a browser's network panel
 * shows.
 */
public class ServerTiming : nexus::Middleware
{
    public function handle(nexus::Payload& $payload, nexus::Next $next) : nexus::Response
    {
        $r = $next->run($payload);
        $ms = ($payload->started->elapsed()->as_micros() as float64) / 1000.0;
        $r->header('Server-Timing', "app;dur={$ms}");
        return $r;
    }
}
```

`$next->run($payload)` runs everything inside this layer, eventually the action, and hands back its response. Code before that call runs on the way in; code after it runs on the way out.

### Answering early

To stop a request, return a response instead of calling `$next`. `$payload->fail()` renders a [problem](./problems.md) the way an action's would be, logged when it is the server's fault. The blog's admin guard:

```echo title="src/Middleware/RequireAdmin.eco"
#[atomic]
public class RequireAdmin : nexus::Middleware
{
    public function handle(nexus::Payload& $payload, nexus::Next $next) : nexus::Response
    {
        $me = guard $payload->state<Caller>() else ($p) {
            return $payload->fail($p);
        };
        if ($me->user->role != Role::admin) {
            return $payload->fail(nexus::Problem::forbidden('this needs an admin'));
        }
        return $next->run($payload);
    }
}
```

When it refuses, nothing inside it runs. The action never sees a request that is not an admin's.

### Binding it

Middleware comes from the container, like any other service. Bind it where the app is wired, with whatever it needs:

```echo title="src/Providers/AuthProvider.eco"
$app->bind<RequireUser>(scoped: (Container $c) => RequireUser($c->get<nexus::auth::Guards>(), $c->get<UserRepository>()));
$app->bind<RequireAdmin>(shared: () => RequireAdmin());
```

`RequireUser` takes the users repository, which lives on the request's database session, so it is bound `scoped:` and built fresh for each request. `RequireAdmin` needs nothing, so one shared instance does; a shared service is used by many threads at once, which is why it is marked `#[atomic]`. If you name middleware you never bound, the boot stops and says which one.

## Handing state to the action

The most useful middleware does not just let a request through; it works something out on the way. `RequireUser` finds out who signed the request, and the action wants to know too. Asking the database again in every action would be wasteful, so the middleware leaves what it learned in the payload with `put`:

```echo title="src/Middleware/RequireUser.eco"
public function handle(nexus::Payload& $payload, nexus::Next $next) : nexus::Response
{
    $id = guard $this->guards->demand($payload) else ($r) {
        return $r;
    };
    $user = guard BlogUsers::of($this->users, $id->subject) else ($p) {
        return $payload->fail($p);
    };
    $payload->put<Caller>(Caller($id, $user));
    return $next->run($payload);
}
```

The state is a type of your own. The blog's `Caller` holds the credential and the user it names:

```echo title="src/Types/Caller.eco"
public struct Caller
{
    public nexus::auth::Identity $identity;
    public User $user;
}
```

Anything that runs later in the same request reads it back with `state<T>()`: an action, or another middleware further in. That is how `RequireAdmin` above knows who is asking:

```echo
$me = try $payload->state<Caller>();
```

So, what if nothing put a `Caller`? That is a mistake in the wiring, not in the request, so the client gets a `500` and the log names the action and the type it asked for. When the state is genuinely optional, ask with `$payload->find<T>()`, which gives you `null` instead.

State lives in the request's own container and is gone when the request ends, so nothing leaks from one request into the next.

## Where middleware goes

There are four places, from the outside in:

| Where | Declared with | Runs for |
|:--|:--|:--|
| An extension's global middleware | `middleware(nexus::Pipeline& $p, ...)` | every request |
| The app's middleware | `$app->middleware<M>()` | every request |
| A route's middleware | `->middleware<M>()` after `->route()` | the routes of one action |
| The action's own | `#[nexus::through: [...]]` | the action, on every route and as an MCP tool |

A request passes through them in that order, and the response comes back out in reverse. Routing sits between the app's middleware and the route's: a request that matches no route is answered with a `404` or `405` at that point, after the outer two layers have run.

### The app's middleware

Middleware that should wrap every request goes on the app. The blog times every answer and requires a session for everything under `/v1`:

```echo title="src/App.eco"
// every answer says how long it took
$app->bind<ServerTiming>(scoped: () => ServerTiming());
$app->middleware<ServerTiming>();

// nothing under /v1 answers without a signed session, but opening one
$app->bind<nexus::auth::RequireSession>(shared: (Container $c) => nexus::auth::RequireSession(
    $c->get<nexus::auth::Guards>(), under: '/v1', except: [type_id<Blog::Actions::Auth::OpenSession>()]));
$app->middleware<nexus::auth::RequireSession>();
```

They run in the order you add them, each taken from the request's container on every request, so they may depend on per-request services. [Tasks](./tasks.md) and [commands](./commands.md) do not go through them; they are about HTTP requests.

Although this middleware runs before the route's own, the route has already been found. `$payload->route` holds it (or `null` when nothing answers), so a middleware that wraps everything may still tell which action a request is headed for. That is how `RequireSession` leaves one action out by type:

```echo
nexus::Route $route = guard $payload->route else {
    // nothing answers this path; routing will say 404 or 405
    return $next->run($payload);
};
```

### An action's own middleware

When an action cannot work without some middleware, name it on the action itself with `#[nexus::through]`. The names are the classes' qualified names, run in the order listed:

```echo title="src/Actions/Admin/StreamStats.eco"
#[nexus::through: [
    "Blog::Middleware::RequireUser",
    "Blog::Middleware::RequireAdmin"
]]
public class StreamStats : nexus::Action
{
    // ...
}
```

The order matters here: `RequireAdmin` reads the `Caller` that `RequireUser` puts, so it has to come second.

This is the place for anything the action relies on, because it travels with the action. It runs on every route the action is bound to and around every call when the action is offered as an [MCP tool](./mcp.md), so the guard can never be forgotten on one door. Tool classes may name `#[nexus::through]` too, and it runs around each of their calls.

### A route's middleware

Sometimes middleware is about where an action answers rather than what it does: an audit trail on one public path, a rate limit on one route. You may add it to the routes when you wire them:

```echo
$app->bindAction<UpdatePost>((Container $c) => UpdatePost($c->get<PostService>(), $c->get<PostTransformer>()))
    ->route([.put, .patch], '/v1/posts/{id}')
    ->middleware<Audit>();
```

It wraps every route of that action, whether declared before or after it, and runs outside the action's own `#[nexus::through]`. It does not run when the action is called as an MCP tool. So the rule of thumb: if the action is broken without it, use `#[nexus::through]`; if it is about this URL, use the route.

### An extension's global middleware

[Extensions](./extensions.md) may add middleware around every request in their `middleware` hook. It runs outermost, before the app's own. The debug console records requests this way:

```echo
public function middleware(nexus::Pipeline& $p, Container $services) : void
{
    // ...
    $p->add(Recorder($debug, $requests, $traces), name: 'nexus::debug::Recorder');
}
```

The hook runs once, after the container is sealed, so it may take services from `$services`. Unlike the other three kinds, a global middleware is built once and shared by every worker thread. Its class must be `#[atomic]` and must keep no per-request state in its fields; anything about the request goes in the payload. The `name` is what the request's timeline shows in the [debug console](./debug.md).

Most apps never write one. The app's own middleware covers "every request" and may take per-request services, which a global one cannot.

## Middleware chosen while wiring

Occasionally an extension is handed middleware to apply, rather than naming a type itself. The debug console, for example, takes the app's own guards for its pages. For that, `nexus::MiddlewareRef::of<M>(name)` describes middleware `M` by value, and `->through($refs)` on the `nexus::ActionRef` that `$s->bindAction()` returns applies a list of them where `->middleware<M>()` would. You will only need this when writing an extension.

## Where to next

- [Authentication](./auth.md): the guards behind `RequireUser`, sessions and tokens.
- [Problems and errors](./problems.md): what `$payload->fail()` sends and how it is logged.
- [The request lifecycle](./lifecycle.md): everything that happens to a request, in order.
