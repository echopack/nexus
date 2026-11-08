# Research: the Echo libraries nexus builds on (2026-11-02)

**Short version:** the libraries cover an HTTP server, DI, an ORM on a typed SQL builder, MySQL, a response/transformer layer, dates, JSON, crypto, CLI and an HTTP client. Seven areas have no library at all: templates, sessions/cookies, config, logging, cache/redis, queues and validation.

## libhttp (`http`, v0.2.6)

- **Basics:** no Echo dependencies; its own kqueue/epoll C shim. 273 tests. Build the final binary with `--optimize whole`, otherwise routing is 4–5× slower.
- **Server model:** reactor threads own idle connections. Complete requests go to one queue served by a worker pool (default `thread::concurrency()`, one reactor per four workers). Handlers are synchronous; there is no async.
- **`Server`** (`#[atomic]`):

  | Group | Members |
  |---|---|
  | Routes | `on(Method, path, fn)`, `get/post/put/patch/del/head/options`, `ws(path, Channel)`, `wrap(fn(Request, Next): Response)` |
  | Lifecycle | `listen(host, port)`, `stop()`, `port()` |
  | Settings | `workers`, `reactors`, `maxBody`, `bodyLimit(fn)`, header/body/idle timeouts, `maxRequests`, `maxConnections`, `maxQueueWait`, `maxMessage`, `pingInterval` |

- **Router (internal):** first match wins, in registration order. Patterns: `{id}`, `{page?}`, `{path*}`, `{id:number|alpha|alphanum|uuid|ulid|a|b}`. 404/405 with `Allow` is automatic, and HEAD falls back to GET. No groups and no URL generation.
- **Middleware:** `wrap`, first registered is outermost. It also sees 404/405. Route params are not filled yet when it runs.
- **`Request`** (struct, public constructor):
  - Fields: `method`, `target`, `path`, `queryString`, `query`, `version`, `headers`, `body: string`, `peer`, `params`.
  - Helpers: `header()`, `param()`, `websocket()`.
- **`Response`:**
  - Constructors: `(status, body)`, `(ok:)`, `(text:)`, `(json: string)`, `(html:)`, `(stream: fn(Writer))`, `(websocket: Channel, protocol:)`, `(file: path)`.
  - Statics: `notFound`, `badRequest`, `noContent`.
- **Streaming and WebSockets:** streams are chunked on HTTP/1.1, so SSE works. WebSockets follow RFC 6455: `Channel` (onOpen/onMessage/onClose), `Socket` (`#[atomic]`), and `Group` for broadcast.
- **Not supported:** TLS, HTTP/2, IPv6, Windows, cookies, multipart, Range, compression, a static directory server. There is no client (use libcurl).
- **Crash model:** a `die` in a handler kills the process.

## container (`container`, v0.1.0, 69 tests, not committed)

- **Model:** runtime, keyed by `type_id<T>()`. No reflection and no codegen.
- **`Builder`:**
  - Binding: `bind<T>(once:|each:|scope: fn() or fn(Container))`, `bind<T>(put: value)`, `param<T>(value)`.
  - Overrides: `replace<T>`, `alias<I, C>`.
  - Packs: `install(fn | Pack)`, `overlay`.
  - Lookup and sealing: `has`/`get`/`find`, `seal(warm:)`.
- **`Container`:** `get<T>` (dies if missing or cyclic), `find<T>`, `has<T>`, `with<M>()`, `child()`, `put<T>(v)`, `warm()`, `drop()`.
- **`Entry<T>`:** `meta<M>(value)`, `view<I>()`. **`Record`:** `meta<M>()`, `fetch<I>()`. **`Pack`:** `install(Builder&)`.
- **Scopes:**
  - `once` is shared across children.
  - `each` is built on every `get`.
  - `scope` is cached per container or child; use it for request-bound services.
- **Request pattern:** `child(); put<Request>(...); ...; drop()`.

## rest (RestTransformers; module `rest`, namespace `EchoPack::Rest`, v0.2.0, rewritten 2026-11-02)

