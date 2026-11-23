# Administrator guide

For the **owner** of the VulnServer instance (the `adminlab` account). The
attacker receives [ATTACKER_GUIDE.md](ATTACKER_GUIDE.md) instead.

## 1. Mental model

- `/opt/vulnserver` is the runtime state: flags, logs, backups, reports, lab data
  and the installed copy of the toolchain (`/opt/vulnserver/bin`).
- The git checkout is the source of truth for scripts and configuration.
- Scenarios are independent switches stored in `/opt/vulnserver/state/scenario-*.state`.
- `adminlab` never participates in the exercise; it is your recovery path.

## 2. Terminal interface

```bash
sudo /opt/vulnserver/bin/lab-manager.sh      # menu
```

| Option | Action |
|---|---|
| 1 | Status: container, SSH, firewall, auditd, scenarios, ports, flags |
| 2 | Install dependencies / re-run installer |
| 3 / 4 | Start / stop services |
| 5 / 6 | Activate / deactivate a scenario (or all) |
| 7 | Read-only audit |
| 8 | Hardening |
| 9 | Activity report |
| 10 | Reset laboratory |
| 11 | Documentation |
| 12 | Exit |

Non-interactive equivalents: `status`, `start`, `stop`, `activate a`,
`deactivate all`, `audit`, `harden`, `report`, `reset`, `docs`, `logs`, `ports`.

## 3. Accounts

| Account | Purpose | Groups | Password |
|---|---|---|---|
| `adminlab` | owner, full administration | `sudo` | from `config/lab.conf` (change it) |
| `labuser` | participant entry point | own group only | shared with participant |
| `labpriv` | intermediate level, Scenario B | own group only | locked; not login-able |

```bash
sudo ./scripts/users/create_users.sh status
sudo passwd adminlab                      # rotate the owner password
sudo ./scripts/users/create_users.sh remove   # removes lab accounts, keeps adminlab
```

Rules:

- never add `labuser` to `sudo`, `adm` or `docker`;
- never enable root SSH login;
- rotate `labuser` password between groups (`sudo passwd labuser`) and tell the
  new participant.

## 4. Scenario control

```bash
sudo ./scripts/scenarios/scenario-a.sh activate|deactivate|status|verify
sudo ./scripts/scenarios/scenario-b.sh activate|deactivate|status|verify
sudo ./scripts/scenarios/scenario-c.sh activate|deactivate|status|verify
```

Behaviour of each command:

- `activate` creates a **restore point** in `/opt/vulnserver/backups/restore-<id>-<ts>/`
  containing a `restore.sh` and a manifest (who, when, host), then applies the
  vulnerable configuration.
- `deactivate` restores the secure baseline for that scenario.
- `verify` exits 0 only if the vulnerability is present (automated check).
- Every action is logged to `events.log`.

Independent activation is supported: A only, B only, C only, or any combination.

## 5. Flags

```bash
sudo ./scripts/flags/generate_flags.sh generate --force   # rotate all three
sudo ./scripts/flags/generate_flags.sh verify             # owner/group/mode check
sudo ./scripts/flags/generate_flags.sh show               # print values (admin only)
```

| File | Owner | Mode | Reachable by |
|---|---|---|---|
| `flags/user.txt` | `labuser:labuser` | `600` | labuser |
| `flags/privilege.txt` | `root:labpriv` | `640` | labpriv, root |
| `flags/root.txt` | `root:root` | `400` | root |

Expected sequence for grading: user flag with initial access, privilege flag
after reaching `labpriv`, root flag at root. Any root session can read all three,
so grade the *order and evidence*, not just the strings.

Record the values somewhere outside the VM if you need to verify a submission;
`reset-lab.sh` rotates them.

## 6. Services

```bash
sudo ./lab-manager.sh status
cd /opt/vulnserver/web && sudo docker compose ps
sudo docker compose -f /opt/vulnserver/web/docker-compose.yml logs --tail 50
sudo ./lab-manager.sh start|stop
```

SSH: `systemctl status ssh`, config drop-in `/etc/ssh/sshd_config.d/99-vulnserver.conf`.

## 7. Logs and monitoring

