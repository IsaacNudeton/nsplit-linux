# Security boundaries

Nsplit changes privileged login and networking configuration. Treat the host
administrator, installed helpers, service manager and kernel as trusted. This
is not a container/VM boundary, complete application sandbox, anonymity tool or
replacement for the tailnet's access policy.

## Important operational limits

**Placement is not universal.** The enrolled systemd user manager and programs
started from it receive the profile namespace. Console and host-SSH shells are
not automatically moved there. A UID guard blocks their non-loopback host-network
traffic instead of silently allowing use of the host network. Loopback and Unix
IPC are not a complete isolation boundary; programs started outside managed
sessions need explicit handling. Do not advertise every process of a user as
universally sandboxed.

**Remote shell options are only partly validated.** `--ssh openssh` (an OpenSSH
server inside the profile namespace) had one focused guest test of a single
profile; `--ssh tailscale` (Tailscale SSH on the profile's node) has not been
tested in a guest. The host's own SSH server is unchanged and is not a way into a
profile; the namespace OpenSSH server also listens on the profile's private link to
the host, not only on its tailnet. See [validation](docs/VALIDATION.md).

**A running profile service can lose its view of the profile.** The profile
services and user manager get the profile's resolver file and Tailscale socket
directory through bind mounts. If the host replaces `/etc/resolv.conf` or
recreates `/run/tailscale` afterwards, the running service silently sees the host's
versions instead. `nsplit status` does not detect this
([issue #1](https://github.com/IsaacNudeton/nsplit-linux/issues/1), open). Until it
is fixed, treat a profile's DNS and control-socket separation as unverified after a
boot or a host DNS or Tailscale restart unless you checked the mounts yourself
(see [validation](docs/VALIDATION.md#known-issues)).

**Socket protection has prerequisites.** Keep `fs.protected_hardlinks=1` enabled.
Nsplit checks it before listener setup and at operation boundaries; it does not
monitor it continuously or change the setting. The root-owned directory permits
the named profile owner to traverse it without replacing the socket or widening
the directory access. Root retains administrative access.

Changing permissions, removing an external alias or running the preparation
helper on a live daemon does not revoke an established connection. Current link
count cannot reveal a client whose alias was already removed. After known prior
exposure, explicitly restart the affected profile daemon. Managed repair restarts
an active daemon when its current socket checks identify a repairable problem.

**DNS checks are observations, not permanent guarantees.** Managed split DNS
sends `ts.net` names to the profile's Tailscale resolver. A failed recheck/repair
of an existing split setup keeps or restores split configuration rather than
substituting a public fallback. Node-context rereads are not atomic or continuous
stability guarantees. Catchable repair signals enter rollback; power loss or
SIGKILL cannot guarantee recovery. Cooperating operations share a lock; arbitrary
administrator edits do not.

**Account for login failures.** The supported graphical login can refuse a
session without displaying its reason. Keep separate administrator/recovery
access and consult `nsplit status -v` and the PAM-gate journal. Never treat
UNKNOWN as either a security pass or proof of a defect.

## Reporting a suspected vulnerability

Do not put authentication links, node keys, Tailscale state, real tailnet/peer
inventories or unredacted machine logs in a public issue. Use GitHub's private
vulnerability-reporting option when the repository offers it. Otherwise ask the
maintainer for a private reporting channel without posting the sensitive details.
No private email address or response-time guarantee is specified here.

Useful reports identify the commit/package, affected operation, expected versus
observed result, caller privileges and a minimal sanitized reproduction. Keep
raw evidence privately. See [validation scope](docs/VALIDATION.md) before treating
an untested scenario as a documented guarantee.
