# Cloud deployment

The lab can run on a cloud VM, but a cloud VM is **not** a private laboratory.
This guide covers what each provider actually offers (checked November 2026,
prices change), how to keep the lab off the public internet, and the exact
WireGuard setup.

> Provider prices and free-tier conditions were verified from vendor pages and
> 2026 reporting at the time of writing. Re-check before you pay. Do not assume a
> "free" tier still applies: Oracle halved its free ARM allowance in June 2026.

## 1. Provider comparison (November 2026)

| Provider | Smallest useful plan | Price | Root / SSH | Ubuntu 24.04 | Private network | Notes |
|---|---|---|---|---|---|---|
| **Oracle Cloud (Always Free)** | Ampere A1: 2 OCPU / 12 GB total, or 2× AMD micro (1/8 OCPU, 1 GB) | €0 while inside Always Free | yes | yes (A1 and micro) | VCN + private subnet | card required; home region only; A1 capacity often exhausted; quota cut 15 Jun 2026, enforced from ~18 Aug 2026; 200 GB block storage, 10 TB egress/month |
| **Oracle Cloud (PAYG / trial)** | same shapes, $300 credit for 30 days | usage-based after credit | yes | yes | yes | trial credit is separate from Always Free |
| **Hetzner Cloud** | CX23: 2 vCPU / 4 GB / 40 GB NVMe | ≈ €5.99/month incl. IPv4 (Oct 2026 checks; prices rose 15 Jun 2026) | yes | yes | private network (check current fee) | hourly billing capped at monthly price; CPX plans frequently sold out; EU/US/Singapore locations |
| **DigitalOcean** | Basic 2 vCPU / 4 GB / 80 GB | $24/month (2 vCPU/2 GB $18; 1 GB $6) | yes | yes | VPC, free | per-second billing with monthly cap; simple firewall product |
| **Kamatera** | configurable 2 vCPU / 2–4 GB | hourly/monthly, 30-day trial for new accounts | yes | yes | available | fine-grained sizing, less community documentation |

Not recommended for this lab: shared hosting, PaaS/app platforms (no root, no
cron, no SUID), free "container" tiers, or any provider whose terms forbid
hosting vulnerable systems.

### What "free" really means

- **Oracle Always Free** is the only major provider that keeps a real VM free
  indefinitely, but the useful ARM box is now 2 OCPU / 12 GB (it was 4/24 before
  15 June 2026). The AMD micro instances (1 GB RAM) are too small for
  Juice Shop + the lab tooling in practice; the A1 shape is the realistic option.
- Always Free resources must live in the tenancy's **home region**.
- ARM64 works: the Juice Shop image is multi-arch and the lab scripts are
  architecture-neutral. The amd64 path is the better-tested one.
- Nested virtualisation is not available on these plans: you cannot run
  QEMU/KVM *inside* the cloud VM. The cloud VM **is** the lab server.

## 2. Acceptable use — read before deploying

Intentionally vulnerable hosts are a common source of abuse complaints. Before
deploying:

1. Read the provider's acceptable-use and security-testing policy. Most forbid
   unauthorized scanning and abusive traffic; some explicitly require that
   vulnerable systems are not publicly reachable.
2. Assume the lab must **never** be reachable from the internet. Do not open
   port 3000 to `0.0.0.0/0`.
3. Prefer a private subnet with no public IP plus a bastion/VPN. If the provider
   requires a public IP, restrict the cloud firewall to your own address and the
   WireGuard port.
4. Use a dedicated account/tenancy for the lab, not your production account.
5. Destroy the instance when the exercise ends. Snapshot first if you need it.

If the provider does not permit vulnerable workloads even when firewalled, run
the lab on a local hypervisor instead. That is always the safer default.

## 3. Reference topology

```
participant ──(WireGuard 10.8.0.0/24)──┐
                                       ├──> lab VM  (no public HTTP)
owner/admin ──(SSH over WireGuard)─────┘        │
                                                ├─ Juice Shop 127.0.0.1:3000 (or 10.8.0.1:3000)
                                                └─ UFW: deny all inbound except wg0
```

- Only `51820/udp` (WireGuard) is open to the internet, ideally restricted to
  known source addresses.
- SSH listens on the tunnel only, or UFW allows SSH only from `10.8.0.0/24`.
- Juice Shop is published on the tunnel interface, not on the public NIC.

## 4. Create the VM

### Oracle Cloud (Always Free)

1. Create a VCN with a public subnet (for WireGuard) and a private subnet (for
   the lab), or one subnet with strict security lists.
