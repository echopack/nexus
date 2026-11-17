---
description: List, show, create, update and delete over a carbon repository, answered through a transformer, with one crud per model and one action per endpoint.
---

# CRUD endpoints

Most models end up with the same five endpoints: a list, one by id, create, update and delete. Written by hand, each repeats the same work: read `page` and `size`, check `order` against the columns that may be sorted, load what `?include=` asks for, answer a `404` when the id is unknown, check who may touch the record, answer through the transformer. Five times per model, slightly differently each time.

nexus-crud holds what the five share in one `nexus::crud::Crud` per model. Each endpoint is still an [action](./actions.md) of its own, with its own route and its own middleware; it just calls the verb it is. Listing follows one set of query conventions, so every list in your API pages, sorts and counts the same way.

## Adding nexus-crud

nexus-crud is a module, built on [the database](./database.md) and [transformers](./transformers.md). Require it in your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/crud" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

There is no extension to add: a crud is a plain class you bind in the provider that owns the model.

## One crud per model

A `nexus::crud::Crud` takes five type arguments: the model, its query, its key, its repository, and its transformer. That is a mouthful, so give it a name with a type alias:

```echo title="src/Actions/Posts/PostCRUD.eco"
namespace Blog::Actions::Posts;

use Blog::DB::Model::Post;
use Blog::DB::Query::PostQuery;
use Blog::DB::Repository::PostRepository;
use Blog::Transformers::PostTransformer;

/**
 * List, show, create, update and delete of posts, answered through the `PostTransformer`.
 */
public type PostCRUD = nexus::crud::Crud<Post, PostQuery, int64, PostRepository, PostTransformer>;
```

Then bind it per request, built from the request's repository and the shared transformer:

```echo title="src/Providers/PostsProvider.eco"
$app->bindRepository<PostRepository>();
$app->bindTransformer<Post, PostTransformer>(PostTransformer($app->router()));

$app->bind<PostCRUD>(scoped: function(Container $c) : PostCRUD {
    $crud = PostCRUD($c->get<PostRepository>(), $c->get<PostTransformer>());
    $crud->name = 'post';
    return $crud;
});
```

Why `scoped`? A repository belongs to one request's database session, and, as you will see shortly, an action may set hooks on its crud that only hold for the user making the request. A crud built per request may carry both without any locking.

`name` is what a missing record is called: `GET /v1/posts/99` answers a `404` saying "the post" was not found, instead of "the record".

## Actions that call their verb

With the crud bound, an endpoint is a few lines. Here is the blog's `ShowPost`:

```echo title="src/Actions/Posts/ShowPost.eco"
namespace Blog::Actions::Posts;

/**
 * One post; `?include=author` adds its author.
 */
public class ShowPost : nexus::Action
{
    private PostCRUD $crud;

    public constructor(PostCRUD $crud)
    {
        $this->crud = $crud;
    }

    public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
    {
        return $this->crud->show($payload, $id);
    }
}
```

```echo title="src/Providers/PostsProvider.eco"
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCRUD>()))
    ->route([.get], '/v1/posts/{id}');
```

Why not one generic controller for all five? Because then the route, the middleware and the input of each endpoint would hide inside the crud. Keeping each action a class means `DeletePost` can require a signed in user while `ShowPost` does not, a `routes` listing shows five real actions, and `nexus gen` checks each signature like any other.

Each verb answers as you would expect:

| Call | What the client gets |
|:--|:--|
| `$crud->list($payload)` | `200`, a page of records under `data`, with `page` and `size` |
| `$crud->show($payload, $id)` | `200` with the record, or `404` |
| `$crud->create($payload, $model)` | `201` with the record as saved |
| `$crud->update($payload, $id, $fill)` | `200` with the record as saved, or `404` |
| `$crud->delete($payload, $id)` | `204 No Content`, or `404` |

`delete` returns a `status<nexus::Problem>`, so the action's return type is that too. The others return `result<nexus::Response, nexus::Problem>`.

## Listing

A list takes its options from a `nexus::crud::Listing`, built in the action. Let's look at the blog's list of posts, newest first:

