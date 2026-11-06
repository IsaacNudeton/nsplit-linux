# nsplit

**Separate Tailscale networking for selected users on one Linux computer.**

A shared computer normally has one host network and one host Tailscale daemon.
Nsplit gives each enrolled local account a network namespace, its own Tailscale
node and a profile-specific DNS resolver. Users can join different tailnets
without switching the host's Tailscale account.

**Status: experimental, with a reviewed 0.1.0-12 baseline.** The scoped acceptance
work is complete; this is not a claim of general Linux compatibility or a
production deployment certification. Start in a disposable virtual machine.
See [validation and limits](docs/VALIDATION.md).

## What it does

- Places an enrolled account's systemd user manager and programs started from it
  in that profile's network namespace.
- Runs a separate Tailscale daemon with its own state and control socket. A
  profile can be owner-managed or administrator-managed.
- After sign-in, routes `ts.net` DNS names through that profile's Tailscale
  resolver and other names through configured public resolvers.
- Reports observed failures separately from checks it cannot perform, and
  repairs eligible managed DNS configuration through the existing login command.

Ordinary internet traffic uses permitted physical uplinks. This is **not** an
all-traffic Tailscale exit-node configuration, anonymity tool or complete
application sandbox. Console and host-SSH shells are not automatically placed
in the profile namespace; read the [security boundaries](SECURITY.md).

## When should I use this instead of node sharing?

Nsplit is heavier than the alternatives. Use the simplest one that meets the need.

| You need | Likely fit |
| --- | --- |
| People in another tailnet to reach a service on one machine | Tailscale **node sharing**. The machine stays one node in one tailnet and is shared with the other. It does not give each local account its own node identity, DNS or listening-port space. |
| Two Tailscale identities on one machine, and you are happy to build and maintain the plumbing | Two `tailscaled` daemons you manage yourself (separate state and control sockets, usually separate network namespaces or containers). |
| Several local accounts on one machine, each with its own Tailscale node, tailnet, DNS and network namespace, applied at login | **nsplit**, within its [tested scope](docs/VALIDATION.md). It automates a version of the previous row for local accounts, with login-time placement, DNS and firewall checks, status and removal. |

Nsplit is probably not for you if you only need to reach one shared service, if
the machine has no Plasma login manager (see below), or if you need an exit node,
anonymity or a full application sandbox.

## Intended environment

The implemented integration targets Arch-family Linux, exercised in a CachyOS
virtual machine, with systemd, nftables, Tailscale, dnsmasq and the **Plasma login
manager (`plasmalogin`)**. KDE alone is not sufficient: other display managers
are not supported by the current enrollment checks. Enrollment requires the
Plasma login manager's PAM configuration whichever `--ssh` mode is chosen, so
nsplit does not yet fit a headless server without it. The repository also
includes a NetworkManager dispatcher hook and optional ufw integration.

## Remote shell options and former known issues

