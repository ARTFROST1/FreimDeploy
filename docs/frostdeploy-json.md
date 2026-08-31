# frostdeploy.json

The project configuration file — Freim Deploy's answer to `vercel.json` or `render.yaml`. It lives in
the **root of your repository**. Everything in it is optional: without the file, a project is
deployed using the settings from the panel and framework autodetection.

> **Why the old name?** The product was renamed from FrostDeploy to Freim Deploy, but this file is a
> contract with every install and every repository that already exists, so it was deliberately left
> alone and will keep the old name. It is `frostdeploy.json`; nothing reads `freimdeploy.json`.

**Priority: `frostdeploy.json` > project settings in the panel > framework autodetection.**

The file is read on every deploy, from the checkout of the commit being deployed. That means your
build settings are versioned together with your code, and rolling back to an older commit rolls back
its build settings too. The file is also read when you create a project: the wizard parses it with
the same schema, pre-fills `kind` / `build` / `run` / `rootDir` and the list of `services[]`, and
marks those fields as coming from the file. An invalid file shows a warning in the wizard (it does
not block creation) — but the deploy itself will refuse it with the schema error.

## Full schema

```jsonc
{
  // Project type:
  //  "static" — files served by Caddy's file_server: no process, no port
  //  "node"   — a long-running process under systemd (SSR, hybrid, API)
  "kind": "static",

  "build": {
    // Build shell command. '&&' and pipes are allowed.
    // null = no build at all (plain HTML — the repo is served as-is)
    "command": "npm run build",

    // What to serve (for kind=static), relative to rootDir
    "output": "dist",

    // Package manager: auto | npm | pnpm | yarn | none
    // auto = detected from the lockfile; none = no dependencies, install is skipped
    "install": "auto"
  },

  "run": {                       // kind=node only
    // Start command. This is what goes into the systemd unit.
    "command": "node dist/server/entry.mjs",

    // Healthcheck path after restart (default "/")
    "healthcheckPath": "/",

    // NON-secret env defaults. Secrets belong in the panel:
    // values set in the panel win over these.
    "env": { "LOG_LEVEL": "info" }
  },

  // kind=node only: application static files served straight off disk by the
  // web server instead of by your process — see "Static files of SSR projects".
  "assets": {
    // Directory with the files, relative to rootDir
    "root": "dist/client",

    // Request paths that go to disk (Caddy path matchers)
    "paths": ["/_astro/*"],

    // Cache-Control header, verbatim.
    // Default: "public, max-age=31536000, immutable"
    "cacheControl": "public, max-age=31536000, immutable",

    // File missing on disk: proxy — pass the request to the app (default),
    // 404 — answer immediately
    "fallback": "proxy"
  },

  // Monorepo: the subdirectory that is the root of this application
  "rootDir": "website",

  "nodeVersion": "22",

  // Language / process runtime: static | node | python (see below)
  "runtime": "node",

  // Service role: web (listens on a port and a domain) | worker (background process)
  "role": "web",

  // Python version (runtime=python only)
  "pythonVersion": "3.12"
}
```

## How `kind` is chosen

| Situation | kind |
|---|---|
| Astro with no adapter (`output: 'static'`, no `adapter`) | `static` |
| Astro **hybrid**: `output: 'static'` + `adapter: node(...)` (API routes present) | **`node`** — there is a process |
| Astro SSR: `output: 'server'` | `node` |
| Plain HTML/CSS/JS files | `static`, `build.command: null` |
| Express / Fastify / Nest / Next | `node` |

The rule is simple: **if something has to keep running after the build, it is `node`.** `static` is
only for the case where the build result is a folder of files and nothing else.

## Static files of SSR projects: `assets`

An SSR or hybrid project (`kind: "node"`) has static files of its own — `dist/client` in Astro — and
by default **your process** serves them. Astro's Node adapter sends those files with
`cache-control: public, max-age=0`, which means the browser must revalidate **every** file on
**every** visit. That revalidation is pointless by construction: the hash is already in the filename
(`BaseLayout.Di4Pqxy0.css`), so if the bytes change, the address changes too. On a real site with a
large image gallery this measured out at hundreds of megabytes of static files and a TTFB above one
second for a single CSS file.

