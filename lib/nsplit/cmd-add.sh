# shellcheck shell=bash
# nsplit add: set up per-profile networking for one existing user. `--dry-run` prints exactly what would change and changes nothing.
# Every step is verified; if any step or check fails, everything this run did is undone (UNDO stack in common.sh).

usage_add() { cat <<'EOF'
usage: nsplit add USER [options]
  Give an existing local user their own network and their own Tailscale node. Their desktop and terminals will use it from their next login.
  Installing nsplit changes nothing; this command is what does.
  The user must be logged out (no session, no user manager) when it is applied: a user who is logged in is refused before anything is written,
  because the host-network guard takes effect at once and the placement only at their next login. --dry-run works either way.
  LIMIT: only logins and user managers are detected. Programs of that user that run outside any session (cron or at jobs, system services running as that
  uid, `sudo -u` / `su` from another account's session) are NOT detected: they lose their host network when the guard loads and are never placed in the
  profile's network. Stop or move them before enrolling the user.

  --dry-run            show every file and command that would change, change nothing
  --yes                do not ask for confirmation
  --name NAME          profile name (default: the username; up to 12 chars of a-z 0-9 _ -, starting with a letter)
  --mode MODE          desktop (default) | headless
                         desktop    the user logs in at this computer (graphical or console) and their desktop, terminals and services use the profile's network from their next login
                         headless   no desktop is needed: the user's service manager stays running without a login (systemd lingering, switched on by nsplit last and off again by nsplit remove) inside
                                    the profile's network, so their own `systemctl --user` services run there across logouts and reboots; the user is reached only through the profile's OpenSSH server over
                                    their own tailnet. A headless profile is always --ssh openssh and root-managed (the user does not become the node's Tailscale operator and cannot switch the built-in
                                    Tailscale SSH on), it needs no Plasma login manager, and the user must not already have lingering enabled. --mode=headless is accepted too.
  --ssh MODE           none (default) | openssh | tailscale
                         openssh    a separate OpenSSH server inside their namespace that accepts exactly this user (the recommended remote shell)
                         tailscale  ADVANCED: Tailscale's own built-in SSH server on their node. It needs --accept-tailscale-ssh-risk (see below).
  --accept-tailscale-ssh-risk
                       required with --ssh tailscale, and --yes does not stand in for it. It says you accept that the SSH rules of the user's own tailnet policy decide which local
                       account a Tailscale SSH login becomes: they can name any account on this machine (other nsplit users, the administrator, root), nsplit can neither read nor limit
                       them, and nsplit's login gate does not cover these sessions. It is refused with any other --ssh mode.
  --hostname NAME      their node's name on their tailnet (default: <this host>-<profile>)
  --uplinks "A B"      network interfaces their traffic may leave through (first profile only; default: every physical interface found)
  --root-managed       an administrator manages the node: the user may not run `tailscale` or `nsplit login` themselves (the default is owner-managed: the user may,
                       through ONE sudo rule written for them and this profile that allows exactly two fixed nsplit operations and nothing else; it is removed with the profile)
  --host-ssh deny      OPTIONAL: also refuse this user at the host's own sshd (they keep their profile's OpenSSH over their tailnet; a shell from the host's sshd runs in the HOST network namespace).
                       Needs --recovery-user. Only a drop-in in the host's sshd_config.d is written (the main file is never edited); see: nsplit host-ssh --help
  --recovery-user ADMIN  the existing, non-enrolled account that keeps host SSH access (required with --host-ssh deny; keep an SSH session of it open while this runs)
  --no-session-check   with --host-ssh deny: do not require that session (on your own responsibility)
  With --ssh none or openssh, Tailscale's built-in SSH server is only switched OFF when the node is signed in. On an owner-managed profile the user is the node's Tailscale operator
  and can switch it on later (tailscale set --ssh); `nsplit status` reads the node's real setting and reports a node that has it on although the profile says otherwise.
EOF
}

# ---- derived values -------------------------------------------------------------------------------------------------------
add_derive() {
	NAME=${NAME:-$LOGIN}; NAME_ARG=$NAME
	UIDN=$(user_uid "$LOGIN")
	NS=netns-$NAME; VH=vh-$NAME; VN=vn-$NAME; TS_IF=ts-$NAME
	PAMSVC=nsplit-sshd-$NAME   # the PAM service of a headless profile's namespace OpenSSH server
	if [ -r "$CONF" ]; then POOL=$(conf_get POOL); UPLINKS_USED=$(conf_get UPLINKS); PUBLIC_DNS=$(conf_get PUBLIC_DNS)
	else POOL=$(pick_pool) || POOL=""; UPLINKS_USED=${UPLINKS_ARG:-$(discover_uplinks)}; PUBLIC_DNS=$DEFAULT_PUBLIC_DNS; fi
	: "${PUBLIC_DNS:=$DEFAULT_PUBLIC_DNS}"
	SLOT=$(next_slot) || SLOT=""
	if [ -n "$POOL" ] && [ -n "$SLOT" ]; then
		local base=${POOL%.0.0/16}
		HOST_IP=$base.$SLOT.1; NS_IP=$base.$SLOT.2; PLEN=30; TS_PORT=$(next_port $((41641 + SLOT))) || TS_PORT=""
	fi
	if [ -n "$HOSTNAME_ARG" ]; then TS_HOSTNAME=$HOSTNAME_ARG; else local h; h=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo host); TS_HOSTNAME=${h%%.*}-$NAME; fi
	TS_HOSTNAME=${TS_HOSTNAME:0:63}
}

