---
description: Where each kind of class lives in a nexus app, using the blog example as the map.
---

# Project layout

nexus doesn't scan folders, so it doesn't care where your files live. Every action, task and channel is found by its type, and wired in code you write. You are free to organize your app however you like.

That said, a familiar layout makes an app much easier to find your way around, for you and for the next person. This page describes the one `examples/blog` uses: **one folder per layer**, so the folder tells you what kind of thing a class is.

## The top level

```txt
blog/
  module.eco          the manifest: requirements, the nexus gen hook, targets
  src/                the app's code
  resources/          files embedded at build time: mail templates, translations, a web page
  tests/              integration flows and unit checks
  scripts/            shell helpers: a dev loop, a smoke test, a benchmark
  .nexus/nexus.eco    written by nexus gen; committed
  .carbon/models.eco  written by carbon's generator; committed
  ecobuild/           build output; ignored
  vendor/             packages epm fetched; ignored
```

The generated folders are committed on purpose: what runs should be readable in the repository, and CI may check nothing is stale with `nexus gen --check`. [nexus gen](./generator.md) explains what goes in them.

## Inside `src/`

```txt
src/
  main.eco            one line: nexus::Kernel::main(Blog::extensions())
  Extensions.eco      the list of extensions, in boot order
  App.eco             the app's own extension: providers, app-wide wiring, boot hooks

  Providers/          one provider per part of the app: PostsProvider, AuthProvider, ...
  Actions/            one class per endpoint, grouped by resource: Posts/ShowPost.eco
  Inputs/             #[nexus::input] structs: NewPost, PostChanges, Credentials
  Rules/              rule classes for checks that need services: UniqueEmail
  Middleware/         RequireUser, RequireAdmin, ServerTiming
  Services/           the logic every door shares: PostService, CommentService
  Transformers/       how models become answers: PostTransformer, UserTransformer
  DB/
    Model/            carbon models: Post, User, Comment
    Query/            hand-written queries with scopes: PostQuery
    Repository/       hand-written repositories with hooks: PostRepository
    Migration/        one class per migration
    Database.eco      opening the database, the list of migrations
  Config/             #[nexus::config] structs: BlogConfig
  Commands/           command line doors: ShowPostCommand, SetPassword
  Tools/              MCP doors: CreatePostTool
  Tasks/              background work: SendWelcome, PruneAuth
  Queues/             lanes and the queue types named after them
  Signals/            signal structs and their handlers
  Channels/           realtime channels: PostChannel, UserChannel
  Mail/               mailables: WelcomeMail
  Disks/              file volumes and disk types: CoverDisk
  Logs/               #[nexus::log] records: PostPublished
  Types/              small shared types: Caller, Role
```

Namespaces follow the folders: `src/Actions/Posts/ShowPost.eco` declares `Blog::Actions::Posts::ShowPost`.

## A few habits worth keeping

**Services hold the logic, doors stay thin.** An action, a command and an MCP tool are three doors onto the same `PostService`. When a rule changes ("only the author may edit a post"), it changes in one place.

**Providers mirror the resources.** `PostsProvider` binds everything about posts: its repository, service, transformer, actions, tool and commands. To learn what the app does with posts, you read one file.

**Inputs are their own types.** `NewPost` and `PostChanges` are separate structs, even though they look alike, because creating and editing a post have different rules. A struct per purpose keeps each set of rules honest.

**Resources are built in.** Translation catalogs and the browser page in `resources/` are pulled in at build time with `std::embed`, and `nexus gen` compiles the mail templates into the generated code, so the binary is all you deploy.

## Where to next

- [Extensions and wiring](./extensions.md): how `App.eco` and the providers fit together.
- [Modules](./modules.md): which module each of these folders leans on.
