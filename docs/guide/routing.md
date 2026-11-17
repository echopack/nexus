---
description: Where each action answers, the patterns and constraints a path may use, and how to build links back to an action.
---

# Routing and URLs

An action knows what it does, but not where it answers. That is said once, where the app is wired: a method, a path, and the action behind them. nexus keeps the two apart on purpose, so the same action can answer on two paths, be offered as an [MCP tool](./mcp.md), or move to a new URL without touching its code.

This page covers how routes are declared, what a path pattern may contain, how nexus picks the route for a request, and how to build a link back to an action without writing its path twice.

## Declaring a route

You route an action right after binding it. `bindAction` registers the action's factory, and `->route()` says which methods and which path it answers:

```echo title="src/Providers/PostsProvider.eco"
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCRUD>()))
    ->route([.get], '/v1/posts/{id}');
$app->bindAction<CreatePost>((Container $c) => CreatePost($c->get<PostService>(), $c->get<PostTransformer>()))
    ->route([.post], '/v1/posts');
```

The methods are the cases of `nexus::Method`: `.get`, `.head`, `.post`, `.put`, `.patch`, `.delete` and `.options`. A route needs at least one; an empty list stops the boot with a line naming the action.

### Several methods, several paths

You may answer more than one method on the same path by listing them:

```echo
$app->bindAction<UpdatePost>((Container $c) => UpdatePost($c->get<PostService>(), $c->get<PostTransformer>()))
    ->route([.put, .patch], '/v1/posts/{id}');
```

If you would like the same action to answer at a second path too, call `->route()` again. Links to the action go to the first one, so put the path you want people to see first.

### Every action states its full path

You may have noticed there are no route groups, no prefixes and no nesting. That is deliberate. Each action states its full path, so a search for `/v1/posts/{id}/cover` finds the one line that answers it, and nothing you add elsewhere can quietly move a route. When many routes share something, such as a guard on everything under `/v1`, that belongs in [middleware](./middleware.md), not in the route table.

### Routing from an extension

Extensions that do not use `nexus::App` wire their routes on `nexus::Services` directly. The method and path come first, then the factory:

```echo
$s->bindAction<Login>(method: .post, path: '/v1/auth/token', function(Container $c) : Login {
    return Login($c->get<SignIn>(), $c->get<nexus::auth::Tokens>());
});
```

[Extensions and wiring](./extensions.md) has the full story on both styles.

## Path patterns

A path is a list of segments separated by `/`. Each segment is either literal text, which must match exactly, or a parameter in braces, which captures one segment by name.

### Parameters

A parameter is read by the action's `handle()` under the same name. Here the route captures `{id}` and `{comment}`, and the action asks for both:

```echo title="src/Providers/CommentsProvider.eco"
$app->bindAction<DeleteComment>((Container $c) => DeleteComment($c->get<CommentService>()))
    ->route([.delete], '/v1/posts/{id}/comments/{comment}');
```

```echo title="src/Actions/Comments/DeleteComment.eco"
public function handle(nexus::Payload& $payload, int64 $id, int64 $comment) : status<nexus::Problem>
```

A path parameter in `handle()` may be a `string`, `int32`, `int64`, `uint16`, `uint32` or `uint64`; a number past what its type holds is a `404`. Captured values are percent-decoded before the action sees them, so `/files/a%20b` hands over `a b`.

The kernel checks every route against its action before the first request. If `handle()` asks for `$comment` but the path has no `{comment}`, the boot stops with a message saying so. It's fine the other way round: a path may capture a parameter the action does not read.

### Constraints

Often a parameter only makes sense in one shape: an id is a number, a slug is lowercase. You may say so in the pattern with a colon:

```echo
$app->bindAction<ShowTag>(() => ShowTag())
    ->route([.get], '/v1/tags/{name:slug}');
```

A segment that does not fit the constraint does not match the route at all, so the request falls through to another route or to a `404`. These are the constraints a pattern may name:

| Constraint | Admits |
|:--|:--|
| `any` | any non-empty segment (the default) |
| `number` | digits only, `42` |
| `integer` | digits with an optional leading `-`, `-3` |
| `alpha` | ASCII letters only |
| `alphanum` | ASCII letters and digits |
| `uuid` | a UUID in its 8-4-4-4-12 form, any case |
| `slug` | lowercase letters, digits and `-` |

Most of the time you don't need to write one. `nexus gen` derives it from the parameter's type: an `int32` or `int64` parameter makes `{id}` an `{id:integer}`, and an unsigned one makes it `{id:number}`. That is why `GET /v1/posts/abc` never reaches `ShowPost`. A number too large for its type still gets through the pattern, and the action answers `404` without running, since no such post can exist.

### Optional segments

Sometimes the last segment may be left out. Mark it with `?`, and take the parameter nullable or with a default:

```echo
// GET /archive/2026 and GET /archive/2026/10
$app->bindAction<Archive>(() => Archive())
    ->route([.get], '/archive/{year}/{month?}');
```

```echo
public function handle(int32 $year, int32? $month) : result<nexus::Response, nexus::Problem>
```

If the action takes `$month` as a plain `int32`, the boot stops: the path promises it may be missing, so `handle()` has to cope with that. A constraint goes before the `?`, as in `{month:number?}`.

### Catch-all segments

Occasionally you may want one parameter to take the rest of the path, slashes and all, as a file browser or a single page app does. End it with `*`:

```echo
$app->bindAction<ShowFile>((Container $c) => ShowFile($c->get<CoverService>()))
    ->route([.get], '/files/{path*}');
```

`/files/covers/a%20b.png` hands over `covers/a b.png`, and `/files` hands over an empty string. The debug console answers its own pages this way, under `/__nexus/{rest*}`. With a constraint, `{path:slug*}`, every piece between the slashes has to fit and the rest may not be empty.

