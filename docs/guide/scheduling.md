---
description: Pushing tasks on a cron line or every so long, once per slot across every server, with nexus-work's scheduler.
---

# Scheduling

Every app grows a few chores that nobody asks for but somebody has to do: delete the sessions that expired, send a daily digest, refresh a cache every few minutes. The classic answer is a crontab on one machine, which works until that machine is replaced, or until you run two of them and every chore happens twice.

nexus-work brings a scheduler that lives in your app instead. You say which [task](./tasks.md) to push, when, and into which queue, right next to the rest of your wiring. Every server may run the scheduler, and each slot still runs once.

The scheduler is part of nexus-work, so there is nothing more to require: once `nexus::work::Extension()` is in your extension list, as [Tasks and queues](./tasks.md) shows, you may schedule. Scheduling a task is done through nexus-app's builder, `nexus::App`.

## Your first schedule

The blog prunes what has expired in its auth stores every night at three. The work itself is an ordinary task:

```echo title="src/Tasks/PruneAuth.eco"
namespace Blog::Tasks;

/**
 * Every night at three (UTC), deletes what has expired in every auth store: tokens, sessions, OAuth
 * requests, codes and grants, sign-in attempts. What `auth:prune` does by hand.
 */
public struct PruneAuth : nexus::work::Task
{
    public function handle(nexus::Payload& $payload) : status<nexus::work::Failure>
    {
        $done = guard $payload->get<nexus::auth::Pruning>()->run($payload) else ($p) {
            return .error(.retry("pruning: {$p->detail(.dev)}"));
        };
        foreach ($done as const &$d) {
            $payload->log->info('pruned', ['what' => $d->name, 'count' => $d->count as int64]);
        }
        return .ok;
    }
}
```

and one line where the app is wired says when it runs:

```echo title="src/Providers/AuthProvider.eco"
$app->schedule(PruneAuth())->cron('0 3 * * *')->into<JobLane>();
```

That's it. `schedule()` takes a task value, `cron()` says when, and `into<JobLane>()` names the [queue](./tasks.md#queues-and-lanes) the task is pushed into. When the slot comes round, the scheduler pushes `PruneAuth()` into the queue like any other push, and a worker runs it with the task's own tries, keys and logging.

Both "when" and "where" are required, and both are checked when the app boots. A cron line that does not parse, a lane that is not bound, or a schedule with neither `cron()` nor `every()` stops the boot with a message naming the task, rather than a chore that silently never runs.

### Every so long

When you care about the interval rather than the time of day, you may use `every()` with a duration like `30s`, `15m` or `2h`:

```echo
$app->schedule(Heartbeat())->every('1m')->into<WorkerLane>();
```

The interval must be whole seconds, at least one. Slots are counted from the Unix epoch, not from when the process started, so every server agrees on them: `every('15m')` means `:00`, `:15`, `:30` and `:45` on every machine.

A schedule takes `every()` or `cron()`, not both.

### Cron lines

`cron()` takes the familiar five fields: minute, hour, day of month, month and weekday. Each field is `*`, a number, a range like `1-5`, any of those with a step after a slash, or a comma list of them:

```echo plain
$app->schedule(PruneAuth())->cron('0 3 * * *')->into<JobLane>();       // every night at 03:00
$app->schedule(SendDigest())->cron('30 7 * * 1')->into<JobLane>();     // Mondays at 07:30
$app->schedule(RefreshStats())->cron('*/15 8-18 * * 1-5')->into<JobLane>(); // every quarter hour, office hours
```

For the weekday, both `0` and `7` are Sunday. As in cron, when both the day of month and the weekday are restricted, a day that matches either one counts.

### Time zones

Cron lines are read in UTC unless you say otherwise. If "three in the morning" should mean three in the morning where your users are, you may give the extension a `zone:`:

```echo title="src/Extensions.eco"
nexus::work::Extension(zone: $zurich),
```

where `$zurich` is a `calendar::Zone`, such as one from `calendar::Zone::named('Europe/Zurich')`. Every cron line of the app is then read in that zone, daylight saving included. `every()` schedules are not affected, since they count seconds from the epoch.

## Once per slot, across every server

So, what happens when you run three servers, each with the scheduler? It depends on the lane you schedule into, and this is the one choice worth getting right.

