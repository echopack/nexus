---
description: Build a small posts API end to end, with a database table, validated input, a service, a transformer and two actions.
---

# Your first API

The best way to get a feel for nexus is to build something real with it. In this walkthrough we'll grow the app from [installation](./installation.md) into a small posts API: a `posts` table in MySQL, a `POST /v1/posts` that validates its body, and a `GET /v1/posts/{id}` that answers with JSON.

Along the way you'll meet most of the pieces a nexus app is made of. Don't worry about understanding every one of them in depth yet; each step links to the page that does. For now, let's just focus on getting a request through.

Everything here is a trimmed version of the blog in `examples/blog`, so you may always look there to see the full thing.

## Step 1: Add the database and transformer modules

Posts live in a database, and the API answers with JSON built from models. Two modules cover that: nexus-carbon (a [carbon](https://github.com/echopack/carbon) database with a session per request) and nexus-rest ([transformers](./transformers.md)). Add them, plus carbon itself and its MySQL driver, to `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/rest" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/carbon" { version: "^0.2.1", source: git "https://github.com/echopack/carbon" }]
#[requires: "echopack/carbon/drivers/mysql" { version: "^0.2.1", source: git "https://github.com/echopack/carbon" }]
#[requires: "echopack/rest" { version: "^0.2.1", source: git "https://github.com/echopack/rest" }]

#[sources: "src/**/*.eco"]
#[if: !NEXUS_NOGEN]
#[sources: ".nexus/*.eco"]
#[end]
#[if: !CARBON_NOGEN]
#[sources: ".carbon/*.eco"]
#[end]
```

The new `CARBON_NOGEN` block is the same idea as the nexus one: `nexus gen` also runs carbon's generator and writes the typed table code into `.carbon/`. Run `epm install` once more to fetch the new packages.

## Step 2: Describe a post

A post is a carbon model. The `#[carbon::...]` attributes say how it is stored; the `#[nexus::expose]` attributes say what the API shows:

```echo title="src/DB/Model/Post.eco"
namespace Blog::DB::Model;

use std::time;

#[carbon::model: 'posts']
public class Post : carbon::Model<Post, PostRepository>
{
    public carbon::Link $link = .detached();

    #[carbon::key]
    #[nexus::expose: { attribute: true }]
    public int64 $id = 0;

    #[nexus::expose]
    public string $title;

    #[nexus::expose]
    public string $body = '';

    #[carbon::codec: 'csv']
    #[nexus::expose: { item: 'tag' }]
    public array<string> $tags = [];

    #[carbon::created]
    #[nexus::expose]
    public time::timestamp? $createdAt = null;

    public function link() : carbon::Link&
    {
        return $this->link;
    }
}
```

A field without `#[nexus::expose]` never leaves the server, so a column you add later is private until you say otherwise.

Reading and writing posts goes through a repository. Since we have nothing special to add yet, carbon's generator writes one for us, `Blog::DB::Model::PostRepository`, along with a typed query, `PostQuery`. When you need finders or hooks of your own later, you declare the struct yourself and the generator steps aside. The blog's own `PostRepository` trims every title before it is saved, for example.

## Step 3: Create the table

The table comes from a migration:

```echo title="src/DB/Migration/CreatePosts.eco"
namespace Blog::DB::Migration;

#[carbon::migration: '20261102100100_create_posts']
public class CreatePosts : carbon::Migration
{
    public function up(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->create(carbon::ddl::Table('posts')
            ->id()
            ->string('title', 120)
            ->text('body')
            ->string('tags', $default: '')
            ->timestamps());
    }

    public function down(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->drop('posts');
    }
}
```

Now let's tell nexus how the database opens. One function builds it from `NEXUS_DATABASE_URL` and registers the repository; another lists the migrations, which carbon's generator collected for us:

```echo title="src/DB/Database.eco"
namespace Blog::DB;

use Blog::DB::Model::PostRepository;

public function open(const nexus::carbon::DatabaseConfig& $config) : result<carbon::DB, carbon::Error>
{
    if ($config->url->empty()) {
        return .error(.invalid('NEXUS_DATABASE_URL is not set; it looks like mysql://user:pass@host:3306/blog'));
    }
    $pool = try carbon::mysql::Source::parse($config->url);
    $db = carbon::DB($pool);
    try $db->register<PostRepository>();
    try Blog::DB::Model::Carbon::check($db);
    return .ok($db);
}

public function migrations() : array<carbon::migrate::Step>
{
    return Blog::DB::Migration::Carbon::migrations();
}
```

And add the extension to the list, before the app:

```echo title="src/Extensions.eco"
array<nexus::Extension> $all = [
    nexus::http::Extension(),
    nexus::carbon::Extension((nexus::carbon::DatabaseConfig $config) => Blog::DB::open($config), Blog::DB::migrations()),
    Blog::App(),
];
```

With that in place, the app binary has a `migrate` command. Let's run it against a local MySQL:

```bash
export NEXUS_DATABASE_URL=mysql://app:secret@127.0.0.1:3306/blog
echoc run -- migrate
```

[Database](./database.md) covers the session per request and the other migrate commands.

## Step 4: Say what creating a post takes

A body is described by an `#[nexus::input]` struct. Its rules are checked before any of our code runs:

```echo title="src/Inputs/NewPost.eco"
namespace Blog::Inputs;

/**
 * What creating a post takes.
 */
#[nexus::input]
public struct NewPost
{
    #[nexus::rule: { min: 3, max: 120 }]
    public string $title;

    #[nexus::rule: { notBlank: true }]
    public string $body;

    #[nexus::rule: { max: 5, distinct: true, each: { trim: true, lower: true, notBlank: true, max: 30 } }]
    public array<string> $tags = [];
}
```

`title` and `body` have no default, so they are required. `tags` may be left out. Each tag is trimmed and lowercased on the way in. `nexus gen` checks the rules themselves too: a `min` on a field that can't have one is a build error, not a surprise at runtime. Every rule is listed in [input and validation](./input.md).

## Step 5: Put the logic in a service

We'll keep the actions thin and put the work in a service, so a [command](./commands.md) or an [MCP tool](./mcp.md) can reuse it later:

```echo title="src/Services/PostService.eco"
namespace Blog::Services;

use Blog::Inputs::NewPost;
use Blog::DB::Model::{Post, PostRepository};

public class PostService
{
    private PostRepository $posts;

    public constructor(PostRepository $posts)
    {
        $this->posts = $posts;
    }

    /**
     * Post `$id`; a 404 when there is none.
     */
    public function find(int64 $id) : result<Post, nexus::Problem>
    {
        $found = try $this->posts->find()->get($id);
        $p = guard $found else {
            return .error(.notFound('the post'));
        };
        return .ok($p);
    }

    /**
     * Publishes `$in`.
     */
    public function create(const NewPost& $in) : result<Post, nexus::Problem>
    {
        $made = try $this->posts->create(Post($title: $in->title, $body: $in->body, $tags: $in->tags));
        return .ok($made);
    }
}
```

Notice that the service speaks `nexus::Problem`. A post that doesn't exist is a `notFound`, which the client will see as a `404`.

## Step 6: Shape the answer with a transformer

A transformer turns a `Post` into what the API answers. `nexus gen` wrote `PostMapping` from the exposed fields, so all that's left is anything extra. Let's add a link to the post itself:

```echo title="src/Transformers/PostTransformer.eco"
namespace Blog::Transformers;

use Blog::Actions::Posts::ShowPost;
use Blog::DB::Model::{Post, PostMapping};

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

The link is built from the action's type, not a string, so renaming the route can't leave a dead link behind.

## Step 7: Write the actions

Now we are ready for the endpoints themselves. Each one is a class with a `handle()`:

```echo title="src/Actions/Posts/CreatePost.eco"
namespace Blog::Actions::Posts;

use Blog::Inputs::NewPost;
use Blog::Services::PostService;
use Blog::Transformers::PostTransformer;

/**
 * Publishes a post.
 */
public class CreatePost : nexus::Action
{
    private PostService $posts;
    private PostTransformer $transformer;

    public constructor(PostService $posts, PostTransformer $transformer)
    {
        $this->posts = $posts;
        $this->transformer = $transformer;
    }

    public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
    {
        $made = try $this->posts->create($in->value);
        return $this->transformer->createResponse($payload, $made, status: 201);
    }
}
```

```echo title="src/Actions/Posts/ShowPost.eco"
namespace Blog::Actions::Posts;

use Blog::Services::PostService;
use Blog::Transformers::PostTransformer;

/**
 * One post.
 */
public class ShowPost : nexus::Action
{
    private PostService $posts;
    private PostTransformer $transformer;

    public constructor(PostService $posts, PostTransformer $transformer)
    {
        $this->posts = $posts;
        $this->transformer = $transformer;
    }

    public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
    {
        $post = try $this->posts->find($id);
        return $this->transformer->createResponse($payload, $post);
    }
}
```

`nexus::Body<NewPost>` is the validated body; `int64 $id` comes from the `{id}` in the path. [Actions](./actions.md) lists everything `handle()` may ask for.

## Step 8: Wire it together

Finally, the app says how each piece is built and where each action answers. Let's give posts a provider of their own:

```echo title="src/Providers/PostsProvider.eco"
namespace Blog::Providers;

use container::Container;
use Blog::Actions::Posts::{CreatePost, ShowPost};
use Blog::DB::Model::{Post, PostRepository};
use Blog::Services::PostService;
use Blog::Transformers::PostTransformer;

public class PostsProvider : nexus::Provider
{
    public function register(nexus::App $app) : void
    {
        $app->bindRepository<PostRepository>();
        $app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>()));
        $app->bindTransformer<Post, PostTransformer>(PostTransformer($app->router()));

        $app->bindAction<CreatePost>((Container $c) => CreatePost($c->get<PostService>(), $c->get<PostTransformer>()))
            ->route([.post], '/v1/posts');
        $app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostService>(), $c->get<PostTransformer>()))
            ->route([.get], '/v1/posts/{id}');
    }
}
```

And list it in the app:

```echo title="src/App.eco"
public function providers() : array<nexus::Provider>
{
    array<nexus::Provider> $all = [PostsProvider()];
    return $all;
}

