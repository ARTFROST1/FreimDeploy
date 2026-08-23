# Domains and HTTPS

A project answers on **two kinds of address**, and they coexist — one never replaces the other.

## The platform address

`<project-name>.<your-platform-domain>`, for example `shop.example.com`.

It is **derived, never stored**: it is computed from the project name and your platform domain every
time it is needed. Nothing writes it into the database, so it cannot drift, cannot be edited into
something broken, and cannot be lost. A site keeps a working address no matter what happens to its
custom domains — the same guarantee a `*.vercel.app` address gives you.

It cannot be edited directly. The project name is what defines it.

### This is why the wildcard DNS record is required

```
A   *   →   <server IP>
```

Vercel can hand out `*.vercel.app` because it owns that zone; FrostDeploy depends on you adding one
wildcard record for your platform domain. One record covers every project you will ever create.
Without it the platform address resolves nowhere.

The panel checks whether the platform address actually resolves and says so plainly — a silent
failure here is otherwise almost impossible to diagnose from inside the panel.

### The platform namespace is not for custom domains

**`*.<platform-domain>` cannot be attached as a custom domain** — not "is taken", but cannot, even
when the name is free. In this zone an address is *derived*, not *attached*: a name belongs to
whichever project is called that. Allowing it to also be attached would give one host two sources of
truth, and the next project created with a matching name would silently take the address away.

Two deliberate exceptions:

- **The apex itself stays free.** The setup wizard puts the panel on `frostdeploy.<apex>` precisely so
  that the apex remains available for your own landing page — attaching it to a project is normal.
- **`www.<X>` when `X` is already a domain of the same project.**

## Custom domains

Any number of domains can be attached to a project. The first one is the primary. Adding a domain
adds a route — it does not move the existing ones, so the project keeps answering everywhere it did
before.

### Is the domain ready? Three states, not one

"DNS verified" is a true sentence that reads as "done" — and then the site is not there yet, because
the certificate is issued *after* the name starts pointing at the server. So readiness is reported as
three separate states, and only all three green means ready:

| State | How it is measured | `pending` vs `failed` |
|---|---|---|
| **DNS** | the A record via public resolvers (1.1.1.1, 8.8.8.8), compared with the server IP | no record → pending; points elsewhere → failed |
| **Certificate** | a real TLS handshake to the name, chain verified | not issued yet → pending (automatic, just not instant) |
| **HTTPS** | a real request; redirects are not followed | 5xx → failed (the site is there and broken) |

They are measured against the name, not read out of the panel's own configuration: the config says
what the platform *intends* to serve and says nothing about whether a certificate exists or a process
is alive behind it.

The last two are skipped while DNS is not ok — the name points somewhere else and someone else
answers on it, so claiming anything about "our" certificate would be misleading.

Public resolvers are used deliberately: a panel host's own DNS cache once accused an owner of broken
DNS while every authoritative server already returned the right address.

### Certificates and rate limits

Certificates are issued and renewed automatically by Caddy through Let's Encrypt. The route is added
when you save the domain, but the certificate is only requested when a working DNS record is seen —
so adding a domain early does not burn Let's Encrypt rate limits.

## `www`

Every apex gets a `www.<apex>` route, and the rule is always the same: **`www` ends up wherever the
apex points.**

| The apex | `www.<apex>` |
|---|---|
| serves the site | `307 → <apex>` |
| redirects to `T` | same status → `T`, in one hop — not `www → apex → T` |

## Redirects

Any custom domain can redirect to another address of the same project instead of serving it. Path and
query are preserved. The status is yours to choose — 308/301 permanent, 307/302 temporary — and the
default is **307, temporary**.

The default is temporary on purpose. A permanent redirect is cached by the browser, which then
follows the remembered path without asking the server at all; setting one up by mistake makes the
change quietly irreversible for anyone who already visited. Switch to 308 once the setup is final —
that is what search engines want to see for a canonical address.

This is what a classic `example.com` + `www.example.com` pair needs: both attached, one redirecting to
the other, so search engines see one canonical address rather than two hosts serving identical
content.

## The Domain tab

A domain is one line: the name, one state badge, a check button and a disclosure. The badge names the
**first** unfinished state in the order DNS → certificate → HTTPS, because that order is causal: a
certificate cannot be issued while the name points elsewhere, so naming the last red state would name
a consequence rather than the cause.

Details — the three states in full, redirect controls, the records table, the `www` block, detaching —
open on request, and open by themselves when something needs attention.