| Source | Location |
|---|---|
| Lab events (JSONL one object per line) | `/opt/vulnserver/logs/events.log` |
| Human-readable lab log | `/opt/vulnserver/logs/vulnserver.log` |
| Sudo transcript (input/output) | `/var/log/sudo-vulnserver.log` |
| SSH / auth | `journalctl -u ssh`, `/var/log/auth.log` |
| Cron | `journalctl -u cron`, `/var/log/syslog` |
| auditd | `ausearch -k vulnserver_flags`, `aureport` |
| Docker | `docker logs vulnserver-juice-shop` |
| Installed rule set | `/etc/audit/rules.d/vulnserver.rules` |

The log directory is `root:root 0750`, so `labuser` cannot read or modify it.
`events.log` records: timestamp, host, actor (real invoking user), event,
service, scenario, result, detail.

Generate a report:

```bash
sudo ./lab-manager.sh report          # or: sudo ./scripts/monitoring/report.sh --days 7
```

Output goes to `/opt/vulnserver/reports/lab-report-<ts>.md`. Flag values are
never written into reports.

## 8. Audit and hardening cycle

```bash
sudo ./audit.sh                       # read-only, writes reports/audit-<ts>.md
sudo ./audit.sh --only sudo,cron,suid # focused
sudo ./harden.sh                      # interactive: analyse, confirm, fix
sudo ./harden.sh --apply --yes        # non-interactive
sudo ./harden.sh --restore /opt/vulnserver/backups/files-<ts>
```

Recommended workflow for the exercise:

1. Audit before the attack; keep the report as the "before" evidence.
2. Run the attack; collect the student report.
3. `harden.sh --apply` (or let the owner do it manually following
   [HARDENING_GUIDE.md](HARDENING_GUIDE.md)).
4. Audit again; the "after" report must show the findings resolved.
5. `reset-lab.sh` before the next group.

Before disabling SSH password authentication, make sure `authorized_keys` are
distributed: `harden.sh` asks for confirmation for exactly this reason.

## 9. Backups and restore

| Directory | Contents | Retention |
|---|---|---|
| `backups/files-<ts>/` | files replaced by `harden.sh` + `index.txt` | keep per group |
| `backups/restore-<id>-<ts>/` | automatic restore point per activation | keep per group |
| `backups/logs-<ts>.tar.gz` | archived logs from `reset-lab.sh` | keep as evidence |

```bash
sudo tar -czf /root/vulnserver-backup-$(date +%F).tar.gz -C /opt vulnserver
```

Hypervisor snapshots are the most reliable rollback; take one after a clean
install and one after hardening.

Restore a hardening backup:

```bash
sudo ./harden.sh --restore /opt/vulnserver/backups/files-20261123-101500
sudo ./audit.sh --stdout | head -30
```

## 10. Remote access

Preferred: WireGuard tunnel, then SSH/HTTP only over the tunnel.

```bash
sudo apt install -y wireguard
sudo ./config/ufw/ufw-rules.sh apply
# Then restrict SSH to the tunnel network only:
#   SSH_ALLOWED_NETS="10.8.0.0/24" sudo ./install.sh --no-docker --no-auditd
```

See [CLOUD_DEPLOYMENT.md](CLOUD_DEPLOYMENT.md) for a complete WireGuard
configuration and for the cloud firewall rules.

## 11. Between groups

```bash
sudo ./reset-lab.sh --yes        # deactivate, clean practice data, rotate flags
sudo ./audit.sh                  # confirm baseline
```

`reset-lab.sh` never deletes `backups/`.

## 12. Decommission

```bash
sudo ./uninstall.sh            # keeps state for evidence
sudo ./uninstall.sh --purge    # removes /opt/vulnserver
# finally delete the VM
```

## 13. Operator checklist

Before handing the lab over:

- [ ] VM on an isolated/NAT network, snapshot taken
- [ ] `adminlab` password rotated, keys installed, not shared
- [ ] `labuser` password shared only with the participant
- [ ] scenarios activated as intended (`lab-manager.sh status`)
- [ ] Juice Shop reachable from the participant network only
- [ ] UFW active, no database/admin ports listening
- [ ] auditd active, `events.log` writable by root only
- [ ] instructor copy of the flags stored outside the VM
- [ ] participant received only `ATTACKER_GUIDE.md`
