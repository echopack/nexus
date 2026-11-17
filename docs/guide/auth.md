---
description: Signed sessions, bearer tokens, Argon2id passwords and login throttling. Who is calling, and how an action finds out.
---

# Authentication

Almost every app reaches the point where it needs to know who is calling. Who wrote this post? May this person delete that comment? Is the request even from the browser it claims to be? nexus-auth answers those questions. It reads the credential a request carries, names its caller, and leaves that answer in the payload for your middleware and actions.

It brings two kinds of credential. **Signed sessions** are for your own frontend: the browser signs every request with a secret it got once, so nothing travelling over the wire can be replayed with a different body or path. **Bearer tokens** are for scripts and command line tools, where a single header is the friendlier choice. Around those you get Argon2id password hashing, a login throttle, and the hooks [OAuth](./oauth.md) and [Sign in with Google](./connect.md) build on.

Security code has a way of looking intimidating. Don't worry: your part is a few lines of wiring and two or three small actions. Everything delicate (deriving secrets, comparing in constant time, hashing passwords) lives in the module.

To add it, require the module in your app's `module.eco`, plus the carbon store if you want credentials in your database:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/auth" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/auth/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list its extensions after nexus-carbon and before your app. The first argument is the prefix your tokens start with:

```echo title="src/Extensions.eco"
// who is calling: signed sessions only (a client opens one before anything else, signing in
// puts the user on it) and password hashing; the stores come from the next line
nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),

// keeps those sessions in the database
nexus::auth::carbon::Extension(),
```

The one setting you must provide is `NEXUS_AUTH_KEY`, at least 32 characters. Every session secret is derived from it, so the app refuses to boot without it.

## How signing in works

Before we look at code, let's walk through the flow once. It differs a little from cookie logins you may know:

1. The client opens a session **for nobody** with `POST /v1/auth/session`. The answer carries a session id and a secret, and this is the only time the secret is ever sent.
2. From then on, the client signs **every** request with that secret, including the sign in itself.
3. Signing in puts the user on that same session. The session id and secret do not change; the server just knows whose requests they are now.
4. Signing out ends the session, and the client opens a fresh one.

Why a session for nobody first? Because then every request to your API is signed, and the sign in is no exception: a password never travels in a request the server could not tie to the client that opened the session. It also means a visitor who has not signed in yet still has an identity you can rate limit or attach a draft to.

## Signed sessions

### Opening a session

Opening a session is a plain action. Ask for `nexus::auth::Sessions` in the constructor and call `open()`:

```echo title="src/Actions/Auth/OpenSession.eco"
namespace Blog::Actions::Auth;

/**
 * Opens a signed session for nobody, the first thing a client does: the answer carries its id and
 * secret, shown this once, and every request after signs itself with them.
 */
public class OpenSession : nexus::Action
{
    private nexus::auth::Sessions $sessions;

    public constructor(nexus::auth::Sessions $sessions)
    {
        $this->sessions = $sessions;
    }

    public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
    {
        $opened = try $this->sessions->open();
        return .ok(nexus::Response(json: $opened->json(), status: 201));
    }
}
```

The answer is `{"id": "...", "secret": "...", "expires_at": "..."}`. The id is 32 hex characters of fresh randomness. The secret is the hex HMAC-SHA256 of the id under `NEXUS_AUTH_KEY`, so the server can work it out again on every request and **never stores it**. A leaked sessions table holds no secrets at all.

### Signing a request

A signed request carries one header:

```txt
Authorization: Nexus-Sig id=<session id>,ts=<unix seconds>,sig=<hex>
```

The signature is the hex HMAC-SHA256, under the session's secret, of four lines: the method, the target as sent (path and query), the unix time in seconds, and the hex SHA-256 of the body (of the empty string when there is none):

```txt
POST
/v1/posts?draft=1
1730540000
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
```

That is all a client needs. The blog's page does it in a browser with Web Crypto, keeping the session in `localStorage`:

```js title="resources/web/index.html"
// Authorization: Nexus-Sig over METHOD, target, unix time and the body's sha256, one per line
async function sign(s, method, target, body) {
  const ts = Math.floor(Date.now() / 1000);
  const digest = hex(await crypto.subtle.digest('SHA-256', utf8(body)));
  const key = await crypto.subtle.importKey('raw', utf8(s.secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = hex(await crypto.subtle.sign('HMAC', key, utf8(`${method}\n${target}\n${ts}\n${digest}`)));
  return `Nexus-Sig id=${s.id},ts=${ts},sig=${sig}`;
}
```