# ---- preflight: collect every problem, report them all, change nothing ----------------------------------------------------
add_preflight() {
	local p bad=0 n uid_min why
	problem() { printf '  PROBLEM: %s\n' "$*" >&2; bad=1; }
	valid_name "$NAME" || problem "the profile name '$NAME' is not usable (1-12 characters: a-z 0-9 _ -, starting with a letter). Choose one with --name."
	[ -d /run/systemd/system ] || problem "systemd is not the running init system; nsplit needs it"
	[ -e "$UNITDIR/nsplit-netns@.service" ] || problem "nsplit's units are not installed under $UNITDIR (install the nsplit package first; add does not install files by itself)"
	for p in ip nft python3 setpriv busctl loginctl dig; do command -v "$p" >/dev/null 2>&1 || problem "required program missing: $p"; done
	[ -x /usr/bin/tailscaled ] && [ -x "$TS_BIN" ] || problem "Tailscale is not installed (tailscale and tailscaled are needed in /usr/bin)"
	[ -x /usr/bin/dnsmasq ] || problem "dnsmasq is not installed (it is the profile's private resolver)"
	[ "$SSH" != openssh ] || { [ -x /usr/bin/sshd ] && command -v ssh-keygen >/dev/null || problem "--ssh openssh needs OpenSSH (sshd, ssh-keygen)"; }
	[ "$SSH" != tailscale ] || [ "$ACK_TS" = 1 ] || problem "--ssh tailscale needs --accept-tailscale-ssh-risk (--yes does not stand in for it): with Tailscale's built-in SSH server the SSH rules of $LOGIN's tailnet policy choose the local account a login becomes (any account on this machine, including the administrator and root), nsplit cannot read or limit them, and its login gate does not cover these sessions. The recommended remote shell is --ssh openssh."
	if [ "$HOSTSSH" = deny ]; then
		local hp hu
		[ -n "$RECOVERY" ] || problem "--host-ssh deny needs --recovery-user ADMIN: an existing, non-enrolled account that keeps host SSH access"
		if [ -n "$RECOVERY" ]; then
			# the users that would be denied: every profile that has the policy, and this one
			# shellcheck disable=SC2046
			while IFS= read -r hp; do [ -z "$hp" ] || problem "host SSH: $hp"; done < <(HOSTSSH_EXTRA=$LOGIN hostssh_preflight "$RECOVERY" $(hostssh_denied_users) "$LOGIN")
			hostssh_has_session "$RECOVERY" || { [ "$NO_SESSION_CHECK" = 1 ] || { [ "$DRY_REQ" = 1 ] && HOSTSSH_NOTE="no SSH session of $RECOVERY is open: a real run would be refused until you log in as $RECOVERY over SSH in another terminal and keep it open" || problem "no authenticated SSH session of the recovery account $RECOVERY exists: log in as $RECOVERY over SSH in another terminal and keep that session open while the policy is applied (nsplit cannot prove the account still works; --no-session-check overrides this on your own responsibility)"; }; }
		fi
	fi
	if [ "$MODE" = headless ]; then
		[ "$SSH" = openssh ] || problem "--mode headless goes with --ssh openssh only (the namespace OpenSSH server is how a headless profile is reached, and Tailscale's built-in SSH stays off): this enrolment is --ssh $SSH"
		[ -r "$PAMDIR/sshd" ] || [ -r "$PAMVENDOR/sshd" ] || problem "--mode headless needs the host's PAM service for sshd ($PAMDIR/sshd): the namespace OpenSSH server's own PAM service includes it and then adds the placement gate"
		case $(linger_state "$LOGIN") in
		off) ;;
		on) problem "$LOGIN already has lingering enabled (loginctl enable-linger): this release does not take over lingering it did not switch on. Disable it first (loginctl disable-linger $LOGIN), or enrol $LOGIN with --mode desktop";;
		*) problem "could not tell whether $LOGIN has lingering enabled ($LINGERDIR is not readable)";;
		esac
		[ ! -e "$PAMDIR/$PAMSVC" ] || [ "$(own_sha "$NAME" "$PAMDIR/$PAMSVC")" = "$(sha "$PAMDIR/$PAMSVC")" ] || problem "$PAMDIR/$PAMSVC already exists and was not made by nsplit; not overwriting it"
		[ ! -e "$LINGERMARK/$NAME" ] || problem "$LINGERMARK/$NAME exists: a record of lingering from an earlier profile of that name was never cleaned up"
	fi
	[ "$ACK_TS" != 1 ] || [ "$SSH" = tailscale ] || problem "--accept-tailscale-ssh-risk only goes with --ssh tailscale (this enrolment is --ssh $SSH)"
	[ "$MODE" = headless ] || [ -r "$PAMVENDOR/plasmalogin" ] || problem "this system's graphical login is not the supported one (no $PAMVENDOR/plasmalogin: only the Plasma login manager is supported in this release; a profile that needs no desktop can use --mode headless)"
	[ -r "$PAMDIR/login" ] || problem "no $PAMDIR/login (the console login stack)"
	if [ -r "$PAMDIR/plasmalogin" ] && ! grep -q '# nsplit:' "$PAMDIR/plasmalogin" && ! cmp -s "$PAMDIR/plasmalogin" "$PAMVENDOR/plasmalogin"; then
		[ "$(own_sha _shared "$PAMDIR/plasmalogin")" = "$(sha "$PAMDIR/plasmalogin")" ] || problem "$PAMDIR/plasmalogin already exists and was not made by nsplit; not overwriting it"
	fi
	$SYSTEMCTL is-active -q dbus-broker.service 2>/dev/null || $SYSTEMCTL is-active -q dbus.service 2>/dev/null || problem "no running system bus service (dbus-broker or dbus) to reload"
	# an earlier, different nsplit installation would shadow the packaged units: never install over it
	# (nsplit installs its units under $UNITDIR and puts only user@<uid>.service.d drop-ins in $SDIR: any nsplit-* entry there belongs to something else)
	local fu; fu=$(ls "$SDIR" 2>/dev/null | grep -E '^nsplit-' | tr '\n' ' ')
	[ -z "$fu" ] || problem "$SDIR already holds nsplit units that this tool did not create ($fu): an earlier nsplit installation is present and would override the packaged units. Remove or migrate it first; add will not install over it."
	# the user
	id "$LOGIN" >/dev/null 2>&1 || problem "no such user: $LOGIN"
	if [ -n "$UIDN" ]; then
		uid_min=$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null); : "${uid_min:=1000}"
		{ [ "$UIDN" -ge "$uid_min" ] && [ "$UIDN" != 65534 ]; } || problem "$LOGIN (uid $UIDN) is a system account; only regular users can have a profile"
	fi
	for n in $(profile_names); do
		( . "$PROFDIR/$n.env"; [ "$n" = "$NAME_ARG" ] || [ "$LOGIN" = "$LOGIN_ARG" ] || [ "$UIDN" = "$ARG_UID" ] ) && problem "a profile for $LOGIN (or named $NAME) already exists ($n): use 'nsplit status $n'"
	done
	# addresses, names, ports
	[ -n "$UPLINKS_USED" ] || problem "no physical network interface found to leave through; pass --uplinks \"wlan0 enp3s0\""
	if [ -r "$CONF" ]; then [ -z "$UPLINKS_ARG" ] || problem "--uplinks: the uplinks are already set for this machine ($UPLINKS_USED); change them with: nsplit uplinks"
	else for p in $UPLINKS_ARG; do [ -e "/sys/class/net/$p" ] || problem "--uplinks: no such interface $p"; done; fi
	if [ -z "$POOL" ]; then
		if [ -r "$CONF" ]; then problem "$CONF exists but has no POOL (a configuration from another layout?); not guessing"
		else problem "none of the address ranges nsplit uses (${POOL_CANDIDATES// /.0.0/16, }.0.0/16) is free on this host"; fi
	fi
	[ -n "${HOST_IP:-}" ] || problem "no free namespace address slot"
	[ ! -e "/sys/class/net/$VH" ] && [ ! -e "/sys/class/net/$TS_IF" ] || problem "a network interface named $VH or $TS_IF already exists"
	$IP netns list 2>/dev/null | awk '{print $1}' | grep -qx "$NS" && problem "a network namespace named $NS already exists"
	[ -n "${TS_PORT:-}" ] || [ -z "${HOST_IP:-}" ] || problem "no free UDP port for the profile's Tailscale daemon"
	if [ -d "/var/lib/tailscale-$NAME" ] && [ ! -e "$STATEMARK/$NAME" ]; then problem "/var/lib/tailscale-$NAME already exists and was not created by nsplit"; fi
	[ ! -e "$SDIR/user@$UIDN.service.d/50-nsplit.conf" ] || [ "$(own_sha "$NAME" "$SDIR/user@$UIDN.service.d/50-nsplit.conf")" = "$(sha "$SDIR/user@$UIDN.service.d/50-nsplit.conf")" ] || problem "$SDIR/user@$UIDN.service.d/50-nsplit.conf already exists and was not made by nsplit"
	# the guard takes effect the moment it loads but the placement only at the next login: a user who is logged in now would lose the network of everything they have running
	if [ -n "$UIDN" ] && why=$(busy_reason); then
		if [ "$DRY_REQ" = 1 ]; then BUSY_NOTE=$why; else problem "$why"; fi
	fi
	[ $bad = 0 ]
}
# busy_reason: prints why the target cannot be enrolled right now and succeeds; fails (prints nothing) when they can. Failed inspection counts as busy.
busy_reason() {
	user_busy "$LOGIN" "$UIDN"; case $? in
	0) printf '%s is logged in or has a running user manager. Enrolling now would cut off what they have running (the host-network guard takes effect at once; the placement only at the next login). Have them log out completely and run this again.' "$LOGIN";;
	2) printf 'could not tell whether %s is logged in (loginctl or systemctl did not answer), so it is not safe to continue. Check that systemd-logind is running and run this again.' "$LOGIN";;
	*) return 1;; esac; }

