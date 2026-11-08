# nexus feasibility check on echoc 0.12.2 (2026-11-02)

**How the evidence was gathered:** the compiler source, the docs, the decls test fixtures in `echo/tests_eco/decls/` and the existing echolibs code. No probe modules were run; the probes that remain are listed at the end.

**Two blockers in the original design, now resolved in `nexus.md`:**
- `#[nexus::use]` does not parse, because `use` is a keyword. It became `#[nexus::middleware]`.
- A hook that calls `echoc -p decls` without `--no-hooks` re-runs itself forever.

## 1. Tool attributes on a `namespace` (blocked; route groups were dropped)

- `echo/src/Parser/NamespaceParser.cpp` (`parse_namespacedecl`) never drains the attribute stack. Pending attributes stay there until the next declaration takes them, so `#[x] namespace a;` silently attaches `#[x]` to the first class or function after the namespace line. Nothing reports the leftover attribute.
- `echo/src/Compiler/DeclsJson.cpp` emits no namespace entries, only `qualified` strings.
- If grouping is ever needed again, put the attribute on an empty marker struct and derive the namespace from `qualified`.

## 2. What `echoc -p decls` gives nexus gen (works, with gaps)

The emitter is `DeclsJson.cpp`. Fixtures: `echo/tests_eco/decls/{params,interface_default,function_and_struct}.test`.

**What's there**
- **Types:** `kind`, `qualified`, `visibility`, `file` (relative to the nearest `module.eco`), `line`, `column`, `doc`, `tools`, `generics`, `conforms` (full type trees, generic arguments included).
- **Members:** `fields` (each with `tools`, `default_value` as source text, `static`), `constructors` (explicit ones only), `methods` (`kind`: `method`/`static`, `const` receiver).
- **Params:** `name`, `label`, `type`, `default` and `default_value`, `mode`, `move`.
- **Return types:** `result<T,E>` lives in the root namespace, so it renders as `{"kind":"named","name":"result","args":[T,E]}`.
- **Tool attributes:** `{"namespace","name","value"}`. A valueless attribute gives `value: null`. `nexus::mcp::tool` splits at the first `::` into namespace `nexus`, name `mcp::tool`.

Sample, derived from the emitter code rather than a live run (trimmed):
```json
{"kind":"class","name":"ShowPost","qualified":"app::posts::ShowPost","file":"src/posts/ShowPost.eco","line":6,
 "tools":[{"namespace":"nexus","name":"get","value":{"kind":"string","text":"/posts/{id}"}}],
 "conforms":[{"kind":"named","name":"nexus::Action"}],
 "constructors":[{"kind":"constructor","params":[{"name":"p","label":null,"type":{"kind":"named","name":"app::PostRepository"},"default":false,"default_value":null}]}],
 "methods":[{"kind":"method","name":"handle","const":false,"tools":[],
   "params":[{"name":"id","type":{"kind":"prim","name":"int64"},"default":false},
             {"name":"u","type":{"kind":"named","name":"auth::Authenticated","args":[{"kind":"named","name":"app::User"}]}},
             {"name":"page","label":"page","type":{"kind":"prim","name":"int32"},"default":true,"default_value":"1"}],
   "return":{"kind":"named","name":"result","args":[{"kind":"named","name":"app::posts::PostResource"},{"kind":"named","name":"nexus::Problem"}]}}]}
```

**Gaps and quirks**
- No namespace entries, no attributes on parameters, no attributes on enum cases.
- Static requirements on interfaces are probably not emitted.
- **Under NOGEN, generated types render as `unknown` and conformances to generated interfaces are dropped.** Two consequences:
  - Discover actions through `nexus::Action` (a library type) plus the route attribute.
  - `handle()` signatures may only mention hand-written types.
- Without `--decls-all` only the app module is visible. You need it to check that a library extractor conforms.
- JSON is printed even when bodies fail (exit status 1), so parse stdout regardless of the exit code.
- `build -p decls` needs `-o`.

## 3. Static `url()` on the user's class (blocked; use a generated companion struct)

- `docs/language/interfaces.md:262`: "A static requirement can't have a default." There is no `Self`, and a class cannot be reopened from another file.
- **Chosen:** a generated `<Action>Route` struct with `url(...)` and `dispatch(...)`.
  - Path params are positional and query params labelled. Labels are mandatory at the call (`functions.md:122`).
  - Query names that are keywords get escaped.

## 4. Generated dispatcher and extractor contract (works)

```echo
public static function dispatch(nexus::Context& $ctx) : nexus::Response {
    int64 $id = guard nexus::Param::int64($ctx, 'id') else ($p) { return $p->response($ctx); };
    auth::Authenticated<app::User> $u = guard auth::Authenticated<app::User>::extract($ctx) else ($p) { return $p->response($ctx); };
    ShowPost $a = $ctx->container->get<ShowPost>();
    result<PostResource, nexus::Problem> $r = $a->handle($id, $u);
    return nexus::respond($ctx, $r);
}
```