- **Dependencies:** libjson, libhttp, calendar. 38 tests run against `tests/fixtures.eco` (a stand-in for generated code).
- **Documents:** `item<M>(r)` / `collection<M>(arr)` return a `Document<M>` with `with`, `json(pretty:)`, `xml(indent:)`, `render<D>`, `tree()`, `response(Format, pretty:, status:)` (returns an `http::Response`).
- **Formats:** `Format` (json, xml) with `negotiate(accept)`. `Driver` interface, implemented by `JsonDriver` and `XmlDriver`.
- **Per request:** `Context(Transformers, Includes)` with `enter`/`leave`/`wants`/`put<T>`/`get<T>`/`find<T>`. `Transformers` is a sealed registry keyed by type.
- **Includes and relations:** `Allow::of([...])->always([...])->parse(include)`. `Include<T>` (absent/none/of), `Resolved<T>`.
- **Errors:** `Problem::of(Error)->response(Format)`.
- **Intended pattern:** an `#[atomic]` transformer class conforms to a generated `XResourceMapping` and gets `transform`/`many`/`refine` for free.
- **Attributes:**
  - On the model: `#[rest::model]`, `#[rest::from]`, `#[rest::keys: camel|snake]`.
  - On fields: `name`, `source`, `manual`, `skip`, `optional`, `wrap`, `item`, `attribute`.
- **restgen** (`cli/`): writes `.rest/models.eco` behind `REST_NOGEN`. **It is stale:** it still emits the old API, and so does examples/blog.

## carbon (`carbon`, v0.1.0)

- **Dependencies:** hydrahon, calendar, libjson. The MySQL driver is the `drivers/mysql` sub-module. About 208 core tests, plus carbongen 84 and the driver 10.
- **Core types:**
  - **`DB`** (`#[atomic]`): built from a Driver or a pooled Source, with `clock:`. Methods: `register<R>()`, `observe`, `listen`, `seal()`, `session()`, `scoped<C>(ctx)`, `run`, `now()`.
  - **`Session`:** one per request or thread. `put<T>`/`get<T>`, `repo<R>()`, `transaction(fn)`, `now()`.
  - **`Model<M, R>`:** the class supplies `link()` and gets `save`/`delete`/`restore`/`purge`/`fresh` plus dirty tracking.
  - **`Repository<M, Q, K>`:** find/query/create/save/delete/…/get/many/count/exists/each, plus `before`/`after` hooks.
  - **`Query<M, Q>`** (immutable struct): where/with/order/limit/page/scope/join/group/having/select/adjust. Terminals: get/first/one/many/count/exists/each/update/purge.
- **Migrations:** `Migration`, `Migrator(db, X::Carbon::migrations(), ddl::Mysql())` with up/down/reset/status.
- **Testing:** `carbon::fake::Driver<Dialect>`.
- **Attributes:**
  - On the class: `#[carbon::model: 'posts']`, `#[carbon::migration: 'id']`.
  - On fields: `key`, `name`, `skip`, `created`, `updated`, `deleted`, `version`, `codec`, `computed`, `belongsTo`, `hasOne`, `hasMany`.
- **carbongen:** writes `.carbon/models.eco` behind `CARBON_NOGEN`. It generates XTable, XQuery, XRelations, XLoad, XWiring, `Carbon::migrations()`, `register` and `check`.
- **Threading:** one sealed DB per app, plus one `scoped(ctx)` session per request with its own pooled connection.

## Other libraries

| Library | Namespace | Notes |
|---|---|---|
| hydrahon | `hydrahon` | Typed SQL compiler for MySQL, Postgres and SQLite; `hydragen` tool. No DDL |
| libmysql | `mysql` | `#[atomic]` Connection, Pool/Lease, Outcome, Rows streaming. No TLS |
| calendar | `calendar` | Date, Time, DateTime, Zoned, Zone, Period, Interval. `Clock` (System/Fixed/Manual). `Format::rfc3339/rfc2822/http`. Locales en/de/fr/it |
| libcrypto | `crypto` | Argon2id passwords, seal/open, Ed25519, HMAC/SHA, random, constant-time `equal`, hex. **No public base64** |
| libcommand | `command` | Commands and subcommands, args/flags, help, widgets, prompts |
| libcurl | `curl` | HTTP client |
| libtcp | `tcp` | Sockets, Poller, Reader, Deadline. The base for a future Redis client |
| libjson | `json` | parse/dump/Value |

**Missing entirely:** templates, sessions/cookies, cache/redis, queues, validation, form parsing, and drivers for SQLite and Postgres.