From a shell, `openssl` does the same. The blog's `scripts/sign.sh` holds the helpers its smoke test uses:

```bash title="scripts/sign.sh"
ts="$(date +%s)"
digest="$(printf '%s' "${body}" | openssl dgst -sha256 -hex | awk '{print $NF}')"
sig="$(printf '%s\n%s\n%s\n%s' "${method}" "${target}" "${ts}" "${digest}" | openssl dgst -sha256 -hmac "${secret}" -hex | awk '{print $NF}')"
printf 'Authorization: Nexus-Sig id=%s,ts=%s,sig=%s' "${sid}" "${ts}" "${sig}"
```

And for clients and tests written in Echo, `nexus::auth::Signer` builds the header for you:

```echo
$s = nexus::auth::Signer($id, $secret);
string $auth = $s->header('POST', '/v1/posts', $now, $body);
```

The blog's integration tests open a session over HTTP and hand the signer to their API client; [testing](./testing.md) shows how.

### What the server checks

So, what happens when a signed request arrives? `nexus::auth::SignedGuard` reads the header, and `nexus::auth::Sessions` checks it in this order:

- **The time.** The request's `ts` may be at most **five minutes** from the server's clock, either way. Otherwise the answer is a `401` with the reason `signature_stale`.
- **The signature.** The server derives the session's secret from the id, signs the same four lines, and compares in constant time. A mismatch is a `401` with `signature_invalid`.
- **The session.** Only then is the store asked. A session that is gone or past its expiry is a `401` with `session_ended`.

