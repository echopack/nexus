---
description: The app binary's command line. The built-in serve, routes, doctor and env, the commands extensions bring, and commands of your own that call the same services your actions do.
---

# Commands

A web app needs more than requests. You run migrations before a deploy, work a task queue on a separate machine, reset a user's password at two in the morning, or look at one post without opening a browser. In many frameworks that means a second program, or scripts that half reimplement the app.

In nexus your app is one binary, and its command line is part of it. `serve` answers HTTP, `migrate` changes the database, and your own commands sit right next to them, wired by the same extensions and calling the very same services your actions use.

## Running a command

During development you may run any command through the compiler. Everything after `--` goes to your app:

```sh
echoc run -- serve
echoc run -- routes
echoc run -- posts:show 1
```

The binary `echoc build` produces takes exactly the same arguments, so in production that is `blog serve` or `blog migrate`. Run it without a command to see every command it has, or add `--help` to any command for its options.

Every command also takes two options of its own:

| Option | What it does |
|:--|:--|
| `--mode <mode>` | What the process is for: `dev`, `test` or `prod`. Defaults to `NEXUS_MODE` (from the environment, else the env file), else `dev`. |
| `--env-file <path>` | A `.env` file to read. Defaults to `.env`; the process's own environment wins over it. |

```sh
echoc run -- doctor --mode prod --env-file deploy/staging.env
```

The app only boots when a command asks for it. `env`, for example, never boots, so it works before the database is even reachable. [Configuration](./configuration.md) covers the environment and the `.env` file in full.

## The built-in commands

The core brings four commands to every app.

### serve

`serve` boots the app and answers requests through its transport until it gets `SIGINT` or `SIGTERM`. Requests in flight get `NEXUS_SHUTDOWN_GRACE` (30 seconds by default) to finish, and a second signal quits at once.

| Option | What it does |
|:--|:--|
| `--listen <host:port>` | Where to listen. Defaults to `NEXUS_LISTEN` (from the environment, else the env file), else `127.0.0.1:3246`. |
| `--workers <n>` | Worker threads, `0` for one per core. A count that is no number, or more than 2147483647, is refused. |
| `--no-work` | Run no task workers in this process. |
| `--no-schedule` | Push no scheduled tasks from this process. |

By default one `serve` process does everything: it answers HTTP, works the task queues and pushes the scheduled tasks. Once you run dedicated workers, start your web servers with `--no-work`. [The HTTP server](./http.md) has more on serving, and [deployment](./deployment.md) on splitting the roles up.

### routes

`routes` boots the app and prints its route table, most specific first: the methods, the path, the action that answers, and the route's middleware.

### doctor

`doctor` boots the app the way `serve` would, without serving. It reads the config, wires the container, checks that every route and every command has its binding, and then warns about what is likely a mistake: actions no route reaches, and settings that are risky outside a developer's machine.

```txt
ok: 24 routes, 21 commands, mode dev
```

It exits with `1` when anything is broken, which makes it a good last step in a deploy script before the new version takes traffic.

### env

`env` lists every environment variable the app reads, the core's and each module's, with its type, its default and whether it is set. It never shows a value. With `--dotenv`, it prints a `.env` file to start from instead.

```txt
NAME                TYPE      DEFAULT       SET    DESCRIPTION
NEXUS_APP_URL       string    -             unset  The public origin absolute links are built on.
NEXUS_WORK_THREADS  uint32    2             set    Worker threads of each async queue ...
```

## Commands from extensions

Extensions add commands of their own the moment you list them in your app. These are the ones nexus's modules bring:

| Command | From | What it does |
|:--|:--|:--|
| `migrate`, `migrate:status`, `migrate:down`, `migrate:reset` | nexus-carbon | Run, list, undo the last batch of, or undo every [migration](./database.md). |
| `work` | nexus-work | Run task workers and the scheduler until stopped, without HTTP. |
| `work:failed`, `work:retry`, `work:cancel` | nexus-work | List failed [tasks](./tasks.md), send them back to their queue, cancel a waiting one. |
| `work:schedule`, `work:graph` | nexus-work | List the [schedule](./scheduling.md); show how one task's pipeline stands. |
| `auth:prune` | nexus-auth | Delete expired tokens, sessions, grants and sign in attempts. |
| `cache:clear` | nexus-cache | Forget every entry of the [cache](./cache.md). |
| `files:list`, `files:check` | nexus-files | List a disk's [files](./files.md); write, read and delete a probe on one. |
| `realtime:send` | nexus-realtime | Broadcast an event to a [realtime channel](./realtime.md). |

Two extensions may never add the same name. If they do, the binary refuses to start and names both.

## Writing your own command

So, what about the blog's `posts:show`? It prints one post from the command line, through the same `PostService` that `GET /v1/posts/{id}` uses. Writing one takes three small pieces: the options, the command class, and a line of wiring.

### Describing the options

A command's options are an `#[nexus::input]` struct, exactly like an action's body. Each field is an option, and `#[nexus::positional]` makes one a word after the command's name instead:

```echo title="src/Inputs/PostRef.eco"
namespace Blog::Inputs;

/**
 * Which post a command is about.
 */
#[nexus::input]
public struct PostRef
{
    /**
     * The post's id.
     */
    #[nexus::positional]
    public int64 $id;
}
```

The doc comment of each field becomes its line in `--help`. Since this is an ordinary input, every [rule](./input.md) works here too, and a refused value is reported before your command runs.

### The command class

A command class conforms to `nexus::Cli`. Like an action, it takes its services through its constructor and does its work in `handle()`, which receives the payload, libcommand's output, and the input:

```echo title="src/Commands/ShowPostCommand.eco"
namespace Blog::Commands;

use Blog::Inputs::PostRef;
use Blog::Services::PostService;

/**
 * Prints one post: its title, author, tags and text.
 */
public class ShowPostCommand : nexus::Cli
{
    private PostService $posts;

    public constructor(PostService $posts)
    {
        $this->posts = $posts;
    }

    public function handle(nexus::Payload& $payload, command::CLIContext& $out, PostRef $in) : status<nexus::Problem>
    {
        $p = try $this->posts->find($in->id);
        $out->line("#{$p->id}  {$p->title}");
        // ...
        $out->gap();
        $out->line($p->body);
        return .ok;
    }
}
```

The class's doc comment is its help. A command prints what it has to say itself, and returns `.ok` or a problem. A problem is printed as an error and the command exits with `1`, so `posts:show 999` says the post was not found, just as the API would.

The input is optional: a command that takes no options leaves the third parameter out.

### Wiring it up

Commands are wired in a `commands()` method, next to where the rest of that part of the app is wired. With nexus-app, each provider has one. `bindCommand` binds the class with its factory, and `name` says what the command line calls it:

```echo title="src/Providers/PostsProvider.eco"
/**
 * The command line door onto the same service.
 */
public function commands(nexus::Commands& $cmds) : void
{
    $cmds->bindCommand<ShowPostCommand>((Container $c) => ShowPostCommand($c->get<PostService>()))
        ->name('posts:show');
    $cmds->bindCommand<CreatePostCommand>((Container $c) => CreatePostCommand($c->get<PostService>()))
        ->name('posts:create');
}
```

The app's extension then hands the call on to its providers:

```echo title="src/App.eco"
public function commands(nexus::Commands& $cmds) : void
{
    nexus::App::commands($cmds, $this->providers());
    $cmds->add(SetPassword());
}
```

A name is lowercase letters, digits, `-` and `:`. A colon groups related commands, like `posts:show` and `posts:create`. You may call `name` a second time to offer the same command under another name.

The command line reads `commands()` before the app boots, so it only records what you bind. The bindings land in the container when a command boots the app.

And that's it:

```sh
echoc run -- posts:show 1
```

### Options, flags and lists

The field's type decides what kind of option it becomes. Names are written in kebab case, so a field `$passwordConfirmation` is `--password-confirmation`. The blog's `posts:create` shows the rest:

```echo title="src/Inputs/AuthoredPost.eco"
#[nexus::input]
public struct AuthoredPost
{
    /**
     * The id of the user who writes it.
     */
    public int64 $author;

    /**
     * The title, 3 to 120 characters.
     */
    #[nexus::rule: { min: 3, max: 120 }]
    public string $title;

    // ...

    /**
     * A tag; give it once per tag.
     */
    #[nexus::rule: { max: 5 }]
    public array<string> $tags = [];
}
```

A scalar is an option with a value, an array is given once per item, and a `bool` is a flag that is either there or not:

```sh
echoc run -- posts:create --author 1 --title 'Hello, Echo' --body 'First post.' --tags echo --tags nexus
```

A refused option is printed per field, with the message the API would send, in the language `LANG` names (see [translations](./i18n.md)):

```txt
title: The title field must be at least 3 characters.
```

A few things can't come from a command line, and `nexus gen` tells you so when it reads the input: a nested input, a JSON field, or a file upload (take a path instead, and read the file). A `bool` option may not default to `true`, since a flag can only switch something on; left out, it is `false`, with or without a default written. A positional is a single value, not a list, and a required positional must come before the optional ones.

### What a command runs on

A command runs on a payload of its own, just like a task: it has its own child container, so a service bound `scoped:`, such as a database session, is fresh for the run, and its log lines carry the command's name. That is why `PostService` works unchanged. As far as the service is concerned, this is just another door, and the blog's MCP tools are a third one onto the same code.

## Hand-written commands

`nexus::Cli` covers most commands. Occasionally you may want full control: options that don't fit an input, a command that runs without booting the app, or work that needs the kernel itself. For that you may implement `nexus::Command` directly. The blog's `user:password` does:

```echo title="src/Commands/SetPassword.eco"
public class SetPassword : nexus::Command
{
    public const function name() : string
    {
        return 'user:password';
    }

    public const function summary() : string
    {
        return "set a user's password";
    }

    public const function options() : array<nexus::CommandOption>
    {
        array<nexus::CommandOption> $out = [];
        $out[] = nexus::CommandOption(value: 'email', '<email>', 'the user');
        $out[] = nexus::CommandOption(value: 'password', '<password>', 'the new password');
        return $out;
    }

    public function run(nexus::Invocation& $in) : int32
    {
        $kernel = guard $in->kernel() else {
            return 1;
        };
        $email = $in->value('email');
        // ...
        io::println("password set for {$email}");
        return 0;
    }
}
```

An option is a `flag:`, a `value:` with an optional fallback, a `list:` given once per value, or a `positional:` word. `run` reads them from the `nexus::Invocation` with `value`, `flag`, `list` and `positional`, prints for itself, and returns the exit code.

`$in->kernel()` boots the app the first time it is called and hands back the same kernel after that. When the boot fails, it prints why and returns null, so `guard ... else { return 1; }` is all you need. For a payload with its own container, as a `Cli` command gets, ask the kernel for one with `$kernel->background('command', 'user:password')` and release it with `nexus::Kernel::finish($payload)` when you are done.

Add a hand-written command with `$cmds->add(...)`, as the blog's `commands()` above does with `SetPassword()`.

## Where to next

- [Input and validation](./input.md): every rule an option may carry.
- [nexus gen](./generator.md): what is generated for a `nexus::Cli` class.
- [Deployment](./deployment.md): running `migrate`, `serve` and `work` in production.
