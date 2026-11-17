---
description: Typed disks on a directory, in memory or in S3, with uploads, downloads that honor ranges, and links that expire.
---

# Files

Most apps keep some files: avatars, attachments, the cover image of a blog post. Where they live tends to change over an app's life. On your laptop a directory is perfect, in the tests you would rather not touch the disk at all, and in production the files belong in a bucket. If your code talks to each of those differently, every move hurts.

nexus-files gives each place you keep files a name and a type, and puts the choice of where behind one URL. Your code calls `put`, `get` and `respond` on a disk, and the same code works on a directory, in memory and in S3.

To add it, require the module in your app's `module.eco`, plus the S3 module if a disk may live in a bucket:

```echo title="module.eco"
#[requires: "echopack/nexus/modules/files" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
#[requires: "echopack/nexus/modules/files/s3" { version: "^0.1.0", source: git "https://github.com/echopack/nexus" }]
```

Then list their extensions, the S3 one after the files one:

```echo title="src/Extensions.eco"
nexus::files::Extension(),
nexus::files::s3::Extension(),
```

## Naming a disk

Each place you keep files is a volume: an empty marker struct. The disk of that volume is a type, `nexus::files::Disk<V>`, and you give it a short name with an alias. Here is where the blog keeps its covers:

```echo title="src/Disks/CoverDisk.eco"
namespace Blog::Disks;

public struct CoverVolume : nexus::files::Volume {}

public type CoverDisk = nexus::files::Disk<CoverVolume>;
```

Why a type per disk? Because a service then asks for exactly the disk it uses. A `CoverService` that takes a `CoverDisk` can't be handed the disk of invoices by mistake, and the compiler says so if you try.

You bind the disk where the app is wired, with a name and the URL of where its files go:

```echo title="src/Providers/CoversProvider.eco"
$app->bindDisk<CoverVolume>('covers', url: $app->get<BlogConfig>()->coversUrl);
$app->bind<CoverService>(scoped: (Container $c) => CoverService($c->get<PostRepository>(), $c->get<CoverDisk>(), $c->get<nexus::Logger>()));
```

The name shows up in links and in the `files:*` commands, so it may only hold lowercase letters, digits and dashes. The disk is bound once for the whole process, and anything that needs it takes it through its constructor. [Extensions and wiring](./extensions.md) covers bindings and providers.

> [!NOTE]
> List `nexus::files::Extension()` before the extension that binds disks. If it comes later, the boot stops and says so.

### Where the files go

The URL picks the store. The blog reads it from its own setting, `BLOG_COVERS_URL`, so each environment may choose:

| URL | Where the files are |
|:--|:--|
| `file:storage/covers` | A directory, relative to where the app runs. |
| `file:///srv/covers` | A directory, absolute. |
| `memory:` | In memory, gone when the process ends. Handy for tests. |
| `s3://bucket/prefix` | Objects under `prefix` in an S3 bucket. Needs nexus-files-s3. |

The `s3://` disks work with AWS and with anything that speaks S3, such as MinIO, R2, Hetzner or Wasabi. The bucket and prefix are each disk's own; the credentials and region are shared, in `NEXUS_FILES_S3_*`, listed under the settings at the end of this page.

Every disk is checked at boot. A directory that can't be written, or a bucket that can't be listed, stops the app before it serves its first request, not when the first upload comes in.

## Keeping and reading files

A disk keeps bytes under a key. Keys are yours to make: `/`-separated, relative, like `posts/5/cover-1a2b.png`.

```echo
guard $this->covers->put('posts/5/cover-1a2b.png', $bytes, type: 'image/png') else ($e) {
    return .error($e->problem());
};

string $png = try $this->covers->get('posts/5/cover-1a2b.png');
```

A key is never absolute, never holds `.` or `..` segments, a backslash or a control character, and is at most 1024 bytes, so a key can name nothing outside its disk. Even so, you should never use a file name a client sent as a key. The blog makes a fresh one for each cover:

```echo title="src/Services/CoverService.eco"
internal static function keyFor(const string& $dir, const string& $type) : result<string, nexus::Problem>
{
    string $ext = nexus::Upload::extensionOf($type);
    string $nonce = guard crypto::random(4) else {
        return .error(.unavailable('no randomness for a cover name'));
    };
    string $tag = crypto::hex($nonce);
    return .ok("{$dir}/cover-{$tag}.{$ext}");
}
```

