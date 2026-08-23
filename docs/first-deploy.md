# Your first site

This is the path from a freshly installed panel to a live site on HTTPS. It assumes you have already
run the installer and finished the setup wizard — if not, start with the
[quick start](../README.md#-quick-start).

## 1. Prepare the repository

Add a `frostdeploy.json` to the root of your repository. The minimum for a static site built by npm:

```json
{ "kind": "static", "build": { "command": "npm run build", "output": "dist" } }
```

For a server-side project the start command is required, and your application **must listen on
`process.env.PORT`** — the port is assigned by the platform, not chosen by you:

```json
{
  "kind": "node",
  "build": { "command": "npm run build" },
  "run": { "command": "node dist/server/entry.mjs", "healthcheckPath": "/" }
}
```

The file is optional — without it the panel falls back to autodetection and to whatever you fill in
the wizard. It is still worth adding: settings in the file are versioned with your code, so rolling
back to an older commit also rolls back how it is built. The full reference is
[frostdeploy-json.md](frostdeploy-json.md).

## 2. Create the project

In the panel: **New Project**.

- **Repository** — the GitHub URL and the branch to deploy. Private repositories work; that is what
  the token from the setup wizard is for.
- **Server** — which server this site runs on. On a fresh install there is one: the panel's own host.
  To deploy onto other machines, see [servers.md](servers.md).
- **Framework** — detection fills this in, and `kind` follows from it. If the repository has a
  `frostdeploy.json`, its fields are pre-filled and marked as coming from the file.
- **Environment variables** — add them now if the build needs them. Read
  [environment-variables.md](environment-variables.md) first if the site needs anything at build
  time; it is the one part of this that surprises people.

If the repository contains several independent processes (a site and a bot, an API and a worker), the
wizard detects them and shows an extra step where you confirm the list. See "Multiservice" in
[frostdeploy-json.md](frostdeploy-json.md#multiservice-services).

## 3. Deploy

Press **Deploy** and watch the log stream. The pipeline creates the whole directory structure on the
server itself:

```
/srv/frostdeploy/<project>/
├── src/                  the git checkout
├── releases/             one directory per deploy, last 5 kept
├── current →             symlink to the active release
└── shared/               env file, caches, persistent data
```

The first build of a large site is slow — caches are cold. The next ones are much faster: package
manager and framework caches survive releases.

If the healthcheck fails after the restart, the previous release is restored automatically and the
site stays up. A failed deploy never takes a working site down.

At this point the site is already reachable at `<project>.<your-platform-domain>` — that address is
derived from the project name and works because of the wildcard DNS record you created during
installation.

## 4. Attach a domain

Project → **Domain** → enter the domain.

The route is added to the web server **immediately when you save** — a domain whose DNS is already
correct should not have to wait for a button. The panel then shows you the A record to create.

Point the DNS at the server, and the certificate is issued automatically as soon as the name starts
resolving here. The panel reports three separate states — DNS, certificate, HTTPS — and only all
three green means the domain is actually ready. Details, including `www` handling and redirects, are
in [domains.md](domains.md).

## 5. Verify

- The site opens over HTTPS on your domain.
- The project status in the panel is `active`.
- For a `node` project, the logs tab shows your process starting.

## Common first-deploy problems

| Symptom | Cause |
|---|---|
| `Build output missing` | `build.output` does not match the directory your build actually produces |
| Healthcheck failed (node) | The app does not listen on `process.env.PORT`, or does not answer on `healthcheckPath` |
| `npm ci` failed | No lockfile in the repository — set `build.install` explicitly, or commit the lockfile |
| The site builds but a value is empty | A build-time variable without a public prefix — see [environment-variables.md](environment-variables.md) |
| The domain does not open | DNS has not propagated yet, or the A record does not point at this server |
| Python install fails | `python3-venv` / `python3-pip` missing on a manually prepared server |
