# nexus: the Echo successor to ClanCats Nexus

## Context

ClanCats Nexus (PHP, `~/Developer/ClanCats/nexus`) wires everything through `.ctn` container
metadata: routes, commands, signals, views and translations. It has no kernel object, no
middleware, no module system, global `PATH_*` constants, and storage that every app re-wires
by hand. Three apps use it (deckofpoints, yourlocalchef, oxycam-web).

The Echo foundation now exists in `~/Developer/echolibs`:

| Area | Libraries |
|---|---|
| DI | container |
| Data | carbon on hydrahon on libmysql |
| Responses | rest (RestTransformers, rewritten 2026-11-02) |
| Dates | calendar |
| HTTP | libhttp (server), libcurl (client) |
| Other | libcrypto, libjson, libcommand |

The two real Echo web apps, harbor and Recensio, each re-invented the same plumbing: `Refusal`/`Reply`/`Doc`, CORS, `Throttle`, passwords and tokens, OAuth 2.1, MCP JSON-RPC, the signal shim, `setting()` config, CLI boilerplate, hand-mounted "doors", two nested closures per route, and a second route matcher.

**nexus** (namespace `nexus`, `~/Developer/echolibs/nexus`, today a hello-world skeleton) becomes
the framework that absorbs all of that. It is API-first, typed end to end, code is discovered by attributes at build time through
one generator, and it is extended through one Extension mechanism.

## Decisions (made with the user, 2026-11-02)

