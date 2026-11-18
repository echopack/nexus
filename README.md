# nexus

The HTTP application framework for Echo. Typed from the route to the response: you wire the app by hand, in code you can read, and `nexus gen` writes everything the types already say.

**Docs:** <https://echopack.github.io/nexus> (sources in [`docs/`](docs/), built with [ecodoc](https://github.com/echolang/ecodoc))

```bash
echoc build
echoc test
```

To preview the docs locally:

```bash
(cd docs/_api && epm install)
ecodoc dev
```
