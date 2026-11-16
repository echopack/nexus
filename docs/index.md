---
layout: home
hero:
  name: nexus
  text: The HTTP application framework for Echo
  tagline: Typed from the route to the response. You wire the app by hand, in code you can read; nexus generates everything the types already say.
  actions:
    - theme: brand
      text: Get started
      link: /guide/
    - text: Your first API
      link: /guide/tutorial
    - text: API reference
      link: /api/
features:
  - title: One class per endpoint
    details: An action's handle() signature says what the request must provide and its return type says what goes back. nexus gen writes the code in between.
    link: /guide/actions
  - title: Validation before your code runs
    details: Input structs carry their rules. Every refused field comes back in one 422, with a stable code for clients and a translated message for people.
    link: /guide/input
  - title: Mistakes stop the boot
    details: An unbound action, a missing middleware, a dependency cycle or a bad setting refuses to start, naming what to fix. Never a 500 days later.
    link: /guide/lifecycle
  - title: Every door, one service
    details: The same service answers HTTP actions, command line commands and MCP tools, with the same middleware around each.
    link: /guide/extensions
  - title: Batteries you opt into
    details: Auth with signed sessions, an OAuth 2.1 server, queues and a scheduler, mail, files, cache, realtime channels and a debug console.
    link: /guide/modules
  - title: One binary
    details: serve, work, migrate and your own commands, with templates and translations built in. Typed config from the environment, listed by the env command.
    link: /guide/deployment
---

You want an API whose wiring you can read and whose plumbing you never write. Bind an action, give it a route, and let the types do the rest:

```echo
$app->bindAction<CreatePost>((Container $c) => CreatePost($c->get<PostService>(), $c->get<PostTransformer>()))
    ->route([.post], '/v1/posts');
```

```echo
#[nexus::input]
public struct NewPost
{
    #[nexus::rule: { min: 3, max: 120 }]
    public string $title;

    #[nexus::rule: { notBlank: true }]
    public string $body;
}

public class CreatePost : nexus::Action
{
    // ...

    public function handle(nexus::Payload& $payload, nexus::Body<NewPost> $in) : result<nexus::Response, nexus::Problem>
    {
        $made = try $this->posts->create($in->value);
        return $this->transformer->createResponse($payload, $made, status: 201);
    }
}
```

The body is decoded and checked before `handle()` runs, a bad one is answered with a `422` listing every field, and the post comes back as JSON or XML, whichever the client asked for.

Ready? [Install nexus](/guide/installation) and have your first endpoint answering in a few minutes.