A new key per cover has a nice side effect: a browser that cached the old cover never mistakes it for the new one.

Besides `put` and `get`, a disk has what you would expect:

| Method | What it does |
|:--|:--|
| `putFile($key, $path, type:)` | Keeps a file from this machine without reading it into memory. |
| `saveTo($key, $path)` | Writes a file to this machine without reading it into memory. |
| `read($key, $from, $length)` | A slice of the file, enough to look at how it starts. |
| `stat($key)` | Its size, type, ETag and modification time, or null. |
| `exists($key)` | Whether anything is kept under the key. |
| `list($prefix)` | Every file whose key starts with the prefix. |
| `copy($from, $to)` / `move($from, $to)` | Copies or moves a file within the disk. |
| `delete($key)` | Forgets the file. One that is not there is fine. |

Each answers a `result` or `status` with a `nexus::files::FilesError`. `$e->problem()` turns it into the right `nexus::Problem` for the client: a `404` for a missing file, `400` for a bad key, `503` for a store that failed. The paths and bucket names stay in the log, not in the answer.

## Taking an upload

When a client sends a file in a multipart form, describe it as an input with a `nexus::Upload` field. The rules check its size and what it is by its bytes, not by what the client claims:

```echo title="src/Inputs/CoverUpload.eco"
#[nexus::input]
public struct CoverUpload
{
    #[nexus::rule: { maxBytes: 2097152, types: ['image/png', 'image/jpeg', 'image/webp'] }]
    public nexus::Upload $image;
}
```

The action takes the body, and the service puts the upload on the disk. `put` with an upload keeps it as the type its bytes show:

```echo title="src/Services/CoverService.eco"
public function upload(const User& $me, int64 $id, const nexus::Upload& $image) : result<Post, nexus::Problem>
{
    Post $p = try $this->changeable($me, $id);
    string $key = try CoverService::keyFor("posts/{$id}", $image->kind());
    guard $this->covers->put($key, $image) else ($e) {
        return .error($this->failed($e));
    };
    return $this->replace($p, $key);
}
```

[Input and validation](./input.md) has every rule an upload may carry.

## Serving a file

To answer a request with a file, hand the payload and the key to `respond`:

```echo title="src/Services/CoverService.eco"
public function show(nexus::Payload& $payload, int64 $id) : result<nexus::Response, nexus::Problem>
{
    Post $p = try $this->post($id);
    string $key = guard $p->cover else {
        return .error(.notFound('a cover'));
    };
    string $ext = nexus::files::Keys::extension($key);
    return $this->covers->respond($payload, $key, name: "post-{$id}-cover.{$ext}", inline: true);
}
```

