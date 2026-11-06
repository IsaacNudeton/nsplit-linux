# Walkthrough: a shared GPU machine, from one command to a login (alpha)

[Overview](../README.md) · [Usage](USAGE.md) · [Validation](VALIDATION.md) · [Security](../SECURITY.md)

This page shows what `nsplit setup --preset shared-gpu` does and what you see afterwards, **as printed by the real package (0.2.0-alpha.3) in the project's disposable test guest**. It is a demonstration of the commands, not a
claim that anything is ready for a particular deployment: read [validation](VALIDATION.md#shared-gpu-setup-020-alpha3) for what was and was not tested, and start in a disposable virtual machine.

How to read the output below:
- The guest's throwaway accounts were called `hsa`, `hsb` and `hsr`; here they are `alice`, `bob` and `admin`, and the guest's node name prefix is `gpubox-`. Nothing else was changed except that long lines
  of the guest's preview and of systemd's own explanatory text are cut where marked with `[...]`.
- `100.X.X.X` and `SUFFIX.ts.net` are placeholders the test harness puts in its logs instead of the lab tailnet's real addresses and suffix.
- The guest has **no GPU**: the profiles do not depend on one, and the command only reports what it sees of the GPU (it changes none of it). The tailnet was a throwaway lab control server, not Tailscale's, so
  signing in (`sudo nsplit login`) used a lab pre-authorisation key instead of the link an administrator would hand to each user; the output of that step is therefore not shown.

## The situation

Two people, `alice` and `bob`, are to run their own services on one shared machine, each in their own private network, each reached only over their own tailnet. `admin` is an administrator account that keeps
ordinary SSH access to the machine and holds a session open while this runs (the host-SSH denial needs that: if it went wrong, that session is the way back).

## 1. Preview, then run

```text
$ sudo nsplit setup --preset shared-gpu --recovery-user admin --dry-run alice bob
nsplit setup --preset shared-gpu: alice bob
  GPU devices seen: none under /dev/nvidia* or /dev/dri (informational: the profiles do not depend on a GPU being present)
  alice: groups giving GPU device access: none of video/render (not changed by this command)
  bob: groups giving GPU device access: none of video/render (not changed by this command)
  plan:
    nsplit add alice --mode headless --host-ssh deny --recovery-user admin
    nsplit add bob --mode headless --host-ssh deny --recovery-user admin
  what the add for alice would change (the others look the same, with their own names and addresses):
    [...]
Dry run: nothing was changed.
```

`--dry-run` changes nothing. The whole call is checked first (every user exists, is not logged in, is not already set up another way, the recovery account and its held session), and each add is previewed, so a
problem is found before the first change. Without `--dry-run` it asks once (`--yes` skips the question) and then runs `nsplit add USER --mode headless --host-ssh deny --recovery-user admin` for each user in turn:

```text
$ sudo nsplit setup --preset shared-gpu --recovery-user admin --yes alice bob
[...]
== alice
nsplit add: alice
  uid 3401   namespace netns-alice   link 10.200.4.1 <-> 10.200.4.2   node name gpubox-alice   uplinks: labup0   ssh: openssh   management: root   mode: headless
  LIMIT: only logins and user managers are checked. Programs of alice outside any session (cron/at jobs, system services running as uid 3401, sudo -u or su from another account) are not detected: they lose their host network when the guard loads and are not placed in netns-alice.
  NOTE (--mode headless): alice's user manager will stay running without a login (systemd lingering, switched on last and off again by nsplit remove), inside netns-alice; the profile is root-managed.
  A service of alice that listens on all addresses inside the profile is reachable from the tailnet AND from any process on this machine over the profile's private link (10.200.4.1 <-> 10.200.4.2): bind such a service to the profile's tailnet address if that matters.
  NOTE: Tailscale's built-in SSH server is switched OFF when the node is signed in. nsplit status reads the node's real setting and reports it if it is on.
[...]
  checking:
    PASS  uid guard loaded with the three rules and uid 3401
    PASS  NEGATIVE: alice in the host namespace has no network
    PASS  CONTROL: alice's namespace has internet access
    PASS  CONTROL: alice keeps loopback
    PASS  NEGATIVE: alice's call to the host's systemd-resolved is refused by the bus
    PASS  the profile's Tailscale daemon runs inside netns-alice and not in the host network namespace
    PASS  the daemon's socket directory is reachable only by root and alice
    PASS  CONTROL: alice can reach their own daemon's socket
    PASS  NEGATIVE: another user (uid 65534) is refused at alice's daemon socket
    PASS  the Tailscale operator is nobody (root only), as the root-managed policy says
    PASS  systemd will start user@3401.service inside netns-alice
    PASS  both login stacks carry the gate
    SKIP  gate refusal test (alice has a running user manager)
    PASS  CONTROL: another user passes the gate untouched
    PASS  lingering is on for alice and nsplit recorded that it switched it on
    PASS  alice's user manager (pid 25941), running without a login, is inside netns-alice
    PASS  the namespace OpenSSH server is running
    PASS  the namespace sshd's own PAM service carries the placement gate
    PASS  built-in Tailscale SSH is off on the node
    PASS  the host's sshd (sshd -t, sshd -T) refuses alice and still lets admin in
    PASS  the profile's own namespace sshd configuration is untouched by the host-SSH policy (no DenyUsers there)
  20 passed, 0 failed

Done. alice has a network of their own (not yet signed in to Tailscale).
  NOTE: Tailscale's built-in SSH server is switched OFF when the node is signed in. nsplit status reads the node's real setting and reports it if it is on.
  NOTE (--mode headless): alice's user manager will stay running without a login (systemd lingering, switched on last and off again by nsplit remove), inside netns-alice; the profile is root-managed.
  A service of alice that listens on all addresses inside the profile is reachable from the tailnet AND from any process on this machine over the profile's private link (10.200.4.1 <-> 10.200.4.2): bind such a service to the profile's tailnet address if that matters.
Next:  sudo nsplit login alice     (an administrator runs it; the user opens the sign-in link and approves their own Tailscale account)
       Then alice puts a public key in their ~/.ssh and connects with ordinary OpenSSH to the profile's Tailscale address (or name), and starts their own services with systemctl --user.
       alice's user manager is already running inside netns-alice; their enabled user services start at boot, stay up across logouts, and run in the profile's network.
       A login of alice is accepted only when that manager is running inside netns-alice: otherwise it is refused (journalctl -t nsplit-pam-gate, nsplit status).
[...]

nsplit setup: done for alice bob.
Next, for each user (an administrator for the first step; the user for the rest):
  alice:  sudo nsplit login alice   (they open the link it prints and approve with their own Tailscale account)
  bob:  sudo nsplit login bob   (they open the link it prints and approve with their own Tailscale account)
  then each user puts a public key in their ~/.ssh/authorized_keys, connects with ordinary OpenSSH to their profile's Tailscale address, and starts their services with systemctl --user enable --now NAME.
  Check everything with: nsplit status -v     A service that listens on all addresses inside a profile is also reachable from this machine's own processes over the profile's private link.
  Host SSH: these users are refused at the host's sshd; admin keeps host SSH access (nsplit host-ssh status).
```

If an add fails, it undoes itself, the command stops there and says who is done, who failed and who was not attempted; running the same command again skips the users that are already set up and finishes the rest.

## 2. The administrator signs each user in

`sudo nsplit login alice` prints a link; Alice opens it and approves the machine as a node of **her own** Tailscale account (the same for Bob). Nothing else about Alice's tailnet is shared with Bob or with the machine.
Afterwards (the three older profiles of the test guest are left out of this listing):

```text
$ sudo nsplit status
PROFILE        STATE            NEXT
alice          Ready            personal tailnet connected (gpubox-alice, 100.X.X.X); headless: the user manager lingers inside netns-alice, reached through the namespace OpenSSH server only
bob            Ready            personal tailnet connected (gpubox-bob, 100.X.X.X); headless: the user manager lingers inside netns-bob, reached through the namespace OpenSSH server only
```

## 3. What Alice sees

Alice puts a public key in her `~/.ssh/authorized_keys` and connects with ordinary OpenSSH to her profile's Tailscale address or name, from any machine on her tailnet. She lands in **her own network
namespace** (a private link to the host and her own Tailscale interface), as herself, and her `systemctl --user` manager is the one that has been running all along:

```text
$ ssh alice@<her node's tailscale address>
uid=3401(alice) gid=3401(alice) groups=3401(alice)

network namespace: net:[4026532644]
lo               UNKNOWN        127.0.0.1/8 ::1/128
vn-alice@if7     UP             10.200.4.2/30
ts-alice         UNKNOWN        100.X.X.X/32 fd7a:115c:a1e0::2/128 fe80::8d50:f88a:7883:57c6/64

systemctl --user is-system-running: running
login sessions of this user:
14 3401 alice       -     32320 user          -     no -
 9 3401 alice       -     25941 manager       -     no -
```

She enables her services with `systemctl --user enable --now NAME`; they start at boot, keep running after she logs out, and run in her network. A service that listens on all addresses (`0.0.0.0`) is also reachable
from the host's own processes over the profile's private link, so bind it to her tailnet address if that matters.

## 4. The host's own sshd

With `--host-ssh deny`, Alice and Bob are refused at the machine's ordinary `sshd`, the recovery account is not, and the whole policy is one drop-in that nsplit wrote and keeps in step with the profiles:

```text
$ ssh alice@localhost
alice@127.0.0.1: Permission denied (publickey,password).

$ ssh admin@localhost
admin

$ cat /etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf
# nsplit: host sshd denial for enrolled users. Written by 'nsplit add --host-ssh deny' / 'nsplit host-ssh deny'; change it with nsplit, not by hand.
# These users may log in only through their profile's own OpenSSH server over their tailnet. Recovery account that keeps host SSH access: admin
DenyUsers alice bob

$ sudo nsplit host-ssh status
host SSH denial: recovery account admin; drop-in /etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf
  PASS  the drop-in exists and is exactly what nsplit wrote
  PASS  sshd -T lists alice in DenyUsers (the host's sshd refuses alice; a running daemon needs the reload that nsplit did)
  PASS  sshd -T lists bob in DenyUsers (the host's sshd refuses bob; a running daemon needs the reload that nsplit did)
  PASS  the recovery account admin is allowed by the host's sshd as configured now
  INFO  sshd.service is running
```

## 5. Checking everything, and undoing it

`sudo nsplit status -v alice` lists every check, including the ones above:

```text
PROFILE        STATE            NEXT
alice          Ready            personal tailnet connected (gpubox-alice, 100.X.X.X); headless: the user manager lingers inside netns-alice, reached through the namespace OpenSSH server only
    PASS     namespace netns-alice is up
    PASS     firewall unit is active
    PASS     the profile's Tailscale daemon is active
    PASS     Tailscale node gpubox-alice is Running (100.X.X.X), tailnet SUFFIX.ts.net
    PASS     the daemon's socket directory is reachable only by root and alice; hard-link protection is enabled and any present socket has one link
    INFO     private DNS: split resolver configured (current resolution is checked separately)
    PASS     private DNS: public and private DNS resolution checks passed during this invocation
    INFO     root-managed: only an administrator signs this node in (sudo nsplit login alice)
    PASS     built-in Tailscale SSH is off, as the profile record says (--ssh openssh)
    PASS     placement drop-in for user@3401.service is installed
    PASS     the placement drop-in requires the profile's namespace and the firewall before the manager starts (fail-closed at boot)
    INFO     headless profile: alice's user manager runs without a login (lingering) inside netns-alice and is reached through the namespace OpenSSH server only
    PASS     lingering is on for alice, switched on by nsplit (nsplit remove switches it off again)
    PASS     the namespace OpenSSH server is running
    PASS     the namespace sshd uses its own PAM service nsplit-sshd-alice
    PASS     the PAM service /etc/pam.d/nsplit-sshd-alice carries the placement gate after the host's sshd stack
    PASS     login gate present in every login stack that exists here (console and graphical)
    PASS     D-Bus policy installed
    PASS     uid guard loaded for uid 3401
    PASS     host SSH denial: /etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf is exactly what nsplit wrote (recovery account admin)
    PASS     host SSH denial: sshd -T lists alice in DenyUsers (the host's sshd, as configured now, refuses them)
    PASS     alice's running user manager is inside netns-alice
    PASS     profile mounts: 6 required view(s) of /etc/resolv.conf and /run/tailscale in the running services match their sources
```

`sudo nsplit remove alice` takes her profile away again in one pass (it refuses while she has a login session): her lingering manager is stopped, the drop-in loses her name (and goes when the last
profile with the policy goes), and her account, her home and her own unit files are left alone.

## What this does not do

It does not install or configure a GPU driver, CUDA, device permissions or group membership: an administrator still decides who may open `/dev/nvidia*` and `/dev/dri` (usually the `video` and `render` groups), and
nothing here changes it. It does not sign anybody in, put anybody's SSH key anywhere, or restrict other ways onto the machine (cron or `at` jobs, services running as the user, `su` or `sudo -u` from another account).
