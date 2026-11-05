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
OpenSSH server inside the profile's namespace) and `--ssh tailscale` (Tailscale
SSH on the profile's node).

- **`--ssh openssh` has had one focused guest test, not an acceptance program.**
  One throwaway profile on the reviewed baseline package: public-key login over
  the profile's private link, the session's user, namespace and Tailscale-socket
  view, refusal of root and of other accounts, forwarding refused, one reboot, and
  removal. It also found three problems, fixed in this snapshot (below). It did not cover a Tailscale
  sign-in, a connection over the profile's tailnet or a graphical session.
- **`--ssh tailscale` has not been validated.** It exists in the code; no guest
  profile used it and nothing connected through it.
- The host's own SSH server is not changed by nsplit and is not a way into a profile.

See [validation and limits](docs/VALIDATION.md) for exactly what was and was not shown.

### Former known issues, fixed in this snapshot

The focused test found three problems. Each is fixed in this snapshot (0.1.0-14) and its
issue is closed. The fixes were tested off-host and in a disposable guest on the reviewed
0.1.0-12 program files with the changed files copied over them; the 0.1.0-14 package built from
this repository was not itself installed or run in the guest. See
[validation](docs/VALIDATION.md#former-known-issues) for what was and was not shown.

| Issue | What happened | What changed |
| --- | --- | --- |
| [#1](https://github.com/IsaacNudeton/nsplit-linux/issues/1) | A running profile service or user manager could **lose the bind mounts** that give it the profile's `/etc/resolv.conf` and `/run/tailscale` when the host replaced those paths (NetworkManager rewriting `/etc/resolv.conf`; the host's `tailscaled` recreating `/run/tailscale`), and then saw the host's versions. `nsplit status` did not notice. | `nsplit status` reads the running services' mount tables (a lost mount is Degraded, an unreadable one Not checked), and a watcher re-attaches the mounts without restarting or logging out anything. **Limit:** until the repair (about 2 seconds measured, up to 15 minutes if an event is missed) the service sees the host's resolver file and the profile's default Tailscale control path leads to the host's daemon. The exposure is shortened, not removed. |
| [#2](https://github.com/IsaacNudeton/nsplit-linux/issues/2) | `nsplit remove` left the removed profile's rules in the **live** firewall until the next `nsplit reload`. | The firewall reads an explicit profile list that a removed profile is out of. A damaged list makes `nsplit-fw` fail instead of loading a narrower ruleset. |
| [#3](https://github.com/IsaacNudeton/nsplit-linux/issues/3) | After following the generated key file's own instruction (adding keys to it), the first `nsplit remove` kept the file, exited 1 and had to be run again. | nsplit no longer creates or owns the root-managed key file; one an administrator makes is kept on removal and is not an error. |

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