2. Create an instance: shape `VM.Standard.A1.Flex`, 2 OCPU / 12 GB, image
   **Ubuntu 24.04**, boot volume 50 GB (minimum is ~47 GB).
3. Security list / NSG inbound: `51820/udp` from your address, `22/tcp` from your
   address only. No other ingress.
4. Save the SSH key; connect as `ubuntu`, then `sudo -i`.
5. If A1 capacity is unavailable, retry in another availability domain or use
   Pay As You Go (Always Free resources stay free; usage above them is billed).

### Hetzner Cloud

1. New server → location EU → image Ubuntu 24.04 → type CX23 (2 vCPU/4 GB).
2. Add your SSH key, no additional volumes.
3. Firewall: inbound `22/tcp` and `51820/udp` from your IP only.
4. Enable backups only if you accept the extra cost; a snapshot before the
   exercise is cheaper.

### DigitalOcean

1. Create Droplet → Ubuntu 24.04 → Basic, 2 vCPU/4 GB ($24/month).
2. Authentication: SSH keys only.
3. Cloud firewall: inbound SSH from your IP, WireGuard UDP; everything else
   denied.
4. Take a snapshot after installation, destroy the Droplet afterwards.

### If you already have an Ubuntu ISO

**You do not need it, and using it makes the deployment worse.** Every provider
above offers an official Ubuntu 24.04 image that is already configured for the
cloud: DHCP, SSH key injection through cloud-init, serial console, and a
boot volume that resizes to the plan. Booting your own ISO means no cloud-init
(so no SSH keys and no user), manual network configuration, and a 30–60 minute
interactive install through a VNC console.

The ISO also gains nothing for this lab: the scripts install everything else
(`install.sh --install-deps`), and the lab is a normal Ubuntu server.

If you still want your own media, these are the verified paths (checked
November 2026):

| Provider | Custom media | Format | Notes |
|---|---|---|---|
| **Vultr** | yes | `.iso` by public URL | max 10 GB, direct URL without auth or redirects, 2 ISOs per account, no Windows media; boot from the ISO then use the VNC console |
| **Oracle Cloud** | import only | `.qcow2` or `.vmdk` | upload to Object Storage, then *Compute → Custom Images → Import*; BIOS/MBR, single disk, no encryption, max 1 TB |
| **Hetzner Cloud** | ISO library only | provider images | the Cloud API has no image upload; a custom disk requires snapshotting an existing server or the rescue-system `.img` procedure |
| **DigitalOcean** | custom image | `.qcow2`, `.vmdk`, `.raw` (check the current list) | image import, not ISO; the boot loader must already be installed |

Whichever path you take, once the machine boots you are in the same place as
§5: install WireGuard and Docker, clone the repo, run `install.sh`.

> If you install from an ISO, create the administrative user yourself and copy
your SSH public key before exposing anything. A cloud VM with password-only SSH
on a public IP is compromised within hours.

## 5. Install the lab

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git wireguard

# Copy the project to the VM (or clone your fork):
sudo mkdir -p /root/vulnserver
sudo rsync -a --exclude reports/ --exclude .git/ ./ root@<vm>:/root/vulnserver/

# Create the tunnel FIRST (section 6): the web app binds 10.8.0.1, which does
# not exist until wg0 is up, and Docker would fail to publish the port.
cd /root/vulnserver
sudo ./scripts/remote/setup_remote_access.sh --apply --endpoint <public-ip> --peer owner

# Then install the lab, publishing the web app only on the tunnel address:
sudo LAB_BIND_ADDR=10.8.0.1 \
     SSH_ALLOWED_NETS="10.8.0.0/24" \
     LAB_ALLOWED_NETS="10.8.0.0/24" \
     ./install.sh --install-deps --activate a,b,c
```

If you install the lab before the tunnel, re-run
`setup_remote_access.sh --apply --publish-web` afterwards to rebind Juice Shop.

Then verify from the VM: `curl -s -o /dev/null -w '%{http_code}\n' http://10.8.0.1:3000/`.

## 6. WireGuard server configuration

### 6.1 Automated (recommended)

`scripts/remote/setup_remote_access.sh` builds the tunnel, keys, peer configs
and firewall rules. It is idempotent: re-running it keeps existing keys and
reloads the interface without dropping connected clients.

```bash
# 1. See what it will do (no root, no changes):
./scripts/remote/setup_remote_access.sh --endpoint 203.0.113.10 --peer owner

# 2. Apply on the VM:
sudo ./scripts/remote/setup_remote_access.sh \
     --apply --endpoint 203.0.113.10 --peer owner --peer alice

# 3. Publish Juice Shop on the tunnel only, then verify:
sudo ./scripts/remote/setup_remote_access.sh --apply --publish-web
sudo ./scripts/remote/setup_remote_access.sh --status
```

