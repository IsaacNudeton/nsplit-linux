# Build and use nsplit

[Overview](../README.md) · [Security boundaries](../SECURITY.md) · [Validation](VALIDATION.md)

## Before installing

Use a disposable VM first, with an administrator account that will not be
enrolled. Keep a separate recovery console. The current enrollment checks require
systemd and the Plasma login manager's vendor PAM file (`plasmalogin`). Do not
replace your login manager or bypass a failed preflight just to make nsplit run.

The Arch package declares these dependencies:

```text
bash iproute2 nftables python tailscale dnsmasq bind util-linux systemd pam dbus acl
```

Install normal Arch build tooling as appropriate for the test machine. `sudo`
and a valid sudoers setup are needed for owner-managed sign-in without an
administrator. OpenSSH is needed only for `--ssh openssh`; ufw integration is
used when ufw is active. The included NetworkManager hook handles uplink events.

The socket helper requires the existing `fs.protected_hardlinks` setting to be
`1`. Inspect it with `sysctl fs.protected_hardlinks`. Nsplit does not change that
setting for you. Resolve a failed prerequisite with the machine administrator;
do not weaken the check.

## Build the packaged snapshot

This repository began as a single-commit snapshot of nsplit 0.1.0-13 and is now
nsplit **0.2.0-alpha.3** (an alpha: see below). The reviewed runtime baseline, 0.1.0-12, is described in
[VALIDATION.md](VALIDATION.md); the 0.1.0-13 package differed from it only by the added
MIT license text, 0.1.0-14 adds the fixes for issues #1 to #3 (see
[former known issues](VALIDATION.md#former-known-issues)), 0.1.0-15 the fixes for
#7 and #8 (see [validation](VALIDATION.md#defects-7-and-8-fixed-in-010-15)), 0.1.0-16 the
fixes for #9 and #10 (see [validation](VALIDATION.md#defect-10-fixed-in-010-16)), and 0.1.0-17 the
fix for #17, the temporary files (see [validation](VALIDATION.md#issue-17-fixed-in-0110-17)). **0.2.0-alpha.1 adds headless profiles**, **0.2.0-alpha.2 the optional host-SSH denial** and **0.2.0-alpha.3 the shared-GPU setup command**, new features that have had no independent review (see
[validation](VALIDATION.md#headless-profiles-020-alpha1), [validation](VALIDATION.md#host-ssh-denial-020-alpha2) and [validation](VALIDATION.md#shared-gpu-setup-020-alpha3)); pacman versions cannot contain a hyphen, so the package is called `0.2.0alpha.3` (it sorts after 0.2.0alpha.2, 0.2.0alpha.1 and 0.1.0-17 and before 0.2.0).
The following creates a source checkout on a new evaluation machine. For an
existing development checkout, use that checkout rather than creating duplicates.

```sh
git clone https://github.com/IsaacNudeton/nsplit-linux.git
cd nsplit-linux
make check
make dist
cp nsplit-0.2.0alpha.3.tar.gz packaging/arch/
(cd packaging/arch && makepkg --syncdeps)
```

Run `makepkg` as an ordinary user. `make check` performs **syntax checks only**;
it does not run the external acceptance suites. `make dist` contains the build
and runtime inputs, not these repository guides. The recipe consumes the local
source archive and currently uses `sha256sums=(SKIP)`; that is not independent
verification of an arbitrary downloaded archive.

Install only the package you just built, in the evaluation VM:

```sh
sudo pacman -U packaging/arch/nsplit-0.2.0alpha.3-1-any.pkg.tar.zst
pacman -Q nsplit
nsplit --version
```

Pacman shows the package revision; `nsplit --version` shows the upstream version
`0.1.0`. Nsplit's `make install` copies its files and does not enroll users.
Dependency installation and distribution hooks may have their own side effects.

## Enroll an existing test account

The examples use an existing account named `demo`. Log it out completely and
stop its user manager before applying enrollment. Nsplit refuses an account
with a detected login or running user manager. It cannot discover every cron
job, system service or process started through `su`/`sudo -u`; those processes
are not automatically moved into the new namespace and can lose host-network
access when the UID guard is loaded.

From a separate administrator account:

```sh
sudo nsplit add demo --dry-run
sudo nsplit add demo
```

Read the preview and confirmation. Enrollment manages profile configuration,
network namespaces, service units, firewall/UID-guard rules, user-manager
placement, login-gate configuration, D-Bus policy and, for owner-managed profiles,
a scoped sudo rule. It is not just a change to a single user's dotfiles.

Useful enrollment options are `--name NAME`, `--hostname NAME`, `--root-managed`,
`--ssh none|openssh|tailscale`, `--accept-tailscale-ssh-risk` (required by `--ssh tailscale`, refused with the other modes)
and `--uplinks "IFACE IFACE"` for the first profile.
Profile names are 1–12 lowercase letters/digits/underscores/hyphens and begin
with a letter. `nsplit add --help` describes the options. SSH defaults to `none`.
`--ssh openssh` had two focused guest tests and `--ssh tailscale` one (see
[validation](VALIDATION.md)); try both only on a disposable machine.

**`--ssh tailscale` is an advanced mode governed from outside this machine** (`--ssh openssh` is the
recommended remote shell). The profile's node is signed in with the user's own Tailscale account, so
that account's SSH policy, not nsplit, decides which local accounts a session can become on this
machine. In the test, a rule allowing non-root users reached another enrolled user and the
administrator account, and a rule listing `root` gave a root session that can leave the profile
namespace. `--ssh openssh` pins the server to the profile's own user instead. Since 0.1.0-16
`nsplit add --ssh tailscale` is refused without `--accept-tailscale-ssh-risk` (`--yes` does not stand
in for it): by giving it you accept that the policy may authorize other local accounts or root, that
nsplit can neither read nor limit it, and that nsplit's login gate is not part of these sessions. The
preview, the final output of `nsplit add`, `nsplit login` and `nsplit status` repeat that. If you use
the mode, have the `users` list of that account's SSH rule name only the profile's own login (tested
to restrict it); that is advice about a policy nsplit does not control, not something it enforces.

With `--ssh none` or `--ssh openssh` Tailscale's built-in SSH server is only switched **off** when
the node is signed in. On an owner-managed profile the user is the node's Tailscale operator and can
switch it on later (`tailscale set --ssh`), so `nsplit status` reads the node's real setting and shows
the profile as Degraded, with the command that turns it off, when it is on although the profile says
`none` or `openssh`; a setting it cannot read is `Not checked`. On a root-managed profile the profile's
user was refused when they tried to switch it on (one profile, Tailscale 1.104.2, measured), and an
administrator can switch it on; status reports that the same way.
Desktop enrollment (the default, `--mode desktop`) still requires the Plasma login manager whichever SSH mode you choose; a headless profile (`--mode headless`, below) does not.
Use an explicit generic hostname when you do not want the default machine-derived
name to appear in the tailnet.

### Interrupting `nsplit add`, and temporary files

`nsplit add` changes many things and undoes all of them if a step or a check fails. Since 0.1.0-17 the same holds for an interrupt:
the first Ctrl-C (`SIGINT`), `SIGTERM` or `SIGHUP` while it is applying changes is noted, the step in progress finishes (so that
every change already has its undo registered), and the command then ends with status 130, 143 or 129 after undoing everything; it
says so ("finishing the step in progress, then undoing"). A second signal ends it at once and still undoes what is registered by then.
`SIGKILL` and a power loss cannot be handled. Outside an apply (a preview, `status`, `stop` and the rest) a signal ends the command as it
always did.

nsplit keeps no temporary file after it ends: the copies it makes for undo (and the generated login files and the sudoers check copy) are
registered by their exact path when they are made and removed when the command ends; nothing else in the temporary directory is touched.
They are made in `$TMPDIR` (`/tmp` when it is unset; `sudo` normally resets it).

### Reaching the namespace OpenSSH server over the profile's tailnet

With `--ssh openssh` the server listens on port 22 inside the profile's namespace, so once the profile's node is
signed in it answers on the profile's Tailscale address, from the nodes of that tailnet that its own rules allow (nsplit
does not manage the tailnet's access rules). It accepts exactly the profile's user, public keys only, no root login,
no passwords, and no forwarding of ports, agents or client environment. Put the user's public key in their own
`~/.ssh/authorized_keys` (the user needs nothing from an administrator) or in the root-managed file
`/etc/nsplit/ssh/PROFILE/authorized_keys`, which nsplit never creates or deletes. Pin the server's host key
(`/etc/nsplit/ssh/PROFILE/ssh_host_ed25519_key.pub`) in the client's `known_hosts`. Two behaviours to expect:
OpenSSH 10 resets new connections from an address that has just failed several logins, for a while; and a service
started inside the profile that listens on all addresses is reachable over the tailnet **and** from the host
namespace over the profile's private link, by any process of the host.

## Headless profiles (`--mode headless`, alpha)

For a computer where users need a private network but no desktop: for example one shared GPU machine whose users run their own services, each in their own network and each reached only over their own
tailnet. The user's systemd service manager (`user@UID.service`) stays running **without any login**, inside the profile's network namespace, so the user's own `systemctl --user` services start at boot, keep running
after the user logs out, and run in the profile's network. This is an alpha feature (0.2.0-alpha.1): read what was and was not tested in [validation](VALIDATION.md#headless-profiles-020-alpha1).

```sh
sudo nsplit add alice --mode headless      # --ssh openssh and root-managed are implied; no Plasma login manager is needed
sudo nsplit login alice                    # an administrator runs it; alice opens the link it prints and approves with her own Tailscale account
# alice puts her public key in ~/.ssh/authorized_keys (or an administrator in /etc/nsplit/ssh/alice/authorized_keys), then, from a node of her tailnet:
ssh alice@<the profile's Tailscale address or name>
systemctl --user enable --now my-service.service   # in that session: it starts at boot, survives logouts, runs in her network
```

What the mode does, and requires:

- **Always `--ssh openssh` and root-managed.** The namespace OpenSSH server is how the user is reached; Tailscale's built-in SSH stays off. The user is not the node's Tailscale operator, so (in the one
  profile and Tailscale version measured) they cannot switch the built-in SSH on; `nsplit status` reports it if an administrator does. `--ssh none`, `--ssh tailscale` and `--accept-tailscale-ssh-risk` are refused with it.
- **A dedicated PAM service for the namespace sshd.** The profile's sshd is configured with `PAMServiceName nsplit-sshd-NAME` (checked with `sshd -T` when it is added): the host's own `sshd` stack, unchanged,
  then nsplit's placement gate after `pam_systemd`. A login is accepted only when the user's manager is active **and inside the profile's namespace**. Nothing is added to the host's `sshd`, `login` or `plasmalogin`
  PAM files for this (the console login stack still gets the same gate lines as for every profile, and the graphical one only when it exists).
- **Fail-closed at boot.** systemd-logind starts a lingering manager by itself, so the placement drop-in *requires* the profile's namespace and the firewall (systemd brings them up first and stops the manager with them) and
  wants the daemon and the sshd; if the namespace cannot be joined the manager fails to start instead of running in the host's network.
- **Lingering is switched on last** (`loginctl enable-linger`, after the network, firewall, daemon, placement, namespace sshd and login gate are in place) and recorded as nsplit's own. The preflight **refuses a user who
  already has lingering enabled**. A failed or interrupted add, and `nsplit remove`, switch it off again and stop the manager, after checking that the user has no login session; lingering nsplit did not switch on is never touched.
- **`stop`, `start`, `remove`.** For a headless profile only a *login session* (SSH, console, graphical) counts as "logged in"; the manager's own logind session does not. `nsplit stop` stops the manager first (lingering stays
  on; `nsplit start` brings the manager back last). `nsplit remove` refuses while a session exists; otherwise it stops the manager, switches nsplit's lingering off, removes the placement and the rest in one pass, and leaves the
  account, its home and its own unit files alone. If lingering cannot be switched off the placement stays and the removal is reported as unfinished (the same command finishes it).
- **`nsplit status`** shows the mode, whether lingering is on and whose doing it is, the manager's placement, the namespace sshd and its PAM service; a manager that is not running, not inside the namespace, or whose
  placement cannot be read is **not Ready** (no later login would place it), and an unplaced manager is a Degraded security finding shown first.
- **A service the user runs that listens on all addresses** (`0.0.0.0`) inside the profile is reachable from the tailnet **and**, over the profile's private link, from any process on this machine. The add says so. Bind such a service
  to the profile's tailnet address if that matters; nothing in this release restricts it.
- The host's own `sshd` is **unchanged**: an enrolled headless user can still log in there and gets a shell in the host's network namespace (the UID guard keeps it off the network). Refusing them there is a separate,
  optional policy that this release does not include.

## Refusing enrolled users at the host's own sshd (`--host-ssh deny`, alpha)

By default an enrolled user can still log in to this machine through the host's ordinary `sshd`, and a shell from there runs in the **host's** network namespace: the UID guard keeps it off the network
beyond loopback, but it sees local files, loopback and unix sockets. For a headless profile you may want the user to come in only through their own profile's OpenSSH server over their tailnet. This
**optional** policy (never the default) refuses the profile's user at the host's `sshd`. It is an alpha feature (0.2.0-alpha.2): read what was and was not tested in
[validation](VALIDATION.md#host-ssh-denial-020-alpha2).

```sh
# keep an authenticated SSH session of the recovery account open in another terminal, then:
sudo nsplit add alice --mode headless --host-ssh deny --recovery-user admin
sudo nsplit host-ssh deny bob --recovery-user admin     # a profile that already exists
sudo nsplit host-ssh allow bob                          # take it away again
sudo nsplit host-ssh status                             # what is configured, and what sshd -T says now
```

- **What it writes:** one drop-in, `/etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf`, with `DenyUsers` for every profile that has the policy (it is generated from the profiles' records, so it cannot disagree with
  them), and only when the host's `sshd_config` includes that directory; otherwise nsplit refuses and says so. The main `sshd_config`, the host keys, PAM, the firewall, Tailscale and sshd's service definition are never
  touched, a drop-in of that name that nsplit did not write (or that was changed since) is never overwritten or removed, and the directory itself is never removed.
- **A recovery account is mandatory.** It is an existing account that is not enrolled in nsplit, not denied elsewhere, with a login shell and a home directory, not expired, and that the host's `sshd` lets in
  **as configured now** (judged with `sshd -T`: an authorized key it accepts, or an allowed password; the host must not demand more than one authentication method). nsplit cannot prove that the account's
  owner still holds the key, so **an authenticated SSH session of that account must be open while the policy is applied**: the command refuses unless one exists (`--no-session-check` overrides this, on your own
  responsibility). One policy has one recovery account.
- **Checked before anything takes effect:** the whole configuration with `sshd -t`, and the effective result for every denied user and for the recovery account with `sshd -T`. sshd is then **reloaded**, never
  restarted, so open sessions stay. Any failure, and any interrupt, leaves the previous policy in force (an add is undone completely; `deny` and `allow` put the record, the drop-in and sshd's view back).
- **Removing** a profile takes its user off the list; when no profile has the policy any more the drop-in is removed and sshd reloads.
- **Status** (`nsplit status`, `nsplit host-ssh status`) shows whether the policy is configured, whether the drop-in is exactly what nsplit wrote, and what `sshd -T` says now. A setting that cannot be read is
  `UNKNOWN` and is never reported as enforced; a drop-in that is missing or changed is a Degraded security finding. Reading `sshd -T` needs administrator rights.
- **If you are locked out:** use the held recovery session, or the console, and run `sudo nsplit host-ssh allow PROFILE` (or `sudo nsplit remove PROFILE`). With nsplit gone from the picture, deleting
  `/etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf` and reloading sshd (`sudo systemctl reload sshd`) does the same.
- **What it does not do:** it does not restrict any other way in (cron or `at` jobs, services running as the user, `su` or `sudo -u` from another account), it does not change the profile's own OpenSSH server
  (which never carries `DenyUsers` and does not include the host's drop-in directory), and it does not decide who the recovery account's owner is.

## Setting up a shared machine in one command (`nsplit setup --preset shared-gpu`, alpha)

For a computer that several people share for GPU work, one command does what `nsplit add USER --mode headless` (and, with a recovery account, `--host-ssh deny`) does, user after user: every user gets their own
network namespace, Tailscale node and DNS, their own `systemctl --user` services run in it across logouts and reboots, and they are reached only through their own OpenSSH server over their own tailnet. It is a thin
frontend: it runs those `nsplit add` commands, one separate process per user, and adds nothing of its own to what they do. It is an alpha feature (0.2.0-alpha.3): read what was and was not tested in
[validation](VALIDATION.md#shared-gpu-setup-020-alpha3), and see [a walkthrough with real output](DEMO.md).

```sh
sudo nsplit setup --preset shared-gpu --dry-run alice bob                          # the plan and what each add would change; nothing is changed
sudo nsplit setup --preset shared-gpu alice bob                                    # asks once, then sets both up (--yes skips the question)
sudo nsplit setup --preset shared-gpu --recovery-user admin alice bob              # also refuses them at the host's own sshd (keep a session of admin open, see above)
sudo nsplit setup --preset shared-gpu alice=gpu-alice bob                          # USER=NAME names the profile (as `nsplit add USER --name NAME`)
```

- **Checked before anything changes, for the whole call:** every user exists, is named once, is not logged in or running a user manager, is not already set up another way (a profile that is not a headless one is
  refused with the way out; one that is already headless is skipped), the profile names are free, and, with `--recovery-user`, the recovery account and its held SSH session (the checks of `nsplit add --host-ssh deny`).
  Then each add is previewed with `--dry-run`, so a problem that only the add can see (an address pool, a port, a unit, a name) is found before the first change.
- **It stops at the first user whose add fails** (that add undoes itself) and says who is done, who failed and who was not attempted. Running the same command again skips the users that are already set up and finishes the rest.
- **The GPU:** it reports which `/dev/nvidia*` and `/dev/dri` devices it sees and which of the users' groups (`video`, `render`) give device access, and changes none of it. It does not install or configure a driver or
  CUDA, change device permissions or group membership, sign anybody in (an administrator runs `sudo nsplit login NAME` for each, and the user approves their own link) or put anybody's SSH key anywhere.

## Sign in and verify

In the enrolled owner's intended session:

```sh
nsplit login demo
```

Approve the displayed link in the intended Tailscale account. This registers
that profile's node in that account; do not put the link or resulting node details
in public logs. For a root-managed profile, an administrator runs
`sudo nsplit login demo` instead.

Login reports registration, operator policy and network readiness separately.
It performs fresh public/private DNS checks even when split DNS is already
configured. Repeating it for an already-running node rechecks networking rather
than inherently requesting another browser approval. Authentication state can
still require a new approval; never reset node identities merely to repeat a test.

```sh
nsplit status -v demo
sudo nsplit status -v demo
```

Status is read-only. It also reads the mount tables of the running services (see [Lost profile mounts](#lost-profile-mounts)) and the node's real built-in Tailscale SSH setting (see above). An ordinary user can see `UNKNOWN` or `Not checked` because
some observations require administrator rights. This does not itself mean that
the profile is broken, and it does not justify granting broader sudo access.

| Command | Exit codes relevant to normal operation |
| --- | --- |
| `login` | `0`: registration/operator/network checks succeeded; `1`: sign-in or an earlier check refused/failed; `3`: registered but operator/network completion failed |
| `status` | `0`: shown profiles are ready, or none exist; `2`: a checked profile is not ready; `3`: no checked profile is non-ready, but some checks are unavailable |

For a refused graphical login, inspect `sudo nsplit status -v demo` and
`sudo journalctl -t nsplit-pam-gate`. The graphical screen may reset without
showing the reason. The console path has different placement behavior; see
[SECURITY.md](../SECURITY.md).

## Routine administration

| Command | Effect |
| --- | --- |
| `sudo nsplit run demo -- COMMAND...` | Run a command as the profile user in its managed network/resolver view |
| `nsplit ts demo status` | Address the profile's Tailscale socket, subject to its operator/access policy |
| `sudo nsplit start demo` | Start managed networking; selectively restart a daemon whose current socket protections need repair |
| `sudo nsplit stop demo` | Stop managed networking; refuses a busy/unknown user unless explicitly forced. Reports "stopped" only after checking that every unit is down and the namespace is gone |
| `nsplit uplinks` | Show configured and discovered physical uplinks |
| `sudo nsplit uplinks --set "IFACE IFACE"` | Set existing uplinks and reload rules; substitute actual interface names. The ufw route rules of an uplink that leaves the list are deleted first; if that fails nothing is changed |
| `sudo nsplit reload` | Reapply managed firewall/forwarding configuration while the firewall is running |
| `sudo nsplit mounts [check\|repair] [demo]` | Check, or re-attach, the profile's private `/etc/resolv.conf` and `/run/tailscale` in its **running** services (see below) |

Stopping a namespace ends processes inside it. Repairing an unsafe active socket
can interrupt that profile's connections, including SSH. `start --all` and
`stop --all` affect all profiles; they are not harmless diagnostic commands.

**Stopping with a Tailscale SSH session open.** `nsplit stop` and `nsplit remove` refuse while the
profile's user has a login session or a running user manager. A shell left behind by an abruptly
closed Tailscale SSH connection counts: Tailscale 1.104.2 leaves the remote login shell running
when the client dies. If nobody is really using the account, an administrator can end every
process of that user with `loginctl terminate-user USER` (the refusal names it; nsplit never runs
it) and then repeat the command. `nsplit stop --force` ends the session by stopping the profile.
With a Tailscale SSH session open the profile's Tailscale daemon does not exit within systemd's
stop time-out (10 s) and is killed, which leaves its unit `failed` (also on a node without nsplit).
nsplit accepts that one state, and only that one, when systemctl succeeded, the unit's result is a
time-out, no process of the unit is left, and the namespace and every other unit of the profile are
down; it then clears the failed state, prints a warning that the stop was not graceful, and exits 0.
A surviving process or namespace, any other failure, or a state it cannot read or clear is still
reported as not stopped, exit 1.

After a package upgrade, installing files alone does not repair an already-open
socket or close existing clients. Schedule affected profile starts/restarts and
verify status. After **known prior exposure**, explicitly restart the affected
`nsplit-tailscaled@PROFILE.service`: a current link count of one cannot reveal
an older connected client. Do not modify permissions by hand and assume that
connections have been revoked.

## Lost profile mounts

A profile's running services (its Tailscale daemon, its namespace SSH server when
enabled, and the user's session manager) see the profile's own `/etc/resolv.conf` and
`/run/tailscale` through bind mounts. A bind mount belongs to the file or directory
it was made on. If the host replaces that file (NetworkManager rewrites
`/etc/resolv.conf`) or recreates that directory (the host's `tailscaled` is stopped,
started or restarted), services that were already running lose the mount and
silently see the host's version, while their units still say `active`. A fresh
process still looks correct, so only the running services' own mount tables show it.

`nsplit status` reads those mount tables. A lost mount makes the profile
**Degraded** (it is not hidden behind `Needs sign-in`); a view that cannot be read
makes it **Not checked**. Neither is `Ready`.

nsplit also repairs this by itself. `nsplit-mounts.path` reacts to a change of
`/etc/resolv.conf` or `/run/tailscale`, `nsplit-mounts.timer` checks again 2 minutes
after boot and then every 15 minutes as a safety net, and `sudo nsplit start` checks
too. A missing mount is re-attached into the **running** service with
`systemctl bind`; nothing is restarted and nobody is logged out. Every repair is
checked again and is only reported as `REPAIRED` if the check afterwards says
`MATCH`.

```sh
sudo nsplit mounts check          # all profiles; MATCH, MISMATCH (lost) or UNKNOWN per service and path
sudo nsplit mounts repair demo    # re-attach now, for one profile
```

Exit status: `0` everything matches (or was repaired); `2` a mount is missing or a
repair failed; `3` something could not be read. What a running service sees can only
be read as root, so an ordinary user's `nsplit mounts check` reports `UNKNOWN`.

Limits to know about:

- Between the host event and the repair (normally a few seconds) the service still
  sees the host's files, and two things follow:
  - **Names** are looked up through the host's `resolv.conf`. nsplit's firewall already
    drops traffic from a profile's namespace to private address ranges, so a host resolver
    on a private address or the `127.0.0.53` stub cannot be reached; a host `resolv.conf`
    that lists a **public** resolver could be asked about profile-private names.
  - **The Tailscale control path** `/run/tailscale/tailscaled.sock`, which a profile
    process uses by default, resolves to the **host** daemon's socket instead of the
    profile's. What a profile user could do against the host daemon through it is decided by
    Tailscale's own operator and peer-credential checks and has not been measured; the
    separation the profile is meant to give is broken for as long as the mount is gone.
- A running service whose own unit definition no longer declares one of these binds (for
  example after an unreviewed edit of a drop-in) is reported as `NOT-DECLARED`: that makes
  the profile Degraded and the command exit 2. nsplit never attaches a bind that the
  unit does not declare, and never attaches anything to a user manager or service that is
  not inside the profile's network namespace. If that placement cannot be verified (the
  profile's namespace under `/run/netns` or the service's own namespace cannot be read), the
  service is reported `UNKNOWN` and nothing is attached to it, even where a mount is missing.
- A package upgrade installs the watcher units but does not switch them on; the next
  `nsplit add`, `nsplit remove` or `nsplit start` does (it is switched off again when
  the last profile is removed).
- If the host's `tailscaled` is stopped, systemd removes `/run/tailscale`; the repair then first creates it empty (root, mode 755) so there is a mountpoint to attach to.
- Only the three services above are covered, and only these two mounts. The repair
  changes no DNS or Tailscale setting and no authentication.
- If a repair cannot be completed it is reported as `FAILED`, the service keeps
  running, `nsplit status` keeps showing the profile as not ready, and
  `nsplit-mounts.service` exits with status 2 (systemd reports that as a failed unit).

## Remove a profile, not its user

With the account fully logged out:

```sh
sudo nsplit remove demo --dry-run
sudo nsplit remove demo
```

Removal regenerates the firewall without the removed profile, so its rules are gone
from the live ruleset when `remove` finishes ([#2](https://github.com/IsaacNudeton/nsplit-linux/issues/2)).
The firewall reads the profiles it forwards for from `/etc/nsplit/firewall-profiles`,
which nsplit regenerates together with the UID guard. If that file is damaged (an entry
that is not a profile name, a repeated name, a name without a readable record, an empty
list while records exist), `nsplit-fw` exits without loading anything and says so. At boot
that means no profile daemon starts until the list is repaired; to recover, repair the
file or delete it so that every profile record is used, then run `sudo nsplit reload`.
An installation from before this change has no list and keeps working from the profile
records until its next `add` or `remove` writes one.

A root-managed key file for the namespace OpenSSH server
(`/etc/nsplit/ssh/PROFILE/authorized_keys`) is the administrator's: nsplit does not create
it, never deletes it, and reports it as kept; that is not an error
([#3](https://github.com/IsaacNudeton/nsplit-linux/issues/3)). A profile enrolled by
0.1.0-12 or -13 has such a file recorded as nsplit's own: if keys were added to it, removal
keeps it; if it is still exactly what nsplit wrote (it holds no keys), removal deletes it
with the rest.

Removal takes away the managed profile configuration, not the local account or
home directory. Files changed outside nsplit are kept and reported rather than
silently overwritten/deleted; unresolved removal can be retried after the cause
is addressed. Ownership and recovery records are not ordinary build clutter.

By default, node state in `/var/lib/tailscale-PROFILE` is retained. `--purge`
deletes that local state and is a separate destructive choice. Local removal is
not deletion of the device entry in the Tailscale account. Do not remove node
state or account registrations merely to tidy a source directory.
