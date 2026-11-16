---
description: Every module nexus ships, what each one adds, and the lines that bring it into your app.
---

# Modules

nexus is a small core plus a set of modules, all in one repository. The core knows no transport and no database. Everything else, from the HTTP server to the debug console, is a module you opt into. Your binary only carries what you list.

This page is the map. Each entry says what the module is for, how to add it, and which page covers it.

## Adding a module

A module takes two lines. The first goes in your `module.eco`, with the module's path inside the nexus repository:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/work" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

The second goes in your list of extensions, before your app:

```echo title="src/Extensions.eco"
nexus::work::Extension(),
```

Then run `epm install`. A few modules are plain libraries without an extension (nexus-app, nexus-rest, nexus-crud and the testing modules); those only need the first line.

### Adapters

Several modules keep their state in memory out of the box, which is perfect for development and tests. An **adapter** moves that state somewhere every server shares, such as your database or Redis. Adapters live in a folder under their module (`modules/work/carbon`) and are listed right after it:

```echo
nexus::work::Extension(),
nexus::work::carbon::Extension(),
```

## The core

#### nexus

`echopack/nexus`. The kernel, actions, routing, input and validation, responses, middleware, problems, typed configuration, signals, logging, translations, the app's command line and the `nexus gen` tool. Every app requires it. Start with [the request lifecycle](./lifecycle.md).

## Building the app

#### nexus-app

`echopack/nexus/modules/app`, no extension. `nexus::App` and `nexus::Provider`: one wiring object with a helper for every door the other modules bring. See [extensions and wiring](./extensions.md).

#### nexus-http

`echopack/nexus/modules/http`, `nexus::http::Extension()`. Serves the app over HTTP/1.1 on libhttp, with websockets and server-sent events. nexus does the routing; TLS belongs to the proxy in front. See [the HTTP server](./http.md).

## Data and answers

#### nexus-carbon

`echopack/nexus/modules/carbon`, `nexus::carbon::Extension(open, migrations)`. A carbon database from `NEXUS_DATABASE_URL`, a session per request with a pooled connection, and the `migrate` commands. See [database](./database.md).

#### nexus-rest

`echopack/nexus/modules/rest`, no extension. Transformers that turn models into JSON or XML answers, with shapes, sensitive fields and `?include=`. See [transformers](./transformers.md).

#### nexus-crud

`echopack/nexus/modules/crud`, no extension. List, show, create, update and delete over a carbon repository, with one set of listing conventions. See [CRUD endpoints](./crud.md).

## Security

#### nexus-auth

`echopack/nexus/modules/auth`, `nexus::auth::Extension(...)`. Who is calling: prefixed bearer tokens and signed sessions, password hashing, login throttling, and the `RequireSession` and `Authenticate` middleware. See [authentication](./auth.md).

- **nexus-auth-carbon** (`modules/auth/carbon`, `nexus::auth::carbon::Extension()`): keeps tokens and sessions in the app's database.

#### nexus-oauth

`echopack/nexus/modules/oauth`, `nexus::oauth::Extension(...)`. An OAuth 2.1 authorization server for the app's protected resources, so a client such as an MCP client connects with a click instead of a pasted token. See [OAuth server](./oauth.md).

- **nexus-oauth-carbon** (`modules/oauth/carbon`, `nexus::oauth::carbon::Extension()`): keeps clients, codes and grants in the database.

#### nexus-connect

`echopack/nexus/modules/connect`, `nexus::connect::Extension(...)`. Signing in with Google or any OpenID Connect provider, without cookies. See [sign in with Google](./connect.md).

- **nexus-connect-carbon** (`modules/connect/carbon`, `nexus::connect::carbon::Extension()`): keeps sign-in attempts and linked accounts in the database.

## Background work

#### nexus-work

`echopack/nexus/modules/work`, `nexus::work::Extension()`. Tasks, async queues on threads in the process, distributed queues every server shares, pipelines, and a cron-style scheduler. See [tasks and queues](./tasks.md) and [scheduling](./scheduling.md).