# ---- text generators -----------------------------------------------------------------------------------------------------
env_text() { cat <<EOF
# nsplit profile $NAME. Written by 'nsplit add'; change it with nsplit, not by hand.
NAME=$NAME
LOGIN=$LOGIN
UIDN=$UIDN
NS=$NS
VH=$VH
VN=$VN
HOST_IP=$HOST_IP
NS_IP=$NS_IP
PLEN=$PLEN
TS_IF=$TS_IF
TS_PORT=$TS_PORT
TS_HOSTNAME=$TS_HOSTNAME
SSH=$SSH
MANAGED=$MANAGED
MODE=$MODE
$( [ "$HOSTSSH" = deny ] && printf 'HOSTSSH=deny\nHOSTSSH_RECOVERY=%s' "$RECOVERY" )
EOF
}
conf_text() { cat <<EOF
# nsplit global configuration. UPLINKS = physical interfaces the namespaces may egress through (anything else, e.g. tailscale0, docker, virbr, is never a permitted egress).
# POOL = the address range the namespaces' private links come from. PUBLIC_DNS = the resolvers a profile uses for non-tailnet names.
# After changing UPLINKS run: nsplit reload
UPLINKS="$UPLINKS_USED"
POOL="$POOL"
PUBLIC_DNS="$PUBLIC_DNS"
EOF
}
# guard_text UID...: the host-namespace egress backstop for these uids (processes inside a profile namespace are not matched: tables are per namespace)
guard_text() { cat <<EOF
# nsplit uid guard: a BACKSTOP in the HOST network namespace. Any process of a profile's user that ends up in the host namespace (a console or host-ssh login,
# the login-session helpers, a failed or missing placement) has NO network off this machine instead of silently using the host's. Loopback (127.0.0.0/8, ::1)
# and unix sockets (D-Bus, Wayland) are untouched; the host's own non-loopback addresses are unreachable too (traffic to a local address leaves via lo).
# Own table: ufw, NetworkManager and nsplit's other rules are not edited. Generated by nsplit; delete+add in ONE transaction, so it is never absent while reloading.
table inet nsplit_uid
delete table inet nsplit_uid
table inet nsplit_uid {
	set uids {
		type uid
		elements = { $(IFS=,; echo "$*" | sed 's/,/, /g') }
	}
	chain out {
		type filter hook output priority -20; policy accept;
		meta skuid @uids oifname != "lo" counter drop
		meta skuid @uids fib daddr type local ip daddr != 127.0.0.0/8 counter drop
		meta skuid @uids fib daddr type local ip6 daddr != ::1 counter drop
	}
}
EOF
}
placement_text() { if [ "$MODE" = headless ]; then placement_text_headless; else placement_text_desktop; fi; }
placement_text_desktop() { cat <<EOF
# nsplit profile $NAME: places $LOGIN's whole user manager (so the desktop, terminals and user services started from it) in $NS. Affects user@$UIDN.service only.
# Requisite= (not Requires=/Wants=): if the namespace is not already up the manager FAILS to start instead of running unplaced; nothing is ever started by this file.
[Unit]
Requisite=nsplit-netns@$NAME.service
After=nsplit-netns@$NAME.service nsplit-firewall.service nsplit-tailscaled@$NAME.service nsplit-dns@$NAME.service
[Service]
NetworkNamespacePath=/run/netns/$NS
BindReadOnlyPaths=$NETNSETC/$NS/resolv.conf:/etc/resolv.conf
InaccessiblePaths=-/run/systemd/resolve -/var/lib/tailscale
BindPaths=/run/tailscale-$NAME:/run/tailscale
EOF
}
# A headless profile's user manager is started by systemd-logind at boot (lingering), not by a login, so this drop-in does the opposite of the desktop one: it makes systemd bring the profile's namespace and
# firewall up FIRST (Requires=, not Requisite=) and keeps the manager from starting without them. If the namespace handle is missing or broken the manager fails to start (NetworkNamespacePath);
# it never starts in the host network. The daemon and the namespace sshd are wanted and ordered before it, not required: a crashed daemon does not take the user's services down with it.
placement_text_headless() { cat <<EOF
# nsplit profile $NAME (headless): places $LOGIN's whole user manager, which stays running without a login (lingering), in $NS. Affects user@$UIDN.service only.
# Requires= (not Requisite=): systemd brings the namespace and the firewall up before the manager, and the manager is stopped with them. If the namespace cannot be joined the manager FAILS to start instead of running unplaced.
[Unit]
Requires=nsplit-netns@$NAME.service nsplit-firewall.service
Wants=nsplit-tailscaled@$NAME.service nsplit-sshd@$NAME.service
After=nsplit-netns@$NAME.service nsplit-firewall.service nsplit-tailscaled@$NAME.service nsplit-dns@$NAME.service nsplit-sshd@$NAME.service
[Service]
NetworkNamespacePath=/run/netns/$NS
BindReadOnlyPaths=$NETNSETC/$NS/resolv.conf:/etc/resolv.conf
InaccessiblePaths=-/run/systemd/resolve -/var/lib/tailscale
BindPaths=/run/tailscale-$NAME:/run/tailscale
EOF
}
# the PAM service of a headless profile's namespace OpenSSH server: the host's own sshd stack, unchanged (it brings pam_systemd), then the placement gate. A login is accepted only when the user manager is
# active and inside the profile's namespace. Nothing is added to the host's sshd or login stacks for this.
pam_service_text() { cat <<EOF
#%PAM-1.0
# nsplit profile $NAME (headless): the PAM service of the profile's namespace OpenSSH server (PAMServiceName in $ETC/ssh/$NAME/sshd_config). Written by 'nsplit add'; change it with nsplit, not by hand.
# The host's own sshd stack first (it includes pam_systemd), then the gate: the session is refused unless user@$UIDN.service is active and inside $NS.
auth      include   sshd
account   include   sshd
password  include   sshd
session   include   sshd
$(pam_pairs "$NAME")
EOF
}
# sshd_config_text: the namespace OpenSSH server's configuration; a headless profile's names its own PAM service
sshd_config_text() { subst < "$SHARE/sshd_config.in"
	if [ "$MODE" = headless ]; then printf '# headless profile: its own PAM service (the host sshd stack, then the placement gate)\nPAMServiceName %s\n' "$PAMSVC"; fi; }
resolv_public_text() { local s; printf '# nsplit: %s uses public resolvers until its tailnet is signed in (then the split resolver replaces this file).\n' "$NAME"; for s in $PUBLIC_DNS; do printf 'nameserver %s\n' "$s"; done; printf 'options edns0 timeout:2 attempts:2\n'; }
subst() { sed -e "s|@ETC@|$ETC|g" -e "s|@NAME@|$NAME|g" -e "s|@LOGIN@|$LOGIN|g" -e "s|@NS_IP@|${NS_IP:-}|g" -e "s|@TS_IF@|$TS_IF|g"; }

# sudoers_text: the whole rule. Fixed command lines for this user and this profile only (the helper checks them again itself).
sudoers_text() { local who=$LOGIN; case $LOGIN in *[!a-z0-9_-]*|[!a-z_]*) who="#$UIDN";; esac
	cat <<EOF
# nsplit profile $NAME: $LOGIN may run exactly these two operations as root, for this profile only, without a password. Written by 'nsplit add', removed with the profile.
# They are fixed command lines: check that the profile's Tailscale daemon is inside the profile's namespace, and switch on the profile's private DNS. Nothing else.
$who ALL=(root) NOPASSWD: $SCOPED $NAME verify, $SCOPED $NAME dns
EOF
}

