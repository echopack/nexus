---
description: Turning models into API answers. What a model exposes, the transform() hook, includes, sensitive fields, and JSON or XML by Accept.
---

# Transformers

A model is how your app stores something; an answer is how a client sees it. The two are rarely the same. A user row carries a password hash that must never leave the server, a post wants a link to itself that the table does not have, and a client may want a post's author in the same answer or may not. Writing that by hand in every action is tedious, and one forgotten field is a leak.

nexus-rest gives each model a **transformer**: one shared class that knows how that model looks on the wire. The model marks what it exposes, `nexus gen` writes the code that copies those fields, and the transformer adds whatever the fields alone cannot say. Every action that answers with a post then goes through the same `PostTransformer`, and gets JSON or XML, includes, and envelope for free.

## Adding nexus-rest

nexus-rest is a module. Require it in your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/rest" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

There is no extension to add to your extensions list: transformers are registered by the provider that owns the model, with `$app->bindTransformer<M, T>()`, as you will see below. [Modules](./modules.md) lists the others.

## Your first transformer

Let's start with the blog's comments. First, the model says which of its fields a client may see, with `#[nexus::expose]`:

```echo title="src/DB/Model/Comment.eco"
#[carbon::model: 'comments']
public class Comment : carbon::Model<Comment, CommentRepository>
{
    public carbon::Link $link = .detached();

    #[carbon::key]
    #[nexus::expose: { attribute: true }]
    public int64 $id = 0;

    #[nexus::expose]
    public int64 $postId;

    public int64 $authorId;

    #[nexus::expose]
    public string $body;

    #[carbon::created]
    #[nexus::expose]
    public time::timestamp? $createdAt = null;

    // ...
}
```

`authorId` and `updatedAt` carry no `#[nexus::expose]`, so they stay on the server. From the marked fields, `nexus gen` writes a mapping interface named after the model, `CommentMapping`, into `.nexus/`. A transformer conforms to `nexus::rest::Transformer` for the model and to that mapping, and often that is all it needs:

```echo title="src/Transformers/CommentTransformer.eco"
namespace Blog::Transformers;

use Blog::DB::Model::{Comment, CommentMapping};

#[atomic]
public class CommentTransformer : nexus::rest::Transformer<Comment>, CommentMapping
{
}
```

The mapping brings `name()`, `map()` and the list of includes; `nexus::rest::Transformer` brings everything that answers a request. The class is `#[atomic]` because one instance is shared by every request. Head over to [nexus gen](./generator.md) for when the generated code is written.

Finally, the provider that owns comments registers it:

```echo title="src/Providers/CommentsProvider.eco"
$app->bindTransformer<Comment, CommentTransformer>();
```

That binds the transformer shared, so actions may ask the container for a `CommentTransformer`, and puts it in the app's transformer network under `Comment`, so another transformer can nest comments without holding a reference to this one. When your transformer takes constructor arguments, hand over the instance yourself:

```echo title="src/Providers/PostsProvider.eco"
// a post links to ShowPost through the router, which boot fills
$app->bindTransformer<Post, PostTransformer>(PostTransformer($app->router()));
```

A model gets one transformer in the network. Registering a second for the same model stops the boot with a message saying so.

## Answering with a transformer

An action answers with one model through `createResponse()`, and with a list through `createCollectionResponse()`:

```echo title="src/Actions/Comments/ListComments.eco"
public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
{
    $all = try $this->comments->on($id);
    return $this->transformer->createCollectionResponse($payload, $all);
}
```

The model goes under `data`. A comment just posted (`CreateComment` answers with `createResponse($payload, $made, status: 201)`) looks like this:

```json
{"data":{"id":3,"post_id":1,"body":"Nice write-up!","created_at":"2026-10-13T14:06:00Z","author":{"id":7,"name":"Ada","welcomed_at":null}}}
```

Field names are written in snake case, `postId` as `post_id`, and instants in UTC. Don't worry about the `author` key for now; we'll get to includes soon.

You may pass a status for an answer that is not a plain `200`, such as a post just made:

```echo
return .ok($this->transformer->createResponse($payload, $made, mv $inc, status: 201));
```

