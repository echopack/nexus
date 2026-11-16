---
description: Offering the app's tools to models over the Model Context Protocol, with schemas written from your types.
---

# MCP tools

More and more, the one calling your app isn't a person in a browser but a model: an assistant that wants to read a post, or write one on someone's behalf. The Model Context Protocol (MCP) is how such a client discovers what your app can do and calls it. Each thing it can do is a tool, with a name, a description, and a JSON Schema for its arguments.

Writing those schemas by hand, and keeping them in step with your code, is exactly the kind of chore nexus avoids. With nexus-mcp, a tool is a class whose `handle()` takes an input struct, much like an action. `nexus gen` writes the schema from the struct's types, rules and docblocks, and an existing action may become a tool with one line.

To add it, require the module in your app's `module.eco`:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/mcp" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list its extension after nexus-auth, since every call needs a signed in caller, and before your app:

```echo title="src/Extensions.eco"
// the `/mcp` endpoint that offers the blog's tools to models
nexus::mcp::Extension(),
```

## Your first tool

A tool is a class conforming to `nexus::mcp::Tool`. Its `handle()` takes the payload and one `#[nexus::input]` struct, whose fields are the tool's arguments. Here is the blog's tool for writing a post:

```echo title="src/Tools/CreatePostTool.eco"
namespace Blog::Tools;

use Blog::Inputs::NewPost;
use Blog::Services::PostService;
use Blog::Transformers::PostTransformer;
use Blog::Types::Caller;

/**
 * Publishes a post by the signed in user: a title of 3 to 120 characters, a body, and up to five
 * tags. Answers the post as the API does.
 */
#[nexus::through: ["Blog::Middleware::RequireUser"]]
public class CreatePostTool : nexus::mcp::Tool
{
    private PostService $posts;
    private PostTransformer $transformer;

    public constructor(PostService $posts, PostTransformer $transformer)
    {
        $this->posts = $posts;
        $this->transformer = $transformer;
    }

    public function handle(nexus::Payload& $payload, NewPost $in) : result<nexus::Response, nexus::Problem>
    {
        $me = try $payload->state<Caller>();
        $made = try $this->posts->create($me->user, $in);
        return $this->transformer->createResponse($payload, $made);
    }
}
```

If this looks a lot like an [action](./actions.md), that is on purpose. It returns what an action returns, the middleware in `#[nexus::through]` runs around every call and leaves what it learned in the payload, and the logic lives in the same `PostService` the API's `CreatePost` uses. A model and an HTTP client end up running the very same code.

The docblock matters here: it is the description the model reads to decide when to use the tool. You should write it for that reader, saying what the tool does and what it needs.

### Offering it

Like an action, a tool doesn't say what it is called. You say that where the app is wired, with `bindTool` and `->offer()`:

```echo title="src/Providers/PostsProvider.eco"
$app->bindTool<CreatePostTool>((Container $c) => CreatePostTool($c->get<PostService>(), $c->get<PostTransformer>()))
    ->offer('create_post', title: 'Write a post');
```

The name is what the model calls, 1 to 64 letters, digits, `_` and `-`. The tool is built for each call on that call's own container, as an action is for each request. [Extensions and wiring](./extensions.md) has the full story on bindings.

`->offer()` also takes a `description:` when you would rather not use the docblock, and the hints MCP clients show: `readOnly:`, `destructive:`, `idempotent:` and `openWorld:`.

## The schema, written for you

`nexus gen` reads the input struct and writes the JSON Schema of the tool's arguments. Here is the blog's `NewPost`:

```echo title="src/Inputs/NewPost.eco"
#[nexus::input]
public struct NewPost
{
    #[nexus::rule: { min: 3, max: 120 }]
    public string $title;

    #[nexus::rule: { notBlank: true }]
    public string $body;

    #[nexus::rule: { max: 5, distinct: true, each: { trim: true, lower: true, notBlank: true, max: 30 } }]
    public array<string> $tags = [];
}
```

