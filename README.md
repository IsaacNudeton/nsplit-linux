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

## Intended environment

The implemented integration targets Arch-family Linux, exercised in a CachyOS
virtual machine, with systemd, nftables, Tailscale, dnsmasq and the **Plasma login
manager (`plasmalogin`)**. KDE alone is not sufficient: other display managers
are not supported by the current enrollment checks. The repository also includes
a NetworkManager dispatcher hook and optional ufw/OpenSSH integration.

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