### Keys next to `data`

Sometimes an answer needs to say something about the data rather than in it: the page a list is on, or the session a user just signed into. Put those keys in a `nexus::rest::Meta` and they are written before `data`:

```echo
$meta = nexus::rest::Meta();
$meta->with('total', json::int(41));
return $this->transformer->createCollectionResponse($payload, $all, $meta);
```

```json
{"total":41,"data":[{"id":1,"post_id":1,"body":"First!", ...}]}
```

[CRUD endpoints](./crud.md) fill `page`, `size` and the counts for you this way.

### JSON or XML

The format follows the request's `Accept` header: JSON unless the client prefers XML. You write nothing for it. Fields marked `attribute: true` go into the start tag, and in a list each element is named by the transformer's `name()`, the model's name in snake case:

```txt
GET /v1/posts
Accept: application/xml

<?xml version="1.0" encoding="UTF-8"?><response><page>1</page><size>20</size><data><post id="1"><title>Hello</title><body>...</body><tags><tag>echo</tag></tags>...</post></data></response>
```

In JSON, an attribute is a plain key like any other.

## Choosing what a model exposes

A bare `#[nexus::expose]` writes the field under its snake case name. When the wire should look different, `#[nexus::expose]` takes a record of options:

```echo title="src/DB/Model/Post.eco"
#[carbon::key]
#[nexus::expose: { attribute: true }]
public int64 $id = 0;

#[carbon::codec: 'csv']
#[nexus::expose: { item: 'tag' }]
public array<string> $tags = [];
```

| Option | What it does |
|:--|:--|
| `key: 'created'` | The wire name, instead of the field name in snake case |
| `attribute: true` | Written into the XML start tag, `<post id="1">`; a non-null integer, string or backed enum only |
| `item: 'tag'` | Names each element of a list in XML; for `array<string>` and integer arrays |
| `stamp: 'date'` | How a `time::timestamp` is written: `zulu` (the default, `2026-10-13T14:06:00Z`), `atom` (`2026-10-13T14:06:00+00:00`) or `date` (`2026-10-13`) |
| `shapes: ['admin']` | Only in the named shapes; see [sensitive fields and shapes](#sensitive-fields-and-shapes) |
| `include: 'default'` | A relation written without being asked; see [includes](#includes) |

A mapping writes strings, booleans, integers and floats, lists of strings or integers, `time::timestamp`, a free-form `json::Value`, backed enums (as their value), and `carbon::One` and `carbon::Many` relations as includes. A field of any other type is refused by `nexus gen` at its line, with a hint: leave it unexposed and write it in the `transform()` hook instead. The field must also be `public`, so the mapping can read it.

## Adding to what the mapping wrote

The fields of a model rarely tell the whole story. A post should carry a link to itself and to its cover image, neither of which is a column. That is what the `transform()` hook is for: it runs on every item after the mapping wrote the fields, and may add, replace or remove keys:

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
        if ($p->cover != null) {
            $item->text('cover_url', $this->router->url<ShowCover>(['id' => "{$p->id}"])->text());
        }
    }
}
```

`nexus::rest::Item` has a writer per kind of value: `text`, `int`, `float`, `bool`, `nil`, `time`, `texts`, `ints`, `value` for a `json::Value`, and `attribute`. Setting a key that is already there replaces it in place; a new key goes last; `$item->remove('body')` takes one out. Attributes are always written first and includes last, whatever order you set them in.

Notice the post's cover is stored as a key on a disk, which the model leaves unexposed: the client gets `cover_url`, never the storage key.

::: tip Without a mapping
A transformer does not need a generated mapping. You are free to write `name()`, `map()`, `availableIncludes()` and `defaultIncludes()` yourself, which is handy for a type that is not a carbon model.
:::

## Includes

A client reading a post may or may not want its author. Rather than two endpoints, or always paying for the join, nexus lets the client ask: `GET /v1/posts/1?include=author`.

Every exposed relation becomes an include. The blog's post exposes its author:

```echo title="src/DB/Model/Post.eco"
#[carbon::belongsTo: 'authorId']
#[nexus::expose]
public carbon::One<User> $author = .unloaded();
```

When the request names `author`, the author is written under its key by the transformer of `User` in the network, so it looks exactly as a user does anywhere else.

So, what loads the author? Not the transformer. The mapping writes an include only when the relation is **loaded**, so the code that reads the post loads what the request asked for. With [CRUD endpoints](./crud.md) that is the crud's `load` hook; in your own action, check what was asked and load it in the query, the way the blog's `CommentService` reads comments with `->withAuthor()`. An include the request asked for but nobody loaded is simply left out.

### Checking what a client asks for

`?include=` is checked against the transformer's `availableIncludes()`. A name it does not list answers a `400` that says which one. When an action writes before it answers, check the includes first with `requestedIncludes()`, so a typo in `?include=` stops the request before anything changed:

```echo title="src/Actions/Posts/UpdatePost.eco"
public function handle(nexus::Payload& $payload, int64 $id, nexus::Body<PostChanges> $in) : result<nexus::Response, nexus::Problem>
{
    $me = try $payload->state<Caller>();
    // checked before the write: a bad ?include= changes nothing
    $inc = try $this->transformer->requestedIncludes($payload);
    $changed = try $this->posts->update($me->user, $id, $in->value);
    return .ok($this->transformer->createResponse($payload, $changed, mv $inc));
}
```

The `createResponse()` overloads that take the includes return a `nexus::Response` directly, since nothing is left to fail.

### Includes by default

Some relations belong in every answer. A list of comments without their authors is not much use, so the blog's comment includes its author whether asked or not:

```echo title="src/DB/Model/Comment.eco"
#[carbon::belongsTo: 'authorId']
#[nexus::expose: { include: 'default' }]
public carbon::One<User> $author = .unloaded();
```

### Nested includes

The mapping lists a model's own relations. When you would like a client to reach further, say `?include=author.posts`, spell the path out in `extraIncludes()`; the generated `availableIncludes()` adds them after its own:

```echo
public function extraIncludes() : array<string>
{
    return ['author.posts'];
}
```

Loaded data can form a cycle (a user whose posts carry the user again). That is fine: past eight levels of nesting, a nested model is left out instead of recursing forever.

## Sensitive fields and shapes

Some fields must never reach the wrong client, whatever a hook does by mistake. Mark them `#[nexus::sensitive]`. A sensitive field without `#[nexus::expose]` is never written by any mapping, and writing its key in a `transform()` hook stops the program with a message naming the key:

```echo title="src/DB/Model/User.eco"
/**
 * Argon2id, empty until `user:password` sets one.
 */
#[nexus::sensitive]
public string $passwordHash = '';
```

What about a field some clients may see? An admin should see a user's email and role; everyone else should not. You may declare a named **shape** on the model, and expose a field only in it:

```echo title="src/DB/Model/User.eco"
#[carbon::model: 'users']
#[nexus::shapes: [{ name: 'admin', sensitive: true }]]
public class User : carbon::Model<User, UserRepository>
{
    #[carbon::key]
    #[nexus::expose: { attribute: true }]
    public int64 $id = 0;

    #[nexus::sensitive]
    #[nexus::expose: { shapes: ['admin'] }]
    public string $email;

    #[nexus::expose]
    public string $name;

    #[nexus::expose: { shapes: ['admin'] }]
    public Role $role = .author;

    // ...
}
```

A bare `#[nexus::expose]` puts a field in every shape. A sensitive field must name its shapes, and each must be declared `sensitive: true`; `nexus gen` refuses anything else at the field's line. The default shape is never sensitive, since nested includes always use it.

Each shape gets a mapping of its own: `UserMapping` for the default shape, `UserAdminMapping` for `admin`. The blog writes a transformer for each:

```echo title="src/Transformers/UserAdminTransformer.eco"
#[atomic]
public class UserAdminTransformer : nexus::rest::Transformer<User>, UserAdminMapping
{
}
```

Here is the catch: the network holds one transformer per model, and `UserTransformer` already is the one for `User`. So the admin one is bound as a plain shared service, outside the network. That is a feature, not a workaround: a post's nested author can never come out in the admin shape.

