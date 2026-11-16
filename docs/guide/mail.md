---
description: Mails as typed structs, templates checked by nexus gen, and sending over SMTP, to the log, or into a test outbox.
---

# Mail

Sooner or later your app has to write to people: a welcome when they sign up, a link to reset a password, a receipt. Mail is a surprisingly fiddly thing to get right. Templates drift away from the data that fills them, a typo in a placeholder only shows up as a hole in a mail someone already received, and a development setup that sends real mail is one bad afternoon away from mailing every customer.

nexus-mail takes care of that. A mail is a struct, its templates are compiled and checked against that struct by `nexus gen`, and until you point it at a real server, every mail lands in the log instead of an inbox.

To add it, require the module in your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/mail" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then put its extension in your app's extension list:

```echo title="src/Extensions.eco"
// mail through NEXUS_MAIL_URL: SMTP, the log, or kept in memory for tests
nexus::mail::Extension(),
```

## Your first mail

A mail is a struct conforming to `nexus::mail::Mailable`. Its fields are the data the mail needs, and `subject()` is plain code. Here is the welcome the blog sends to new readers:

```echo title="src/Mail/WelcomeMail.eco"
namespace Blog::Mail;

#[nexus::mail: { text: "welcome.txt", html: "welcome.html" }]
public struct WelcomeMail : nexus::mail::Mailable
{
    public string $name;
    public string $blog;
    public array<PostLink> $posts = [];

    public const function subject() : string
    {
        return "Welcome to {$this->blog}";
    }
}
```

`#[nexus::mail]` names the templates the bodies come from. Both are paths under your module's `resources/emails/`, and you may give a text body, an HTML body, or both. When both are there, the mail goes out as a `multipart/alternative` and each client shows the one it prefers.

Why is the subject code and not part of the attribute? Because subjects are often translated or computed. The blog's real `WelcomeMail` carries the reader's locale and the app's `nexus::Messages`, and looks the subject up in its catalogs. See [translations](./i18n.md) for how that catalog works. `nexus gen` refuses a `subject` key in `#[nexus::mail]` and tells you to write `subject()` instead.

## Writing templates

A template is the text of the mail with holes in `{{ }}`. Here is the plain text half of the welcome:

```txt title="resources/emails/welcome.txt"
Hello {{ name }},

welcome to {{ blog }}. Your account is ready, and you can sign in with the address this mail went to.
{{ if posts }}

The latest posts:
{{ each posts as post }}
- {{ post.title }} ({{ post.url }})
{{ end }}
{{ end }}

See you soon.
```

And its HTML twin:

```html title="resources/emails/welcome.html"
<h1>Hello {{ name }}</h1>
<p>Welcome to {{ blog }}.</p>
{{ if posts }}
<h2>The latest posts</h2>
<ul>
  {{ each posts as post }}
  <li><a href="{{ post.url }}">{{ post.title }}</a></li>
  {{ end }}
</ul>
{{ end }}
```

That is the whole language:

| Tag | What it does |
|:--|:--|
| `{{ name }}` | Writes a string or number field. In an `.html` template the value is HTML-escaped. |
| `{{ raw intro }}` | The same, never escaped. |
| `{{ if posts }} ... {{ else }} ... {{ end }}` | Tests a `bool`, a nullable (not null), a string or an array (not empty). |
| `{{ each posts as post }} ... {{ end }}` | Walks an array; `post` is each item. |

A path may walk into fields of structs and classes, like `post.author.name`, and a hole whose value is null writes nothing. If you need a literal `{{` in the mail, write `{{{{`.

You might worry that putting each `if`, `each` and `end` on its own line leaves blank lines all over the mail. Don't: a block tag that sits alone on its line takes that line with it, so the template may stay readable without the mail looking odd.

### Checked before it builds

Templates are not read at runtime. `nexus gen` compiles each one into code (a `nexus::mail::render` overload for your struct) and checks every hole against the struct's fields. A misspelled field, a hole that names an array, an `each` over a string, or an `if` without its `end` all stop the build with the template, the line and the column:

```txt
resources/emails/welcome.txt:1:7: WelcomeMail has no field nmae
```

Since the templates are compiled in, a changed template needs a rebuild. The `before_build` hook in your `module.eco` runs `nexus gen` for you, so `echoc build` and `echoc run` pick it up. [nexus gen](./generator.md) has the details.

> [!NOTE]
> Only fields that are neither private nor static are visible to a template. A private field is as good as missing.

## Sending a mail

The extension binds one `nexus::mail::Mailer` for the whole process. You may take it in a service, a task or a signal handler. `compose()` turns a mailable into a `nexus::mail::Message` with its subject and bodies filled in, and the builder methods add the rest:

```echo
$mailer = $payload->get<nexus::mail::Mailer>();
$msg = $mailer->compose(WelcomeMail($u->name, $blog, mv $posts))
    ->to(nexus::mail::Address($u->email, $u->name));

guard $mailer->send($msg) else ($e) {
    return .error(nexus::work::Failure::of($e->problem()));
};
```

A `nexus::mail::Address` is an email and an optional display name. Besides `to()`, a message takes `cc()`, `bcc()`, `replyTo()`, `from()`, `header()` and `attach()`, each returning the message so you may chain them.

`send()` checks the message first: it needs a recipient, a subject and at least one body, and no address, header or file name may contain a line break. A mail that fails the check is never handed to the transport. When the message names no sender, the mailer uses `NEXUS_MAIL_FROM`.

### What a mail always carries

Sometimes a mail always has the same reply address, an extra header, or a file attached. Rather than repeating that wherever it is sent, you may write it on the mailable. `envelope()` and `attachments()` are both optional:

```echo
public const function envelope(nexus::mail::Envelope& $e) : void
{
    $e->replyTo(nexus::mail::Address('billing@example.com'))
        ->header('List-Unsubscribe', '<https://blog.example.com/unsubscribe>');
}

public const function attachments(array<nexus::mail::Attachment>& $out) : void
{
    $out[] = nexus::mail::Attachment('terms.pdf', bytes: $this->terms);
    $out[] = nexus::mail::Attachment(file: '/var/reports/2026-11.csv');
}
```

An attachment holds bytes you already have, or a path that is read when the mail is sent. Without a `type`, the content type follows the file's extension.

### When sending fails

`send()` answers `result<nexus::mail::Sent, nexus::mail::MailError>`. `Sent` carries the `Message-ID` and who the mail went to. A `MailError` says why it did not go: an invalid mail, a server that could not be reached, a timeout, a failed TLS setup, a refused login, or an SMTP error code.

Not every failure deserves the same answer. A server that is away for a minute is worth trying again; a mail with a broken address never will be. `$e->transient()` tells the two apart, and `$e->problem()` turns the error into a `nexus::Problem` that says so.

## Sending from a task

Sending is synchronous. Over SMTP, `send()` returns once the server has the mail, which may take a moment, and it may fail. So you should not send mail in the middle of a request. Instead, queue a [task](./tasks.md) and send from there, where a failure is retried.

The blog does exactly that. Signing up fires a signal, whose handler queues `SendWelcome`, and a worker sends the mail:

```echo title="src/Tasks/SendWelcome.eco"
public struct SendWelcome : nexus::work::Task
{
    public int64 $user;
    public string $locale = 'en';

    public const function tries() : int64
    {
        return 5;
    }

    public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
    {
        // ... find the user and the latest posts
        $mail = WelcomeMail($u->name, $payload->get<BlogConfig>()->title, $this->locale, $payload->get<nexus::Messages>(), mv $posts);
        $mailer = $payload->get<nexus::mail::Mailer>();
        $msg = $mailer->compose($mail)->to(nexus::mail::Address($u->email, $u->name));
        guard $mailer->send($msg) else ($e) {
            return .error(nexus::work::Failure::of($e->problem()));
        };
        // ... note that the welcome went out
        return .ok;
    }
}
```

`Failure::of($e->problem())` is the piece that makes this work: a transient error becomes a retry, and anything else gives up instead of hammering a server with a mail it will never take.

## Where mail goes

`NEXUS_MAIL_URL` picks the transport:

- `smtp://user:pass@smtp.example.com:587` sends over SMTP with STARTTLS. The port defaults to `587`.
- `smtps://user:pass@smtp.example.com` speaks TLS from the first byte. The port defaults to `465`.
- `log:` writes each mail to the log and never sends it. This is the default, so a fresh checkout can't mail anyone by accident.
- `memory:` keeps every mail in a `nexus::mail::Outbox`, for tests.

The username and password are percent-decoded, so a password holding `@` or `:` should be written as `%40` or `%3A`. For SMTP, a sender in `NEXUS_MAIL_FROM` is required, and the boot stops with a message if it is missing.

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_MAIL_URL` | `log:` | Where mail goes: `smtp://`, `smtps://`, `log:` or `memory:`. |
| `NEXUS_MAIL_FROM` | | The sender of every mail that names none, like `hello@example.com`. Required for SMTP. |
| `NEXUS_MAIL_FROM_NAME` | | The display name beside that sender. |
| `NEXUS_MAIL_TLS` | `starttls` | For `smtp://`: `starttls` (required), `optional`, or `none` for a local relay or a development catcher. |
| `NEXUS_MAIL_TIMEOUT` | `30s` | How long one mail may take, connecting included. |

[Configuration](./configuration.md) covers how these are read.

If you would like to send through something else entirely, an HTTP mail API for instance, you may write a class conforming to `nexus::mail::Transport` and hand it to the extension as `nexus::mail::Extension(transport: ...)`. It then wins over `NEXUS_MAIL_URL`.

## Testing mail

With `NEXUS_MAIL_URL=memory:`, the extension binds the `nexus::mail::Outbox` as well, so a test reads straight from it what went out. The blog's integration tests run a welcome and look at the result:

```echo title="tests/integration/UsersFlowTest.eco"
expect($world->run(Blog::Tasks::SendWelcome($user: $user)))->fine();

$outbox = $world->app->kernel->services->get<nexus::mail::Outbox>();
$mail = expect($outbox->find(to: 'reader@example.com'))->some();
expect($mail->message->subject)->is('Welcome to A nexus blog');
expect($mail->message->html ?? '')->has('<h1>Hello A reader</h1>');
expect($mail->mime)->has('To: A reader <reader@example.com>');
```

Each delivery holds the `message` as composed and the `mime` exactly as it would have been written to the wire. You may also find a mail by `subject:`, read every one with `delivered()`, or count them with `count()`.

So, what about the day the mail server is down? `refuse()` makes the next delivery fail with the error you give it, which is how the blog checks that its welcome is retried:

```echo
$outbox->refuse(.connect('connection refused'));
$f = expect($world->run(Blog::Tasks::SendWelcome($user: $user)))->fails();
expect($f->why())->has('cannot reach the mail server');
```

[Testing](./testing.md) shows how the blog boots its app for tests like these.

## Where to next

- [Tasks and queues](./tasks.md): sending on a worker, with retries.
- [Signals](./signals.md): queueing the mail when something happens.
- [Translations](./i18n.md): subjects in the reader's language.
