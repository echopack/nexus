---
description: Tasks as plain structs, run inline, on worker threads, or on a queue every server shares. Retries, exclusive keys, pipelines, and the work commands.
---

# Tasks and queues

Some work does not belong in a request. Sending a welcome mail can take a few seconds and may fail because the mail server is away; resizing a cover or counting every user is work the person who clicked the button should not wait for. You would like to say "do this soon, and try again if it fails", answer the request, and move on.

nexus-work is how you do that. A task is a struct: its fields are its data, its `handle()` is the work, and it says for itself how often it is tried and whether two runs of it may overlap. The very same task value can run inline on the caller's payload, on worker threads in this process, or on a distributed queue that every server of your app shares.

To add it, require the module in your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/work" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then put its extension in your app's extension list, before your app's own extension (the one that binds queues):

```echo title="src/Extensions.eco"
// tasks, queues, workers and the scheduler
nexus::work::Extension(),
```

If the extension comes after the one that binds a queue, the boot stops and tells you to move it up.

## Your first task

A task is a struct conforming to `nexus::work::Task`, with one method you must write: `handle()`. Here is the blog's simplest, which notes how many users the blog has:

```echo title="src/Tasks/CountUsers.eco"
namespace Blog::Tasks;

use Blog::DB::Model::UserRepository;

/**
 * Notes how many users the blog has; it runs after a welcome, in the same pipeline.
 */
public struct CountUsers : nexus::work::Task
{
    public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
    {
        $users = $payload->get<UserRepository>();
        uint64 $n = guard $users->find()->count() else ($e) {
            return .error(.retry("counting users: {$e}"));
        };
        $payload->log->info('users counted', ['users' => $n as int64]);
        return .ok;
    }
}
```

`handle()` gets a `nexus::Payload&`, just like an [action](./actions.md) does. On a worker it is a payload of the task's own, with a fresh child container, so services bound per request (a database session, for instance) are fresh for each run, and its log is stamped with the task's name and id.

A task with data simply has fields. The blog's welcome needs to know whom to welcome, and in which language:

```echo title="src/Tasks/SendWelcome.eco"
public struct SendWelcome : nexus::work::Task
{
    public int64 $user;
    public string $locale = 'en';

    public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
    {
        // ... find the user, mail them, note when
    }
}
```