public function services(nexus::Services& $s) : status<nexus::BootError>
{
    $app = nexus::App($s, $this->providers());
    $app->bindAction<Health>(() => Health())->route([.get], '/health');
    return .ok;
}
```

`scoped:` means one `PostService` per request, built on that request's own database session. [Extensions and wiring](./extensions.md) explains the lifetimes.

## Step 9: Try it

Start the server:

```bash
echoc run -- serve
```

Create a post:

```bash
curl -s -X POST http://127.0.0.1:3246/v1/posts \
  -H 'Content-Type: application/json' \
  -d '{"title":"Hello world","body":"My first post.","tags":[" Echo "]}'
```

```json
{"data":{"id":1,"title":"Hello world","body":"My first post.","tags":["echo"],"created_at":"...","url":"/v1/posts/1"}}
```

The tag came back trimmed and lowercased, and the post links to itself. Read it back with `curl http://127.0.0.1:3246/v1/posts/1`, or ask for XML with `-H 'Accept: application/xml'`: the transformer answers in whichever format the client accepts.

### So, what if the body is wrong?

Let's send a title that is too short and forget the body:

```bash
curl -s -X POST http://127.0.0.1:3246/v1/posts -H 'Content-Type: application/json' -d '{"title":"Hi"}'
```

```json
{
  "type": "about:blank",
  "title": "Unprocessable Content",
  "status": 422,
  "detail": "the input did not validate",
  "requestId": "...",
  "errors": [
    {"field": "title", "code": "min", "message": "The title field must be at least 3 characters.", "params": {"min": "3"}},
    {"field": "body", "code": "required", "message": "The body field is required.", "params": {}}
  ]
}
```

Every refused field is in one answer, each with a stable `code` a client can switch on and a `message` a person can read. `CreatePost` never ran. And a post that doesn't exist, `GET /v1/posts/99`, is a `404` problem document, straight from the service's `notFound`.

## What we built, and what's next

In a handful of small files we have a validated, database-backed API whose wiring you can read top to bottom in one provider. From here, you might like to:

- list posts a page at a time with [CRUD endpoints](./crud.md);
- let only signed in users write, with [authentication](./auth.md) and [middleware](./middleware.md);
- send a welcome mail in the background with [tasks](./tasks.md) and [mail](./mail.md);
- test the whole flow on a real database with [testing](./testing.md).
