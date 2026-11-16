---
description: A carbon database for your app. A session per request with a pooled connection, repositories in the container, migrations run from the app binary.
---

# Database

nexus talks to databases through [carbon](https://github.com/echopack/carbon), the active record library for Echo. The glue lives in the `nexus-carbon` module. Add it to your app's `module.eco`, next to carbon itself and a driver:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/carbon" { version: "^0.2.1", source: git "https://github.com/echopack/carbon" }]
#[requires: "echopack/carbon/drivers/mysql" { version: "^0.2.1", source: git "https://github.com/echopack/carbon" }]
```

Then put the extension in your app's extensions list, after the HTTP server and before your own app:

```echo title="src/Extensions.eco"
nexus::carbon::Extension((nexus::carbon::DatabaseConfig $config) => Blog::DB::open($config), Blog::DB::migrations()),
```

A web app and its database have a few chores in common. Every request wants a connection of its own, and a transaction that can't leak into another request. That connection should go back to the pool when the request ends, whatever happened. And the schema changes should ship with the code that needs them. `nexus-carbon` takes care of all three: you say how the database opens, and the extension gives every request a `carbon::Session` with a pooled connection, puts your repositories in the container, and adds `migrate` to your app binary.

This page covers how carbon plugs into nexus. Models, queries, relations and migrations themselves are carbon's, and [carbon's own README](https://github.com/echopack/carbon#readme) is the place to learn them.

## Opening the database

The extension's first argument is a function that builds the database from its config. The blog keeps it in `src/DB/Database.eco`:

```echo title="src/DB/Database.eco"
namespace Blog::DB;

use Blog::DB::Model::UserRepository;
use Blog::DB::Repository::{CommentRepository, PostRepository};

public function open(const nexus::carbon::DatabaseConfig& $config) : result<carbon::DB, carbon::Error>
{
    if ($config->url->empty()) {
        return .error(.invalid('NEXUS_DATABASE_URL is not set; it looks like mysql://user:pass@host:3306/blog'));
    }
    $pool = try carbon::mysql::Source::parse($config->url);
    $db = carbon::DB($pool);
    try wire($db);
    return .ok($db);
}

public function wire(carbon::DB $db) : status<carbon::Error>
{
    try $db->register<UserRepository>();
    try $db->register<PostRepository>();
    try $db->register<CommentRepository>();
    try Blog::DB::Model::Carbon::check($db);
    // ...
    return .ok;
}
```

It runs once, at boot. If it returns an error, the boot stops with `nexus-carbon: the database did not open: ...`, so a typo in the URL never turns into a 500 on the first request. When it succeeds, the extension seals the `carbon::DB` so every thread may share it, and binds it in the container.

`Carbon::check` is generated, as you'll see below. It makes sure every repository your models need was registered, so a forgotten `register` is a boot error too.

Why a function of your own instead of a URL the extension parses? Because only your app knows which driver it uses, which repositories exist, and which modules bring tables of their own. The blog's `wire` also registers the tables of `nexus-auth`, `nexus-work`, `nexus-oauth` and `nexus-connect`, which keep their state in the same database.

### The database URL

The config is `nexus::carbon::DatabaseConfig`, read from `NEXUS_DATABASE_URL` in the environment or a `.env` file:

```txt
NEXUS_DATABASE_URL=mysql://app:secret@127.0.0.1:3306/blog
```

What the URL means is up to the function you wrote. For `carbon::mysql::Source`, it is `mysql://user:password@host:port/database`, with query options such as `timeout`, `connectTimeout` and `fetchServerKey` (`?connectTimeout=5s`). An option the driver doesn't know is an error, so a misspelled one stops the boot.

The setting is marked secret, so `env --dotenv` leaves it blank for you to fill in rather than printing a value. [Configuration](./configuration.md) covers `.env` files and how settings are read.

## Repositories in your actions

Once the database is open, your actions want repositories. If you use nexus-app's builder, bind each one with `bindRepository`:

```echo title="src/Providers/PostsProvider.eco"
public function register(nexus::App $app) : void
{
    $app->bindRepository<PostRepository>();
    $app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>(), $c->get<UserRepository>(), $c->get<nexus::Logger>()));
    // ...
}
```

From there on, anything built per request may ask for a `PostRepository` in its constructor:

```echo title="src/Services/PostService.eco"
public class PostService
{
    private PostRepository $posts;
    private UserRepository $users;
    private nexus::Logger $log;

    public constructor(PostRepository $posts, UserRepository $users, nexus::Logger $log)
    {
        $this->posts = $posts;
        $this->users = $users;
        $this->log = $log;
    }

    public function find(int64 $id) : result<Post, nexus::Problem>
    {
        $found = try $this->posts->find()->withAuthor()->get($id);
        $p = guard $found else {
            return .error(.notFound('the post'));
        };
        return .ok($p);
    }
}
```

If you wire services by hand in an extension of your own, `nexus::carbon::Repositories::bind<PostRepository>($s)` does the same thing inside `services()`.

### One session per request

So, where does the connection come from? Every repository is built from the request's own `carbon::Session`. The session borrows one connection from the pool with its first statement and keeps it for the whole request, then gives it back when the request ends. Two repositories in the same request share that connection, so a transaction you open covers both:

```echo title="src/Services/PostService.eco"
$repo = $this->posts;
$made = try $repo->connection()->transaction<array<Post>>(function[$repo, $authorId, $all]() : result<array<Post>, carbon::Error> {
    $out = arr::room<Post>($all->count());
    foreach ($all as const &$one) {
        $p = try $repo->create(Post($authorId: $authorId, $title: $one->title, $body: $one->body, $tags: PostService::tags($one->tags)));
        $out[] = mv $p;
    }
    return .ok($out);
});
```

The batch publishes every post or none of them, and no other request can see it half done.

The same goes for work that doesn't come from HTTP. A task, a command, or an MCP tool runs on a payload of its own, with a session of its own, so `$payload->get<PostRepository>()` works there exactly as it does in an action.

> [!WARNING]
> A repository you bind must also be registered on the database in your `open` function. `Carbon::check` catches a forgotten one at boot; if one slips past it anyway, resolving it stops the program with a message naming the repository.

### Database errors as problems

A function that answers `result<T, nexus::Problem>` may `try` a carbon call directly. The `carbon::Error` converts into a `nexus::Problem` on the way up, the way `nexus::carbon::Problems::of` reads it:

| carbon error | What the client gets |
|:--|:--|
| no row (`missing`) | `404` |
| a stale version, a duplicate, a broken reference or constraint | `409` |
| a refusal from a repository hook | `409` with the refusal's message |
| busy, a deadlock, a lost or exhausted connection | `503` |
| anything else | `500`, whose cause only dev and test show |

That makes a repository hook a natural home for a rule. The blog's `PostRepository` refuses an empty title, and the client hears about it as a `409` saying "a post needs a title":

```echo title="src/DB/Repository/PostRepository.eco"
public struct PostRepository : carbon::Repository<Post, PostQuery, int64>, PostWiring
{
    public carbon::Session $session;

    public function before(carbon::Event $event, Post& $post) : status<carbon::Error>
    {
        if ($event->saves()) {
            $post->title = string::from(str::trim($post->title));
            if ($post->title->empty()) {
                return .error(.refused(carbon::Refusal('a post needs a title')));
            }
        }
        return .ok;
    }
}
```

[Problems and errors](./problems.md) has the full story on how a problem reaches the client.

## Models, queries and repositories

A model is a class marked `#[carbon::model]`, a query is a struct conforming to `carbon::Query`, and a repository is a struct conforming to `carbon::Repository`. The blog keeps them in `src/DB/Model/`, `src/DB/Query/` and `src/DB/Repository/`:

```echo title="src/DB/Model/Post.eco"
#[carbon::model: 'posts']
public class Post : carbon::Model<Post, PostRepository>
{
    public carbon::Link $link = .detached();

    #[carbon::key]
    #[nexus::expose: { attribute: true }]
    public int64 $id = 0;

    public int64 $authorId;

    #[nexus::expose]
    public string $title;

    // ...

    #[carbon::belongsTo: 'authorId']
    #[nexus::expose]
    public carbon::One<User> $author = .unloaded();

    public function link() : carbon::Link&
    {
        return $this->link;
    }
}
```

The `#[nexus::expose]` marks are not carbon's. They say what the API shows of a post, and [transformers](./transformers.md) explains them.

You don't write the table mapping yourself. carbongen reads the `#[carbon::*]` attributes and writes it into `.carbon/`: a `PostTable` with every column as a static (`PostTable::$title`), the relation loaders behind `withAuthor()`, the `PostWiring` your repository conforms to, and the `Carbon::check` and `Carbon::migrations()` you saw above. A model with no repository of its own, like the blog's `User`, gets a plain `UserRepository` and `UserQuery` generated for it.

Don't worry about running carbongen by hand. `nexus gen` runs it on the same declarations pass it makes for your actions, as long as your manifest lists `.carbon/` behind its define:

```echo title="module.eco"
#[hook: before_build { run: "nexus", args: ["gen"] }]

#[sources: "src/**/*.eco"]
#[if: !NEXUS_NOGEN]
#[sources: ".nexus/*.eco"]
#[end]
#[if: !CARBON_NOGEN]
#[sources: ".carbon/*.eco"]
#[end]
```

Since carbongen is offered by carbon, your module has to require `echopack/carbon` directly, as in the opening snippet. [nexus gen](./generator.md) explains the pass and the defines.

## Migrations

A migration is a class marked `#[carbon::migration]` with an `up` and a `down`. The id orders them, so a timestamp prefix keeps them in the order you wrote them:

```echo title="src/DB/Migration/CreatePosts.eco"
namespace Blog::DB::Migration;

#[carbon::migration: '20261102100100_create_posts']
public class CreatePosts : carbon::Migration
{
    public function up(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->create(carbon::ddl::Table('posts')
            ->id()
            ->bigint('author_id')
            ->string('title', 120)
            ->text('body')
            ->string('tags', $default: '')
            ->string('cover', 255, $nullable: true)
            ->timestamps()
            ->foreign('author_id', 'users'));
    }

    public function down(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->drop('posts');
    }
}
```

carbongen lists every migration of a namespace in its `Carbon::migrations()`. You hand the full list to the extension as its second argument. The blog puts the tables of the modules it uses first, then its own:

```echo title="src/DB/Database.eco"
public function migrations() : array<carbon::migrate::Step>
{
    $all = nexus::auth::carbon::Tables::migrations();
    $all->extend(nexus::work::carbon::Tables::migrations());
    $all->extend(nexus::oauth::carbon::Tables::migrations());
    $all->extend(nexus::connect::carbon::Tables::migrations());
    $all->extend(Blog::DB::Migration::Carbon::migrations());
    return $all;
}
```

### Running them

With migrations handed over, the extension adds four [commands](./commands.md) to your app binary. There is no separate migration tool to install or keep in step with your code: the binary you deploy carries exactly the migrations it needs.

```sh
NEXUS_DATABASE_URL=mysql://app:secret@127.0.0.1:3306/blog ./blog migrate
```

| Command | What it does |
|:--|:--|
| `migrate` | runs the migrations that have not run yet; `--to <id>` stops after that one |
| `migrate:status` | lists the migrations that ran, with their batch, and the ones still pending |
| `migrate:down` | undoes the last batch |
| `migrate:reset` | undoes every migration |

`migrate:status` also lists migrations the database has recorded that your app doesn't know about, which usually means a newer build ran against this database:

```txt
ran      20261102100000_create_users  (batch 1)
ran      20261102100100_create_posts  (batch 1)
ran      20261102100150_create_comments  (batch 1)
pending  20261102100200_seed_editor
```

`migrate:down` and `migrate:reset` undo schema changes. In `prod` mode they refuse to run without `--force`, so a stray command in the wrong terminal can't drop your production tables.

## Watching the queries

Every statement a request runs lands on that request's timeline when someone is watching it in the [debug console](./debug.md). The text is kept, cut at 2000 bytes; the parameters are not, since they may be passwords or tokens.

## On PostgreSQL

The extension builds migrations for MySQL unless you say otherwise. For PostgreSQL, open a `carbon::pgsql::Source` in your function (from `echopack/carbon/drivers/pgsql`), and pass the grammar:

```echo
nexus::carbon::Extension((nexus::carbon::DatabaseConfig $config) => Blog::DB::open($config), Blog::DB::migrations(), grammar: carbon::ddl::Postgres()),
```

carbon's README lists what behaves differently on PostgreSQL.

## Settings

| Variable | Default | What it does |
|:--|:--|:--|
| `NEXUS_DATABASE_URL` | empty | The database URL your `open` function reads. Secret. |

## Where to next

- [Transformers](./transformers.md): turning models into JSON or XML responses.
- [CRUD endpoints](./crud.md): list, show, create, update and delete a model with little code.
- [Testing](./testing.md): booting the app on a MySQL database of each test's own.
- [carbon](https://github.com/echopack/carbon#readme): models, queries, relations and migrations in depth.
