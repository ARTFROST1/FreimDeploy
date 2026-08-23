# Operating your install

Everything here is day-two work: what to press when something breaks, how to update, and what has to
be configured before you can honestly say the data is safe.

## The command line

The installer puts `frostdeploy` in `/usr/local/bin` on the panel host.

| Command | What it does |
|---|---|
| `frostdeploy status` | Is the panel running |
| `frostdeploy logs` | Follow the panel log |
| `frostdeploy restart` | Restart the panel (and the CMS portal, if installed) |
| `frostdeploy update` | Update to the latest release — rolls back by itself if the healthcheck fails |
| `frostdeploy rollback` | Return to the previous release |
| `frostdeploy reset-password` | Set a new admin password if you are locked out |
| `frostdeploy reencrypt` | Re-encrypt stored secrets under the current `ENCRYPTION_KEY` |
| `frostdeploy uninstall` | Remove FrostDeploy (`--purge` also deletes data and sites) |

## Updating

```bash
frostdeploy update
```

The new release is downloaded, its signature verified before it is unpacked, `current` is switched
and the service restarted. If the healthcheck fails afterwards, the previous release is restored
automatically — an update cannot leave you with a dead panel.

Re-running `install.sh` does the same thing. Your database, `.env` and deployed sites are untouched.

## A site is down

1. **Look at the panel first.** The project page shows the unit status and the last deploy; the log
   tab usually names the cause on the first screen.
2. **Roll back from the panel** — one click on any previous release. This is the fastest fix and it
   is almost always the right first move: get the site up, investigate afterwards.
3. **If the panel itself is unreachable**, everything is still plain systemd and symlinks on the
   server:

```bash
systemctl status fd-<project>          # what the unit thinks
journalctl -u fd-<project> -n 100      # why it died
ls -l /srv/frostdeploy/<project>/current   # which release is active
ls /srv/frostdeploy/<project>/releases/    # what else is there

# manual rollback = point the symlink at the previous release and restart
ln -sfn /srv/frostdeploy/<project>/releases/<previous> /srv/frostdeploy/<project>/current
systemctl restart fd-<project>
```

For routing or certificate problems, `journalctl -u caddy -f` shows the actual error, including
anything Let's Encrypt refused.

Common causes, in the order they actually occur: the app does not listen on `process.env.PORT`; a
missing environment variable; a build that ran out of memory; DNS that has not propagated; a domain
whose A record points somewhere else.

## Backups

Backups are two independent arms, so that losing one still leaves you a way back.

**On each server** an agent runs on a systemd timer once a night. It takes the lock shared with the
deploy pipeline (so a backup and a deploy never trample each other), snapshots site databases
properly instead of copying live files byte by byte, and uploads everything to a restic repository in
any S3-compatible storage. Two layers are kept apart: the *platform* layer (the panel database, its
environment file, certificates — only on the panel host) and the *sites* layer (the persistent data
of every project, on every server).

**Separately, the panel keeps an offline copy of itself**: once a day, and on every start, it writes
an encrypted archive of its database and environment into a second bucket. It restores **without
restic, without the panel and without the internet** — one command. This is what you rebuild from
when there is nothing left.

The important consequence: **the real backup is taken by a timer on the server, not by the panel.**
The panel can be down for a day and backups still happen. What the panel does is watch and
orchestrate — collect agent reports, cover a layer that has no fresh success, run a restore drill,
verify the repository, prune by policy, and send an alert or a heartbeat.

### What you must configure

1. **Enable the agent on every server.** Servers → the server card → enable backups. Without it, that
   server is not backed up at all.
2. **Set up alerting** — a dead-man's-switch URL and/or a webhook. **Without it a failure is silent.**
   Send a test message afterwards and confirm it arrives.
3. **Generate the owner key offline and seal the repository passwords.** This is the insurance against
   losing `ENCRYPTION_KEY`: without it, repository passwords are unrecoverable and your snapshots
   become encrypted bricks.
4. **Keep three secrets in a password manager, outside the servers:** `ENCRYPTION_KEY`, the offline
   copy's passphrase, and the owner private key.
5. **Turn on versioning and lifecycle rules on the buckets**, so that an attacker with your
   credentials cannot simply delete the history.

### Restoring

Restore from the panel: pick a snapshot, a project, a sub-path — and **always run the dry run first**.
It is synchronous and creates no job. The "created / overwritten" counts must match what you expect;
if they do not, do not restore, investigate. That check has caught real mistakes.

## Secrets worth writing down today

- **`ENCRYPTION_KEY`** from `/opt/frostdeploy/.env` — it decrypts every secret in the panel database:
  the GitHub token, server SSH keys, project environment variables. A database backup without this
  key is worthless.
- **The admin password.**
- **The backup passphrase and owner key**, if you have configured backups.

To rotate `ENCRYPTION_KEY`: put the new key in `ENCRYPTION_KEY`, the old one in `ENCRYPTION_KEY_OLD`,
run `frostdeploy reencrypt`, then remove `ENCRYPTION_KEY_OLD`. It is safe to interrupt and re-run.

## Uninstalling

```bash
frostdeploy uninstall           # remove the program, keep data and secrets
frostdeploy uninstall --purge   # remove everything: databases, /srv, project users, .env
```

Both print exactly what they will delete and ask for confirmation unless `--yes` is passed. Without
`--purge`, reinstalling later picks up where you left off.