```echo title="src/Actions/Posts/ListPosts.eco"
public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
{
    $o = nexus::crud::Listing<PostQuery>();
    $o->orderable('created_at', PostTable::$createdAt);
    $o->orderable('title', PostTable::$title);
    $o->order = '-created_at';
    $o->size = $this->config->pageSize as uint64;
    $o->ids = function(array<int64> $ids) : hydrahon::Term<bool> {
        return PostTable::$id in $ids;
    };
    $o->filter = function(PostQuery $q, const nexus::Request& $req) : result<PostQuery, nexus::Problem> {
        $tag = guard $req->query->get('tag') else {
            return .ok($q);
        };
        return .ok($q->tagged($tag));
    };
    return $this->crud->list($payload, $o);
}
```

If you are happy with the defaults (paged, 20 per page, counting allowed, no ordering), `$this->crud->list($payload)` is all you need.

Every list reads the same query parameters:

| Parameter | Meaning |
|:--|:--|
| `page` | The page, from `1`; `1` when left out |
| `size` | Rows per page, from `1` up to the listing's `maxSize` (`100`); the listing's `size` (`20`) when left out |
| `order` | A key made `orderable`, `-` in front for descending: `order=title`, `order=-created_at` |
| `ids` | Only these records, comma separated: `ids=4,8,15` |
| `count` | `count=1` adds `total_count` and `filter_count` to the answer |
| `include` | Relations to include, checked against the transformer |

A value that does not fit answers a `422` naming the field and what it accepts: `order by one of: created_at, title` for an unknown order, `size must be a whole number from 1 to 100` for a size too large. Your action never sees it.

The answer carries the page next to the data:

```json
{"page":1,"size":20,"total_count":42,"filter_count":3,"data":[{"id":12,"title":"Echo in production", ...}]}
```

### Ordering

Ordering by any column a client names would let them sort by a column without an index, or one they should not know exists. So a list sorts only by what you make `orderable`, under a public name of your choosing mapped to a column. `order` sets the default for a request that names none; leave it empty to keep whatever order the query has.

### Filtering

Most lists need a filter or two of their own, like the blog's `?tag=echo`. `filter` receives the query and the request, and returns the narrowed query, or a problem to refuse the request. Since it reads the request directly, you may name the parameter anything that does not clash with the conventions above.

### Fetching by ids

A client that holds a handful of ids often wants exactly those records in one request. `ids` says how to match them, here `PostTable::$id in $ids`. Leave it `null` and a request with `ids=` answers a `422` saying this list cannot be filtered by ids. At most `maxSize` ids are accepted.

### Counting

`count=1` adds two numbers: `total_count`, every record the request may see, and `filter_count`, the records left after its filters and `ids`. Counting costs two extra queries, so it only runs when asked. Set `counting` to `false` on the listing to ignore `count` entirely, or `paging` to `false` for a list that is always short enough to answer whole.

## Loading includes

