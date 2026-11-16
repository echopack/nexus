---
description: How an action says something went wrong. Every nexus::Problem case and its status, the RFC 9457 document a client receives, your own problem types, and what the mode keeps private.
---

# Problems and errors

Things go wrong in every app. A post is not there, a user may not edit it, a field is too short, the database is busy. Each of those has to reach the client as an answer it can act on, with the right status and a body it can read, and the ones that are your fault have to reach your log.

In nexus, all of that is one type: `nexus::Problem`. Every action, decoder and middleware speaks it, and the kernel renders it as [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details, the standard JSON format for HTTP errors. You decide *what* went wrong; nexus takes care of how it looks on the wire, what gets logged, and what stays private.

## Returning a problem

An action that can fail returns a `result`, and a problem goes in its error side. Each case maps to its HTTP status:

```echo
$post = guard $posts->find($id) else {
    return .error(.notFound('post'));
};
if ($post->authorId != $me->user->id) {
    return .error(.forbidden('only the author may edit a post'));
}
```

Because problems travel through `result`, `try` passes one up from a service without ceremony. The blog's services all answer `result<T, nexus::Problem>`, so an action can chain them and any failure on the way becomes the answer:

```echo title="src/Actions/Users/Register.eco"
$inc = try $this->transformer->requestedIncludes($payload);
const Registration& $r = $in->value;
try $this->passwords->acceptable($r->password);
$hash = try $this->passwords->hash($r->password);
```

An action with nothing to say on success returns `status<nexus::Problem>`, which answers `204 No Content` when it is ok.

## What the client sees

Let's look at what `.notFound('post')` turns into on the wire. The response has status `404`, the content type `application/problem+json`, and this body:

```json
{
  "type": "about:blank",
  "title": "Not Found",
  "status": 404,
  "detail": "post not found",
  "requestId": "5f1c0e9a7d2b4c83"
}
```

`type` and `title` say what kind of problem it is, `detail` says what happened this time, and `requestId` is the same id the response carries in `X-Request-Id`, so a client can quote it and you can find the request in your log. Every problem is shaped like this, plus a few members some of them add:

- `errors`: the refused fields of a `422`, each with its `field`, `code`, `message` and `params`. [Input and validation](./input.md#what-the-client-sees) shows one in full.
- `reason`: a stable code for a `401`, see below.
- Whatever members your own problem types carry.

Some problems come with a header too. A `405` lists the methods that would have answered in `Allow`, and a `429` says how many seconds to wait in `Retry-After`.

### Reason codes

A client often needs to know more than "401". Is the session gone, so it should open a new one? Did the password not match, so it should ask again? Branching on a `detail` meant for people is fragile, so `unauthorized` carries a second argument, a stable `snake_case` code sent as `reason`:

```echo
return $payload->fail(.unauthorized('this needs a session: open one first', $reason: 'session_required'));
```

The [authentication](./auth.md) extensions answer with codes like `session_required`, `token_invalid` and `wrong_credentials`, and your own guards may use codes of your own the same way.

## Problems in middleware

Middleware returns a response rather than a `result`, so it renders a problem itself with `$payload->fail()`. The client sees exactly what it would from an action, and a server error is logged the same way:

```echo title="src/Middleware/RequireAdmin.eco"
if ($me->user->role != Role::admin) {
    return $payload->fail(nexus::Problem::forbidden('this needs an admin'));
}
```

[Middleware](./middleware.md) covers the rest of answering early.

## Your own problem types

The built-in cases cover HTTP's common answers. Occasionally your API has a failure of its own that a client should be able to recognise by type and act on, with data of its own: an account out of credit, a post locked by an editor. For that, describe it with a `nexus::ProblemDetail` and return it as `.custom(...)`:

```echo
json::Value $extra = json::object();
$extra['editor'] = json::str($lock->editorName);
$extra['until'] = json::str($lock->until);
return .error(.custom(nexus::ProblemDetail(
    'https://blog.example.com/problems/post-locked', 423, 'The post is being edited.',
    $detail: "{$lock->editorName} is editing this post", $extra: $extra)));
```

The `type` should be a URI you control, ideally one that explains the problem to a developer who opens it. The status is yours to choose, and every member of `extra` lands at the top level of the document, next to `type` and `title`.

## Turning other errors into problems

Your services will meet errors that are not problems yet: a database error, a mail server that refuses. You may convert each one by hand, but `try` can do it for you. Give `nexus::Problem` an implicit conversion from your error type, and `try` uses it wherever a function answers with a problem. This is how [nexus-carbon](./database.md) lets a repository call be `try`'d straight into an action's result:

```echo
extension nexus::Problem
{
    #[implicit]
    public static function from(carbon::Error $e) : nexus::Problem
    {
        return Problems::of($e);
    }
}
```

With that in place, a missing row is a `404`, a duplicate a `409`, a lost connection a `503`, and anything else a `500`, without one line of mapping in your actions:

```echo
Post $post = try $posts->get($id);
```

## Server errors and the mode

Some failures are not the client's fault at all. When your code hits something it cannot recover from, answer with `.server()` and say what happened, as precisely as you can:

```echo
return .error(.server("cover store: {$e}"));
```

That cause is for you, not for the client: it may name a table, a host or a file path. So how much of it leaves the process depends on the [mode](./configuration.md#the-mode) the app runs in:

- In `dev` and `test`, the client sees the cause as the `detail`, which is what you want while building.
- In `prod`, the client sees only `the server failed to answer this request`.

Only `server` hides its detail. Every other case's detail is meant for the client and is always sent, so keep secrets out of a `badRequest` or a `conflict`.

::: warning Dev is the default
A process started without `--mode` or `NEXUS_MODE` runs in `dev`. When `serve` listens on an address other machines can reach in `dev`, it warns at start, since every client would see the cause of every error. Set `NEXUS_MODE=prod` wherever others reach the app.
:::

### What gets logged

Every problem with a `5xx` status is logged as an error the moment it is rendered, with its status and its full cause, whatever the mode. The request's log line carries its id, so the `requestId` a client quotes leads you straight to it. The request's access line is written at `warn` instead of `info` too. Problems in the `4xx` range are the client's business and are not logged as errors; they show up only in the access line with their status. [Logging and tracing](./logging.md) shows where those lines go.

## Problems nexus answers for you

Many problems never pass through your code. nexus answers them before your action runs, in the same format:

| Situation | Answer |
|:--|:--|
| No route has the path | `404` |
| The path exists, but not for this method | `405` with `Allow` |
| A path parameter does not fit its type, such as an id too large for `int64` | `404` |
| The body is not valid JSON, or not a JSON object | `400` |
| The body's content type is not JSON or a form | `415` |
| The body is larger than `NEXUS_HTTP_MAX_BODY` | `413` |
| An input field is missing, of the wrong type or refused by a rule | `422` with `errors` |
| An action reads state no middleware put | `500`, logged with the action's name |

## Available problems

Each case of `nexus::Problem`, with the status it answers and what goes in `detail`.

#### badRequest
`.badRequest(string $detail)` answers `400 Bad Request`. For a request that is malformed in a way no input rule describes.

#### unauthorized
`.unauthorized(string $detail, string $reason)` answers `401 Unauthorized`. No credential, or one that does not hold. `$reason` is sent as the `reason` member; pass it by name, `$reason: 'token_invalid'`.

#### forbidden
`.forbidden(string $why)` answers `403 Forbidden`. The caller is known, but may not do this.

#### notFound
`.notFound(string $what)` answers `404 Not Found`, with the detail `{what} not found`. Name the thing, `.notFound('post')`, not a sentence.

#### methodNotAllowed
`.methodNotAllowed(array<nexus::Method> $allow)` answers `405 Method Not Allowed` with an `Allow` header listing `$allow`. Routing answers this for you.

#### conflict
`.conflict(string $detail)` answers `409 Conflict`. The request clashes with the current state: a taken email, a record that changed since it was read.

#### invalid
`.invalid(array<nexus::FieldError> $fields)` answers `422 Unprocessable Content`, with the fields in `errors`. For one field, `nexus::Problem::field('key', 'cover', 'nothing was uploaded under that key')` builds it for you. The messages are translated into the request's language, and the response says which in `Content-Language`.

#### tooLarge
`.tooLarge` answers `413 Content Too Large`.

#### unsupportedMedia
`.unsupportedMedia(string $type)` answers `415 Unsupported Media Type`, naming the content type that was refused.

#### tooMany
`.tooMany(int64 $retryAfter)` answers `429 Too Many Requests` with a `Retry-After` header of `$retryAfter` seconds.

#### unavailable
`.unavailable(string $detail)` answers `503 Service Unavailable`. Something the app depends on is busy or away, and trying again later may work. It counts as the server's fault, so it is logged.

#### server
`.server(string $cause)` answers `500 Internal Server Error`. The cause is logged, and shown to the client only outside `prod`.

#### custom
`.custom(nexus::ProblemDetail $detail)` answers with the status, type and title you give, plus the extra members. See [your own problem types](#your-own-problem-types).

## Where to next

- [Input and validation](./input.md): the `422` and every rule that can produce one.
- [Configuration](./configuration.md): setting the mode for each place the app runs.
- [Logging and tracing](./logging.md): finding the request behind a `requestId`.
