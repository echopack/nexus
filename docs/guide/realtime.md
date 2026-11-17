---
description: Websocket channels with per-channel authorization, presence, whispers, and broadcasts from any process.
---

# Realtime channels

Some things should reach the browser the moment they happen: a new comment under the post someone is reading, a note to an author that somebody answered them, the little "Ada is typing" under a comment box. Polling for these is wasteful and always a bit late. What you want is a socket that stays open, and a way to say "tell everyone reading post 5".

nexus-realtime gives you exactly that. A browser opens one websocket at `/realtime` and subscribes to channels by name, like `posts.5`. A channel class in your app decides who may follow which channel. Anything in your app, in any process, may then broadcast an event to a channel, and every socket following it gets the event.

To add it, require the module in your app's `module.eco`, plus the Redis module if the app may run on more than one server:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/realtime" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/realtime/redis" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list their extensions after nexus-auth, whose guards say who is opening a socket:

```echo title="src/Extensions.eco"
nexus::auth::Extension('blog', stores: .provided, guards: [nexus::auth::BuiltinGuard::signed]),
// ...
nexus::realtime::Extension(),
nexus::realtime::redis::Extension(),
```

> [!NOTE]
> Realtime channels are for many listeners on named topics. If all you need is a one-way stream to one client, like an admin's live numbers, that is a server-sent event stream, not a channel. See `nexus::Response(events:)` in [responses](./responses.md).

## Deciding who may follow a channel

Every channel name your app answers for belongs to a channel class, conforming to `nexus::realtime::Channel`. Its `authorize()` is asked on every subscribe, and says yes with `.ok` or no with a `nexus::Problem`.

Here is the blog's channel for a user's own notifications. Only that user, signed in, may follow it:

```echo title="src/Channels/UserChannel.eco"
namespace Blog::Channels;

public class UserChannel : nexus::realtime::Channel
{
    public function authorize(nexus::Payload& $payload, const nexus::auth::Identity& $who, const nexus::realtime::Topic& $topic) : status<nexus::Problem>
    {
        if ($who->anonymous()) {
            return .error(.unauthorized('sign in to follow your own channel', $reason: 'signed_in_required'));
        }
        if (($who->number() ?? -1) != ($topic->number('id') ?? -2)) {
            return .error(.forbidden('this channel belongs to another user'));
        }
        return .ok;
    }
}
```

`$who` is the caller who opened the socket, and is anonymous for a socket opened without signing in. `$topic` is the channel name, with the parameters its pattern captured: `$topic->number('id')` for an integer, `$topic->text('name')` for anything else.

You bind the class where the app is wired, and say which names it answers for with `->on()`:

```echo title="src/Providers/CommentsProvider.eco"
$app->bindChannel<PostChannel>((Container $c) => PostChannel($c->get<PostRepository>(), $c->get<UserRepository>()))
    ->on('posts.{id:integer}');
$app->bindChannel<UserChannel>(() => UserChannel())
    ->on('users.{id:integer}');
```

A pattern is dot-separated segments, each a word or a parameter. `{id}` takes any segment and `{id:integer}` digits only, so `posts.{id:integer}` answers `posts.5`, but not `posts.new` or `posts.5.likes`. A name that no pattern answers is refused with a `404`.

The channel class is built for each subscribe on a payload of its own, just like an action, so it may take scoped services such as a repository. The blog's `PostChannel` uses that to refuse a post that does not exist:

```echo title="src/Channels/PostChannel.eco"
public function authorize(nexus::Payload& $payload, const nexus::auth::Identity& $who, const nexus::realtime::Topic& $topic) : status<nexus::Problem>
{
    int64 $id = $topic->number('id') ?? 0;
    $found = try $this->posts->find()->get($id);
    if ($found == null) {
        return .error(.notFound('the post'));
    }
    return .ok;
}
```

## Broadcasting

So, how does an event reach the sockets? Through the `nexus::realtime::Broadcaster`, which you may take in a service, a [signal](./signals.md) handler or a [task](./tasks.md):

```echo
$this->broadcaster->send("posts.{$post->id}", 'comment.posted', $json);
```

The arguments are the channel, the name of the event, and its data as JSON. Every socket subscribed to `posts.5` gets the event, whichever server it is connected to (more on that in a moment).

The blog broadcasts from a signal handler, so the code that saves a comment knows nothing about sockets:

```echo title="src/Signals/BroadcastComment.eco"
public function handle(const CommentPosted& $signal) : status<nexus::Problem>
{
    json::Value $comment = $this->transformer->json($signal->comment, $this->network, EchoPack::Rest::Includes::of(['author']));
    $this->send("posts.{$signal->comment->postId}", 'comment.posted', $comment, $signal->except);
    if ($signal->postAuthor != $signal->comment->authorId) {
        $this->send("users.{$signal->postAuthor}", 'comment.received', $comment, nexus::realtime::SocketId());
    }
    return .ok;
}
```

