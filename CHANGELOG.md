# Changelog

All published builds live under [Releases](https://github.com/ARTFROST1/FrostDeploy/releases).
Each release carries three assets: the `linux-x64` tarball, its `ed25519` signature (`.sig`) and a
`.sha256` checksum. A release without a valid signature cannot be installed — the installer and
`frostdeploy update` both refuse it.

## Versioning

```
v<major>.<minor>.<patch>[-rc.<n>]      e.g. v0.2.0-rc.59
```

The `0.2.0-rc.*` line is the current, actively deployed series: release candidates are cut
continuously and are what production installs run. `frostdeploy update` always follows the latest
published release, so upgrading between `rc` builds is the normal path — it is atomic and rolls
back automatically if the post-restart healthcheck fails.

Development happens in a private repository; this file summarizes what reaches the distribution
channel. Fixes that never shipped a release are not listed.

---

## 0.2.0-rc series

### Recent releases

| Version | Date | What changed |
| --- | --- | --- |
| [`rc.59`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.59) | 2026-08-13 | Dependency cache shared between releases, deploy timing instrumentation, shared settle window — noticeably faster deploys |
| [`rc.58`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.58) | 2026-08-13 | Documentation graph shipped with the release tree |
| [`rc.57`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.57) | 2026-08-13 | Caddy serves an SSR project's static output straight off disk with real `Cache-Control` headers |
| [`rc.56`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.56) | 2026-08-12 | Healthcheck settle window raised to 10s — import-time crashes no longer slip through as "healthy" |
| [`rc.55`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.55) | 2026-08-12 | Rollback verifies that restarted units actually came up |
| [`rc.54`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.54) | 2026-08-12 | Web processes pinned to IPv4 bind; rollback stops services missing from the restored release |
| [`rc.53`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.53) | 2026-08-12 | Environment-variable changes trigger a rebuild, with an "unapplied changes" banner in the panel |
| [`rc.52`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.52) | 2026-08-11 | Cancellable deploys; faster, config-aware framework detection |
| [`rc.51`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.51) | 2026-08-10 | Framework build cache |
| [`rc.50`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.50) | 2026-08-09 | mTLS certificate reissue fixes |
| [`rc.48`](https://github.com/ARTFROST1/FrostDeploy/releases/tag/v0.2.0-rc.48) | 2026-08-08 | Auth fixes: a wrong password no longer ends the session; password whitespace handling; OTP input |

Older releases: [full list](https://github.com/ARTFROST1/FrostDeploy/releases?page=2).

### Highlights of the series so far

- **Supply chain.** Every tarball is signed with ed25519 in a CI job that runs no third-party code;
  the public key is embedded in `install.sh` and in the `frostdeploy` CLI, and the signature is
  verified before extraction. Publishing credentials and the signing key are held in separate jobs.
- **Deploy pipeline.** Atomic release directories with symlink switching, healthcheck-gated
  promotion, automatic rollback, cancellable builds, dependency and build caching, live SSE logs.
- **Access control.** Panel bound to loopback only, TOTP two-factor authentication, optional mTLS
  client-certificate gate, per-site unix users, narrow sudoers allowlist for privileged operations.
- **Domains.** Platform subdomains plus custom domains, DNS / certificate / HTTPS state surfaced in
  the UI, automatic HTTPS through Caddy.
- **Operations.** `harden-host.sh` baseline (ufw, fail2ban, sshd drop-in, unattended-upgrades,
  journald retention, permission audit) with `--dry-run` and a PASS/FAIL verification gate;
  scheduled database backups, local or S3-compatible; secret re-encryption for key rotation.
- **Client CMS portal.** Optional companion service that lets site owners edit their own content.

---

## 0.1.0

Initial internal line: panel, deploy engine for Node and static projects, Caddy proxying,
authentication, monitoring. Superseded by the `0.2.0-rc` series.
