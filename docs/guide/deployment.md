---
description: Shipping a nexus app. One binary that serves, works and migrates; production mode and its settings; logs, clean restarts, and running several servers side by side.
---

# Deployment

Shipping a web app often means juggling several programs: a web server, a process manager, a queue worker, a migration tool, a cron daemon. A nexus app is one binary. The same file answers HTTP, runs your background tasks, pushes your schedule, and migrates your database, each behind a command. Deploying it comes down to building it once, giving it its settings, and starting it the way your platform likes.

This page walks through that, from a single server to several. Don't worry if you have never run a production service before: most of what follows is a short list of settings, and the binary itself tells you when one is missing.

## Building for production

Build a release binary:

```sh
echoc build --release
```

A release build drops the asserts and runtime checks a debug build keeps, and answers several times faster. If you ever serve a debug build by accident, `serve` says so in its log: `serving a debug build: asserts and runtime checks are on, so it answers several times slower than a release build`.

The code `nexus gen` writes is compiled in, so there is no generation or warm-up step at runtime. Copy the binary to your server or into an image, and you're ready for the rest of this page.

## One binary, a few commands

Every command runs the same app, booted from the same extensions list. These are the ones that matter for running it:

| Command | What it does |
|:--|:--|
| `serve` | Answers HTTP, and runs the task workers and the scheduler in the same process. |
| `work` | Runs the task workers and the scheduler without serving HTTP (nexus-work). |
| `migrate` | Applies pending migrations (nexus-carbon); `migrate:status`, `migrate:down` and `migrate:reset` too. |
| `doctor` | Boots the app, checks every route and command has its binding, and warns about risky settings. |
| `env` | Lists every environment variable the app reads. Boots nothing. |
| `routes` | Prints the route table. |

Each command takes `--mode <dev|test|prod>` and `--env-file <path>`. Your own extensions and modules add more, such as the blog's `user:password` or nexus-work's `work:failed`; [commands](./commands.md) shows how.

## Settings

A nexus app reads its settings from the environment, and every module adds its own. Before your first deploy, you'll want the full list. The `env` command prints it, with each variable's type, its default, whether it is set right now, and what it is for:

```sh
./ecobuild/blog env
```

```txt
NAME                    TYPE      DEFAULT         SET    DESCRIPTION
NEXUS_MODE              string    dev             unset  What the process is for: dev, test or prod; --mode wins.
NEXUS_LISTEN            string    127.0.0.1:3246  unset  Where serve listens; --listen wins.
NEXUS_SHUTDOWN_GRACE    duration  30s             unset  How long serve lets requests in flight finish once stopped; a second signal quits at once.
NEXUS_APP_URL           string    -               unset  The public origin absolute links are built on, like https://blog.example.com.
...
```

Values are never printed, only whether they are set, so you may run it on a production machine without leaking a secret into your terminal history. Because `env` boots nothing, it works before the database exists or the environment is complete.

For a starting point, `--dotenv` prints the same list as a `.env` file. Each variable sits under its description, commented out with its default, except the required and secret ones, which are left for you to fill in:

```sh
./ecobuild/blog env --dotenv > .env
```

The app reads `.env` from the directory it runs in, or the file `--env-file` names. A missing file is fine. A variable set in the process environment always wins over the file, so your platform's secrets take precedence over anything left lying in a `.env`. [Configuration](./configuration.md) explains how settings are checked when the app boots.

### Production mode

Set `NEXUS_MODE=prod` (or pass `--mode prod`) on every production process. Production mode changes a few things at once:

- Problems sent to clients no longer carry the cause of a `500`; the log still has it.
- The log is written as JSON lines on stdout instead of pretty lines on stderr.
- Commands that undo things, like `migrate:down` and `migrate:reset`, want `--force`.
- Settings that are only safe on your machine stop the boot, such as an open [debug console](./debug.md) gate.

