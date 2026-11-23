# Hardening guide

Every finding produced by `audit.sh`, with the correction and the verification
step. `harden.sh` automates most of these; this document is for the owner who
prefers to apply changes by hand, and for the report the owner submits.

General rule: **back up before changing, verify after changing.**

```bash
sudo cp -a /etc/ssh/sshd_config.d/99-vulnserver.conf /root/backup-sshd.conf
sudo sshd -t && sudo systemctl reload ssh
```

## 1. SSH

**Risk** — password authentication against a lab account is the initial access
path; root login expands the blast radius.

Fix `/etc/ssh/sshd_config.d/99-vulnserver.conf`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers adminlab labuser
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no
```

Before disabling passwords, install keys:

```bash
ssh-keygen -t ed25519 -C "lab-owner"
ssh-copy-id -i ~/.ssh/id_ed25519.pub adminlab@<host>
ssh -o PasswordAuthentication=no adminlab@<host> true   # prove it works
```

Verify: `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers'`
and `sudo audit.sh --only ssh`.

Rollback: restore the backup, `sshd -t`, reload. Keep a hypervisor console open
while doing this.

## 2. Users and groups

**Risk** — an administrative group membership turns the unprivileged account
into root (sudo, docker, adm can all read sensitive files; docker is
root-equivalent).

```bash
sudo gpasswd -d labuser sudo
sudo gpasswd -d labuser adm
sudo gpasswd -d labuser docker
sudo passwd -l labpriv                       # intermediate account must not log in
sudo awk -F: '$3==0 {print $1}' /etc/passwd  # only root
sudo awk -F: '$2=="" {print $1}' /etc/shadow # nothing
```

Verify: `id labuser` (only its own group), `passwd -S labpriv` (`L`).

## 3. File permissions

**Risk** — a SUID root binary is a direct root shell; a world-writable directory
executed by root is equivalent to root access.

```bash
# Unexpected SUID/SGID binaries
sudo find /usr /bin /sbin /opt -xdev -type f \( -perm -4000 -o -perm -2000 \) -ls
sudo chmod u-s /usr/bin/find          # Scenario A
sudo chmod g-s <file>

# World-writable directories
sudo find / -xdev -type d -perm -0002 ! -path '/tmp/*' ! -path '/var/tmp/*' -ls
sudo chmod o-w <dir> ; sudo chmod 0755 /opt/vulnserver/lab/perms /opt/vulnserver/lab/cron

# State directory baseline
sudo chown root:root /opt/vulnserver /opt/vulnserver/logs
sudo chmod 0750 /opt/vulnserver/logs
sudo chmod 0700 /opt/vulnserver/backups
sudo chown root:root /opt/vulnserver/flags/root.txt && sudo chmod 0400 /opt/vulnserver/flags/root.txt
sudo chown root:labpriv /opt/vulnserver/flags/privilege.txt && sudo chmod 0640 /opt/vulnserver/flags/privilege.txt
```

Verify with `sudo ./scripts/flags/generate_flags.sh verify` and
`sudo audit.sh --only permissions,suid`.

Note: `/tmp` is world-writable by design; the sticky bit (`1777`) prevents
deleting other users' files. Check it: `stat -c '%a' /tmp` → `1777`.

## 4. sudo

**Risk** — `NOPASSWD` delegation to a utility that can execute commands (`tar`,
`find`, `less`, `vim`, `python`) gives a shell as the delegated user; a
root-executed helper writable by that user gives root.

Inspect:

```bash
sudo visudo -c
sudo grep -rE 'NOPASSWD|ALL' /etc/sudoers /etc/sudoers.d/
sudo -l -U labuser
```

Fix:

```bash
sudo rm -f /etc/sudoers.d/vulnserver-lab-b      # Scenario B
sudo chown root:root /usr/local/bin/lab-healthcheck
sudo chmod 0755 /usr/local/bin/lab-healthcheck
sudo visudo -c
```

Principles:

- never delegate a command that can spawn a shell or write a file;
- if a helper script must run as root, it must be `root:root 0755` and must not
  read configuration from a user-writable location;
- prefer `sudo -u serviceuser` with an explicit command allow-list over `ALL`;
- keep `Defaults use_pty` and logging enabled.

Verify: `sudo -l -U labuser` shows no root command; `sudo audit.sh --only sudo`.

## 5. SUID/SGID inventory

Keep a baseline and diff against it:

```bash
sudo find / -xdev -type f -perm -4000 2>/dev/null | sort > /root/suid-baseline.txt
# later
sudo find / -xdev -type f -perm -4000 2>/dev/null | sort | diff /root/suid-baseline.txt -
```

Remove the bit from anything unexplained (`chmod u-s`), then decide whether the
package is needed at all.

## 6. cron

**Risk** — a root job that executes a script from a user-writable path is root
code execution for any local user, on a schedule.

```bash
ls -la /etc/cron.d /etc/cron.hourly /etc/cron.daily
sudo stat -c '%A %U:%G %n' /etc/cron.d/*
sudo rm -f /etc/cron.d/vulnserver-lab-c      # Scenario C
sudo chmod 0755 /opt/vulnserver/lab/cron
sudo chown root:root /opt/vulnserver/lab/cron/lab-cleanup.sh
sudo chmod 0755 /opt/vulnserver/lab/cron/lab-cleanup.sh
```