A transformer writes a relation only when it is loaded (see [includes](./transformers.md#includes)). The crud loads it through its `load` hook, which gets the query and the includes the request asked for:

```echo title="src/Providers/PostsProvider.eco"
$crud->load = function(PostQuery $q, const EchoPack::Rest::Includes& $inc) : PostQuery {
    if ($inc->has('author')) {
        return $q->withAuthor();
    }
    return $q;
};
```

It runs for `list`, `show` and `update`, so `GET /v1/posts?include=author` loads every author of the page in one go rather than one query per post. When the request asks for includes, a created or updated record is read again after the write, so an update that moves a post to another author answers with the new one. That read goes by the key and skips `scope`: the write went through, and a record the scope no longer sees is answered as written rather than with a `404` a client would retry into a second write. A bad `?include=` is refused with a `400` before anything runs, writes included.

## Who may see and change what

So far anyone may call every verb. Real apps have rules, and the crud has two hooks for them.

### Authorizing one record

`authorize` runs on every single record a request shows, creates, updates or deletes, before anything is written. It gets the `nexus::crud::Verb` and the record, and returns a problem to refuse. The blog lets anyone read a post, but only its author or an admin change it:

```echo title="src/DB/Model/Post.eco"
public static function authorizeFor(User $me) : function<status<nexus::Problem>(nexus::crud::Verb, const Post&)>
{
    return function[$me](nexus::crud::Verb $v, const Post& $p) : status<nexus::Problem> {
        if (!$v->writes()) {
            return .ok;
        }
        return $p->changeableBy($me);
    };
}
```

The action knows who is asking, so it sets the hook right before the call:

```echo title="src/Actions/Posts/DeletePost.eco"
#[nexus::through: ["Blog::Middleware::RequireUser"]]
public class DeletePost : nexus::Action
{
    // ...

    public function handle(nexus::Payload& $payload, int64 $id) : status<nexus::Problem>
    {
        $me = try $payload->state<Caller>();
        $this->crud->authorize = Post::authorizeFor($me->user);
        return $this->crud->delete($payload, $id);
    }
}
```

This is safe precisely because the crud is bound `scoped`: the hook lives as long as this one request. `Verb::writes()` is true for `create`, `update` and `delete`.

You may answer `.notFound(...)` instead of `.forbidden(...)` when even knowing the record exists would say too much.

### Narrowing every read

`authorize` looks at one record at a time, so it does not run on lists. For rules about which rows a request may see at all, set `scope`. It narrows the query every read starts from: lists, shows, updates and deletes alike, and the `total_count` too:

```echo
// only my own posts, whatever the id in the URL says
int64 $mine = $me->user->id;
$this->crud->scope = function[$mine](PostQuery $q) : PostQuery {
    return $q->where(PostTable::$authorId == $mine);
};
```

A record outside the scope answers `404`, as if it did not exist. The one read that skips it is the reload after a create or update, described under [loading includes](#loading-includes).

## Creating and updating

`create` takes a model the action built from its input, and answers with a `201`:

```echo
public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
{
    $me = try $payload->state<Caller>();
    return $this->crud->create($payload, Post($authorId: $me->user->id, $title: $in->value->title, $body: $in->value->body));
}
```

`update` reads the record, authorizes it, and hands it to your closure to change before saving. `authorize` then sees the changed record too, and both must pass, so a change that hands a post to another author is checked against the new author as well as the old one:

```echo
public function handle(nexus::Payload& $payload, int64 $id, nexus::Body<PostChanges> $in) : result<nexus::Response, nexus::Problem>
{
    $changes = $in->value;
    return $this->crud->update($payload, $id, function[$changes](Post& $p) : status<nexus::Problem> {
        if ($changes->title != null) {
            $p->title = guard $changes->title;
        }
        return .ok;
    });
}
```

The closure may return a problem to refuse the change; nothing is saved then.

::: tip When there is more to it
The blog creates and updates posts through `PostService` rather than the crud, because a post's tags need cleaning and the same logic serves the `posts:create` command and the `create_post` MCP tool. That is fine: the crud does not have to own all five verbs. Use it where it saves you work, and answer through the same transformer everywhere else.
:::

### Hooks around writes

Sometimes a write has a side effect the database does not know about. `before` runs after `authorize` and before every create, update and delete, may change the model, and may refuse with a problem. `after` runs once the write went through. The blog uses `after` to remove a deleted post's cover image from its disk:

```echo title="src/Providers/PostsProvider.eco"
// a deleted post's cover goes with it
CoverService $covers = $c->get<CoverService>();
$crud->after = function[$covers](nexus::crud::Verb $v, const Post& $p) : void {
    if ($v == nexus::crud::Verb::delete) {
        $covers->forget($p->cover);
    }
};
```

## Handing the transformer the viewer

When the transformer needs to know who is asking (to show users their own email, say), put it in the crud's `context`. It is the `nexus::rest::TransformerContext` the crud hands the transformer on every answer:

```echo
$crud->context->set<UserContext>($user: $me->user);
```

[Transformers](./transformers.md#handing-the-transformer-what-the-action-knows) explain how a transformer reads it.

## When you need the models

Occasionally an action wants the records but answers in its own way, or wants to look at them first. `find` gives you one record, loaded for the request's includes and authorized; `page` gives you a `nexus::crud::Page` with the models and what the listing read:

```echo
$post = try $this->crud->find($payload, $id);
$page = try $this->crud->page($payload, $o);
// $page->models, $page->window->page, and with count=1 $page->total and $page->matching
```

`$page->meta()` is the `nexus::rest::Meta` a list answer carries, so you may still answer with `createCollectionResponse($payload, $page->models, $page->meta())` after doing your own thing.

## When the database says no

A database error becomes the problem it means, through `nexus::carbon::Problems`: a duplicate, a broken reference or a refusal from a repository hook is a `409` with its message, a busy or lost connection a `503`, anything else a `500`. A carbon repository that refuses a post without a title, for example, answers the create with a `409` and nothing is written. [Problems and errors](./problems.md) shows how the client sees each.

## Where to next

- [Transformers](./transformers.md): what the crud answers with, includes and sensitive fields.
- [Database](./database.md): repositories, queries and the relations `load` reads.
- [Input and validation](./input.md): the input structs a create or update takes.
- [Testing](./testing.md): calling these endpoints against a real database.