# headless_notice: what a headless profile is and what it is not
headless_notice() {
	say "  NOTE (--mode headless): $LOGIN's user manager will stay running without a login (systemd lingering, switched on last and off again by nsplit remove), inside $NS; the profile is root-managed."
	say "  A service of $LOGIN that listens on all addresses inside the profile is reachable from the tailnet AND from any process on this machine over the profile's private link ($HOST_IP <-> $NS_IP): bind such a service to the profile's tailnet address if that matters."
}
# ssh_notice: the boundary of the chosen SSH mode, printed in the preview, before applying, and at the end. Nothing here claims more than was measured:
# on a root-managed profile it does not say the built-in server cannot be switched on (that was not tested), only that nsplit status reads it.
ssh_notice() {
	case $SSH in
	tailscale)
		say "  NOTICE (--ssh tailscale: advanced, governed from outside this machine): this turns on Tailscale's built-in SSH server on $LOGIN's node. Which local account a login becomes is decided by the"
		say "  SSH rules of the tailnet policy that $LOGIN's Tailscale account controls, not by nsplit: they can name any account on this machine (other nsplit users, the administrator, root)."
		say "  nsplit can neither read nor limit that policy, and its login gate does not apply to these sessions. Use it only if whoever controls that tailnet may have a shell here as any account its policy names."
		say "  The recommended remote shell is --ssh openssh: a separate OpenSSH inside the namespace that accepts exactly $LOGIN.";;
	*)
		if [ "$MANAGED" = owner ]; then
			say "  NOTE: Tailscale's built-in SSH server is switched OFF when the node is signed in, but $LOGIN is the node's Tailscale operator (owner-managed) and can switch it on later (tailscale set --ssh). nsplit status reads the node's real setting and reports it if it is on."
		else
			say "  NOTE: Tailscale's built-in SSH server is switched OFF when the node is signed in. nsplit status reads the node's real setting and reports it if it is on."
		fi;;
	esac
}

# ---- PAM login gate ---------------------------------------------------------------------------------------------------
# pam_pairs: the two lines per profile (skip for everyone else; refuse this user unless his manager is in his namespace)
pam_pairs() { local n l u ns
	for n in "$@"; do
		if [ -r "$PROFDIR/$n.env" ]; then eval "$( . "$PROFDIR/$n.env"; printf 'l=%q u=%q ns=%q' "$LOGIN" "$UIDN" "$NS" )"; else l=$LOGIN; u=$UIDN; ns=$NS; fi
		printf 'session    [success=1 default=ignore]  pam_succeed_if.so  quiet  user != %s      # nsplit: skip the gate for everyone else\n' "$l"
		printf 'session    requisite    pam_exec.so  quiet  stdout  %s %s %s %s      # nsplit: refuse %s unless the user manager is in %s\n' "$GATE" "$l" "$u" "$ns" "$l" "$ns"
	done; }
