# Research: the PHP ClanCats Nexus framework (2026-11-02)

**Short version:** Nexus lives at `~/Developer/ClanCats/nexus`, about 16.8k lines in `src/`. A ClanCats Container `.ctn` file declares every service, and metadata tags on those services register routes, CLI commands, event listeners, view finders and translation finders. There is no middleware pipeline, no attribute routing and no module system.

## Layout and entry points

| Path | What it is |
|---|---|
| `bootstrap.php` | The procedural kernel: builds the container, sets up env, error handling, logging and signals |
| `nexus.ctn` | Framework services; it ends with `import app` |
| `nexus_dev.ctn` | The env used when developing Nexus itself |
| `bin/nexus-cli` | Dev CLI for Nexus itself |
| `bin/portal` | Docker dev environment wrapper |
| `src/` | Auth, Cache, Command, Error, Exception, HTTP, Maker, Routing, Signal, Signals, Storage, Toolbelt, Transformer, Translation, Validation, View |

- **Dependencies:** PHP 8.3+, clancats/container, clancats/hydrahon, symfony/http-foundation, nikic/fast-route, league/climate, respect/validation, filp/whoops, monolog.
- **App entry points:**
  - `bootstrap.php` defines `PATH_*` and requires the Nexus bootstrap.
  - `public/server.php` calls `$container->get('nexus.http')->handle(Payload::createFromGlobals())->send()`.
  - `bin/nexus` calls `cli_loader->pass($argv)`.

## Concepts

### Kernel and container
- **Kernel:** `bootstrap.php` is a script. It compiles the container (`AppContainer`) from `nexus.ctn`, `app.ctn`, the `app/` directory, vendor `.ctn` files and `app.ctn.env` overrides. It copies constants into `const.*` parameters and `NEXUS_*` env vars into `env.*`, registers the exception handler and Monolog with a rotating `error.log`, collects `log_handler`-tagged services, and dispatches `bootstrap.pre`/`post`.
- **Container metadata tags:** `route`, `command`, `on` (call, priority), `view.finder`, `translation.finder`, `log_handler`.
- **Config:** container parameters only. `env === 'dev'` enables Whoops and disables the router cache. `debug` is never read.

### HTTP
- **Routing:** FastRoute with a cached dispatcher. The handler is a service name. No groups, no named routes, no URL generation. Route params are copied into `$payload->query`. Ordering follows `.ctn` import order, so the catch-all goes last.
  ```
  @actions.workspace.update: App\Action\Workspace\UpdateWorkspaceAction(@repository.workspace, @transformer.workspace)
    = route: {'PUT', 'DELETE'}, '/v1/workspaces/{workspace}'
  ```
- **Lifecycle:** signal `http.request` → match → resolve the action service → inject the container and session → `prepare()` → `handle(Payload)`. On an exception, signal `http.exception` (a handler may set a response); after the response, signal `http.response`.
- **Action:** `prepare`, `handle`, exception factories, `validate`, `view`/`dynamicView`, `createRESTPayloadBag`.
- **Payload** (a Symfony Request): decodes JSON bodies. **Response:** `json()` (pretty-printed), `redirect()`, always sets `X-Powered-By`.
- **RESTPayloadBag:** `page`, `page_size` (2 to 200, default 50), `order`, `order_dir`, `include`, `resolve`, `idfs` (comma-separated ids, up to 2048).
- **ActionGenerics:** `List`/`Get`/`UpdateEndpointScaffolding` plus `*Options`, combining a repository, a transformer, a validator and will/did callbacks. Delete is missing; apps build their own.
- **Middleware:** none. Cross-cutting concerns live in a `prepare()` inheritance chain (`Action` → `AuthenticatedAction` → `APIAction` → `WorkspaceAction`) plus signals.