`serve` warns you if it runs in dev mode on an address other machines can reach, because clients would then see the cause of every error.

### The public URL

Some links leave your app: an OAuth issuer, the page a sign in provider sends the browser back to, absolute links in emails. Without help, nexus builds those on the `Host` header the client sent, which any client may set to anything. Set `NEXUS_APP_URL` to your public origin and nexus uses it instead:

```sh
NEXUS_APP_URL=https://blog.example.com
```

In production, an extension whose links leave the app ([OAuth](./oauth.md), [sign in with Google](./connect.md)) refuses to boot without it, with a message saying which links are at stake. In other modes, `serve` and `doctor` warn about it instead. It must be absolute, with a scheme and a host; anything else stops the boot.

### Checking before you start

Once the settings are in place, `doctor` boots the app exactly as `serve` would, without listening:

```sh
NEXUS_MODE=prod ./ecobuild/blog doctor
```

When all is well, it prints one line starting with `ok:`, with the number of routes and commands and the mode. It fails if a setting is missing or invalid, a route or command has no binding, or a database can't be opened, and warns about actions no route reaches and risky settings. It's a cheap step to put in front of every deploy.

## Migrating the database

Run pending migrations with the same binary, before the new version starts serving:

```sh
NEXUS_MODE=prod ./ecobuild/blog migrate
```

`migrate` applies only what has not run yet, so running it on every deploy is safe. With several servers, run it once, from one place, before you roll the new version out to any of them. [Database](./database.md) covers migrations, `migrate:status`, and rolling back.

## Serving

Start the server on an address your reverse proxy reaches:

```sh
NEXUS_MODE=prod NEXUS_LISTEN=0.0.0.0:3246 ./ecobuild/blog serve
```

nexus speaks plain HTTP/1.1; TLS belongs to the proxy or load balancer in front. Tell nexus which addresses that proxy uses, so it believes the client address and scheme the proxy forwards:

```sh
NEXUS_HTTP_TRUSTED_PROXIES=10.0.0.0/8
```

A proxy should pass `X-Forwarded-For` and `X-Forwarded-Proto` along. In nginx, for example:

