---
description: Let people sign in with Google or any OpenID Connect provider, without cookies, and find, link or create the user they are.
---

# Sign in with Google

Many people would rather not invent yet another password for your app. "Sign in with Google" is the button they look for. Behind that button sits OpenID Connect: a redirect to the provider, a code coming back, a token exchange, an ID token to check, and then the question of which of *your* users this person is. Each of those steps has a well-known way to go wrong.

nexus-connect walks that path for you. It is an OpenID Connect relying party with a `Google()` preset and a generic `Oidc` connector for any other provider. It is built for nexus apps that sign every request instead of using cookies, so the whole flow works with the sessions from [authentication](./auth.md) and never sets a cookie.

To add it, require the module in your app's `module.eco`, plus its carbon store when you keep sign-ins in your database:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/connect" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/connect/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list its extensions after nexus-auth's:

```echo title="src/Extensions.eco"
// sign in with Google, once NEXUS_CONNECT_GOOGLE_CLIENT_ID and _SECRET are set; the
// browser comes back to /signed-in, which posts the attempt to POST /v1/auth/connect, signed
// with its session
nexus::connect::Extension(page: '/signed-in', connectors: [nexus::connect::Google()], stores: .provided),

// keeps sign-in attempts and the Google accounts linked to users in the database
nexus::connect::carbon::Extension(),
```

## How a sign in flows

Let's walk through one sign in before looking at code. There are three parties: your frontend, the provider, and your app. nexus-connect owns the middle of the flow, and your app owns both ends.

1. Your frontend calls `POST /auth/connect/google`. The answer holds the provider's URL, an attempt id, and a **binding** secret the frontend keeps.
2. The frontend sends the browser to that URL. The person signs in at Google.
3. Google sends the browser back to `/auth/connect/google/callback`. nexus-connect trades the code, checks the ID token, keeps who signed in on the attempt, and sends the browser on to your page with the attempt and a fresh **proof**: `/signed-in?attempt=<id>&proof=<proof>`.
4. Your page posts the attempt, the proof and the binding to an action of your own. That action claims the attempt with `nexus::connect::Connect::claim`, finds or creates the user, and signs them in the way your app always does.

Why two secrets? The attempt id is not one: it travels through URLs and the browser history. Each of the other two proves something different. The **binding** proves who *started* the sign in: it never leaves the browser that called `POST /auth/connect/google`. The **proof** proves who *came back*: nexus-connect makes it when the provider sends the browser back, and hands it to that browser only. A claim needs both, so it works only where one browser did both halves.

Here is what that stops. An attacker starts a sign in, keeps the binding, and sends the provider's URL to a victim. The victim signs in at Google, and their browser lands on your page. With the binding alone, the attacker could now claim the attempt and walk off with the victim's identity. But the proof went to the victim's browser, not to the attacker, so the attacker's claim gets a `401`. The victim's page has the proof but not the binding, so its claim fails too. Nobody is signed in as anybody they are not. The store keeps only the proof's sha256 hash, and compares it in constant time like the binding.

## Setting up Google

In your Google Cloud project, create an OAuth client of type "Web application". Its authorized redirect URI is your app's public origin plus the callback path:

```txt
https://blog.example.com/auth/connect/google/callback
```

Then give your app the client's id and secret:

```bash
NEXUS_CONNECT_GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
NEXUS_CONNECT_GOOGLE_CLIENT_SECRET=...
```

Until `NEXUS_CONNECT_GOOGLE_CLIENT_ID` is set, Google is simply left out: `POST /auth/connect/google` answers `404`, and your app runs as before. That keeps development painless. Setting the id without the secret stops the boot, so a half-configured deploy never goes live.

`Google()` asks for `openid email profile`, and it is trusted to vouch for email addresses, since Google owns the addresses it verifies. More on why that matters under "Finding the user" below.

## Starting from the frontend

The start answers with everything the frontend needs:

```json
{"url": "https://accounts.google.com/o/oauth2/v2/auth?...", "attempt": "...", "binding": "...", "expires_at": "..."}
```

The frontend keeps the binding in `sessionStorage` and sends the browser on its way:

```js
const started = await (await fetch('/auth/connect/google', { method: 'POST' })).json();
sessionStorage.setItem('connect.binding', started.binding);
location = started.url;
```

The start needs no session, but it is throttled: thirty starts per address in fifteen minutes, then a `429`. An attempt lasts **ten minutes** from its start.

When the browser lands on your page, it posts the attempt, the proof and the binding. The blog's page would do that with its `api()` helper, which signs the request with the browser's session like any other request under `/v1`:

