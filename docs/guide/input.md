---
description: Describe a request body or query string as a struct, put rules on its fields, and let nexus answer one 422 for everything that does not fit.
---

# Input and validation

Almost every endpoint that changes something takes input: a title and a body, an email and a password, an image. And every one of them has to answer the same questions before it does any work. Is the field there? Is it the right type? Is it long enough, short enough, one of the allowed values?

In nexus you answer those questions once, on a struct. You describe the input, put rules on its fields, and ask for it in `handle()`. `nexus gen` writes the code that reads the request and checks every rule, so by the time your action runs, the input is typed and valid. If anything is wrong, the client gets one `422` that lists every field that failed, and your action never sees bad data.

## Validation quickstart

To get a feel for it, let's walk through the blog's sign up endpoint from start to finish: describing the input, checking it, adding a rule that needs the database, and seeing what the client gets back when something is off.

### Describing the input

First, we describe what signing up takes. An input is a struct marked `#[nexus::input]`, with one public field per value the client sends:

```echo title="src/Inputs/Registration.eco"
namespace Blog::Inputs;

/**
 * Who signs up: a name, an email and a password, given twice.
 */
#[nexus::input]
public struct Registration
{
    public string $name;
    public string $email;
    public string $password;
    public string $passwordConfirmation;
}
```

That alone already does a lot. Each field is required because it has no default and is not nullable, and each must be a string. A request without `email`, or with `"email": 42`, is refused before any of our code runs.

### Asking for it in the action

Next, the action asks for the input as `nexus::Body<Registration>`. The decoded struct is in `$in->value`:

```echo title="src/Actions/Users/Register.eco"
public class Register : nexus::Action
{
    // ...

    public function handle(nexus::Payload& $payload, nexus::Body<Registration> $in) : result<nexus::Response, nexus::Problem>
    {
        $inc = try $this->transformer->requestedIncludes($payload);
        const Registration& $r = $in->value;
        try $this->passwords->acceptable($r->password);
        $hash = try $this->passwords->hash($r->password);
        // ...
    }
}
```

The body may arrive as JSON, as an urlencoded form, or as a multipart form; the action looks the same for all three. We'll come back to that in a moment.

### Adding rules

Now we're ready to say what a good sign up looks like. Rules go on each field with `#[nexus::rule]`:

```echo title="src/Inputs/Registration.eco"
#[nexus::input]
public struct Registration
{
    #[nexus::rule: { squish: true, notBlank: true, max: 190 }]
    public string $name;

    #[nexus::rule: { trim: true, lower: true, email: true, max: 190 }]
    public string $email;

    #[nexus::rule: { confirmed: true }]
    public string $password;

    public string $passwordConfirmation;
}
```

Let's read that top to bottom. The name has its whitespace tidied up (`squish`), may not be blank, and is at most 190 characters. The email is trimmed and lowercased before anything else looks at it, then has to look like an email address. And `confirmed` says `passwordConfirmation` must hold the same password.

A rule that does not fit its field is caught by `nexus gen`, not by a request. Put `email: true` on an `int64` and the build stops with a line saying which rules an integer field takes instead.

### A rule that needs the database

Some rules cannot be written as an attribute, because they need a service. "Nobody has signed up with this email yet" is one: it has to ask the users table. For that, you may write a rule class conforming to `nexus::Rule<T>`, where `T` is the type of the field it checks:

```echo title="src/Rules/UniqueEmail.eco"
namespace Blog::Rules;

use Blog::DB::Model::{UserRepository, UserTable};

public class UniqueEmail : nexus::Rule<string>
{
    private UserRepository $users;

    public constructor(UserRepository $users)
    {
        $this->users = $users;
    }

    public function check(const string& $email, nexus::Check $v) : void
    {
        // a database that does not answer leaves the decision to the insert
        $found = guard $this->users->find()->where(UserTable::$email == $email)->first() else {
            return;
        };
        if ($found != null) {
            $v->fail('unique', 'The {label} has already been taken.');
        }
    }
}
```

We name it on the field with `check`, and while we're there, give the field a friendlier label and a message of our own for the `unique` code:

