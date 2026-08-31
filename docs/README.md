# Documentation

Everything you need to run Freim Deploy without access to its source code.

> The product was renamed from FrostDeploy to Freim Deploy. Nothing on the server was renamed:
> the paths, the `frostdeploy` command and the `frostdeploy.json` file in your repository keep
> their old names on purpose, so existing installs keep working.

| Document | What is in it |
|---|---|
| [first-deploy.md](first-deploy.md) | From a fresh install to your first site live on HTTPS |
| [frostdeploy-json.md](frostdeploy-json.md) | **The configuration reference.** How to describe a project: build, start command, static output, monorepos, python workers, several services in one repository |
| [environment-variables.md](environment-variables.md) | Build time versus runtime, which variables reach the build and why secrets do not |
| [domains.md](domains.md) | Platform addresses, custom domains, the wildcard record, certificates, `www`, redirects |
| [servers.md](servers.md) | Adding more servers to one panel, and what the bootstrap does |
| [operations.md](operations.md) | Updates, rollbacks, a site that is down, backups, secrets, uninstalling |
| [cms-portal.md](cms-portal.md) | The optional portal where clients edit their own content |

New here? Read [first-deploy.md](first-deploy.md), then keep
[frostdeploy-json.md](frostdeploy-json.md) open while you write your first config.

Installing? The [quick start](../README.md#-quick-start) is in the main README, and
[AGENTS.md](../AGENTS.md) is a step-by-step runbook an AI agent can follow to do the whole setup with
you.

Need something to deploy? [FreimSite](https://github.com/ARTFROST1/FreimSite) is the platform's
official site template — Astro 7, SEO-ready, carrying the CMS markup [cms-portal.md](cms-portal.md)
edits. Click **Use this template** on its page to start a new site from it.

Prefer a browsable page over raw files? [This same index, plus how Freim Deploy and FreimSite fit
together, is also published as a page.](https://artfrost1.github.io/FreimDeploy/)