### Events, sessions, auth, validation, views
- **Signals:** handlers keyed by string, integer priority (lower runs first), `stopPropagation`, resolved lazily from the container. Built-ins: Bootstrap, Payload, Response, ResponseForException, Any.
- **Sessions:** a Symfony native session (`_nx_session`). Apps often replace it; yourlocalchef uses a Redis `SessionManager` with HMAC-signed access tokens, sending `HMAC(secret, METHOD:URI:timestamp)` as base64 JSON in `X-AccessToken` with a 1 h window.
- **Auth:** `AuthPayloadInterface` → `AuthState`. `SimpleTokenAuth` reads the `X-AccessToken` header or the `access_token` query param. `PasswordAuth` stores `_nx_auth_id` and a signature in the session. `SignedTokenAuth` is an empty stub.
- **Validation:** wraps Respect. `prop()` chains, `rule()`, `MethodListValidationProvider` (reflection), `PayloadValidationException`.
- **Views:** plain PHP (`extract` + `require`). The Twig fixtures in the tests have no renderer behind them.

### Storage
Hydrahon-based data mapper:
- **Manager:** `name:type` connections, `bind(name, Repo)`.
- **Repositories:** `BaseRepository` (`$mapping`) and `MySQLRepository` (`select`/`get`/`find`/`count`/`save`/`delete`/`with`).
- **Models:** `BaseModel` with `static $properties`, cast types (`int`/`float`/`bool`/`json`/`serialize`/`comma`) and magic accessors.
- **Queries and relations:** `BaseQuery` (IDFS ordering, soft delete), relations HasMany/HasOne/BelongsTo, and ChannelReference (`name:id`).
- **Not wired by default:** every app writes its own `StorageManager` ServiceProvider.
- **Migrations:** raw numbered SQL files run by `sql:migrate`, tracked in `_nexus_migrations`, forward-only.

### Other components
- **Transformers:** `Transformer<M>::transform`, `createResponse`/`createCollectionResponse`, `ConnectedTransformer` with depth limit 1, `TransformerNetwork` resolving by container prefix.
- **CLI:** `Command` (CLImate argument specs). Built-ins: `commands:available`, `cache:clear`, `container:dump`, `signals:dump`, `sql:migrate`, `sql:create_migration`, `make`.
- **Maker:** generators for class, action, command, transformer and `storage:mysql` (table introspection).
- **Missing entirely:** queues and scheduling. Apps reference a Beryllium queue package that isn't installed, and schedule through php-cron-scheduler shelling out to `bin/nexus`.
- **Cache:** `CacheInterface` with `get(key, callback, lifetime)`; Redis and APCu implementations.
- **i18n:** JSON/CSV catalogs cached per language, `trans` via `str_replace`, no plurals, no fallback.
- **Testing:** a fake app in `tests_env/`, DB environment test cases, Codeception REST suites in the apps.

## Dated or awkward parts (what the successor must not repeat)
- **Global state:** global `PATH_*` constants deep inside classes, a global override variable, a static parameter bag ("I HATE IT"), static caches.
- **Kernel and error handling:** no Kernel object. Two competing error handlers. `handleShutdown` is a TODO. A hardcoded `env === 'dev'`.
- **HTTP:** no middleware, groups or URL generation. A forgotten `cache:clear` after a route change costs half an hour. Route params land in the query. `Response` has side effects (`header_remove`, watermark).
- **Validation and scaffolding:** wrong validator keys "validate but silently never assign". No Delete scaffolding.
- **Storage:** untyped and magic. `find()` returns array, model, false or null. `limit(1)` changes the return shape. Storage is not wired by default.
- **Stubs and dangling references:** `SignedTokenAuth` is empty. Beryllium and `ServiceProcessor` are referenced but missing.
- **Distribution:** `dev-master` only, and the vendored copies have drifted from source.

## Apps using it
- `~/Developer/Games/deckofpoints` is the cleanest, and its `CLAUDE.md` describes the architecture.
- `~/Developer/YourLocalChef/yourlocalchef.ch` is the largest: 39+ migrations, a scheduler, Twig, Elasticsearch, Stripe.
- `~/Developer/ClanCats/oxycam-web`.

Shared skeleton:

| Path | Contents |
|---|---|
| `app.ctn` | Imports `app/config`, `app/services`, `app/events`, `app/routes`, `app/commands`, then `app.env` |
| `src/Action/` | Base classes `APIAction`, `AuthenticatedAction`, … |
| `src/Storage/` | Models, queries, repositories and the `StorageManager` |
| `src/Transformer/` | Transformers |
| `resources/` | Migrations, translations, views |