# pam_generate SRC ANCHOR_REGEX PROFILE... : SRC without nsplit's marked lines, plus the pairs right after the ONE anchor line. Exit 4 on 0 or >1 anchors.
pam_generate() { local src=$1 anchor=$2; shift 2; local pairs; pairs=$(pam_pairs "$@")
	python3 -I -c '
import re,sys
src,anchor,pairs=sys.argv[1:4]
lines=[l for l in open(src).read().split("\n") if "# nsplit:" not in l]
idx=[i for i,l in enumerate(lines) if re.match(anchor,l)]
if len(idx)!=1: sys.stderr.write("anchor matches %d lines (need exactly 1)\n"%len(idx)); sys.exit(4)
ins=[l for l in pairs.split("\n") if l]
lines[idx[0]+1:idx[0]+1]=ins
sys.stdout.write("\n".join(lines))' "$src" "$anchor" "$pairs"; }
ANCH_PL='^session\s+include\s+system-login\s*$'; ANCH_LG='^session\s+include\s+system-local-login\s*$'
# only_marked_added OLD NEW : NEW = OLD (minus any marked lines) plus exactly the marked lines
only_marked_added() { diff <(grep -v '# nsplit:' "$1") <(grep -v '# nsplit:' "$2") >/dev/null; }

# pam_install PROFILE...: (re)write the gated files for exactly these profiles (none = remove the gate). plasmalogin is a copy of the vendor file; login is edited in place with a first-time backup.
pam_install() {
	local gpl="" glg gkept haspl=0
	[ -r "$PAMVENDOR/plasmalogin" ] && haspl=1   # a machine with no Plasma login manager can still have headless profiles: then only the console login stack is gated
	[ $haspl = 0 ] || tmp_new gpl; tmp_new glg
	if [ $haspl = 1 ]; then pam_generate "$PAMVENDOR/plasmalogin" "$ANCH_PL" "$@" > "$gpl" || die "cannot generate the graphical login file (unexpected vendor file layout)"; fi
	pam_generate "$PAMDIR/login" "$ANCH_LG" "$@" > "$glg" || die "cannot generate the console login file (unexpected layout)"
	{ [ $haspl = 0 ] || only_marked_added "$PAMVENDOR/plasmalogin" "$gpl"; } && only_marked_added "$PAMDIR/login" "$glg" || die "generated login files differ from the originals by more than the gate lines"
	OWNER=_shared
	if [ "$#" -eq 0 ]; then
		if [ "$DRY" = 1 ]; then printf '    would remove the gate lines from %s and %s\n' "$PAMDIR/plasmalogin" "$PAMDIR/login"; [ -z "$gpl" ] || tmp_drop "$gpl"; tmp_drop "$glg"; return 0; fi
		if [ -e "$PAMDIR/plasmalogin" ] && grep -q '# nsplit:' "$PAMDIR/plasmalogin"; then
			if [ "$(own_sha _shared "$PAMDIR/plasmalogin")" = "$(sha "$PAMDIR/plasmalogin")" ]; then rm -f "$PAMDIR/plasmalogin"
			else tmp_new gkept; grep -v '# nsplit:' "$PAMDIR/plasmalogin" > "$gkept" && cat "$gkept" > "$PAMDIR/plasmalogin"   # changed by hand: only nsplit's own lines come out
				warn "kept $PAMDIR/plasmalogin: it was changed after nsplit wrote it; only nsplit's gate lines were taken out of it"; fi
			own_forget _shared "$PAMDIR/plasmalogin"; fi
	elif [ $haspl = 1 ]; then put "$PAMDIR/plasmalogin" 644 < "$gpl"; fi
	pam_edit_login "$glg"
	[ -z "$gpl" ] || tmp_drop "$gpl"; tmp_drop "$glg"
}
pam_edit_login() {
	local new=$1 prev
	if [ "$DRY" = 1 ]; then printf '    would edit: %s (gate lines only; first-time backup in %s/pam/login.orig)\n' "$PAMDIR/login" "$BKDIR"; return 0; fi
	if [ ! -e "$BKDIR/pam/login.orig" ]; then   # first edit ever: keep the original; if this run fails the backup goes away with the rest
		undo_push put_remove _shared "$BKDIR/pam/login.orig"; mkdir -p "$BKDIR/pam"; cp -p "$PAMDIR/login" "$BKDIR/pam/login.orig"; fi
	tmp_new prev; cp -p "$PAMDIR/login" "$prev"   # the rollback copy: dropped by pam_login_restore, or swept at exit when nothing needed to be undone
	undo_push pam_login_restore "$prev"           # registered before the edit: restoring an unchanged file does nothing
	install -m 644 "$new" "$PAMDIR/login.nsplit-new" && { tmp_adopt "$PAMDIR/login.nsplit-new"; mv -f "$PAMDIR/login.nsplit-new" "$PAMDIR/login"; }
}
pam_login_restore() { cat "$1" > "$PAMDIR/login"; tmp_drop "$1"; }

# ---- the steps ------------------------------------------------------------------------------------------------------------
fw_refresh() { # make the firewall reflect the profiles that exist now: none = stop and disable it; otherwise start it or reload it
	mounts_refresh || warn "could not switch the mount watcher (nsplit-mounts.path, nsplit-mounts.timer); look with: nsplit mounts check"
	if [ -z "$(profile_names)" ]; then $SYSTEMCTL disable --now nsplit-firewall.service; return; fi
	if unit_active nsplit-firewall.service; then $SYSTEMCTL reload nsplit-firewall.service; else $SYSTEMCTL enable --now nsplit-firewall.service; fi; }
guard_refresh() { # load the guard file as it is now (atomic reload), or remove the guard when no profile is left
	# no profile left: unit stopped (its ExecStop removes the table) AND the table deleted directly, because the guard may have been loaded by hand before the unit started
	if [ -z "$(profile_names)" ]; then local rc=0; $SYSTEMCTL disable --now nsplit-uid-guard.service || rc=1; $NFT delete table inet nsplit_uid 2>/dev/null; return $rc; fi
	$NFT -f "$ETC/uid-guard.nft" && $SYSTEMCTL enable --now nsplit-uid-guard.service; }

step_files() {
	say "  - profile configuration"
	[ "$DRY" = 1 ] || undo_push rmdir_conf_dirs   # pushed first of all = runs last: the configuration directories this run made, once they are empty
	[ "$DRY" = 1 ] || undo_push fw_refresh_after_env_removed   # runs after the profile files are gone
	OWNER=_shared; [ -r "$CONF" ] || { put "$CONF" 644 < <(conf_text); }
	OWNER=$NAME
	put "$PROFDIR/$NAME.env" 644 < <(env_text)
	put "$NETNSETC/$NS/resolv.conf" 644 < <(resolv_public_text)
	# the firewall's list of profiles gets the new one before the firewall is started or reloaded (the profile being added is in the list once, whether or not its file exists yet: a preview)
	OWNER=_shared; put "$FWSET" 644 < <(fw_set_text $(profile_names) "$NAME")
}
fw_refresh_after_env_removed() { fw_refresh; guard_refresh; }
rmdir_conf_dirs() { rmdir "$ETC/ssh" "$ETC/dns" "$PROFDIR" 2>/dev/null; rmdir "$ETC" 2>/dev/null; true; }   # the same directories `nsplit remove` takes away when it is the last profile; rmdir only ever removes an empty one

step_guard() {
	say "  - host-namespace egress guard for uid $UIDN"
	local uids n why; uids=$( { for n in $(profile_names); do ( . "$PROFDIR/$n.env"; echo "$UIDN" ); done; echo "$UIDN"; } | sort -nu | tr '\n' ' ')
	if [ "$DRY" != 1 ] && why=$(busy_reason); then die "$why"; fi   # last look before the guard is loaded: they may have logged in while the earlier steps ran
	[ "$DRY" = 1 ] || undo_push guard_refresh   # runs after the previous guard file is back
	OWNER=_shared
	# shellcheck disable=SC2086
	put "$ETC/uid-guard.nft" 644 < <(guard_text $uids)
	if [ "$DRY" = 1 ]; then run $SYSTEMCTL enable --now nsplit-uid-guard.service; return 0; fi
	$NFT -c -f "$ETC/uid-guard.nft" || die "the generated guard ruleset is not valid"
	$NFT -f "$ETC/uid-guard.nft" && $SYSTEMCTL enable --now nsplit-uid-guard.service >/dev/null 2>&1 || die "could not load the uid guard"
}

step_dbus() {
	say "  - D-Bus policy: $LOGIN may not use the host's systemd-resolved"
	[ "$DRY" = 1 ] || undo_push dbus_reload
	OWNER=$NAME; put "$DBUSDIR/nsplit-$NAME.conf" 644 < <(subst < "$SHARE/dbus-policy.conf.in")
	if [ "$DRY" = 1 ]; then run $SYSTEMCTL reload dbus-broker.service; return 0; fi
	dbus_reload || die "the system bus rejected the policy reload"
}
dbus_reload() { if $SYSTEMCTL is-active -q dbus-broker.service; then $SYSTEMCTL reload dbus-broker.service; else $SYSTEMCTL reload dbus.service; fi; }

step_start() {
	say "  - namespace, firewall, Tailscale daemon"
	if [ "$DRY" = 1 ]; then printf '    would run: %s/nsplit-ufw add %s   (only if ufw is active)\n' "$LIB" "$NAME"
	else undo_push "$LIB/nsplit-ufw" del "$NAME"; "$LIB/nsplit-ufw" add "$NAME" || die "could not add the ufw route rules"; fi
	[ "$DRY" = 1 ] || undo_push $SYSTEMCTL disable --now "nsplit-netns@$NAME.service"
	run $SYSTEMCTL enable --now "nsplit-netns@$NAME.service" || die "the namespace for $NAME did not start (see: journalctl -u nsplit-netns@$NAME)"
	if [ "$DRY" = 1 ]; then printf '    would run: %s enable --now nsplit-firewall.service   (or reload it if it is already active)\n' "$SYSTEMCTL"; printf '    would run: %s enable --now nsplit-mounts.path nsplit-mounts.timer   (re-attaches the profile mounts if the host replaces /etc/resolv.conf or /run/tailscale)\n' "$SYSTEMCTL"
	else fw_refresh || die "the firewall did not start"; fi
	if [ ! -e "$STATEMARK/$NAME" ] && [ "$DRY" != 1 ]; then
		mkdir -p "$STATEMARK"; : > "$STATEMARK/$NAME"; MARK_MADE=1
		undo_push rm -f "$STATEMARK/$NAME"; undo_push rm -rf "/var/lib/tailscale-$NAME"   # runs after the daemon has stopped
	fi
	[ "$DRY" = 1 ] || undo_push $SYSTEMCTL disable --now "nsplit-tailscaled@$NAME.service"
	run $SYSTEMCTL enable --now "nsplit-tailscaled@$NAME.service" || die "the Tailscale daemon for $NAME did not start (see: journalctl -u nsplit-tailscaled@$NAME)"
	[ "$DRY" = 1 ] && return 0
	local i; for i in $(seq 30); do [ -S "$(sock_of "$NAME")" ] && break; intr_check; sleep 1; done
	[ -S "$(sock_of "$NAME")" ] || die "the profile's Tailscale daemon did not come up (see: journalctl -u nsplit-tailscaled@$NAME)"
}

step_ssh() {
	[ "$SSH" = openssh ] || return 0
	say "  - OpenSSH inside the namespace"
	local d=$ETC/ssh/$NAME; OWNER=$NAME
	put "$d/sshd_config" 644 < <(sshd_config_text)
	[ "$MODE" != headless ] || put "$PAMDIR/$PAMSVC" 644 < <(pam_service_text)   # before the server starts: it reads this service for every login
	# No root-managed authorized_keys is created: it is the administrator's file if they want one (see the sshd_config), so nsplit neither writes nor owns it.
	if [ "$DRY" = 1 ]; then printf '    would create: %s/ssh_host_ed25519_key(.pub)\n' "$d"; [ "$MODE" != headless ] || printf '    would check: sshd -T reports PAMServiceName %s for the generated configuration\n' "$PAMSVC"; run $SYSTEMCTL enable --now "nsplit-sshd@$NAME.service"; return 0; fi
	if [ ! -e "$d/ssh_host_ed25519_key" ]; then
		ssh-keygen -q -t ed25519 -N '' -C "nsplit-$NAME@$(cat /proc/sys/kernel/hostname)" -f "$d/ssh_host_ed25519_key" || die "ssh-keygen failed"
		chmod 600 "$d/ssh_host_ed25519_key"; chmod 644 "$d/ssh_host_ed25519_key.pub"
		own_record "$NAME" "$d/ssh_host_ed25519_key"; own_record "$NAME" "$d/ssh_host_ed25519_key.pub"
		undo_push put_remove "$NAME" "$d/ssh_host_ed25519_key"; undo_push put_remove "$NAME" "$d/ssh_host_ed25519_key.pub"
	fi
	/usr/bin/sshd -t -f "$d/sshd_config" || die "the generated sshd configuration does not parse"
	if [ "$MODE" = headless ]; then   # the server must really use the profile's own PAM service: ask it, do not assume the option exists
		local eff; eff=$(/usr/bin/sshd -T -f "$d/sshd_config" 2>/dev/null)   # captured first: under pipefail a grep -q that quits at its match would make sshd die of SIGPIPE and the pipeline look failed
		grep -qix "pamservicename $PAMSVC" <<<"$eff" || die "this OpenSSH does not report PAMServiceName $PAMSVC for the generated configuration, so the profile's own PAM service (the placement gate) would not be used; nothing was left in place"
	fi
	undo_push $SYSTEMCTL disable --now "nsplit-sshd@$NAME.service"   # before the enable: `enable --now` can enable the unit and then fail to start it
	$SYSTEMCTL enable --now "nsplit-sshd@$NAME.service" || die "the namespace sshd did not start"
}

step_placement() {
	say "  - placement: $LOGIN's user manager will start inside $NS"
	[ "$DRY" = 1 ] || undo_push $SYSTEMCTL daemon-reload
	OWNER=$NAME; put "$SDIR/user@$UIDN.service.d/50-nsplit.conf" 644 < <(placement_text)
	run $SYSTEMCTL daemon-reload || die "systemd rejected the new drop-in"
}

step_gate() {
	say "  - login gate: $LOGIN is refused at login unless the placement is in force"
	local names; names=$(printf '%s\n' $(profile_names) "$NAME" | sort -u)   # the profile being added is in the list once, whether or not its file exists yet (preview)
	# shellcheck disable=SC2086
	pam_install $names
}

# step_linger (headless only): the very last change. Lingering makes systemd-logind start the user's manager without a login and keep it; by now the namespace, the firewall, the daemon, the placement drop-in,
# the namespace sshd and the login gate are all in place, so the manager is born inside the profile's namespace. The marker records that nsplit switched lingering on (removal switches it off only then).
step_linger() {
	[ "$MODE" = headless ] || return 0
	say "  - lingering: $LOGIN's user manager stays running without a login, inside $NS (switched on last; nsplit remove switches it off again)"
	if [ "$DRY" = 1 ]; then printf '    would run: %s enable-linger %s   (after everything above is in place; recorded in %s/%s)\n' "$LOGINCTL" "$LOGIN" "$LINGERMARK" "$NAME"; return 0; fi
	[ "$(linger_state "$LOGIN")" = off ] || die "lingering for $LOGIN is on already (or cannot be read): not taking it over"
	mkdir -p "$LINGERMARK"; printf '%s %s\n' "$LOGIN" "$UIDN" > "$LINGERMARK/$NAME"
	undo_push linger_release "$NAME" "$LOGIN" "$UIDN"   # the newest undo step: it runs first, before the placement and the units go
	$LOGINCTL enable-linger "$LOGIN" || die "loginctl enable-linger $LOGIN failed"
	# logind starts the manager itself, but not when its own record of a user whose manager was stopped a moment ago (a removal right before this add) says it is already running: seen in a guest run (the wait
	# below expired with no manager). Asking systemd directly as well makes the outcome independent of that bookkeeping; if the manager is already starting this changes nothing.
	$SYSTEMCTL start "user@$UIDN.service" >/dev/null 2>&1
	manager_wait_up "$UIDN" "${NSPLIT_MANAGER_WAIT:-60}" || die "the user manager of $LOGIN did not start after lingering was switched on (see: journalctl -u user@$UIDN.service)"
}

# step_hostssh (--host-ssh deny only): after everything else, including lingering. The aggregate drop-in is regenerated from the records (this profile's is already written), validated, and sshd is reloaded.
step_hostssh() {
	[ "$HOSTSSH" = deny ] || return 0
	say "  - host SSH: $LOGIN is refused at the host's own sshd (DenyUsers in $HOSTSSH_DROPIN); $RECOVERY keeps host SSH access; the profile's own OpenSSH over the tailnet is not affected"
	HOSTSSH_EXTRA=$LOGIN
	hostssh_apply "$RECOVERY" || die "the host-SSH policy could not be put in force (the previous policy is unchanged)"
	HOSTSSH_EXTRA=
}

step_operator() { # the enrolment's policy, applied explicitly either way: owner-managed = the user is the node's operator, root-managed = nobody is
	local want=""; [ "$MANAGED" = owner ] && want=$LOGIN
	[ "$DRY" = 1 ] && { printf '    would run: tailscale (profile socket) set --operator=%s   (%s-managed)\n' "$want" "$MANAGED"; return 0; }
	ts "$NAME" set --operator="$want" >/dev/null 2>&1 || warn "could not set the Tailscale operator for $NAME ($MANAGED-managed); the add checks below say whether it took"
}
step_scoped() { # owner-managed only: the one sudo rule that lets the user run the two fixed operations of nsplit login
	[ "$MANAGED" = owner ] || return 0
	say "  - sign-in without an administrator: one sudo rule lets $LOGIN run two fixed nsplit operations for this profile ($SUDOERSDIR/nsplit-$NAME)"
	if [ ! -d "$SUDOERSDIR" ] || ! command -v "$VISUDO" >/dev/null 2>&1; then
		warn "sudo is not set up here ($SUDOERSDIR or visudo is missing): $LOGIN cannot sign in without an administrator; run: sudo nsplit login $NAME"; return 0; fi
	case $SCOPED in *[!A-Za-z0-9/._+-]*) warn "the install path of the helper ($SCOPED) has characters a sudo rule cannot carry exactly: $LOGIN cannot sign in without an administrator; run: sudo nsplit login $NAME"; return 0;; esac
	local chk; tmp_new chk; sudoers_text > "$chk"   # checked BEFORE it is installed: a broken file in sudoers.d would break sudo for everyone
	$VISUDO -c -f "$chk" >/dev/null 2>&1 || { tmp_drop "$chk"; die "the sudo rule nsplit generated is not valid sudoers syntax; nothing was installed"; }
	tmp_drop "$chk"
	OWNER=$NAME; put "$SUDOERSDIR/nsplit-$NAME" 440 < <(sudoers_text)
	[ "$DRY" = 1 ] && return 0
	$VISUDO -c -f "$SUDOERSDIR/nsplit-$NAME" >/dev/null 2>&1 || die "the installed sudo rule is not valid sudoers syntax"
}

