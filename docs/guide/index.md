---
description: What nexus is, the two ideas it is built on, and how to find your way through these docs.
---

# Introduction

You want to build an API in Echo. You'd like the compiler to catch as much as it can: a misspelled field, a route that points nowhere, a handler that expects a number the path can't give it. You'd rather not write the same plumbing every web app needs (decoding, validation, error documents, config, auth, background work) for the hundredth time. And you'd like to read your app's wiring top to bottom without hunting through annotations.

nexus is the HTTP application framework for Echo, built for exactly that. It is API-first and typed from the route to the response.

```echo title="src/Actions/Posts/ShowPost.eco"
public class ShowPost : nexus::Action
{
    private PostService $posts;
    private PostTransformer $transformer;

    public constructor(PostService $posts, PostTransformer $transformer)
    {
        $this->posts = $posts;
        $this->transformer = $transformer;
    }

    public function handle(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
    {
        $post = try $this->posts->find($id);
        return $this->transformer->createResponse($payload, $post);
    }
}
```

```echo title="src/Providers/PostsProvider.eco"
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostService>(), $c->get<PostTransformer>()))
    ->route([.get], '/v1/posts/{id}');
```

That's a complete endpoint. `{id}` arrives as an `int64` (a path that isn't a number is a `404`), a missing post is a `404` problem document, and the answer is JSON or XML, whichever the client accepts.

## Two ideas

If you remember only two things about nexus, make it these.

### Registration by hand

Where things answer is code you write: the route of each action, the name of each command, each MCP tool, each queue and schedule. It all lives in your app's `services()`, usually split into one provider per part of the app. There is no folder scanning and no route annotation. To find out what `/v1/posts/{id}` runs, you search for the string and land on the line that builds it.

### Generation by type

What can be read from the types, nexus reads, so you never write it. `nexus gen` runs before every build and writes the code that decodes each action's input, checks its rules, calls its `handle()` and encodes what it returns; it also writes your config loaders, mail templates and JSON schemas. The two halves meet at boot, where the kernel checks they agree. A route to an action without a binding, or a path parameter `handle()` doesn't take, stops the process before the first request.

The upshot: your code says what you mean, and everything that is merely tedious is generated and checked.

## What's in the box

nexus is a small core plus modules you opt into:

- **The core**: actions, routing, validated input, responses, middleware, RFC 9457 problems, typed config, signals, structured logging, translations, and a command line for the app binary.
- **Serving and data**: an HTTP/1.1 server, a carbon database with a session per request, transformers, and ready-made CRUD.
- **Security**: bearer tokens and signed sessions, an OAuth 2.1 server, and sign-in with Google.
- **Background work**: tasks on in-process or distributed queues, pipelines and a scheduler.
- **Services**: mail, files (local or S3) and a cache (memory or Redis).
- **Realtime and agents**: websocket channels, MCP tools, and a debug console.

The [modules](./modules.md) page lists every one, with the two lines that add it.

## One binary

A nexus app builds to a single executable. `serve` answers HTTP and runs the workers and the scheduler; `work` runs the workers and the scheduler without HTTP; `migrate` updates the database; and your own commands sit beside them. Your mail templates and translations are built in, so the binary is all you deploy.

## How these docs are organized

If you're new, we suggest reading in this order:

1. [Installation](./installation.md): a project with one endpoint, running.
2. [Your first API](./tutorial.md): a posts API with a database, validation and a transformer, built step by step.
3. [The request lifecycle](./lifecycle.md): what happens between the socket and your action, so nothing feels "magical."

After that, the sidebar is grouped by what you're trying to do. Each page starts with the problem it solves, so you may jump straight to the one you need. The [API reference](/api/) documents every public type of every module, straight from the source.

Throughout the docs, examples come from `examples/blog` in the nexus repository: a complete blog with users, posts, comments and covers, which you may run and read alongside.