Rules: cron scripts and every directory in their path must be root-owned and not
writable by others; never source a config file from a user directory; prefer
systemd timers with `User=` and explicit paths if you rebuild the lab.

Verify: `sudo ./scripts/scenarios/scenario-c.sh verify` must fail after
hardening (the vulnerability is gone), and `audit.sh --only cron` passes.

## 7. Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.56.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 3000 proto tcp
sudo ufw --force enable
sudo ufw status verbose
```

Never `ufw allow 3000` without a source. Verify from an out-of-scope host that
the port is unreachable (`nc -zv <host> 3000` must fail).

## 8. Services and ports

```bash
sudo ss -ltnp
```

Expected on this host: `22` (SSH), `3000` (Juice Shop), plus Docker's internal
bridge addresses. Anything else needs a justification.

Docker API: it must never listen on TCP.

```bash
sudo ss -ltnp | grep -E ':2375|:2376'    # must be empty
sudo ls /etc/systemd/system/docker.service.d/ 2>/dev/null
sudo rm -f /etc/systemd/system/docker.service.d/10-vulnserver-tcp.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
```

Database/administrative panels must not be published: check
`docker ps --format '{{.Names}} {{.Ports}}'`.

## 9. Docker / Juice Shop

```yaml
# already the default in web/docker-compose.yml
security_opt: [no-new-privileges:true]
mem_limit: 1g
restart: unless-stopped
ports: ["${LAB_BIND_ADDR}:${JUICE_SHOP_PORT}:3000"]
logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```

Hardening steps:

- pin the image tag (done) and rebuild deliberately when updating;
- never mount `/var/run/docker.sock` into a container;
- never use `privileged: true`;
- bind the published port to the lab interface (`LAB_BIND_ADDR`) and restrict the
  source network in UFW;
- do not give `labuser` membership in the `docker` group — it is root-equivalent.

```bash
cd /opt/vulnserver/web && sudo docker compose up -d --force-recreate
sudo docker inspect vulnserver-juice-shop --format '{{.HostConfig.Privileged}} {{.HostConfig.Memory}}'
```

## 10. Security updates

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y unattended-upgrades
sudo systemctl enable --now unattended-upgrades
sudo apt-get -s upgrade | grep -c '^Inst '
```

Do not run a full upgrade during an exercise; schedule it between groups.

## 11. auditd

```bash
sudo ./scripts/monitoring/setup_audit.sh apply
sudo auditctl -l | grep vulnserver
sudo ausearch -k vulnserver_flags -ts recent
```

Keep the rule set versioned; it is part of the evidence chain.

## 12. Logs and integrity

```bash
sudo chown root:root /opt/vulnserver/logs /opt/vulnserver/logs/*
sudo chmod 0750 /opt/vulnserver/logs
sudo chmod 0640 /opt/vulnserver/logs/*
sudo chattr +a /opt/vulnserver/logs/events.log   # append-only (ext4)
lsattr /opt/vulnserver/logs/events.log
```

`chattr +a` prevents even root from rewriting history (root can still clear the
attribute, so it is tamper *evidence*, not tamper *proof*). Archive logs off-host
after each group.

## 13. Verification matrix

| Finding | Audit section | Command to prove the fix |
|---|---|---|
| root SSH login | `ssh` | `sshd -T \| grep permitrootlogin` → `no` |
| password SSH | `ssh` | `sshd -T \| grep passwordauthentication` → `no` |
| labuser in sudo/adm/docker | `accounts` | `id labuser` |
| labpriv login-able | `accounts` | `passwd -S labpriv` → `L` |
| flag permissions | `permissions` | `generate_flags.sh verify` |
| world-writable dirs | `permissions`,`cron` | `find /opt/vulnserver -type d -perm -0002` |
| SUID on find | `suid` | `stat -c '%a' /usr/bin/find` → `755` |
| sudo delegation | `sudo` | `ls /etc/sudoers.d/vulnserver-lab-b` |
| writable root helper | `sudo` | `stat -c '%U:%G %a' /usr/local/bin/lab-healthcheck` |
| root cron job | `cron` | `ls /etc/cron.d/vulnserver-lab-c` |
| firewall inactive | `firewall` | `ufw status` |
| Docker API on TCP | `services` | `ss -ltnp \| grep 2375` |
| privileged container | `docker` | `docker inspect ... Privileged` |
| missing audit rules | `auditd` | `auditctl -l \| grep -c vulnserver` |

## 14. Final acceptance run

```bash
sudo ./harden.sh --apply --yes
sudo ./audit.sh --stdout | head -5          # expect 0 FAIL for lab sections
sudo ./scripts/scenarios/scenario-a.sh verify; echo "A exit=$?"
sudo ./scripts/scenarios/scenario-b.sh verify; echo "B exit=$?"
sudo ./scripts/scenarios/scenario-c.sh verify; echo "C exit=$?"
```

All three `verify` calls must exit **1** (the vulnerabilities are gone) and the
audit must show no FAIL in `ssh`, `accounts`, `permissions`, `sudo`, `suid`,
`cron` or `firewall`.