# ---- checks after applying (each one needs the profile to be live) ---------------------------------------------------------
PROBE_HOST=${NSPLIT_PROBE_HOST:-1.1.1.1}; PROBE_PORT=${NSPLIT_PROBE_PORT:-443}
CONNECT='import socket,sys; socket.create_connection((sys.argv[1],int(sys.argv[2])),4).close()'
# a unix-socket connect that says only whether the path could be traversed: success, or the daemon refusing a connection, both mean "permitted"; EACCES and every other error mean "not"
UNIXCONN='import socket,sys,errno
s=socket.socket(socket.AF_UNIX)
try: s.connect(sys.argv[1])
except OSError as e: sys.exit(0 if e.errno==errno.ECONNREFUSED else 1)'
as_user() { local u=$1 g; shift; g=$(id -g "$u"); setpriv --reuid="$UIDN" --regid="$g" --clear-groups "$@"; }
add_checks() {
	local fails=0 pass=0 o
	okc() { intr_check; pass=$((pass+1)); printf '    PASS  %s\n' "$*"; }
	badc() { intr_check; fails=$((fails+1)); printf '    FAIL  %s\n' "$*"; }
	skipc() { intr_check; printf '    SKIP  %s\n' "$*"; }
	say "  checking:"
	# the guard: exactly the expected uids and rules
	o=$($NFT list table inet nsplit_uid 2>/dev/null)
	if [ "$(grep -c 'meta skuid @uids' <<<"$o")" = 3 ] && grep -q "$UIDN" <<<"$o"; then okc "uid guard loaded with the three rules and uid $UIDN"; else badc "uid guard is not loaded as expected"; fi
	# can the host reach the internet at all? (the control for every negative test below)
	local host_net=0; timeout 6 python3 -I -c "$CONNECT" "$PROBE_HOST" "$PROBE_PORT" 2>/dev/null && host_net=1
	if [ $host_net = 1 ]; then
		as_user "$LOGIN" timeout 6 python3 -I -c "$CONNECT" "$PROBE_HOST" "$PROBE_PORT" 2>/dev/null && badc "$LOGIN in the host namespace can still reach the internet" || okc "NEGATIVE: $LOGIN in the host namespace has no network"
		"$LIB/nsplit-run" "$NAME" -- timeout 8 python3 -I -c "$CONNECT" "$PROBE_HOST" "$PROBE_PORT" 2>/dev/null && okc "CONTROL: $LOGIN's namespace has internet access" || badc "$LOGIN's namespace has no internet access"
	else skipc "network tests (this host cannot reach 1.1.1.1:443 right now, so a failure would prove nothing)"; fi
	as_user "$LOGIN" python3 -I -c 'import socket; a=socket.socket(); a.bind(("127.0.0.1",0)); a.listen(1); socket.create_connection(a.getsockname(),2).close()' 2>/dev/null && okc "CONTROL: $LOGIN keeps loopback" || badc "loopback is broken for $LOGIN"
	# D-Bus
	local RC='busctl --system --no-pager call org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.DBus.Properties Get ss org.freedesktop.resolve1.Manager DNSStubListener'
	if $RC >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		o=$(as_user "$LOGIN" $RC 2>&1); grep -qiE 'access denied|AccessDenied|not allowed' <<<"$o" && okc "NEGATIVE: $LOGIN's call to the host's systemd-resolved is refused by the bus" || badc "$LOGIN can still call the host's systemd-resolved"
	else skipc "D-Bus test (systemd-resolved is not answering on the bus: nothing to deny)"; fi
	# the daemon is inside the namespace
	local erc=0 want=""; P_NS=$NS; endpoint_check "$NAME" || erc=$?
	if [ $erc = 0 ]; then okc "the profile's Tailscale daemon runs inside $NS and not in the host network namespace"
	elif [ $erc = 10 ]; then badc "$ENDPOINT_WHY"
	else badc "the profile's Tailscale daemon could not be inspected: $ENDPOINT_WHY"; fi
	# the daemon's control socket: its directory lets root and the owner in and nobody else (nsplit-sockdir)
	local sock sdo; sock=$(sock_of "$NAME")
	if sdo=$("$LIB/nsplit-sockdir" "$NAME" check 2>&1); then okc "the daemon's socket directory is reachable only by root and $LOGIN"; else badc "the daemon's socket directory is not private: ${sdo#*: }"; fi
	as_user "$LOGIN" python3 -I -c "$UNIXCONN" "$sock" 2>/dev/null && okc "CONTROL: $LOGIN can reach their own daemon's socket" || badc "$LOGIN cannot reach their own daemon's socket"
	setpriv --reuid=65534 --regid=65534 --clear-groups python3 -I -c "$UNIXCONN" "$sock" 2>/dev/null && badc "NEGATIVE: another user (uid 65534) can reach $NAME's daemon socket" || okc "NEGATIVE: another user (uid 65534) is refused at $NAME's daemon socket"
	[ "$MANAGED" = owner ] && want=$LOGIN
	if o=$(node_operator "$NAME"); then [ "$o" = "$want" ] && okc "the Tailscale operator is ${want:-nobody (root only)}, as the $MANAGED-managed policy says" || badc "the Tailscale operator is '${o:-nobody}', the $MANAGED-managed policy calls for '${want:-nobody}'"
	else badc "the Tailscale operator could not be read from the node"; fi
	# placement as systemd sees it
	[ "$($SYSTEMCTL show -p NetworkNamespacePath --value "user@$UIDN.service" 2>/dev/null)" = "/run/netns/$NS" ] && okc "systemd will start user@$UIDN.service inside $NS" || badc "systemd does not show the placement for user@$UIDN.service"
	# the login gate
	if [ "$MODE" = headless ] && [ ! -e "$PAMDIR/plasmalogin" ]; then grep -q 'nsplit-pam-gate' "$PAMDIR/login" && okc "the console login stack carries the gate (this machine has no Plasma login manager)" || badc "the gate lines are missing from the console login stack"
	else grep -q 'nsplit-pam-gate' "$PAMDIR/plasmalogin" && grep -q 'nsplit-pam-gate' "$PAMDIR/login" && okc "both login stacks carry the gate" || badc "the gate lines are missing from a login stack"; fi
	if [ -z "$(manager_pid "$UIDN")" ]; then
		PAM_TYPE=open_session PAM_USER="$LOGIN" PAM_SERVICE=login "$GATE" "$LOGIN" "$UIDN" "$NS" >/dev/null 2>&1 && badc "NEGATIVE: the gate lets $LOGIN in with no user manager" || okc "NEGATIVE: the gate refuses $LOGIN while no user manager is placed"
	else skipc "gate refusal test ($LOGIN has a running user manager)"; fi
	PAM_TYPE=open_session PAM_USER=root PAM_SERVICE=login "$GATE" "$LOGIN" "$UIDN" "$NS" >/dev/null 2>&1 && okc "CONTROL: another user passes the gate untouched" || badc "another user is blocked by the gate"
	if [ "$MODE" = headless ]; then
		local mp ref
		[ "$(linger_state "$LOGIN")" = on ] && [ -e "$LINGERMARK/$NAME" ] && okc "lingering is on for $LOGIN and nsplit recorded that it switched it on" || badc "lingering is not on for $LOGIN, or nsplit's record of it is missing"
		mp=$(manager_pid "$UIDN"); ref=$(ns_obj "$NETNSRUN/$NS")
		if [ -n "$mp" ] && [ -n "$ref" ] && [ "$(ns_obj "/proc/$mp/ns/net")" = "$ref" ]; then okc "$LOGIN's user manager (pid $mp), running without a login, is inside $NS"
		elif [ -n "$mp" ]; then badc "$LOGIN's user manager (pid $mp) is not inside $NS"; else badc "no user manager is running for $LOGIN although lingering is on"; fi
		[ "$(unit_state "nsplit-sshd@$NAME.service")" = active ] && okc "the namespace OpenSSH server is running" || badc "the namespace OpenSSH server is not running"
		grep -q "nsplit-pam-gate $LOGIN $UIDN $NS" "$PAMDIR/$PAMSVC" 2>/dev/null && [ -x "$GATE" ] && okc "the namespace sshd's own PAM service carries the placement gate" || badc "the placement gate is missing from $PAMDIR/$PAMSVC"
		o=$(node_ssh "$NAME")
		case $o in off) okc "built-in Tailscale SSH is off on the node";; on) badc "built-in Tailscale SSH is ON for the node of a headless profile";; *) skipc "built-in Tailscale SSH setting (the node's preferences could not be read)";; esac
	fi
	if [ "$HOSTSSH" = deny ]; then
		local hp nseff
		hp=$(hostssh_verify "$RECOVERY" $(hostssh_denied_users))
		[ -z "$hp" ] && okc "the host's sshd (sshd -t, sshd -T) refuses $LOGIN and still lets $RECOVERY in" || badc "host SSH: $(tr '\n' ';' <<<"$hp")"
		nseff=$(/usr/bin/sshd -T -f "$ETC/ssh/$NAME/sshd_config" 2>/dev/null)
		if grep -qi '^denyusers' <<<"$nseff"; then badc "the profile's own namespace sshd carries DenyUsers"; else okc "the profile's own namespace sshd configuration is untouched by the host-SSH policy (no DenyUsers there)"; fi
	fi
	printf '  %s passed, %s failed\n' "$pass" "$fails"
	[ $fails = 0 ]
}