From that, `tools/list` tells the model that `title` is a required string of 3 to 120 characters, `body` a required non-empty string, and `tags` an optional array of at most five distinct strings. Types become JSON types, rules become keywords like `minLength`, `maxLength`, `enum` or `format`, and a docblock on a field becomes its `description`. Since the schema comes from the same struct that checks the input, the two can never disagree.

Every rule is still checked when the tool runs, exactly as for an HTTP body. [Input and validation](./input.md) lists them all.

## An action as a tool

Often the tool you want is an endpoint you already have. Rather than writing a second class, you may offer the action itself with `->tool()`:

```echo title="src/Providers/PostsProvider.eco"
$app->bindAction<ShowPost>((Container $c) => ShowPost($c->get<PostCRUD>()))
    ->route([.get], '/v1/posts/{id}')
    ->tool(
        'show_post',
        title: 'Read a post',
        description: 'One post of the blog by its id: title, body, tags and when it was written.',
        readOnly: true,
        map: ['post' => 'id']
    );
```

The action's path parameters and its input's fields become the tool's arguments. `map:` renames them, tool argument to the name `handle()` uses, so the model sees a `post` argument while the action still gets its `id`. A path parameter and an input field may not share a name, since both end up side by side as arguments.

## Calling the endpoint

The endpoint is `POST /mcp`, the stateless form of MCP's Streamable HTTP transport: one JSON-RPC message per request, answered with one JSON body. It speaks `initialize`, `ping`, `tools/list` and `tools/call`. There are no sessions and no streams, so `GET` and `DELETE` on `/mcp` answer `405`.

A call looks like this:

```json
{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
 "params": {"name": "create_post", "arguments": {"title": "Over MCP", "body": "Written by a model"}}}
```

The tool's response comes back as text content, and a JSON object body as `structuredContent` too, so the model gets the post exactly as the API answers it.

So, what happens when the model gets an argument wrong? A refused input, an argument the tool does not take, or a problem from your code come back as a tool result with `isError: true` and the problem as text. That is a message the model can read and correct, rather than a protocol error it can't do much with.

### Introducing the server

The extension takes how the server introduces itself in `initialize`: a `name`, `title`, `version`, and `instructions` for the model, such as which tool to start with:

```echo
nexus::mcp::Extension(name: 'blog', title: 'A nexus blog', instructions: 'A blog. Read a post with show_post before changing it.'),
```

## Who may call

Every MCP message needs a signed in caller, read by nexus-auth's guards, the same way as any other request. Without one, the answer is a `401`.

The endpoint is also a nexus-auth resource named `mcp`. Add the [OAuth server](./oauth.md) and this pays off: the `401` names where to sign in, so an MCP client like a desktop assistant walks its user through signing in by itself and gets a token for the `mcp` resource alone, which opens nothing else in your app. The blog does exactly that; nobody pastes a token anywhere. [Authentication](./auth.md) covers guards and resources.

## Testing tools

Since the endpoint is plain HTTP, a test posts JSON-RPC messages to it like any other request. The blog's flow lists the tools, checks the schemas, and calls them:

```echo title="tests/integration/McpFlowTest.eco"
rpc($admin, 'tools/list', json::object())
    ->status(200)
    ->json('$.result.tools[1].name', 'create_post')
    ->json('$.result.tools[1].inputSchema.properties.title.maxLength', 120);

$id = toolCall($admin, 'create_post', json::object(['title' => 'Over MCP', 'body' => 'Written by a model']))
    ->json('$.result.isError', false)
    ->capture('$.result.structuredContent.data.id');

toolCall($admin, 'create_post', json::object(['title' => 'No']))
    ->json('$.result.isError', true);
```

`rpc` and `toolCall` are two small helpers in that test that wrap the message. [Testing](./testing.md) has the rest.

## Where to next

- [OAuth server](./oauth.md): letting MCP clients sign in by themselves.
- [Input and validation](./input.md): the rules that become the schema.
- [nexus gen](./generator.md): what is generated for each tool.