The `assets` block moves the listed paths onto the web server's `file_server` with a real
`Cache-Control`:

```jsonc
"assets": {
  "root": "dist/client",                                  // relative to rootDir
  "paths": ["/_astro/*"],                                 // Caddy path matchers
  "cacheControl": "public, max-age=31536000, immutable",  // this is the default
  "fallback": "proxy"                                     // proxy (default) | 404
}
```

**Opt-in only.** An application that generates or rewrites anything under those paths must keep
serving them itself — which is why this block is never enabled automatically by framework detection.

**`fallback: "proxy"` makes turning it on nearly risk-free:** if the file is not on disk, the request
continues to your application instead of getting a 404 from the web server. That is why it is the
default.

| Field | Type | Required | Description |
|---|---|---|---|
| `root` | string | yes | Directory with the files, relative to `rootDir`. No `..`, no leading `/` — same rule as `build.output` |
| `paths` | string[] | yes | 1–20 Caddy path matchers, each starting with `/`. Anything that does not match goes to the application |
| `cacheControl` | string | no | The header, verbatim; defaults to `public, max-age=31536000, immutable`. Only header-safe characters are allowed (a newline is a validation error) |
| `fallback` | `proxy \| 404` | no (default `proxy`) | What to do when the file is missing on disk |

Things worth knowing:

- **`assets` is meaningless for `runtime: "static"`** — there the whole output directory is already
  served from disk. It is a validation error, not an ignored field.
- **Permissions.** The web server runs under its own account, so the pipeline grants `o+rX` on the
  declared `root` (and `o+X` on the path to it) — **strictly on that directory, not on the whole
  `dist/`**: your server-side code sits next to it and there is no reason to open it to every local
  account on the host.
- **If `root` is missing or empty after the build, the deploy fails** — before activation, so the
  live site is untouched. Silently falling back to "everything through Node with `max-age=0`" would
  be exactly the thing you turned this on to avoid, and nothing in the log would say so.
- **Handler order is preserved:** compression and security headers are applied *above* disk serving,
  so these files are still compressed and still carry the same headers as the rest of the site.
- **Removing the block removes the route.** The file is authoritative here: the next deploy without
  `assets` hands serving back to the application.
- The directory is resolved through the `current` symlink, so activating a new release does not
  require reloading Caddy.

## `runtime` and `role` (python workers)

`kind` remains a historical field: `static` means files, `node` means "there is a process" (in that
sense a python project is also stored as `kind: "node"` — Caddy and static serving decide by `kind`).
`runtime` is the more precise field on top of it: **which language or process** is actually running.

| `runtime` | What it is | `kind` underneath |
|---|---|---|
| `static` | files behind Caddy's file_server | `static` |
| `node` | a Node process (Express, Astro SSR/hybrid, Next…) | `node` |
| `python` | a python process (FastAPI, a Telegram bot, a queue worker…) | `node` — there is a process, it just is not Node |

`role` says what kind of process it is:

| `role` | What it is | Port / domain | Healthcheck |
|---|---|---|---|
| `web` | long-running server answering HTTP | assigned automatically, your app listens on `process.env.PORT` | HTTP GET on `run.healthcheckPath` (default `/`) after restart |
| `worker` | background process with no HTTP (a bot, a queue consumer) | **none** — no port, no domain, no `healthcheckPath` | systemd status: the unit is `active`/`running` **and** the restart counter did not grow during the settle window (otherwise it is a crash loop, which `ActiveState` alone does not catch) |

Resolution priority is the same as everywhere: **`frostdeploy.json` > project settings in the panel >
autodetection from `kind`.** If `runtime` is set neither in the file nor in the panel, it is derived
from `kind`: `static → static`, `node → node`.

### Installing python dependencies

`build.install` for `runtime: "python"` uses the same field with python values:

| `install` | Manager | Command |
|---|---|---|
| `auto` | from the lockfile: `uv.lock` → uv, `poetry.lock` → poetry, `requirements.txt` → pip, otherwise nothing | — |
| `pip` | pip + venv | `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt` |
| `uv` | uv | `uv sync --frozen` |
| `poetry` | poetry | `POETRY_VIRTUALENVS_IN_PROJECT=1 poetry install --no-root --only main` (the venv goes into `./.venv` so the unit finds it by a relative path) |
| `none` | no dependencies | install is skipped |

