---
description: A console on the running app with its requests, timelines, log, routes and queues, plus a JSON API agents can read.
---

# Debug console

When something is slow or wrong, the questions are always the same. Which requests came in? Where did this one spend its time: the middleware, the action, a query that ran forty times? What did the app log just now? Which routes does it actually have, and which settings did it boot with? Answering those from log files and print statements gets old fast.

nexus-debug puts all of it in one place: a small web console served by your running app, and the JSON API behind it, which an agent may read just as well as you.

To add it, require the module in your app's `module.eco`. The two extras add the queues and the realtime sockets to the console, if your app uses those:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/debug" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/debug/work" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/debug/realtime" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list the extension early, so it times the whole request, and after nexus-auth when its gate reads the sign in. The extras go after the module they look at:

```echo title="src/Extensions.eco"
nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),
// ...
nexus::debug::Extension(),
nexus::debug::realtime::Extension(),
// ...
nexus::debug::work::Extension(),
```

## Turning it on

The console is off until you say otherwise:

```sh
NEXUS_DEBUG_ENABLED=true blog serve
```

Off, the extension binds nothing and costs nothing, so you may leave it in your extension list everywhere. On, the app logs where the console lives, `/__nexus/` by default, and which gate guards it. Open that address in a browser and you are in.

## What it shows

The console is made of panels, each with a few views:

- **Overview**: uptime, requests answered, the mode and build, at a glance.
- **Requests**: the recent requests as they come in, the slowest ones, and a timeline of each.
- **Logs**: what the app logs, live.
- **Routes**: every route, and any bound action that has none.
- **Environment**: every setting the app reads, whether it is set, and its value. Secrets show as `***`.

Extensions add panels of their own. nexus-debug-work adds **Queues**: the lanes, what is running now, schedules, failed tasks with a retry button, and stored tasks drawn as a graph. nexus-debug-realtime adds **Realtime**: the open sockets, the channels they follow, the broadcasts kept for catching up, and a button to close a socket.

### A request's timeline

The timeline is where the console earns its keep. Pick a request and you see where its time went, drawn as a waterfall: each middleware, the action, any spans your code opened, every database query, cache read and write, mail sent and file touched, with what it logged along the way.

You don't have to do anything for this. The database, [cache](./cache.md), [mail](./mail.md) and [files](./files.md) modules mark the request's timeline themselves whenever the console is watching. If you want a part of your own code on it, a span from [logging and tracing](./logging.md) shows up there too.

A request is found by its id. If a client sends `X-Request-Id`, that is the id, which makes it easy to look up one request you just made.

## Who gets in

A console that shows your routes, your log and your settings must not be open to the world. A gate decides who gets in, and nexus-debug picks one for you in this order:

1. The gate you pass to the extension.
2. Else, when `NEXUS_DEBUG_TOKEN` is set, a token gate.
3. Else, an open gate for localhost.

### A token from the environment

The simplest gate for a server: set `NEXUS_DEBUG_TOKEN` to a secret of at least 32 characters, and every call must carry it as `Authorization: Bearer <token>`. The console asks for it when you open it.

```sh
NEXUS_DEBUG_ENABLED=true NEXUS_DEBUG_TOKEN=a-debug-token-of-at-least-32-characters blog serve
```

### The app's own sign in

Often you would rather let in your admins, signed in the way they always sign in, than share one more secret. `nexus::debug::GuardGate` does that: it reads the caller with nexus-auth's guards, and lets in only whoever the middleware you name lets through. Here is the blog's gate:

```echo title="src/Extensions.eco"
nexus::debug::Extension(gate: nexus::debug::GuardGate(login: nexus::debug::Login(session: '/v1/auth/session', endpoint: '/v1/auth/signin'))
    ->through<Blog::Middleware::RequireUser>()
    ->through<Blog::Middleware::RequireAdmin>()),
```

`->through<M>()` names a middleware, resolved from the request's container just like an action's `#[nexus::through]`, so the very same `RequireAdmin` that guards the blog's admin endpoints guards its console too. [Middleware](./middleware.md) shows how those are written.

`login:` tells the console how to show your app's sign in form instead of asking for a token:

- `nexus::debug::Login('/v1/auth/token')` posts the email and password as JSON and takes the bearer token from the answer's `token` key.
- `nexus::debug::Login(session: '/v1/auth/session', endpoint: '/v1/auth/signin')` opens a signed session first, signs the sign in with it, and signs every console call with that session after. This is what the blog uses.

Without `login:`, the console asks for a bearer token of your app's own sign in. You may also pass `scope:` to let in only callers holding that scope. Either way, a token an OAuth client holds for another resource, like [MCP](./mcp.md), never opens the console.