```js
const params = new URLSearchParams(location.search);
// the proof is a secret: keep it out of the history and of any Referer
history.replaceState(null, '', location.pathname);
if (params.get('error')) {
  // access_denied: the person said no; failed or expired: start again
}
const binding = sessionStorage.getItem('connect.binding');
const me = await api('POST', '/v1/auth/connect', { attempt: params.get('attempt'), proof: params.get('proof'), binding });
```

The page may get `?error=` instead of a usable attempt: `access_denied` when the person declined at the provider, `failed` when the code or the ID token did not hold, and `expired` when the attempt was unknown, too old, or already settled. With `access_denied` and `failed`, the attempt and its proof come along too, so a claim can tell you why.

## Claiming the sign in

Now we are ready for the app's side. The action needs an input for what the page posts:

```echo title="src/Inputs/OutsideSignIn.eco"
namespace Blog::Inputs;

/**
 * What the page `/signed-in` posts once a provider sent the browser back: the attempt and its proof
 * from its query, and the binding it kept when the sign in started.
 */
#[nexus::input]
public struct OutsideSignIn
{
    #[nexus::rule: { min: 1, max: 64 }]
    public string $attempt;

    #[nexus::rule: { min: 1, max: 128 }]
    public string $proof;

    #[nexus::rule: { min: 1, max: 128 }]
    public string $binding;
}
```

The action claims the attempt, asks `nexus::connect::Accounts` which user it is, and puts that user on the session the request is signed with:

```echo title="src/Actions/Auth/SignInWith.eco"
public function handle(nexus::Payload& $payload, nexus::Body<OutsideSignIn> $in) : result<nexus::Response, nexus::Problem>
{
    $session = try $payload->state<nexus::auth::Identity>();
    if (!$session->anonymous()) {
        return .error(nexus::auth::Sessions::taken());
    }
    $who = try $this->connect->claim($in->value->attempt, $in->value->binding, $in->value->proof);
    $subject = try $this->accounts->of($who, BlogUsers($this->users, $this->signals, $payload->locale()));
    try $this->sessions->attach($session->credential, $subject);
    $user = try BlogUsers::of($this->users, $subject);
    return $this->transformer->own($payload, $user, nexus::rest::Meta());
}
```

The blog routes it at `POST /v1/auth/connect`, where `nexus::auth::RequireSession` has already left the session's identity in the payload. A session that somebody signed in on already takes nobody else, hence the `409` from `nexus::auth::Sessions::taken()`. The last steps are the same as a password sign in; [authentication](./auth.md) covers sessions and `attach`.

`claim` hands out an attempt **once**, and it is careful about what it says:

| Claim | Answer |
|:--|:--|
| the binding does not match | `401`, reason `sign_in_elsewhere`; the attempt stays for its own browser |
| the proof does not match | `401`, reason `sign_in_elsewhere`; the attempt stays as well |
| the provider has not sent the browser back yet | `409` |
| the sign in failed or was declined | `401`, reason `sign_in_failed` |
| unknown, expired, or already claimed | `404` |

