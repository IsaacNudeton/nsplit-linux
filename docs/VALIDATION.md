# Validation and release scope

[Overview](../README.md) · [Usage](USAGE.md) · [Security](../SECURITY.md)

## Reviewed baseline

The scoped correction/acceptance work completed on **0.1.0-12**, commit
`b2cdb21446c3305c69061fcbff1d1ca3b522cfcf`, tree
`35731ba6a7d5e47f546153092a55c0d8b9b5beaa`, in the project's earlier
development repository. That commit is **not part of this repository**, which
began as a single-commit snapshot of the later 0.1.0-13 source and has since gained the fixes described below; the identifiers
are provenance references, not something you can check out here. The development
repository's issues and pull request, with their detailed reviews, remain private;
this page summarizes what they established. Acceptance of that candidate is
separate from publishing a release or deploying to a real workstation.

The test environment was a disposable CachyOS guest using the documented
systemd/Plasma-login-manager integration. Documentation-only changes do not
extend the tested runtime scope.

**This snapshot is 0.2.0-alpha.1**, which adds [headless profiles](#headless-profiles-020-alpha1) to 0.1.0-17 (everything below about 0.1.0-17 and earlier still describes the code those profiles share). 0.1.0-13 added the MIT license and its packaging only:
building both packages and comparing them showed the 25 installed program files
byte-identical, in content and mode, to the reviewed 0.1.0-12 package, and the only added
file was `/usr/share/licenses/nsplit/LICENSE`. **0.1.0-14 is different: it changes
runtime code** to fix the three issues under [Former known issues](#former-known-issues)
and adds one command, one helper and three systemd units for the mount watcher.
**0.1.0-15 changes two files relative to -14** (`cmd-ops.sh` and `nsplit-ufw`; comparing the two
packages showed 31 installed files, exactly those two different) to fix #7 and #8, see
[below](#defects-7-and-8-fixed-in-010-15).
**0.1.0-16 changes four files relative to -15** (`cmd-ops.sh`, `cmd-add.sh`, `cmd-login.sh` and `cmd-status.sh`; comparing the two packages showed 31 installed files, exactly those four different): `cmd-ops.sh` for #10, see
[below](#defect-10-fixed-in-010-16), and the other three for #9, see [below](#issue-9-acknowledgement-and-status-for---ssh-tailscale-0110-16).
**0.1.0-17 changes three files relative to -16** (`bin/nsplit`, `cmd-add.sh` and `common.sh`; comparing the two packages showed 31 installed files, exactly those three different), for #17, see
[below](#issue-17-fixed-in-0110-17).
**0.2.0-alpha.1 changes four files relative to -17** (`cmd-add.sh`, `cmd-ops.sh`, `cmd-status.sh` and `common.sh`, which also carries the version string; comparing the two packages showed 31 installed files, exactly those four different, with the same modes), see
[below](#headless-profiles-020-alpha1).
The guest tests of the fixes ran on the 0.1.0-12 baseline package, with the changed files
copied over it (originals restored and checked afterwards). The -13 package was not installed.
**The -14 package built from this repository (main 49ed71b) was installed over 0.1.0-12 in
the guest for the [Tailscale SSH test](#focused---ssh-tailscale-test-2026-11-0506)**, where its
in-place upgrade, the repair of mounts lost at a boot, removal and a reboot ran; the focused
cases of the three former issues were not repeated on it.

## What the evidence supports

| Area | Accepted observations |
| --- | --- |
| Package binding | Source and 25 installed payload files matched the reviewed candidate, including installation transforms and modes. |
| Startup and access | Upgrade, migration, restart, fresh-start, crash-recovery and sampled boot observations; intended owner access and denial of recorded other-user/GID-0 paths. |
| Privileged operations | Actual owner sudo/helper paths, refusal/environment cases, and distinct unavailable/failed guard observations. |
| DNS repair | Actual guest services/files/helper with declared Tailscale/private-resolver stand-ins: drift repair, unchanged repeat, ownership/path refusal, rollback and catchable-signal recovery. |
| Real DNS | Two authenticated runs on one profile/tailnet: known public and node-own private answers, separate IPv4 port-53 destination counters, positive login and repeat verification without another link. |
| Held client | Corrected same-connection observation: successful no-restart control, then client-originated EOF and failed exchange after a managed restart, with no reconnect or client kill. |

The final held-client observer was reviewed against raw events and independent
local predicate controls. The original journal-substring detector could match
its own command text and is **not** valid evidence for its old closure claims.
Original failed runs remain part of the historical record, not erased by later
passing runs.

## Remote shell options

Both options are reachable only by enrolling with that option.

| Feature | In the code | Guest-validated |
| --- | --- | --- |
| `--ssh openssh`: a separate OpenSSH server in the profile namespace (`nsplit-sshd@PROFILE.service`) | Yes | **Partly.** Two focused tests (below): over the profile's private link (2026-11-03), and over the profile's Tailscale address on a lab tailnet (2026-11-06). Neither is part of the reviewed acceptance baseline. |
| `--ssh tailscale`: Tailscale SSH on the profile's node (`tailscale up --ssh`) | Yes | **Partly.** One focused test on a throwaway lab tailnet (below). It found that the tailnet policy, not nsplit, chooses the local account, and that the login gate is not in the paths these sessions use. Not part of the reviewed acceptance baseline. |

### Focused `--ssh openssh` test (2026-11-03)

One throwaway profile, enrolled with `--ssh openssh` (owner-managed) on the
0.1.0-12 baseline package in the disposable CachyOS guest (OpenSSH 10.6, systemd,
NetworkManager with `dns=systemd-resolved`); no Tailscale sign-in of any kind; the
guest was rebooted once. Observed:

- Enrollment (including its dry run) and the profile's `nsplit-sshd@` unit worked;
  the server listens on port 22 inside the profile's namespace and not in the host's.
- Public-key login from the host over the profile's private link, pinned to the
  profile's own host key, with a key in the root-managed key file and with one in the
  user's own `~/.ssh/authorized_keys`.
- Inside such a session, before the reboot: the right user, the profile's network
  namespace, the profile's resolver file, the profile's own Tailscale socket (another
  profile's socket was refused), and name resolution through the profile's resolver.
  The user's systemd manager was placed in the profile namespace.
- Refused, each with the server's own log line as the reason and with a key that does
  log in as the profile user: root, another enrolled user, an existing unenrolled
  user, a host administrator, a nonexistent user; also an unauthorised key and
  password authentication. Refused attempts started no session or user manager.
- Local and remote port forwarding, agent forwarding and client environment
  variables were refused, each against a positive control. X11 forwarding, tunnels,
  `PermitUserEnvironment` and `GatewayPorts` were checked by the effective
  configuration only, not by behavior.
- After the reboot the service was up, kept its host key and still refused the same
  users. Removal returned the checked state to the pre-enrollment baseline, apart
  from the former known issues below and one ownership-list file whose bytes differ for a
  reason that was not established.

Not covered by this test: `--ssh tailscale` (see the section after the next one); a connection
over the profile's tailnet (the second test, next section, covers it); any Tailscale sign-in; a graphical session; `kill -9`; IPv6;
more than one reboot or profile; a retest on the -13 or -14 package.

### Focused `--ssh openssh` test over the profile's tailnet (2026-11-06, phase 1 of [#13](https://github.com/IsaacNudeton/nsplit-linux/issues/13))

One throwaway owner-managed profile enrolled with `--ssh openssh` and signed in to the same throwaway lab tailnet as the
Tailscale SSH test (headscale in the guest, nothing on the public internet), on the **0.1.0-16 package** upgraded in place
from -15 in the disposable guest (OpenSSH 10.6, Tailscale 1.104.2). The client was ordinary OpenSSH (`ssh -i KEY
USER@ADDRESS`, host key pinned) in the namespace of a second lab node, connecting to the profile's **Tailscale address**:
not Tailscale SSH (the node's built-in SSH was off). One test key was authorized for the profile's user (their own
`~/.ssh/authorized_keys`) and, as a control, for root, the administrator account and another enrolled user, so that only the
server's own rules could keep those out; every refusal below was also tried against a plain OpenSSH server with permissive
settings in the lab namespace, and what that server accepted shows the test could tell the difference.

- **Login.** A command and an interactive login (terminal) as the profile's user worked. Each session ran in the
  profile's network namespace, saw the profile's private `/etc/resolv.conf` and the profile daemon's `/run/tailscale` (its `tailscale`
  CLI answered from the profile's node) and resolved names through the profile's resolver. The session had a logind session (PAM service
  `sshd`, class `user`) and a runtime directory, and with a login held open the user's **user manager ran in the profile namespace**
  (the placement drop-in applies to an ssh login).
- **Refused.** Root, another enrolled user, the administrator account and a nonexistent user: `Permission denied (publickey)`, with the
  server's own log lines `not allowed because not listed in AllowUsers` / `Invalid user` (the plain server accepted the same key for
  root, the administrator and the other user). An unauthorised key for the profile's user. Password: the failure lists `publickey` only, while the
  plain server's lists `publickey,password`; keyboard-interactive is not offered either.
- **Forwarding.** `ssh -L`: the server refused the channel (`administratively prohibited`, in the client's log) and the tunnel carried
  nothing (through the plain server it carried the far end's banner). `ssh -R`: `remote port forwarding failed`, exit 255 (the plain
  server accepted it). Agent forwarding: no agent socket in the session (the plain server gave one). A client environment variable was not
  set in the session (the plain server accepted it).
- **A user service.** A `systemd --user` service started from the session (`python3 -m http.server --bind 0.0.0.0`) ran in the profile's
  namespace and answered over the profile's Tailscale address from the lab node; it listened inside the profile namespace, not on the host.
  **Observed, not an expectation:** from the host's namespace it also answered over the profile's private veth address, because the in-namespace
  firewall accepts the host's address: a service that listens on all addresses is reachable by any process on the host over that address, whatever
  its user (`AllowUsers` protects only the sshd).
- **Lifecycle.** With a session open, restarting the profile's Tailscale daemon left the session's client alive and a new login worked within
  seconds; `nsplit stop --force` exited 0 and the server answered nobody while the profile was stopped, and after `nsplit start` a new login
  worked and status said Ready; after a reboot the daemon, the server and the mount watcher came up by themselves (the watcher re-attached the
  resolver mounts the boot had lost) and a login to the profile's Tailscale address worked, with the same refusal of root.
- **Where it answers.** Over the profile's Tailscale address, and over the documented private veth address from the host. Not from another profile's
  namespace (two tried), not from the lab at the veth address, and the host has no listener on port 22 (the host's own sshd stayed disabled and its
  configuration unchanged).
- **Removal** with an administrator-owned key file in `/etc/nsplit/ssh/PROFILE/`: the file was kept and reported, nothing else of the profile was
  left, and the guest's state (tree, content hashes, units, namespaces, ufw rules, host nft rules compared as a set, host sshd, accounts, links,
  trust anchors) equalled its state before the test. Two things were compared differently: the nft rules as a set of lines (a `stop --all` and `start --all` earlier in the run reloads the
  firewall in the sorted order of the profile list), and the shared ownership list, whose bytes at the start were not kept: its four records were each checked against the file they name.

**Operational observation.** OpenSSH 10 keeps a penalty per source address for failed logins and then resets new connections from that address for a while
(the default `PerSourcePenalties`; nsplit's server configuration does not change it). The refused attempts of this test had to be spaced for that reason,
and it applies to the profile's owner too: while a tailnet peer is failing logins from one address, other connections from that same address
are reset until the penalty expires.

Not covered: connecting by the node's MagicDNS name (the test used the address); more than one profile with OpenSSH at once; a key in the root-managed
key file (used only for the removal check); Tailscale versions other than 1.104.2; other OpenSSH versions; a graphical session; IPv6; Tailscale's own control
plane; and the headless placement that [#13](https://github.com/IsaacNudeton/nsplit-linux/issues/13) plans for a later phase (not implemented: enrollment still
needs the Plasma login manager).

### Focused `--ssh tailscale` test (2026-11-05/06)

One throwaway owner-managed profile enrolled with `--ssh tailscale` on the **0.1.0-14 package
built from main 49ed71b**, installed with `pacman -U` over 0.1.0-12 in the disposable CachyOS
guest (kernel 7.3, systemd 262, Tailscale 1.104.2, ufw active). The tailnet was a throwaway
lab: a self-hosted **headscale 0.29.7** control server in the guest (TLS with a private CA the
guest trusted for the test, embedded DERP relay), a second Tailscale node as the SSH client, and
`nsplit uplinks` set to a veth that reaches only the lab, so nothing of the profile could reach
the internet (checked with controls). No Tailscale account and no real tailnet were used; the
sign-in used the flags `nsplit login` passes plus the lab server and a lab pre-auth key, so
nsplit's own browser flow was not exercised. The lab policy's `ssh` rule allowed the owner's
own nodes with the action `accept`, with the allowed local users varied (non-root users; also
`root`; only the profile's own user).

**What worked.** A client logged in through the profile's node as the profile's user in three
shapes: a command without a terminal and a command with one (both started by the profile daemon
through `su`), and an interactive login shell (started by `login` with PAM service `remote`,
registered by logind as a user session). In every shape the session ran in the profile's
network namespace, saw the profile's private `/etc/resolv.conf` and the profile daemon's
`/run/tailscale`, and resolved names through the profile's resolver; the user manager started
by an interactive login was placed in the profile namespace. Port 22 was not answered on the
profile's host-side address (Tailscale SSH is served inside the daemon on the tailnet address
only). A node of another lab user was refused by the policy. After `systemctl restart` of the
profile's daemon with sessions open, the node
was Running again within seconds without a new sign-in and a new session worked; the same after
`nsplit stop --force` and `nsplit start`, and after a reboot (the daemon and the mount watcher
came up by themselves, the watcher repaired the resolver mounts that the boot had lost, and a
session saw the profile's namespace, resolver and socket). `nsplit stop` and `nsplit remove`
refuse while the user has a session. The 0.1.0-14 in-place upgrade did not restart the running
daemons, `nsplit status` reported the mounts the earlier version had lost at a reboot as Degraded,
and `nsplit mounts repair` re-attached them without restarting anything.

**What it found** (all in the profile's namespace unless stated):

- **The tailnet policy chooses the local account ([#9](https://github.com/IsaacNudeton/nsplit-linux/issues/9)).** Under a rule allowing
  `autogroup:nonroot` (the shape of Tailscale's documented default rule) the client logged in as
  another enrolled profile user and as the guest's administrator account (group wheel). Under a
  rule that also listed `root` a root session worked; it started in the profile namespace but
  `nsenter -t 1 -n` returned the host's namespace, and it read a root-only file and listed every
  profile record. A rule listing only the profile's own login restricted all of this. nsplit has
  no equivalent of `--ssh openssh`'s `AllowUsers`; each profile is signed in with the user's own
  account, so that account's owner writes the rule.
- **The login gate does not cover these sessions.** Its lines are in `/etc/pam.d/login` and
  `plasmalogin` only. With the placement drop-in removed (and no session or manager running
  before), the gate script refused that state when run as the login stack runs it, but an
  interactive Tailscale SSH login was accepted and `user@UID.service` started in the host's
  network namespace and stayed there for later logins until the user was terminated. What such
  a manager could reach was not measured.
- **`--ssh none` is not enforced for an owner-managed profile.** The profile user, as the
  node's operator, ran `tailscale set --ssh=false` and `--ssh=true` on their node and the
  client was refused and then accepted. `--root-managed` was not tested then (it was in 0.1.0-16: [below](#issue-9-acknowledgement-and-status-for---ssh-tailscale-0110-16)).
- **Two behaviours of Tailscale 1.104.2 itself ([#10](https://github.com/IsaacNudeton/nsplit-linux/issues/10)),** reproduced on a bare
  `tailscaled --ssh` node with nothing of nsplit: a client killed abruptly leaves the remote
  interactive login shell running (still there after 90 s, the user manager stays up), and
  stopping the daemon with a session open waits for systemd's stop timeout (10 s here) and ends
  in SIGKILL, so `nsplit stop --force` with an open session exited 1 although the profile was down
  (fixed in 0.1.0-16, [below](#defect-10-fixed-in-010-16)).
- **Two defects not specific to SSH,** both fixed in 0.1.0-15 (next section): changing the uplinks
  left ufw route rules for the previous uplinks ([#7](https://github.com/IsaacNudeton/nsplit-linux/issues/7)); `nsplit remove` left
  `scoped-NAME.lock` ([#8](https://github.com/IsaacNudeton/nsplit-linux/issues/8)).

Not covered: Tailscale's own control plane and its SSH policy features (the `check`
re-authentication mode, session recording, tags, grants), Tailscale versions other than
1.104.2, `--root-managed` with `--ssh tailscale`, two profiles with SSH at once, a graphical
session, IPv6, what an unplaced user manager could reach, nsplit's own interactive sign-in,
and whether Tailscale's default policy for a new tailnet allows `root` (a policy that lists it
was tested, not the default). The guest was left as it was before the test apart from the
package upgrade.

### Defects #7 and #8 (fixed in 0.1.0-15)

**[#7](https://github.com/IsaacNudeton/nsplit-linux/issues/7) — stale ufw route rules after changing the uplinks.** *Found* in the Tailscale SSH
test: after `nsplit uplinks --set` moved the uplinks to a lab interface and back, route rules for the lab
interface were still in ufw's rule file and in the live ruleset for every profile, including one removed
later. *Fix:* the rules of the uplinks that leave the list are deleted first (the helper takes the
dropped uplinks in an environment variable, interface-name characters only, for deletion only); a failing
delete stops the command before anything is changed, so it can be run again; the rules of an uplink that
stays are never touched. *Tested:* off-host with a stateful fake ufw, 21 checks including adding, dropping,
replacing, the same list again, a failing delete and its retry, and spacing in the list; the same checks
against the unfixed code fail 16 of 21, and seven mutants that each remove one safeguard are each rejected
by named checks; the existing suites are unchanged (403, 98 and 46 checks, all passing). In the disposable
guest with real ufw (active) on the changed files over the installed -14 package, and again on the real
installed 0.1.0-15 package: a dummy interface added and dropped as an uplink left no rule for it in the file
or the live ruleset and kept those of the real uplink; with ufw's rule file made immutable the delete
failed, the command said nothing was changed and nothing was, and the same command finished once the file
was writable again. *Not tested:* a list edited by hand followed by `nsplit reload` (not covered by the
fix); other ufw versions.

**[#8](https://github.com/IsaacNudeton/nsplit-linux/issues/8) — `scoped-NAME.lock` left by `nsplit remove`.** *Found* in the same test: the profile's DNS
step creates the empty file `/var/lib/nsplit/scoped-NAME.lock` and nothing records it, so removal left it.
*Fix:* removal deletes exactly the kind of file the step makes (an empty regular file with one link); a
symlink, a file with content or one with a second link is kept, reported, and keeps the profile registered
like any file nsplit did not write. *Tested:* off-host (the empty file removed, another profile's file
untouched, no file, and the three odd kinds kept with exit 1 and finished on retry once dealt with; controls
and mutants as above) and in the guest (a throwaway profile removed with its lock file, the others' files
still there, the guest's nsplit state equal to its state before the run). The 0.1.0-15 package in the guest
was upgraded in place from -14 (31 files compared, 2 changed).

### Defect #10 (fixed in 0.1.0-16)

**[#10](https://github.com/IsaacNudeton/nsplit-linux/issues/10) — `nsplit stop --force` reported a failure with a Tailscale SSH session open.** *Found* in the
Tailscale SSH test: the daemon holding the session did not exit within systemd's stop time-out
(10 s), systemd killed it, the profile really was down, but the unit was left `failed` and
nsplit's own check ("every unit inactive") reported that the stop had failed (exit 1). The same
time-out and kill happened on a bare `tailscaled --ssh` node, so it is Tailscale's behaviour; nsplit
changed only how it reports the result. *Fix:* after the stop nsplit reads the daemon unit's
`ActiveState`, `SubState`, `Result`, `MainPID` and `ControlPID`. It accepts the one state
`failed` with `Result=timeout`, no main and no control process, and only when `systemctl` itself
succeeded, the profile's namespace and every other unit of the profile are down, and `reset-failed`
clears the state and the unit then reads `inactive`. It prints a warning that the daemon was
killed (so not a graceful stop). A surviving process or namespace, a failure of another kind, another
unit, a state that cannot be read, and a state that cannot be reset all stay "NOT fully stopped" with the
diagnosis kept. The path without a session is unchanged (one `reset-failed` before the stop, no warning,
under 10 s). The refusals of `stop` and `remove` for a user who is logged in now say that a shell left
behind by an abruptly closed Tailscale SSH connection counts, and name
`loginctl terminate-user USER` as the administrator's explicit action; nsplit never runs it.
*Tested:* off-host with a fake systemd, 30 checks (a positive control that the fake loginctl logs what
nsplit calls, the killed daemon with exit 0 and the cleared state, the no-session path unchanged, `remove`
and `stop --all` with a killed daemon, and eleven cases that must NOT be normalised: systemctl exiting 1,
a process alive, a control process running, the namespace not gone, reset-failed failing, reset-failed lying,
facts unreadable, facts nonsensical, another failure result, another unit, and a second failed unit); the same
checks against the unfixed code fail 11 of 30, and nine mutants that each remove one safeguard are each
rejected by named checks. The existing suites on the integrated tree are unchanged. In the disposable
guest on the real 0.1.0-16 package (upgraded in place from -15, 31 files compared) with a throwaway
profile enrolled with `--ssh tailscale` on the lab tailnet: no session, stop exit 0 in 3 s with no warning;
with a Tailscale SSH command session open, a plain stop refused with the new text and
stopped nothing, `stop --force` hit the time-out (journal), exited 0 after 12 s, warned, left the unit
`inactive` rather than `failed`, left nothing in the namespace, and `start` brought the node back
Running with Tailscale SSH on; after the client was killed abruptly the abandoned login shell was still
running 20 s later, `stop` and `remove` refused naming `loginctl terminate-user`, nsplit ended nothing,
and after the test side ran that command the plain stop succeeded; `stop --all --force` with a session
open stopped all six profiles and then the shared firewall, exit 0, with the warning for the one killed
daemon, and `start --all` brought everything back. *Not tested:* other Tailscale versions; a daemon that
survives SIGKILL or a namespace that cannot be removed on the real system (those cases were
injected off-host only); `nsplit remove` with a killed daemon on the real system (off-host only); a
graphical session.

### Issue #9: acknowledgement and status for `--ssh tailscale` (0.1.0-16)

**[#9](https://github.com/IsaacNudeton/nsplit-linux/issues/9) — the tailnet policy chooses the local account.** The limitation cannot be removed by nsplit (it cannot read or
limit the policy, and its PAM gate is not in every path Tailscale's own SSH server launches a session by), so
0.1.0-16 changes what is *claimed and checked*, not what Tailscale SSH does. *Change:* `nsplit add --ssh
tailscale` is refused (in a dry run too, listed with any other problem) unless `--accept-tailscale-ssh-risk` is
given; `--yes` does not stand in for it, and the flag is refused with any other `--ssh` mode. The preview, the
final output of `nsplit add` and `nsplit login` state that the tailnet policy chooses the local account (any
account on the machine, the administrator and root included), that nsplit can neither read nor limit it and that its
login gate does not apply to these sessions, and name `--ssh openssh` as the recommended remote shell. For `--ssh
none` and `openssh` they say the built-in server is only switched off when the node is signed in (and, on an
owner-managed profile, that its user can switch it on later); for a root-managed profile they claim nothing
about that. `nsplit status` reads `RunSSH` from the node's real preferences: on although the record says `none`
or `openssh` is **Degraded** (exit 2) with the command that turns it off; unreadable, or a preferences record
without the field, is `Not checked` (a missing value is never read as off); a profile enrolled with
`--ssh tailscale` carries the boundary as a warning in its Ready line and as a `WARN` line in `status -v`.
*Tested:* off-host with a fake `tailscale` that records the setting, 38 checks (the refusals and their
wording, the dry run, the flag with other modes, the notices in the preview and at the end, the note for
owner- and root-managed profiles, status for none, openssh and root-managed profiles with the setting switched on and off
through `nsplit ts`, unreadable and missing preferences, a node not signed in yet, the `--ssh tailscale`
profile in all three states); the same checks against the unfixed code fail 30 of 38, and ten mutants that each remove one safeguard are each
rejected by named checks. One older check of the 0.1.0-12 suite that enrols with `--ssh tailscale` now needs the flag;
with that one line changed the suite passes unchanged otherwise. In the disposable guest on the real 0.1.0-16 package
with three throwaway profiles on the lab tailnet (`--ssh tailscale` acknowledged, `--ssh openssh`, and `--ssh none`
root-managed): the refusals, the dry runs and the notices printed as designed; the nodes signed in with the flags
`nsplit login` passes (plus the lab server) had the built-in SSH on, off and off in their real preferences; status
said Ready for all three, with the warning for the first. **Owner-managed `--ssh openssh`:** its user ran
`tailscale set --ssh=true` on their node (exit 0), `nsplit status` then said Degraded with the message and the
command, the lab peer could log in through Tailscale SSH as that user **and as the administrator account**, and after
the user switched it off status said Ready. **Root-managed:** the profile's user was refused when they ran
`tailscale set --ssh=true` ("Access denied") and when they ran the whole `tailscale up` command line that
`nsplit login` uses with `--ssh=true` ("Access denied: prefs write access denied"; the same line run by root was
accepted); another local user could not use that profile's socket at all; an administrator (`nsplit ts`) could switch
it on, and status then said Degraded. The `--ssh tailscale` profile's setting switched off behind the record's back was
shown as a `WARN` line. (The first guest run of the `up` case ran the command without the lab's `--login-server` flag
and got Tailscale's "mention all non-default flags" error, which says nothing about permission; the case was
rerun with the full line.) *Not tested:* Tailscale versions other than 1.104.2; a root-managed profile enrolled with
`--ssh tailscale`; an operator changed after enrolment; Tailscale's `check` mode and tags; `nsplit login` on a node
that is already signed in with the built-in SSH switched on (login does not re-apply the setting).

### Issue #17 (fixed in 0.1.0-17)

**[#17](https://github.com/IsaacNudeton/nsplit-linux/issues/17) — temporary files left in `/tmp`.** *Found* during the 0.1.0-16 guest test: `put` and the console login edit make a first-time
copy of every file they change, for undo, and only the undo ever removed it, so a successful `nsplit add` or `nsplit remove` left it behind (12 files after three adds and three removes in the
guest; about 71,000 files, 280 MB, from the maintainer's own off-host test runs). *Fix:* every temporary file is made by one function (`mktemp`, then registered by its exact path) or, for the
staging file beside a target that is renamed over it, registered when it is made. The exit handler undoes an interrupted add first (it still needs the copies) and then removes whatever is
registered, once; a registered file is removed only while it is still the same regular file (device and inode), and nothing else is ever removed: no glob, no directory listing, no directory removed
recursively (the generated login files are separate registered files instead of one directory). A subshell, which does not inherit the exit trap, removes what it registered when it ends. A failing
`mktemp` stops the command with a message. *Behaviour change that came with it:* before, a `SIGTERM`/`SIGHUP` during `nsplit add` was **not undone at all** (a signal leaves `$?` at 0 in an exit trap
under bash, so the undo condition was never met); now the first signal is noted, the step in progress finishes, the command ends (130/143/129) at the next safe point and undoes everything, and a second
signal ends it at once. *Found by the first guest test of this fix:* with signals acted on at once, an interrupt that arrived between a change and the registration of its undo left that change
behind (the enable symlink of the namespace sshd and an empty `/etc/nsplit/ssh`); that build was replaced. The undo of every change is now registered before the change (`put`, the console login edit, the
namespace sshd: `systemctl enable --now` can enable a unit and then fail to start it, which used to leave it enabled), and a failed first add removes the configuration directories it made.
*Tested:* off-host, 89 checks (`TMPDIR` a fresh directory, a logging `mktemp` as a positive control): a successful add and remove, a failed add that rolls back (bytes and modes restored), refusals before
any change (nothing asked for), a dry run, `TERM`/`HUP`/`INT` at five points of an add (each ends in exactly the state before the add), two signals, a second signal during the undo, a unit that is enabled
but fails to start, a first add that fails after its directory, keys and configuration exist, files that nsplit did not make (one named like its own) untouched, and the registry's own functions (unregistered
files, a replaced file, a symlink, subshells, a missing or relative or spaced `TMPDIR`). The same checks fail 55 of 89 against the unfixed code, and 21 mutants that each remove one safeguard are each
rejected by named checks (one of them was rerun alone after its patch text had gone stale). The existing suites pass unchanged: 403, 98, 46, 21, 30 and 38 checks. In the disposable guest on the real
packages: with the 0.1.0-16 package an add and a remove leave 8 files in `/tmp` and a `SIGTERM` during an add exits 143 with the profile left half applied (no undo); on the 0.1.0-17 package, upgraded in place,
the same add and remove leave nothing in `/tmp` (and nothing in a fresh `TMPDIR`; planted files, one named like nsplit's own, untouched), and `SIGTERM`, `SIGHUP` and `SIGINT` during an add exit 143, 129 and
130 after "finishing the step in progress" and "undoing 16 step(s)" with the guest's whole recorded state (tree, content hashes, units, namespaces, firewall, accounts, links) identical to before. *Not
tested:* `sudo -E` or any other way a caller's `TMPDIR` reaches a root run; a temporary directory that is not a tmpfs; two nsplit commands at once; the cleanup of the staging files after a failure between
their creation and their rename (only the registry's behaviour is checked, no failure is injected there); the DNS repair's own retained backup directory (`dns-NAME.XXXXXX` under `/var/lib/nsplit`, kept on
purpose when a repair cannot be rolled back) was not changed. One check of the guest baseline failed (the three original profiles read Degraded right after the guest booted, because its mount watcher is
off and nothing had repaired their lost mounts yet, as in [#1](https://github.com/IsaacNudeton/nsplit-linux/issues/1)); they read as before in every later phase.

### Headless profiles (0.2.0-alpha.1)

**[#13](https://github.com/IsaacNudeton/nsplit-linux/issues/13), phase 2: `nsplit add USER --mode headless`.** *What it is:* the profile's user manager (`user@UID.service`) is kept running without a login by systemd lingering, inside the profile's
namespace, and the user is reached through the profile's own OpenSSH server over their tailnet with a dedicated PAM service (the host's `sshd` stack, then the placement gate). The profile is root-managed, needs no Plasma login manager,
and switches lingering on last and off again on failure and removal; the design is described in [Usage](USAGE.md#headless-profiles---mode-headless-alpha) and [Security](../SECURITY.md).
*Found by the guest tests (each changed the product, each now has an off-host fake that reproduces it and a mutant):* (1) on systemd 262 every user manager has a logind session of its own (class `manager`, service `systemd-user`), and `nsplit
remove` counted it as a login and refused; sessions of class `manager` and `manager-early` are no longer counted (any other class, and a class that cannot be read, still are). (2) After a removal, a headless add whose `enable-linger` had
succeeded once saw no manager start for 60 seconds and ended: logind did not start it (not reproducible in isolation: six remove-and-add cycles in a row all started it; it followed a sequence of manual stops and starts of that manager);
nsplit now also asks systemd to start `user@UID.service` after switching lingering on (harmless when it is starting already). (3) The test's held login ran a command without a terminal, so after the client was killed the remote command and the
logind session survived (state *closing*, scope abandoned) and `nsplit remove` refused, correctly; `loginctl terminate-session` did not end it, `kill-session --signal=KILL` did. The refusal text of a headless profile now names the session and
`kill-session` instead of suggesting `terminate-user` (which would also end the lingering manager).
*Tested off-host:* 86 checks (a fake `systemctl`, `loginctl`, `tailscale` and `nft`, real OpenSSH reading the generated configuration with `sshd -T`): the preview and the options (nothing changes); no Plasma login manager (headless works, desktop still refuses
clearly); a fresh add (network first, lingering last, a manager inside the namespace without a login); the preflight refusals (lingering already on, a lingering directory that cannot be read, a PAM service file that nsplit did not make, no host `sshd` PAM service to include, a leftover linger record, a login session, a running manager) with nothing
changed; failed and interrupted adds undone, lingering and the manager included (a failing `enable-linger`, a manager that never starts, a failing post-apply check, a failing undo reported as unfinished); stop, start and remove (lingering that
nsplit did not switch on is never touched; a failing `disable-linger` keeps the placement); status (a manager that is missing, unplaced or unreadable is never Ready); and a desktop profile next to a headless one unchanged. The same checks fail
67 of 86 against the code without the feature (public main at 8973523), and 24 mutants that each remove one safeguard (lingering not last, `Requires=` weakened to `Requisite=`, no PAM service file, no `PAMServiceName`, the gate before the host's stack,
an undo that is not registered, a removal that keeps lingering, a status that calls an unknown placement Ready, the manager's own session counted as a login, …) are each rejected by named checks. The older suites pass unchanged on the same tree:
403, 98, 46, 21, 30, 38 and 89 checks.
*Tested in the disposable guest,* on the real package `nsplit-0.2.0alpha.1-1` (sha256 `7abbdfa9dd33fde8e493dba16a9dfe2e37b867c167ce69d566c6db62e47cb3df`, installed in place over 0.1.0-17; systemd 262.1, Tailscale 1.104.2, OpenSSH 10.6p1), against a
throwaway control server (headscale) inside a private lab network whose only routes were lab-internal, so that nothing left the machine and no real Tailscale control server was used: the upgrade (package files as built, the original profiles' daemons
not restarted); a headless add with the Plasma login manager's files moved aside (only the console login stack gated, removal in one pass, the host state identical afterwards); a headless add with them present: the manager running with no login session,
inside the profile's namespace, after the namespace, the daemon and the namespace sshd (systemd's own timestamps), the placement drop-in *requiring* the namespace and the firewall, `sshd -T` reporting the dedicated PAM service, the host's own `sshd` and
PAM files untouched; the user's node signed in to the lab, `nsplit status` Ready; a service the user enabled and started **without any login** (through the lingering manager) running in the profile's namespace and reached by a remote tailnet client, not on the
host's loopback or its ordinary interface, and reachable from a host process over the private link (documented, and warned about by the add); ordinary OpenSSH over the tailnet as the owner (the namespace, resolver file and Tailscale socket are the profile's, the
session's manager is the lingering one, the session's logind `Service` is the dedicated PAM service, SFTP works), with root, two other local accounts and a name that does not exist refused (each with a control that the same client and key get in on a plain
OpenSSH), password and keyboard-interactive authentication not offered, and port, agent and environment forwarding refused (each with the same control); the owner refused when switching the built-in Tailscale SSH on (including a full `tailscale up --ssh`),
root able to, and status reporting that as Degraded; with the namespace handle removed the manager would not start (status 226/NAMESPACE) and no process of the user was in the host's network; with the gate not executable and with the PAM service file missing the SSH
login was refused (a control each: the login works again once restored); with the placement drop-in removed by hand the manager ran in the host's network, status said Degraded naming the restart, the SSH login was refused by the gate, and a process of the user in
the host namespace could not reach the network beyond loopback; stop (the manager stops with the namespace) and start (the manager comes back after the namespace and the firewall); an add that fails at its own post-apply check after lingering was switched on, undone
completely (lingering, manager, marker, PAM service, record; the guest's whole recorded state identical to before); remove and stop refused while a login session exists; removal in one pass of a profile with a lingering manager and the user's own unit file untouched (the
guest's state identical to before the add); re-adding it; and **one real guest reboot**: the manager active and placed right after boot with no login session, after the namespace and the firewall, the user's enabled service started by itself, the node Running again
without a new sign-in, the service answering the tailnet peer, and an ordinary key login working. Four complete guest runs: the first three each found one of the issues above or a mistake of the test script, and are kept annotated; the fourth, on the final package,
ran everything including the reboot: 181 checks, 3 failed, all three failures being mistakes of the test's own closing comparison and one of its self-tests (the lab's tailnet peer left `/var/lib/tailscale` behind, which the comparison with the guest's first state
reported; PIDs recorded before the reboot were compared with the PIDs after it; and the check that no nsplit unit had failed was vacuous because of a `systemctl` argument form, which was then rebuilt with a planted failed unit proving it can reject), classified on
the real end state and rerun; every check of the product passed.
*Not tested:* more than one headless profile at a time in the guest (the off-host suite covers a desktop and a headless profile together); a real Tailscale control server; Tailscale's built-in SSH as the way in (it is refused by construction in this mode); a user who
already had lingering before the add (refused by the preflight, tested off-host only); other systemd, OpenSSH, Tailscale or kernel versions; cron or `at` jobs, system services running as the user, and `sudo -u` or `su` from another account (the UID guard's documented limit);
any GPU workload; sessions that do not end (an abandoned logind session needs `loginctl kill-session`, as the refusal says); a real workstation (nothing was installed on one); and independent review.

## Former known issues

The focused test above, and a read-only inspection, found three problems. Each is fixed in
this snapshot (0.1.0-14) and its issue is closed. **How the fixes were tested:** off-host
with fake system commands (each check suite also run against a version without the change, or
with one safeguard removed, to show that it can fail), and in the disposable guest on the
0.1.0-12 baseline package with the changed files copied over it. The -14 package built from
this repository was later installed over -12 in the guest for the Tailscale SSH test (the focused
cases below were not repeated on it), and no real workstation was part of this validation.
`--ssh openssh` and `--ssh tailscale` were each tested only as scoped above.

**[#1](https://github.com/IsaacNudeton/nsplit-linux/issues/1) — profile bind mounts
detach (fixed; one limit).** *Found:* the profile services and the user manager bind the
profile's files over `/etc/resolv.conf` and the profile's socket directory over
`/run/tailscale`. A bind mount on a file is removed in every mount namespace when the host
replaces that file by `rename`, and one on a directory when the host removes and recreates it.
Both were reproduced in the guest against an untouched control unit. After the reboot, the
host's `/etc/resolv.conf` was rewritten right after the services started (the host runs
NetworkManager with `dns=systemd-resolved`, the likely writer; its system calls were not
traced), and a session in the profile saw the host's stub resolver address and failed to
resolve names. `nsplit status` still reported the profile ready, because its resolver probe
starts a fresh process rather than inspecting the running services' mount tables. A read-only
inspection of a long-running deployment of the same design found a service and a user manager
with neither mount present, although their units declare both.

*Fix:* `nsplit status` reads each running service's mount table and the object it really sees
(a lost mount is Degraded, an unreadable view Not checked, neither is Ready). A root helper
re-attaches a missing mount into the **running** unit with `systemctl bind`, checks again, and
reports REPAIRED only if the check says so; nothing is restarted or logged out. It never
attaches a bind the unit does not declare (that is a failure, `NOT-DECLARED`), and never into a
service whose placement in the profile's network namespace it could not verify (`UNKNOWN`).
A path unit reacts to a change of the two host paths and a timer checks every 15 minutes. The
manual command is `nsplit mounts` (see [usage](USAGE.md#lost-profile-mounts)).

*Tested in the guest* (real systemd 262, NetworkManager, kernel namespaces; a throwaway
profile with a held login): a real NetworkManager rename of `/etc/resolv.conf`, and the guest's
real host `tailscaled` started, restarted, stopped (which removes the directory) and killed with
`kill -9`; detection by `status`; repair with every service PID and start time and the held login
unchanged; the watcher repairing each event by itself within seconds, bursts of events without
stacking mounts or losing the watch; a failing bind reported as FAILED with the services untouched;
a real reboot, after which the watcher re-attached the resolver mount that NetworkManager rewrote;
a service whose unit lost its declaration; and a missing, unreadable or foreign network-namespace
handle (nothing is attached). Which Tailscale socket a profile process reaches before and after
a repair was checked by endpoint selection only.

*Limits:* the repair is not instantaneous. For about 2 seconds as measured (up to 15 minutes if an
event is missed, until the safety timer), the service sees the host's `resolv.conf`, and a profile
process's default control path `/run/tailscale/tailscaled.sock` leads to the **host** daemon's
socket. What a profile user could do against the host daemon through it was not measured. A design
in which a detached mount exposes an empty path instead is not implemented. An ordinary user's
`nsplit mounts check` reports `UNKNOWN`. Not tested: other systemd versions, an in-place package
upgrade, a crash between steps; the `Ready` state was exercised off-host only. Restarting a service
also re-creates its mounts, but a logged-in user's manager cannot be restarted without ending the
session; use `sudo nsplit mounts repair` instead. To look at one service by hand (as root), a line
for a path only shows that *a* mount exists:

```sh
pid=$(systemctl show -p MainPID --value nsplit-tailscaled@PROFILE.service)
awk '$5 == "/etc/resolv.conf" || $5 == "/run/tailscale"' /proc/$pid/mountinfo
```

**[#2](https://github.com/IsaacNudeton/nsplit-linux/issues/2) — stale firewall
rules after `remove` (fixed).** *Found:* `nsplit remove PROFILE` regenerated the firewall while the
profile's record still existed, so the live ruleset kept naming its interface and
addresses until `sudo nsplit reload`. The profile's namespace was already gone in
the test, which limited the effect. The UID guard was correct. *Fix:* the firewall reads an
explicit profile list, `/etc/nsplit/firewall-profiles`, which nsplit regenerates together with the
UID guard; the profile record is still deleted last, so a failed removal can be retried. A damaged
list makes `nsplit-fw` fail before it writes or loads anything (a boot with a damaged list starts
no profile daemon: the intended fail-closed outcome). *Tested:* off-host (removal of one of two
profiles leaves none of its interface or addresses in the generated ruleset and all of the other's; an
injected reload failure keeps the profile registered and a retry finishes; eight kinds of damaged
list; last-profile removal leaves nothing) and in the guest (the unpatched code left the removed
profile named in 8 places in the live ruleset, this change in 0; the loaded ruleset equal to the
pre-enrollment one byte for byte; two real reboots, one with a damaged list). *Not tested:* a crash
between the steps of a removal (reasoned about only); an in-place upgrade of an existing installation
(off-host only).

**[#3](https://github.com/IsaacNudeton/nsplit-linux/issues/3) — key file
ownership (fixed).** *Found:* `--ssh openssh` created `/etc/nsplit/ssh/PROFILE/authorized_keys`,
recorded its exact hash as nsplit-owned and wrote a comment telling the
administrator to add keys. After that edit the first `nsplit remove` kept the file
as "changed", exited 1 and left the profile registered. Deleting the file by hand
and re-running finished the removal. *Fix:* nsplit no longer creates or records that file; the
namespace server still reads it first if an administrator creates one, and removal keeps it,
says so and exits 0. For a profile enrolled by 0.1.0-12 or -13 the ownership record is dropped
and a changed file kept in one pass; a copy that is still exactly what nsplit wrote holds no
keys and is removed. Other owned files keep the rule that a hand-edited one is never deleted.
*Tested:* off-host and in the guest (a legacy profile enrolled by the unpatched code with a key
added the documented way: one removal exits 0 and leaves the file byte-identical; a fresh profile
logs in with a key in the user's own file and in an administrator-made file; re-adding the same
name leaves it alone; an unauthorised key is still refused). *Not tested:* owner-managed profiles
only, one boot, no Tailscale sign-in, no graphical session.

**Observation: OpenSSH `PerSourcePenalties`.** OpenSSH 10 drops further connections
from an address for roughly 15 seconds after refused attempts. Every host-side login
to a namespace server arrives from the profile's single host-side link address, so
a burst of refused attempts by one host user delays all host-side logins. nsplit
does not configure this.

## What is not claimed

- `--ssh openssh` and `--ssh tailscale` were tested only as scoped above (one profile each for the
  first tests, the tailnet tests on a lab control server, not on Tailscale's).
- The fixes of the three former issues were tested as changed files over the 0.1.0-12 baseline
  package; the 0.1.0-14 package built from this repository was exercised in the Tailscale SSH test, the
  0.1.0-15 package, upgraded in place from -14, for the fixes of #7 and #8 only, and the 0.1.0-16 package,
  upgraded in place from -15, for the changes of #9 and #10 only, and the 0.1.0-17 package, upgraded in place from -16, for the change of #17 only, and the 0.2.0alpha.1 package, upgraded in place from -17, for headless profiles only. This documentation is
  not a claim that the package is ready for any particular deployment.
- A fresh `nsplit add` on the final -12 guest package, a graphical desktop run on
  that package, or an installation on the real workstation was not demonstrated
  by the final acceptance program. Earlier-version and controlled tests retain
  their own scope; a fresh-directory start is not a substitute for every add step.
- Real DNS covered one profile, one tailnet and IPv4, using only the node's own
  private name. Peer-name answers, an IPv6-only tailnet, a real suffix migration,
  sign-out/re-authentication and reboot of the authenticated node were not shown.
- The corrected held-client observer covers managed restart. The older `kill -9`
  held-client closure assertion remains unestablished; separate crash-recovery
  startup/access evidence is not the same assertion.
- Sampling is not continuous proof. The DNS file sampler did not validate every
  byte of every read, and the boot wait marker did not prove the full intended
  observation window. Historical UID/DNS one-offs remain unexplained.
- DNS counter results cover named IPv4 UDP/TCP port-53 destination groups during
  recorded trial windows, not every possible egress path or query payload.
  The optional public-server control could pass on timeout. Acceptance used the
  actual positive product output and exit statuses, not an ambiguous `ready`
  substring that also matches `NOT ready`.

These are disclosed boundaries, not a claim that every excluded scenario fails
or a demand to repeat the completed acceptance program for documentation work.

## Evidence retention

Raw logs, scripts, private inventories and VM assets are retained outside the
product repository. The reviewed package SHA256 is:

```text
79be6e335ed02531801fba031e56ddcd37877f280ae8b02ee4e9c620511d6c28
```

This identifies a specific reviewed package; it does not promise that a rebuild
will be byte-identical. Detailed archive bindings and superseded claims are in
the maintainer's private records, not in this repository. Preserve one verified copy of each cited evidence bundle,
including failed controls. Do not edit a hash-bound report to update its status;
record a dated correction or index entry instead.
