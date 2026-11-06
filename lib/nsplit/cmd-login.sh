# shellcheck shell=bash
# nsplit login: sign the profile's OWN Tailscale node in to the user's own account, then switch on and prove the profile's private DNS.
# The profile's user (when the enrolment is owner-managed) or an administrator runs it; Tailscale prints a sign-in link to open in a browser.
# It can only ever talk to this profile's daemon socket and refuses unless that daemon really runs inside the profile's namespace.
# Two things need administrator rights and an ordinary user gets exactly those two, as fixed operations (nsplit-scoped, through one sudo rule written by `nsplit add`):
# looking at /proc/PID/ns of the root-owned daemon (the endpoint check) and writing the profile's DNS files. /proc permissions are not loosened for anyone.

usage_login() { cat <<'EOF2'
usage: nsplit login [PROFILE] [--dry-run]
  Sign the profile's own Tailscale node in to the profile owner's account, then switch on and prove the profile's private DNS. Prints a link; open it in a browser and approve it.
  Existing private DNS is refreshed only when its files still match nsplit's records. Files changed by hand are refused; readiness always requires fresh checks.
  Run it as the profile's own user (when the profile is owner-managed, the default) or as an administrator: sudo nsplit login PROFILE. With no PROFILE it means the user running it.
  It reports three things separately:   Registered (the node is signed in)   Operator (who may run tailscale for this node)   Network (the private DNS is in force and proved).
  Exit status: 0 = all three are as they should be;  1 = not registered (the sign-in did not happen);  3 = registered, but the operator or the network is not as it should be (the lines say what, and what finishes it).
  An ordinary user needs no sudo rights of their own: when the profile was added, nsplit wrote ONE sudo rule for that user and that profile that allows exactly two fixed operations
  (check that the profile's Tailscale daemon is inside the profile's namespace; switch on the profile's private DNS). A profile enrolled with --root-managed has no such rule: an administrator signs it in.
  Nothing about the host's own Tailscale is touched.
EOF2
}

# endpoint_check NAME: is the profile's Tailscale daemon really inside the profile's namespace, and not in the host's? Needs administrator rights (/proc/PID/ns is root-only). Needs profile_load NAME.
#   0  = verified
#   10 = inspected and WRONG: the daemon is in the host namespace or in some other namespace (ENDPOINT_WHY says which)
#   11 = could NOT be inspected: no process id, an unreadable /proc entry, a failed command (ENDPOINT_WHY says which). Not a match and not a mismatch: nothing was learned.
endpoint_check() {
	local n=$1 pid mine host ident
	ENDPOINT_WHY=""
	pid=$($SYSTEMCTL show -p MainPID --value "nsplit-tailscaled@$n.service" 2>/dev/null) || { ENDPOINT_WHY="systemctl did not answer for nsplit-tailscaled@$n"; return 11; }
	case $pid in ''|*[!0-9]*) ENDPOINT_WHY="nsplit-tailscaled@$n reported no process id"; return 11;; esac
	[ "$pid" -gt 1 ] || { ENDPOINT_WHY="nsplit-tailscaled@$n has no main process"; return 11; }
	mine=$(ns_obj "/proc/$pid/ns/net"); [ -n "$mine" ] || { ENDPOINT_WHY="the daemon's network namespace (/proc/$pid/ns/net) could not be read"; return 11; }
	host=$(ns_obj "/proc/$HOSTNS_PID/ns/net"); [ -n "$host" ] || { ENDPOINT_WHY="the host network namespace (/proc/$HOSTNS_PID/ns/net) could not be read"; return 11; }
	[ "$mine" != "$host" ] || { ENDPOINT_WHY="that daemon is in the HOST network namespace"; return 10; }
	ident=$($IP netns identify "$pid" 2>/dev/null) || { ENDPOINT_WHY="ip netns identify failed for the daemon (pid $pid)"; return 11; }
	[ "$ident" = "$P_NS" ] || { ENDPOINT_WHY="that daemon is in ${ident:-no named namespace}, not in $P_NS"; return 10; }
	return 0
}

