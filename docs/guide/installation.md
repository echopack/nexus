---
description: Add nexus to an Echo project, hook up nexus gen, and answer your first request.
---

# Installation

Let's get a nexus app answering requests. By the end of this page you'll have a small project with one endpoint, built and served from a single binary. It takes four files.

## What you need

nexus is an Echo library, so you need the Echo toolchain: `echoc` 0.15 or newer, and `epm` to fetch packages. If you don't have them yet, the [Echo installation guide](https://echoc.dev/guide/installation) walks you through it.

That's all. There is no separate nexus installer: the `nexus` developer tool ships inside the nexus package, and your build runs it for you.

## The manifest

A nexus app is an ordinary Echo module. Create a directory for it and add a `module.eco`:

```echo title="module.eco"
#[module: "blog"]
#[version: "0.1.0"]

#[requires: "echopack/nexus" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/http" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/app" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/container" { version: "^0.1.0", source: git "https://github.com/echopack/container" }]
#[requires: "echolang/libjson" { version: "^0.3.0", source: git "https://github.com/echolang/libjson" }]

// write the generated code before every build
#[hook: before_build { run: "nexus", args: ["gen"] }]

#[sources: "src/**/*.eco"]
#[if: !NEXUS_NOGEN]
#[sources: ".nexus/*.eco"]
#[end]

#[target: exe { name: "blog", entry: "src/main.eco" }]
```

Three parts of this deserve a word:

- **The requirements.** The core is `echopack/nexus`; every other module (the HTTP server, the database, auth, ...) lives in the same repository and is required by its path, such as `echopack/nexus/modules/http`. You only pull in what you use. The [modules](./modules.md) page lists them all.
- **The hook.** `nexus gen` runs before every build and writes `.nexus/nexus.eco`: the code that calls your actions, decodes your inputs and loads your config. You never write that code, and you never have to remember to regenerate it.
- **The `NEXUS_NOGEN` guard.** While `nexus gen` reads your module, it leaves its own previous output out, so a stale file can never confuse it. If you forget the guard, `nexus gen` tells you the exact lines to add.

Now fetch the packages:

```bash
epm install
```

## The entry point

`main.eco` hands the process to nexus, along with the list of extensions your app is made of:

```echo title="src/main.eco"
nexus::Kernel::main(Blog::extensions());
```

```echo title="src/Extensions.eco"
namespace Blog;

/**
 * Everything the blog is made of, in boot order.
 */
public function extensions() : array<nexus::Extension>
{
    array<nexus::Extension> $all = [
        // the HTTP/1.1 server behind `serve`
        nexus::http::Extension(),

        // the blog itself, always last
        Blog::App(),
    ];
    return $all;
}
```

The app comes last, so its bindings may replace anything a module bound. We'll add more modules to this list as the blog grows.

## Your first action

An action is one endpoint: a class with a `handle()` method. Let's write a health check:

```echo title="src/Actions/Health.eco"
namespace Blog::Actions;

/**
 * Whether the blog is up.
 */
public class Health : nexus::Action
{
    public function handle() : json::Value
    {
        $o = json::object();
        $o['ok'] = true;
        return $o;
    }
}
```

And the app, which says where it answers:

```echo title="src/App.eco"
namespace Blog;

use Blog::Actions::Health;

public class App : nexus::Extension
{
    public function name() : string
    {
        return 'blog';
    }

    public function services(nexus::Services& $s) : status<nexus::BootError>
    {
        $app = nexus::App($s);
        $app->bindAction<Health>(() => Health())
            ->route([.get], '/health');
        return .ok;
    }
}
```

## Running it

Now we are ready to start the server:

```bash
echoc run -- serve
```

The build runs `nexus gen` first, then compiles and starts the app on `127.0.0.1:3246`. In another terminal:

```bash
curl -i http://127.0.0.1:3246/health
```

```txt
HTTP/1.1 200 OK
Content-Type: application/json
X-Request-Id: 01JD...

{"ok":true}
```

Every response carries an `X-Request-Id`, and the server logged one line for the request with the same id. If you ask for a path that doesn't exist, you get a `404` as an RFC 9457 problem document, without writing a line of error handling.

You may pick another address with `--listen`, or `NEXUS_LISTEN` in the environment or the `.env` file:

```bash
echoc run -- serve --listen 0.0.0.0:8080
```

## A few commands for free

The binary you just built already has a command line. You may ask it what it knows:

```bash
echoc run -- routes    # the route table, most specific first
echoc run -- env       # every setting the app reads: type, default, whether it is set
echoc run -- doctor    # boots the app and warns about unreachable actions and risky settings
```

[Commands](./commands.md) covers these and how to add your own.

## What to commit

`.nexus/` and the other generated folders are source: commit them. That way a reader of your repository sees exactly what runs, and CI can check that nothing is stale with `nexus gen --check`. Build output and packages are not:

```txt title=".gitignore"
ecobuild/
vendor/
```

## Where to next

- [Your first API](./tutorial.md): grow this into a posts API with validation, a database and a transformer.
- [Project layout](./layout.md): where each kind of class lives as the app grows.
- [The request lifecycle](./lifecycle.md): what just happened when you sent that request.