- **nexus-work-carbon** (`modules/work/carbon`, `nexus::work::carbon::Extension()`): keeps the distributed queue in the database.

## Services

#### nexus-mail

`echopack/nexus/modules/mail`, `nexus::mail::Extension()`. Typed mails with checked text and HTML templates, sent over SMTP, to the log, or kept in memory for tests. See [mail](./mail.md).

#### nexus-files

`echopack/nexus/modules/files`, `nexus::files::Extension()`. Named disks on a local directory or in memory, with ranges, `304`s and expiring signed links. See [files](./files.md).

- **nexus-files-s3** (`modules/files/s3`, `nexus::files::s3::Extension()`): disks in S3 or anything that speaks its API.

#### nexus-cache

`echopack/nexus/modules/cache`, `nexus::cache::Extension()`. A small key/value cache whose failures never fail a request. See [cache](./cache.md).

- **nexus-cache-redis** (`modules/cache/redis`, `nexus::cache::redis::Extension()`): the cache in Redis.

## Realtime and agents

#### nexus-realtime

`echopack/nexus/modules/realtime`, `nexus::realtime::Extension()`. Websocket channels with authorization, presence and whispers, and a broadcaster any process may send through. See [realtime channels](./realtime.md).

- **nexus-realtime-redis** (`modules/realtime/redis`, `nexus::realtime::redis::Extension()`): carries broadcasts to every server's sockets.

#### nexus-mcp

`echopack/nexus/modules/mcp`, `nexus::mcp::Extension()`. The app's tools over the Model Context Protocol at `POST /mcp`, with schemas written from your input types. See [MCP tools](./mcp.md).

#### nexus-debug

`echopack/nexus/modules/debug`, `nexus::debug::Extension(...)`. A debug console at `/__nexus/`: requests with their timelines, the live log, routes and settings, behind a gate. See [debug console](./debug.md).

- **nexus-debug-work** (`modules/debug/work`, `nexus::debug::work::Extension()`): the queues in the console.
- **nexus-debug-realtime** (`modules/debug/realtime`, `nexus::debug::realtime::Extension()`): the open sockets in the console.

## Testing

#### nexus-testing

`echopack/nexus/modules/testing`, no extension, for test targets. Boots the app in process and sends requests straight into the kernel, no socket needed. See [testing](./testing.md).

#### nexus-carbon-testing

`echopack/nexus/modules/carbon/testing`, no extension, for test targets. A MySQL database of its own for each integration test, migrated with the app's migrations and dropped when the test ends.

## A typical list

Here is the order the blog boots its modules in. The rule of thumb: transport first, then the database, then everything that may keep state in it, then the app.

```echo title="src/Extensions.eco"
array<nexus::Extension> $all = [
    nexus::http::Extension(),
    nexus::carbon::Extension((nexus::carbon::DatabaseConfig $config) => Blog::DB::open($config), Blog::DB::migrations()),
    nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),
    nexus::auth::carbon::Extension(),
    nexus::oauth::Extension(stores: .provided),
    nexus::oauth::carbon::Extension(),
    nexus::connect::Extension(page: '/signed-in', connectors: [nexus::connect::Google()], stores: .provided),
    nexus::connect::carbon::Extension(),
    nexus::realtime::Extension(),
    nexus::realtime::redis::Extension(),
    nexus::debug::Extension(gate: ...),
    nexus::debug::realtime::Extension(),
    nexus::mcp::Extension(),
    nexus::work::Extension(),
    nexus::work::carbon::Extension(),
    nexus::debug::work::Extension(),
    nexus::mail::Extension(),
    nexus::files::Extension(),
    nexus::files::s3::Extension(),
    Blog::App(),
];
```

If you get the order wrong, don't worry: a module that needs another one, or an adapter listed in the wrong place, stops the boot with a line that says what to move.

## Where to next

- [Installation](./installation.md): a first app with just the core and nexus-http.
- [API reference](/api/): every public type of every module.
