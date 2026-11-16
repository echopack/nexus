---
description: Typed signals and their handlers. Say that something happened once, and let every part of the app that cares react to it.
---

# Signals

Sooner or later one thing that happens in your app needs to set off several others. When someone signs up, the blog wants to send a welcome mail and count its users. When a comment goes up, everybody reading that post should see it appear. You could call all of that from the action, but then `Register` has to know about mail, tasks and statistics, and every new reaction means editing code that has nothing to do with it.

Signals keep those apart. The code where something happens sends one typed value that says so, and the parts of the app that care each bind a handler for it. The sender never learns who is listening.

## Defining a signal

A signal is any struct. Its fields are everything a handler will be handed, so put in what a handler needs to do its job and nothing more:

```echo title="src/Signals/UserRegistered.eco"
namespace Blog::Signals;

/**
 * Someone signed up, speaking `locale`.
 */
public struct UserRegistered
{
    public int64 $user;
    public string $locale = 'en';
}
```

There is no base type to extend and nothing to register. The type itself is the signal's identity: handlers are found by it, so two signals never collide because of a misspelled name.

## Writing a handler

A handler conforms to `nexus::SignalHandler<S>` for the signal it reacts to, and implements `handle(const S&)`. It gets what it works with through its constructor, and the signal is all it is handed:

```echo title="src/Signals/WelcomeNewUser.eco"
namespace Blog::Signals;

use Blog::Queues::JobQueue;
use Blog::Tasks::{CountUsers, SendWelcome};

/**
 * Welcomes whoever signs up, on a worker, then counts the users.
 */
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

`handle()` returns `status<nexus::Problem>`. Returning `.ok` lets the next handler run; returning a problem stops the rest and hands the problem back to the sender. We'll look at what that means in a moment.

### One handler, several signals

A type may handle as many signals as you like, with one conformance and one `handle` overload each. The blog broadcasts both new and deleted comments from the same class, since both go to the same realtime channel:

```echo title="src/Signals/BroadcastComment.eco"
public class BroadcastComment : nexus::SignalHandler<CommentPosted>, nexus::SignalHandler<CommentDeleted>
{
    // ...

    public function handle(const CommentPosted& $signal) : status<nexus::Problem>
    {
        // ...
    }

    public function handle(const CommentDeleted& $signal) : status<nexus::Problem>
    {
        // ...
    }
}
```

## Binding handlers to the dispatcher

Handlers live on a `nexus::SignalDispatcher`, an ordinary object your app puts in its container. There is one per process. With nexus-app you create it in the app's `services()`, before the providers register, so every provider finds it there:

```echo title="src/App.eco"
public function services(nexus::Services& $s) : status<nexus::BootError>
{
    $app = nexus::App($s);
    // ...

    // the providers bind their handlers on it
    $app->instance(nexus::SignalDispatcher());

    foreach ($this->providers() as const &$p) {
        $app->register($p);
    }
    // ...
}
```

Each provider then binds the handlers for its own part of the app. `bind<S, H>(...)` takes the signal type, the handler type, and the handler's constructor arguments:

```echo title="src/Providers/AuthProvider.eco"
// a sign up is welcomed on a worker
$app->get<nexus::SignalDispatcher>()->bind<UserRegistered, WelcomeNewUser>($app->get<JobQueue>());
```

If you already have a handler built, you may pass it as it is with `bind<S>(handler)`. That is how one `BroadcastComment` serves both of its signals:

```echo title="src/Providers/CommentsProvider.eco"
$broadcast = BroadcastComment($app->get<nexus::realtime::Broadcaster>(), $app->get<CommentTransformer>(),
    $app->get<nexus::rest::TransformerNetwork>(), $app->get<nexus::Logger>());
$app->get<nexus::SignalDispatcher>()
    ->bind<CommentPosted, BroadcastComment>($broadcast)
    ->bind<CommentDeleted, BroadcastComment>($broadcast);
