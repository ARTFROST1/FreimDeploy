# Adding servers

The panel is not limited to the machine it runs on. One panel manages any number of servers over SSH,
which is the point of the architecture: you keep one place to deploy from, and each client or project
can live on its own machine.

The common pattern is **one server per client**: a compromise of one machine gives nothing on the
others, and the client's hosting bill is theirs.

## Requirements for a target server

Same as for the panel host: **Debian 12+ or Ubuntu 22.04+**, `x86_64`, root access, at least 1 GB of
RAM. No Docker, no pre-installed runtime — the bootstrap script installs what is needed.

## Steps

1. **Add the server in the panel** — Servers → Add Server.
   - `name` — something you will recognize later, lowercase with hyphens.
   - `host` — the server's IP address.
   - The panel generates a **dedicated ed25519 key pair for this server** (the private half is stored
     encrypted in the panel's database) and shows you a bootstrap command.

2. **Bootstrap the server.** Log in as root — this is the only time root access is needed — and run
   the command the panel gave you. It is idempotent: re-running it is safe.

   The script installs Node, Caddy, git, rsync and the package managers, creates the unprivileged
   `frostdeploy` user with the panel's key restricted in `authorized_keys`, writes a narrow sudoers
   allowlist, sets up the firewall to allow only 22/80/443, disables SSH password login, and starts
   Caddy in the mode where its configuration is owned by the panel.

3. **Check the connection** in the panel. The server should go `online` and report its public IP. If
   it stays in `provisioning`, the response lists what is missing.

4. Done — the server can be selected when creating a project.

## What this buys you

- **A compromised panel does not give root on your servers.** The key is restricted to the
  `frostdeploy` user, whose sudo allowlist covers only its own units and helpers.
- **A compromised server gives nothing for the others.** Each server has its own key pair, and
  connections are outbound only: panel → server, never the reverse.
- **Applications do not run as root.** Every site gets its own unix user and a hardened systemd unit.

## Servers that already host something

FrostDeploy manages the Caddy configuration on the servers it controls. If Caddy is already serving
something on that machine, the installer and the bootstrap notice a foreign configuration and do not
silently take it over.

A dedicated server is the calm path. If you must share one, expect to reconcile the web server
configuration by hand, and read [operations.md](operations.md) before you start.

## Hardening

The release ships a hardening script that sets a security baseline on a host: firewall defaults,
fail2ban jails for SSH and the web server, an sshd drop-in, unattended security upgrades, journald
retention and a permissions audit. It ends with a PASS/FAIL verification pass, and it has a dry run:

```bash
bash /opt/frostdeploy/current/scripts/harden-host.sh --dry-run
```

Read the output before running it for real — it changes SSH configuration, and you want to know
exactly what it will do to a machine you reach over SSH.