```echo title="src/Providers/AuthProvider.eco"
$app->bindTransformer<User, UserTransformer>();
$app->bind<UserAdminTransformer>(shared: () => UserAdminTransformer());
```

The admin-only `ListUsers` action then takes a `UserAdminTransformer` in its constructor.

### Revealing a sensitive key for one item

Occasionally a sensitive field may be shown to one particular viewer: users may see their own email. The `transform()` hook may allow that for one item with `$item->reveal()` before writing the key:

```echo title="src/Transformers/UserTransformer.eco"
public function transform(const User& $u, nexus::rest::Item& $item, const nexus::rest::TransformerContext& $ctx) : void
{
    UserContext $viewer = guard $ctx->find<UserContext>() else {
        return;
    };
    if ($viewer->user->id == $u->id) {
        $item->reveal('email');
        $item->text('email', $u->email);
    }
}
```

Which brings us to the question of where that viewer comes from.

## Handing the transformer what the action knows

A transformer only sees the model. Who is viewing, which locale they read, whether they are an admin: that is something the action knows. A `nexus::rest::TransformerContext` carries it, one value per type, to every `transform()` in the tree, nested ones included:

```echo title="src/Transformers/UserTransformer.eco"
/**
 * `$u` as the answer to themselves, their email shown, `$meta`'s keys before `data`.
 */
public function own(nexus::Payload& $payload, const User& $u, const nexus::rest::Meta& $meta) : result<nexus::Response, nexus::Problem>
{
    $ctx = nexus::rest::TransformerContext();
    $ctx->set<UserContext>($user: $u);
    return $this->createResponse($payload, $u, $meta, $ctx);
}
```

`set<T>()` gathers the constructor arguments of `T` at the call. Read a value back with `find<T>()`, which gives you `null` when nothing was set; `get<T>()` stops the program instead, so keep it for values that are always there. `/v1/me` and every sign in answer through `own()`, which is how users see their own email and nobody else's.

The blog keeps that helper on the transformer, which is a habit worth copying: every action that answers a user to themselves calls the same method.

## Nesting by hand

The generated mapping nests relations for you. When you would like to nest something the model does not expose as a relation, the `nexus::rest::Item` writes it through the network as well:

```echo
public function transform(const Post& $p, nexus::rest::Item& $item, const nexus::rest::TransformerContext& $ctx) : void
{
    $item->include<User>('editor', $this->editorOf($p));
}
```

`include<M>()` writes one model or `null`, `includeCollection<M>()` a list, and `includeReference<M>()` wraps the model with meta keys next to its `data`, `"editor": {"is_cached": true, "data": {...}}`. Each is left out unless the request wants that key, so list the key in `extraIncludes()`; `$item->wants('editor')` tells you whether it was asked for, so you may skip an expensive lookup.

Underneath, these call the `nexus::rest::TransformerContext`'s `transformInto()`, `transformCollectionInto()` and `transformReferenceInto()`, which find the transformer of the nested model in the `nexus::rest::TransformerNetwork`. Since nothing holds another transformer directly, the order in which providers register them does not matter.

## Outside a request

Sometimes a model has to travel somewhere other than an HTTP answer: a realtime broadcast, a log line. `json()` writes it as a `json::Value`, with the includes you name, using the app's network for nested models:

```echo title="src/Signals/BroadcastComment.eco"
json::Value $comment = $this->transformer->json($signal->comment, $this->network, EchoPack::Rest::Includes::of(['author']));
$this->send("posts.{$signal->comment->postId}", 'comment.posted', $comment, $signal->except);
```

The page following a post gets a comment in exactly the shape the API would have answered with. Ask the container for `nexus::rest::TransformerNetwork` to get the network.

## Where to next

- [CRUD endpoints](./crud.md): list, show, create, update and delete answered through a transformer.
- [Database](./database.md): the models and relations transformers read.
- [nexus gen](./generator.md): when the mappings are written, and what it refuses.
- [Realtime channels](./realtime.md): broadcasting models to the pages that follow them.
