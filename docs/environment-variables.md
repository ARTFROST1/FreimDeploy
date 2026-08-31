# Environment variables

Environment variables are the single most common source of "it works locally, it is broken in
production". Freim Deploy has two completely different moments where a variable can matter, and a
variable that is not present in the right one simply does not exist as far as your site is concerned.

## The two moments

| | Build time | Runtime |
|---|---|---|
| When | while `install` and `build.command` run | while your process runs |
| Who reads it | your framework and build scripts | your application code |
| Where it ends up | baked into the built files, often into the client bundle | in the process environment only |
| Applies to | every project that has a build | `node` and `python` projects only |

A `static` project has **no runtime**: there is no process, the built files are served by the web
server. That has a consequence worth stating plainly:

> On a static project, a variable without a public prefix does nothing at all. It does not reach the
> build (it is not public) and it does not reach a runtime (there is none). You cannot pass a secret
> to a static site — there is nowhere for it to live. Public values must carry a public prefix.

## What reaches the build

Only these reach `install` and `build.command`:

1. Variables whose key starts with a **public prefix**: `PUBLIC_`, `VITE_`, `NEXT_PUBLIC_`,
   `GATSBY_`, `NUXT_PUBLIC_`, `REACT_APP_`. These are the prefixes frameworks use for values they are
   allowed to bake into the client bundle.
2. Variables explicitly marked **"expose to build"** in the panel — an opt-in checkbox for the rare
   dependency that needs a non-prefixed value at build time.

Everything else — that is, every secret — stays out of the build **by design**. The build environment
is passed as arguments to `sudo` (visible in `ps` to the whole host and in the system journal) and it
executes next to every transitive npm dependency you have. A secret has no business being there.

This is exactly why a static site with an empty `PUBLIC_*` value "silently breaks" in production:
without this step the value never reaches the build, and after the build there is nowhere left to
read it from.

## What reaches the runtime

Everything: secrets included. For a `node` or `python` project the panel writes an environment file
(mode 0600) and links it into the release as the systemd unit's `EnvironmentFile`. Your process reads
those variables normally, through `process.env` or `os.environ`.

Secrets are stored encrypted (AES-256-GCM) in the panel's database and are decrypted only when the
environment file is written.

## Defaults in `frostdeploy.json`

`run.env` in the file holds **non-secret defaults**:

```json
"run": {
  "command": "node dist/server/entry.mjs",
  "env": { "LOG_LEVEL": "info" }
}
```

They apply only to keys that are not set in the panel. The order is always:

**a service's own variable (panel) > the project's shared variable (panel) > `run.env` from the file.**

## Changing a variable rebuilds the site

Normally, deploying the same commit twice is skipped — nothing changed. But a build-time variable
changes the *output* of that same commit, so if variables were edited after the last successful
build, the pipeline forces a rebuild instead of skipping, and the log says so:

```
Env variables changed since the last deploy — rebuilding same SHA
```

The panel also shows an "unapplied changes" banner on a project whose variables have moved ahead of
its last deploy.

## Multiservice projects

In a project with several services, each service sees the union of two sets: the project's shared
variables (not attached to any service) and its own. On a key collision the service's own value wins.

Build exposure is resolved per service: one service's `PUBLIC_*` variable never leaks into another
service's build, even when both read the same shared project set.

## Rules of thumb

- Secret → panel, never the file, never a public prefix.
- Needed by the browser → public prefix, and remember it will be visible in the page source.
- Needed by a build script but not by the browser → panel, with "expose to build" checked.
- Changed a build-time value → redeploy; the rebuild is forced for you.
- Static project → no runtime, no secrets, public prefixes only.
