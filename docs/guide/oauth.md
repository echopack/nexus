---
description: An OAuth 2.1 authorization server for your app's protected resources, so an MCP client or a partner app connects with a URL and a click instead of a pasted token.
---

# OAuth server

Sooner or later someone wants to reach your app from a program you did not write: an MCP client that should create posts on your behalf, an editor plugin, a script a colleague runs. You could hand out long-lived API tokens and ask people to paste them into a settings box. That works, but every token can do everything the user can, it lives forever, and nobody remembers which one went where.

OAuth is the standard answer. The client sends the user to your app, the user says "yes, this app may do that", and the client gets a token that opens one part of your app, for a limited time, and can be taken back from an account page. nexus-oauth is that authorization server, built for the parts of your app that [nexus-auth](./auth.md) calls *resources*: the `/mcp` endpoint of [MCP tools](./mcp.md), or an API you declare yourself.

If OAuth has always looked like a wall of RFCs, don't worry. Most of it is handled for you. Your part is one extension line and one small page in your frontend that asks the user.

To add it, require the module in your app's `module.eco`. The carbon store is a separate module, so you may run in memory first and add the database later:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/oauth" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/oauth/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list its extensions after nexus-auth's, since nexus-oauth adds its guard to nexus-auth's:

```echo title="src/Extensions.eco"
nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),
nexus::auth::carbon::Extension(),

// OAuth 2.1 for the blog's resources (the MCP endpoint), so an MCP client signs in with a
// click instead of a pasted token; the stores come from the next line
nexus::oauth::Extension(stores: .provided),

// keeps OAuth clients, requests, codes and grants in the database
nexus::oauth::carbon::Extension(),

// the `/mcp` endpoint that offers the blog's tools to models
nexus::mcp::Extension(),
```

The boot checks your wiring for you. Listing nexus-oauth before nexus-auth, forgetting a store, or having no resource at all stops the boot with a message that says which.

## How a client connects

Before any code, let's follow one connection from start to finish, because every endpoint below is one step of it. Say an MCP client wants to use the blog:

1. The client calls `POST /mcp` without a token and gets a `401` with `WWW-Authenticate: Bearer resource_metadata="..."`. The metadata (nexus-auth's, see [authentication](./auth.md)) names your app as the authorization server.
2. It reads `/.well-known/oauth-authorization-server` (RFC 8414) to find the endpoints, and registers itself at `POST /oauth/register`.
3. It opens the user's browser at `/oauth/authorize` with a PKCE challenge, the resource it wants, and the scopes.
4. nexus-oauth checks the request, keeps it, and redirects the browser to **your consent page** with `?request=<id>`.
5. Your page, signed in as the user, reads `GET /oauth/requests/{id}`, asks the user, and answers `POST /oauth/requests/{id}` with `{"allow": true}`. The answer says where the browser goes next: back to the client, with a code.
6. The client trades the code and its PKCE verifier at `POST /oauth/token` for an access token (`nxo_...`) and a refresh token (`nxr_...`).
7. It calls `/mcp` with `Authorization: Bearer nxo_...`.

Only step 5 is yours. Everything else is routed by the extension.

## The consent page

The consent page is part of your frontend, the same page your users already sign in on. By default nexus-oauth sends the browser to `/oauth/consent`; you may name your own page, relative to your app's origin or absolute:

```echo title="src/Extensions.eco"
nexus::oauth::Extension(consent: '/connect', stores: .provided),
```

The page gets `?request=<id>`. It calls the two request endpoints with your app's own credential, the session or token it signs every other request with. When nobody is signed in yet, those answer `401`, and the page should sign the user in first and come back. Here is the whole thing, written with the blog page's `api()` helper, which signs each request:

```js
const id = new URLSearchParams(location.search).get('request');

// who asks, for what: show this to the user
const asked = await api('GET', `/oauth/requests/${id}`);

// on "Allow" (or "Deny", with allow: false)
const answer = await api('POST', `/oauth/requests/${id}`, { allow: true });
location = answer.redirect;
```

`GET /oauth/requests/{id}` tells the page everything it should show:

```json
{"id": "...", "client": {"id": "...", "name": "Claude"}, "redirect": "https://...",
 "resource": {"name": "mcp", "title": "Blog", "url": "https://blog.example.com/mcp"},
 "scopes": ["mcp"], "granted_before": false}
```

`granted_before` is `true` when this user already allowed this client the same scopes on the same resource, and that grant has not run out. You may skip the question then and answer right away.

A few things hold no matter what your page does:

- A request lives for **ten minutes** and is answered **once**. Allowing or denying removes it; a second answer is a `404`.
- Both endpoints sit behind `nexus::auth::Authenticate`, so only a signed in caller reaches them, and a code is issued to *that* caller's subject.
- Only your app's own credential **without scopes** may read or answer a request, the session or token that stands for all of the user. A token you issued with `scopes: ['posts:read']` gets a `403` here: allowing a client is handing out access, and a token that may only read posts must not hand out more than that. The grants endpoints below hold to the same rule.
- An OAuth access token cannot answer a consent request or manage grants. Those endpoints are not part of any resource, and nexus-auth refuses a resource token anywhere outside its resource.

Denying sends the browser back to the client with `error=access_denied`.

## Resources and scopes

Every token nexus-oauth issues opens **one** resource. A resource is a path prefix with a name and the scopes a client may ask for, declared on `nexus::auth::Resources`. [MCP tools](./mcp.md) add one for you: `mcp` at `/mcp`, with the single scope `mcp`.

Suppose you would also like partner apps to read and write posts through the blog's JSON API. You may declare `/v1` as a resource from a small extension of your own:

```echo title="src/ApiResource.eco"
namespace Blog;

/**
 * The blog's API as an OAuth resource: clients may ask for posts:read and posts:write on /v1.
 */
public class ApiResource : nexus::Extension
{
    public function name() : string
    {
        return 'blog-api';
    }

    public function services(nexus::Services& $s) : status<nexus::BootError>
    {
        array<string> $scopes = ['posts:read', 'posts:write'];
        $s->get<nexus::auth::Resources>()->add($s, nexus::auth::Resource('api', '/v1', $scopes, 'Blog API'));
        return .ok;
    }
}
```

List it after `nexus::auth::Extension`, since that is where `nexus::auth::Resources` comes from.

### Which resource a client gets

The client names the resource with the `resource` parameter of RFC 8707: the resource's full URL on your public origin, such as `https://blog.example.com/v1` (a trailing slash is forgiven). It may leave it out only while your app has exactly one resource. With two or more, a request without one goes back to the client with `invalid_target`.

Scopes work the same way. A client that asks for none gets all of the resource's scopes; one that asks for a scope the resource does not offer gets `invalid_scope`.

### Checking scopes in an action

A token for `api` opens `/v1` and nothing else. Anywhere outside, nexus-auth answers `401` with the reason `wrong_resource`, before your action runs. Inside, the caller's `nexus::auth::Identity` carries what was granted: `audience` is the resource's name, `client` the client's id, and `scopes` the scopes the user allowed.

To check a scope, ask the identity:

```echo title="src/Actions/Posts/CreatePost.eco"
public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
{
    $me = try $payload->state<Caller>();
    try $me->identity->require('posts:write');
    // ...
}
```

`require` is a `403` unless the credential carries the scope. Your own frontend's sessions and tokens carry no scopes and open everything, so `require` lets them through; only an OAuth client is held to what the user allowed.

## Clients

### Clients that register themselves

Most clients, MCP clients in particular, register themselves through dynamic client registration (RFC 7591) at `POST /oauth/register`. Anyone may register, since registering grants nothing: a client can do only what a user later allows it.

Every client is a *public* client. It has no secret; PKCE proves that a code is its own. A registration that asks for anything else is refused:

| A registration may ask for | What nexus-oauth allows |
|:--|:--|
| `token_endpoint_auth_method` | `none` only |
| `grant_types` | `authorization_code`, `refresh_token` |
| `response_types` | `code` |
| `redirect_uris` | one to ten |

The client's name is what your consent page shows, so it is cleaned first: control characters and Unicode direction overrides are removed, it is cut to 100 bytes, and an empty one becomes `an app`.

Registration is open, so it is also bounded. Each address may register ten clients in fifteen minutes (a `429` with `slow_down` after that), there are at most `NEXUS_OAUTH_CLIENTS` clients at once (a `503` beyond), and a client that never traded a code or a token is swept an hour after it registered.

### Redirect URIs

Where a client's codes may go is the one thing that must never be wrong, so redirect URIs are strict:

- `https://` to any host.
- `http://` only to this machine: `localhost`, `127.0.0.1` or `[::1]`, for a desktop app's loopback listener. These match **on any port**, since the listener picks one when it starts (RFC 8252).
- An app's own scheme, such as `cursor://callback` or `com.example.app:/cb`.

`javascript:`, `data:`, `file:`, `vbscript:`, `about:` and `blob:` are refused, as are fragments, user info (`http://localhost:1@evil.example`), and anything over 2000 characters. A client may leave `redirect_uri` out of the authorization request only when it registered exactly one; if it named one, it must name the same one again when it trades the code.

When the client or its redirect is in doubt, nexus-oauth shows a `400` instead of redirecting, because sending the browser to an address nobody vouched for is exactly what must not happen. Every other refusal goes back to the client's redirect as an OAuth error, with the `state` it sent and the `iss` parameter of RFC 9207.

`/oauth/authorize` needs no sign in, and every request it accepts is kept for the consent page, so it is bounded too: thirty requests per address in fifteen minutes, then a `429`. A `state` over 500 bytes is refused with `invalid_request`, and that refusal leaves the state out rather than echo it back.

### Clients in code

Your own mobile or desktop app does not need to register at runtime. You may register it in code, with a fixed id:

```echo title="src/Extensions.eco"
nexus::oauth::Extension(stores: .provided, clients: [
    nexus::oauth::Client($id: 'blog-ios', $name: 'Blog for iOS', $redirects: ['com.example.blog:/oauth']),
]),
```

A client in code is found before the stored ones, and the boot checks each: one without a redirect, with a redirect that is not valid, or with an id that is empty or longer than 32 bytes (what the stores keep), stops it.

## Tokens

### Trading the code

The code your consent page hands back is 64 hex characters, valid for **one minute**, and kept only as its sha256 hash. The client trades it at `POST /oauth/token`, as a form (`application/x-www-form-urlencoded`, as OAuth has it):

```bash
curl -X POST https://blog.example.com/oauth/token \
  --data "grant_type=authorization_code&client_id=${client}&code=${code}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback&code_verifier=${verifier}"
```

PKCE is required and is **S256 only**: the authorization request carries `code_challenge=base64url(sha256(verifier))` with `code_challenge_method=S256`, and the token request the verifier itself, 43 to 128 unreserved characters, compared in constant time. A request with `plain` or without a challenge is refused.

The code is marked used the moment it is presented, before anything else is checked. So a token request with the wrong verifier spends the code too, and the client has to start over. That is deliberate: a code gets exactly one try.

A used code is not thrown away, though. It is kept until its minute is up, together with the grant it was traded for. When it comes back, somebody holds a copy of it, so nexus-oauth does what RFC 6749 (section 4.1.2) asks: the request gets `invalid_grant`, and the grant the code opened ends, its tokens with it. The user connects the app again.

### Access and refresh tokens

The answer is a pair:

```json
{"access_token": "nxo_...", "token_type": "Bearer", "expires_in": 3600,
 "refresh_token": "nxr_...", "scope": "mcp"}
```

Both read as `<prefix>_<id>_<secret>`: the grant's 12 hex id and 64 hex characters of secret. Only the sha256 of each secret is stored, compared in constant time. The prefixes make them easy to spot in a log or a secret scanner, and nexus-auth refuses `nxo` and `nxr` as prefixes for your app's own tokens.

An access token lasts an hour (`NEXUS_OAUTH_ACCESS`). The refresh token lasts thirty days from its last use (`NEXUS_OAUTH_REFRESH`), so a client in regular use stays connected.

### Refreshing, and reuse detection

A client renews its pair with `grant_type=refresh_token`, its `client_id` and the refresh token. Each refresh token is **single use**. The refresh replaces both tokens, so the previous access token stops working at once, and the client should switch to the new one right away.

So, what if a refresh token that was already spent comes back? Then somebody holds a copy of it, and there is no telling whether it is the client or a thief. nexus-oauth ends the whole grant: both the new tokens and the old stop working, the client gets `invalid_grant`, and the user has to connect the app again.

Two refreshes racing with the same token are not a theft. The store rotates the grant only if it still holds the refresh hash that was read, so one wins and the other gets `invalid_grant` without ending anything.

## Grants and disconnecting

What a user allowed a client is a *grant*: one client, one resource, the scopes. Your account page may list a signed in user's grants and let them disconnect one:

| Route | What it does |
|:--|:--|
| `GET /oauth/grants` | the user's grants: id, client and its name, resource, scopes, `created_at`, `used_at` |
| `DELETE /oauth/grants/{id}` | ends one of them; another user's grant is a `404` |

A client may also give its tokens back at `POST /oauth/revoke` (RFC 7009) with `token=...`, access or refresh. It ends the grant; a token that is not one of ours is no error.

When a grant ends, nexus-auth's `nexus::auth::Endings` hears of it, so whatever was opened with its access token, such as a [realtime](./realtime.md) socket, closes too. It works the other way as well: when a user signs out everywhere through one of your own guards, nexus-oauth drops every grant of theirs. You may do the same from your own code after a password change:

```echo
$me = try $payload->state<Caller>();
// ...the new password is saved...
try $payload->get<nexus::oauth::Grants>()->dropAll("{$me->user->id}");
```

## Keeping it in the database

With `stores: .memory` (the default) clients, requests, codes and grants live in the process and are gone when it stops. That is fine for tests. For anything real, nexus-oauth-carbon keeps them in your [database](./database.md). Wire its tables where you open the database and add its migration to yours:

```echo title="src/DB/Database.eco"
try nexus::oauth::carbon::Tables::wire($db);

// ...

$all->extend(nexus::oauth::carbon::Tables::migrations());
```

That adds four tables: `oauth_clients`, `oauth_requests`, `oauth_codes` and `oauth_grants`. A request is taken with a delete that only one caller wins, a code is marked used with an update that only one caller wins, and a refresh rotates a grant with an update conditioned on the refresh hash it read, so several servers never both spend one.

Expired requests, codes and grants are deleted by nexus-auth's pruning, under the name `oauth requests, codes and grants`. [Authentication](./auth.md) shows the `auth:prune` command and how the blog runs it every night.

## Settings

The issuer is your app's public origin. In production the boot needs `NEXUS_APP_URL` for it, so the metadata clients trust is never built from a `Host` header a client sent.

| Variable | Default | What it sets |
|:--|:--|:--|
| `NEXUS_OAUTH_ACCESS` | `1h` | how long an access token lasts |
| `NEXUS_OAUTH_REFRESH` | `720h` | how long a refresh token lasts from its last use |
| `NEXUS_OAUTH_CLIENTS` | `1000` | how many clients may be registered at once |
| `NEXUS_APP_URL` | (none) | the issuer; required in production |

Durations read as `30s`, `5m`, `2h` or `30d`. The consent page is not an environment setting; you name it where you list the extension. [Configuration](./configuration.md) covers how settings are read.

## Where to next

- [Authentication](./auth.md): guards, sessions, and the resource metadata a client finds first.
- [MCP tools](./mcp.md): the resource most OAuth clients come for.
- [Sign in with Google](./connect.md): the other direction, your users signing in with someone else's accounts.
