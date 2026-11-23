# Test report

What was **actually executed** for VulnServer v1.0, in which environment, and
what still has to be verified on a real VM. Nothing in this document is
simulated: every PASS below comes from a command whose output is stored in
`reports/test-run-<timestamp>.log`.

- Date of run: 2026-11-23
- Result: **80 / 80 functional checks PASS, 0 FAIL**
- Artifacts: `reports/test-matrix-20261123-120100.md`,
  `reports/test-run-20261123-120100.log`

## 1. Environment used for validation

| Property | Value | Consequence |
|---|---|---|
| Build host | Kali GNU/Linux Rolling, kernel 7.2.15 | scripts are portable Bash, no Ubuntu-only syntax assumed beyond `apt`/`systemd` guards |
| User | `kaliroot` (uid 1000), groups include `sudo`, `docker` | Docker usable without sudo; **no passwordless sudo** |
| `sudo` | requires a password (not available) | cannot create host users, cannot touch host UFW/auditd/sshd |
| Docker | 28.5.2, cgroup v2, overlay2, Compose 2.40.3 | real containers available → web integration and sandboxed lab tests |
| Resources | 12 vCPU, 22.8 GiB RAM, 693 GB free | comfortable for tests and image pulls |
| `/dev/kvm` | present but not accessible to the user (no `kvm` group) | **no QEMU/KVM VM** could be booted here |
| systemd | running (PID 1) | host services exist, but modifying them needs root |

### What this means

| Layer | Validated here? | How |
|---|---|---|
| Bash scripts (syntax, logic, error handling) | **yes** | `bash -n` on every script + full execution |
| Account creation, permissions, sudo policy, cron | **yes** | executed as root inside a disposable `ubuntu:24.04` container |
| All three privilege-escalation paths | **yes** | exploited end to end, flags read, root proven |
| Flags generation / ownership / rotation | **yes** | generated, verified, rotated by `reset-lab.sh` |
| Audit / hardening / reset / uninstall | **yes** | executed and their effects asserted |
| Juice Shop deployment | **yes** | `docker compose` on the host, HTTP 200 + health check |
| Ubuntu VM boot, sshd login, UFW, auditd, Docker engine install | **no** | needs root on a real Ubuntu 24.04 VM |

The container profile (`install.sh --profile container`) deliberately skips
Docker, UFW, auditd and sshd because those cannot be configured from an
unprivileged container on this host. The lab logic itself is fully exercised.

## 2. Results by group

| Group | Checks | PASS | FAIL |
|---|---|---|---|
| Test dependencies | 2 | 2 | 0 |
| `install.sh --profile container` | 1 | 1 | 0 |
| Accounts | 7 | 7 | 0 |
| Flags | 7 | 7 | 0 |
| Negative controls (lab is not wide open) | 6 | 6 | 0 |
| Scenario A (permissions) | 8 | 8 | 0 |
| Scenario B (sudo) | 9 | 9 | 0 |
| Scenario C (cron) | 8 | 8 | 0 |
| Audit and report | 9 | 9 | 0 |
| Hardening | 10 | 10 | 0 |
| Reset | 6 | 6 | 0 |
| `lab-manager.sh` | 2 | 2 | 0 |
| Uninstall (purge) | 5 | 5 | 0 |
| **Total** | **80** | **80** | **0** |

## 3. Evidence of the key behaviours

**Installation.** `install.sh --profile container --yes` exits 0 and creates the
full tree, three accounts, three flags and the toolchain copy in
`/opt/vulnserver/bin`.

**Account model.**
- `adminlab` in `sudo`; `labuser` **not** in `sudo`; `labpriv` password state `L`.
- Negative controls: `labuser` cannot read `root.txt` or `privilege.txt`, cannot
  `sudo` to root, cannot write the log or flags directories, but **can** read
  `user.txt`.

**Scenario A.** `chmod u+s /usr/bin/find` is applied (`4755`) and a restore point
is created. From a `labuser` session:

```
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \;
```

returns the ROOT flag (`uid=0` effective). `deactivate` restores `0755` on the
binary and `0755` on the directory.

**Scenario B.** Two-stage chain proven:
1. `runuser -u labuser -- sudo -n -u labpriv /usr/bin/cat .../privilege.txt`
   returns the PRIVILEGE flag.
2. As `labpriv`, replacing the group-writable root helper
   (`/usr/local/bin/lab-healthcheck`, mode `774`, group `labpriv`) and invoking
   `sudo -n /usr/local/bin/lab-healthcheck` writes `root.txt` to `/tmp` as root
   (file owner `root`).

After `deactivate`, the sudoers file is gone, the helper is `root:root 0755`, and
`sudo -u labpriv cat /etc/shadow` is denied.

**Scenario C.** The world-writable directory is `0777`; a `labuser` session
replaces the root cron script by rename. A real cron run (test enabled with
`RUN_CRON_TEST=1`) executes the attacker script with **uid 0** and copies the
ROOT flag. Deactivation removes the drop-in and restores `0755` on the directory.