Because the signature is checked before the store is touched, a forged request never costs you a database query. A session in use slides forward: each request moves its expiry out again, written at most once a minute. A session for nobody lasts one hour from its last use, one with a user 30 days; both are [settings](#settings).

The signature binds the method, target, time and body, so nobody can take a captured request and change any of it. The very same request can still be sent again inside its five minute window, though. A write that must happen exactly once should carry an idempotency key of your own.

::: tip Telling the two 401s apart
A client sees a `401` both for "you are not signed in" and for "your session ended". Only the second means the session is useless. The blog's page checks the problem's `reason`, and only on `session_ended` does it forget the session and open a new one.
:::

### Signing in

Signing in puts a user on the session the request is signed with. The action reads the session's `nexus::auth::Identity`, checks the password, and calls `attach`:

```echo title="src/Actions/Auth/Login.eco"
public function handle(nexus::Payload& $payload, nexus::Body<Credentials> $in) : result<nexus::Response, nexus::Problem>
{
    $session = try $payload->state<nexus::auth::Identity>();
    if (!$session->anonymous()) {
        return .error(nexus::auth::Sessions::taken());
    }
    $u = try $this->signIn->check($payload, $in->value);
    try $this->sessions->attach($session->credential, "{$u->id}");
    return $this->transformer->own($payload, $u, nexus::rest::Meta());
}
```

The subject is the user's id as text. `attach` is a single write that only succeeds while nobody is on the session and it has not expired, so two sign ins racing on one session cannot both win. A session somebody already signed in on is a `409`, and one that ended is a `401`. From that moment the session lasts the full signed in lifetime.

Where does the `Identity` come from? From `RequireSession`, which we'll meet in a moment. `SignIn` is the blog's service that checks the password; it is shown under [throttling logins](#throttling-logins).

### Signing out

Signing out ends the credential the request came with. `nexus::auth::Guards::revoke` asks whichever guard read it, so the same action works for a session and a token:

```echo title="src/Actions/Auth/Logout.eco"
public function handle(nexus::Payload& $payload) : status<nexus::Problem>
{
    $session = try $payload->state<nexus::auth::Identity>();
    return $this->guards->revoke($payload, $session);
}
```

When a password changes, you may end every session and token of that user at once with `Sessions::closeAll` and `Tokens::revokeAll`. The blog's `user:password` command does exactly that.

## Requiring a session everywhere

Naming a guard on every single action gets old fast, and the one you forget is the one that leaks. `nexus::auth::RequireSession` turns it around: wrap every request in it, and every route under a path needs a session unless you exempt it. The blog uses it so that nothing under `/v1` answers without one, except the action that opens a session:

```echo title="src/App.eco"
// nothing under /v1 answers without a signed session, but opening one
$app->bind<nexus::auth::RequireSession>(shared: (Container $c) => nexus::auth::RequireSession(
    $c->get<nexus::auth::Guards>(), under: '/v1', except: [type_id<Blog::Actions::Auth::OpenSession>()]));
$app->middleware<nexus::auth::RequireSession>();
```

A request under `/v1` without a credential gets a `401` with the reason `session_required`. A session for nobody passes, so a visitor can read posts without signing in. Everything outside `under` passes untouched (the page, `/health`, OAuth, MCP), and so does a CORS preflight and a request no route answers, which routing then turns into a `404` or `405`.

`RequireSession` leaves the credential's `nexus::auth::Identity` in the payload, anonymous when nobody signed in yet. That is what `Login` and `Logout` above read. [Middleware](./middleware.md) covers app-wide middleware in general.

## Who is calling

`RequireSession` only checks that a credential exists. For an action that needs a signed in user, you go one step further.

### `Authenticate`

`nexus::auth::Authenticate` lets only signed in callers through: a session with a user on it, or a valid token. Anybody else gets a `401` with the reason `signed_in_required`. It is bound for you, so you may name it right away:

```echo
#[nexus::through: ["nexus::auth::Authenticate"]]
public class RevokeTokens : nexus::Action
{
    private nexus::auth::Tokens $tokens;

    // ...

    public function handle(nexus::Payload& $payload) : status<nexus::Problem>
    {
        $me = try $payload->state<nexus::auth::Identity>();
        return $this->tokens->revokeAll($me->subject);
    }
}
```

The guards run once per request. What they found is kept in the payload's container, so a second middleware asking again costs nothing.

### Loading your own user

An `Identity` says *which* subject is calling, but your actions usually want the user record itself. Most apps therefore write a middleware of their own that demands a caller, loads the user, and `put`s both into the payload. Here is the blog's:

```echo title="src/Middleware/RequireUser.eco"
public class RequireUser : nexus::Middleware
{
    private nexus::auth::Guards $guards;
    private UserRepository $users;

    // ...

    public function handle(nexus::Payload& $payload, nexus::Next $next) : nexus::Response
    {
        $id = guard $this->guards->demand($payload) else ($r) {
            return $r;
        };
        $user = guard BlogUsers::of($this->users, $id->subject) else ($p) {
            return $payload->fail($p);
        };
        $payload->put<Caller>(Caller($id, $user));
        return $next->run($payload);
    }
}
```

`Guards::demand` answers the caller's `Identity` or the finished `401` response, so a refusal goes straight back. `BlogUsers::of` turns the subject into a `User`, and answers a `401` when the account no longer exists. `Caller` is a small struct of the blog's own:

```echo title="src/Types/Caller.eco"
public struct Caller
{
    public nexus::auth::Identity $identity;
    public User $user;
}
```

Actions name the middleware and read `$payload->state<Caller>()`, as [actions](./actions.md#reading-what-middleware-learned) shows. Because the middleware holds a repository, the blog binds it per request:

```echo title="src/Providers/AuthProvider.eco"
$app->bind<RequireUser>(scoped: (Container $c) => RequireUser($c->get<nexus::auth::Guards>(), $c->get<UserRepository>()));
$app->bind<RequireAdmin>(shared: () => RequireAdmin());
```

Further checks stack on top. `RequireAdmin` reads the `Caller` that `RequireUser` left and refuses anyone who is not an admin, so it is always named after it:

```echo title="src/Middleware/RequireAdmin.eco"
public function handle(nexus::Payload& $payload, nexus::Next $next) : nexus::Response
{
    $me = guard $payload->state<Caller>() else ($p) {
        return $payload->fail($p);
    };
    if ($me->user->role != Role::admin) {
        return $payload->fail(nexus::Problem::forbidden('this needs an admin'));
    }
    return $next->run($payload);
}
```

### What an identity carries

A `nexus::auth::Identity` holds:

| Field | What it is |
|:--|:--|
| `subject` | Who the credential names, a user id as text; empty for a session for nobody |
| `via` | The guard that read it: `signed`, `bearer`, or one an extension adds |
| `credential` | The session or token id, to revoke it |
| `scopes` | The scopes it carries; empty for the app's own means all |
| `audience` | The [resource](#protected-resources) it was issued for; empty for the app's own |
| `client` | The OAuth client holding it; empty for the app's own |
| `guest` | Whether it is a session nobody signed in on yet |

A few helpers read these for you. `anonymous()` tells a session for nobody apart, `number()` gives the subject as an `int64` for apps with integer ids, and `firstParty()` is true for credentials your app issued to its own frontend or command line. To guard an action by scope, you may write:

```echo
$me = try $payload->state<Caller>();
try $me->identity->require('posts:write');
```

`require` is a `403` unless the credential carries the scope. Your own sessions and tokens issued without scopes carry every scope; a token an [OAuth client](./oauth.md) holds carries only what the user granted.

## Bearer tokens

Sometimes signing every request is more ceremony than the client deserves: a deploy script, a cron job on another machine, a command line tool. For those, you may issue a bearer token. Ask for `nexus::auth::Tokens` and call `issue`. The blog takes signed sessions only, so picture this action in an app that keeps the default guards:

```echo
#[nexus::through: ["Blog::Middleware::RequireUser"]]
public class IssueToken : nexus::Action
{
    private nexus::auth::Tokens $tokens;

    public constructor(nexus::auth::Tokens $tokens)
    {
        $this->tokens = $tokens;
    }

    public function handle(nexus::Payload& $payload) : result<nexus::Response, nexus::Problem>
    {
        $me = try $payload->state<Caller>();
        $issued = try $this->tokens->issue("{$me->user->id}", name: 'cli');
        return .ok(nexus::Response(json: $issued->json(), status: 201));
    }
}
```

The answer is `{"token": "...", "id": "...", "expires_at": "..."}`, and this is the only time the token's text is seen. The client then sends it as `Authorization: Bearer <token>`. You may pass `scopes:` to `issue` to limit what the token may do. A token with scopes also stays away from what stands for the whole user: [nexus-oauth's](./oauth.md) consent and grants endpoints answer it with a `403`, so it cannot hand an app more than it holds.

A token reads `<prefix>_<id>_<secret>`: your prefix, 12 hex characters that find the record, and 64 hex characters of secret, as in `blog_3f9a1c2e5d7b_...`. The store keeps only the SHA-256 of the secret and compares it in constant time. Tokens are long and random, so a fast hash is all a lookup needs. The fixed prefix is there so you, and secret scanners, can recognise a leaked token at a glance.

The prefix must be 1 to 16 lowercase letters and digits. `nxo` and `nxr` are taken by OAuth's own tokens, so the boot refuses them.

Tokens live 30 days by default. Set `NEXUS_AUTH_TOKENS` to change that, or to `0` for tokens that never expire. Revoke one with `Tokens::revoke($id)`, or every token of a user with `Tokens::revokeAll($subject)`.

### Choosing guards

Each kind of credential is read by a guard. By default the extension takes both, signed sessions first:

```echo
// both, the default
nexus::auth::Extension('blog'),

// signed sessions only, as the blog runs
nexus::auth::Extension('blog', guards: [nexus::auth::BuiltinGuard::signed]),
```

A guard that finds no credential of its kind lets the next one look. A credential of its kind that does not hold (unknown, expired, tampered with) is a `401` straight away, never quietly treated as an anonymous request. A bearer token with a different prefix is left alone for later guards, which is how [nexus-oauth](./oauth.md) adds a guard for its `nxo_` tokens beside yours.

You may bring a guard of your own, conforming to `nexus::auth::Guard`, with `extra: [...]`. Guards are shared by every worker thread, so they keep no per-request state in fields.

::: details Older clients: `compat: true`
With `compat: true`, the signed guard also reads an `X-AccessToken` header: base64 JSON of `{token, timestamp, signature}`, signing `METHOD:target:time` **without the body**. It exists for clients written against an older scheme. Leave it off unless you have such clients, since the body is then not covered by the signature.
:::

## Passwords

nexus-auth hashes passwords with **Argon2id**, in the PHC string format every Argon2 implementation reads. Ask for `nexus::auth::Passwords`, check the length, and store the hash:

```echo title="src/Actions/Users/Register.eco"
try $this->passwords->acceptable($r->password);
$hash = try $this->passwords->hash($r->password);
```

`acceptable` answers a `422` on the `password` field when the password is shorter than 10 or longer than 200 bytes. The default cost is 64 MiB of memory and 3 passes on one lane, around a tenth of a second on a laptop. You may pass your own `crypto::PasswordCost` as `cost:` to the extension; the blog's unit tests use a tiny one so they stay fast:

```echo
nexus::auth::Extension('blog', cost: crypto::PasswordCost(8, 1), guards: [nexus::auth::BuiltinGuard::signed]),
```

When you raise the cost later, `needsRehash` tells you which stored hashes are older, so you may hash the password again right after a successful login.

### The decoy check

A login for an email nobody has would normally answer much faster than one with a wrong password, because there is no hash to check. That difference tells an attacker which emails have accounts. `Passwords` holds a decoy hash for this: for an unknown account, you check the password against the decoy, and the answer takes as long as a real one. `Logins::unknown` does it for you, as the next section shows.

## Throttling logins

Without a limit, anyone may try passwords as fast as your server answers. `nexus::auth::Logins` counts failed logins three ways:

| Throttle | Limit |
|:--|:--|
| Per client address | 30 failures in 15 minutes |
| Per account, from one address | 10 failures in 15 minutes |
| Per account, from everywhere | 100 failures an hour |

The middle one locks an account from one address long before a stranger elsewhere could lock its owner out with the last. An attempt is counted when it starts, so a burst of parallel attempts cannot slip under the limit, and a login that works gives its attempt back, so only failures add up. A refused attempt is a `429` with a `Retry-After` header.

Here is the blog's `SignIn` service, which uses all of it:

```echo title="src/Services/SignIn.eco"
public function check(nexus::Payload& $payload, const Credentials& $in) : result<User, nexus::Problem>
{
    try $this->logins->attempt($payload, $in->email);
    $found = try $this->users->find()->where(UserTable::$email == $in->email)->first();
    $u = guard $found else {
        return .error($this->logins->unknown($in->password));
    };
    if ($u->passwordHash->empty()) {
        return .error($this->logins->unknown($in->password));
    }
    try $this->logins->verify($payload, $in->email, $in->password, $u->passwordHash);
    if ($this->logins->passwords->needsRehash($u->passwordHash)) {
        $hash = try $this->logins->passwords->hash($in->password);
        $u->passwordHash = mv $hash;
        try $this->users->save($u);
    }
    return .ok($u);
}
```

Notice that `attempt` runs before the user is looked up, so a flood never reaches your database. An unknown email, a user without a password (one who only signs in [with Google](./connect.md)) and a wrong password all get the same `401` with the reason `wrong_credentials`, after the same amount of work.

Two things are worth knowing. The counts live in each server process, so with several servers each one counts on its own. And the address is the request's peer: behind a reverse proxy, set `NEXUS_HTTP_TRUSTED_PROXIES` so the real client address is read from `X-Forwarded-For`, or every visitor shares the proxy's address and its limit. [The HTTP server](./http.md) covers that setting.

## Protected resources

Some parts of your app are meant for other programs: the `/mcp` endpoint for [MCP tools](./mcp.md), a public API for partners. nexus-auth calls these **resources**. Each one has a name, the path it starts at, the scopes a client may ask for, and protected resource metadata (RFC 9728) at `/.well-known/oauth-protected-resource<path>`.

An extension that serves a resource adds it from its `services`; nexus-mcp adds `/mcp` this way:

```echo
$s->get<nexus::auth::Resources>()->add($s, nexus::auth::Resource('api', '/v1', ['posts:read', 'posts:write'], 'Blog API'));
```

Resources change two things:

- **A token issued for a resource opens that resource only.** A token an OAuth client got for `mcp` is a `401` with the reason `wrong_resource` anywhere else. Your own sessions and tokens still open everything.
- **A `401` under a resource tells the client where to sign in.** It carries `WWW-Authenticate: Bearer resource_metadata="..."` pointing at the metadata, which names the authorization server. That is how an MCP client finds your sign in page by itself.

[nexus-oauth](./oauth.md) says this app issues the tokens, and is the usual way to use resources. If your tokens come from an authorization server elsewhere, `Resources::issuedBy($url)` names it instead; you then bring a guard that reads its tokens. Either way the metadata and the resource URLs are built on the public origin, so in production the boot needs `NEXUS_APP_URL` ([deployment](./deployment.md) explains why).

## When a credential ends

Some things hold on to an identity long after its request: an open websocket, a server-sent event stream. When the user signs out, those should close too. `nexus::auth::Endings` tells you whenever a session or token ends, through a sign out, a revoke, or a `closeAll` after a password change:

```echo title="src/App.eco"
// a sign in that ends closes the streams opened with it
StatsFeed $feed = StatsFeed();
$app->instance($feed);
$app->get<nexus::auth::Endings>()->listen(function[$feed](nexus::auth::Ending $e) : void {
    $feed->ended($e);
});
```

A `nexus::auth::Ending` is either one credential or every credential of a subject, and `$e->covers($identity)` says whether an identity you kept was read from it. A listener runs on the thread that ended the credential, in that process, and cannot fail the sign out, so one with slow work to do should hand it on. [Realtime channels](./realtime.md) listen the same way to close their sockets.

## Pruning expired credentials

Expired sessions and tokens are refused right away, but their rows stay until something deletes them. `nexus::auth::Pruning` gathers every auth store that expires: nexus-auth adds its tokens and sessions, [nexus-oauth](./oauth.md) its requests, codes and grants, [nexus-connect](./connect.md) its sign-in attempts. You may prune them all by hand:

```bash
./ecobuild/blog auth:prune
```

It prints what it removed from each store, and is safe to run any time. The blog runs the same thing nightly as a task:

```echo title="src/Tasks/PruneAuth.eco"
public struct PruneAuth : nexus::work::Task
{
    public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
    {
        $done = guard $payload->get<nexus::auth::Pruning>()->run($payload) else ($p) {
            return .error(.retry("pruning: {$p->detail(.dev)}"));
        };
        foreach ($done as const &$d) {
            $payload->log->info('pruned', ['what' => $d->name, 'count' => $d->count as int64]);
        }
        return .ok;
    }
}
```

```echo title="src/Providers/AuthProvider.eco"
$app->schedule(PruneAuth())->cron('0 3 * * *')->into<JobLane>();
```

[Scheduling](./scheduling.md) explains the schedule, and [tasks and queues](./tasks.md) the task itself.

## Keeping credentials in the database

By default, sessions and tokens live in memory: fine for tests and a quick start, gone on every restart, and not shared between servers. For anything real, keep them in your database with nexus-auth-carbon. It needs three small steps, all of which the blog has.

First, set the auth extension to `stores: .provided` and list `nexus::auth::carbon::Extension()` after it, as shown at the top of this page. Next, register the auth tables on the database where your app opens it:

```echo title="src/DB/Database.eco"
try nexus::auth::carbon::Tables::wire($db);
```

Finally, add the migration to your own, in front of your app's:

```echo title="src/DB/Database.eco"
$all = nexus::auth::carbon::Tables::migrations();
// ... the other modules' migrations
$all->extend(Blog::DB::Migration::Carbon::migrations());
```

If you forget the wiring, the boot stops with a message that tells you the line to add. The migration creates two tables. `auth_tokens` holds each token's id, the SHA-256 of its secret, its subject, name, scopes and expiry. `auth_sessions` holds each session's id, its subject (null for nobody), scopes and expiry, and no secret at all. Both stores work on each request's database session, so they follow your [database](./database.md) setup.

## Settings

Durations are written like `30d`, `12h` or `90m`. [Configuration](./configuration.md) has the details.

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_AUTH_KEY` | none, required | The server secret every session secret is derived from, at least 32 characters. Changing it ends every signed session. |
| `NEXUS_AUTH_TOKENS` | `30d` | How long a bearer token lives; `0` for never. |
| `NEXUS_AUTH_SESSIONS` | `30d` | How long a signed in session lives from its last use. |
| `NEXUS_AUTH_GUESTS` | `1h` | How long a session for nobody lives from its last use. Signing in gives it the lifetime of `NEXUS_AUTH_SESSIONS`. |

Treat `NEXUS_AUTH_KEY` like a database password: anyone who has it can derive the secret of any session whose id they know.

## Where to next

- [OAuth server](./oauth.md): letting MCP clients and other apps sign in to your resources.
- [Sign in with Google](./connect.md): signing users in with an outside provider, onto the same session.
- [Middleware](./middleware.md): writing middleware that puts state, like `RequireUser`.
- [Testing](./testing.md): opening signed sessions in integration tests.