```echo title="src/Inputs/Registration.eco"
#[nexus::rule: { trim: true, lower: true, email: true, max: 190, check: 'Blog::Rules::UniqueEmail' }]
#[nexus::label: 'e-mail address']
#[nexus::message: { unique: 'Someone already signed up with that e-mail address.' }]
public string $email;
```

A rule class is built per request from the container, just like an action, so bind it where the app is wired:

```echo title="src/Providers/AuthProvider.eco"
$app->bind<UniqueEmail>(scoped: (Container $c) => UniqueEmail($c->get<UserRepository>()));
```

If you forget, the boot stops with a line naming the unbound rule class. The check runs only once the field's own rules have passed, so `UniqueEmail` never queries the database for something that is not even an email address.

### What the client sees

So, what happens when a client signs up with no name and two different passwords? `handle()` never runs. Instead, the client gets a `422` in the [problem details](./problems.md) format, with one entry per refused field:

```json
{
  "type": "about:blank",
  "title": "Unprocessable Content",
  "status": 422,
  "detail": "the input did not validate",
  "requestId": "5f1c0e9a7d2b4c83",
  "errors": [
    {
      "field": "name",
      "code": "required",
      "message": "The name field is required.",
      "params": {}
    },
    {
      "field": "password",
      "code": "confirmed",
      "message": "The password field confirmation does not match.",
      "params": {}
    }
  ]
}
```

Every rule on every field is checked, so the client hears about all the problems at once rather than one per round trip. `field` is where the value sits in the input, `code` is stable for a client to switch on, `params` holds what the rule was given (`{"max": "190"}`), and `message` is for people.