# verify_endpoint NAME: endpoint_check as an administrator, or through the profile's fixed sudo rule as its user. Returns 0 or dies with the truthful reason.
verify_endpoint() {
	local n=$1 rc out
	if is_admin; then endpoint_check "$n"; rc=$?; out=$ENDPOINT_WHY
	else
		out=$($SUDO -n -- "$SCOPED" "$n" verify 2>&1); rc=$?
		case $rc in 0|10|11|12) ;; *) die "this account cannot run the administrator check that signing in needs (the one sudo rule nsplit gave $P_LOGIN for it is missing, or sudo is not available). An administrator can sign the node in: sudo nsplit login $n";; esac
	fi
	case $rc in
	0) return 0;;
	10) die "refusing: $out";;
	11) die "could not verify the profile's Tailscale daemon, so nothing was started: $out";;
	*) die "refused: $out";;
	esac
}

# node_summary NAME: host name, first address and tailnet of the signed-in node
node_summary() { local js h ip su; js=$(ts "$1" status --json 2>/dev/null)
	h=$(pyj '(d.get("Self") or {}).get("HostName","")' <<<"$js"); ip=$(pyj '" ".join((d.get("Self") or {}).get("TailscaleIPs",[])[:1])' <<<"$js")
	su=$(pyj '(d.get("CurrentTailnet") or {}).get("MagicDNSSuffix","")' <<<"$js"); printf '%s%s%s' "${h:-?}" "${ip:+, $ip}" "${su:+, tailnet $su}"; }
# node_operator NAME: the operator the node really has right now (empty = root only); fails when it cannot be read
node_operator() { local o; o=$(ts "$1" debug prefs 2>/dev/null) || return 1; [ "$(pyj '"ok"' <<<"$o")" = ok ] || return 1; pyj 'd.get("OperatorUser","")' <<<"$o"; }

# node_ssh NAME: "on" or "off": whether the node's built-in Tailscale SSH server is enabled right now (RunSSH in its preferences); fails when that cannot be read. Never "off" for a value that is not there.
node_ssh() { local o v; o=$(ts "$1" debug prefs 2>/dev/null) || return 1; v=$(pyj 'd.get("RunSSH")' <<<"$o"); case $v in True) printf on;; False) printf off;; *) return 1;; esac; }

# login_socket_check NAME: a fresh read-only check, including the kernel hard-link prerequisite and visible socket link count. Never changes permissions or machine policy.
login_socket_check() {
	local n=$1 out rc
	out=$("$LIB/nsplit-sockdir" "$n" check 2>&1); rc=$?
	case $rc in
	0) SOCKET_WHY=; return 0;;
	1) SOCKET_WHY="the profile's socket protections are not in place: $out"; return 1;;
	3) SOCKET_WHY="the profile's socket directory is absent (an administrator can run: sudo nsplit start $n)"; return 1;;
	*) SOCKET_WHY="the profile's socket protections could not be verified: $out"; return 2;;
	esac
}

# report_state NAME DNS_RESULT [DNS_REASON]: the Operator and Network lines. Only a successful DNS operation in THIS invocation can report ready.
# An omitted result means not verified. Returns 0 when both are as they should be, 3 when not. Needs profile_load NAME.
report_state() {
	local n=$1 dns_rc=${2:-2} dns_why=${3:-DNS was not verified during this invocation} want have rc=0 dns socket_rc pol=${P_MANAGED:-not recorded: treated as root-managed}
	want=$(profile_operator)
	if have=$(node_operator "$n"); then
		if [ "$have" = "$want" ]; then say "Operator:   ${want:-none (root only)}   (policy: $pol, as enrolled)"
		else say "Operator:   MISMATCH: the node's operator is '${have:-none}' but this profile's policy ($pol) calls for '${want:-none}'. An administrator sets it: sudo nsplit ts $n set --operator=$want"; rc=3; fi
	else say "Operator:   could not be read from the node"; rc=3; fi
	dns=$(dns_state "$n")
	login_socket_check "$n"; socket_rc=$?
	if [ "$dns_rc" = 0 ] && [ "$dns" = split ] && [ "$socket_rc" = 0 ]; then say "Network:    ready (the split resolver is configured; public and private DNS resolution checks passed during this invocation)"
	else
		[ "$dns_rc" != 0 ] || dns_why="the profile's split resolver is not in force ($dns resolver file)"
		[ "$socket_rc" = 0 ] || dns_why=$SOCKET_WHY
		say "Network:    NOT ready: $dns_why. Fix the reported problem and run: nsplit login $n   (an administrator can run: sudo nsplit login $n)"; rc=3
	fi
	return $rc
}