- **Extractor:** `public interface Extractor<T> { static function extract(Context& $ctx) : result<T, Problem>; }`. This is the "no Self" idiom: the type is passed as `T`. Generated code calls the concrete static directly.
- **Risk:** a generic conformer `Authenticated<U> : Extractor<Authenticated<U>>` has not been probed. **Fallback:** an instance `fill(Context&) : status<Problem>` on a zero-arg type.
- **Inputs:** nexus gen emits a concrete decoder per input struct.
- **`nexus::Action`:** a marker interface with no `handle` requirement. nexus gen validates `handle` from decls.

## 5. Hooks and one `nexus gen` (works with `--no-hooks`)

- `echo/src/Compiler/BuildHooks.cpp:51` skips hooks only for `--no-hooks` or explicit sources, and `-p decls` runs the full pipeline. The required call is:
  `$ECHOC build -p decls --no-hooks --decls-all --define NEXUS_NOGEN --define CARBON_NOGEN --define REST_NOGEN -o $ECHO_HOOK_STATE/decls`
- **Cost:** the hook runs on every build. Hash `module.eco`, the sources and the echoc version into `ECHO_HOOK_STATE`, and skip the run when nothing changed.
- **Hook rules:** only the root module runs hooks. The editor never runs them. The hook needs a `public: true` exe target.
- **Generators:** carbongen and restgen are library-shaped already. The chosen route is a `--decls <file>` flag on each, because epm cannot vendor a sub-directory.

| Tool | Changes needed |
|---|---|
| carbongen | A local-module filter in `Schema::read`. Skip `wired()` when embedded. |
| restgen | Already filters (`Program::read($decls, $only)`). Must first catch up with the 2026-11-02 rest rewrite. |
| hydragen | Probably not needed: carbongen emits the tables for models. |

## 6. Container (API fits; thread-safety fix needed)

- **The API covers nexus's needs:** `child()`, `put<T>`, `get<T>`, `find<T>`, `has<T>()` (const, checks overlay and catalog), `seal(warm: true)`, `bind<T>(scope: ...)`, `drop()` and `with<M>()`.
- **Hazard:** `Container` and `Core` are `#[atomic]`; `Cell`, `Slot<T>`, `Box<T>` and `Forward<I>` are not.
  - `child->get<T>()` copies shared catalog handles, and those reference counts race across worker threads.
  - A cold `once` read also writes `$cached` and `Core::onceBorn`.
- **Fix:** mark those four classes `#[atomic]`, boot with `seal(warm: true)`, and require that `once` services shared with workers are atomic classes.

## 7. libhttp as transport (works)

- **Single entry:** one `$server->wrap(...)` that never calls `$next`. With no routes registered, the router never runs, so nexus owns 404, 405 with `Allow`, and HEAD-to-GET.
- **Pass-through:** the worker inspects the final response after the chain (`worker.eco:366-378`), so streams and websockets work through a wrap.
- **Realtime:** `Channel` and `Socket` are `#[atomic]`. The socket registry needs a mutex, since there is no rwlock.
- **Threading:** the app object captured by the wrap must be `#[atomic]` and immutable after boot.
- **rest:** `Document::response()` returns an `http::Response`. nexus should use `render<D>` and wrap the result in a `nexus::Response`.

## 8. Other compiler limits

| Limit | Workaround |
|---|---|
| `use` is a keyword in attribute names | `#[nexus::middleware]`; `use:` is fine as a record key |
| A bare `ns::Name` is refused as an attribute value | Use strings |
| A generic class stored as an interface value is a compiler error ("no vtable") | CRUD stores closures |
| No generic interface methods, no `Self` | Marker `Action`, concrete generated code |
| A generic body calling an overloaded generic method binds the non-generic overload | Don't overload generic API methods |
| Generic struct temporaries can't chain `&` methods | Builders are classes |
| No `thread_local`, no async | Pass `Context&` explicitly; tasks run on `std::thread` |
| `guard` only works as a statement or an initializer; a function can fall off its end silently | Typed locals and an explicit final return in generated code |
| `private static` is unreachable from the class's own statics | Use `internal static` |
| Keywords can't be member names | nexus gen escapes them |
| File read order loses alias defaults | Keep generated output in `.nexus/` |

## Probes to run first in M1

1. `#[x: "y"] namespace a; public class B {}`: the attribute should show up on `B`.
2. `struct Authenticated<U> : Extractor<Authenticated<U>>` with a static `extract`, called as `Authenticated<User>::extract(...)`.
3. `#[nexus::use: 1]`: should be a parse error.
4. A labelled `page: int32? $page = null`, called as `url(42, page: 3)` and as `url(42)`.

Never probe hook recursion without `--no-hooks`.
