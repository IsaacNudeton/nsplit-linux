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
server inside the profile namespace) and `--ssh tailscale` (Tailscale SSH on the
profile's node) each had one focused guest test of a single profile. The host's own
SSH server is unchanged and is not a way into a profile; the namespace OpenSSH server
also listens on the profile's private link to the host, not only on its tailnet.

**`--ssh tailscale` does not carry the protections of `--ssh openssh`** ([#9](https://github.com/IsaacNudeton/nsplit-linux/issues/9)).
Which local account a Tailscale SSH session becomes is decided by the SSH policy of the
tailnet the profile is signed in to, which is the profile user's own account: in the test,
a rule allowing non-root users reached another enrolled user and the administrator account
(inside the profile's network namespace), and a rule that also listed `root` gave a root
session that could leave that namespace and read root-only files. The PAM login gate
(installed for `login` and `plasmalogin`) is not in the paths Tailscale SSH uses (`su`, and
`login` with PAM service `remote`): with the placement removed, the gate script refused but
a Tailscale SSH login was accepted and the user manager started in the host namespace. The
profile user, as the node's operator, can switch Tailscale SSH on and off, so `--ssh none` does
not prevent it on an owner-managed profile (on a root-managed profile the user was refused in one
test). Use `--ssh tailscale` only where the person who controls the profile's Tailscale account may be
given a shell on this machine as any account their policy names. Since 0.1.0-16 the mode is an
advanced, acknowledged one: `nsplit add --ssh tailscale` needs `--accept-tailscale-ssh-risk`,
the preview, the final output and `nsplit status` state the boundary, and `nsplit status` reads
the node's real setting and reports it as Degraded when it is on although the profile says
`none` or `openssh`. nsplit still cannot read or limit the tailnet policy, and a PAM-only fix would
not be complete either (Tailscale's own launcher has paths that do not use PAM). See
[validation](docs/VALIDATION.md).

**A running profile service can lose its view of the profile, for a short time.** The profile
services and user manager get the profile's resolver file and Tailscale socket directory
through bind mounts. If the host replaces `/etc/resolv.conf` or recreates `/run/tailscale`
afterwards (NetworkManager rewrites the file; the host's `tailscaled` is stopped, started or
restarted), the running service silently sees the host's versions instead. While that
lasts, a profile process's default Tailscale control path `/run/tailscale/tailscaled.sock`
resolves to the **host** daemon's socket instead of the profile's, and names are looked up
through the host's resolver file. Which operations the profile's user could then perform
against the host daemon is decided by Tailscale's own operator and peer-credential checks and
was not measured; the isolation the profile is meant to give is broken either way.
`nsplit status` now reads the running services' mount tables (a lost mount is Degraded), and
nsplit re-attaches the mounts without restarting or logging out anything, normally within a
couple of seconds of the event; a safety timer checks every 15 minutes in case an event was
missed ([issue #1](https://github.com/IsaacNudeton/nsplit-linux/issues/1)). This **shortens**
the exposure; it does not remove it. A design in which a detached mount exposes an empty or
inaccessible path instead of the host's socket is not implemented. See the usage notes on
[lost profile mounts](docs/USAGE.md#lost-profile-mounts).

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
