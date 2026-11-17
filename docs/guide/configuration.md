---
description: Typed settings from the environment. Config structs, where values come from, secrets, the env command, and the mode a process runs in.
---

# Configuration

Your app runs in more than one place: on your laptop, in CI, in production. Each place has its own database, its own secrets, its own idea of how many posts fit on a page. Those values should not live in the code, and reading them by hand (`getenv`, parse, check, complain) is tedious and easy to get wrong.

nexus reads configuration from the environment into typed structs. You declare the settings once, with their types and defaults; `nexus gen` writes the code that reads them, and the app refuses to boot with a clear list when a value is missing or malformed. By the time any of your code runs, every setting is there and has the right type.

## A config struct

Let's look at the blog's settings. A config struct is marked `#[nexus::config]` with a prefix, and each field read from the environment is marked `#[nexus::env]`:

```echo title="src/Config/BlogConfig.eco"
namespace Blog::Config;

use std::time;

/**
 * The blog's settings. Read from BLOG_TITLE, BLOG_DEFAULT_PAGE_SIZE, BLOG_STATS_EVERY and
 * BLOG_COVERS_URL, in the environment or a .env file.
 */
#[nexus::config: "BLOG"]
public struct BlogConfig
{
    /**
     * The blog's name, on every page.
     */
    #[nexus::env]
    public string $title = 'A nexus blog';

    /**
     * How many posts a page lists.
     */
    #[nexus::env: 'DEFAULT_PAGE_SIZE']
    public uint32 $pageSize = 10;

    /**
     * How often the admin's live stats stream sends a fresh snapshot while somebody watches.
     */
    #[nexus::env: 'STATS_EVERY']
    public time::duration $statsEvery = .secs(2);

    /**
     * Where the posts' cover images are kept: `file:storage/covers` (next to where the blog runs),
     * `s3://bucket/covers` with nexus-files-s3's settings, or `memory:`.
     */
    #[nexus::env: 'COVERS_URL']
    public string $coversUrl = 'file:storage/covers';
}
```

That's the whole thing. There is no loader to write and no registration: `nexus gen` finds every config struct in the program, and the kernel reads them all at boot.

### Naming the variables

Each variable is the struct's prefix, an underscore, and a name for the field. You may give that name in two ways.

Bare, `#[nexus::env]` uses the field's own name in capitals, so `$title` is read from `BLOG_TITLE`. That is the right choice when the field name already says what the variable is.

With a name, `#[nexus::env: 'DEFAULT_PAGE_SIZE']` says exactly what follows the prefix, so `$pageSize` is read from `BLOG_DEFAULT_PAGE_SIZE`. The field keeps a short name in your code while the variable says more to whoever sets it. Only the part after the prefix goes in the attribute; the prefix is always the struct's.

A field without `#[nexus::env]` is not read from anywhere. It must have a default, and that default is its value: handy for a setting you want in the struct but not open to change.

### Types

A config field may be any of these, each read from the variable's text:

| Type | Written as |
|:--|:--|
| `string` | as it is |
| `bool` | `true`, `1`, `yes`, `on` or `false`, `0`, `no`, `off`, any case |
| `int32`, `int64`, `uint16`, `uint32`, `uint64` | a whole number in range |
| `float64` | a number |
| `time::duration` | `250ms`, `30s`, `5m`, `2h`, `1d`, or bare seconds |

Any of them may be nullable, `string? $webhook`: unset, it is `null`.

### Defaults and required values

A field with a default uses it when the variable is not set. A field with neither a default nor `?` is required, and the app will not boot without it.

A default may be any expression the struct's file can write, including names it reaches through its `use` lines or its namespace: `time::duration::secs(30)` under `use std::time;`, or a constant `DEFAULT_PORT` declared beside the struct. `nexus gen` spells those names out in full where it writes the code that reads the struct.

When something is wrong, the boot stops and lists every bad variable at once, so a broken deploy shows you everything to fix in one go rather than one variable per restart:

```txt
blog: config: BLOG_DEFAULT_PAGE_SIZE: 'ten' is not a non-negative integer
blog: config: BLOG_STATS_EVERY: 'often' is not a duration like 30s, 5m or 2h
```

## Using the config

Each config struct is bound in the container as a value, so you take it like any other service. The blog's post listing reads its page size from it:

```echo title="src/Providers/PostsProvider.eco"
$app->bindAction<ListPosts>((Container $c) => ListPosts($c->get<PostCRUD>(), $c->get<BlogConfig>()))
    ->route([.get], '/v1/posts');
```

```echo title="src/Actions/Posts/ListPosts.eco"
$o->size = $this->config->pageSize as uint64;
```

The config is read and bound before any extension's `services()` runs. That means you may already use it while wiring, to decide how something is built:

```echo title="src/Providers/CoversProvider.eco"
$app->bindDisk<CoverVolume>('covers', url: $app->get<BlogConfig>()->coversUrl);
```

Here the covers go to a directory, to S3 or to memory depending on one variable, and nothing else in the blog has to know which.