# ---- the command ---------------------------------------------------------------------------------------------------------
apply_all() {
	# an interrupt that arrives during a step is acted on here, between steps, when every change so far has its undo registered
	step_files; intr_check; step_guard; intr_check; step_dbus; intr_check; step_start; intr_check; step_ssh; intr_check; step_operator; intr_check; step_scoped; intr_check; step_placement; intr_check; step_gate; intr_check; step_linger; intr_check; step_hostssh; intr_check
}

cmd_add() {
	local yes=0 ssh_arg="" ans why
	DRY_REQ=0; BUSY_NOTE=""; MANAGED=owner; MARK_MADE=0; LOGIN=""; NAME=""; SSH=none; HOSTNAME_ARG=""; UPLINKS_ARG=""; ACK_TS=0; MODE=desktop; HOSTSSH=""; RECOVERY=""; NO_SESSION_CHECK=0
	while [ $# -gt 0 ]; do case $1 in
		-h|--help) usage_add; return 0;;
		--dry-run) DRY_REQ=1; shift;; --yes|-y) yes=1; shift;;
		--name) NAME=${2:?--name needs a value}; shift 2;;
		--host-ssh) HOSTSSH=${2:?--host-ssh needs deny}; shift 2;;
		--recovery-user) RECOVERY=${2:?--recovery-user needs an account name}; shift 2;;
		--no-session-check) NO_SESSION_CHECK=1; shift;;
		--mode) MODE=${2:?--mode needs desktop|headless}; shift 2;;
		--mode=*) MODE=${1#--mode=}; shift;;
		--ssh) ssh_arg=${2:?--ssh needs none|tailscale|openssh}; shift 2;;
		--accept-tailscale-ssh-risk) ACK_TS=1; shift;;
		--hostname) HOSTNAME_ARG=${2:?--hostname needs a value}; shift 2;;
		--uplinks) UPLINKS_ARG=${2:?--uplinks needs a list}; shift 2;;
		--root-managed) MANAGED=root; shift;;
		-*) die "unknown option $1 (see: nsplit add --help)";;
		*) [ -z "$LOGIN" ] || die "one user at a time"; LOGIN=$1; shift;;
	esac; done
	[ -n "$LOGIN" ] || { usage_add >&2; exit 2; }
	case $MODE in desktop|headless) ;; *) die "--mode must be desktop or headless";; esac
	case $HOSTSSH in ""|deny) ;; *) die "--host-ssh must be deny (the default is no host-SSH policy)";; esac
	{ [ -z "$RECOVERY" ] || [ "$HOSTSSH" = deny ]; } || die "--recovery-user only goes with --host-ssh deny"
	if [ "$MODE" = headless ]; then MANAGED=root; [ -n "$ssh_arg" ] || ssh_arg=openssh; fi   # a headless profile is always root-managed and reached through the namespace OpenSSH server
	[ -z "$ssh_arg" ] || SSH=$ssh_arg
	case $SSH in none|tailscale|openssh) ;; *) die "--ssh must be none, tailscale or openssh";; esac
	[ "$DRY_REQ" = 1 ] || need_root
	LOGIN_ARG=$LOGIN; ARG_UID=$(user_uid "$LOGIN")
	add_derive
	say "nsplit add: $LOGIN$( [ "$NAME" != "$LOGIN" ] && echo " (profile $NAME)" )"
	add_preflight || { say "Nothing was changed."; exit 1; }
	[ -z "$BUSY_NOTE" ] || info "NOTE: a real run would be refused right now: $BUSY_NOTE"
	[ -z "${HOSTSSH_NOTE:-}" ] || info "NOTE: $HOSTSSH_NOTE"
	say "  uid $UIDN   namespace $NS   link $HOST_IP <-> $NS_IP   node name $TS_HOSTNAME   uplinks: $UPLINKS_USED   ssh: $SSH   management: $MANAGED   mode: $MODE"
	say "  LIMIT: only logins and user managers are checked. Programs of $LOGIN outside any session (cron/at jobs, system services running as uid $UIDN, sudo -u or su from another account) are not detected: they lose their host network when the guard loads and are not placed in $NS."
	[ "$MODE" != headless ] || headless_notice
	ssh_notice
	say; say "Changes:"
	DRY=1; apply_all; DRY=0
	if [ "$DRY_REQ" = 1 ]; then say; [ -z "$BUSY_NOTE" ] || say "NOTE: a real run would be refused right now: $BUSY_NOTE"; say "Dry run: nothing was changed."; return 0; fi
	if [ "$yes" != 1 ]; then
		say; read -r -p "Apply these changes? [y/N] " ans </dev/tty || ans=n
		case $ans in y|Y|yes) ;; *) say "Nothing was changed."; return 1;; esac
	fi
	why=$(busy_reason) && { say "Nothing was changed."; die "$why"; }   # re-checked after the confirmation: it may have waited a long time
	say; say "Applying:"
	APPLYING=1   # from here a failure or an interrupt undoes what was done (nsplit_atexit)
	apply_all
	if ! add_checks; then rollback_all; APPLYING=0
		[ "$UNDO_FAILED" = 0 ] || die "a check failed, and not everything this command did could be undone: the undo steps that failed are listed above; nsplit status and nsplit remove show and finish what is left"
		die "a check failed; everything this command did was undone"; fi
	APPLYING=0
	say; say "Done. $LOGIN has a network of their own (not yet signed in to Tailscale)."
	ssh_notice
	if [ "$MODE" = headless ]; then
		headless_notice
		say "Next:  sudo nsplit login $NAME     (an administrator runs it; the user opens the sign-in link and approves their own Tailscale account)"
		say "       Then $LOGIN puts a public key in their ~/.ssh and connects with ordinary OpenSSH to the profile's Tailscale address (or name), and starts their own services with systemctl --user."
		say "       $LOGIN's user manager is already running inside $NS; their enabled user services start at boot, stay up across logouts, and run in the profile's network."
		say "       A login of $LOGIN is accepted only when that manager is running inside $NS: otherwise it is refused (journalctl -t nsplit-pam-gate, nsplit status)."
	else
	say "Next:  nsplit login $NAME     (the user opens the sign-in link and approves their own Tailscale account)"
	say "       Their next login uses the new network."
	say "       If a login of $LOGIN is ever refused, a console login prints the reason; the graphical login screen just resets, and the reason is in the log (journalctl -t nsplit-pam-gate) and in: nsplit status"
	say "       Reminder: programs of $LOGIN running outside any login session (cron/at jobs, system services run as this uid) have no host network now and are not placed in $NS."
	fi
}
