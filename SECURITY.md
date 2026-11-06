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
also listens on the profile's private link to the host, not only on its tailnet. In the same way a service started
inside a profile that listens on all addresses is reachable from the host's own processes over that link (the
namespace firewall accepts the host's address), whoever the host process runs as.

**Headless profiles (`--mode headless`, alpha).** The user's service manager stays running without a login (systemd lingering that nsplit switches on, last, and off again on removal) inside the
profile's namespace, and the user is reached through the profile's own OpenSSH server over their tailnet. What this relies on, and where it stops:
(1) the profile is root-managed, so the user is not the node's Tailscale operator and, in the one profile and Tailscale version measured, could not switch the built-in Tailscale SSH on; `nsplit status`
reports it if an administrator does. (2) The namespace sshd has its own PAM service: the host's sshd stack unchanged, then nsplit's placement gate after `pam_systemd`, so a login is accepted only when the
user's manager is active and inside the profile's namespace; a gate that cannot run and a missing service file both refuse the login (tested). (3) systemd-logind starts the manager at boot, not a login, so the
placement drop-in *requires* the profile's namespace and firewall: with the namespace handle broken the manager failed to start instead of running in the host's network (tested). Removing the drop-in by hand starts
the manager in the host's network: the gate then refuses every SSH login, the UID guard keeps its processes off the network beyond loopback, and `nsplit status` says Degraded (tested), but loopback and files
remain available to it. (4) A user service that listens on all addresses is reachable from the tailnet **and** from any process on this machine over the profile's private link (see above). (5) The host's own
sshd is unchanged: a headless user can still log in there and gets a shell in the host namespace (UID guard as above); refusing that is a separate optional policy that this release does not include. (6) Lingering is a
per-user logind setting for the whole machine: nsplit refuses to enrol a user who already has it, never touches lingering it did not switch on, and switches its own off only after checking that there is no login session.

**Host SSH denial (`--host-ssh deny`, alpha).** The optional policy writes one `DenyUsers` drop-in for the host's own `sshd`; everything it can promise comes from `sshd -t` and `sshd -T` on the configuration
as it is now: (1) it only works when the host's `sshd_config` already includes `sshd_config.d/*.conf`, and the main file is never edited; (2) a later configuration of the administrator can still let a user in
(for instance another drop-in); `nsplit status` reads `sshd -T` and says Degraded when the user is not listed, `UNKNOWN` when it cannot read it, and never "enforced" on a guess; (3) the recovery account that keeps
host SSH access is judged by what `sshd` would do with it, but nobody can prove that its owner still holds the key, which is why an authenticated session of it must be held open while the policy is applied;
(4) it refuses one way in only: cron or `at` jobs, services running as the user, and `su` or `sudo -u` from another account are not covered; (5) sshd is reloaded, never restarted, and the previous policy stays in
force when anything fails.

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
