# Installation

This guide deploys VulnServer on **Ubuntu Server 24.04 LTS**. The project is a
server lab, not a hosted web service: it needs root, real accounts, SSH, cron and
Docker. Install it on a VM you can destroy.

## 1. Choose the platform

| Platform | Suitable | Notes |
|---|---|---|
| QEMU/KVM + Virtual Machine Manager | yes | recommended; snapshots are the fastest rollback |
| Proxmox / VMware / Hyper-V | yes | use a NAT or host-only network |
| Docker on a Linux host | limited | `--profile container` for CI only; no SSH/UFW/auditd |
| Cloud VPS | yes, with care | see [CLOUD_DEPLOYMENT.md](CLOUD_DEPLOYMENT.md) |
| Shared or production host | **no** | the lab grants root by design |

Minimum resources: 2 vCPU, 2 GB RAM, 20 GB disk (25 GB recommended with the
Juice Shop image).

## 2. Prepare an isolated network

1. Hypervisor network: **NAT** or **host-only**, not bridged to a network with
   other people's machines.
2. Note the lab subnet, e.g. `192.168.56.0/24`.
3. Keep a second management path (hypervisor console) so a firewall mistake
   cannot lock you out.

## 3. Install Ubuntu Server 24.04

- Architecture: amd64 (arm64 works, QEMU/KVM on Apple Silicon needs UEFI).
- Create the owner account, e.g. `adminlab`, with your SSH public key.
- Do **not** install a desktop environment; the lab is a server.
- Enable OpenSSH server during installation.
- After first boot:

```bash
sudo apt update && sudo apt upgrade -y
sudo timedatectl set-timezone UTC     # consistent evidence timestamps
```

## 4. Get the project onto the server

```bash
sudo apt install -y git
git clone <your-fork-url> ~/vulnserver
cd ~/vulnserver
```

Or copy the directory with `scp -r ./vulnserver adminlab@192.168.56.10:/home/adminlab/`.

## 5. Review the configuration

Open `config/lab.conf`. The values you will most likely change:

| Variable | Default | Meaning |
|---|---|---|
| `SSH_ALLOWED_NETS` | `192.168.56.0/24 10.10.0.0/24` | who may reach SSH |
| `LAB_ALLOWED_NETS` | same | who may reach Juice Shop |
| `JUICE_SHOP_PORT` | `3000` | published web port |
| `LAB_BIND_ADDR` | `0.0.0.0` | publication address (firewall restricts it) |
| `LAB_USER_PASSWORD` | `LabUser!2026` | lab-only password shared with the partner |
| `ADMIN_USER_PASSWORD` | `AdminLab!2026` | owner account (change it!) |

All values can be overridden per run without editing the file:

```bash
sudo SSH_ALLOWED_NETS="192.168.56.0/24" JUICE_SHOP_PORT=3000 ./install.sh
```

## 6. Run the installer

```bash
sudo ./install.sh --install-deps --activate a,b,c
```

What it does, in order:

1. verifies the OS, port and required base tools;
2. installs missing packages (`jq`, `curl`, `cron`, `sudo`, `ufw`, `auditd`,
   `docker.io`, `docker-compose-v2`) when `--install-deps` is given;
3. creates `/opt/vulnserver/{bin,flags,logs,backups,reports,state,lab,web}` and
   applies the baseline permission model;
4. creates `adminlab` (sudo), `labuser` (unprivileged) and `labpriv`
   (intermediate, locked password);
5. installs the baseline sudo policy (labuser has no root rights);
6. generates the three flags with random identifiers;
7. installs the sshd drop-in (root login disabled) and validates it with
   `sshd -t` before reloading;
8. installs Docker if needed and starts Juice Shop via `docker compose`;
9. applies UFW rules and the auditd rule set;
10. activates the requested scenarios.

Useful flags:

```
--install-deps     install missing packages automatically
--activate a,b,c   activate scenarios after installation
--no-docker        skip Docker and Juice Shop
--no-firewall      do not touch UFW (e.g. behind an external firewall)
--no-auditd        skip auditd rules
--no-ssh           do not modify sshd
--port N           Juice Shop port
--profile container restricted profile for CI/testing
--skip-os-check    allow non-Ubuntu hosts (disposable VMs only)
-y                 non-interactive
-n                 dry run
```

Every run appends to `/opt/vulnserver/logs/events.log`.

## 7. Verify the installation

```bash
sudo ./lab-manager.sh status
sudo ./audit.sh --stdout | head -40
sudo ./scripts/flags/generate_flags.sh verify
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
```

Expected: three accounts, three flags with the documented ownership, Juice Shop
`HTTP 200`, audit report produced.

## 8. Test the login path as the participant

From another machine on the allowed network:

```bash
ssh labuser@192.168.56.10        # password: LabUser!2026
cat /opt/vulnserver/flags/user.txt
sudo -n true; echo "sudo exit: $?"   # must fail
```

If SSH refuses the connection, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
Never share `adminlab` credentials with the participant.

## 9. Hand over the participant material

Give the participant `docs/ATTACKER_GUIDE.md` **only**. It contains the scope,
the flags to collect and the report template, and no solutions. Keep
`docs/INSTRUCTOR_SOLUTIONS.md` for yourself.

## 10. Snapshot

Before the exercise, take a hypervisor snapshot (`vulnserver-clean`). Restore it
between groups instead of reinstalling. If snapshots are unavailable:

```bash
sudo ./reset-lab.sh --yes
```

## Uninstallation

```bash
sudo ./uninstall.sh            # stops services, keeps logs/flags/backups
sudo ./uninstall.sh --purge    # also deletes the state directory
```

`adminlab` is always kept so you never lose the recovery account.