**Audit.** `audit.sh --stdout` runs, produces a report with a result summary and
per-section findings, detects the (absent) firewall, validates flag permissions,
and leaves the filesystem unchanged (checksums before/after identical).

**Report.** `report.sh --stdout` lists `SCENARIO_ACTIVATE` events; `events.log` is
valid JSON per line and records the acting user.

**Hardening.** With all three scenarios re-activated, `harden.sh --apply --yes
--only permissions,sudo,suid,cron` strips the SUID bit, removes the delegated
sudoers file, secures the helper, removes the cron drop-in, restores `0755` on
lab directories, and writes a backup directory. The SUID path no longer yields
root, the post-hardening audit reports no unexpected SUID binary, and the backup
copy itself is stripped of privilege bits.

**Reset.** Rotates both `user.txt` and `root.txt` (values compared), deactivates
all scenarios, keeps `backups/`, and leaves the participant home directory with
only the shell skeleton.

**Uninstall.** `uninstall.sh --yes --purge` removes `/opt/vulnserver`, the
sudoers files and the cron drop-in, and keeps `adminlab` as the recovery account.

## 4. Juice Shop integration (host Docker)

Deployed from `web/docker-compose.yml` with a test env file
(`LAB_BIND_ADDR=127.0.0.1`, port 13000):

| Check | Result |
|---|---|
| `docker compose config` | valid |
| Image | `bkimminich/juice-shop:v17.1.1` (pinned) |
| `GET /` | **HTTP 200** |
| `GET /rest/admin/application-version` | `{"version":"17.1.1"}` |
| Container health | **healthy** |
| `HostConfig.Memory` | `1073741824` (1 GiB limit applied) |
| `HostConfig.Privileged` | `false` |
| `SecurityOpt` | `no-new-privileges:true` |
| Log rotation | json-file, 10m × 3 |
| Teardown (`down -v`) | container, network and volume removed |

**Defect found and fixed:** the first health check used `node` from `PATH`, but
the Juice Shop image is shell-less and keeps Node at `/nodejs/bin/node`, so every
probe failed with `executable file not found in $PATH` and the container stayed
`starting`. The health check now uses the absolute path and the container reaches
`healthy`.

## 5. Defects found during validation and fixed

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | `useradd` for `labpriv` collided with the pre-created group | install aborted, no flags created | create the group first and pass `--gid` |
| 2 | `generate_flags.sh verify` parsed owner/group/mode incorrectly | install exited non-zero on a correct install | 4-field parsing, compare `owner:group` and mode |
| 3 | `uninstall.sh --purge` recreated the log directory after deletion | `/opt/vulnserver` survived a purge | logging is disabled before removing the state dir |
| 4 | Compose health check used `node` | container never healthy | absolute `/nodejs/bin/node` |
| 5 | `harden.sh` backups preserved the SUID bit | SUID copy inside `backups/` was itself an escalation path | strip privilege bits from backups; exclude backup dir from SUID scans |
| 6 | Test harness passed on empty vs empty | false PASS results masked a broken install | empty expectation is now a failure |
| 7 | `lab-manager.sh status` aborted when the container was absent | `set -e`/`pipefail` killed the assignment after `docker inspect` failed | tolerate the failure and print `absent` |

## 6. Not validated here — must be run on a real VM

| Check | Why not here | How to verify on Ubuntu 24.04 |
|---|---|---|
| VM boots / cloud-init | no KVM access, no VM | boot the image, complete `INSTALLATION.md` |
| SSH password login as `labuser`, root login refused | sshd not installable as non-root | `ssh labuser@host`, `ssh root@host` (must fail) |
| UFW rules and default-deny | needs root + netfilter on the host | `sudo ./config/ufw/ufw-rules.sh apply; sudo ufw status verbose`; test from an out-of-scope host |
| auditd rules loaded in kernel | audit subsystem unavailable in container | `sudo ./scripts/monitoring/setup_audit.sh apply; sudo auditctl -l \| grep vulnserver` |
| Docker installation via `--install-deps` | skipped by container profile | `sudo ./install.sh --install-deps` on a clean VM |
| `systemctl` integration (ssh, cron, docker, auditd) | no systemd in container | `systemctl status ssh cron docker auditd` |
| Metadata-service blocking, cloud firewall | no cloud VM | see `CLOUD_DEPLOYMENT.md` §8 |
| Kernel-level attacks outside scope | intentionally excluded | not part of this lab |

## 7. Reproduce the results

```bash
# 1. Functional suite in a disposable Ubuntu 24.04 container (needs Docker)
RUN_CRON_TEST=1 ./tests/test-container.sh
cat "$(ls -t reports/test-matrix-*.md | head -1)"

# 2. Web application on any host with Docker
docker compose --env-file web/.env.example -f web/docker-compose.yml up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
docker inspect -f '{{.State.Health.Status}}' vulnserver-juice-shop
docker compose --env-file web/.env.example -f web/docker-compose.yml down -v

# 3. On a real VM (manual checks from §6)
sudo ./install.sh --install-deps --activate a,b,c
sudo ./lab-manager.sh status
sudo ./audit.sh
```

## 9. WireGuard remote access