On success you get a `nexus::connect::ExternalIdentity`: the `provider`, its `subject` (the provider's `sub`, stable and never reused), `email`, `emailVerified`, `name`, and every claim of the ID token in `claims`, for things like `picture` or `locale`.

## Finding the user

Which of your users is this person? `nexus::connect::Accounts::of` decides:

1. If this outside identity is **linked** to a user, it is that user.
2. Else the provider has to have **verified** the email. If it did not, the answer is a `403` (`nexus::connect::Accounts::unverified($provider)`), and nothing is made or linked.
3. Else, if a user has the same email **and your app verified it too**, it is that user, and the identity is linked to them now.
4. Else, if a user has the email but your app never verified it, the answer is a `409` (`nexus::connect::Accounts::taken()`): the person should sign in with their password first.
5. Else a new user is made and linked.

Steps 3 and 4 are the one part you choose, with `emailLinking:` on the extension:

```echo
nexus::connect::Extension(page: '/signed-in', connectors: [nexus::connect::Google()], emailLinking: .verified),
```

| `emailLinking` | A verified sign in whose email a user has |
|:--|:--|
| `.verified` (the default) | links to that user only when `Users::emailVerified` says your app verified their email too, else `409` |
| `.always` | links to that user, whatever your app knows about their email |
| `.never` | never links: always `409`, and the person signs in with their password |

Pick `.always` only when no account of yours can hold an address its owner never confirmed: every sign up confirms by mail before the account exists, or accounts are only ever made through providers. Otherwise it brings back the attack below. Step 2 is not a choice: an email the provider did not verify never makes or opens an account.

Every step that touches an existing account asks for two verified addresses, and here is why. Some providers let anybody put any address on their account. If an unverified email could open an account, an attacker could put your address on theirs and walk into your account. If it could *make* one, they could make the account first, in your name, and wait: the day you sign in with Google, your verified email would link to the account they opened, and they would still be in it. The same goes the other way round: an account somebody opened with your address and a password, never confirming it, is not yours yet, so Google vouching for you does not hand it to you either.

A provider that shared no email gives a `403` as well, for an identity that is not linked yet.

A link whose user was deleted is dropped, and the sign in carries on as if it never existed.

### Your app's users

`Accounts` holds the policy; finding and making users is yours, through the `nexus::connect::Users` interface. Its methods speak in subjects (a user's id as text, the way tokens name it):

```echo title="src/Services/BlogUsers.eco"
public class BlogUsers : nexus::connect::Users
{
    // ...

    public function withEmail(const string& $email) : result<string?, nexus::Problem>
    {
        $found = guard $this->users->find()->where(UserTable::$email == $email)->first() else ($e) {
            return .error(nexus::carbon::Problems::of($e));
        };
        $u = guard $found else {
            return .ok(null);
        };
        return .ok("{$u->id}");
    }

    public function create(const nexus::connect::ExternalIdentity& $who) : result<string, nexus::Problem>
    {
        string $name = $who->name;
        if ($name->empty()) {
            $name = $who->email->sub(0, $who->email->find('@'))->clone();
        }
        $made = guard $this->users->create(User($email: $who->email, $name: $name)) else ($e) {
            if ($e->duplicate()) {
                return .error(nexus::connect::Accounts::taken());
            }
            return .error(nexus::carbon::Problems::of($e));
        };
        try $this->signals->send(UserRegistered($user: $made->id, $locale: $this->locale));
        return .ok("{$made->id}");
    }
}
```

`exists($subject)` says whether a user is still there. A new user from a provider has no password, and `create` is the place for whatever else a new user gets: the blog sends the same `UserRegistered` [signal](./signals.md) a password sign up sends, so the welcome mail goes out either way. If a user took the email in the meantime, return `Accounts::taken()`.

The fourth method, `emailVerified($subject)`, says whether your app knows that user owns their email; only `emailLinking: .verified` asks it. It answers `false` unless you write it, so an app that never confirms addresses (the blog is one) never links an account by email: its people sign in with their password, and only new addresses make new users. An app that mails a confirmation link keeps when it was followed, and says so:

```echo title="src/Services/Users.eco"
public function emailVerified(const string& $subject) : result<bool, nexus::Problem>
{
    $u = try Users::of($this->users, $subject);
    return .ok($u->emailVerifiedAt != null);
}
```

A user `create` made came from a provider that verified the address, so set that mark there too.

### Links

Links live in a `nexus::connect::LinkStore`, keyed by provider and the provider's subject. A user may have several, one per provider account. nexus-connect routes no endpoints for them, but an account page of yours may list them with `of($subject)` and remove one with `unlink($provider, $external)`, reached through `$payload->get<nexus::connect::LinkStore>()`.

## Other providers

Any OpenID Connect provider works through `nexus::connect::Oidc`. Give it a name (the `{provider}` in the URLs), the issuer, and your client's id and secret:

```echo title="src/Extensions.eco"
array<nexus::connect::Connector> $providers = [
    nexus::connect::Google(),
    nexus::connect::Oidc('acme', issuer: 'https://login.acme.example', client: 'blog', secret: 'a-client-secret'),
];

// ...

nexus::connect::Extension(page: '/signed-in', connectors: $providers, stores: .provided),
```

The callback for this one is `/auth/connect/acme/callback`. Unlike `Google()`, `Oidc` reads no environment variables of its own; it takes the id and secret as you give them. Without `authorize:` and `token:` endpoints, it reads them once from the issuer's `/.well-known/openid-configuration` and keeps them. A discovery document that names another issuer is refused.

You may also pass `scopes:` (the default is `openid email profile`) and `trustsEmail:`. That last one is `false` by default, and it matters: an untrusted provider's `email_verified` is ignored, so its sign ins neither link an existing account by email nor make a new one; only an identity already linked signs in. Only set it for a provider that owns the addresses it verifies.

The issuer and endpoints must be `https`, or plain `http` on `localhost` for a provider you run locally; anything else stops the boot.

## What is checked, and how

Signing in is where shortcuts hurt most, so here is exactly what nexus-connect does:

- **State.** Each attempt gets a random 32 byte `state`; the callback finds the attempt by it. The store keeps only its sha256 hash.
- **PKCE.** Each attempt has its own verifier, sent as an S256 challenge; the code is traded with the verifier *and* your client secret.
- **Nonce.** Each attempt has its own nonce, which the ID token must carry, compared in constant time.
- **The ID token.** It is checked as OIDC Core 3.1.3.7 asks: `iss` is the provider, `aud` holds your client id (and `azp` is your client when there are several audiences or it is present), `exp` has not passed and `iat` is not in the future, each with five minutes of leeway, and `sub` is present.
- **The binding.** Kept as its sha256 hash and compared in constant time when the attempt is claimed. It proves the claim comes from the browser that started the sign in.
- **The proof.** A random 32 byte value made when the provider sends the browser back, put only in the redirect to your page, kept as its sha256 hash and compared in constant time. It proves the claim comes from the browser that came back.
- **Once only.** The first callback settles an attempt; any later one gets `?error=expired`. The claim spends it.

The ID token's signature is not checked. The token comes straight from the provider's token endpoint over TLS, which nexus-connect verifies, and OIDC Core lets that stand in for the signature. The nonce and the PKCE verifier are kept on the attempt as they are, since the callback needs them; they are worthless once the ten minutes are up.

Callbacks arrive as a `GET` with the code in the query, or as a `POST` with a form for providers using `response_mode=form_post`. Both are routed.

## Keeping it in the database

With `stores: .memory` (the default) attempts and links live in the process. nexus-connect-carbon keeps them in your [database](./database.md). Wire its tables where you open the database and add its migration to yours:

```echo title="src/DB/Database.eco"
try nexus::connect::carbon::Tables::wire($db);

// ...

$all->extend(nexus::connect::carbon::Tables::migrations());
```

That adds `connect_attempts` and `connect_links`. An attempt is claimed with a delete only one caller wins, so two servers never both sign someone in with it. A link is keyed by the sha256 hex of `<provider>:<subject>`, not the text: MySQL's default collation compares text ignoring case and accents, so a provider's person `Alice` would otherwise find the link of `alice`. If you ran an earlier version, its migrations rekey the links you have. Expired attempts are deleted by nexus-auth's pruning, under the name `sign-in attempts`; see [authentication](./auth.md) for `auth:prune`.

## Testing a sign in

You don't need Google in your tests. `nexus::connect::ScriptedFetch` stands in for the provider: it answers what the test scripts and keeps what was sent. The blog's integration tests boot the real app with it in place:

```echo title="tests/integration/World.eco"
$google = nexus::connect::ScriptedFetch();
$this->app = TestApp(Blog::extensions(), mv $vars, replace: $google->replacing());
```

`signedIn` scripts a token endpoint that answers as if the person signed in, filling in the nonce and audience from the URL the start answered, so a test speaks in claims rather than HTTP:

```echo title="tests/integration/ConnectFlowTest.eco"
$started = $browser->post('/auth/connect/google', json: '{}')->status(201);
$url = $started->capture('$.url');
$attempt = $started->capture('$.attempt');
$claims = json::object(['iss' => 'https://accounts.google.com', 'sub' => 'g-1', 'email' => 'grace@example.com', 'name' => 'Grace Hopper']);
$claims['email_verified'] = json::bool(true);
$world->google->signedIn(nexus::connect::Google::TOKEN, $url, $claims);
$page = $browser->get('/auth/connect/google/callback', query: ['state' => nexus::connect::ScriptedFetch::param($url, 'state'), 'code' => 'from-google'])
    ->status(302)
    ->header('Location', starts: "http://app/signed-in?attempt={$attempt}&proof=")
    ->capture(header: 'Location');
$proof = nexus::connect::ScriptedFetch::param($page, 'proof');
$claim = json::object(['attempt' => $attempt, 'proof' => $proof, 'binding' => $started->capture('$.binding')]);
$browser->post('/v1/auth/connect', json: $claim)->status(200);
```

[Testing](./testing.md) shows how the blog boots its app for tests like this one.

## Settings

| Variable | Default | What it sets |
|:--|:--|:--|
| `NEXUS_CONNECT_GOOGLE_CLIENT_ID` | (none) | your Google OAuth client's id; Google is left out without it |
| `NEXUS_CONNECT_GOOGLE_CLIENT_SECRET` | (none) | its secret, required once the id is set |
| `NEXUS_APP_URL` | (none) | the public origin the callback is built on; required in production |

In production the boot needs `NEXUS_APP_URL`, so the redirect a provider is sent never comes from a `Host` header a client chose. [Configuration](./configuration.md) covers how settings are read.

## Where to next

- [Authentication](./auth.md): sessions, signing requests, and password sign in.
- [OAuth server](./oauth.md): the other direction, letting other apps sign in to yours.
- [Signals](./signals.md): reacting when a new user signs up.
