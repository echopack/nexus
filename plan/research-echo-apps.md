# Research: existing Echo web apps and the language features that shape nexus (2026-11-02)

## harbor (`~/Developer/echoex/harbor`, about 65k lines)

- **Manifest:** requires libhttp, libcrypto, libjson, libcommand, libcurl and libtcp. C shims for signal, stat, DNS, gunzip and ssh. The dashboard is embedded as a C byte array.
- **CLI:** libcommand, dispatched by an `if ($subject == 'serve')` chain. A `setting(parsed, arg, envName, fallback)` helper resolves each option as flag, then env, then default.
- **HTTP:** one `wrap` dispatches by Host. A `Routes` wrapper **re-implements libhttp's matcher** just to get per-route body limits. Each door is an `#[atomic]` class with `mount(Routes)` and closures that capture `$self`. About 20 doors are mounted in `run()`.
- **Errors:** `enum Refusal` (status/message/report). `Reply::of(result, status)` builds JSON responses.
- **Auth:** `hb_<id>_<secret>` bearer tokens, Argon2id passwords, a `Throttle` (`mutex<map>`). Cookies only for the site password gate.
- **OAuth and MCP:** OAuth 2.1 with dynamic client registration, PKCE and refresh tokens. MCP is hand-written JSON-RPC.
- **Persistence:** JSON documents on disk or S3. No SQL.
- **Background work:** about nine `thread::spawn` tick loops and a `Running` atomic flag. Shutdown is polled through the signal shim.
- **Logging:** `println`/`eprintln` only.

## Recensio (`~/Developer/echoex/Recensio`, about 37k lines)

- **Stack:** carbon, MySQL and libhttp. Two exe targets.
- **Doors:** mounted directly on `http::Server`. Every route nests two closures: `$self->api->authed($req, 200, function(Access, carbon::Session) ...)`.
- **Shared plumbing:**
  - `Api::authed`/`open` handle sessions from the pool plus bearer auth, with a `Passes` cache.
  - `Refusal` has a `database(carbon::Error)` case.
  - `Reply`/`Doc` give typed body reads.
- **Auth and OAuth:** `rs_` + 64-hex tokens stored as sha256. A decoy hash keeps login timing equal for unknown emails. OAuth in `src/oauth/*`, MCP in `src/mcp/*`.
- **Dashboard:** embedded with `std::embed::text` plus a CSP file.
- **Database:**
  - Models: `#[carbon::model]` classes.
  - Repositories: structs implementing `carbon::Repository` and `XWiring`.
  - Wiring: hand-written `Wiring::open` (register + check).
  - Migrations: `#[carbon::migration]` classes.
- **Background work:** crews, lanes, a scheduler and a ticker that polls the signal shim. Stop runs in reverse order.

## Plumbing duplicated in both apps (what nexus absorbs)

| Concern | What is duplicated |
|---|---|
| Errors and responses | Reply/Refusal/Doc |
| CORS | Byte-identical code |
| Security | Throttle; Argon2id passwords; token minting |
| Embedded SPA | Page plus CSP headers |
| OAuth 2.1 and MCP | JSON-RPC handling |
| Encoding | percent/base64url/form helpers |
| Signals | The signal C shim |
| Config and CLI | `setting()` config; CLI preamble; `host:port` parsing |
| Runtime | Graceful stop and thread loops; `/health`; bootstrap/reset-admin |

**Patterns nexus fixes:**
- Mounting doors by hand.
- Two closures per route.
- A second route matcher.
- No logger, request ids or access log.
- No cookies or sessions.

## Language facts (echoc 0.12.2; docs in `~/Developer/echo/docs`)

### Attributes and code generation
- **Tool attributes:** any namespaced attribute (`#[nexus::get: "/x"]`) is carried, not interpreted. Value grammar: string, int, bool, name, list, record, tagged.
- **`attr::of<T>(name, key)`** collects tagged declarations at compile time. It handles free functions, static methods, zero-arg factories for types, and type_ids. Payload fields are filled from the attribute value, and the `key` argument enforces uniqueness. It sees public declarations program-wide and internal ones in the calling module. **Limit: only zero-arg-constructible types**, so it cannot build DI-constructed actions.
- **`echoc -p decls`** prints resolved declarations as JSON, the basis for carbongen, hydragen and restgen. The format is not versioned.
- **Build hooks:** `#[hook: before_build { run, name, args }]` runs in the root module only. Env vars passed: `ECHO_MODULE_DIR`, `ECHO_HOOK_STATE`, `ECHOC`, … Convention: commit the generated code and write only changed files.
- **No general reflection and no macros.**

### Types
- **Generics** are monomorphized, with constraints and `where` clauses.
- **Interfaces:** default bodies and associated types; no traits, no `Self`.
- **Enums:** payloads and integer backing.
- **Errors:** `result`/`status` with `guard ... else`; no exceptions.
- **Structs vs classes:** a struct is a value, a class is reference-counted, and `#[atomic]` is required for anything shared across threads.
- **Closures** capture by copy, implicitly or with `function[$a, mv $b]`.

### Concurrency
- **std::thread:** `spawn`/`task`/`channel`/`mutex`/`condition`/`once`/`atomic`.
- **Missing:** async, select, rwlock and thread_local.
- **Crashes:** `die`/`assert` in a handler kills the whole process.

### Other
- **Embedding:** `std::embed::text/bytes` works per file; there is no directory embedding.
- **Plugins:** `#[target: lib]`, `#[export]`, `extern interface` and `std::dynlib::load`.
- **Modules:** `module.eco` is itself Echo. epm uses git and path sources. Default visibility is module-level.
- **Tests:** `test name {}` blocks, groups, `expects death`, each test in its own process.

### What the stdlib lacks
No sockets, HTTP, JSON or crypto (those come from echolibs). No stat or recursive walk, no signals, no regex, no DNS.