Copies of the client configs land in `/etc/wireguard/clients/<peer>.conf`
(mode `0600`); import one into the WireGuard app on that device, or add `--qr`
to display a QR code for a phone (`apt install qrencode`).

Useful operations:

```bash
sudo ./scripts/remote/setup_remote_access.sh --apply --peer tablet   # new device
sudo ./scripts/remote/setup_remote_access.sh --apply --remove-peer tablet
sudo ./scripts/remote/setup_remote_access.sh --apply --endpoint new.example.net
```

Changing the endpoint regenerates every client config; redistribute them.
The script refuses to remove the last peer, which would leave the tunnel
unreachable.

**Order matters:** `install.sh` applies UFW with a reset. Run it first, then
`setup_remote_access.sh`, or re-run the WireGuard script afterwards to restore
`51820/udp` and the `wg0` allow rule. `config/ufw/ufw-rules.sh` also re-adds the
WireGuard rules when `/etc/wireguard/wg0.conf` exists.

### 6.2 Manual equivalent

```bash
cd /etc/wireguard
umask 077
wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee peer1.key | wg pubkey > peer1.pub
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <contents of server.key>

# Owner laptop
[Peer]
PublicKey = <peer1.pub>
AllowedIPs = 10.8.0.2/32

# Participant laptop
[Peer]
PublicKey = <participant.pub>
AllowedIPs = 10.8.0.3/32
```

```bash
systemctl enable --now wg-quick@wg0
wg show
```

Client configuration (owner laptop):

```ini
[Interface]
Address = 10.8.0.2/32
PrivateKey = <peer1.key>
DNS = 1.1.1.1

[Peer]
PublicKey = <server.pub>
Endpoint = <vm-public-ip>:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

Connect, then `ssh adminlab@10.8.0.1` and `curl http://10.8.0.1:3000/`.

Give each participant their own key pair and remove the peer block when the
exercise ends (`wg set wg0 peer <key> remove`).

## 7. Firewall on the VM

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 51820/udp
sudo ufw allow in on wg0
sudo ufw --force enable
sudo ufw status verbose
```

`config/ufw/ufw-rules.sh` already limits SSH and the web port to the configured
networks; set those networks to the tunnel (`10.8.0.0/24`) for cloud use.

The cloud provider's firewall is a second, independent layer: keep both. Opening
a port in UFW does not open it in the provider firewall, and vice versa.

## 8. Cloud-specific risks

| Risk | Mitigation |
|---|---|
| Public IP scanning finds Juice Shop | publish only on `wg0`/private address; cloud firewall denies 3000 |
| Cloud metadata service (`169.254.169.254`) reachable from a compromised account | block it for the lab user: `iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner labuser -j REJECT` (and for the container network) |
| Provider suspends the account for abuse | keep the lab off the internet, use a dedicated account, destroy after use |
| Billing while the instance is stopped | destroy, don't stop, when finished |
| Evidence lost with the instance | copy `reports/` and `backups/` off-host before destroying |
| Tunnel up but no handshake | provider firewall still blocks the UDP port; check the cloud firewall **and** `ufw status` |
| Handshake works, web page does not | Juice Shop is bound to `0.0.0.0` or `127.0.0.1`; rebind with `--publish-web` and check `docker ps` shows `10.8.0.1:3000` |
| Peer cannot reach the VM after a reboot | `systemctl status wg-quick@wg0`; the interface must come up before Docker recreates the container |
| Shared public IP with other tenants | never scan beyond your own instance |

Metadata blocking example (add to the VM, not to the repo defaults):

```bash
sudo iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner labuser -j REJECT
sudo iptables -I OUTPUT 1 -d 169.254.169.254 -s 172.28.60.0/24 -j REJECT
sudo netfilter-persistent save
```

## 9. Cost control checklist

- [ ] smallest shape that fits (2 vCPU / 4 GB is enough)
- [ ] hourly billing provider if the lab runs only a few days
- [ ] snapshot instead of a second always-on VM
- [ ] delete the instance, volumes and reserved IPs after the exercise
- [ ] check the invoice after the first cycle, not before

## 10. When not to use the cloud

Choose a local hypervisor when:

- the provider forbids vulnerable hosts or requires a public IP;
- the exercise includes kernel or network-level attacks;
- you need snapshots and instant rollback;
- you cannot expose the participants' source addresses.

A local QEMU/KVM VM with a host-only network remains the best environment for
this lab.
