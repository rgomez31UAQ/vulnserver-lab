# Participant guide — authorized penetration test

**Read this first.** You are performing an authorized security assessment of a
laboratory server that a classmate deployed for this exercise. The authorization
covers *only* that machine, *only* during the agreed window, *only* from the
agreed network. Anything else is unauthorized access and is out of scope.

You must not:

- attack any other host, including the hypervisor, the school network or the
  internet;
- attack the Juice Shop image's upstream project or its infrastructure;
- leave persistence, backdoors, miners, or destructive changes behind;
- modify or delete the audit logs — the exercise requires them intact;
- use another student's flags or reports.

If you accidentally damage the host, stop and tell the owner immediately.

## 1. The target

| Item | Value |
|---|---|
| Host | your partner will give you the IP, e.g. `192.168.56.10` |
| Operating system | Ubuntu Server 24.04 LTS |
| Web application | OWASP Juice Shop, `http://<host>:3000` |
| SSH | `ssh labuser@<host>` (port 22), password given by the owner |
| Scope | the whole lab VM: web app, accounts, permissions, sudo, cron |
| Window | agreed with the owner; announce the start and end |

You are given an **unprivileged** account (`labuser`). You do not have, and must
not ask for, the owner's account (`adminlab`).

## 2. Goals

Collect and prove three flags, in this order:

| # | Flag path | What it proves | How far you must get |
|---|---|---|---|
| 1 | `/opt/vulnserver/flags/user.txt` | initial access as `labuser` | log in and read it |
| 2 | `/opt/vulnserver/flags/privilege.txt` | intermediate privilege level | reach the delegated account |
| 3 | `/opt/vulnserver/flags/root.txt` | full root compromise | run commands as root |

Hints on methodology (no solutions):

- enumerate before exploiting: users, groups, home directories, sudo rights,
  world-writable paths, SUID/SGID binaries, cron jobs, services and the web app;
- the web application is OWASP Juice Shop: its own challenges are a legitimate
  part of the exercise, but the flags live on the filesystem;
- the intermediate level exists because the owner delegated a narrow set of
  administrative tasks; study the delegation carefully;
- a scheduled task is part of the environment; observe it before touching it.

## 3. Rules of engagement

1. Work from the agreed source network; do not use VPNs, proxies or cloud shells
   that hide your origin.
2. Automated scanners are allowed against the lab host only, with a rate limit
   that does not overload it (Juice Shop on 2 vCPU).
3. Do not brute force SSH beyond a small, targeted password list; the lab
   password is given to you.
4. Do not install packages on the host, do not modify `/etc`, `/opt/vulnserver/logs`
   or `/opt/vulnserver/flags` permissions/locations, do not delete the web volume.
5. Keep your tooling in your home directory or in `/tmp`.
6. Stop when the window closes. Report anything still running.

## 4. Suggested workflow

1. **Reconnaissance** — reachability, open ports, service versions, HTTP headers.
2. **Web enumeration** — Juice Shop is a single-page app; explore its API and
   documented challenges.
3. **Host enumeration** — `id`, `sudo -l`, `find / -perm -4000`, writable
   directories, `/etc/cron*`, running processes, listening sockets.
4. **Initial access** — use the provided `labuser` credentials (SSH or the web
   app, if applicable). Record the exact command and timestamp.
5. **Privilege escalation** — one step at a time; record every command.
6. **Evidence** — flags, command transcripts, timestamps, screenshots.
7. **Clean up** — remove only the files you created.

## 5. Evidence you must deliver

For each flag:

- the flag value (copy/paste, not retyped);
- the command(s) that produced it, with timestamps;
- the identity before and after the step (`id`, `whoami`);
- one screenshot or terminal capture per step;
- the finding it corresponds to, and a severity assessment.

Also deliver:

- the list of services/ports you found and why each matters;
- every vulnerability you identified, even if you did not exploit it;
- one paragraph per finding on how the owner should fix it (you do not need to
  apply the fix).

## 6. Report template

```markdown
# Security assessment — VulnServer
Participant: <name>            Owner/host: <name> / <IP>
Window: <start> – <end>        Source network: <CIDR>

## 1. Executive summary
<3–6 lines: what you achieved, overall risk, most serious finding>

## 2. Scope and methodology
Tools used, source host, constraints, what was excluded.

## 3. Findings

### F-01 <title>
- Severity: Critical / High / Medium / Low
- Affected component: <service / file / account>
- Evidence: <command output, screenshot reference>
- Impact: <what an attacker gains>
- Recommendation: <precise configuration change>
- Verification: <how the owner can prove it is fixed>

(repeat per finding)

## 4. Flag evidence

| Flag | Value | Identity | Command | Timestamp | Evidence file |
|---|---|---|---|---|---|
| USER | VS{...} | labuser | ... | ... | shot-01.png |
| PRIVILEGE | VS{...} | ... | ... | ... | shot-02.png |
| ROOT | VS{...} | root | ... | ... | shot-03.png |

## 5. Attack narrative
Numbered steps from first connection to root, each with the command used.

## 6. Remediation plan (prioritised)
1. <highest impact fix>
2. ...

## 7. Appendix
Full command transcript, raw scan output, leftovers/cleanup notes.
```

## 7. Grading criteria (shared with the owner)

| Criterion | Weight |
|---|---|
| USER flag with valid evidence | 20% |
| PRIVILEGE flag reached through the intended delegation | 20% |
| ROOT flag with reproducible steps | 25% |
| Quality of findings and severity reasoning | 15% |
| Remediation recommendations | 15% |
| Professionalism (scope, cleanup, report clarity) | 5% |

Partial credit is given for a well-documented finding that you could not
exploit. Fabricated evidence scores zero.

## 8. After the exercise

The owner will harden the server. You may be asked to repeat the assessment: in
that case, document what is now blocked and *why*, and confirm with the same
methods. If a path still works, that is a finding, not a failure on your part.