Combining `install: "pip"/"uv"/"poetry"` with `runtime: "node"` — or a Node package manager with
`runtime: "python"` — is a validation error, caught when the file is parsed.

`pythonVersion` (`3.10`–`3.13`) is currently an informational field: the pipeline creates the virtual
environment with the system `python3`.

`run.command` for python must be the one that actually uses the venv, e.g. `.venv/bin/python bot.py`
— not `python bot.py`, which would run the system interpreter and ignore the venv entirely.

### System requirements (runtime: python)

The pip path (`python3 -m venv .venv && .venv/bin/pip install …`) needs the **python3-venv** and
**python3-pip** packages on the server: Debian and Ubuntu ship `python3` without the `venv` and
`ensurepip` modules — they live in a separate `python3.X-venv` package.

- Servers connected through the panel get them out of the box; the bootstrap script installs
  `python3 python3-venv python3-pip`.
- On a manually prepared server, before the first python deploy: `apt install python3-venv python3-pip`.
- The deploy checks this itself: a `python3 -Im ensurepip --version` preflight runs before the install
  step, and if the package is missing the deploy fails **before the build starts**, with that same
  hint — instead of raw venv output from the middle of an install.
- The `uv` and `poetry` paths do not need ensurepip; they only need their own binary on the server.

## Examples

### 1. Astro static site

```json
{
  "kind": "static",
  "build": { "command": "astro check && astro build", "output": "dist" }
}
```

Note that `astro check && astro build` works — a chain with `&&` is fine. With no lockfile, install
falls back to `npm install`.

### 2. Astro hybrid — static plus API routes in a monorepo

```json
{
  "kind": "node",
  "rootDir": "website",
  "build": { "command": "npm run build" },
  "run": {
    "command": "node dist/server/entry.mjs",
    "healthcheckPath": "/"
  }
}
```

### 3. Astro SSR / hybrid with static served off disk

```json
{
  "kind": "node",
  "build": { "command": "npm run build" },
  "run": { "command": "node dist/server/entry.mjs" },
  "assets": { "root": "dist/client", "paths": ["/_astro/*"] }
}
```

Without the `assets` block the same project still works, but all static files are served by Node with
`max-age=0` — see "Static files of SSR projects".

### 4. Plain HTML, no build

```json
{
  "kind": "static",
  "build": { "command": null, "output": ".", "install": "none" }
}
```

### 5. Express API

```json
{
  "kind": "node",
  "build": { "command": null },
  "run": { "command": "node index.js", "healthcheckPath": "/health" }
}
```

### 6. Python worker — a Telegram bot

```jsonc
{
  "runtime": "python",
  "role": "worker",
  "build": { "install": "auto" }, // requirements.txt in the repo → pip + venv
  "run": { "command": ".venv/bin/python bot.py" }
}
```

A worker needs no port, no `healthcheckPath` and no domain — it listens to nothing. The panel knows
this from `role: "worker"`: `run.healthcheckPath` on a worker is a validation error, not an ignored
field. A worker's health after a restart is the systemd unit status (`active`/`running`, restart
counter flat), not HTTP polling.

## Multiservice: `services[]`

One repository can deploy several processes **in a single atomic release** — a site and a Telegram
bot, or an API and a background queue worker. The deploy stays a single deploy: one button, one
commit, one release directory — but the pipeline walks each service separately (its own install,
build, unit and healthcheck), and switching `current` to the new release is atomic for all services
at once.

Instead of the top-level `kind` / `build` / `run` / `assets` / `rootDir` / `runtime` / `role`, the
file describes a `services[]` array.

### Mutual exclusivity with top-level fields

`services` and the top-level `kind` / `build` / `run` / `assets` / `rootDir` / `runtime` / `role` are
**mutually exclusive**. If the file has `services`, the presence of any of those fields at the top
level is a schema validation error (the message lists only the fields actually present):

```
services[] is mutually exclusive with top-level kind, build, run, assets, rootDir, runtime, role — use per-service fields instead
```

Either one service the old way (top-level fields) or a `services[]` list — never mixed.

### When the repository has no `frostdeploy.json`