## Where values come from

nexus looks for each variable in three places, and the first one that has it wins:

1. Values set explicitly, by a command line flag or a test.
2. The process environment.
3. A `.env` file.

Then, if none has it, the field's default.

So a `.env` file holds the settings for your machine, and anything set in the real environment overrides it, which is what a deployment usually does. A `.env` file is plain `KEY=value` lines:

```sh title=".env"
# the blog on my machine
BLOG_TITLE="Notes from the editors"
BLOG_DEFAULT_PAGE_SIZE=20
export BLOG_STATS_EVERY=5s
NEXUS_DATABASE_URL=mysql://app:secret@127.0.0.1:3306/blog
```

Blank lines and `#` comments are skipped, an `export ` prefix is allowed, and single or double quotes around a value are removed. A comment may also follow a value, after a space: `BLOG_STATS_EVERY=5s # how often` is `5s`, while `KEY=abc#def` keeps its `#`. Inside double quotes, `\"` is a quote and `\\` a backslash. A line without `=`, a quote that is not closed, or text after a closing quote stops the boot with the file and line number.

By default the app reads `.env` in the directory it starts in; a missing file is fine. You may point it at another file with `--env-file`, which every command takes:

```sh
echoc run -- serve --env-file .env.staging
```

### Secrets

Some settings must never be shown: a database URL with its password, the key sessions are signed with. Mark them with `#[nexus::secret]`, as nexus's own modules do:

```echo
#[nexus::config: "NEXUS_DATABASE"]
public struct DatabaseConfig
{
    #[nexus::env: 'URL']
    #[nexus::secret]
    public string $url = '';
}
```

A secret is read like any other setting. The difference is in what nexus shows about it: the [debug console](./debug.md) masks its value, and `env --dotenv` leaves it empty for you to fill in instead of writing out its default.

## The env command

When you deploy somewhere new, the first question is "what do I have to set?". The `env` command answers it: every variable the app reads, the core's own first, then each module's config structs:

```sh
echoc run -- env
```

Here are a few lines of the blog's:

```txt
NAME                    TYPE      DEFAULT              SET    DESCRIPTION
NEXUS_MODE              string    dev                  unset  What the process is for: dev, test or prod; --mode wins.
NEXUS_APP_URL           string    -                    unset  The public origin absolute links are built on, like https://blog.example.com.
BLOG_COVERS_URL         string    file:storage/covers  unset  Where the posts' cover images are kept: ...
BLOG_DEFAULT_PAGE_SIZE  uint32    10                   set    How many posts a page lists.
```

It shows each variable's type, its default (`required` when there is none), and whether it is set, but never a value. The description is the field's docblock, so a good comment on a config field pays off here. `env` boots nothing, so it works before the database or any secret is in place.

To start a `.env` file from scratch, ask for one:

```sh
echoc run -- env --dotenv > .env
```

Each variable comes under its description, commented out with its default, except the required and secret ones, which are left empty for you to fill in. A required setting left empty (`NAME=`) counts as not set, so the app refuses to boot until you fill it in.

## The mode

Besides its settings, every process runs in a mode that says what it is for:

- `dev`, the default: problem details show the cause of server errors, and the log is pretty.
- `test`: for the test suite; quiet.
- `prod`: internals stay inside the process, and the log is JSON lines.

You may set it with `NEXUS_MODE` or with `--mode`, which wins. Both take `dev` or `development`, `test` or `testing`, and `prod` or `production`:

```sh
NEXUS_MODE=prod echoc run -- serve
echoc run -- serve --mode prod
```

`NEXUS_MODE` is read like any other setting: `--mode` wins, then the real environment, then the `.env` file (or the one `--env-file` names). So a `NEXUS_MODE=prod` line in a server's `.env` is enough. A value that names no mode stops the command instead of falling back to `dev`.

The mode changes a few things at once. [Problems and errors](./problems.md#server-errors-and-the-mode) shows exactly what a client sees in each. In `prod`, extensions whose links leave the app refuse to boot without `NEXUS_APP_URL` (see [absolute links](./routing.md#absolute-links)), and outside `dev`, `serve` and `doctor` warn when it is missing. In `dev`, `serve` warns when it listens where other machines can reach it, since every client would see the cause of every error.

## Reading a variable by hand

Almost everything belongs in a config struct, where it is typed, checked at boot and listed by `env`. For the rare value you only need to peek at, the container holds the same sources as `nexus::Env`:

```echo
string? $region = $payload->get<nexus::Env>()->get('AWS_REGION');
```

It answers `null` when no source has the variable. In tests you may build one from fixed values with `nexus::Env(fixed: [...])`, so a test never depends on the machine it runs on; [testing](./testing.md) shows how.

## Where to next

- [Deployment](./deployment.md): which variables to set where the app runs for real.
- [Problems and errors](./problems.md): what the mode keeps from clients.
- [Extensions and wiring](./extensions.md): taking the config into your services.