# complete_networking NAME: switch on and prove the private DNS (administrator directly, an ordinary user through the profile's fixed rule), then report. 0 = everything as it should be, 3 = not.
complete_networking() {
	local n=$1 rc why
	if is_admin; then
		dns_apply "$n"; rc=$?; why=${DNS_WHY:-the DNS operation did not provide a result}
	else
		$SUDO -n -- "$SCOPED" "$n" dns; rc=$?
		case $rc in
		0) why=;;
		20) why="the current DNS verification did not succeed (the reason is printed above)";;
		21) why="the administrator DNS step stopped on an error (the reason is printed above)";;
		12) why="the administrator DNS step refused this invocation (the reason is printed above)";;
		*) why="this account could not run its fixed administrator DNS step (exit $rc); an administrator should check its nsplit sudo rule";;
		esac
	fi
	report_state "$n" "$rc" "$why"
}

cmd_login() {
	local pn="" dry=0 sock state ssh_flag op
	while [ $# -gt 0 ]; do case $1 in -h|--help) usage_login; return 0;; --dry-run) dry=1; shift;; -*) die "unknown option $1";; *) pn=$1; shift;; esac; done
	pn=$(resolve_profile "$pn") || die "no nsplit profile for ${pn:-$(id -un)} (see: nsplit status)"
	profile_load "$pn"; sock=$(sock_of "$pn")
	if ! is_admin; then
		[ "$(id -u)" = "$P_UIDN" ] || die "$pn is not your profile; an administrator signs it in: sudo nsplit login $pn"
		if [ "${P_MANAGED:-}" != owner ]; then
			die "$pn is managed by an administrator ($( [ -n "${P_MANAGED:-}" ] && echo "enrolled with --root-managed" || echo "its record does not say who manages it, so it is treated that way")): an administrator signs it in: sudo nsplit login $pn"
		fi
	fi
	login_socket_check "$pn" || die "$SOCKET_WHY; an administrator must resolve this before signing in"
	[ "$sock" != /run/tailscale/tailscaled.sock ] || die "internal error: the target socket is the host daemon's"
	[ -S "$sock" ] || die "the profile's Tailscale daemon is not running (nsplit start $pn)"
	verify_endpoint "$pn"
	state=$(backend_state "$pn")
	ssh_flag=false; [ "$P_SSH" = tailscale ] && ssh_flag=true
	op=$(profile_operator)
	case $state in
	Running) say "Registered: yes ($pn was already signed in: $(node_summary "$pn"))"; [ "$dry" = 1 ] && return 0; complete_networking "$pn"; return $?;;
	NeedsLogin|NoState|Stopped|"") ;;
	NeedsMachineAuth) die "the node is waiting for approval in the tailnet's admin console (machine authorization); nothing more to do here";;
	*) die "the node is in state '$state'; not a state this command signs in from (nsplit status -v $pn)";;
	esac
	# every setting nsplit manages is passed explicitly: tailscale up resets what it is not told, and which settings it keeps differs between root and the node's operator
	local cmd=("$TS_BIN" --socket="$sock" up --hostname="$P_TS_HOSTNAME" --accept-dns=false --ssh="$ssh_flag" --operator="$op")
	say "profile : $pn   node: $P_TS_HOSTNAME   (daemon verified inside $P_NS)"
	say "command : ${cmd[*]}"
	[ "$P_SSH" != tailscale ] || say "NOTICE   : this profile is enrolled with --ssh tailscale: the SSH rules of the tailnet policy $P_LOGIN controls choose the local account a login becomes (any account on this machine, root included); nsplit cannot limit them and its login gate does not cover these sessions."
	[ "$dry" = 1 ] && { say "(dry run: not executed)"; return 0; }
	say "Open the link printed below in a browser and sign in with $P_LOGIN's own Tailscale account."
	"${cmd[@]}" || die "sign-in did not complete (run it again; nothing else was changed)"
	[ "$(backend_state "$pn")" = Running ] || die "the node is not Running after sign-in (nsplit status -v $pn)"
	say "Registered: yes (signed in: $(node_summary "$pn"))"
	complete_networking "$pn"
}