The priority principle — **file > database > autodetection** — applies to the *set of services* too,
not just to the fields of one service. If the file does not declare `services[]` (there is no file,
or it only has top-level fields), the topology comes from the **panel's database**:

- **One service in the database (or none)** — the classic single-service mode: one service is
  deployed and the file's top-level fields, if any, apply to it.
- **More than one service in the database** — **all** rows are deployed (multiservice driven by the
  database). This is the wizard's flow: the wizard detected, say, a site and a Telegram bot and
  created both rows, while the repository simply has no `frostdeploy.json`. No row is ever removed
  in this case. Top-level fields from the file, if present, apply **only to the primary (first)
  service**; the remaining rows resolve from their own database records.

**Tearing a service down happens only when the file explicitly declares `services[]` and omits a
row** — removing a service from `services[]` is a deliberate "take it down" instruction. A silent
file never removes anything; the only other way to delete a service is the explicit delete action in
the panel.

### Fields of one service entry

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Unique within `services[]`. Regex `^[a-z0-9][a-z0-9-]*$` (lowercase letters, digits, hyphens; starts with a letter or digit), max 32 characters |
| `runtime` | `static \| node \| python` | **yes** | Unlike the top-level `runtime`, there is no fallback to panel settings here — it is required on every entry |
| `role` | `web \| worker` | no (default `web`) | `static` cannot be a `worker` — static has no process |
| `rootDir` | string | no | Monorepo subdirectory that is the root of this particular service |
| `build` | `{ command, output, install }` | no | Same sub-schema as in the single-service format, per service |
| `run` | `{ command, healthcheckPath, env }` | see rules below | `run.env` — non-secret defaults for this service |
| `assets` | `{ root, paths, cacheControl, fallback }` | no | Static files of this service served off disk. `root` is relative to **this** service's `rootDir`. Only for `runtime` other than `static` |
| `domain` | string | no | The service's own domain or subdomain; `web` and `static` only |
| `nodeVersion` | `18\|20\|22\|24` | no | |
| `pythonVersion` | `3.10`–`3.13` | no | |
| `resources` | `{ memMax, cpuQuota, limitNofile }` | no | systemd limits for this service: `memMax` like `512M`/`2G`, `cpuQuota` like `150%`, `limitNofile` a positive integer |

### Validation rules

- `services[]`: at least 1, at most **10** entries.
- `name` is unique within the array — a duplicate is reported per entry:
  `duplicate service name "<name>" — names must be unique within services[]`.
- `runtime` is required on every entry (no fallback to the project row in the database, unlike the
  top-level `runtime`).
- `runtime: "static"` + `role: "worker"` — error: static has no process and cannot be a worker.
- `runtime: "static"` + `run` present — error: static has no process, so `run` is not allowed.
- `runtime: "static"` + `assets` present — error: such a service is already served from disk in full.
- Any process service (`runtime` other than `static`) must have `run.command` — otherwise you get
  `web services (runtime 'node') require run.command` or the equivalent for workers.
- `role: "worker"` forbids `run.healthcheckPath` and `domain` — a worker has no HTTP to answer and
  nothing to proxy through Caddy.
- Install coherence (`build.install` vs `runtime`) is checked against **each entry's own** runtime:
  `install: "pip"/"uv"/"poetry"` only with `runtime: "python"`; `install: "npm"/"pnpm"/"yarn"` with
  any runtime except `python`.
- `domain`, if set, must be a valid domain name (not a bare IPv4 address) with an alphabetic TLD.

### Example: a site plus a Telegram bot in one monorepo

```jsonc
{
  "services": [
    {
      "name": "web",
      "runtime": "node",
      "role": "web",
      "rootDir": "website",
      "build": { "command": "npm run build", "install": "auto" },
      "run": {
        "command": "node dist/server/entry.mjs",
        "healthcheckPath": "/",
        "env": { "LOG_LEVEL": "info" }
      },
      "domain": "example.com",
      "nodeVersion": "22",
      "resources": { "memMax": "1G", "cpuQuota": "150%" }
    },
    {
      "name": "bot",
      "runtime": "python",
      "role": "worker",
      "rootDir": "telegram-bot",
      "build": { "install": "auto" },   // requirements.txt in telegram-bot/ → pip + venv
      "run": { "command": ".venv/bin/python bot.py", "env": { "PYTHONUNBUFFERED": "1" } },
      "pythonVersion": "3.12",
      "resources": { "memMax": "256M" }
    }
  ]
}
```

