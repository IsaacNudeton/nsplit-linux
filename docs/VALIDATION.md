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

**This snapshot is 0.1.0-14.** 0.1.0-13 added the MIT license and its packaging only:
building both packages and comparing them showed the 25 installed program files
byte-identical, in content and mode, to the reviewed 0.1.0-12 package, and the only added
file was `/usr/share/licenses/nsplit/LICENSE`. **0.1.0-14 is different: it changes
runtime code** to fix the three issues under [Former known issues](#former-known-issues)
and adds one command, one helper and three systemd units for the mount watcher.
The guest tests ran on the 0.1.0-12 baseline package, and the later fixes were tested by
copying the changed files over that package (originals restored and checked afterwards).
**Neither the -13 package nor the -14 package built from this repository was itself
installed or run in the guest.**

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
| `--ssh openssh`: a separate OpenSSH server in the profile namespace (`nsplit-sshd@PROFILE.service`) | Yes | **Partly.** One focused test (below). It is not part of the reviewed acceptance baseline. |
| `--ssh tailscale`: Tailscale SSH on the profile's node (`tailscale up --ssh`) | Yes | **No.** Off-host checks covered only the flag passed to `tailscale up`. No guest profile used the option and nothing connected through it. Whether such sessions pass the login-gate configuration is unknown. |

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

Not covered: `--ssh tailscale`; a connection over the profile's tailnet; any
Tailscale sign-in; a graphical session; `kill -9`; IPv6; more than one reboot or
profile; a retest on the -13 or -14 package.

## Former known issues

The focused test above, and a read-only inspection, found three problems. Each is fixed in
this snapshot (0.1.0-14) and its issue is closed. **How the fixes were tested:** off-host
with fake system commands (each check suite also run against a version without the change, or
with one safeguard removed, to show that it can fail), and in the disposable guest on the
0.1.0-12 baseline package with the changed files copied over it. The -14 package built from
this repository was not itself installed or run in the guest, and no real workstation was part of
this validation. The scope stated above is unchanged: `--ssh tailscale` is untested, and
`--ssh openssh` only as scoped.

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

- `--ssh tailscale` was not tested, and `--ssh openssh` only as scoped above.
- The 0.1.0-14 package built from this repository was not installed or run in the guest; the fixes
  were tested as changed files over the 0.1.0-12 baseline package. This documentation is not a claim
  that the package is ready for any particular deployment.
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
