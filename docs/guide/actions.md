---
description: One class per endpoint. What handle() may ask for, what it may return, and how it reads what middleware learned.
---

# Actions

An action is the code that answers one endpoint. In nexus every endpoint gets a class of its own, conforming to `nexus::Action`, with a single `handle()` method. There are no controllers holding a dozen methods, and no closures nested inside a route table.

That might feel like a lot of classes at first. In practice it means each endpoint states, in one place, exactly what it needs: its dependencies in the constructor, its request data in the `handle()` signature, and what it answers with in the return type. `nexus gen` reads that signature and writes the code that feeds it, so there is nothing to keep in sync by hand.

## Your first action

Let's start with the smallest action the blog has, a health check:

```echo title="src/Actions/Health.eco"
namespace Blog::Actions;

use Blog::Config::BlogConfig;

/**
 * Whether the blog is up, and what it is called.
 */
public class Health : nexus::Action
{
    private BlogConfig $config;

    public constructor(BlogConfig $config)
    {
        $this->config = $config;
    }

    public function handle() : json::Value
    {
        $o = json::object();
        $o['ok'] = true;
        $o['title'] = json::str($this->config->title);
        return $o;
    }
}
```

An action does not say where it answers. You say that where the app is wired, next to the code that builds it:

```echo title="src/App.eco"
$app->bindAction<Health>((Container $c) => Health($c->get<BlogConfig>()))
    ->route([.get], '/health');
```

The closure is the action's factory. nexus calls it once per request, on that request's own container, so an action may hold per-request things such as a database session without any locking. Head over to [extensions and wiring](./extensions.md) for the full story on bindings.

Before the first request, the kernel checks every route: is its action bound, did `nexus gen` write a dispatcher for it, and do the path parameters fit `handle()`? A mistake there stops the boot with a message naming the action, not a 500 some days later.

## Asking for request data

The parameters of `handle()` say what the request must provide. You never parse a path or a body yourself; you declare what you want and nexus hands it over, already typed.

### Path parameters

Any loose `string` or integer parameter (`int32`, `int64`, `uint16`, `uint32`, `uint64`) comes from the path, bound by name:

```echo
// GET /v1/posts/{id}
public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
{
    return $this->crud->show($payload, $id);
}
```

If `{id}` in the request is not a number, the action never runs and the client gets a `404`. You may give a path parameter a default or make it optional (`int64? $page`) when the segment itself is optional. [Routing](./routing.md) covers patterns and constraints.

### A JSON or form body

When an endpoint takes a body, describe it as an `#[nexus::input]` struct and ask for it as `nexus::Body<T>`:

```echo
public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
{
    $made = try $this->posts->create($me->user, $in->value);
    // ...
}
```

The body is decoded from JSON, a form, or a multipart upload, and every rule on the struct is checked before `handle()` runs. If anything is refused, the client gets one `422` listing every field that failed, and your action never sees bad data. [Input and validation](./input.md) has every rule.

### Query strings

Query parameters come the same way, as an input struct in `nexus::QueryOf<T>`:

```echo
public function handle(nexus::QueryOf<PostSearch> $q) : result<nexus::Response, nexus::Problem>
```

Why not loose parameters for queries too? Because loose parameters are always the path. Keeping the two apart means a reader can tell from the signature alone which part of the URL each value lives in.

### The payload and the request

`nexus::Payload&` is everything the request carries through middleware into the action: the request, the request's own container, its log, and the state middleware learned on the way. Most actions take it. If you only need the raw request, you may ask for `nexus::Request&` instead.

```echo
public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
{
    $payload->log->info('listing posts');
    $posts = $payload->get<PostRepository>();
    // ...
}
```

`$payload->get<T>()` resolves a service for this request, and `$payload->find<T>()` gives you `null` instead when nothing provides one.

### Anything else

So, what about the signed in user? That is not something the request "has"; it is something a middleware works out. nexus refuses any other parameter type with a message that says so, and points you at the next section.

## Reading what middleware learned

Middleware resolves what a request *is* (who signed it, which user that is) and puts it in the payload. The action names its middleware on the class and reads the result with `$payload->state<T>()`:

```echo title="src/Actions/Posts/CreatePost.eco"
#[nexus::through: ["Blog::Middleware::RequireUser"]]
public class CreatePost : nexus::Action
{
    // ...

    public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
    {
        $me = try $payload->state<Caller>();
        $inc = try $this->transformer->requestedIncludes($payload);
        $made = try $this->posts->create($me->user, $in->value);
        return .ok($this->transformer->createResponse($payload, $made, mv $inc, status: 201));
    }
}
```

`#[nexus::through]` runs on every route the action is bound to, and around it when it is offered as an [MCP tool](./mcp.md), so the guard can never be forgotten on one door.

If `state<Caller>()` finds nothing, that is a wiring mistake, not a bad request: the client gets a `500`, and the log names the action and the type it asked for. [Middleware](./middleware.md) shows how to write one that puts state.

## What an action may return

The return type says what goes back, and the generated dispatcher picks the right way to answer from it.

| Return type | What the client gets |
|:--|:--|
| `result<nexus::Response, nexus::Problem>` | the response, or the problem as RFC 9457 JSON |
| `nexus::Response` | the response as it is |
| `result<json::Value, nexus::Problem>` / `json::Value` | `200` with the JSON document |
| `result<string, nexus::Problem>` | `200` with the text |
| `status<nexus::Problem>` | `204 No Content`, or the problem |
| `result<T, nexus::Problem>` where `T : nexus::Resource` | the resource's JSON document |

Most actions in a real app return `result<nexus::Response, nexus::Problem>`, built by a [transformer](./transformers.md). A delete that has nothing to say returns `status<nexus::Problem>`:

```echo title="src/Actions/Posts/DeletePost.eco"
public function handle(nexus::Payload& $payload, int64 $id) : status<nexus::Problem>
{
    $me = try $payload->state<Caller>();
    $this->crud->authorize = Post::authorizeFor($me->user);
    return $this->crud->delete($payload, $id);
}
```

### Failing with a problem

When something goes wrong that the client should hear about, return a `nexus::Problem`. Each case maps to its HTTP status:

```echo
$post = guard $posts->find($id) else {
    return .error(.notFound('post'));
};
if ($post->authorId != $me->user->id) {
    return .error(.forbidden('only the author may edit a post'));
}
```

Because problems travel through `result`, `try` passes one up from a service without ceremony. [Problems and errors](./problems.md) lists every case and how the client sees it.

## Keeping actions thin

You may put any code you like in `handle()`, but the blog follows one habit worth copying: **services return models, actions answer**. `PostService` knows how to create a post; `CreatePost` only decodes, delegates, and answers through a transformer. That keeps the same logic reachable from the other doors without an HTTP request in sight: the blog's `posts:create` [command](./commands.md) and its `create_post` [MCP tool](./mcp.md) call the very same `PostService`.

## Where to next

- [Routing and URLs](./routing.md): patterns, constraints, and building links to an action.
- [Input and validation](./input.md): every rule an input field may carry.
- [Responses](./responses.md): headers, downloads, redirects and streams.