When the lane is a **distributed queue**, the scheduler stores each push under a key made of the task and its slot, like `Blog::Tasks::PruneAuth@1793588400`. The store keeps a key once, so the first server to reach the slot stores it and every other server's push is skipped. Every server may schedule, and each slot still runs once. That is why the blog schedules its prune into `JobLane`, its database queue.

When the lane is an **async queue**, there is no shared store to agree in. Every process that runs the scheduler pushes the task into its own threads, so three servers run it three times. The boot logs a warning for each task scheduled like that:

```txt
Blog::Tasks::Heartbeat is scheduled into async lane Blog::Queues::WorkerLane, so every process that schedules pushes it
```

That is sometimes exactly what you want, for a chore that belongs to each process (flushing a local buffer, say). For anything that should happen once, schedule into a distributed lane.

> [!TIP]
> A done stored task is kept for `NEXUS_WORK_KEEP` (24 hours unless set). That is what lets a server that reaches a slot late still find it stored, so leave it well above the few seconds servers may disagree by.

If you schedule the same task type twice (say, a digest at two different times), each plan gets a key of its own, so the two never skip each other.

## Missed slots

The scheduler looks for due slots every second, on a thread of its own. When it finds that several slots of a plan passed since it last looked, it pushes only the latest one. Slots missed while no process ran the scheduler are not caught up, with one exception: a slot that fell within the minute before a process started still counts, so a restart at 03:00:20 does not lose the 03:00 prune.

If a chore must never be skipped, have the task itself work out what it has not done yet (everything expired *before now*, every day without a digest) rather than relying on each slot. The blog's prune does just that: whichever night it runs, it deletes everything that has expired by then.

## Running the scheduler

`serve` runs the scheduler, and so does `work`. You may keep a process from scheduling with `serve --no-schedule`, for example on web servers when your worker machines already schedule:

```sh
NEXUS_DATABASE_URL=... NEXUS_AUTH_KEY=... echoc run -- serve --no-schedule
```

With distributed lanes there is no harm in every process scheduling, so you only need `--no-schedule` when you schedule into async lanes and want those chores on particular machines.

> [!WARNING]
> The scheduler also looks after the distributed queues' stores: once a minute it fails the stored tasks that waited past their expiry and deletes the done ones older than `NEXUS_WORK_KEEP`. It does this even when nothing is scheduled. Make sure at least one process runs the scheduler, or the task tables grow for ever.

To see what is planned, `work:schedule` lists every scheduled task with its schedule, its lane, and when it is next due:

```sh
echoc run -- work:schedule
```

The [debug console](./debug.md) shows the same list with nexus-debug-work.

## Testing a schedule

A schedule is plain data you may check without waiting for three in the morning. The booted app's `nexus::work::Work` holds the scheduler's plans, and `nexus::work::Schedule` answers when a cron line is next due. The blog checks its nightly prune like this:

```echo title="tests/unit/ScheduleTest.eco"
test the_prune_runs_nightly_at_three
{
    $r = FakeRig();
    $w = $r->app->kernel->services->get<nexus::work::Work>();
    expect($w->scheduler->plans)->size(1);
    expect($w->scheduler->plans[0]->into)->is('Blog::Queues::JobLane');
    $parsed = guard nexus::work::Schedule::of('', $w->scheduler->plans[0]->cron);
    $nightly = guard $parsed;
    calendar::Zone $utc = .utc();
    // 2026-11-02T02:59:30Z
    $before = time::timestamp::from_unix_secs(1793588370);
    $first = expect($nightly->next($before, $utc))->some();
    expect($first->unix_secs())->is(1793588400);

    $second = expect($nightly->next($first, $utc))->some();
    expect($second->unix_secs())->is(1793588400 + 86400);
}
```

The task itself is tested like any other, by running it inline. [Testing](./testing.md) shows how the blog boots its app for both.

## Settings

The scheduler has no settings of its own; it shares nexus-work's. The one that matters here is how long a done task is kept:

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_WORK_KEEP` | `24h` | How long a done stored task is kept, so a scheduled slot is not pushed again and the graph still shows it. |

[Tasks and queues](./tasks.md#settings) lists the rest.

## Where to next

- [Tasks and queues](./tasks.md): what a scheduled task may say about its tries, keys and logging.
- [Authentication](./auth.md): what `auth:prune` and the nightly prune delete.
- [Deployment](./deployment.md): splitting web servers from workers.