That's a complete, validated endpoint. Don't worry about memorizing the rules yet; every one of them is listed [at the end of this page](#available-rules).

## Where input comes from

### Request bodies

`nexus::Body<T>` reads the body by its `Content-Type`:

- `application/json` (or any `+json` type): the body must be a JSON object. JSON that does not parse, or is not an object, is a `400`.
- `application/x-www-form-urlencoded`: the form's fields, at most 1000 of them.
- `multipart/form-data`: the form's fields and its files.
- An empty body with no type, or with a JSON type, reads as an empty input, so a request with only optional fields still works.

Anything else is a `415 Unsupported Media Type`. The whole body is capped by `NEXUS_HTTP_MAX_BODY` (8 MiB unless you say otherwise), and a bigger one is a `413` before it is read.

### Query strings

When the input is in the query string, as for a search or a filtered listing, take it as `nexus::QueryOf<T>` instead. The struct and its rules look exactly the same:

```echo
#[nexus::input]
public struct PostSearch
{
    #[nexus::rule: { trim: true, max: 50 }]
    public string? $tag = null;

    #[nexus::rule: { min: 1 }]
    public uint32 $page = 1;
}
```

```echo
public function handle(nexus::QueryOf<PostSearch> $q) : result<nexus::Response, nexus::Problem>
```

A query cannot carry files, so `nexus gen` refuses a `QueryOf<T>` whose input has an upload field and tells you to take it as a body.

### The other doors

The same input structs are what [commands](./commands.md) read from their options and what [MCP tools](./mcp.md) read from their arguments, with the same rules. You describe an input once, wherever it arrives from.

## Describing fields

### Field types

The type of a field says what the client must send, and which rules may go on it:

| Field type | Kind | What the client sends |
|:--|:--|:--|
| `string` | string | text |
| `bool` | boolean | `true` or `false`; in a form also `1`/`0`, `on`/`off`, `yes`/`no` |
| `int32`, `int64`, `uint16`, `uint32`, `uint64` | integer | a whole number in range |
| `float64` | number | a number |
| `calendar::Date` | date | an ISO 8601 date, `2026-10-28` |
| `time::timestamp` | timestamp | an RFC 3339 instant, `2026-10-28T09:30:00Z` |
| a backed enum | enum | one of the enum's values |
| `json::Value` | json | any JSON value, kept raw |
| `nexus::Upload` | file | a file in a multipart form |
| another `#[nexus::input]` struct | object | a nested object |
| `array<string>`, `array<int64>`, `array<nexus::Upload>`, an array of enums or inputs | list | a list |

A value of the wrong type is refused with the code `type` and a message naming what was expected ("must be a whole number"). An enum value that is not one of its cases is refused with `oneOf`, listing the ones that are.

### Optional fields

A field is required unless it has a default or is nullable. Leaving out a required field is refused with `required`. Sending `null` counts as leaving it out:

```echo title="src/Inputs/PostChanges.eco"
#[nexus::input]
public struct PostChanges
{
    #[nexus::rule: { min: 3, max: 120 }]
    public string? $title = null;

    public string? $body = null;
}
```

The rules of an optional field only run when the client sent it. Here, a `PATCH` without a title leaves the title alone, while a title of two characters is refused.

### Labels and messages

Messages call a field by its name made readable: `passwordConfirmation` is "password confirmation". When that does not read well, you may give the field a label of its own with `#[nexus::label]`, and every message for it uses that instead.

`#[nexus::message]` replaces the English message of one code on one field. It works for built-in codes and for the codes your rule classes use alike:

```echo
#[nexus::label: 'e-mail address']
#[nexus::message: { unique: 'Someone already signed up with that e-mail address.' }]
public string $email;
```

A message may name `{label}` and the rule's params, such as `{min}` or `{max}`. Messages start in English and are rendered in the language the request speaks when the app has a catalog for it; [translations](./i18n.md) shows how.

### Naming a field on the wire

The client sends each field under its Echo name, `passwordConfirmation`. If your API speaks another spelling, you may rename a field with `#[nexus::name]`:

```echo
#[nexus::name: 'password_confirmation']
public string $passwordConfirmation;
```

## Normalising values

Values from people are messy: a stray space before an email, a name typed in capitals. A normaliser changes the value before any rule sees it, and your action gets the cleaned version:

- `trim` drops whitespace at both ends.
- `lower` and `upper` change the case.
- `squish` trims, and turns every run of whitespace inside into one space.
- `nullIfBlank` turns a blank string into `null`, for a `string?` field.

```echo
#[nexus::rule: { trim: true, notBlank: true, max: 2000 }]
public string $body;
```

## Comparing fields

Some rules look at another field of the same input. `confirmed` checks that `{field}Confirmation` holds the same value, as the password above does. `same` and `different` compare with a field you name, and `gt`, `gte`, `lt`, `lte`, `after` and `before` accept a field name in place of a fixed value.

`requiredWith` and `requiredWithout` make an optional field required depending on another. For example, you may insist that a change to a post changes at least something:

```echo
#[nexus::rule: { requiredWithout: 'title' }]
public string? $body = null;
```

`nexus gen` checks that the named field exists and that the types can be compared, so a typo is a build error, not a rule that never fires.

## Rule classes

You've seen a rule class on a field. You may also put one on the whole input, for a rule that is about more than one field. There, `T` is the input itself, and the check runs only once every field has passed its own rules. Use `fail(field:)` to blame the field the client should fix:

```echo
#[nexus::input]
#[nexus::rule: { check: 'Blog::Rules::SaysMore' }]
public struct NewPost
{
    // ...
}
```

```echo title="src/Rules/SaysMore.eco"
public class SaysMore : nexus::Rule<NewPost>
{
    public function check(const NewPost& $post, nexus::Check $v) : void
    {
        if ($post->body == $post->title) {
            $v->fail(field: 'body', 'repeats', 'The {label} should say more than the title.');
        }
    }
}
```

On the input itself, `#[nexus::rule]` takes only `check`; every other rule goes on a field. A field may name several classes as a list, `check: ['Blog::Rules::UniqueEmail', 'Blog::Rules::NotBanned']`, and they run in order.

`fail` also takes `params:`, a map whose values fill the holes in your message. Since rule classes are built from the container, they may take any service a request can have: a repository, the config, the router.

## Nested inputs

Sometimes one request carries several records at once. A field may be another input struct, or a list of them, and each one follows its own rules. The blog publishes a batch of posts this way:

```echo title="src/Inputs/PostBatch.eco"
#[nexus::input]
public struct PostBatch
{
    #[nexus::rule: { min: 1, max: 20 }]
    public array<NewPost> $posts;
}
```

The rules on `posts` are about the list (one to twenty posts); the rules inside `NewPost` apply to every post in it. A refusal deep inside names its full path, so the client knows exactly which one to fix:

```json
{ "field": "posts.1.title", "code": "min", "message": "The title field must be at least 3 characters.", "params": { "min": "3" } }
```

In JSON, a nested input is an object and a list of them an array of objects. A form says the same with bracketed keys: `posts[0][title]`, `posts[1][title]`. A list of plain values may be a JSON array or a repeated form field (`tags=a&tags=b`, `tags[]=a`, `tags[0]=a`).

The rules on a list's items go in `each`. The blog's tags are trimmed, lowercased and checked one by one, while the list itself may hold five distinct ones at most:

```echo title="src/Inputs/NewPost.eco"
#[nexus::rule: { max: 5, distinct: true, each: { trim: true, lower: true, notBlank: true, max: 30 } }]
public array<string> $tags = [];
```

A refused item is named by its index, as in `tags.2`.

## Uploads

Files come in a `multipart/form-data` body, as a `nexus::Upload` field. The blog's cover upload takes one image:

```echo title="src/Inputs/CoverUpload.eco"
/**
 * A post's cover image, sent as `image` in a multipart form: a PNG, JPEG or WebP by its bytes, up
 * to 2 MB.
 */
#[nexus::input]
public struct CoverUpload
{
    #[nexus::rule: { maxBytes: 2097152, types: ['image/png', 'image/jpeg', 'image/webp'] }]
    public nexus::Upload $image;
}
```

```echo title="src/Actions/Covers/UploadCover.eco"
public function handle(nexus::Payload& $payload, int64 $id, nexus::Body<CoverUpload> $in) : result<nexus::Response, nexus::Problem>
{
    $me = try $payload->state<Caller>();
    $changed = try $this->covers->upload($me->user, $id, $in->value->image);
    return $this->transformer->createResponse($payload, $changed);
}
```

An upload carries the form field it came in (`field`), the file name the client gave (`filename`, without any directory), the type it claimed (`type`), and the `bytes`. `size()` counts them.

::: warning The client's word is not proof
The file name and the type are whatever the client said. `sniffed()` reads the type from the bytes where it can (PNG, JPEG, GIF, WebP, AVIF, PDF, ZIP, gzip), and `kind()` gives you the sniffed type when there is one. The `types` rule goes by the bytes too, so an HTML page sent as `image/png` is refused. Store the bytes under a key your app makes, never under the file name.
:::

For several files, use `array<nexus::Upload>`: the client sends them as `photos`, `photos[]` or `photos[0]`, ... and you may check each with `each: { maxBytes: ... }`. A file input a browser left empty is skipped, so an optional `nexus::Upload?` stays `null`. A multipart body is cut into at most 1000 parts with 8 KiB of headers each; one that is not well formed is a `400`. [Files](./files.md) shows where to keep what you receive.

## Refusing input from your own code

Not every refusal fits a rule. When a service finds out something is wrong with one field, it may answer the same `422` shape with `nexus::Problem::field()`:

```echo title="src/Services/CoverService.eco"
return .error(nexus::Problem::field('key', 'cover', 'nothing was uploaded under that key'));
```

The client handles it exactly like a refusal from a rule. [Problems and errors](./problems.md) covers the other answers an action may give.

## Available rules

Rules are written as keys in `#[nexus::rule: { ... }]`. A rule that takes no value is written `key: true`. Each rule fits some kinds of field; `nexus gen` refuses the rest with a list of what would fit. Every field also takes `check`, `requiredWith` and `requiredWithout`.

### Normalisers

#### trim
Removes whitespace at both ends of a string before the other rules run. Fits strings and string list items.

#### lower
Lowercases a string before the other rules run. Fits strings and string list items.

#### upper
Uppercases a string before the other rules run. Fits strings and string list items.

#### squish
Trims a string and replaces every run of whitespace inside it with one space. Fits strings and string list items.

#### nullIfBlank
Turns a blank string into `null`. Fits a `string?` field only, not list items.

### Size

#### min
The field must be at least this much: characters for a string, the value for a number, items for a list. `min: 3`.

#### max
The field must be at most this much: characters for a string, the value for a number, items for a list. `max: 120`.

#### between
The field must be between the two ends, inclusive, counted like `min` and `max`. `between: [3, 120]`.

#### size
A string must have exactly this many characters, a list exactly this many items. `size: 2`.

### Strings

#### notBlank
The string must contain something besides whitespace.

#### email
The string must be a plausible email address: one `@`, something before it, a dot in the domain after it, no spaces.

#### url
The string must be an absolute `http` or `https` URL with a host and no spaces.

#### uuid
The string must be a UUID in its 8-4-4-4-12 hex form, any case.

#### alpha
The string must contain letters only. Letters beyond ASCII count.

#### alphaNum
The string must contain letters and digits only.

#### alphaDash
The string must contain letters, digits, `-` and `_` only.

#### ascii
The string must contain ASCII characters only.

#### digits
The string must contain the digits `0` to `9` only, at least one.

#### startsWith
The string must start with the given text, or with one of a list. `startsWith: ['https://', 'mailto:']`.

#### endsWith
The string must end with the given text, or with one of a list. `endsWith: '.md'`.

#### oneOf
The value must be one of the list. Fits strings and integers. `oneOf: ['image/png', 'image/jpeg', 'image/webp']`.

#### noneOf
The value must not be one of the list. Fits strings and integers. `noneOf: ['admin', 'root']`.

### Numbers

#### multipleOf
The number must be a multiple of the value. Fits integers and numbers. `multipleOf: 5`.

#### gt
The number must be greater than a value, or than another field of the input. Fits integers and numbers. `gt: 0`, `gt: 'minimum'`.

#### gte
Like `gt`, but equal is allowed.

#### lt
The number must be less than a value, or than another field of the input.

#### lte
Like `lt`, but equal is allowed.

### Booleans

#### accepted
The field must be `true`: a box ticked to accept the terms.

#### declined
The field must be `false`.

### Dates and timestamps

#### after
The date or timestamp must be after a fixed one (`after: '2026-01-01'`), after another field of the input (`after: 'starts'`), after `'today'` for a date, or after `'now'` for a timestamp.

#### before
Like `after`, in the other direction.

#### afterOrEqual
Like `after`, but the same day or instant is allowed.

#### beforeOrEqual
Like `before`, but the same day or instant is allowed.

### Files

#### maxBytes
The file must not be larger than this many bytes. `maxBytes: 2097152`. The message shows the size the way people read it, "2 MB".

#### minBytes
The file must be at least this many bytes.

#### types
The file must be one of these media types, written lowercase; `image/*` matches any image. A type `sniffed()` knows is checked against the bytes, any other type against what the client said. `types: ['image/png', 'image/jpeg']`.

#### extensions
The file name must end in one of these extensions, written without the dot. `extensions: ['csv', 'txt']`.

### Lists

#### distinct
No value may appear twice. Fits lists of strings and of integers.

#### each
The rules every item must follow, written like a field's own. Fits lists of strings, of integers and of files. `each: { trim: true, max: 30 }`.

### Other fields

#### confirmed
The field `{name}Confirmation` must hold the same value; it has to exist, with the same type. Not for lists, files, nested inputs or `json::Value`.

#### same
The field must hold the same value as the field you name. `same: 'email'`. Not for lists, files, nested inputs or `json::Value`.

#### different
The field must differ from the field you name. Not for lists, files, nested inputs or `json::Value`.

#### requiredWith
The field is required when the field you name is present. The field must be nullable, since a plain one is always required. `requiredWith: 'starts'`.

#### requiredWithout
The field is required when the field you name is missing. The field must be nullable. `requiredWithout: 'title'`.

### Your own

#### check
Runs a rule class, or a list of them, conforming to `nexus::Rule<T>` for the field's type (or the input's, on the struct). Fits every field, list items included. `check: 'Blog::Rules::UniqueEmail'`.

## Where to next

- [Problems and errors](./problems.md): the other ways a request can fail, and how each one looks to a client.
- [Translations](./i18n.md): input messages in the language your users speak.
- [Files](./files.md): keeping uploads on disk or in S3.