`send` answers a `status`. The blog logs a broadcast that did not go out rather than failing, since the comment is saved already, and you should usually do the same.

If you would rather give an event a type of its own, a struct conforming to `nexus::realtime::Broadcast` says its `channel()`, `event()` and `data()`, and `$broadcaster->send($b)` sends it.

### A slow reader holds up nobody

Not every client reads as fast as you send. A phone in a tunnel stops reading, and its socket's buffer fills up. So each socket gets a small queue of its own, and a few writer threads work through the queues, so one stuck socket never delays the event for everyone else. A socket that falls more than 256 frames behind is closed with code `1008`, and its client reconnects and catches up with `after`, like after any other drop.

### Skipping the socket that caused it

When a reader posts a comment from the page, the page usually shows it right away. Getting the same comment back over the socket a moment later would show it twice. To avoid that, the client sends its socket's id in the `X-Socket-Id` header, and the action passes it on as `except:`:

```echo title="src/Actions/Comments/CreateComment.eco"
$made = try $this->comments->create($me->user, $id, $in->value, nexus::realtime::SocketId::of($payload));
```

`nexus::realtime::SocketId::of($payload)` reads the header, and the broadcast skips that one socket. It only skips a socket owned by the same caller who made the request, so nobody can silence somebody else's socket by sending its id.

## Presence: who else is here

Sometimes a channel should know who is following it: the readers of a post, the people in a room. You may make a channel a presence channel by writing `member()`. What it returns is what the other subscribers see about this socket:

```echo title="src/Channels/PostChannel.eco"
public function member(nexus::Payload& $payload, const nexus::auth::Identity& $who, const nexus::realtime::Topic& $topic) : result<json::Value?, nexus::Problem>
{
    json::Value $info = json::object();
    $info['name'] = json::nil();
    if (!$who->anonymous()) {
        $me = try BlogUsers::of($this->users, $who->subject);
        $info['name'] = json::str($me->name);
    }
    return .ok($info);
}
```

A subscriber now gets the list of members along with `subscribed`, and hears `joined` and `left` as others come and go, always after its own `subscribed`. Return `null`, the default, and the channel stays without presence.

Members are keyed by id, so hearing `left` for someone who already left is harmless, and a server says `left` even when the roster lost track of the member first. Every `NEXUS_REALTIME_BEAT`, each server also puts the roster right about its own members: one the roster lost (Redis restarted, say) is listed again and announced as `joined`, and one it no longer holds (a leave that failed while Redis was down) is taken out and announced as `left`.

Since the member info is whatever the server says, you should only put in it what everyone on the channel may see.

## Whispers

Some messages don't need your server's logic at all, they only need to get from one reader to the others: "Ada is typing". A subscriber may whisper to a channel's other subscribers, and the channel class's `whisper()` hook decides whether it goes. Whispers are refused unless you write it:

```echo title="src/Channels/PostChannel.eco"
public function whisper(nexus::Payload& $payload, const nexus::auth::Identity& $who, const nexus::realtime::Topic& $topic, nexus::realtime::Whisper& $w) : status<nexus::Problem>
{
    if ($w->event != 'typing') {
        return .error(.forbidden('readers of a post whisper typing only'));
    }
    if ($who->anonymous()) {
        return .error(.unauthorized('sign in to comment', $reason: 'signed_in_required'));
    }
    $me = try BlogUsers::of($this->users, $who->subject);
    json::Value $data = json::object();
    $data['name'] = json::str($me->name);
    $w->data = $data;
    return .ok;
}
```

Notice the hook replaces the whisper's data with the name from the account. A client could send any name it likes; the server puts in the real one, so nobody types as somebody else. A whisper never goes back to its sender and is never kept for catching up, and `NEXUS_REALTIME_MAX_WHISPER` caps its size.

## Connecting from a browser

A browser can't sign a websocket request the way it signs an API call, so it asks for a one-time ticket first. `POST /realtime/ticket`, sent as the signed in caller, answers `{ticket, expires_at}`, and the browser opens the socket with it:

```js
// signed like any other API call
const { ticket } = await api.post('/realtime/ticket', {});
const ws = new WebSocket(`wss://blog.example.com/realtime?ticket=${ticket}`);