Enrollment accepts `--ssh none` (the default), `--ssh openssh` (a separate
OpenSSH server inside the profile's namespace; the recommended remote shell) and
`--ssh tailscale` (Tailscale's own SSH server on the profile's node; an advanced mode that
needs `--accept-tailscale-ssh-risk`).

- **`--ssh openssh` has had one focused guest test, not an acceptance program.**
  One throwaway profile on the reviewed baseline package: public-key login over
  the profile's private link, the session's user, namespace and Tailscale-socket
  view, refusal of root and of other accounts, forwarding refused, one reboot, and
  removal. It also found three problems, fixed in this snapshot (below). A second focused test
  (2026-11-06, 0.1.0-16, one profile on a throwaway lab tailnet) connected with ordinary OpenSSH to the
  profile's **Tailscale address**: login as the profile's user in the profile's namespace, resolver and
  Tailscale socket, with its user manager placed in the namespace; refusal of root, another enrolled user,
  the administrator account, an unauthorised key, passwords, forwarding, agent forwarding and client
  environment variables, each against a control; a user service started from the session answering on the
  profile's tailnet address; and the same after a daemon restart, `nsplit stop`/`start` and a reboot. See
  [validation](docs/VALIDATION.md#focused---ssh-openssh-test-over-the-profiles-tailnet-2026-11-06-phase-1-of-13)
  for what it did not cover. Neither test covered a graphical session.
- **`--ssh tailscale` is an advanced mode governed from outside this machine. It has had one
  focused guest test on a throwaway lab tailnet, and it does not carry the protections of
  `--ssh openssh`.** Since 0.1.0-16 `nsplit add --ssh tailscale` is refused unless
  `--accept-tailscale-ssh-risk` is given (`--yes` does not stand in for it); the preview, the final
  output and `nsplit status` print the boundary below, and `nsplit status` reads the node's real
  built-in SSH setting. The test used one throwaway profile, the 0.1.0-14
  package, a self-hosted headscale control server in the guest and a second Tailscale node as
  the client (no Tailscale account, nothing on the public internet). Sessions ran in the
  profile's network namespace with the profile's resolver and Tailscale socket and survived a
  daemon restart, `nsplit stop` and `start`, and a reboot. **But Tailscale, not nsplit, decides
  which local account a session becomes** (the client logged in as another enrolled user and as
  the administrator account under a policy that allows non-root users, and as root under one that
  lists root), the PAM login gate is not in the paths Tailscale SSH uses, and the profile user can
  switch Tailscale SSH on and off on an owner-managed node (on a root-managed profile that user was
  refused in the 0.1.0-16 test). nsplit can neither read nor limit the tailnet policy, so this is a
  boundary to accept, not one nsplit enforces. Read [#9](https://github.com/IsaacNudeton/nsplit-linux/issues/9) and
  [validation](docs/VALIDATION.md#focused---ssh-tailscale-test-2026-11-0506) before using it.
- The host's own SSH server is not changed by nsplit and is not a way into a profile.

See [validation and limits](docs/VALIDATION.md) for exactly what was and was not shown.

### Former known issues, fixed in this snapshot

The focused test found three problems. Each is fixed in 0.1.0-14 (this snapshot is 0.1.0-16)
and its issue is closed. The fixes were tested off-host and in a disposable guest on the reviewed
0.1.0-12 program files with the changed files copied over them. The 0.1.0-14 package built from
this repository was later installed over 0.1.0-12 in a disposable guest for the Tailscale SSH test,
but the focused cases of these three issues were not repeated on it. See
[validation](docs/VALIDATION.md#former-known-issues) for what was and was not shown.

| Issue | What happened | What changed |
| --- | --- | --- |
| [#1](https://github.com/IsaacNudeton/nsplit-linux/issues/1) | A running profile service or user manager could **lose the bind mounts** that give it the profile's `/etc/resolv.conf` and `/run/tailscale` when the host replaced those paths (NetworkManager rewriting `/etc/resolv.conf`; the host's `tailscaled` recreating `/run/tailscale`), and then saw the host's versions. `nsplit status` did not notice. | `nsplit status` reads the running services' mount tables (a lost mount is Degraded, an unreadable one Not checked), and a watcher re-attaches the mounts without restarting or logging out anything. **Limit:** until the repair (about 2 seconds measured, up to 15 minutes if an event is missed) the service sees the host's resolver file and the profile's default Tailscale control path leads to the host's daemon. The exposure is shortened, not removed. |
| [#2](https://github.com/IsaacNudeton/nsplit-linux/issues/2) | `nsplit remove` left the removed profile's rules in the **live** firewall until the next `nsplit reload`. | The firewall reads an explicit profile list that a removed profile is out of. A damaged list makes `nsplit-fw` fail instead of loading a narrower ruleset. |
| [#3](https://github.com/IsaacNudeton/nsplit-linux/issues/3) | After following the generated key file's own instruction (adding keys to it), the first `nsplit remove` kept the file, exited 1 and had to be run again. | nsplit no longer creates or owns the root-managed key file; one an administrator makes is kept on removal and is not an error. |

### Found by the Tailscale SSH test

Fixed in 0.1.0-15 (tested off-host with controls and mutants, and in a disposable guest with real ufw on the
installed package; see [validation](docs/VALIDATION.md#defects-7-and-8-fixed-in-010-15)):

- [#7](https://github.com/IsaacNudeton/nsplit-linux/issues/7): changing the uplinks left ufw route rules for the previous uplinks. They are now deleted first.
- [#8](https://github.com/IsaacNudeton/nsplit-linux/issues/8): `nsplit remove` left `/var/lib/nsplit/scoped-NAME.lock`. It is now removed.

Fixed in 0.1.0-16 (tested off-host with controls and mutants, and in a disposable guest on the installed package; see
[validation](docs/VALIDATION.md#defect-10-fixed-in-010-16) and [#9](docs/VALIDATION.md#issue-9-acknowledgement-and-status-for---ssh-tailscale-0110-16)):

- [#10](https://github.com/IsaacNudeton/nsplit-linux/issues/10): `nsplit stop --force` reported a failure when a Tailscale SSH session was open, because
  Tailscale's own shutdown (10 s stop time-out, then SIGKILL) leaves the daemon unit `failed`. nsplit now checks that nothing of the
  profile is left, clears that one state, says the stop was not graceful and exits 0. The refusal for a user who is still logged in
  now names `loginctl terminate-user USER` as the administrator's way out; nsplit never runs it.
- [#9](https://github.com/IsaacNudeton/nsplit-linux/issues/9): `--ssh tailscale`: the tailnet policy chooses the local account, and the login gate and `--ssh none` do not apply.
  What changed is that the mode now needs an explicit acknowledgement, says so in the preview, the final output and
  `nsplit status`, and `nsplit status` reads the node's real built-in SSH setting (Degraded when it is on although the
  profile says `none` or `openssh`). **The limitation itself remains:** nsplit cannot read or limit the tailnet policy.

Enrollment changes login/network configuration and requires an administrator.
The target account must be logged out, with no running user manager; programs
outside its login sessions also need attention before enrollment.

## Start here

[Build and use nsplit](docs/USAGE.md) covers dependencies, package installation,
a dry-run-first enrollment, owner sign-in, status and removal. No installation
or enrollment command needs to be run just to read the source.

The basic flow, **after installation in a disposable test machine**, is:

```sh
# Administrator; demo is an existing, fully logged-out test account.
sudo nsplit add demo --dry-run
sudo nsplit add demo

# Run as demo after entering its intended session.
nsplit login demo

# Administrator: inspect all current checks.
sudo nsplit status -v demo
```

`nsplit add` creates a profile; installing nsplit's own files does not enroll
accounts. Package-manager dependencies and hooks are separate from that claim.
An owner-managed login uses a narrowly scoped sudo rule, not general passwordless
administrator access. Do not enroll your only recovery/admin account first.

## Repository map

| Path | Purpose |
| --- | --- |
| `bin/nsplit` | Command-line entry point |
| `lib/nsplit/` | Commands and internal helpers |
| `lib/systemd/system/` | Managed service templates |
| `lib/NetworkManager/dispatcher.d/` | Uplink recovery hook |
| `share/nsplit/` | Firewall, DNS, D-Bus and SSH templates |
| `packaging/arch/` | Arch package recipe |
| `docs/` | Usage and validation scope |

Raw test logs, machine inventories, VM images, credentials and agent scratch
files do not belong in this repository. Historical review evidence is retained
separately; [CONTRIBUTING.md](CONTRIBUTING.md) explains the workflow.

## License

nsplit is released under the [MIT License](LICENSE). The Arch package records
`MIT` and installs the license text. Third-party dependencies retain their own
licenses.