```txt
location / {
    proxy_pass http://127.0.0.1:3246;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

[The HTTP server](./http.md) covers trusted proxies, worker threads (`--workers`), body limits and timeouts. One of those deserves a mention here: keep `NEXUS_HTTP_IDLE_TIMEOUT` (75 s by default) longer than your load balancer's keep-alive, or it reuses connections your app has just closed and answers `502`.

For your load balancer's health check, point it at a cheap action. The blog binds `GET /health`, which answers without touching the database.

## Logs

In production the log goes to stdout as one JSON object per line, ready for whatever collects your container's or service's output. Each request line carries its request id, the status and how long it took.

`NEXUS_LOG` sets the lowest level written (`info` by default), and `NEXUS_LOG_FORMAT` switches to `logfmt` or `pretty` if you prefer. If you would rather write to a file as well, `NEXUS_LOG_FILE` appends to one and `NEXUS_LOG_ROTATE` rotates it. `serve` writes the log on a thread of its own, so a slow terminal or disk never holds up a request. [Logging and tracing](./logging.md) has every option.

## Stopping and restarting

A deploy usually means stopping the old process and starting the new one. Send `SIGTERM` (or `SIGINT`) and `serve` stops in order:

1. It stops taking connections. Idle ones close; requests in flight finish.
2. Every extension's `drain` hook runs, last listed first: the scheduler and task feeders stop, and running tasks get `NEXUS_WORK_GRACE` to finish.
3. The process exits with `0`.

Requests in flight get `NEXUS_SHUTDOWN_GRACE` (30 s) to finish. If one is still running after that, or a second signal arrives, the process logs `stopping took too long` and exits anyway. Give your process manager a stop timeout a little longer than both graces, so it never kills the process mid-drain. With systemd, for example:

```txt
[Service]
Environment=NEXUS_MODE=prod
EnvironmentFile=/etc/blog/env
ExecStartPre=/srv/blog/blog migrate
ExecStart=/srv/blog/blog serve --listen 0.0.0.0:3246
KillSignal=SIGTERM
TimeoutStopSec=70
```

So, what if the process is killed outright, by a crash or `kill -9`? Tasks on a distributed queue are stored in the database, so they survive: once their lease passes, another worker claims them and runs them again. Tasks on an async queue live in memory only and are lost. [Tasks and queues](./tasks.md) explains which to choose.

## Splitting web and work

By default `serve` does everything: it answers HTTP, runs task workers, and pushes scheduled tasks. That's the simplest setup, and often all you need.

As your app grows, you may want background work on machines of its own, so a burst of tasks never slows down requests. Two flags turn the background parts off in a `serve` process:

```sh
./ecobuild/blog serve --no-work --no-schedule
```

`--no-work` runs no task workers here; `--no-schedule` pushes no scheduled tasks from here. Then run the background half with `work`, which runs the workers and the scheduler without serving HTTP:

```sh
./ecobuild/blog work
```

`work` stops the same way `serve` does: on `SIGTERM` it stops the scheduler and the feeders and lets running tasks finish within `NEXUS_WORK_GRACE`. A task pushed by a `serve --no-work` process waits in its distributed queue until a `work` process claims it.

## Running several servers

Running the same binary on several machines (or several containers) behind one load balancer needs nothing special from nexus itself. What it needs is that every piece of state your app keeps lives somewhere all of them reach, rather than in one process's memory. Here is what to check, module by module:

- **Database.** Every server points `NEXUS_DATABASE_URL` at the same database. Signed sessions live there (nexus-auth-carbon), so a client may land on any server.
- **Secrets.** `NEXUS_AUTH_KEY` must be the same everywhere, since every session's secret is derived from it; so must `NEXUS_FILES_KEY`, which signs file links.
- **Tasks.** Use a distributed queue with nexus-work-carbon, so tasks are stored in the database and claimed under a lease by whichever server is free. The scheduler stores each slot once across servers when it pushes into a distributed lane; a push into an async lane happens on every process that schedules, so with several schedulers you would run that task several times.
- **Realtime.** By default a broadcast reaches only the sockets of the process that sent it. Add `nexus::realtime::redis::Extension()` and set `NEXUS_REALTIME_URL=redis://...`, and a broadcast from any process (a request, a task in `work`, a command) reaches every server's sockets.
- **Cache.** `NEXUS_CACHE_URL=memory:` keeps entries per process. Add `nexus::cache::redis::Extension()` and point `NEXUS_CACHE_URL` at Redis to share them.
- **Files.** A `file:` disk lives on one machine's filesystem. Use an `s3://` disk with `nexus::files::s3::Extension()` and the `NEXUS_FILES_S3_*` settings, so every server sees the same files.

You may list these extensions from day one. Each steps aside when its URL points elsewhere, so the same list runs on your laptop with `local:`, `memory:` and `file:` and in production on Redis and S3, changed only by settings. The blog does exactly that with `nexus::realtime::redis::Extension()` and `nexus::files::s3::Extension()`. [Realtime channels](./realtime.md), [cache](./cache.md) and [files](./files.md) cover each in detail.

::: tip
`examples/blog/scripts/smoke.sh` runs the blog much like production: it migrates, serves, stops with `SIGTERM`, kills a server with `-9` and lets `work` pick up the tasks it left, and serves files from a second server. It's a good place to see these pieces working together.
:::

## Where to next

- [The HTTP server](./http.md): listen address, worker threads, limits and timeouts.
- [Configuration](./configuration.md): how settings are read and checked.
- [Tasks and queues](./tasks.md): async and distributed queues, and what survives a restart.
- [Logging and tracing](./logging.md): log levels, formats and files.