```

`bind` returns the dispatcher, so you may chain as many as you like.

Handlers are built once, while the app is wired, and live as long as the process. Give them what is shared by every request (a queue, a broadcaster, the root logger), never something that belongs to one request, such as a database session. When a reaction needs the database, push a task, as `WelcomeNewUser` does; the task gets a fresh session of its own on the worker.

## Sending a signal

Whatever sends signals takes the dispatcher through its constructor, like any other dependency, and calls `send` with a value:

```echo title="src/Actions/Users/Register.eco"
public class Register : nexus::Action
{
    // ...
    private nexus::SignalDispatcher $signals;

    public function handle(nexus::Payload& $payload, nexus::Body<Registration> $in) : result<nexus::Response, nexus::Problem>
    {
        // ...
        $made = guard $this->users->create(User($email: $r->email, $name: $r->name, $passwordHash: $hash)) else ($e) {
            // ...
        };
        try $this->signals->send(UserRegistered($user: $made->id, $locale: $payload->locale()));
        return .ok($this->transformer->createResponse($payload, $made, mv $inc, status: 201));
    }
}
```

The binding passes the dispatcher in from the container:

```echo title="src/Providers/AuthProvider.eco"
$app->bindAction<Register>((Container $c) => Register($c->get<UserRepository>(), $c->get<nexus::auth::Passwords>(),
        $c->get<UserTransformer>(), $c->get<nexus::SignalDispatcher>()))
    ->route([.post], '/v1/users');
```

Signals are not only for actions. The blog's `CommentService` sends `CommentPosted` and `CommentDeleted` itself, right after the write, so whichever door posts a comment through the service sets off the same broadcast. A signal that no handler is bound to is fine: `send` simply returns `.ok`.

## How handlers run

`send` is synchronous. It runs every handler of the signal right there, on the sender's thread, in the order they were bound, and returns once the last one is done. There is no queue in between and nothing runs later, so when `send` returns you know every handler has finished.

So, what happens when a handler fails? The first problem stops the rest. The handlers bound after it do not run, and `send` returns the problem. With `try`, as in `Register`, it travels on up to the client.

That has a consequence worth keeping in mind: `send` comes after the write, and a failing handler does not undo it. In `Register` the user already exists by the time `WelcomeNewUser` runs. If its push fails, the client gets an error for a sign up that did in fact happen. Decide per handler whether its failure should reach the sender at all. `BroadcastComment` decides that it should not: the comment is saved already, so a broadcast that does not go out is logged and the handler still returns `.ok`:

```echo title="src/Signals/BroadcastComment.eco"
private function send(const string& $channel, const string& $event, const json::Value& $data, const nexus::realtime::SocketId& $except) : void
{
    guard $this->broadcaster->send($channel, $event, $data, except: $except) else ($e) {
        $this->log->warn('comment broadcast failed', ['channel' => $channel, 'event' => $event, 'error' => $e->message()]);
        return;
    };
}
```

## Doing slow work later

Because handlers run inside the request, everything they do adds to its response time. Anything slow, or anything that talks to a service that might be down, such as sending a mail, belongs on a worker. The handler only pushes a [task](./tasks.md) and returns:

```echo plain
// the request only stores the two tasks; a worker sends the mail
$p = nexus::work::Pipeline();
$welcome = $p->add(SendWelcome($user: $signal->user, $locale: $signal->locale));
$p->add(CountUsers(), after: [$welcome]);
try $this->jobs->push($p);
```

That is the pattern to reach for by default: a signal says what happened, and a handler decides whether it is quick enough to react right away or should hand the work to the queue.

## Signals in tests

A dispatcher is an ordinary object, so a unit test may build one without booting an app, bind the handlers it wants to check, and send to it. `count<S>()` tells you how many handlers a signal has:

```echo
$d = nexus::SignalDispatcher()
    ->bind<UserRegistered, WelcomeNewUser>($jobs);

guard $d->send(UserRegistered($user: 42, $locale: 'de'));
expect($d->count<UserRegistered>())->is(1);
```

For a test that walks a whole flow through the booted app, see [testing](./testing.md).

## Where to next

- [Tasks and queues](./tasks.md): the work a handler hands off.
- [Realtime channels](./realtime.md): what `BroadcastComment` sends to.
- [Extensions and wiring](./extensions.md): providers, `instance` and the container.