`web` is a Node site built from `website/`: it listens on an automatically assigned port and answers
on `example.com`. `bot` is a python worker from `telegram-bot/`: its own venv, no port, no domain, no
healthcheck path — its health after a restart is the systemd unit status.

### Environment variables: shared and per-service

Resolution order for one service: **the service's own variable (panel) > the project's shared
variable (panel) > `run.env` from the file.** Each service sees the union of the project's shared set
(variables not attached to any service) and its own set; on a key collision the service's own value
wins. `run.env` in the file provides non-secret defaults for keys that are not set in the panel at
all — the file always comes last.

Only build-exposed prefixes reach the build, and they come from the **merged set of that specific
service**: one service's own `PUBLIC_*` variable never leaks into another service's build, even when
both use the same shared project set. See [environment-variables.md](environment-variables.md).

### Routing

- The **primary** service (the first `web` or `static` in the list) gets the platform address
  `<project>.<platform-domain>` and all of the project's domains.
- Other `web` / `static` services are routed **only** through their own `domain`, if one is set —
  they get no platform subdomain by default.
- `worker` services never appear in the Caddy config: there is nothing to proxy and they have no port.

## What happens during a deploy

1. The panel fetches the requested commit into `<baseDir>/src` on the target server.
2. It reads `frostdeploy.json` from the root of that checkout and merges it with the panel settings.
3. It copies the sources into a new directory, `releases/<timestamp>-<sha7>/` — **the live site is
   not touched**.
4. `install` (from the lockfile) and then `build.command` in a shell with `NODE_ENV=production`
   (python builds run without it). Only public build-time variables reach this step — see
   [environment-variables.md](environment-variables.md).
5. It writes the environment file for the service (mode 0600) and links it into the release. This is
   the `EnvironmentFile` of the systemd unit, i.e. the **runtime** environment of a `node` project. A
   `static` project has no unit at all.
6. For `kind=node` it generates a hardened systemd unit from `run.command` (`NoNewPrivileges`,
   `ProtectSystem=strict`; `runtime: "python"` also gets `PYTHONUNBUFFERED=1` so logs are not
   buffered). For `kind=static` it verifies that `output` exists and is not empty. If `assets` is
   declared, it verifies that `assets.root` exists and is not empty, and grants the web server access
   strictly to it.
7. It switches the `current` symlink to the new release — **atomically**.
8. `role: "web"` — restart the unit and run the HTTP healthcheck; `role: "worker"` — restart and check
   the systemd status. **On failure the previous release is restored automatically.**
9. It updates the Caddy config (if the project has a domain), including the `assets` route if
   declared, and prunes old releases (the last 5 are kept).

The port for `role: "web"` is assigned automatically from the server's range — you never specify it,
and your application must listen on `process.env.PORT`. A `role: "worker"` gets no port at all.

### Build caches

Caches survive releases. Package manager caches (npm/pnpm/yarn, pip/uv/poetry) live in
`shared/.cache`, and the framework's own build cache lives in `shared/.cache/framework/<service>` —
after install, the pipeline symlinks it in place for Astro (`node_modules/.astro/assets`, the
optimized-image cache, which is the expensive part of a build), Vite (`node_modules/.vite`), Next.js
(`.next/cache`) and Nuxt (`node_modules/.cache/nuxt`). This is why the first deploy of a site with a
large gallery is slow and the next ones are fast.

The cache is capped at 500 MB per service; when it grows past that it is cleared entirely (the next
build is cold again), and its size is printed in every deploy log. A framework outside that list can
point its own cache at a place that survives releases: the build environment receives
`FD_BUILD_CACHE_DIR`.

## Limits

- Do not put secrets in `run.env` — use the panel, where they are encrypted with AES-256-GCM.
- `rootDir` — no `..`, no leading `/`.
- `build.command` and `run.command` run as the project's own unix user, never as root.
- `assets.root` is readable by every local account on the host (those bytes are public over HTTP
  anyway). Point it at your public static directory, not at the whole `dist/`.