`scripts/remote/setup_remote_access.sh` was executed for real inside an
`ubuntu:24.04` container with `NET_ADMIN` and `wireguard-tools` installed, so
`wg0` was a real kernel interface, not a mock.

| Check | Result |
|---|---|
| `--apply` with two peers | exit 0; `wg show` lists `wg0`, port 51820, peers `10.8.0.2/32` and `10.8.0.3/32` |
| Server address | `10.8.0.1/24` on `wg0` |
| Key material | `wg0.conf`, `server.key`, `clients/*.conf`, `peers/*.info` all mode `600` |
| Second run (idempotent) | existing peers reported, new peer added at the next free address, `wg syncconf` reload |
| `--remove-peer` with `--apply` | peer removed from the interface, client config deleted |
| Removing the last peers | refused with exit 1; interface and config untouched |
| Endpoint change | all client configs regenerated with the new endpoint |
| Dry-run | prints the plan, exits 0, writes nothing, needs no root |
| Input validation | rejects `/16`, port 99999 and a peer name with spaces |

Found and fixed during this test: `wg-quick strip` rejected the temporary
config because it derives the interface name from the file name (now validated
as `<iface>.conf`), and `--apply --remove-peer` wrongly demanded `--endpoint`
again (now remembered in `/etc/wireguard/server.info`).

Not verified here: a handshake between two real machines, the provider
firewall, UFW rules (no ufw in the container), `systemctl enable wg-quick@wg0`,
and `--publish-web` (no lab installed in the container).

## 10. Cloud provisioning and cloud-init (2026-11-23)

Tested on the same host (Kali Rolling, Docker 28.5.2). No cloud account,
credentials or VM was used, so this validates the tooling's logic, not the
providers' behaviour.

| Check | Result |
|---|---|
| `tests/test-cloud.sh` (mock Hetzner + Vultr API) | **23/23 PASS**, exit 0 |
| Hetzner create | image, plan, SSH key, firewall and server requests issued with the expected bodies |
| Hetzner firewall | `udp/51820` from `0.0.0.0/0` and `tcp/22` only from the operator `/32` |
| Vultr create | `os_id` 24.04 x64, plan validated, `sshkey_id` + `firewall_group_id` attached |
| Destroy (both) | server/instance and firewall deleted, state file removed, exit 0 |
| Dry-run | prints the plan, sends no HTTP request, needs no token |
| cloud-init rendering | valid YAML, ~2.5 KB, placeholders substituted, > 32 KiB refused, `http://` and shell metacharacters rejected |
| `bootstrap-vm.sh` in `ubuntu:24.04` (`--cap-add NET_ADMIN`) | real `wg0` at `10.8.0.1/24`, `install.sh --profile container` completed, marker written, client config mode 0600 |
| Bootstrap re-run | idempotent: existing tunnel and peer reused, exit 0 |

Defects found and fixed while writing this:

1. `api()` returned status 1 whenever the response had no body, so every
   successful `DELETE` was reported as failed and `set -e` aborted the destroy.
2. Vultr request bodies were built with `jq --argjson` for `k1`/`g1` style IDs;
   jq exited with an error and an empty body was posted. IDs are now `--arg`
   and converted only where the API expects numbers.
3. `bootstrap-vm.sh` assumed `iproute2`/`iptables`/`openssl`; a minimal image
   failed at `wg-quick`. They are now installed with `wireguard-tools`.
4. The cloud-init template's own comments were being substituted by the
   generator, corrupting the header of the rendered file.
5. `install.sh` only updated `JUICE_SHOP_PORT` in the generated `.env`, so a
   re-run with `LAB_BIND_ADDR=10.8.0.1` kept publishing on `0.0.0.0`. The bind
   address is now rewritten and the health probe uses the real bind address.

Not verified here (requires credentials and a real VM):

- real `POST /servers` / `POST /instances` responses, quotas, image/plan names
  and prices at the time of deployment;
- the provider firewall actually dropping traffic (mock only records rules);
- the SSH upload and `bootstrap-vm.sh` path against a real cloud image with
  systemd, sshd, UFW, auditd and Docker;
- cloud-init executing the user-data at first boot, and Hetzner's 32 KiB
  acceptance of the generated file (size is checked locally);
- `scp` of the client configs from a real server (`fetch_clients`).

Reproduce:

```bash
./tests/test-cloud.sh

docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro ubuntu:24.04 bash -c '
  cp -a /src /work && cd /work
  LAB_DIR=/work PUBLIC_IP=203.0.113.10 PEER=owner \
  LAB_INSTALL_ARGS="--profile container --install-deps --yes" \
  ./scripts/cloud/bootstrap-vm.sh'
```

## 11. Conclusion

The laboratory logic — accounts, flags, the three escalation paths, audit,
hardening, reset and uninstall — is functionally verified in a clean Ubuntu 24.04
userland, including a real root cron execution and two full root compromises.
The components that require a real machine with root (sshd, UFW, auditd, Docker
installation, VM boot) are implemented and syntax-checked but remain to be
confirmed on Ubuntu Server 24.04 following §6; they are not claimed as verified
here.