ws.onopen = () => {
  ws.send(JSON.stringify({ op: 'subscribe', channel: 'posts.5' }));
};
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.op === 'event' && msg.event === 'comment.posted') {
    showComment(msg.data);
  }
};
```

A ticket lasts `NEXUS_REALTIME_TICKET` (thirty seconds) and opens one socket only. A visitor who is not signed in gets no ticket, and may open the socket without one: it then follows public channels only, the ones whose `authorize()` lets anonymous callers in. An Echo client that signs its requests may skip the ticket altogether, since the upgrade request carries its own credential.

### What a socket says

Each message is one JSON object with an `op`. A client sends:

| Message | What it does |
|:--|:--|
| `{"op":"subscribe","channel":"posts.5"}` | Follows a channel. Add `"after":"<id>"` to catch up from the last event seen. |
| `{"op":"unsubscribe","channel":"posts.5"}` | Stops following it. |
| `{"op":"whisper","channel":"posts.5","event":"typing","data":{}}` | Whispers to the others, when the channel lets it. |
| `{"op":"ping"}` | Answered with `pong`. |

And the server sends `ready` once the socket is open (with `socket_id` and `signed_in`), `subscribed` or `refused` (with the RFC 9457 `problem` why) for each subscribe, `event` for each broadcast, `whisper`, `joined` and `left` on presence channels, and `reset`, which means "fetch afresh": when a reconnecting client asked to catch up from an event no longer kept, or when the server may have missed broadcasts (its Redis listener lost the connection for a while).

Nothing on a channel arrives before its `subscribed`, and nothing arrives twice: the catch up after `after` comes first, then everything live.

The `socket_id` from `ready` is the value to send as `X-Socket-Id`.

## Sockets end with the sign in

A socket lives as long as the sign in it was opened with. When someone signs out, or their password changes and every session ends, their sockets close at once with code `4001`, on every server. A presence channel's other readers see them leave. Credentials that simply expire are caught too: every `NEXUS_REALTIME_RECHECK`, a server checks its open sockets and closes the ones whose sign in no longer holds. A server whose Redis listener was cut off checks right away once it is back, since a sign out may have been among what it missed.

An open socket does not keep its session alive, though. The requests the client signs do that. [Authentication](./auth.md) covers sessions and how they end.

## Across several servers

With one server, broadcasts stay in the process, and that's all you need. Once you run several servers behind a load balancer, a comment saved on one has to reach readers connected to another. Set `NEXUS_REALTIME_URL` to a Redis server and nexus-realtime-redis carries every broadcast, presence change and ending sign in to every server:

```sh
NEXUS_REALTIME_URL=redis://127.0.0.1:6379/0
```

This also lets you broadcast from a process that holds no sockets at all, like a worker running a task, or the command line:

```sh
blog realtime:send --channel posts.5 --event note --data '{"text":"hi"}'
```

On `local:` that command refuses, since its own process has no sockets to send to.

When a server's listener loses Redis, it connects again on its own. Whatever was published meanwhile never reaches that server, so once it is back, every socket there hears `reset` for the channels it follows, cursors from before the gap catch up no further than `reset`, and the sign ins of its sockets are checked again.

> [!NOTE]
> `rediss://` is refused for now: the Redis client has no TLS yet.

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_REALTIME_URL` | `local:` | Where broadcasts travel: `local:` (this process) or `redis://host:6379/db` (every server). |
| `NEXUS_REALTIME_PREFIX` | `nexus:` | What the Redis channels broadcasts travel on start with. |
| `NEXUS_REALTIME_TICKET` | `30s` | How long a ticket is good for. |
| `NEXUS_REALTIME_BACKLOG` | `1024` | How many recent broadcasts a reconnecting socket may catch up on. |
| `NEXUS_REALTIME_MAX_CHANNELS` | `50` | How many channels one socket may follow. |
| `NEXUS_REALTIME_MAX_SOCKETS` | `10` | How many sockets one caller may have open on one server. `0` for no limit. |
| `NEXUS_REALTIME_RATE` | `20` | How many messages a second one socket may send. `0` for no limit. |
| `NEXUS_REALTIME_MAX_WHISPER` | `4096` | The largest whisper in bytes. `0` for no limit. |
| `NEXUS_REALTIME_RECHECK` | `60s` | How often a server checks that its sockets' sign ins still hold. |
| `NEXUS_REALTIME_BEAT` | `10s` | How often a server tells the presence roster it is alive. |

## Testing channels

`nexus::testing::TestSocket` opens a socket on your test app, so a test may follow a post, post a comment through the API, and look at what arrived. Here is a piece of the blog's realtime flow:

```echo title="tests/integration/RealtimeFlowTest.eco"
TestSocket $page = $world->app->socket('/realtime');
$page->say("\{\"op\":\"subscribe\",\"channel\":\"posts.{$post}\"}");
$world->settle();

$ada->post("/v1/posts/{$post}/comments", json: newComment('Hello, live'))->status(201);
$world->settle();
array<json::Value> $events = $page->where('op', 'event');
expect($events[0]->get('event')?->asStr())->some('comment.posted');
```

For a server you are running by hand, the blog's smoke script uses a tiny websocket client in `examples/blog/scripts/wsprobe`, since curl speaks none. [Testing](./testing.md) has the rest.

## Where to next

- [Signals](./signals.md): broadcasting when something happens, without coupling the two.
- [Authentication](./auth.md): who a socket belongs to, and how a sign in ends.
- [Debug console](./debug.md): the open sockets and the channels they follow.
