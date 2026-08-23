# AGENTS.md — instructions for AI agents

You are installing **FrostDeploy** (a self-hosted deploy platform) on a server for a human user.
This file is the runbook. Follow it in order. Human-facing overview: [README.md](README.md).

The user may know nothing about servers. Explain each step in one plain sentence before you run it,
and never assume they can debug something you skipped.

---

## 0. Collect these before you start

| You need | Ask the user for it if you do not have it |
| --- | --- |
| Server IP + `root` SSH access | "What is the server IP, and can you SSH into it as root?" |
| A domain they control | "Which domain should this use, and do you have access to its DNS?" |
| GitHub personal access token | Fine-grained, `Contents: Read` on the repos to deploy: https://github.com/settings/personal-access-tokens |
| Admin password (14+ chars) | Have them choose one and save it in a password manager |

**Requirements that are not negotiable:** Debian 12+ or Ubuntu 22.04+, `x86_64`, ≥1 GB RAM, root
access. RHEL-family distributions, Alpine, Arch and arm64 are not supported — if the server is one
of those, stop and tell the user to reinstall it with a supported image.

---

## 1. Preflight

```bash
ssh root@<SERVER-IP> 'cat /etc/os-release | head -2; uname -m; free -m | head -2'
```

Confirm: Debian ≥12 or Ubuntu ≥22.04, `x86_64`, ≥1 GB RAM.

---

## 2. DNS — do this before installing

Two A records must point at the server IP:

```
A   @   →   <SERVER-IP>
A   *   →   <SERVER-IP>
```

The wildcard is required: project addresses are `<project>.<domain>` and are never added to DNS
individually. Tell the user exactly what to create in their DNS provider, then verify yourself:

```bash
dig +short A frostdeploy.<DOMAIN> @1.1.1.1
dig +short A random-check-name.<DOMAIN> @1.1.1.1
```

Both must return the server IP. If they do not, wait and retry — propagation can take from a few
minutes to a few hours. **Do not install before DNS resolves**; the certificate step will fail and
the user will think the install broke.

---

## 3. Install

```bash
ssh root@<SERVER-IP> 'curl -fsSL https://raw.githubusercontent.com/ARTFROST1/FrostDeploy/main/install.sh | sudo bash'
```

Takes 2–5 minutes. Success looks like:

- a line containing `подпись релиза проверена (ed25519)` — the release signature was verified;
- a final banner saying FrostDeploy is ready.

If the run reports that the signature does **not** verify, stop. Do not retry with any flag, do not
work around it — report it to the user and point them at
https://github.com/ARTFROST1/FrostDeploy/security/advisories/new

---

## 4. First login — the tunnel

The panel listens on `127.0.0.1:9000` and is not reachable from the internet. The first login goes
through an SSH tunnel.

**The tunnel command runs on the user's own machine, not on the server.** If you are operating
from the user's laptop, run it yourself in a background shell:

```bash
ssh -L 9000:127.0.0.1:9000 root@<SERVER-IP>
```

If you are working from somewhere else, give the user the command verbatim and tell them to keep
that terminal window open.

Then have them open **http://127.0.0.1:9000**.

Never suggest opening port 9000 in the firewall as a shortcut. The panel controls every managed
server; exposing it is the one mistake that matters.

---

## 5. Setup wizard

Walk the user through the form:

| Field | Value |
| --- | --- |
| Admin password | 14+ characters, saved in their password manager |
| GitHub token | the fine-grained PAT from step 0 |
| Platform domain | the apex only — `example.com`, not `https://` and not a subdomain |

After submitting, the panel becomes available at `https://frostdeploy.<DOMAIN>`. Certificate
issuance takes up to a minute. Once it works, the tunnel can be closed.

---

## 6. Hand-off — tell the user, verbatim

1. The panel is at `https://frostdeploy.<DOMAIN>`.
2. Two things must be saved in a password manager: the admin password, and the `ENCRYPTION_KEY`
   value from `/opt/frostdeploy/.env` on the server. Without that key a backup cannot be restored.
   Retrieve it for them: `ssh root@<SERVER-IP> 'grep ENCRYPTION_KEY /opt/frostdeploy/.env'` — show
   it to the user, and do not write it into any file, log, commit or chat transcript that persists.
3. To deploy a site: open the panel → add a project → choose the repository → press Deploy.

If the user asks you to prepare a repository for deployment, read
[docs/frostdeploy-json.md](docs/frostdeploy-json.md) and write the config file from it — do not guess
field names. The two rules that break most first deploys: a server-side app must listen on
`process.env.PORT`, and a value needed during the build must carry a public prefix
(see [docs/environment-variables.md](docs/environment-variables.md)).

---

## 7. If something fails

| Symptom | What to do |
| --- | --- |
| `Unsupported OS` | Wrong distribution. The server must be reinstalled — nothing else will help |
| `Unable to locate package jq` | apt cannot reach its mirrors. Check DNS and outbound network on the server |
| Signature verification failed | Stop. Do not retry, do not bypass. Report it (see step 3) |
| Panel not reachable in the browser | The tunnel is running on the wrong machine, or the service is down: `ssh root@<SERVER-IP> 'frostdeploy status'` |
| Domain has no certificate | DNS is not fully propagated, or ports 80/443 are blocked by the provider's firewall |
| Service broken after an update | `ssh root@<SERVER-IP> 'frostdeploy rollback'` |
| Everything else | `ssh root@<SERVER-IP> 'journalctl -u frostdeploy -n 100 --no-pager'` and read the actual error |

---

## 8. Server-side commands

| Command | Purpose |
| --- | --- |
| `frostdeploy status` | Is the panel running |
| `frostdeploy logs` | Follow panel logs |
| `frostdeploy restart` | Restart the panel |
| `frostdeploy update` | Update to the latest release; rolls back automatically on failure |
| `frostdeploy rollback` | Return to the previous release |
| `frostdeploy reset-password` | Set a new admin password |
| `frostdeploy uninstall [--purge]` | Remove FrostDeploy; `--purge` also deletes data and sites |

Re-running `install.sh` on an existing install is equivalent to `frostdeploy update`: it preserves
the database and configuration.

---

## Rules

- Do not open port 9000 in the firewall, ever.
- Do not bypass a failed signature check.
- Do not store the GitHub token, the admin password or `ENCRYPTION_KEY` in files, commits or
  anywhere that outlives the conversation.
- Do not install before DNS resolves — including the wildcard.
- Do not invent flags or configuration files. The installer takes no arguments; everything else is
  configured in the panel UI.
