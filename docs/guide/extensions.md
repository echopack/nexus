---
description: How an app is put together. The Extension hooks, binding services by lifetime, nexus::App and its helpers, and providers for each part of the app.
---

# Extensions and wiring

Every nexus app has to answer the same few questions somewhere. Which services exist, and how long does each one live? Where does each action answer? Which commands, tools, queues and channels does the app offer?

nexus answers all of them in **one place you can read**: code you write by hand, in your app's extension. There are no annotations to scan for routes and no config files that drift away from the code. If you want to know what `/v1/posts/{id}` runs, you search for it, and you find the line that builds it.

## The app is an extension

An extension is a class conforming to `nexus::Extension`. Modules like nexus-http and nexus-carbon are extensions, and so is your app. The kernel boots them in the order you list them, and the app comes last so its bindings may replace anything a module bound.

Every hook has a default, so an extension writes only the ones it needs. Here is the skeleton of the blog's:

```echo title="src/App.eco"
namespace Blog;

public class App : nexus::Extension
{
    public function name() : string
    {
        return 'blog';
    }

    public function services(nexus::Services& $s) : status<nexus::BootError>
    {
        $app = nexus::App($s);
        // bindings, actions, queues, ...
        return .ok;
    }
}
```

### The hooks

Here is every hook, in the order the kernel calls them. The [request lifecycle](./lifecycle.md) shows where each one sits in the bigger picture.

| Hook | When it runs | What it is for |
|:--|:--|:--|
| `name()` | anytime | a short name for logs and errors |
| `commands(Commands&)` | before the boot | recording the commands this extension adds |
| `services(Services&)` | at boot, in list order | bindings and routes; may fail, so opening a database goes here |
| `middleware(Pipeline&, Container)` | after the container is sealed | global middleware |
| `boot(Kernel)` | once the kernel is ready | last checks, loading catalogs |
| `transport()` | when serving | the transport, if the extension brings one |
| `start(Kernel, const Serve&)` | when `serve` or `work` starts | starting background work |
| `drain(Kernel)` | when serving stops, in reverse | stopping what `start` started |
| `shutdown(Kernel)` | when the process stops, in reverse | final cleanup |

A hook that returns `status<nexus::BootError>` may stop the boot. Return `.error(.extension('blog', "..."))` with a message that says what to fix, and the process exits with that line instead of starting half-configured.

## Binding services

Most of `services()` is telling the container how to build things. The core `nexus::Services` speaks the container's own words, but most apps wrap it in `nexus::App` from nexus-app, which gives every binding a lifetime you can read at a glance:

```echo
$app = nexus::App($s);

// once per request: a fresh PostService for every request, on that request's session
$app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>(), $c->get<UserRepository>(), $c->get<nexus::Logger>()));

// once for the whole app: the middleware that closes /v1 to requests without a session
$app->bind<nexus::auth::RequireSession>(shared: (Container $c) => nexus::auth::RequireSession(
    $c->get<nexus::auth::Guards>(), under: '/v1', except: [type_id<Blog::Actions::Auth::OpenSession>()]));

// something you already built
$app->instance(nexus::SignalDispatcher());
```

The loader is a short closure. When it needs something, it takes the `Container` and asks for it; when it needs nothing, it takes no argument at all. There is a third lifetime, `factory:`, for a fresh value on every `get`, though you will rarely need it.

So, which lifetime should you pick? A good default is `scoped:` for anything that touches the request or the database, and `shared:` for things that are safe to share across threads, such as a client or a clock. If you get it wrong in the dangerous direction (a `shared:` service that takes a `scoped:` one), the boot refuses to start and shows you the chain.

### Replacing a binding

Sometimes you may want to swap a service a module bound for one of your own. You may call `$app->replace<T>(...)` with the same three lifetimes as `bind`. Since the app is listed last, its replacement is the one every request sees.

### Reading what is already there

While wiring, `$app->get<T>()` returns a service that is already bound, and `$app->has<T>()` asks first. This is handy when one binding needs a value at wiring time:

```echo
$app->bindDistributedQueue<JobLane>(store: nexus::work::carbon::Store($app->get<carbon::DB>()))
    ->into<WorkerLane>();
```

Config structs are bound before any `services()` runs, so `$app->get<BlogConfig>()` always works here.

## Binding actions

An action is bound like a scoped service, then given its route:

```echo
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCRUD>()))
    ->route([.get], '/v1/posts/{id}');
```

The same chain may offer the action through other doors too, such as an MCP tool:

```echo
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCRUD>()))
    ->route([.get], '/v1/posts/{id}')
    ->tool('show_post', title: 'Read a post', readOnly: true, map: ['post' => 'id']);
```

[Actions](./actions.md) covers the class itself, [routing](./routing.md) the patterns, and [MCP tools](./mcp.md) the tool side.

## A helper for every door

`nexus::App` also has a helper for each thing the other modules bring, so all of an app's wiring reads the same way:

| Helper | Module | Page |
|:--|:--|:--|
| `bindAction<A>(...)->route(...)` | core | [Actions](./actions.md) |
| `middleware<M>()` | core | [Middleware](./middleware.md) |
| `bindTransformer<M, T>()` | nexus-rest | [Transformers](./transformers.md) |
| `bindRepository<R>()` | nexus-carbon | [Database](./database.md) |
| `bindTool<T>(...)->offer(...)` | nexus-mcp | [MCP tools](./mcp.md) |
| `bindAsyncQueue<L>()`, `bindDistributedQueue<L>(...)` | nexus-work | [Tasks and queues](./tasks.md) |
| `schedule(task)->cron(...)` | nexus-work | [Scheduling](./scheduling.md) |
| `bindChannel<C>(...)->on(...)` | nexus-realtime | [Realtime channels](./realtime.md) |
| `bindDisk<V>(name, url:)` | nexus-files | [Files](./files.md) |
| `router()` | core | [Routing and URLs](./routing.md) |

A helper for a module you didn't list in your extensions stops the boot with a line that says which extension to add. List nexus-mcp and nexus-work **before** your app when it offers tools or binds queues.

## Splitting the app into providers

One `services()` with every binding works for a small app, but it grows quickly. A **provider** wires one part of the app (posts, comments, auth) in a class of its own, conforming to `nexus::Provider`:

```echo title="src/Providers/PostsProvider.eco"
namespace Blog::Providers;

public class PostsProvider : nexus::Provider
{
    public function register(nexus::App $app) : void
    {
        $app->bindRepository<PostRepository>();
        $app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>(), $c->get<UserRepository>(), $c->get<nexus::Logger>()));

        $app->bindAction<CreatePost>((Container $c) => CreatePost($c->get<PostService>(), $c->get<PostTransformer>()))
            ->route([.post], '/v1/posts');
        // ...
    }

    public function commands(nexus::Commands& $cmds) : void
    {
        $cmds->bindCommand<ShowPostCommand>((Container $c) => ShowPostCommand($c->get<PostService>()))
            ->name('posts:show');
    }
}
```

The app lists its providers once and hands them to both hooks. The command line reads the commands before the boot, and everything else is wired at boot:

```echo title="src/App.eco"
public function providers() : array<nexus::Provider>
{
    array<nexus::Provider> $all = [AuthProvider(), PostsProvider(), CoversProvider(), CommentsProvider()];
    return $all;
}

public function services(nexus::Services& $s) : status<nexus::BootError>
{
    $app = nexus::App($s, $this->providers());
    return .ok;
}

public function commands(nexus::Commands& $cmds) : void
{
    nexus::App::commands($cmds, $this->providers());
}
```

You are free to register providers yourself instead, with `$app->register($p)`, when some app-wide binding has to come first. The blog does exactly that: it binds its queues and its signal dispatcher, then registers the providers that use them.

## Writing your own extension

You may want an extension of your own when a piece of wiring is reused across apps. It is the same interface the app uses. Here is nexus-cache's, slightly trimmed, as a model:

```echo
namespace nexus::cache;

public class Extension : nexus::Extension
{
    public function name() : string
    {
        return 'nexus-cache';
    }

    public function services(nexus::Services& $s) : status<nexus::BootError>
    {
        CacheConfig $config = $s->get<CacheConfig>();
        if ($config->ttl <= std::time::duration::zero()) {
            return .error(.extension('nexus-cache', "NEXUS_CACHE_TTL is {$config->ttl}; expected more than 0s"));
        }
        // ... bind the Cache on the store NEXUS_CACHE_URL names
        return .ok;
    }

    public function commands(nexus::Commands& $cmds) : void
    {
        $cmds->add(ClearCommand());
    }
}
```

Notice the pattern: read a typed config, refuse a bad one with a message naming the variable, bind the service. An extension in a library also gets its own `#[nexus::config]` structs and `nexus gen` run, exactly like an app.

## Where to next

- [Actions](./actions.md): the classes you have been binding.
- [Configuration](./configuration.md): the typed settings every `services()` may read.
- [Modules](./modules.md): every extension nexus ships, and what each one adds.
