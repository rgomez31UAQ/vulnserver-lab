# Troubleshooting

## SSH

**Connection refused**
```bash
sudo systemctl status ssh
sudo sshd -t                 # syntax error in a drop-in?
sudo ss -ltnp | grep :22
sudo ufw status              # is your source network allowed?
```
If a drop-in broke sshd, remove it and reload:
`sudo rm /etc/ssh/sshd_config.d/99-vulnserver.conf && sudo systemctl restart ssh`.

**Permission denied (publickey,password)**
`AllowUsers` only permits `adminlab` and `labuser`. Confirm the account:
`sudo ./scripts/users/create_users.sh status`, then reset the lab password:
`sudo passwd labuser`.

**Locked out after hardening**
Use the hypervisor console, then:
```bash
sudo rm -f /etc/ssh/sshd_config.d/99-vulnserver.conf
sudo systemctl restart ssh
```
This is why `harden.sh` asks before disabling password authentication.

## Accounts

**`useradd: group labpriv exists`**
Fixed in `scripts/users/create_users.sh` (the group is created first and reused).
If you see it on an older copy, run `sudo ./scripts/users/create_users.sh create`
again after updating.

**`labpriv` can log in**
```bash
sudo passwd -l labpriv
sudo usermod --password '!' labpriv
passwd -S labpriv        # must start with L
```

## Flags

**Flags missing after install**
```bash
sudo ./scripts/flags/generate_flags.sh generate --force
sudo ./scripts/flags/generate_flags.sh verify
```

**A student can read `root.txt`**
The permission model is broken. `sudo ./scripts/flags/generate_flags.sh verify`
shows the drift; fix with `sudo ./harden.sh --apply --only permissions`. Also
check for copies: `sudo grep -r 'VS{' /home /tmp /opt/vulnserver/lab 2>/dev/null`.
`reset-lab.sh` rotates the values, so leaked copies become useless.

**Flags tracked by git**
```bash
git rm --cached flags/user.txt flags/privilege.txt flags/root.txt
```
`.gitignore` already excludes the directory; never commit generated flags.

## Docker / Juice Shop

**`Cannot connect to the Docker daemon`**
```bash
sudo systemctl status docker
sudo systemctl enable --now docker
sudo docker info
```

**Port already in use**
```bash
sudo ss -ltnp | grep :3000
sudo JUICE_SHOP_PORT=3001 ./install.sh --no-firewall   # or stop the other service
```

**Container starts then exits**
```bash
cd /opt/vulnserver/web
sudo docker compose logs --tail 100 juice-shop
sudo docker compose ps
```
Low memory is the usual cause on a 1 GB VM; give the VM 2 GB or lower
`JUICE_SHOP_MEMORY_LIMIT` to `768m`.

**Health check stays `starting`**
The image is shell-less and keeps Node at `/nodejs/bin/node`. The compose file
uses that absolute path; if you edited it to `node`, the exec fails with
`executable file not found in $PATH`. Restore the shipped file and recreate:
`sudo docker compose up -d --force-recreate`.

**Juice Shop unreachable from the participant**
Check the publish address and the firewall:
`docker port vulnserver-juice-shop`, `sudo ufw status verbose`, and
`LAB_BIND_ADDR` in `/opt/vulnserver/web/.env`.

**`docker compose` not found**
Ubuntu's package is `docker-compose-v2`; the binary is `docker compose` (plugin).
Older hosts need `docker-compose` (v1) — install `docker-compose-v2` instead.

## Scenarios

**Scenario B will not activate**
```bash
id labpriv; getent group labpriv
command -v visudo
sudo visudo -cf /etc/sudoers.d/vulnserver-lab-b
```
The activation validates the file before installing it; a validation failure
aborts without touching the host policy.

**Sudo says "no new privileges" or ignores the rule**
Check file mode (`0440`) and that the filename has no dot:
`/etc/sudoers.d/vulnserver-lab-b` is valid; `...lab-b.conf` is ignored.

**Scenario C does nothing**
```bash
systemctl status cron
sudo cat /etc/cron.d/vulnserver-lab-c
sudo tail -50 /var/log/syslog | grep CRON
```
Cron runs the job at the top of each minute; wait up to 60 seconds. A replaced
script must be executable and readable by root.

**`verify` returns 1 but the lab looks active**
`verify` checks the *vulnerability*, not the state file. A `FAIL` means the
vulnerability is gone (for example after hardening) — that is expected after
remediation.

## Firewall

**UFW refuses to enable / locks out SSH**
Always allow SSH from your management network **before** enabling:
```bash
sudo ufw allow from 192.168.56.0/24 to any port 22 proto tcp
sudo ufw --force enable
```
If you lose access, use the hypervisor console: `sudo ufw disable`.

**Docker bypasses UFW**
Docker inserts its own iptables rules; a published port can be reachable even if
UFW denies it. Publish on a specific address (`LAB_BIND_ADDR`) and rely on the
provider/hypervisor firewall as well. Never publish on `0.0.0.0` on a host with a
public interface.

## auditd

**`auditctl: command not found`**
`sudo apt install -y auditd audispd-plugins`.

**Rules do not survive reboot**
Ubuntu loads `/etc/audit/rules.d/*.rules` via `augenrules`; ensure the file is
`0640 root:root` and run `sudo augenrules --load`. Check `sudo auditctl -l`.

**`ausearch` returns nothing**
Give it a key and a window: `sudo ausearch -k vulnserver_flags -ts today`.
Nothing is logged until the audited path is touched.

## Logs

**`events.log` not updating**
The log directory is root-only. Run the tools with `sudo`. If the directory was
deleted, recreate it: `sudo ./scripts/permissions/apply_permissions.sh base`.

**Need to prove logs were not modified**
```bash
sudo chattr +a /opt/vulnserver/logs/events.log
lsattr /opt/vulnserver/logs/events.log
sha256sum /opt/vulnserver/logs/events.log | tee /root/events.sha256
```
Copy archives off-host after each group.

## Tests

**Container test suite fails at install**
The suite runs `install.sh --profile container`, which skips Docker, UFW, auditd
and SSH. A failure there is a real script bug: read
`reports/test-run-<ts>.log` and `/tmp/install.log` printed in the failure block.

**`docker: permission denied` on the test runner**
The runner needs access to the Docker daemon (root or the `docker` group). It does
not need `sudo` for anything else.

## Full reset

```bash
sudo ./reset-lab.sh --yes          # state, flags, practice data
sudo ./uninstall.sh --yes --purge  # remove everything (keeps adminlab)
sudo ./install.sh --install-deps --activate a,b,c
```

If even that fails, restore the hypervisor snapshot `vulnserver-clean`.