On a directory or memory disk, the blog sends the file itself, and does the fiddly parts for you: `Range` requests get a `206` with the part asked for, a client whose copy is current gets a `304`, and the response carries `X-Content-Type-Options: nosniff`. A browser saves the file as `name` (the key's last segment when you give none), or shows it when `inline` is true and its type is safe to show.

On S3, `respond` answers with a redirect to a link the bucket signed, good for five minutes, so the bytes never pass through your app. Your action doesn't change either way.

## Links that expire

Sometimes you would rather hand a client a link than the file: a download in a mail, or an image on a page. `url` gives you a link anyone holding it may read the file with, until it expires:

```echo
nexus::Url $link = try $this->covers->url($key);
nexus::Url $longer = try $this->covers->url($key, expires: .hours(1), name: 'cover.png');
```

Without `expires:`, a link lasts `NEXUS_FILES_EXPIRES`, fifteen minutes by default.

So, who signs these links? S3 signs its own, and the link points straight at the bucket. S3 takes a link that lasts one second to seven days: asking for one outside that is an `unsupported` error, and a `NEXUS_FILES_EXPIRES` outside it stops the boot of an app with an `s3://` disk. Every other disk is served by nexus-files itself, on a signed route the extension adds: `GET|PUT /files/{disk}/{key*}`. Those links are signed with `NEXUS_FILES_KEY`, so binding a `file:` or `memory:` disk needs that key, at least 32 characters long. A link that was changed or has expired gets a `403`.

> [!WARNING]
> Changing `NEXUS_FILES_KEY` ends every link handed out with the old key.

### Uploading straight to the store

A big file passing through your app costs memory and time for no gain. You may instead hand the client a link to upload to the disk directly, then check the result once it is there. The blog does this in two steps. First, a link:

```echo title="src/Services/CoverService.eco"
public function link(const User& $me, int64 $id, const string& $type) : result<json::Value, nexus::Problem>
{
    try $this->changeable($me, $id);
    string $key = try CoverService::keyFor("posts/{$id}/pending", $type);
    nexus::files::Signed $up = guard $this->covers->uploadUrl($key, expires: .mins(10), type: $type, maxBytes: CoverService::MAX_BYTES) else ($e) {
        return .error($this->failed($e));
    };
    json::Value $out = $up->json();
    $out['key'] = json::str($key);
    return .ok($out);
}
```

`$up->json()` is `{url, method, headers, expires_at}`: the client sends a `PUT` of the bytes to `url` with those headers, no session needed. On a disk nexus-files serves, the upload must match the type and fit `maxBytes`, or it gets a `415` or `413`.

Then, once the client says it is done, the blog confirms the key: it checks the file is there, still small enough, and an image by its first bytes, and only then moves it out of `pending/` and onto the post:

```echo
nexus::files::Stat? $found = guard $this->covers->stat($key) else ($e) {
    return .error($this->failed($e));
};
// ... too large? delete it and refuse
string $head = guard $this->covers->read($key, 0, 16) else ($e) {
    return .error($this->failed($e));
};
string $kind = nexus::Upload::sniff($head) ?? '';
```

Here is the catch with S3: a presigned upload cannot be held to a size, so the bucket takes whatever the client sends. That is why you should `stat` the key and check its size before trusting it, as the blog does.

## Commands

The extension adds two commands that are handy when setting up a server:

```sh
blog files:list --disk covers --prefix posts/5/
blog files:check --disk covers
```

`files:list` lists a disk's files. `files:check` writes a small file, reads it back, checks a range of it and deletes it, so you know the disk works before the first upload does. See [commands](./commands.md) for how commands run.

## Testing with files

In the tests, `memory:` is the disk you want: fast, empty for every test, and nothing left behind. The blog sets `BLOG_COVERS_URL=memory:` (with a `NEXUS_FILES_KEY`) and reads the disk straight from the container to check what was kept:

```echo title="tests/integration/CoversFlowTest.eco"
CoverDisk $disk = $world->app->kernel->services->get<CoverDisk>();
array<nexus::files::Stat> $all = expect($disk->list("posts/{$id}/"))->ok();
$world->api->with('If-None-Match', $all[0]->etag)->get("/v1/posts/{$id}/cover")->status(304);
```

[Testing](./testing.md) shows how the blog boots its app for tests like these.

## Settings

| Variable | Default | Meaning |
|:--|:--|:--|
| `NEXUS_FILES_KEY` | | Signs the links of `file:` and `memory:` disks. At least 32 characters; required when you bind one. |
| `NEXUS_FILES_EXPIRES` | `15m` | How long a link lasts when the code names no time. At most `7d` with an S3 disk. |
| `NEXUS_FILES_ROUTE` | `/files` | Where the signed route answers. |
| `NEXUS_FILES_S3_ACCESS_KEY` | | The S3 access key. |
| `NEXUS_FILES_S3_SECRET_KEY` | | The S3 secret key. |
| `NEXUS_FILES_S3_SESSION_TOKEN` | | For temporary credentials only. |
| `NEXUS_FILES_S3_REGION` | `us-east-1` | The bucket's region. |
| `NEXUS_FILES_S3_ENDPOINT` | | The store's address when it is not AWS, like `http://127.0.0.1:9000` for MinIO. |
| `NEXUS_FILES_S3_PATH_STYLE` | `false` | Puts the bucket in the path (`host/bucket/key`, what MinIO wants) instead of the host name. |
| `NEXUS_FILES_S3_TIMEOUT` | `10m` | How long one request may take, a whole upload or download included. |

[Configuration](./configuration.md) covers how these are read.

## Where to next

- [Input and validation](./input.md): the rules for uploads.
- [Responses](./responses.md): downloads, redirects and ranges on your own responses.
- [Deployment](./deployment.md): pointing a disk at a bucket in production.