### Localhost in development

With no gate and no token, the console opens to requests from this machine only: the developer at their desk, nothing to type. It refuses anything else, including a request through a proxy or for a host name that is not `localhost`, so a page on another site can't reach it either.

> [!WARNING]
> The open gate is for development. In `prod` mode the boot stops and asks for `NEXUS_DEBUG_TOKEN` or a gate.

## An API for agents

Everything the console shows comes from a JSON API, and that API describes itself. One call to `/__nexus/api` returns the panels, each view's URL, the live topics, and how every endpoint is called:

```sh
curl -H "Authorization: Bearer $NEXUS_DEBUG_TOKEN" http://127.0.0.1:3246/__nexus/api
```

That makes the console as useful to a coding agent as to you. Point an agent at that URL, and it finds its own way to the slowest requests, a failing request's timeline, or the last errors in the log:

| Endpoint | What it does |
|:--|:--|
| `GET /__nexus/api` | The description: panels, views, topics, endpoints. |
| `GET /__nexus/api/panels/{panel}/{view}` | One view's data, like `requests/timeline?id=...`. |
| `POST /__nexus/api/panels/{panel}/actions/{action}` | Runs a view's action, like retrying a failed task. |
| `GET /__nexus/api/topics/{topic}?after=<seq>&wait=<seconds>` | The events of a live topic (`logs`, `requests`, `jobs`) after a point, waiting for new ones. |
| `GET /__nexus/api/topics/{topic}/stream` | The same as server-sent events. |
| `GET /__nexus/api/sign-in` | How to sign in, readable without a credential. |

The blog's tests use the API the same way, to check that a request's timeline holds the queries it ran:

```echo title="tests/integration/DebugFlowTest.eco"
$world = World(['NEXUS_DEBUG_ENABLED' => 'true']);
$admin = $world->admin();
$admin->with('X-Request-Id', 'list-posts-1')->get('/v1/posts')->ok();
$admin->get('/__nexus/api/panels/requests/timeline?id=list-posts-1')->ok()
    ->json('$.request.target', '/v1/posts')
    ->has('"kind":"query"')
    ->has('"kind":"action"');
```

## A panel of your own

Sometimes your app knows something worth seeing at a glance: a feature switch, the size of a backlog. You may add a panel of your own, a class conforming to `nexus::debug::Panel`. It names its views and answers each one's data as JSON, and the console draws it by the view's kind, so a panel is Echo only:

```echo title="src/Debug/BlogPanel.eco"
namespace Blog::Debug;

#[atomic]
public class BlogPanel : nexus::debug::Panel
{
    private const string $title;

    public constructor(const string& $title)
    {
        $this->title = $title;
    }

    public function name() : string
    {
        return 'blog';
    }

    public function title() : string
    {
        return 'Blog';
    }

    public function views() : array<nexus::debug::View>
    {
        array<nexus::debug::View> $v = [nexus::debug::View('settings', 'Settings', .fields)];
        return $v;
    }

    public function read(nexus::Payload& $payload, const string& $view) : result<json::Value, nexus::Problem>
    {
        $title = json::object();
        $title['label'] = json::str('Title');
        $title['value'] = json::str($this->title);
        $fields = json::arr();
        $fields[] = mv $title;
        $o = json::object();
        $o['fields'] = mv $fields;
        return .ok($o);
    }
}
```

Pass it with `nexus::debug::Extension(panels: [...])`, or add it from an extension's `services()` with `$s->find<nexus::debug::Debug>()`, which is null while the console is off. A panel is shared by every request, so it is `#[atomic]` and keeps no per-request state. Besides `.fields`, a view may be `.stats`, `.table`, `.log`, `.json`, `.graph` or `.timeline`, and a table may offer actions, which your panel's `act()` runs.

## Settings

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_DEBUG_ENABLED` | `false` | Whether the console is mounted at all. |
| `NEXUS_DEBUG_PATH` | `/__nexus` | Where the console lives. The API is under `<path>/api`. |
| `NEXUS_DEBUG_TOKEN` | | A token that opens it as a bearer token, at least 32 characters. Used when the app passes no gate. |
| `NEXUS_DEBUG_KEEP` | `1000` | How many events each live topic keeps for late readers. |

[Configuration](./configuration.md) covers how these are read.

## Where to next

- [Logging and tracing](./logging.md): what feeds the log and the timeline.
- [Middleware](./middleware.md): the guards a `GuardGate` reuses.
- [Tasks and queues](./tasks.md): what the Queues panel shows.
