# The client CMS portal

An optional companion service. It gives the people whose sites you host a place to edit their own
content — without GitHub, without the panel, without you.

## What the client sees

They log in to a portal of their own with an email and a password, and get:

- **their live site in an iframe** — they click a piece of text and edit it in place;
- **a sidebar with forms** — lists, prices, FAQ entries, anything structured, generated from the
  site's own content contract;
- **a Publish button** — the draft is committed to the site's GitHub repository, Freim Deploy rebuilds
  the site automatically, and the change is live a couple of minutes later.

Content lives in Git, in the repository, as it should. The portal is an editor, not a database.

## What it means for you

- The portal is a separate service on its own port with its own database. It is not part of the base
  install: turn it on from the **CMS** tab in the panel, which starts the unit, generates its secrets
  and publishes it at `cms.<your-platform-domain>` through the same mechanism as the panel itself.
- Access is granted per project: you enter the client's email and a **fine-grained GitHub token
  scoped to that one repository with Contents: read and write**. The panel provisions the client,
  encrypts the token and shows the generated password **once**.
- Later you can reset a client's password, revoke their access, restart the service, or switch the
  CMS off entirely (a soft stop — data and secrets are kept).

## Why the client cannot break anything

- They only ever see the portal. Not the panel, not GitHub, not the server.
- The portal commits only to files listed in the site's content contract. The file path never comes
  from the client.
- Every value is validated against the schema before it is committed.
- The GitHub token is fine-grained, limited to that one repository and to content, and stored
  encrypted.
- The key the portal uses against the panel can do exactly two things: "rebuild" and "show status".
- The portal's admin API is bound to loopback and requires a bearer token that the panel generates and
  stores encrypted.

## What the site has to provide

This is the part that requires work on the site itself. The portal is generic; the site tells it what
is editable. Three things are needed:

1. **A content contract** — a JSON file describing the collections (features, reviews, pricing, FAQ…),
   which files hold them, and which fields exist with human-readable labels. Generating it from the
   schemas you already validate content with is the sane approach; then it cannot drift from reality.
2. **Annotations in the markup** — each editable text carries an attribute identifying it as
   `collection:item:field`. This is what makes click-to-edit possible.
3. **An edit overlay** — a small script that is loaded **only** when the site is opened inside the
   portal. Ordinary visitors never receive a byte of it.

For a monorepo the panel also passes the web service's `rootDir` to the portal, so that content paths
resolve inside the subdirectory the site actually lives in.

> **A ready-made starter is not published yet.** The sites this was built for are generated from an
> Astro template that already implements all three pieces. Making a public template out of it is on
> the roadmap; until then, the contract above is what you would implement in your own site.