| Topic | Decision |
|---|---|
| Discovery | **Registration by hand, generation by type** (revised 2026-11-03): where a door answers (route, command name, tool name, listener, task queue and schedule) is said in code where the app is wired (`nexus::Services`, or `nexus::App` with a helper per door and `nexus::Provider` per part of the app). **`nexus gen`** (reads `echoc -p decls`) finds actions, commands, tools and tasks by what they conform to and writes only what their types tell, keyed by `type_id`. Shape attributes stay: `#[nexus::input]`, `#[nexus::config]`, field attributes, `#[nexus::answers]` |
| Handler unit | **One class per action**, conforming to the marker `nexus::Action`, with a `handle(...)` method |
| Return | `result<T, nexus::Problem>`, auto-encoded. **T is a `nexus::Response` in most cases** (revised after M5), else `json::Value`, a string, a `nexus::Resource`, a `Redirect` or a `Stream` |
| Answers | **Services return models; an action answers with the `nexus::Response` a transformer builds from a generated mapping** (revised 2026-11-05): `return $this->transformer->createResponse($payload, $post);`. The model marks what it exposes (`#[nexus::expose]`, options `key`/`shapes`/`attribute`/`item`/`stamp`/`include: "default"`), declares named shapes (`#[nexus::shapes: [{ name: "admin", sensitive: true }]]`) and marks `#[nexus::sensitive]` fields, which only sensitive shapes may expose (never the default one, which nested includes use). `nexus gen` writes one `<Model><Shape>Mapping` interface per shape (`name()`, `map()`, `availableIncludes()`, `defaultIncludes()`); an `#[atomic]` transformer conforms to `nexus::rest::Transformer<M>` and a mapping, and its `transform(const M&, nexus::rest::Item&, ctx)` hook adds, replaces or removes keys per item (a sensitive key needs `$item->reveal(key)`). JSON or XML by Accept, `?include=` checked against `availableIncludes()`, a typed `nexus::rest::TransformerContext` from the action. No resource structs, no restgen. `#[nexus::answers: { response: "blog::PostTransformer" }]` (or `collection:`) names the transformer for OpenAPI (M6) |
| HTTP types | Own `nexus::Request`/`Response`; libhttp is the first `Transport` |
| DI | echolibs/container, **every binding hand-written, actions included**: `bindAction<A>(method:, path:, factory)` binds and routes in one call. At boot every route is checked for a binding, a generated dispatcher and path parameters that fit `handle()` |
| Action lifetime | Per request (`scope:` binding on a request child container) |
| Extensions | `nexus::Extension` with default-bodied hooks, **listed in code** in `main.eco`. **The app is an Extension** |
| Config | Typed `#[nexus::config: "db"]` structs, `#[nexus::env]`, `#[nexus::secret]`. Generated loader: flags, then env, then `.env`, then defaults |
| Packaging | Core plus sub-modules in one repo (carbon's `drivers/mysql` pattern) |
| Middleware | Classes for wrapping concerns, with their dependencies in the constructor: the extensions' (atomic, shared), the app's around every request (**`$app->middleware<M>()`**, built per request), a route's (**`->middleware<Audit>()`**) and the action's own, named on the class in **`#[nexus::through: [...]]`**, which runs on every route and around every MCP tool call. Middleware resolves what a request is (who signed it, their user) and **`put`s** it in the payload; the action reads it with **`$payload->state<T>()`** (a logged 500 when no middleware put it) |
| Groups | **None.** Each action states its full path (`/v1/posts/{id}`); versioning lives in the path literally |
| Input | `#[nexus::input]` structs with generated JSON/form/query decoders. **Laravel-like rules as a typed record** (`#[nexus::rule: { trim: true, between: [3, 120], email: true }]`), checked at `nexus gen` time per field kind; the type does `required`/`nullable`/`in:` (backed enums). **Rule classes** (`nexus::Rule<T>`, services injected) via `check:` on a field or the whole input. **Nesting**: fields typed as other inputs or lists of them, each bringing its own rules (`posts.1.title`). **Messages** in English with `#[nexus::label]`/`#[nexus::message]`, translated through `nexus::Messages` catalogs by Accept-Language (revised after M5). One 422 with `{field, code, params, message}` |
| Views | **None.** API plus embedded SPA |
| Auth | Pluggable guards. Built in: **prefixed bearer tokens** and **HMAC request-signed tokens** (the yourlocalchef scheme plus a body hash, ±5 min window) |
| Database | Optional `nexus-carbon`, one `carbon::Session` per request |
| Errors | `nexus::Problem` enum rendered as RFC 9457 |
| Tasks | Structs conforming to `nexus::work::Task`, typed payloads, bound with `$app->bindTask<T>()->queue('mail')->tries(5)`; Queue drivers (memory, carbon; Redis later), retries and backoff |
| Scheduler | `$app->bindTask<T>()->every('30s')` / `->cron('0 3 * * *')` run in-process, pushed once per slot under a key |
| Events | Typed event structs; listeners conform to `nexus::Listener<E>` and are wired with `listen<E, L>()`, keyed by type, sync (a listener queues a task for async work) |
| Doors | **Explicit door classes over shared services** (revised in M5): HTTP actions, `nexus::Cli` command classes (`$cmds->bindCommand<C>(...)->name('posts:show')`, in a provider's `commands()`), `nexus::mcp::Tool` tool classes (`$app->bindTool<T>(...)->offer('name')`); an action may also be offered as a tool, `$app->bindAction<A>(...)->route([.get], '/path')->tool('name', map: ['post' => 'id'])` |
| OAuth | `nexus-oauth` (OAuth 2.1: DCR, PKCE S256, rotating refresh), used by `nexus-mcp` |
| Codegen run | One `nexus gen` before_build hook, **one decls pass**; carbongen and restgen get a **`--decls <file>`** flag and run as processes on it. The tool is a `public: true` exe target of the core module (`cli/`), so apps find it through their normal dependency on nexus |
| URLs | Every loose scalar `handle()` param is a path param, bound by name and type; queries come in `nexus::QueryOf<T>`. **`nexus::Router`** (bound in the container, `$app->router()` while wiring) builds links by action type: `$router->url<ShowPost>(['id' => '5'])` returns a **`nexus::Url`**; names the pattern lacks become query pairs; `absoluteUrl<A>()` uses `APP_URL` (revised 2026-11-07; `nexus::Endpoint<A>` is gone) |
| Dev tool | `nexus new / make / gen / dev / routes / doctor` |
| Telemetry | **`nexus::Logger`** (built 2026-11-09): typed fields from map literals, `with` contexts, timed spans, `#[nexus::log]` typed records, pretty/logfmt/json formats, stream/file (rotating)/async/memory sinks, a compile-time level cap, a process logger; request ids, access log. Metrics with `/metrics` and a tracing interface later |
| Testing | `nexus-testing`: in-process client, fluent asserts, fakes, recorded tasks and events |
| Frontend | SPA embedding plus **OpenAPI 3.1 and a typed TS client** |
| i18n | JSON/CSV catalogs generate a typed key enum; fallback chain; plurals through calendar locales |
| Low-level gaps | Go upstream (libhttp, libcrypto, a new libsignal, container) |
| App layout | **Layer folders**: src/actions, src/inputs, src/models, src/repositories, src/transformers, src/tasks, src/listeners, src/config |
| CRUD | **Generic endpoints with an options struct and closures** (PHP style), listing conventions built in, delete included |
| Services v1 | Cache, Mail and Files, plus CORS / secure-headers / throttle middleware |
| Process | One binary: `serve` (HTTP, workers and scheduler; `--no-work`/`--no-schedule`), `work`, `migrate`, `routes`, `doctor`, user commands. Graceful drain; TLS at the proxy |
| Realtime | `nexus-realtime`: WebSocket/SSE channels with authorization, events broadcast to channels |
| Acceptance | `examples/blog` from M1, then port Recensio's HTTP layer |
| Order | Vertical slice first (M1 to M9) |

## Architecture

```
 Doors:      HTTP (nexus-http on libhttp)   CLI (core, libcommand)   MCP (nexus-mcp)   Realtime
                         │
 Kernel ── global middleware ── Router (routes from services()) ── route middleware ── XDispatch::dispatch
   │                                                     per request: child container, Payload,
   │                                                     input decode, handle(), Responder
   ├─ Extension[]  (services / boot / commands / shutdown, app last)
   ├─ container::Container (sealed + warmed; route bindings verified at boot)
   ├─ Config (generated loader)   ├─ Events   ├─ Log / Metrics
   └─ Supervisor: workers, scheduler, realtime hubs (threads, libsignal, graceful drain)
```

**Request flow:**
1. **Transport.** A single `http::Server::wrap` never calls `$next`, so nexus owns 404, 405 with `Allow`, and HEAD fallback. Streams and websockets pass through, because libhttp inspects the response after the chain.
2. **Request setup.** `nexus::Request` is built, a request id assigned, then `Container $rc = $root->child(); $rc->put<nexus::Request>(...)`.
3. **Middleware and routing.** Global middleware runs, then the router match on the routes the extensions wired, then the route's own middleware.
4. **Dispatch.** `ShowPostDispatch::dispatch(Payload&)` (found by `type_id<ShowPost>` in the generated table) decodes path params and runs the input decoders, then calls `$rc->get<ShowPost>()->handle(...)`.
5. **Response.** The `Responder` turns `result<T, Problem>` into a Response, with the format chosen from Accept: JSON or XML through rest `render<D>`, problems as RFC 9457.
6. **Teardown.** Access log, metrics, `$rc->drop()` (releases the carbon Session and the pooled connection).

## Status

**M1 done (2026-11-02).** Every suite runs through `scripts/test.sh`: core (with generator) 48, nexus-http 6, nexus-testing 3, blog 11, `nexus gen --check`, and blog smoke 19 checks over a real socket, including a clean SIGTERM stop.

Upstream items 1 to 3 are done. container has `#[atomic]` Cell/Slot/Box/Forward and a new 8-thread ThreadsTest; without the fix that test crashes. libsignal is new (5 tests). libcrypto has public `base64`/`base64url`/`unbase64`/`unbase64url` (72 tests).

Settled while building M1:
- **Renames.** `use`, `test`, `internal` and `match` are reserved. So the per-action attribute is `#[nexus::middleware]`, the test mode is `Mode::testing`, the 500 case is `Problem::server(cause)`, and `Pattern::matches`.
- **Generated output.** One file, `.nexus/nexus.eco`. Per action it holds an `XRoute` struct (`url()` and `dispatch()`); per input an `XDecoder` struct. For the module it holds `nexusgen::<module>::routes()` (tagged `#[nexus::routes]`) and `configs()` (tagged `#[nexus::configs]`). The kernel collects both with `attr::of`, so an app registers nothing and a library built on nexus contributes its routes too.
- **`handle()` parameter rules.**
  - A path name binds by name. Integer types write the constraint (`{id:integer}`, `{n:number}`).
  - `nexus::Body<T>` / `nexus::QueryOf<T>` take `#[nexus::input]` structs.
  - Other scalars (`uint32 $page = 1`, `string? $tag`) become query params and labelled `url()` arguments.
  - `nexus::Payload&` and `nexus::Request` are passed as they are.
  - Any other named type is a located gen error: the action reads it from the payload (`T::of($payload)`).
- **Return types.**
  - `result<T, Problem>` with T as Response, json::Value or string goes through `Reply::of`.
  - Any other T needs `nexus::Resource` (`json()`) and goes through `Reply::resource` / `resources`. nexus-rest replaces this in M2.
  - Plain `json::Value`, `string`, `Response`, `status<Problem>` and `void` (204) also work.
- **Extra attributes:** `#[nexus::route: {path, methods}]`, `#[nexus::name]` on input fields, `#[nexus::env]` and `#[nexus::secret]` on config fields.
- **Config.** `#[nexus::config: "blog"]` fields read `BLOG_<FIELD>` by default. The loader binds each struct with `Builder::param<T>`.
- **Kernel.** `Kernel::boot(extensions, mode, log, env)` uses the generated tables. A labelled overload takes explicit tables for tests. `Kernel::main(extensions)` is the whole `main.eco` and gives `serve`/`routes`/`doctor` with `--mode`, `--env-file`, `--listen`, `--workers`.
- **nexus-http** also brings `Cors` and `SecureHeaders` middleware.


**M2 done (2026-11-02).** `scripts/test.sh`: core (with generator) 51, nexus-http 6, nexus-testing 3, nexus-carbon 8, nexus-rest 6, nexus-crud 10, blog 14, `nexus gen --check` for modules/carbon and the blog, and the blog smoke test with 41 checks against MySQL 8.0 in Docker, also green on MariaDB 11 (`IMAGE=mariadb:11`). The smoke test runs migrate, CRUD over a real socket, a clean SIGTERM stop, and migrate:reset.

Upstream item 5 is done. carbongen and restgen take `generate|check --decls <file>`, reading a `--decls-all` pass and keeping the module that `#[module:]` names. Their own passes now add `--no-hooks`. Each library's module.eco offers its tool as a public exe target, `carbongen` and `restgen`. Suites: carbongen 86, restgen 18, rest 40, carbon 208, carbon blog 17, rest blog 13.

Settled while building M2:
- **One decls pass.** `nexus gen` runs `--decls-all` with NEXUS/CARBON/REST_NOGEN and writes the result to `$ECHO_HOOK_STATE/decls.json`. For each generated directory the manifest wires (`.carbon/` behind `!CARBON_NOGEN`, `.rest/` behind `!REST_NOGEN`), it finds the tool through `echoc -p tools`, builds it with the command echoc gives, and runs it with `--decls`. Then it writes `.nexus/` for the root module. `--check` runs every tool in check mode. The app must depend directly on carbon and rest (RestTransformers), because a tool two levels down is not offered.
- **`Extension::services(Builder&)` returns `status<BootError>`**, so opening a database can stop the boot. It runs after the config loaders, so `$b->get<DatabaseConfig>()` works. A new `Extension::commands() : array<nexus::Command>` hook adds commands to the app binary (`nexus::Command`, `CommandOption`, `Invocation`).
- **nexus-carbon** (`modules/carbon`, namespace `nexus::carbon`): `Extension(function(DatabaseConfig) : result<carbon::DB, carbon::Error>, migrations, grammar:)`. The app opens the DB and registers its repositories; the extension seals the DB, binds `carbon::DB` once and `carbon::Session` per request, and adds `migrate`, `migrate:status`, `migrate:down` and `migrate:reset` (undoing in prod wants `--force`). `DatabaseConfig` reads `DATABASE_URL`; its loader is committed in `modules/carbon/.nexus/`. `Repositories::bind<R>($b)` binds a repository per request from the session. `Problems::of(carbon::Error)` maps missing → 404; stale, refused, duplicate and reference → 409; busy, connection and deadlock → 503; anything else → 500 with the cause hidden in prod.
- **nexus-rest** (`modules/rest`, namespace `nexus::rest`): a per-request `Resources` holding the transformers, the format negotiated from Accept, and `includes(...)` / `context(...)`, checked against what an action allows; a bad include is a 400. The `Allow` overloads are labelled `allow:`, because an array literal cannot pick an overload. `nexus gen` recognises `#[rest::model]` types across the whole program: `result<R, Problem>`, `result<array<R>, Problem>` and `result<EchoPack::Rest::Document<M>, Problem>` are answered through `nexus::rest::Reply::item/items/document`, in JSON or XML. Without nexus-rest in the program this is a located error. Problems stay RFC 9457 JSON.
- **nexus-crud** is a module of its own (`modules/crud`), so nexus-rest stays database-free. One `nexus::crud::Crud<M, Q, K, Repo, Res, Map>` per resource, behind a type alias (`public type PostCrud = ...`), bound per request. Its options are fields: `includes`, `always`, `load(Q, Includes)`, `scope(Q)`, `authorize(Verb, M)`, `before(Verb, M&)`, `after(Verb, M)` and `name`. The verbs are methods each action calls: `list(c[, Listing<Q>])`, `show(c, key)`, `create(c, model)`, `update(c, key, fill)` and `delete(c, key)`. `Listing<Q>` holds the query conventions: `page`/`size` (bounded by `maxSize`), `order=-key` over `orderable(name, column)`, `ids=` through an `ids` closure, `count=1` for `total_count`/`filter_count`, and a `filter(Q, Request)` closure; bad values are 422s naming the field. The type parameters are unconstrained: a same-module alias cannot see Q's conformances yet, which echoc reports as UnsatisfiedTypeConstraint. Calls are checked when the generic is instantiated.
- **Generator:** a `nexus::Payload&` or `nexus::Request&` parameter (decls kind `ptr` + `borrow`) is handed the dispatch's own; any other reference parameter is a located error.
- **Blog** (`examples/blog`, module renamed `nexus-blog`, because carbon's example is also `blog` and both end up in one build): users and posts in MySQL, migrations including a seeded editor, `PostRepository` trims and refuses titles, `PostQuery::tagged`, `PostResource`/`UserResource` with `url` computed through `ShowPostRoute::url`, five post actions on `PostCrud` plus Health, writes behind `RequireKey`. Its `vendor/` links hydrahon, calendar, libjson, libhttp, libcrypto (the echolibs one, shared with nexus core) and libmysql's libtcp. Tests run on carbon's fake driver.
- `nexus-testing` gained `assertCount(path, n)`.

**M3 done (2026-11-02).** `scripts/test.sh`: core 51, nexus-http 8, nexus-testing 3, nexus-carbon 8, nexus-rest 6, nexus-crud 10, nexus-auth 16, nexus-auth-carbon 6, blog 19, `nexus gen --check` for http, carbon, auth, auth-carbon and the blog, and the blog smoke test with 58 checks, green on MySQL 8.0 and MariaDB 11.

Settled while building M3 (choices made with the user: `Authenticated<User>`, derived session secrets, `prefix_id_secret` tokens, carbon stores in a sub-module):
- **nexus-auth** (`modules/auth`, namespace `nexus::auth`): `Extension(prefix, stores:, compat:, clock:, cost:, guards:)`. `AuthConfig` reads `AUTH_KEY` (at least 32 characters; boot fails without it), `AUTH_TOKENS` and `AUTH_SESSIONS` (durations, default 30 days). It binds `Guards` (signed, bearer, then the app's own), `Passwords`, `Logins` once, and `Tokens` / `Sessions` per request on `TokenStore` / `SessionStore`. `stores: .memory` (the default) binds `MemoryTokens` / `MemorySessions`; `.provided` leaves them to another extension.
- **Caller as a parameter.** Guards run lazily, on the first `Identity` or `Authenticated<U>` parameter, and the result is kept in the request's container (`Resolved`), so public actions never run them. A request without a credential is anonymous until an action needs one (401); a credential that is present but does not hold is a 401 right away, never anonymous. `Authenticated<U>` is a generic `Extractor` (it compiles; `U::principal` resolves at instantiation); the app's user conforms to `Principal<U>` with a static `principal(Context&, Identity)`. `Identity` carries `via` (`guard` is a keyword), `subject`, `credential` and `scopes` (`has` / `require`, none means all). `Guards::revoke` ends the credential the request came with (logout).
- **Bearer:** `<prefix>_<12 hex id>_<64 hex secret>`; the store keeps the hex sha256 of the secret, found by id and compared in constant time; expiry from `AUTH_TOKENS` (zero means never).
- **Signed sessions:** a session's secret is `hex(HMAC(AUTH_KEY, "nexus-auth session " + id))`, sent once at open and stored nowhere, so a database dump opens nothing (rotating `AUTH_KEY` ends every session). `Authorization: Nexus-Sig id=..,ts=..,sig=..` over `METHOD\ntarget\nts\nhex(sha256(body))`, ±5 minutes (`Extension::window`); the signature is checked before the store is asked, so forged requests never reach the database. Expiry slides, written at most once a minute. `compat: true` also accepts `X-AccessToken` (base64 JSON `{token, timestamp, signature}` over `METHOD:target:ts`). A captured request can be replayed unchanged within its window; that is documented, not prevented. `Signer` signs on the client side (tests, Echo clients).
- **Passwords and logins:** `Passwords` (Argon2id via libcrypto, decoy hash made at boot, `needsRehash`, `acceptable` as a 422). `Logins::attempt(c, account)` takes the throttles before any lookup (30 per address, 10 per account, 15 minutes, 429 with `Retry-After`); `verify` gives a good login's attempt back; `unknown(plain)` burns the decoy and answers the same 401 as a wrong password.
- **nexus-auth-carbon** (`modules/auth/carbon`, namespace `nexus::auth::carbon`): `AuthToken` / `AuthSession` models (string keys) on `auth_tokens` / `auth_sessions`, one migration `20261102000000_create_auth_tables`, `Tables::wire($db)` (register + check, in the app's open function) and `Tables::migrations()`, `CarbonTokens` / `CarbonSessions` on the request's `carbon::Session`, and `auth:prune`. Boot fails with a pointer to `Tables::wire` when the repositories are missing.
- **nexus-http:** `HttpConfig` reads `HTTP_TRUSTED_PROXIES`; a request from one of them comes from the rightmost `X-Forwarded-For` address that is not a trusted proxy, so the per-address throttle sees clients, not the proxy. The header is ignored from anyone else.
- **Blog:** `RequireKey` and `BLOG_KEY` are gone. Users have a `password_hash` (in `create_users`; a separate later migration would be undone first by `migrate:reset` and break the "reset with posts left" check). `User : Principal<User>`. `POST /v1/auth/token` (bearer), `POST /v1/auth/session` (signed session), `DELETE /v1/auth` (logout), `GET /v1/me`. Writes take `Authenticated<User>`; a post's author is the caller, and update/delete set the crud's `authorize` so only the author may (403). `user:password --email --password` sets a password and ends the user's tokens and sessions. The tests run on memory stores; the smoke test runs on the carbon stores, signs requests with openssl, and shows a signed session outliving a server restart.

**M4 done (2026-11-02).** `scripts/test.sh`: core 59, nexus-http 8, nexus-testing 3, nexus-carbon 8, nexus-rest 6, nexus-crud 10, nexus-auth 16, nexus-auth-carbon 6, nexus-work 17, nexus-work-carbon 8, blog 23, `nexus gen --check` for http, carbon, auth, auth-carbon, work, work-carbon and the blog, and the blog smoke test with 73 checks, green on MySQL 8.0 and MariaDB 11.

Settled while building M4 (choices made with the user: a task struct is its payload, an own `Failure` enum, a scheduled task is an ordinary task, sync listeners):
- **Tasks.** `#[nexus::task]` (optionally `{ queue: "mail", tries: 5 }`) on a struct whose public fields are the payload (integers, float64, bool, string, arrays of string or int64, and their nullables) and whose `handle(nexus::Context&) : status<nexus::work::Failure>` is the work; services come from the task run's own child container. `nexus gen` writes a `<Task>Task` companion: `push(c, task)`, `push(c, task, after: duration)`, `kind()`, `encode`, `decode`, `run`, plus a `#[nexus::tasks]` table nexus-work collects with `attr::of`. A payload that does not decode gives up.
- **Failure** is `retry(why)` (backoff 10s, ×4 each try, at most 1h), `later(after, why)` or `giveUp(why)`; `Failure::of(Problem)` maps 5xx to retry, 429 to later, the rest to giveUp. When the tries run out the task is kept as failed; `work:failed` lists, `work:retry --id <id|all>` sends back with fresh tries.
- **Queue** (`nexus::work::Queue`): `push` (false for a key already stored), `claim(queues, now, until)`, `done`, `retry`, `fail`, `failed`, `again`, `prune`, `waiting`. A claim raises the attempt count and holds the task until the lease (`WORK_LEASE`, 5 min); every later change names the attempt it claimed, so a worker whose lease ran out changes nothing. A task whose process died runs again after its lease (at least once); one claimed `tries` times without finishing gives up. `MemoryQueue` in nexus-work; nexus-work-carbon keeps `nexus_tasks` (one migration `20261102000500_create_nexus_tasks`, `Tables::wire`/`migrations`) and claims with `UPDATE … WHERE id = ? AND attempts = ?`. A push during a request goes through the request's carbon session.
- **Scheduler.** `#[nexus::every: "15m"]` (slots counted from the epoch, so processes agree) or `#[nexus::cron: "0 3 * * *"]` (five fields, ranges, steps, lists, day-or-weekday rule, in `Extension(zone:)`, UTC by default) on a task whose fields all default. Each due slot is pushed under the key `name@slot`; the queue keeps a key once and keeps done keyed runs for `WORK_KEEP` (24h), pruned hourly, so any number of processes may schedule. Missed slots are not caught up, except one within a minute of a restart. `work:schedule` lists the next run.
- **Events** (core, `nexus::Events`): an event is any struct; `#[nexus::on]` on a struct with a static `handle(nexus::Context&, const E&) : status<nexus::Problem>`; the kernel collects every module's `#[nexus::listeners]` table, keyed by `type_id<E>`, so an app can listen to a library's events. `Events::emit($c, e)` runs them in order and returns the first problem. Queued listeners were left out: a listener pushes a task.
- **Process.** Core `Extension` gained `start(Kernel, const Serve&)` and `drain(Kernel)`; `serve` starts the extensions, serves, stops the transport (its requests finish), drains in reverse, shuts down. `Serve` carries `work`/`schedule` (`--no-work`, `--no-schedule`). nexus-work starts `WORK_WORKERS` (2) threads polling every `WORK_POLL` (1s) on `WORK_QUEUES` (default: every queue a task names) and the scheduler thread; drain stops the scheduler and gives running tasks `WORK_GRACE` (30s). `work` runs the same without HTTP (`Console::background`). `Kernel::background(what, id)` makes a context outside a request (task, scheduled push, command); `Kernel::finish(c)` drops it.
- **Kernel boot** takes `tables: Tables` (routes, configs, listeners; `Tables::generated()`), instead of the `routes:`/`configs:` pair.
- **container's new `construct` parameters** (echoc 0.12.3: `bind<T>(put: construct T)`, `param`, `put`) refuse an interface or enum `T`. nexus binds the concrete class and aliases the interface (`bind<MemoryQueue>(put: MemoryQueue()); alias<Queue, MemoryQueue>()`, the same for auth's memory stores), and the unused `param<Mode>` binding is gone.
- **Blog:** `POST /v1/users` (sign up, 409 for a taken email) emits `UserRegistered`; `WelcomeNewUser` pushes `SendWelcome` (queue `mail`, 5 tries), which notes `users.welcomed_at` (shown on `/v1/me`; no mail until M7). `PruneAuth` runs at 03:00 UTC. The smoke test shows serve's own workers welcoming a sign-up, a task queued under `serve --no-work` outliving `kill -9` and done by `blog work`, and both processes draining on SIGTERM.

**M5 done (2026-11-02).** `scripts/test.sh`: core 64, nexus-http 8, nexus-testing 3, nexus-carbon 8, nexus-rest 6, nexus-crud 10, nexus-auth 16, nexus-auth-carbon 6, nexus-work 17, nexus-work-carbon 8, nexus-mcp 8, nexus-oauth 9, nexus-oauth-carbon 5, blog 27, `nexus gen --check` for every module with generated code and the blog, and the blog smoke test with 107 checks, green on MySQL 8.0 and MariaDB 11.

Settled while building M5 (choices made with the user: the business logic lives in services and each door is its own declared class; commands and tools take one `#[nexus::input]` struct; an action may be offered as a tool with metadata and an argument map; commands print through libcommand; OAuth consent is the app's page plus a JSON API; OAuth tokens open MCP only; OAuth state in a store with a carbon sub-module):
- **Doors.** Core `nexus::Door` (`http`, `cli`, `mcp`, `work`) on every `Context`; guards read it. `Kernel::background` contexts are `.work`, commands `.cli`, the MCP endpoint `.mcp`.
- **Commands.** `#[nexus::cli: "posts:show"]` on a class conforming to `nexus::Cli`, `handle(nexus::Context&, command::CLIContext&, Input) : status<nexus::Problem>` (the input is optional). The class docblock is the help (first paragraph the summary), the input's fields the options: `--kebab-name` values, bool flags (default false), arrays repeated (`--tags a --tags b`), `#[nexus::positional]` words in field order (required first); field docblocks are the option help, and the input's rules run before the command. `nexus gen` writes a `<Command>Cli : nexus::Command` and a `#[nexus::commands]` table the console collects with `attr::of` next to the extensions' commands. A problem prints `error: <title>: <detail>` (one line per field for a 422) and exits 1. `nexus::Command` gained `help()` and `bound(container)`; `CommandOption` gained `list:` and `positional:`; `Invocation` carries `positionals`, `lists`, `stated()` and `out` (libcommand's `CLIContext`, a plain buffer in tests). `doctor` reports unbound commands.
- **Tools.** `#[nexus::mcp::tool: { name, title, description, readOnly, destructive, idempotent, openWorld }]` on a class conforming to `nexus::mcp::Tool` whose `handle()` takes `nexus::Context&`, extractors and at most one input struct; or on an action, with `map: { post: "id" }` renaming path or query parameters (body fields keep their names; a clash is refused). `nexus gen` writes the JSON Schema from the types, rules (`min`/`max` as length, items or bounds, `email` as format, `oneOf` as enum, `notBlank` as minLength 1) and field docblocks, the description from the class docblock, `<Tool>Mcp::spec()`/`call()` or `<Action>Route::tool()`/`call()`, and a `#[nexus::mcp::tools]` table. A tool call runs the generated `call(Context&, Fields&)` on the MCP request's context: extractors and rules run, routing and route middleware do not.
- **nexus-mcp.** `POST /mcp`, the stateless Streamable HTTP form: one JSON-RPC message per request (`initialize`, `ping`, `tools/list`, `tools/call`; a notification is a 202; GET and DELETE are 405), revisions 2025-11-25, 2025-06-18, 2025-03-26. Every message needs an identity from nexus-auth's guards; without one a 401 with `WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp"`. Unknown arguments and decoder refusals are tool errors (`isError`) the model reads; a JSON object answer is also `structuredContent`. `MCP_NAME`, `MCP_TITLE`, `MCP_VERSION`, `MCP_INSTRUCTIONS`, `MCP_ORIGIN`.
- **nexus-oauth.** Metadata (RFC 9728, RFC 8414), dynamic registration of public clients (RFC 7591: https, loopback http on any port, or an app scheme; 10 per address in 15 min; at most `OAUTH_CLIENTS`; unused clients swept after an hour), `/oauth/authorize` (a doubtful client or redirect is a 400, anything else goes back as an OAuth error; otherwise a 302 to `OAUTH_CONSENT` with the same query), `GET /oauth/request` and `POST /oauth/approve` for the app's consent page (signed in), `/oauth/token` (code with PKCE S256, single use, 60 s; refresh), `/oauth/revoke`, `GET /oauth/grants` and `DELETE /oauth/grants/{id}` for an account page, `oauth:prune`. A grant holds one access token (`nxo_<grant>_<secret>`, `OAUTH_ACCESS` 1h) and one refresh token (`nxr_…`, `OAUTH_REFRESH` 30 days from last use), both as hashes; a refresh replaces both with a conditional update on the hash it read, and the spent one coming back ends the grant. `OAuthGuard` (added to nexus-auth's `Guards`, so list nexus-oauth after nexus-auth) accepts `nxo_` tokens on the MCP door only. `OAUTH_ISSUER` (default: the request's origin from `Host` and `X-Forwarded-Proto`, core `Request::origin()`).
- **nexus-oauth-carbon.** `oauth_clients`, `oauth_codes`, `oauth_grants` (migration `20261102000600_create_oauth_tables`); a code is taken by the delete that removes it.
- **nexus-auth:** `BearerGuard` leaves a token of another prefix to the guards after it; `Guards::add`. **nexus-crud:** `Crud::answer(m)` for actions that write through a service.
- **A module's actions belong to every app that depends on it:** the kernel collects every module's routes, so an app that depends on nexus-mcp or nexus-oauth lists their extensions, or boot names the unbound route.
- **Blog:** a `PostService` (find, author, create with cleaned tags, update by the author only) behind `CreatePost`, `UpdatePost`, `posts:show <id>`, `posts:create --author --title --body --tags`, the `create_post` tool and `ShowPost` offered as `show_post` (`post` → `id`). The smoke test runs the commands against the live database and a whole OAuth client: discovery through the 401, registration, authorize, the editor's approval, PKCE (computed with openssl), MCP calls, the access token refused on `/v1/me`, refresh rotation and reuse ending the grant.

**After M5: answers from transformers (2026-11-02).** The user found the resource layer too abstract (restgen resource structs, generated `XResourceMapping`s, the `rest::Transformers` registry, `nexus::rest::Resources`, and `nexus gen` picking `nexus::rest::Reply::item/items/document` from the return type). Now:
- **nexus-rest** is `Transformer<M>` + `Out` + `Meta` + `TransformerContext` + `TransformerNetwork`, named after PHP Nexus. Transformers are registered by model, one line each in any order (`nexus::rest::Transformers::add<User, UserTransformer>($b)`, which also binds the class); one nests another without holding it via `$ctx->transformInto<User>($o, 'author', $u)` (the network rides on the `Out`), so cycles bind fine and the depth limit ends them. `transformReferenceInto<M>(o, key, m, meta)` wraps a nested model as `{meta…, data: …}` (PHP `transformReference`), and `createResponse(c, m, meta, ctx)` puts meta next to an item's `data`. A transformer implements `name()` (the XML entity), `transform(const M&, Out&, const TransformerContext&)` and optionally `availableIncludes()`/`defaultIncludes()`; its defaults give `requestedIncludes(c)` (the request's `?include=`, a 400 for one it does not name), `createResponse(c, m[, ctx])`/`createCollectionResponse(c, ms[, meta[, ctx]])` (a `nexus::Response` in the negotiated format, the model under `data`, meta keys first; overloads taking already checked includes) and `transformInto`/`transformCollectionInto(o, ctx, key, …)` to nest another transformer's model (depth limit 8). `TransformerContext` holds one value per type (`set<UserContext>($user: $u)`, `get/find/has<T>()`), set explicitly by the action (Crud: its `context` field); the blog's `UserTransformer` shows the email only to that user. `Out` drives RestTransformers' JSON and XML drivers with the same event order the generated encoders used, so the wire format is unchanged (blog responses diffed byte for byte before and after). `Resources`, `Reply` and the rest `Extension` are gone. The RestTransformers library itself is untouched.
- **nexus-crud** is `Crud<M, Q, K, Repo, T>` with `T` the transformer (which owns the allowed includes): `find(c, key)` and `page(c, listing)` (a `Page<M>` with `meta()`) hand back models; `show`, `list`, `create`, `update` answer with a `Response`; `answer()` is gone. Writes check `?include=` before writing.
- **nexus gen** no longer knows rest resources (`restReply`, `#[rest::model]` scanning gone); it reads `#[nexus::answers: { item|list: "x::T" }]` on actions and tool classes and refuses a name that is not a class conforming to `nexus::rest::Transformer`. Nothing is emitted from it yet; M6 reads it. restgen support stays for apps that wire `.rest/`.
- **Blog:** `src/resources/` and `.rest/` gone; `PostTransformer` (nests `UserTransformer` as `author`) and `UserTransformer` are bound `once:`; actions take the transformer they answer with. nexus-testing gained `assertBody`.
- **No `#[nexus::status]`:** the response carries its status. `createResponse($c, $m, status: 201)`, `nexus::Response(json: $doc, status: 201)`; `Crud::create` answers 201 itself; Login and OpenSession build their 201 responses from `Issued`/`Opened`. A leftover `#[nexus::status]` is a located `nexus gen` error.
- Suites: core 65, nexus-rest 5, nexus-crud 12, blog 27, the rest unchanged; smoke 107 on MySQL 8.0 and MariaDB 11.

**After M5: input validation, Laravel-like (2026-11-02).** Choices made with the user: rules stay a typed record on the field (not pipe strings, not a `rules()` method); service-backed and cross-field rules are classes; messages in English with overrides and other languages through catalogs; nesting where each nested type brings its own rules.
- **Rules** (`#[nexus::rule]`, validated by `cli/src/Rules.eco` per field kind, misfits reported at the field's line, every bad field in one run): normalisers `trim lower upper squish nullIfBlank`; strings `min max between size notBlank email url uuid alpha alphaNum alphaDash ascii digits startsWith endsWith oneOf noneOf`; numbers `min max between multipleOf oneOf noneOf gt gte lt lte` (a number or a sibling field); booleans `accepted declined`; `calendar::Date` / `time::timestamp` fields with `after before afterOrEqual beforeOrEqual` (`'today'`, `'now'`, a literal, a sibling); lists `min max between size distinct each: {...}`; cross-field `confirmed same different requiredWith requiredWithout` (sibling existence and type checked); `check: 'x::R'` names `nexus::Rule<T>` classes, `T` checked against the field type, or the struct for `#[nexus::rule: { check: ... }]` on the input. `in`/`use` are Echo keywords, hence `oneOf`.
- **Types:** backed enums (string or integer) decode by an emitted case chain, a bad value is `oneOf` with the allowed values; nested inputs and `array<Input>` decode through the nested type's generated `read()`; forms use bracket keys (`posts[1][title]`, `tags[]`). Nesting is refused in command inputs.
- **Runtime:** `nexus::Check` (class; `at`/`item` point at a field, one method per rule, `fail(code, message, params:)` and `fail(field: ...)` for rule classes; nested checks share one `Refusals`), `nexus::Fields` readers report through it (new `date`, `timestamp`, `object`, `objects`). `FieldError` gained `params`, `input`, `name`, `kind`, `label`, `template`; messages read "The {label} field must ...". Decoders are `decode(Context&, Fields&) : result<T, Problem>` plus `read(Context&, Fields&) : T?`; commands now build their context before decoding.
- **Order:** read, normalise, every built-in rule; the field's rule classes only when the field passed; cross-field rules once all fields are read; the input's rule classes only when every field passed.
- **Messages:** `nexus::Messages` (`#[atomic]`, bound by the kernel) holds per-locale catalogs (JSON, nested keys joined with dots): `{input}.{field}.{code}`, `rule.{code}.{kind}`, `rule.{code}`, labels `label.{input}.{field}` / `label.{field}`; chain `de-CH` → `de` → `en`, else the English message. `pick(Accept-Language)` with q-values; `LANG` for commands and tasks. `Context::fail` translates 422s and sets `Content-Language`; `Context::localized(p)` for commands. A generated `#[nexus::inputs]` table (`InputTable`, `Inputs`) registers `#[nexus::message]` overrides as English entries and the rule classes, which boot refuses unless bound.
- **Blog:** `Registration` normalises (squish, trim, lower) and confirms the password; `UniqueEmail` (src/rules) answers a taken address with a 422 `unique` before writing, the 409 stays for races; `NewPost` tags `{ max: 5, distinct, each: { trim, lower, notBlank, max: 30 } }`; `POST /v1/posts/batch` (`PublishPosts`, `PostBatch` of `NewPost`s, all or none in one transaction); `lang/de.json` embedded and added in `App::boot`. nexus-testing gained `assertBody`.
- Suites: core 77, blog 31, the rest unchanged; smoke 110 on MySQL 8.0 and MariaDB 11.

**2026-11-03: registration by builder, not attributes (uncommitted).** The user disliked attribute-based registration. Every door is now wired where the app is: core `nexus::Services` (what `Extension::services` gets: the container passthroughs, `bindAction<A>(method:, path:, [factory])` returning `ActionRef<A>` with `->middleware<M>()`, `route<A>()` for a second method or path, hand-built `route(Route)`, `endpoint<A>()`, `listen<E, L>()`, `on<E>()`, `fail()`), `Extension::commands(nexus::Commands&)` (`add(Command)`, `add<C>(name, factory)`, read before boot), and the new **nexus-app** module whose `nexus::app::Builder` adds `bindTransformer`, `bindRepository`, `bindTool<T>(name:, factory, title:, ...)`, `bindTask<T>(queue:, tries:, every:, cron:)` and `->tool(name:, ..., map:)` on actions. `nexus gen` dropped `#[nexus::get/post/.../route/middleware/mcp::tool/cli/on/job/every/cron]` and writes per module one `#[nexus::generated]` table (`Generated`: dispatcher + path params per action, command makers, names of every type conforming to a nexus interface), `#[nexus::mcp::tools]` offers and `#[nexus::tasks]` codecs, all keyed by `type_id`. Boot checks each route against its dispatcher: a loose scalar `handle()` param must be a `{name}` of the path (`{name?}` only when it is nullable or defaulted), integer constraints are filled in, a missing dispatcher names the action. Links: `nexus::Endpoint<A>` replaces `XRoute::url()`. `doctor` warns about actions no route reaches. A library's actions only answer when its extension routes them. echoc 0.12.3 traps hit: `str::join([...], "\n")` or a temporary into a memberwise constructor in generated nexus-mcp code ("no storage to take the address of"), a defaulted `map<string, string>` param written `= map<string, string>()` makes calls ambiguous (write `= []`), a closure literal cannot follow skipped labelled defaults, generic overloads must differ beyond the type parameter. Suites: core 82, http 8, testing 3, carbon 8, rest 12, crud 13, auth 16, auth-carbon 6, work 17, work-carbon 8, mcp 8, oauth 9, oauth-carbon 5, app 5, blog 31, smoke 112 on mysql:8.0; `routes`, `doctor`, `work:schedule` and `--help` print the same lines as before.

**2026-11-04: `nexus::App`, providers and a boot check (uncommitted).** The user wanted `$app`, not `$b`/Builder, and a clean wiring that reads well, scales and catches most errors before runtime or at boot. They rejected autowiring through `nexus gen` (generated per-type hooks) as too magic. `.make<X>()` recipes are not possible on echoc 0.12.4 (a leading dot onto a generic `Dep<A>` parameter has no owner; `array<Dep>` cannot build `T` without generated code). From four directions (types wiring themselves, a typed app graph, both, Laravel providers) they picked the **Laravel providers**. nexus-app's `nexus::App` (namespace `nexus`): `register(Provider)`, `bind<T>(loader)` per request, `bind<T>(shared: loader)` once, `instance<T>(value)`, `param<T>`, `alias<I, C>`, `replace<T>(loader)` / `(shared:)`, route verbs `get/post/put/patch/delete<A>(path, loader)` (without a loader: route an action that is bound already), `endpoint<A>`, `listen<E, L>`, `transformer<M, T>`, `repository<R>`, `tool<T>(name, loader, title: ...)`, `task<T>(...)`; `->tool(name, ...)` on a route. `nexus::Provider` = `register(nexus::App $app) : void`. Loaders are short callbacks, `(Container $c) => PostService($c->get<PostRepository>(), ...)`. `put:` and the Endpoint loader variant are gone from App because of two echoc 0.12.4 gaps: a labelled `put: construct T` overload swallows an unlabelled callback when `T`'s constructor takes that many arguments, and an untyped short callback cannot pick between overloads that differ only in the callback's parameters. **Boot check:** the container (echolibs/container) has type names (`Builder::name<T>` / `name(type_id, ...)`), a resolve stack of frames (id + life) and `Container::probe()`. A missing binding, a cycle or a `once` binding that takes a `scope` one now dies with its chain (`container: blog::Login: nothing binds blog::SignIn`, `container: Mailer → PostRepository: Mailer is a once binding, so it would keep the scope binding PostRepository`). The kernel names the core types and every generated name, and probes every binding in a `background('boot', 'probe')` context on every boot (carbon sessions connect lazily). `nexus gen` now names every non-generic, non-private class, struct and type alias of a module. Blog: `src/providers/AuthProvider.eco` and `PostsProvider.eco`; App.eco registers them plus Health, the listener and the tasks. Suites: container 84, core 82, app 8, blog 31, the rest unchanged, smoke 112 on mysql:8.0.

**2026-11-04, later: loaders on echoc 0.12.5 (uncommitted).** echoc 0.12.5 fixed both gaps (a labelled `construct` overload no longer takes unlabelled arguments; an untyped short callback picks its overload by parameter list). `nexus::App` now takes loaders of three shapes: `bind`/`bind(shared:)`/`replace` accept `(Container $c) => …` and `() => …`, and every verb accepts those plus `(Container $c, nexus::Endpoint<A> $at) => …` for an action that links to itself. Blog: `$app->delete<Logout>('/v1/auth', () => Logout())`. **nexus now needs echoc 0.12.5**; 0.12.4 refuses these calls. Suites unchanged and green on 0.12.5 (core 82, app 8, blog 31, smoke 112).

**2026-11-04, lifetimes are labels.** The user wanted the lifetime explicit on every bind: `bind<T>(scoped: …)` once per request, `bind<T>(shared: …)` once for the app, `bind<T>(factory: …)` fresh on every get; `replace` takes the same labels; no unlabelled `bind`. Each label takes a `(Container $c) =>` or a `() =>` loader. Actions (verbs) and tools stay per request without a label.

**2026-11-04, actions bind then route.** The user disliked `$app->post<Login>('/v1/auth/token', …)`. Now `$app->bindAction<A>(loader)` (per request; loader `(Container $c) =>`, `() =>` or `(Container $c, nexus::Endpoint<A> $at) =>`) returns `nexus::app::ActionRef<A>` with `->route(array<nexus::Method>, path)` (callable again for another path), `->middleware<M>()` (wraps every route of the ref, before or after), `->tool(name, …)` and `->endpoint()`. `$app->action<A>()` routes an action bound elsewhere. The route verbs are gone. A route with no methods fails the boot.

**2026-11-04, every registration binds then chains.** Like actions: `bindTool<T>(loader)->offer('name', title: …)`, `bindTask<T>()->queue('mail')->tries(5)` / `->every('15m')` / `->cron('0 3 * * *')` (each call re-binds through `nexus::work::Tasks::bind` with what is set so far), `bindListener<L>()->on<E>()` (callable for several events), `bindTransformer<M, T>()`, `bindRepository<R>()`. Commands: core `nexus::Commands::bindCommand<C>(loader)->name('posts:show')` (replaces `add<C>(name, …)`; `add(Command)` stays). Because the command line reads commands before the boot (boot opens the database), `nexus::Provider` has an optional `commands(nexus::Commands&)` next to `register(App)`; the extension lists its providers once (`providers()`) and hands them to `nexus::App($s, $this->providers())` and `nexus::App::commands($cmds, $this->providers())`.

**2026-11-04, jobs are tasks.** The user renamed the domain: `nexus::work::Task` (was `Job`), `Tasks::bind/push`, `StoredTask`, `TaskTable` + `#[nexus::tasks]`, `Extension(tasks:)`, generated `<X>Task` companions, `$app->bindTask<T>()` / `TaskRef<T>`, nexus-work-carbon's `QueuedTask` in `nexus_tasks` (migration `20261102000500_create_nexus_tasks`), the blog's `src/tasks/`. The module stays nexus-work with its `work*` commands and `WORK_*` settings. No compatibility shims: the framework has no users yet, so gen no longer reports removed attributes either (`Program::gone` deleted).

**2026-11-05: `Payload`, and preconditions on types (uncommitted).** The user renamed `nexus::Context` to **`nexus::Payload`** (the PHP Nexus name), passed as `$payload` everywhere (generated code too), which frees `$c` for the `Container` in loaders. They found `nexus::auth::Authenticated<User> $me` as a `handle()` parameter wrong: who signed a request is state of the payload (its container already kept `Resolved`), not an input. After rejecting a facade (`Auth::user<User>($payload)`) as un-Echo, they picked **types answer for themselves**: nexus-auth keeps `Identity::of($payload)` (401 for nobody) and `Identity::find($payload)` (null for nobody, still a 401 for a credential that does not hold). `Authenticated<U>`, `Principal<U>` and the generic **`nexus::Extractor` mechanism are gone**. `nexus gen` refuses any other named `handle()` parameter with `read it from the payload in the body, as T::of($payload)`, and a tool's `handle()` is `(nexus::Payload&, Input)`. A precondition that needs a repository reaches it through the payload's container; anything needing more logic sits in a service the action gets through its constructor. Name clash: `nexus::work::Payload` became `nexus::work::TaskData`, `StoredTask`/`QueuedTask` `$payload` became `$data` (column `data` in `nexus_tasks`), and the generated `run(nexus::Payload&, const string& $data)`. Blog: `Role` (uint8 backed, carbon maps integer enums only; `tinyint role` in `create_users`, the seeded editor is admin), `User::of`/`User::admin`, `Post::changeableBy` (author or admin) and `Post::authorizeFor` (the crud closure, replacing `Authorship`), admin-only `GET /v1/users` (`ListUsers`). **Order change:** with auth inside `handle()`, the generated input decoding runs first, so an anonymous request with a bad body is a 422, not a 401, and rule classes run before the caller is known. echoc 0.12.5: a field default `= Role::author` is refused as an unknown constant; `= .author` works. Suites: core 81, auth 17, blog 33, the rest unchanged.

**2026-11-05, later: middleware resolves, actions read state (uncommitted).** `User::of($payload)` resolving the caller lazily hid its dependencies (the repository came from the container by type) and ran auth after decoding. The user wanted it middleware-shaped: a middleware with its dependencies in its constructor resolves and `put`s state, the action only reads. They chose **`#[nexus::through: [...]]` on the action** (over stacking `->middleware<M>()` in the wiring, a typed `Needs` value read by one middleware, or a gate service in the constructor), **app-wide middleware as well** (`$app->middleware<M>()` / `Services::middleware<M>()`, built from the request's container so it may take scoped services; it runs after the extensions' atomic middleware, before routing), and **`$payload->state<T>()`** as the reader (a logged 500 naming the action when no middleware put `T`). The list attribute may span lines. `nexus gen` indexes every `nexus::Middleware` class of the program, refuses unknown, non-middleware, duplicate and empty names, and writes `$g->through<A>([nexus::MiddlewareRef::of<M>('M'), ...])` plus `Offer.through` for tools; `MiddlewareRef` carries a `bound` check, and the boot refuses an unbound one (`X goes through M, which is not bound`). Order around an action: extensions', app's, routing, the route's `->middleware<M>()`, the action's `through`, decoding, `handle()`; MCP tool calls run their `through` inside `/mcp` (`Endpoint` takes `Guards` by constructor and identifies first, with the door set). nexus-auth: `Guards::identify`/`revoke` are instance methods (still cached in `Resolved`), new `Authenticate` middleware (401 or `put<Identity>`), `Identity::of`/`find` removed. oauth's consent actions go through `nexus::auth::Authenticate`. Blog: `RequireUser(Guards, UserRepository)` puts `Caller { identity, user }`, `RequireAdmin` (after it) is a 403, `User::of`/`admin` removed, `Logout` takes `Guards`, and `ServerTiming` shows the app-wide kind. Auth runs before decoding again: an anonymous bad body is a 401. Suites: core 89, auth 18, mcp 9, app 12, blog 34, the rest unchanged.

**2026-11-05, generated mappings (uncommitted).** The hand-written transformers copied every field one line at a time. The user wanted generated mappers with room for custom logic, fields declared on the model, several shapes per model, and no way for a small slip to leak a field. Built:
- **nexus-rest.** `Transformer<M>` no longer requires `name()`/`transform(M, Out&, ctx)` or defaults the includes. Its default bodies call `name()`, `map()`, `availableIncludes()` and `defaultIncludes()`, which the generated mapping (or a hand-written class) supplies. A no-op `transform(const M&, Item&, ctx)` hook and `extraIncludes()` are its defaults. A spike on echoc 0.12.5 confirmed that one interface's default may call another interface's default, also through a stored `Transformer<M>`.
- **`nexus::rest::Item`.** It holds the keys of one model before they are written: the same writers as `Out`, `include`/`includeCollection`/`includeReference` (only when wanted), `remove`/`has`/`keys`/`wants`, `protect`/`reveal` for sensitive keys (writing one unrevealed dies), and `flush` (attributes, values, then includes, so the post's `url` still comes before `author`). `Out::wantedHere()` feeds `wants`.
- **nexus gen.** `Exposures` reads `#[nexus::shapes]`, `#[nexus::expose]` and `#[nexus::sensitive]`, with located refusals for: an unknown shape, a type no writer handles, a duplicate key, a bare `expose` on a sensitive field, a sensitive field in a non-sensitive shape, `default` redeclared, a misplaced `attribute`/`item`/`stamp`/`include`, and an unknown option. `Mappings` writes `<Model><Shape>Mapping`. The writers cover integers (cast), floats, bool, string, timestamp, string/int64 lists, `json::Value`, backed enums (as their wire value), nullables (as null), `carbon::One` (include) and `carbon::Many` (include list). `Names::snake` gives the wire keys.
- **Blog.** `Post`/`User` expose their fields. `User` has the sensitive `admin` shape (email, role); `passwordHash` is sensitive and unexposed. `PostTransformer` and `UserTransformer` are hooks only (url; own email via `reveal`), and the new `UserAdminTransformer` (`UserAdminMapping`, bound outside the network) answers `ListUsers`.
- **Open for M6:** the decls pass drops the conformance to a not-yet-generated mapping, so OpenAPI cannot read a transformer's shape from its class. `#[nexus::answers]` will need to name the shape, or a second pass is needed.
- **Trap (echoc 0.12.5):** a closure capturing a `const string&` parameter keeps a dangling reference; copy it into a local before capturing.
- **Suites:** core 93, rest 17, crud 13, blog 34.

**2026-11-07: the router builds links, `nexus::Url` (uncommitted).** `nexus::Endpoint<A>` (one container binding per routed action) is gone, along with the `(Container, Endpoint<A>)` loader overloads and `endpoint<A>()` on `Services`, `App` and both `ActionRef`s. Instead:

- **`nexus::Url`** (`src/http/Url.eco`): scheme, host, port, escaped path, `Query`, decoded fragment. `Url::parse` takes an absolute URL or a `/path` and refuses `//host`, user info, bad ports and broken escapes (`UrlError`). `with`/`without`/`at` return copies; `on($base)` moves a URL onto an origin under its path (`/v1/posts/5` on `https://x.ch/api`); `text()` and `"{$url}"` print it. `Request::url()` is the asked URL on `origin()`; `Response(redirect: Url)` sits next to the string one; `Query::remove`.
- **`nexus::Router`** does both directions. `Route` carries the action's `type_id`; the first route an action gets is where its links go. `url<A>(params)` fills the pattern (checking constraints), turns unknown names into query pairs in name order and dies on a missing required param or an unrouted action. `absoluteUrl<A>()` uses the origin from `APP_URL` (a bad or relative value fails the boot as a config error); `routed<A>()`.
- **Lifetime:** `Services` creates the router and binds it (`put:`) before any extension wires, so an eagerly built transformer takes `$app->router()`; the kernel fills that same router before sealing the container. Loaders take `$c->get<nexus::Router>()`.
- **Suites:** core 105, app 12, rest 17, blog 34 (blog's `vendor/` was missing the `libmysql` link its `module.eco` now requires; added).

**2026-11-09: oauth on `Url`, link deaths tested (uncommitted).** `Authorize` builds the consent redirect as a `nexus::Url` (a relative `OAUTH_CONSENT` on the issuer, its own query kept, the request's pairs appended). Redirects back to a client stay the registered text (an app's own scheme is no `Url`) with a `nexus::Query` appended: `RedirectUri::with(Query)`, `Asked::back(name, value, issuer)`. `OAUTH_CONSENT` that is no URL and `OAUTH_ISSUER` that is no absolute URL fail the boot. Router deaths (missing param, refused constraint, unrouted action, no origin, relative origin) are `#[tests: expects death]` tests; echoc cannot match the message yet. Suites: core 110, oauth 11.

**2026-11-09: logging, `nexus::Logger` (uncommitted).** `nexus::Log` became `nexus::Logger` (the user's name), everything else lives in `nexus::log` (`src/log/`, one type per file), no shims. Choices made with the user: map literals plus typed records, spans as a struct whose destructor closes them, the logger in the container plus a process logger, and in v1 async, file + rotation and a compile-time cap (no per-target filter directives).
- **Fields.** `log::Fields` fills from a map literal through `[k] =` operators into a small copyable `log::Value` (str, int, uint, float, bool, duration, time, raw JSON); a null `string?`/`int64?` leaves its key out, a repeated key replaces. `log::Context` is an immutable `#[atomic]` node chain (`with` adds one, `span` adds one that opens a span), so children and entries share fields instead of cloning them.
- **Logger.** `trace/debug/info/warn/error(message, Fields = [])`, `write`, `enabled`, `with`, `span(name, Fields = [], $close: .info)`, `emit<R>(construct R)`, `flush`, `silent()`, `process()`/`install()`. `--define NEXUS_LOG_MAX_DEBUG|INFO|WARN|ERROR` compiles the lower level methods to nothing (`Level::cap()`); arguments are still built, so `enabled` guards expensive ones.
- **Spans.** `log::Span` holds the inner logger (`$s->log`), a random 16 hex id, the parent's id; its destructor writes `<name> closed` with `ms`. Formats show `span`, `span_id`, `parent_id`; pretty prints `import{file=a.csv}: rows read n=5`.
- **Typed records.** `#[nexus::log: { level: "warn", message: "..." }]` on a struct: `nexus gen` writes `nexus::log::record(const R&) : log::Record` in a `namespace nexus::log;` section of `.nexus/nexus.eco` (an `extension` block cannot add methods, so the hook is an overload, like `str::from`); keys snake_case or `#[nexus::name]`, `#[nexus::sensitive]` logs `[redacted]`, nullables unwrap. Located errors for a bad level, no message, an unloggable field, a non-struct. Blog: `PostPublished`, a `batch` span in `PostService::createAll`.
- **Sinks.** `log::Stream(.stdout|.stderr, Format)` (pretty coloured on a terminal), `log::Memory` (`saw(level, msg)`, `find`, `clear`), `log::File::open(path, Format, Rotate, keep)` (`.never`, `.daily` by UTC day, `.size(bytes)`; `app.log` → `app.1.log` …, flushed per line, `result<File, FileError>`), `log::Async(sink, capacity, overflow)` (bounded channel + writer thread; `.block` waits, `.drop` counts and later logs `log dropped entries`; the handle is kept because dropping a `thread::handle` joins).
- **Kernel.** The root logger is bound in the container; each request's and background payload's stamped logger is `put` in its child container, so scoped services get it. `Kernel::shutdown` flushes. `Console::logFor` reads `NEXUS_LOG`, `NEXUS_LOG_FORMAT`, `NEXUS_LOG_FILE`, `NEXUS_LOG_ROTATE`, `NEXUS_LOG_KEEP`, `NEXUS_LOG_ASYNC`, `NEXUS_LOG_OVERFLOW` (a bad value stops the start with `log::ConfigError::message()`) and installs the process logger. nexus-work runs each task inside a `task` span; nexus-testing's `TestApp` gained `logged(level, msg)`, `assertLogged`, `assertNotLogged`.
- Suites: core 131 (LogTest 21 + RecordTest 4), every module unchanged and green, blog 34, `nexus gen --check` current everywhere, smoke 120 (`posts:create` now logs `post published` on stderr; the check reads stdout). `echoc test --define NEXUS_LOG_MAX_INFO --filter the_cap_compiles_the_levels_below_it_away` checks the cap.
- echoc 0.14.0 facts: `extension` holds conversions only; `try` only starts a new declaration; quoted strings process escapes (a literal backslash is `\\`); `fs::path::extension()` has no dot; no `try_send` (the async drop counts in flight with an atomic).

## Repository layout

```
nexus/
  module.eco                   module `nexus` (core). Requires container, libjson, libcommand, calendar, libcrypto, libsignal
  src/                         one PascalCase file per type
    Kernel.eco Extension.eco Mode.eco Payload.eco
    Request.eco Response.eco Redirect.eco Stream.eco Format.eco
    Problem.eco FieldError.eco Responder.eco
    Router.eco RouteTable.eco Route.eco Pattern.eco Param.eco
    Action.eco Middleware.eco Next.eco Pipeline.eco
    Body.eco QueryOf.eco Form.eco Rules.eco
    config/ (Config, Source, DotEnv)   events/ (Events, Listener, lifecycle events)
    log/ (Log, Level, Sink, ConsoleSink, JsonSink, AccessLog)   metrics/ (Metrics, Counter, Histogram)
    cli/ (Console, Command, Serve, Routes, Doctor)   run/ (Supervisor, Worker, Halt)
  cli/                         module `nexus-tool`, public exe `nexus`: gen, new, make, dev, routes, doctor
    src/gen/                   decls reader + emitters: routes, inputs, config, i18n, openapi, ts client
  modules/
    http/      nexus-http      libhttp Transport, Cors / SecureHeaders / Throttle, static + Range
    carbon/    nexus-carbon    DB binding, Session per request, migrate commands, Problem::of(carbon::Error), stores
    rest/      nexus-rest      rest Context per request, negotiation, CRUD endpoints (List/Show/Create/Update/Delete)
    auth/      nexus-auth      Guard, Guards, Identity (of/find from the payload), Tokens, Sessions, Passwords, Logins, Throttle
      carbon/  nexus-auth-carbon  auth_tokens + auth_sessions, carbon stores, auth:prune
    oauth/     nexus-oauth     OAuth 2.1 for MCP: metadata, DCR, authorize + consent API, token (PKCE, rotating refresh), revoke, OAuthGuard
      carbon/  nexus-oauth-carbon  oauth_clients, oauth_codes, oauth_grants, CarbonOAuth
    mcp/       nexus-mcp       POST /mcp stateless JSON-RPC, Tools registry, tool classes and actions offered as tools
    work/      nexus-work      Task marker, generated companions and codecs, Tasks::bind, Failure, Queue + MemoryQueue, Runner, Workers, Scheduler (every/cron), work commands
      carbon/  nexus-work-carbon  nexus_tasks, CarbonQueue (claim by attempt count)
    realtime/  nexus-realtime  channels, authorization, broadcast, SSE
    spa/       nexus-spa       embedded asset table, hashed caching, CSP, fallback, dev proxy
    cache/ mail/ files/ i18n/  v1 services
    testing/   nexus-testing   TestApp, Client, assertions, fakes (ManualClock, queue, mail, files)
    app/       nexus-app       nexus::App + nexus::Provider: bind/bind(shared:)/instance/param, route verbs, transformer, repository, tool, task
  examples/blog/               running tour; executable in its own module (carbon examples/blog/app pattern)
  docs/
```

## Core shapes

```echo
// src/main.eco
nexus::Kernel::main([
    nexus::http::Extension(),
    nexus::carbon::Extension(),
    nexus::auth::Extension(),
    blog::App(),                                 // the app is an Extension, listed last
]);

// src/App.eco
public class App : nexus::Extension
{
    public function providers() : array<nexus::Provider>
    {
        array<nexus::Provider> $all = [AuthProvider(), PostsProvider()];
        return $all;
    }

    public function services(nexus::Services& $s) : status<nexus::BootError>
    {
        nexus::App $app = nexus::App($s, $this->providers());
        $app->bindListener<WelcomeNewUser>()->on<UserRegistered>();
        $app->bindTask<SendWelcome>()->queue('mail')->tries(5);
        return .ok;
    }

    public function commands(nexus::Commands& $cmds) : void
    {
        nexus::App::commands($cmds, $this->providers());
        $cmds->add(SetPassword());
    }
}

// src/providers/PostsProvider.eco
public class PostsProvider : nexus::Provider
{
    public function register(nexus::App $app) : void
    {
        $app->bindRepository<PostRepository>();
        $app->bind<PostService>(scoped: (Container $c) => PostService($c->get<PostRepository>(), $c->get<UserRepository>()));
        $app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCrud>()))
            ->route([.get], '/v1/posts/{id}')
            ->tool('show_post', title: 'Read a post', map: ['post' => 'id']);
        $app->bindTransformer<Post, PostTransformer>(PostTransformer($app->endpoint<ShowPost>()));
        $app->bindTool<CreatePostTool>((Container $c) => CreatePostTool($c->get<PostService>(), $c->get<PostTransformer>()))
            ->offer('create_post', title: 'Write a post');
    }

    public function commands(nexus::Commands& $cmds) : void
    {
        $cmds->bindCommand<ShowPostCommand>((Container $c) => ShowPostCommand($c->get<PostService>()))
            ->name('posts:show');
    }
}

// src/actions/posts/ShowPost.eco
#[nexus::answers: { response: "blog::PostTransformer" }]
public class ShowPost : nexus::Action
{
    public constructor(PostService $posts, PostTransformer $transformer) { ... }
    public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem> { ... }
}

// generated .nexus/nexus.eco: how it runs, keyed by type, not where
public struct ShowPostDispatch
{
    internal static function dispatch(nexus::Payload& $payload) : nexus::Response { ... }
    public static function offer() : nexus::mcp::Offer { ... }            // when nexus-mcp is in the program
}
#[nexus::generated: "nexus-blog"]
public function generated(nexus::Generated $g) : void
{
    $g->action<blog::ShowPost>('blog::ShowPost', [nexus::PathParam('id', 'integer', false)], ...);
}

// src/inputs/NewPost.eco
#[nexus::input]
public struct NewPost { #[nexus::rule: { min: 3, max: 120 }] public string $title; public string $body; }

// src/config/DbConfig.eco
#[nexus::config: "db"]
public struct DbConfig { #[nexus::env: "DB_URL"] #[nexus::secret] public string $url; public uint32 $pool = 16; }
```

**Preconditions in middleware:** there are no extractors. A precondition is a middleware class with its dependencies in its constructor, named by the action in `#[nexus::through: ["blog::RequireUser", "blog::RequireAdmin"]]` (outermost first; `nexus gen` checks each names a `nexus::Middleware` and writes them into the generated table, the boot checks each is bound). It answers early (401, 403) or `put`s what it learned and runs the rest; the action reads it with a guard, `Caller $me = guard $payload->state<Caller>() else ($p) { return .error($p); };`. nexus-auth brings `Authenticate` (only signed in callers, leaves the `Identity`); an app with users writes its own (`RequireUser(Guards, UserRepository)` leaves a `Caller`). Because it runs before the generated decoding, an anonymous request with a bad body is a 401. Model rules that need a loaded record stay methods on the model (`$post->changeableBy($me)`, a 403), called where the record is loaded.

`Body<T>`, `QueryOf<T>` and `Form<T>` are decoded by concrete per-input functions that nexus gen emits.

**Problem** generalises Refusal. Cases: badRequest, unauthorized, forbidden(why), notFound(what), conflict, invalid(array<FieldError>), tooLarge, tooMany(retryAfter), unavailable, upstream, internal(Error), custom(type, status, title). Methods: `status()`, `title()`, `render(Format, Mode)`. In prod, `internal` hides details and logs them with the request id.

**Auth (nexus-auth, as built in M3):**
- **Bearer:** `<prefix>_<id>_<secret>` tokens, the secret's sha256 at rest, `TokenStore` interface.
- **Signed:** the server issues `{id, secret}` once; the secret is derived from `AUTH_KEY` and the id, never stored. Each request sends `Authorization: Nexus-Sig id=..,ts=..,sig=..` with `sig = HMAC-SHA256(secret, METHOD\ntarget\nts\nhex(sha256(body)))`, window ±5 min. `X-AccessToken` (base64 JSON `{token,timestamp,signature}`, method:target:ts) is accepted in compat mode for yourlocalchef. `SessionStore` has a sliding expiry, with memory and carbon implementations.
- `crypto::equal` for all comparisons; Argon2id passwords with a decoy hash for unknown users; throttle per address (behind trusted proxies, the forwarded client) and per account.
- **Who is calling** is resolved by middleware: `Guards` (bound by the extension, the app's and oauth's guards added) identify once per request and keep the answer in `Resolved`; `nexus::auth::Authenticate` refuses anybody else with a 401 and `put`s the `Identity`; an app's own middleware does the same and loads its user. Actions read it with `$payload->state<T>()`.

**CRUD (nexus-crud, as built in M2):** one `Crud<M, Q, K, Repo, Res, Map>` per resource holds the shared options (includes, load, scope, authorize, before/after hooks) as fields; each action calls its verb (`list`/`show`/`create`/`update`/`delete`). `Listing<Q>` carries the listing conventions: `page`, `size` (bounded), `order=-created_at` over orderable columns, `include`, `ids`, `count` (`total_count`/`filter_count`). The document carries `page`/`size` next to `data`.

## Compiler constraints (echoc 0.12.2) baked into the design

- **Hook recursion.** A before_build hook that calls `echoc -p decls` must pass `--no-hooks`, or it recurses forever. nexus gen runs `$ECHOC build -p decls --no-hooks --decls-all --define NEXUS_NOGEN --define CARBON_NOGEN --define REST_NOGEN -o $ECHO_HOOK_STATE/decls`, parses stdout even when the exit code is non-zero, and skips the run when a stamp is unchanged. The stamp hashes module.eco, the sources and the echoc version.
- **Generated types are invisible under NOGEN.** They appear as `unknown` and their conformances are dropped. So actions, commands, tools and tasks are discovered through their hand-written markers (`nexus::Action`, `nexus::Cli`, `nexus::mcp::Tool`, `nexus::work::Task`), `handle()` may only mention hand-written types, and hand-written code reaches generated code only by `type_id` (`Generated`, `Offers`, `Codecs`) or through the task companions.
- **Local module only.** Only the root module runs hooks. nexus gen generates for the local module only; libraries built on nexus commit their `.nexus/`.
- **Attribute spellings.** Type references in attributes are strings. Field and label names that are keywords get escaped.
- **Interfaces.** No generic interface methods, no static defaults, no `Self`. Hence the marker `Action`, the companion `XDispatch` structs, and concrete generated code.
- **Payload.** No thread_local, so `Payload&` is passed explicitly and there is no global `request()`.
- **Generated code style.** Typed locals everywhere (no inference through `get<T>()`), `guard` only as statement or initializer, an explicit final `return`, `internal static` (never `private static`), plain public fields.

## Upstream work (outside nexus, in order of need)

1. **container:** mark `Cell`, `Slot`, `Box` and `Forward` `#[atomic]`. Per-request `child()->get` copies them across worker threads and races otherwise. Document that `once` services shared with workers must be atomic.
2. **New `echolibs/libsignal`:** `signal::trap([.int, .term])` / `caught()`, replacing the two copied C shims.
3. **libcrypto:** public `base64` / `base64url`. libhttp and libmysql drop their private copies.
4. **libhttp:** cookies (parse and Set-Cookie), multipart/form, a static directory with Range and ETag, gzip. Dispatch through `wrap` already works.
5. **carbongen / restgen:** a `--decls <file>` flag that reads the JSON instead of spawning echoc, plus a local-module filter (carbongen `Schema::read`). restgen first catches up with the 2026-11-02 rest rewrite (Mapping interfaces).
6. **harbor:** the S3 + sigv4 code moves into `nexus-files`.

## Milestones (vertical slices, each ends green and running through examples/blog)

| M | Scope | Done when |
|---|---|---|
| M1 core slice | Upstream items 1 to 3. Kernel, Extension, Context, Request/Response, Router, Action, extractors, Body/QueryOf, input decoders and rules, Problem/Responder (JSON), middleware, log/request id/access log, CLI (`serve`/`routes`/`doctor`), nexus-http, `nexus gen` (routes, XRoute url/dispatch, inputs, config, boot verification), nexus-testing basics | blog `/v1/posts/{id}` on an in-memory repo; in-process tests; real `serve` plus curl smoke; `nexus gen --check` clean |
| M2 data | Upstream 5; nexus-carbon (DB, Session per request, migrate), nexus-rest (Context, JSON/XML negotiation), CRUD endpoints | blog CRUD on the fake driver and on live MySQL 8 / MariaDB 11 |
| M3 auth | nexus-auth (guards, Bearer, Signed, passwords, throttle, carbon stores) | tests for login, token, signature, tamper, window, compat mode |
| M4 async | Events (sync and queued), nexus-work (tasks, memory and carbon queues, retries, scheduler, once-lock), graceful drain via libsignal | welcome task and nightly task in blog; tasks survive kill and restart |
| M5 doors | `#[nexus::cli]` actions, nexus-mcp, nexus-oauth | one blog action works over HTTP, CLI and MCP; OAuth DCR + PKCE + refresh tested by script |
| M6 frontend | nexus-spa, `nexus gen client` (OpenAPI 3.1 + TS) | embedded blog SPA; generated client passes strict tsc |
| M7 services | Upstream 4 and 6; cache, mail (SMTP plus fake), files (disk, S3), i18n catalogs to typed enum, `/metrics` | blog uses each one; tests run on fakes |
| M8 realtime | channels, SSE, broadcast events | live comments in blog over WebSocket and SSE |
| M9 proof | `nexus new / make / dev`; port Recensio's HTTP layer (doors to actions, Refusal to Problem, Api::authed to a `RequireUser` middleware, OAuth/MCP to the extensions) | Recensio test.sh, test-live.sh and smoke.sh green; duplicated plumbing deleted |

Probe first in M1 (10-line modules):
- generic `Extractor<T>` conformer plus a static call;
- `url(42, page: 3)` with a labelled optional;
- the decls JSON shape of a sample action.

## Conventions

- One type per PascalCase file; type-oriented API (enums with methods, static named constructors, no loose free functions).
- No fake variadics: take array or map literals.
- Shared objects `#[atomic]`, seal-then-share.
- Docs and comments never name foreign frameworks or tools. No README unless asked. No git init or commits.
- The rest library is under active edit by another session (2026-11-02): coordinate before touching it.

## Verification

- Every milestone: `echoc test` in core and every touched module; `nexus gen --check` reports nothing stale; examples/blog in-process tests; `scripts/smoke.sh` runs a real `serve` on its own port with curl checks.
- Live: `scripts/test-live.sh` (Docker MySQL 8 + MariaDB 11) for nexus-carbon/work/auth stores.
- Threads: a parallel-client load test (like Recensio's) to prove the container and Session per request are race-free.
- M5: scripted MCP handshake and tool call through the OAuth flow.
- M6: strict `tsc` on the generated client; Playwright on the embedded SPA.
- M9: Recensio's existing suites unchanged and green.
