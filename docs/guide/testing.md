---
description: Boot the real app on a real MySQL database, one per test, and send it requests in process. Fakes only for the faults a real database won't produce.
---

# Testing

nexus apps are tested with two modules. `nexus-testing` boots your app in process and sends it requests without a socket; `nexus-carbon-testing` gives each test a MySQL database of its own. Both belong in your app's test target, not its build:

```echo title="module.eco"
#[target: test] {
    #[sources: "tests/**/*.eco"]
    #[requires: "echopack/nexus/modules/testing" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
    #[requires: "echopack/nexus/modules/carbon/testing" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
}
```

There is no extension to add to your list. A test boots the list you already have.

`nexus-testing` brings [ecotest](https://github.com/echolang/ecotest) and its HTTP module with it, so the target needs no `requires` of its own for either.

## The real app, on a real database

Here is the one rule this page is built around: **an API test boots the real app on a real database.** The same `Blog::extensions()` list that `main.eco` runs, a MySQL database created for that one test, real password hashing, real clocks. Requests go in through the kernel, exactly where a socket would have handed them over.

Why so strict? Because the bugs worth catching live in the seams. A query that MySQL rejects, a migration that forgot a column, a middleware that isn't in the list, a unique key that a fake would happily ignore. A test against a fake database tells you the fake works. A test against the real one tells you the blog works.

Fakes still have a place, but a narrow one: the faults a real database won't produce on demand, such as a deadlock or a race past a unique check. We'll get to those at the end of this page.

## Booting the app in a test

`nexus::testing::TestApp` boots a list of extensions with fixed config and keeps every log entry. Here is the blog's health check, with a title of the test's choosing:

```echo
use nexus::testing::TestApp;

// $vars holds what the blog needs to boot: NEXUS_DATABASE_URL, NEXUS_AUTH_KEY and the rest
$vars['BLOG_TITLE'] = 'Testing blog';
$app = TestApp(Blog::extensions(), $vars);
$app->api()->get('/health')->status(200)->json('$.title', 'Testing blog');
$app->expectLogged(.info, 'GET /health 200');
```

The map is the *whole* environment the app sees. Neither the process environment nor a `.env` file is read, so a test runs the same on your laptop and in CI. If the boot fails, the test stops with every reason the kernel gave.

`api()` hands back an ecotest-http `Api`. Every request goes straight into the kernel, from `127.0.0.1`, with the `Host`, `Accept` and `Content-Length` headers a real client would add. No port is opened, and coverage counts your app's code. ecotest-http's own docs list every check (`status`, `json`, `count`, `capture`, `problem`, `invalid` and the rest).

### Checking the log

Sometimes the reply alone doesn't tell you whether something happened. `expectLogged` checks that an entry with exactly that message was written at that level, and `expectNotLogged` checks the opposite. When the check fails, it prints everything that *was* logged, which is usually the fastest way to see what went wrong.

```echo
$world->app->expectLogged(.info, 'post published');
```

## A database of each test's own

`nexus::carbon::testing::Database` creates a MySQL database on a server, runs your migrations on it, and drops it when the test ends:

```echo
use nexus::carbon::testing::Database;

$server = Database::server(env: ['BLOG_TEST_DATABASE_URL', 'ECOTEST_MYSQL_URL']);
$db = Database(server: $server, migrations: Blog::DB::migrations(), prefix: 'blog_test');
$app = TestApp(Blog::extensions(), ['NEXUS_DATABASE_URL' => $db->url]);
```

A few things are worth knowing here:

- `Database::server` returns the first of those variables that is set. If none is, the test is **skipped**, not failed, so `echoc test` on a machine without MySQL still passes the rest of the suite.
- The database is named after the prefix, the process id and a counter (`blog_test_4711_1`), so tests running side by side never meet. A database left over from a crashed run is dropped first.
- It is dropped when the value goes away, and also when a check stops the test early.
- It waits up to 90 seconds for the server to answer, so a container that is still starting is fine.

The value also lets you look at and shape the database directly. `count` tells you how many rows a table holds, and `run` executes a statement for state the API can't write, such as dating posts a day apart:

```echo
expect($world->db->count('posts'))->is(1);
$world->db->run("UPDATE posts SET created_at = '2026-11-01 12:00:00' WHERE title = 'Banana'");
```

For anything more, `$db->db` is a `carbon::DB` on the test database.

## A world for your flows

Booting the app, creating the database, and signing someone in is the same in every test. The blog gathers it in one class, `World`, in `tests/integration/World.eco`:

```echo title="tests/integration/World.eco"
use ecotest::http::Api;
use nexus::testing::TestApp;
use nexus::carbon::testing::Database;

internal class World
{
    public Database $db;
    public TestApp $app;
    public nexus::connect::ScriptedFetch $google;
    public Api $api;
    public Api $bare;

    public constructor(map<string, string> $more = map<string, string>())
    {
        $server = Database::server(env: ['BLOG_TEST_DATABASE_URL', 'ECOTEST_MYSQL_URL']);
        $this->db = Database(server: $server, migrations: Blog::DB::migrations(), prefix: 'blog_test');
        $google = nexus::connect::ScriptedFetch();
        $this->google = $google;
        $vars = World::vars($this->db);
        foreach ($more as $k => const &$v) {
            $vars[$k] = $v;
        }
        $this->app = TestApp(Blog::extensions(), mv $vars, replace: $google->replacing());
        $this->bare = $this->app->api();
        $this->api = $this->visitor();
    }

    internal static function vars(const Database& $db) : map<string, string>
    {
        return [
            'NEXUS_DATABASE_URL' => $db->url,
            'NEXUS_AUTH_KEY' => 'an-integration-key-of-at-least-32-chars',
            'NEXUS_MAIL_URL' => 'memory:',
            'NEXUS_MAIL_FROM' => 'hello@blog.test',
            // ...
            'BLOG_COVERS_URL' => 'memory:',
        ];
    }

    // visitor(), admin(), author($name), outbox(), run($task) ...
}
```

Notice that mail and the covers' disk are set to `memory:` through their ordinary settings. That's not a fake: it's a real configuration of those modules, and the test reads what was sent from the real outbox.

With the world in place, a flow test reads like a story. Each `ecotest::step` names what happens next, so a failure says *where* in the flow it broke:

```echo title="tests/integration/PostsFlowTest.eco"
use ecotest::expect;

#[group: "integration"]
test an_admin_publishes_and_everyone_reads
{
    $world = World();
    $admin = $world->admin();

    ecotest::step('an admin publishes a post');
    $id = $admin->post('/v1/posts', json: newPost('  Hello world ', ['Echo', 'nexus']))
        ->status(201)
        ->json('$.data.title', 'Hello world')
        ->json('$.data.tags[0]', 'echo')
        ->capture('$.data.id');
    $world->app->expectLogged(.info, 'post published');
    expect($world->db->count('posts'))->is(1);

    ecotest::step('it shows with its author, whose email stays hidden');
    $world->api->get("/v1/posts/{$id}", query: ['include' => 'author'])
        ->status(200)
        ->json('$.data.author.name', 'The editor')
        ->lacks('editor@example.com');

    ecotest::step('deleting it answers 204 and it is gone');
    $admin->delete("/v1/posts/{$id}")->status(204);
    $world->api->get("/v1/posts/{$id}")->problem(404)->has('the post');
    expect($world->db->count('posts'))->is(0);
}
```

Every `World()` makes a fresh database, so tests never depend on each other's leftovers. The seed migration's editor is there in each one because the migrations really ran.

### Signed requests

The blog signs every request with a session, as its browser page does. `api(signed:)` takes a function that makes the `Authorization` header from the method, target and body, and adds it to each request:

```echo
public function session(nexus::auth::Signer $s) : Api
{
    return $this->app->api(signed: World::sign($s));
}
```

How the blog opens those sessions is shown in `World.eco`; [authentication](./auth.md) explains signed sessions themselves.

### Event streams and websockets

Some endpoints don't answer with one reply. `$app->events(target)` opens an event stream in process and keeps every event sent to it, and `$app->socket(target)` opens a websocket you can `say` messages into. Both have a `signed:` variant too:

```echo title="tests/integration/RealtimeFlowTest.eco"
TestSocket $page = $world->app->socket('/realtime');
```

An answer that isn't a stream or an upgrade, such as a `401`, comes back as one that never opened, with its status and body, so you may check a refusal the same way.

### Running tasks

A task that a request queued sits in the real queue table. The blog's world runs one in place, as a worker would, and then checks its effect:

```echo title="tests/integration/UsersFlowTest.eco"
expect($world->db->count('nexus_tasks'))->is(2);
expect($world->run(Blog::Tasks::SendWelcome($user: $user)))->fine();
$mail = expect($world->outbox()->find(to: 'reader@example.com'))->some();
```

[Tasks and queues](./tasks.md) covers `nexus::work::Inline`, which `World::run` is built on.

## Replacing what reaches outside

Your database is under your control; Google is not. When a flow calls an outside service, `TestApp` may replace that one binding while booting everything else as it is:

```echo
$google = nexus::connect::ScriptedFetch();
$app = TestApp(Blog::extensions(), $vars, replace: $google->replacing());
```

The `replace` function runs on the services after every extension, as an extension listed last would, so it wins. You keep the app's own list, and only the call that would have left the process is scripted. [Sign in with Google](./connect.md) shows the scripted answers.

## Faults: the one place for a fake

Some failures a real database simply won't produce when you ask for them. A sign-up that races another one past the email check and hits the unique key. A foreign key that breaks between a read and a write. To test how the blog *answers* those, it uses carbon's fake driver, which lets you queue what the database replies, failures included.

The blog keeps this rig in `tests/unit/FakeRig.eco`, and its comment says plainly that everything else runs against a real database:

```echo title="tests/unit/FakeRig.eco"
public constructor()
{
    $driver = fake::Driver<Mysql>();
    $this->fake = $driver;
    $clock = calendar::FixedClock(time::timestamp::from_unix_secs(1700000000));
    $db = nexus::carbon::Extension(function[$driver, $clock](nexus::carbon::DatabaseConfig $cfg) : result<carbon::DB, carbon::Error> {
        $made = carbon::DB($driver, clock: $clock);
        try Blog::DB::wire($made);
        return .ok($made);
    });
    // ... the other extensions, then Blog::App()
    $this->app = TestApp($exts, mv $vars, replace: nexus::connect::ScriptedFetch()->replacing());
    $this->api = $this->session('');
}
```

Each fault test queues exactly the answers the request will need, then the failure, and checks the reply:

```echo title="tests/unit/FaultsTest.eco"
#[group: "unit"]
test a_sign_up_racing_past_the_email_check_is_a_conflict
{
    $r = FakeRig();
    // the address looks free, then the insert hits the unique key another sign-up just took
    $r->fake->rows([])->fails(carbon::Error::driver(carbon::Failure($fault: carbon::Fault::duplicate, $message: 'Duplicate entry')));
    $r->api->post('/v1/users', json: '{"name":"A reader","email":"reader@example.com","password":"a long password","passwordConfirmation":"a long password"}')
        ->problem(409)
        ->has('that email is taken');
}
```

> [!WARNING]
> Reach for the fake only when the test is *about* a failure. A happy path on a fake database proves little, and queued rows drift away from the real schema without anyone noticing. If a real database can produce the state, put the test in `tests/integration/` and use `World`.

The fake driver comes from `echopack/carbon/fake`; add it to the test target next to the two modules.

## Testing boot itself

A few tests are about whether the app boots at all, such as what `prod` mode refuses. `TestApp::attempt` hands the boot error back instead of stopping the test, and takes the mode to boot in. nexus-oauth's own tests check that its issuer won't boot in `prod` without a public origin, and boots once one is set:

```echo title="modules/oauth/tests/OAuthTest.eco"
map<string, string> $bare = ['NEXUS_AUTH_KEY' => KEY];
nexus::BootError $e = expect(TestApp::attempt(Rig::extensions($clock, '/consent'), $bare, mode: .prod))->fails();
expect($e->lines()[0])->has('NEXUS_APP_URL');

map<string, string> $set = ['NEXUS_AUTH_KEY' => KEY, 'NEXUS_APP_URL' => 'https://blog.example.com'];
expect(TestApp::attempt(Rig::extensions($clock, '/consent'), $set, mode: .prod)->failed())->no(says: 'it boots with the origin set');
```

## Running the tests

Tests are grouped with `#[group: ...]`, and the blog's manifest turns each group into a test target of its own:

```echo title="module.eco"
#[target: test] {
    #[sources: "tests/**/*.eco"]
    #[requires: "echopack/carbon/fake" { version: "^0.2.1", source: git "https://github.com/echopack/carbon" }]
    // the two testing modules ...
}

// `echoc test --target unit` needs no database; `--target integration` is the flows alone
#[target: test { name: "unit", groups: ["unit"] }]
#[target: test { name: "integration", groups: ["integration"] }]
```

You need a MySQL server for the integration tests. The easiest way is to let ecotest start one in Docker. The blog's `ecotest.json` describes it:

```json title="ecotest.json"
{
  "services": [
    {
      "name": "mysql",
      "run": ["sh", "-c", "docker rm -f nexus-blog-test >/dev/null 2>&1; exec docker run --rm --name nexus-blog-test -e MYSQL_ROOT_PASSWORD=test -p 127.0.0.1:33071:3306 --tmpfs /var/lib/mysql mysql:8.0 --skip-log-bin"],
      "url": "mysql://root:test@127.0.0.1:33071/?fetchServerKey=true"
    }
  ]
}
```

ecotest starts the service, exports its URL as `ECOTEST_MYSQL_URL`, runs the tests, and stops it again. The `--tmpfs` keeps the data in memory, which makes creating a database per test cheap.

From `examples/blog`, these are the ways to run them:

```sh
# MySQL in Docker, started from ecotest.json
epm run -m ../.. ecotest

# your own server; each test creates and drops its database there
BLOG_TEST_DATABASE_URL=mysql://root:pw@127.0.0.1:3306/ echoc test

# no database at all: only the unit group
echoc test --target unit
```

The `-m ../..` runs the ecotest that the nexus repository vendors, since the blog lives inside it. A plain `echoc test` without either variable runs everything and skips the flows.

### The whole repository

`scripts/test.sh` at the repository root runs every suite the same way: the core, each module, and the blog, each through ecotest (so suites with an `ecotest.json` get their MySQL or Redis in Docker). It then checks with `nexus gen --check` that no generated file is stale, and finishes with the blog's smoke test over a real socket. `DOCKER=0` skips everything that needs Docker, `SMOKE=0` skips just the smoke test, and `IMAGE=mariadb:11` runs it on another server.

## Settings

These are read by the tests, not the app:

| Variable | What it does |
|:--|:--|
| `BLOG_TEST_DATABASE_URL` | The blog's own name for a MySQL server to create test databases on. Name yours after your app. |
| `ECOTEST_MYSQL_URL` | Set by ecotest for the `mysql` service in `ecotest.json`. |

## Where to next

- [Database](./database.md): the migrations each test database runs.
- [Configuration](./configuration.md): the settings you pass to `TestApp`.
- [Deployment](./deployment.md): running the same binary for real.
