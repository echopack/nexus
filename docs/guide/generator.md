---
description: What nexus gen reads, what it writes, when it runs, and the mistakes it catches before your code compiles.
---

# nexus gen

nexus asks you to wire your app by hand: which action answers which route, which handler hears which signal, which command has which name. That part is a decision, and you make it in code you can read. But a lot of what an app needs is not a decision at all. Once `handle()` says it takes an `int64 $id` and a `nexus::Body<NewPost>`, there is exactly one right way to read a request for it. Once a config struct lists its fields and their types, there is one right way to read them from the environment.

Writing that code by hand is tedious and easy to get subtly wrong. Doing it at run time with reflection costs every request, and only fails once a request arrives. `nexus gen` takes a third way: **registration by hand, generation by type**. It reads your types before the build and writes the code that follows from them, as plain Echo you can open and read.

You will rarely run it yourself. Don't worry if this page feels like more detail than you need right now; it is here for the day you want to know what happens under the hood, or why a build stopped.

## How it runs

`nexus gen` is a tool the core nexus module offers, and your app's `module.eco` runs it before every build with a hook:

```echo title="module.eco"
#[hook: before_build { run: "nexus", args: ["gen"] }]

#[sources: "src/**/*.eco"]
#[if: !NEXUS_NOGEN]
#[sources: ".nexus/*.eco"]
#[end]
#[if: !CARBON_NOGEN]
#[sources: ".carbon/*.eco"]
#[end]
```

From then on every `echoc run`, `echoc build` and `echoc test` brings the generated code up to date first, and you never have to think about it. When you would like to run it by hand, `epm run` finds the tool through your dependency on nexus:

```sh
epm run nexus gen
```

### Why the guard

Notice that `.nexus/*.eco` is only compiled when `NEXUS_NOGEN` is not defined. That guard is what lets the generator read your program at all.

To learn your types, `nexus gen` compiles your program once with `NEXUS_NOGEN` (and `CARBON_NOGEN` and `REST_NOGEN`) defined, which leaves every generated directory out. A generated file that is stale, because you just renamed an action, can never stand in the way of writing its replacement. Code of yours that uses generated names will not compile in that pass, and that's fine: the compiler still prints every declaration, which is all the generator needs.

A manifest without the guard is refused, with the lines to add:

```txt
nexus: module.eco does not wire the generated code; add:

#[if: !NEXUS_NOGEN]
#[sources: ".nexus/*.eco"]
#[end]
```

## What it reads

The generator makes **one pass** over the whole program: `echoc build -p decls`, which prints every declaration as JSON instead of building. It then finds what it writes code for by what each type conforms to or is tagged with:

| It finds | By |
|:--|:--|
| Actions | classes conforming to `nexus::Action` |
| Inputs | structs tagged `#[nexus::input]` |
| Configs | structs tagged `#[nexus::config]` |
| Tasks | structs conforming to `nexus::work::Task` |
| Commands | classes conforming to `nexus::Cli` |
| MCP tools | classes conforming to `nexus::mcp::Tool` |
| Mapped models | models and structs with `#[nexus::expose]` fields |
| Log records | structs tagged `#[nexus::log]` |
| Mails | structs tagged `#[nexus::mail]`, with their templates under `resources/emails/` |

It also learns what the rest of the program declares, so it can check names across modules: which classes are middleware that `#[nexus::through]` may name, which rule classes `check:` may name, which enums an input field may hold.

### carbongen and restgen

Other generators read the same pass instead of making their own. When your manifest wires `.carbon/` behind `CARBON_NOGEN`, as the blog's does, `nexus gen` builds and runs carbongen on it, which writes `.carbon/models.eco` for your [database](./database.md) models. `.rest/` behind `REST_NOGEN` does the same for restgen. One hook, one pass, every generated file.

The tool is found through your module's own dependencies, so you need to depend on `carbon` (or `rest`) directly. Otherwise the generator says so: `module.eco wires .carbon/ but no dependency offers carbongen; depend on carbon directly`.

## What it writes

Everything goes into one file, `.nexus/nexus.eco`. For each thing it found:

- **an action** gets a `<Action>Dispatch` struct, the code that reads what `handle()` asks for, calls it and turns the result into a response; plus what it offers MCP clients when the action is offered as a tool,
- **an input** gets a `<Input>Decoder` that reads it from JSON, a form, a query string or a command line, and checks every rule,
- **a config** gets its loader, which reads it from the environment and binds it, and a row per variable for the `env` command,
- **a task** gets a `<Task>TaskCodec` that stores it and reads it back,
- **a command** gets a `<Command>Cli`, the `nexus::Command` that reads its options and runs it,
- **an MCP tool** gets a `<Tool>Mcp`,
- **a mapped model** gets a `<Model><Shape>Mapping` per shape,
- **a log record** gets the `nexus::log::record` overload `emit` asks for,
- **a mail** gets a `nexus::mail::render` overload with its templates compiled in,

and the `#[nexus::message]` overrides of your inputs go into a table for the English catalog.

You are free to open it. Here is what `DeletePost`'s `handle(nexus::Payload& $payload, int64 $id)` turns into:

```echo title=".nexus/nexus.eco"
internal static function dispatch(nexus::Payload& $payload) : nexus::Response
{
    int64 $argId = guard nexus::Param::int64($payload, 'id') else ($p) {
        return nexus::Reply::problem($payload, $p);
    };
    $action = $payload->get<Blog::Actions::Posts::DeletePost>();
    $result = $action->handle($payload, $argId);
    return nexus::Reply::of($payload, $result);
}
```

Nothing magical: read the path parameter, resolve the action from the request's container, call it, answer. You should never edit this file. It says so at the top, and the next build would overwrite your change anyway.

### What it does not write

Routes, command names, tool names and task queues are not in the generated file. Those are decisions, and you make them where the app is wired. The generated code knows *how* each action runs, never *where* it answers.

### How the kernel finds it

Each module that declares any of the above has its own `.nexus/nexus.eco`, and each of those ends in a few functions tagged with the module's name, such as `#[nexus::generated: 'nexus-blog']` and `#[nexus::configs: 'nexus-blog']`. The kernel collects every one of them at compile time, by attribute and keyed by type. There is no list of modules to keep in sync, and nothing is looked up by string at run time.

### Commit it

The generated files belong in git, next to the code they come from. The blog commits `.nexus/nexus.eco` and `.carbon/models.eco`. You see changes to them in review, your editor can navigate into them, and `echoc build --no-hooks` still compiles the program. A library that generates code commits it too; an app that depends on it compiles what was published and never runs the library's generator.

## When it runs, and when it doesn't

A hook runs before every build, so it had better be quick when nothing changed. `nexus gen` keeps a stamp of everything the generated file depends on: every `.eco` file of your module and of the path dependencies its `module.eco` names, the mail templates, `epm.lock.json` and the compiler. When the stamp matches and the generated files exist, it skips the pass entirely:

```txt
nexus gen  up to date
```

Otherwise it makes the pass, says what it found, and writes the file only when its content changed:

```txt
nexus gen  23 action(s), 12 input(s), 1 config(s), 3 task(s), 2 command(s), 1 tool(s), 1 log record(s), 1 mail(s)
wrote      .nexus/nexus.eco
```

## Mistakes it catches

Because the generator reads every signature before anything compiles, it can tell you about a mistake in terms of what you wrote, with the file and line, instead of leaving you with an error deep inside generated code.

Say an action asks `handle()` for the signed in user directly:

```echo
public function handle(nexus::Payload& $payload, Caller $me) : result<nexus::Response, nexus::Problem>
```

The build stops with:

```txt
nexus: src/Actions/Posts/CreatePost.eco:12: handle() parameter $me of type Blog::Types::Caller is not something nexus can provide; let a middleware the action names in #[nexus::through] put it in the payload, and read it with $payload->state<Blog::Types::Caller>()
```

The line is the declaration's: the class, the struct, or the field at fault. Every problem is listed at once, one per line, so a rename that breaks five types tells you about all five. A few of the others you may meet, each after its file and line:

- `nexus::Body<Blog::Inputs::NewPost> needs #[nexus::input] on Blog::Inputs::NewPost`
- `handle() parameter $page is bool; a loose parameter comes from the path, which holds a string or an integer, and a query comes in a nexus::QueryOf<T>`
- `#[nexus::through] names Blog::Middleware::RequireEditor, which is not a class conforming to nexus::Middleware`
- `field $pageSize is not read from the environment and has no default; give it a default or #[nexus::env]`
- `option $cover of Blog::Inputs::CoverUpload is a file upload, which a command line cannot give; take a path and read it`

And if the generator did not run at all, say you built with `--no-hooks` after adding an action, the kernel still catches it at boot rather than at the first request: `Blog::Actions::Posts::ShowPost is routed but nexus gen wrote no dispatcher for it; is it a class conforming to nexus::Action, and did nexus gen run?`

## Reference

```txt
usage: nexus <command> [options]

  gen              write .nexus/nexus.eco for this module
  gen --check      exit 1 when .nexus/nexus.eco is out of date
  gen --force      regenerate even when nothing changed

  --echoc <path>   the compiler, default $ECHOC or echoc on PATH
  --quiet          say nothing on success
```

#### gen

Writes the generated files of the module in the working directory, and runs the generators the manifest wires. It exits with `1` and the reasons when anything does not fit.

#### --check

Generates in memory and compares, without writing. It exits with `1` and `.nexus/nexus.eco is out of date; run nexus gen` when the committed file is not what generating would write now, and runs carbongen and restgen in their check mode too. Put it in CI, so a pull request cannot forget to commit its generated code. nexus's own CI runs it for every module and the blog.

#### --force

Ignores the stamp and makes the pass even when nothing seems to have changed.

#### --quiet

Prints nothing on success. Problems are still printed.

#### --echoc

The compiler to make the pass with. Without it, `nexus gen` uses `$ECHOC`, which a build sets to the `echoc` that runs the hook, and else `echoc` on your `PATH`.

## Where to next

- [Actions](./actions.md): what `handle()` may ask for and return.
- [Input and validation](./input.md): what an input decoder checks.
- [Configuration](./configuration.md): the structs a config loader reads.
