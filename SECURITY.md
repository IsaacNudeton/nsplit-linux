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