An optional or catch-all segment must be the last one. A pattern that breaks a rule (no leading `/`, an unclosed brace, an unknown constraint, a name used twice) stops the boot with the pattern and what is wrong with it.

## How a request finds its route

You never have to think about the order you declare routes in. nexus compares patterns segment by segment and tries the more specific one first: literal text beats a constrained parameter, which beats an open one, which beats an optional segment, which beats a catch-all.

The blog relies on this. `POST /v1/posts/batch` and `PATCH /v1/posts/{id}` share a prefix, and the literal `batch` is tried before `{id}` wherever you declared them.

So, what happens when nothing matches? The answer depends on why:

- No route has the path at all: a `404`.
- The path exists, but not for this method: a `405` with an `Allow` header listing the methods that would have answered.
- `OPTIONS` on a known path: a `204` with that `Allow` header, no action involved.
- `HEAD` on a path that only answers `GET`: the `GET` route runs and the body is dropped.

The same method and path declared twice is a boot error, never a silent "last one wins". That includes two spellings of one path: `/posts/{id}` and `/posts/{slug}`, or `/posts` and `/posts/`, match the same requests, so the second is refused too.

Routing happens before any middleware runs, so even a global middleware can look at `$payload->route` to see which action a request is headed for. An unmatched request is still answered at the end of the chain, so your middleware runs for a `404` too. [Middleware](./middleware.md) shows what you can do with that.

### Listing the routes

When you would like to see the whole table, most specific first, ask the app:

```sh
echoc run -- routes
```

## Building links to an action

Writing `/v1/posts/5` into a response by hand means the path now lives in two places. Instead, ask `nexus::Router` where an action answers. Take the router in the constructor and build links when a request comes:

```echo title="src/Transformers/PostTransformer.eco"
#[atomic]
public class PostTransformer : nexus::rest::Transformer<Post>, PostMapping
{
    private nexus::Router $router;

    public constructor(nexus::Router $router)
    {
        $this->router = $router;
    }

    public function transform(const Post& $p, nexus::rest::Item& $item, const nexus::rest::TransformerContext& $ctx) : void
    {
        $item->text('url', $this->router->url<ShowPost>(['id' => "{$p->id}"])->text());
    }
}
```

`url<A>()` fills the parameters of the action's first route into its pattern and escapes them. A name the pattern does not have becomes a query pair, in name order:

```echo
echo $router->url<ShowPost>(['id' => '5'])->text();     // /v1/posts/5
echo $router->url<ListPosts>(['page' => '2'])->text();  // /v1/posts?page=2
```

The router is empty while the app is wired and filled at boot, which is why you take it now and ask for links later. In a provider, `$app->router()` hands it over; in a factory, `$c->get<nexus::Router>()` does.

::: warning A broken link is a bug
A missing required parameter, a value its constraint refuses, or an action no route reaches stops the program rather than producing a link that leads nowhere. If a link is only there when its action is routed, check with `$router->routed<A>()` first.
:::

### Absolute links

A link inside a JSON answer is usually fine as a path, since the client knows where it asked. For a link that leaves the app, in a mail or a webhook, you need the full origin. Set `NEXUS_APP_URL` to the app's public origin:

```sh
NEXUS_APP_URL=https://blog.example.com
```

Then `absoluteUrl<A>()` builds the link on it:

```echo
echo $router->absoluteUrl<ShowPost>(['id' => '5'])->text();  // https://blog.example.com/v1/posts/5
```

The origin may carry a path the app is mounted under, `https://example.com/blog`, and links land beneath it. A value that is not an absolute URL stops the boot, and asking for an absolute link without one set stops the program. For an answer to the client who is asking right now, you may skip the configuration and put the link on the request's own origin instead:

```echo
$link = $router->url<ShowPost>(['id' => '5'])->on($payload->request->url());
```

Be careful with that for links other people will follow: the request's origin comes from the `Host` header a client sends. In `prod`, extensions whose links leave the app (an OAuth issuer, a sign in callback) refuse to boot without `NEXUS_APP_URL`, and outside `dev` the `serve` and `doctor` commands warn when it is missing. [Configuration](./configuration.md) covers where the variable may come from.

## Working with URLs

`nexus::Url` is what the router hands back. It keeps the path escaped and the query decoded, and `text()` writes it out again. You may adjust a copy without touching the original:

```echo
nexus::Url $next = $router->url<ListPosts>(['page' => '2'])->with('tag', 'echo');
echo $next->text();               // /v1/posts?page=2&tag=echo
echo $next->without('tag')->text();  // /v1/posts?page=2
```

`at()` sets the fragment, and `Url::parse()` reads a URL from text, refusing anything that is neither an absolute URL nor a path starting with `/`.

### Reading the query string

The query string of a request is a `nexus::Query`: decoded pairs, in order, where a name may repeat. For one or two optional filters, you may read it straight from the request, as the blog's post listing does for `?tag=`:

```echo title="src/Actions/Posts/ListPosts.eco"
$o->filter = function(PostQuery $q, const nexus::Request& $req) : result<PostQuery, nexus::Problem> {
    $tag = guard $req->query->get('tag') else {
        return .ok($q);
    };
    return .ok($q->tagged($tag));
};
```

`get()` gives the first value, `all()` every value of a repeated name, and `has()` says whether it is there. When the query carries real input with rules, describe it as an input struct and take it as `nexus::QueryOf<T>` instead; [input and validation](./input.md) shows how.

## Where to next

- [Middleware](./middleware.md): wrapping one route, or every request, in code of your own.
- [Input and validation](./input.md): typed bodies and query strings, checked before `handle()` runs.
- [Responses](./responses.md): redirects to a link the router built, and everything else an action may answer.