You build one like any struct, `SendWelcome($user: 5)`, and keep its memberwise constructor: `nexus gen` refuses a task with a handwritten one. Every field must be public, and of a type a task can store: integers, `float64`, `bool`, `string`, `array<string>`, `array<int64>`, and their nullables. That is what lets a [distributed queue](#distributed-queues) write the task down and read it back on another server.

### When a task fails

`handle()` answers `status<nexus::work::Failure>`, and the failure says what the worker should do next:

- `.retry(why)` tries again, backing off: 10 seconds after the first try, four times longer after each one after it, at most an hour.
- `.later(after, why)` tries again once `after` has passed.
- `.giveUp(why)` does not try again. Trying again would change nothing: the user is gone, the input is wrong.

Here is how `SendWelcome` tells the two kinds of trouble apart:

```echo
$found = guard $users->find()->get($this->user) else ($e) {
    return .error(.retry("the users table: {$e}"));
};
$u = guard $found else {
    return .error(.giveUp("user {$this->user} is gone"));
};
```

A database that hiccups is worth another try. A user who no longer exists is not.

When the trouble arrives as a `nexus::Problem`, `nexus::work::Failure::of()` picks for you: a `5xx` retries, a `429` waits its `Retry-After`, and anything else (a `404`, a `422`) gives up. The blog's welcome uses it on the mailer's error:

```echo
guard $mailer->send($msg) else ($e) {
    return .error(nexus::work::Failure::of($e->problem()));
};
```

Once a task has used up its tries, or gave up, it has failed for good. Its run logs `task failed` with the reason, and a stored task is kept with the failed ones, where you may [send it back](#the-work-commands) later.

### Saying how a task is tried

Everything on `nexus::work::Task` but `handle()` has a default, so a task only says what it changes. Each of these is a method on the task itself, so the policy lives next to the work it governs:

| Method | Default | What it says |
|:--|:--|:--|
| `tries()` | `3` | How often the task is tried, 1 to 100. |
| `exclusive()` | `.none` | Whether runs may overlap, and under which key. |
| `priority()` | `.normal` | Which waiting task runs first: `.critical`, `.high`, `.medium`, `.normal` or `.low`. |
| `expires()` | `null` | How long it may wait before it is dropped unrun. |
| `allowFailure()` | `false` | Whether the tasks after it in a [pipeline](#pipelines) still run when it fails. |
| `log(run)` | `.inherit` | Where its run logs. |
| `failed(payload, why)` | nothing | What to put right once it failed for good. |

The blog's welcome is tried five times and lets only one welcome per user wait or run at a time:

```echo title="src/Tasks/SendWelcome.eco"
public const function tries() : int64
{
    return 5;
}

public const function exclusive() : nexus::work::Exclusive
{
    return .unique("user:{$this->user}");
}
```

A push may also give a count of its own, `push(SendWelcome($user: 5), tries: 1)`, which wins over `tries()`.

### Keeping runs apart

Sometimes two runs of a task must never overlap: two welcomes for the same user would mean two mails. `exclusive()` answers one of three cases:

- `.none` lets runs overlap freely.
- `.running(key)` lets one task with the key run at a time. The others wait their turn.
- `.unique(key)` lets one task with the key wait *or* run at a time. A further push is skipped, and `push()` answers `nexus::work::Pushed::skipped` instead of `.queued(id)`.

An empty key means the task type itself, so `.running('')` is "one run of this task at a time, whatever its data". A key narrows it: `.unique("user:{$this->user}")` is one per user. Once the task has finished, the key is free again.

On an async queue the key holds within the process; on a distributed queue it holds across every server.

### Expiry, priority and cleaning up

Some tasks are only worth running while they are fresh. You may say how long a task may wait with `expires()`; a task that waited longer is dropped unrun, and the tasks waiting for it in a pipeline count it as failed:

```echo
public const function expires() : std::time::duration?
{
    return .mins(10);
}
```

When a task has failed for good, you may want to put right what it leaves half done, such as marking a record failed or telling somebody. `failed()` runs once, on the payload of the last run, with the reason:

```echo
public function failed(nexus::Payload& $payload, const string& $why) : void
{
    $payload->log->error('the welcome never went out', ['user' => $this->user, 'why' => $why]);
}
```

A task that is dropped without running (it expired, it was cancelled, or a stored one no longer decodes) never runs `failed()`, since it never ran in the first place.

`priority()` decides which waiting task a free worker takes: the higher priority first, then the one due longest. A password reset mail might say `.high` so it never waits behind a batch of newsletters.

## Running a task inline

The simplest way to run a task is right here and now. `nexus::work::Inline::run()` runs it on the caller's payload, inside its database session, before the caller goes on:

```echo
guard nexus::work::Inline::run($payload, CountUsers()) else ($f) {
    return .error(.server($f->why()));
};
```

Each task is tried once, and the caller decides what a failure means. That makes inline runs a handy way to reuse a task's work from a [command](./commands.md), and it is how the blog's tests run a task and look at what it did:

```echo title="tests/integration/World.eco"
public function run(Blog::Tasks::PruneAuth $task) : status<nexus::work::Failure>
{
    $payload = $this->app->kernel->background('test', nexus::Kernel::id());
    $out = nexus::work::Inline::run($payload, $task);
    nexus::Kernel::finish($payload);
    return $out;
}
```

`$kernel->background()` makes a payload for work that is not a request, with its own child container; `nexus::Kernel::finish()` releases it.

## Queues and lanes

Most of the time you do not want to wait for the work, you want somebody else to do it. That is a queue. In nexus-work, a queue is named by a **lane**: an empty struct conforming to `nexus::work::Lane`. The queue's type takes the lane as its parameter, and an alias gives it a short name:

```echo title="src/Queues/WorkerQueue.eco"
namespace Blog::Queues;

/**
 * The blog's worker threads in each process: `NEXUS_WORK_THREADS` of them.
 */
public struct WorkerLane : nexus::work::Lane {}

public type WorkerQueue = nexus::work::AsyncQueue<WorkerLane>;
```

Why a struct and not a string? Because the type is what you ask the container for. A service that takes a `WorkerQueue` cannot be handed the wrong queue, and a typo is a compile error rather than tasks quietly piling up in a queue nobody works.

### Async queues

An async queue runs its tasks on worker threads of this process, as soon as one is free. You bind it where the app is wired:

```echo title="src/App.eco"
$app->bindAsyncQueue<WorkerLane>();
```

It gets as many threads as `NEXUS_WORK_THREADS` says (two unless set). If one queue needs a count of its own, you may give it with `threads:`, which wins over the setting:

```echo
$app->bindAsyncQueue<WorkerLane>(threads: 4);
```

Anything built with the queue may push to it:

```echo
$app->bind<SignUpService>(scoped: (Container $c) => SignUpService($c->get<WorkerQueue>()));

// in SignUpService
$this->workers->push(SendWelcome($user: 5));
```

`push()` answers `result<nexus::work::Pushed, nexus::Problem>`: the task was queued under an id, or skipped because of a `.unique` key. You may also `cancel(id)` a waiting task (and every task waiting for it), and ask how many are `waiting()`.

> [!WARNING]
> What waits on an async queue is kept in memory. When the process stops, waiting tasks are lost, and running ones get `NEXUS_WORK_GRACE` to finish. For work that must not be lost, or that should wait until later, use a distributed queue.

### Distributed queues

A distributed queue stores its tasks where every server of your app reaches them. Any server may claim a due task, and it runs on that server's async queue. Tasks survive a restart, may be pushed to run later, and failed ones are kept so you can look at them and send them back.

The blog keeps its tasks in its database. It declares a second lane for them:

```echo title="src/Queues/JobQueue.eco"
namespace Blog::Queues;

/**
 * The blog's tasks in its database, run by the workers of whichever server claims them first.
 */
public struct JobLane : nexus::work::Lane {}

public type JobQueue = nexus::work::DistributedQueue<JobLane>;
```

and binds it on a store, saying which async queue its tasks run on:

```echo title="src/App.eco"
// tasks wait in the database and run on the worker threads of whichever server claims them
$app->bindAsyncQueue<WorkerLane>();
$app->bindDistributedQueue<JobLane>(store: nexus::work::carbon::Store($app->get<carbon::DB>()))
    ->into<WorkerLane>();
```

The `->into<WorkerLane>()` is required: a distributed queue only stores and claims, and the async queue does the running. The boot stops if you leave it out or name a lane that is not a bound async queue.

The queue is one for the whole process, bound when the app is wired, so anything built after it may take it. Pushing works as before, and a distributed queue can also wait:

```echo
$this->jobs->push(SendWelcome($user: 5));
$this->jobs->push(SendWelcome($user: 5), in: std::time::duration::mins(20));
$this->jobs->push(SendWelcome($user: 5), at: $tomorrowMorning);
```

A push is stored on its own, apart from whatever the pushing request writes. If the request's own writes roll back, the task stays queued, so a task should check that what it works on is really there (as `SendWelcome` does when the user is gone).

#### How servers share the work

Each server runs a feeder per distributed lane. It claims as many due tasks as its async queue has idle workers, the highest priority first, then the one due longest. A claim holds a task under a **lease** (`NEXUS_WORK_LEASE`, five minutes unless set), and a running task's lease is renewed every third of it. So a long task is never claimed twice while its server is alive; if the server dies, its tasks are claimed again once their leases run out.

Every change to a claimed task names the attempt it claimed, so a server whose lease ran out (and whose task another server took over) changes nothing. Don't worry about two servers sending the same welcome: the store makes sure only one of them holds it.

A task whose tries keep ending without ever settling (because its server keeps dying) is failed with a note saying so, rather than tried for ever.

#### Choosing a store

`nexus::work::MemoryStore` keeps the tasks in memory, with everything a database store does: delays, pipelines, leases and keys. It is meant for tests, and for a single process that wants those features but may lose what waits when it stops. Two queues on one memory store behave like two servers on one database, which makes it a good fit for testing exactly that.

For production you will want **nexus-work-carbon**, which keeps the store in your app's [database](./database.md). Require it next to nexus-work:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/work/carbon" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

and list its extension after nexus-carbon's:

```echo title="src/Extensions.eco"
// keeps the distributed queue's tasks in the database
nexus::work::carbon::Extension(),
```

It brings three tables (`nexus_tasks`, `nexus_task_edges` and `nexus_task_locks`). You wire them where the app opens its database and add their migration to your own:

```echo title="src/DB/Database.eco"
public function wire(carbon::DB $db) : status<carbon::Error>
{
    // ... the app's own repositories
    try nexus::work::carbon::Tables::wire($db);
    return .ok;
}

public function migrations() : array<carbon::migrate::Step>
{
    $all = nexus::work::carbon::Tables::migrations();
    $all->extend(Blog::DB::Migration::Carbon::migrations());
    return $all;
}
```

If the tables are not wired, the boot stops and says which call is missing. A claim takes each row with an update that only holds while its attempt count is still the one it read, so of two servers after the same row, one wins and the other moves on.

## Pipelines

Sometimes tasks belong together: first welcome the new user, *then* count the users. You may push them as a `nexus::work::Pipeline`, where each task names the ones it waits for. Here is the blog's signal handler for a new sign up:

```echo title="src/Signals/WelcomeNewUser.eco"
public struct WelcomeNewUser : nexus::SignalHandler<UserRegistered>
{
    public JobQueue $jobs;

    public function handle(const UserRegistered& $signal) : status<nexus::Problem>
    {
        $p = nexus::work::Pipeline();
        $welcome = $p->add(SendWelcome($user: $signal->user, $locale: $signal->locale));
        $p->add(CountUsers(), after: [$welcome]);
        try $this->jobs->push($p);
        return .ok;
    }
}
```

The handler is handed the queue where it is bound, so the request that fires the signal only stores the two tasks:

```echo title="src/Providers/AuthProvider.eco"
$app->get<nexus::SignalDispatcher>()->bind<UserRegistered, WelcomeNewUser>($app->get<JobQueue>());
```

`add()` answers a step, and `after:` takes the steps a task waits for. A task runs once every task it waits for is done, so a pipeline may fan out and join again. A task can only wait for one added before it, which means a pipeline never has a cycle. The queue takes the whole pipeline or none of it.

So, what happens when a task in the middle fails for good? The tasks after it are held back: they never run, and on an async queue they are dropped with a warning in the log. That is usually what you want; there is no point counting users for a welcome that never happened.

### Letting the pipeline go on

Some steps are nice to have rather than essential. A task that returns `true` from `allowFailure()` lets the tasks after it run even when it failed for good. They may ask how it went through `nexus::work::Run`, which every run finds in its payload's state:

```echo
public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
{
    $run = guard $payload->state<nexus::work::Run>() else {
        return .error(.giveUp('no run'));
    };
    foreach ($run->upstream as const &$u) {
        if ($u->failed) {
            $payload->log->warn('going on without it', ['task' => $u->name, 'error' => $u->error]);
        }
    }
    // ...
}
```

`Run` also says which try this is (`attempt` of `tries`), the run's `id` and `lane`, and the exclusive `key` it holds.

## Spawning more work

Occasionally a task only learns while it runs how much work there is. Say a task that prepares a post's cover finds that it needs three sizes. It may spawn a task per size through `nexus::work::Flow`:

```echo plain
foreach ($sizes as $size) {
    $payload->get<nexus::work::Flow>()->spawn(ResizeCover($post: $this->post, width: $size));
}
```

Spawned tasks run after the task that spawned them, on its queue, and any task that was waiting for the parent now waits for them too. `spawn()` takes `after:` just like `Pipeline::add()`, so spawned tasks may wait for each other. A task that fails spawns nothing, and a retry spawns afresh.

## Where runs log

By default a run logs to the app's log, stamped with the task's name and id. You may give a task, or a whole queue, a log of its own. `log()` answers a `nexus::work::RunLog`:

- `.inherit` leaves it to the queue (the default).
- `.app` writes to the app's log.
- `.also(sink)` writes to the app's log and a sink of its own.
- `.only(sink)` writes to the sink alone.
- `.silent` writes nowhere.

A task that keeps a file per run might say:

```echo
public const function log(const nexus::work::Run& $run) : nexus::work::RunLog
{
    return .also(nexus::log::File("var/tasks/{$run->id}.log", .json));
}
```

A queue says the same for every task that leaves it to the queue, with `->log()` where it is bound:

```echo
$app->bindAsyncQueue<WorkerLane>()
    ->log((const nexus::work::Run& $run) => .also(nexus::log::File("var/tasks/{$run->id}.log", .json)));
```

A distributed queue's `->log()` is asked first, then its async queue's. [Logging and tracing](./logging.md) covers sinks.

## How a task is stored

A distributed queue has to turn a task into text and back. You never write that code: `nexus gen` finds every struct conforming to `nexus::work::Task` and writes a codec for it, which `nexus::work::Extension` registers at boot. It is also where the rules on fields come from (public fields, memberwise constructor, a `handle()` of exactly the right shape), and a task that breaks one fails `nexus gen` with a message saying which. [nexus gen](./generator.md) has more on what it writes.

The codec names the task by its qualified struct name, like `Blog::Tasks::SendWelcome`. If you rename or move a task while some of it is still stored, the server that claims a stored one finds no task by that name, and fails it with a note saying so. The same goes for data that no longer reads, so a field you add should have a default: tasks stored before the change then still decode. Failed this way, a task stays with the failed ones, and once the fix is deployed `work:retry` sends it back.

## Running the workers

`serve` works the queues as well as answering HTTP: every async queue starts its threads, every distributed lane its feeder, and the [scheduler](./scheduling.md) starts too. When `serve` stops, the feeders stop claiming, and the running tasks get `NEXUS_WORK_GRACE` to finish. A stored task still running after that runs again once its lease has passed; an async one is lost.

You may also split the work from the web. `serve --no-work` answers HTTP without running any workers, and `work` runs the workers and the scheduler without serving HTTP:

```sh
# the web servers
NEXUS_DATABASE_URL=... NEXUS_AUTH_KEY=... echoc run -- serve --no-work

# the worker machines
NEXUS_DATABASE_URL=... echoc run -- work
```

Keep in mind that tasks pushed to an async queue only run in the process that pushed them, so `--no-work` only makes sense when the web servers push to distributed queues.

### The work commands

The distributed queues come with commands to look after them. Each takes `--queue <lane>` when the app binds more than one distributed queue.

| Command | What it does |
|:--|:--|
| `work` | runs the workers and the scheduler until stopped |
| `work:failed` | lists the stored tasks that failed for good, the latest first |
| `work:retry --id <id>` | sends a failed task back with fresh tries, and with it the tasks held back behind it; `--id all` sends every one |
| `work:cancel --id <id>` | cancels a waiting task and every task waiting after it |
| `work:graph --id <id>` | prints every task connected to one, and where each stands |
| `work:schedule` | lists the scheduled tasks and when each is next due |

The [debug console](./debug.md) shows the same lanes, failed and stored tasks in a browser once you add nexus-debug-work.

## Settings

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_WORK_THREADS` | `2` | Worker threads of each async queue bound without `threads:`. |
| `NEXUS_WORK_POLL` | `1s` | How long a feeder with nothing to claim waits before it looks again. |
| `NEXUS_WORK_LEASE` | `5m` | How long a claimed task is held; renewed every third of it while it runs. |
| `NEXUS_WORK_GRACE` | `30s` | How long a stopping process waits for running tasks to finish. |
| `NEXUS_WORK_KEEP` | `24h` | How long a done stored task is kept, so a scheduled slot is not pushed again and the graph still shows it. |

[Configuration](./configuration.md) covers how these are read.

## Where to next

- [Scheduling](./scheduling.md): pushing a task every night, or every five minutes.
- [Signals](./signals.md): queueing work when something happens.
- [Mail](./mail.md): sending from a task, with retries.
