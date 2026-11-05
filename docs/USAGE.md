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

This repository is a single-commit snapshot of nsplit **0.1.0-13**. The reviewed
runtime baseline, 0.1.0-12, is described in [VALIDATION.md](VALIDATION.md); the
0.1.0-13 package differs from it only by the added MIT license text.
The following creates a source checkout on a new evaluation machine. For an
existing development checkout, use that checkout rather than creating duplicates.

```sh
git clone https://github.com/IsaacNudeton/nsplit-linux.git
cd nsplit-linux
make check
make dist
cp nsplit-0.1.0.tar.gz packaging/arch/
(cd packaging/arch && makepkg --syncdeps)
```

Run `makepkg` as an ordinary user. `make check` performs **syntax checks only**;
it does not run the external acceptance suites. `make dist` contains the build
and runtime inputs, not these repository guides. The recipe consumes the local
source archive and currently uses `sha256sums=(SKIP)`; that is not independent
verification of an arbitrary downloaded archive.

Install only the package you just built, in the evaluation VM:

```sh
sudo pacman -U packaging/arch/nsplit-0.1.0-13-any.pkg.tar.zst
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
`--ssh none|tailscale|openssh`, and `--uplinks "IFACE IFACE"` for the first profile.
Profile names are 1–12 lowercase letters/digits/underscores/hyphens and begin
with a letter. `nsplit add --help` describes the options. SSH defaults to `none`.
`--ssh openssh` had one focused guest test and `--ssh tailscale` has **not been
validated in a guest** (see [validation](VALIDATION.md)); try both only on a
disposable machine.
Enrollment still requires the Plasma login manager whichever mode you choose.
Use an explicit generic hostname when you do not want the default machine-derived
name to appear in the tailnet.

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

Status is read-only. It also reads the mount tables of the running services (see [Lost profile mounts](#lost-profile-mounts)). An ordinary user can see `UNKNOWN` or `Not checked` because
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
| `sudo nsplit stop demo` | Stop managed networking; refuses a busy/unknown user unless explicitly forced |
| `nsplit uplinks` | Show configured and discovered physical uplinks |
| `sudo nsplit uplinks --set "IFACE IFACE"` | Set existing uplinks and reload rules; substitute actual interface names |
| `sudo nsplit reload` | Reapply managed firewall/forwarding configuration while the firewall is running |
| `sudo nsplit mounts [check\|repair] [demo]` | Check, or re-attach, the profile's private `/etc/resolv.conf` and `/run/tailscale` in its **running** services (see below) |

Stopping a namespace ends processes inside it. Repairing an unsafe active socket
can interrupt that profile's connections, including SSH. `start --all` and
`stop --all` affect all profiles; they are not harmless diagnostic commands.

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

Known issues affect removal while they are open: the live firewall can keep the
removed profile's rules until `sudo nsplit reload` ([#2](https://github.com/IsaacNudeton/nsplit-linux/issues/2)),
and a key file you edited under `/etc/nsplit/ssh/PROFILE/` makes the first removal
exit 1 ([#3](https://github.com/IsaacNudeton/nsplit-linux/issues/3)): keep a copy
of the keys, delete that file and run the removal again.

Removal takes away the managed profile configuration, not the local account or
home directory. Files changed outside nsplit are kept and reported rather than
silently overwritten/deleted; unresolved removal can be retried after the cause
is addressed. Ownership and recovery records are not ordinary build clutter.

By default, node state in `/var/lib/tailscale-PROFILE` is retained. `--purge`
deletes that local state and is a separate destructive choice. Local removal is
not deletion of the device entry in the Tailscale account. Do not remove node
state or account registrations merely to tidy a source directory.
