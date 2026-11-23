# VulnServer — Ubuntu Hardening & Privilege Escalation Lab v1.0

A reproducible, deliberately vulnerable Ubuntu Server 24.04 laboratory for a
university **server hardening** exercise. One student owns and hardens the
server; a second authorized student attacks it; both document the result.

> **Authorized, isolated use only.** VulnServer creates a SUID root binary, an
> over-broad sudo policy and a root cron job executing a user-writable script.
> Anyone with local access can become root. Run it only on a disposable VM or a
> dedicated lab host that nobody else uses, on a private network.

| | |
|---|---|
| Target OS | Ubuntu Server 24.04 LTS (amd64; arm64 supported) |
| Host footprint | 2 vCPU, 2–4 GB RAM, 20–25 GB disk |
| Web application | OWASP Juice Shop (pinned Docker image) |
| Scenarios | A: file permissions · B: sudo · C: cron |
| Tooling | Bash only (no Python runtime dependency) |
| Validation | 80/80 functional tests PASS in a clean Ubuntu 24.04 container |

## What the exercise looks like

1. The owner deploys the lab (`install.sh`) and shares access with a partner.
2. The partner enumerates the host and the web application.
3. The partner gets a foothold as `labuser`, then reads the **USER flag**.
4. The partner escalates to the intermediate account `labpriv` (Scenario B) and
   reads the **PRIVILEGE flag**.
5. The partner obtains root through any scenario and reads the **ROOT flag**.
6. Both document evidence; the owner applies `harden.sh`.
7. The partner repeats the attempt and proves the paths are closed.

## Quick start

```bash
# On a disposable Ubuntu Server 24.04 VM, on an isolated network:
git clone <this repo> vulnserver && cd vulnserver
sudo ./install.sh --install-deps --activate a,b,c

./lab-manager.sh            # status / scenario control (interactive)
sudo ./audit.sh             # read-only findings report
sudo ./harden.sh --apply    # hardened equivalent, with backups
```

Juice Shop is published on port **3000** by default and restricted by UFW to
`LAB_ALLOWED_NETS`. SSH allows only `adminlab` and `labuser`, never root.

## Repository layout

```
vulnserver/
├── install.sh                 # full installation (idempotent)
├── uninstall.sh               # reverse installation, keeps evidence by default
├── lab-manager.sh             # terminal administration UI
├── audit.sh                   # read-only audit -> reports/audit-<ts>.md
├── harden.sh                  # backup + fix + verify
├── reset-lab.sh               # clean state, rotate flags
├── lib/common.sh              # logging, config, safety helpers
├── config/
│   ├── lab.conf               # all tunables (env-overridable)
│   ├── ssh/99-vulnserver.conf # sshd drop-in
│   ├── ufw/ufw-rules.sh       # isolation firewall
│   └── scenarios/scenarios.conf
├── scripts/
│   ├── users/                 # account creation
│   ├── permissions/           # baseline permission model
│   ├── sudo/                  # baseline sudo policy
│   ├── cron/                  # cron baseline
│   ├── scenarios/             # scenario-a.sh, scenario-b.sh, scenario-c.sh
│   ├── flags/                 # flag generation and verification
│   ├── monitoring/            # auditd rules, activity report
│   └── remote/                # WireGuard access for cloud VMs
├── web/docker-compose.yml     # OWASP Juice Shop
├── tests/                     # container-based functional test suite
├── flags/ logs/ backups/ reports/   # runtime (git-ignored)
└── docs/                      # student, admin, hardening, cloud, instructor
```

## Documentation

| Document | Audience |
|---|---|
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | owner: deploy on VM/host |
| [docs/ADMIN_GUIDE.md](docs/ADMIN_GUIDE.md) | owner: operate, back up, restore |
| [docs/ATTACKER_GUIDE.md](docs/ATTACKER_GUIDE.md) | participant: scope, goals, report template |
| [docs/HARDENING_GUIDE.md](docs/HARDENING_GUIDE.md) | owner: fix each finding, verify |
| [docs/CLOUD_DEPLOYMENT.md](docs/CLOUD_DEPLOYMENT.md) | owner: cloud VM + WireGuard |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | everyone |
| [docs/INSTRUCTOR_SOLUTIONS.md](docs/INSTRUCTOR_SOLUTIONS.md) | instructor only: full solutions |
| [docs/TEST_REPORT.md](docs/TEST_REPORT.md) | instructor: what was actually verified |

## Design guarantees

- **Isolation** — UFW default-deny; SSH and Juice Shop limited to configured
  networks; no Docker API on TCP; no database ports; no admin panel.
- **Reproducibility** — pinned image tag, idempotent scripts, generated flags.
- **Auditability** — JSONL event log, sudo transcript log, auditd rules,
  journald integration; students cannot write to the log directory.
- **Reversibility** — every scenario has `deactivate`; `harden.sh` backs up
  before changing anything; `reset-lab.sh` restores baseline and rotates flags.

## License

MIT, with an additional notice restricting use to authorized isolated
laboratories. See [LICENSE](LICENSE).
