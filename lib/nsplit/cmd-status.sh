# shellcheck shell=bash
# nsplit status: what is actually true now, per profile, and what needs attention. Read-only; works without root (some checks need root and say so).

usage_status() { cat <<'EOF2'
usage: nsplit status [-v] [PROFILE]
  Shows each profile as one line: Ready, Needs sign-in, Needs new login, Stopped, Degraded or Not checked, with what to do next.
  -v   also list every individual check (PASS / FAIL / UNKNOWN)
  Exit status: 0 if every profile shown is Ready; 2 if a profile it could check is not Ready; 3 if everything it could check is Ready but some profile could not be checked (Not checked).
  Some checks need root, and a profile's Tailscale daemon is reachable only by its owner and administrators: what a check cannot read is shown as UNKNOWN or Not checked, never as fine and never as broken.
  The mount tables of the running services (daemon, namespace sshd, user manager) are read too: a lost private /etc/resolv.conf or /run/tailscale, or a running service whose unit no longer declares it, is Degraded; one that cannot be read (needs root) is Not checked.
  The node's real built-in Tailscale SSH setting is read and compared with what the profile record says: ON although the record says none or openssh is a security problem (Degraded: the tailnet
  policy can then authorize logins as other local accounts or root, which nsplit's login gate does not cover); a profile enrolled with --ssh tailscale always carries that boundary as a warning.
  A headless profile (nsplit add --mode headless) is also checked for lingering, for its user manager running inside the profile's namespace without a login, for the namespace OpenSSH server and for its own
  PAM service with the placement gate; a manager that is not running, not placed, or whose placement cannot be read is not Ready (there is no next login that would place it).
  Current DNS resolution is checked inside the profile's namespace when run as root. Without those rights, configured DNS is shown separately from unverified current resolution; status never invokes the mutating login helper.
EOF2
}

# guard_read UID: read the exact uid set as numeric JSON, without turning a failed query or parse into a membership claim. Sets
#   GUARD = listed | missing | absent | unreadable | unparsed,  GUARD_WHY = one factual sentence,  GUARD_TRIES = reads made,  GUARD_FIRST = the first failure's message (empty if none)
#   listed     exactly one inet/nsplit_uid/uids set of type uid was read and the uid is in it
#   missing    that complete set was read and understood and the uid is NOT in it (including an empty set)
#   absent     nft answered that the requested set or its table does not exist
#   unreadable nft failed for another reason (after 3 reads, 0.2 s apart: a read can lose a race with a ruleset change); nothing is known about the guard
#   unparsed   nft succeeded but the complete JSON, exact set identity/type or numeric elements could not be understood; nothing is known about the guard
# Numeric scalar elements and inclusive {"range":[LOW,HIGH]} elements follow libnftables-json(5). Other sets never supply this set's members.
guard_read() {
	local uid=$1 out="" rc=1 first="" v
	GUARD=""; GUARD_WHY=""; GUARD_TRIES=0; GUARD_FIRST=""
	while [ "$GUARD_TRIES" -lt 3 ]; do
		GUARD_TRIES=$((GUARD_TRIES+1)); out=$(LC_ALL=C $NFT -n -j list set inet nsplit_uid uids 2>&1); rc=$?
		[ $rc = 0 ] && break
		first=${out%%$'\n'*}; [ -n "$GUARD_FIRST" ] || GUARD_FIRST=$first
		case $rc:$out in 1:*"Error: No such file or directory"*) GUARD=absent; GUARD_WHY="nft says the set inet nsplit_uid uids or its table does not exist"; return 0;; esac
		[ "$GUARD_TRIES" -lt 3 ] && sleep 0.2
	done
	[ $rc = 0 ] || { GUARD=unreadable; GUARD_WHY="nft could not read the set inet nsplit_uid uids in $GUARD_TRIES tries (exit $rc: ${first:-no message})"; return 0; }
	v=$(python3 -I -c '
import json,sys
def fail(reason):
    raise ValueError(reason)
def unique(pairs):
    obj={}
    for key,value in pairs:
        if key in obj: fail("duplicate JSON key")
        obj[key]=value
    return obj
def number(value):
    if type(value) is not int or not 0<=value<=4294967295:
        fail("a UID is not an unsigned 32-bit integer")
    return value
def interval(value):
    if type(value) is int:
        return (number(value),number(value))
    if type(value) is dict and set(value)=={"elem"}:
        item=value["elem"]
        if type(item) is not dict or "val" not in item or not set(item)<={"val","comment"}:
            fail("unsupported set-element metadata")
        if "comment" in item and type(item["comment"]) is not str:
            fail("invalid set-element comment")
        value=item["val"]
        if type(value) is int:
            return (number(value),number(value))
    if type(value) is not dict or set(value)!={"range"}:
        fail("unsupported numeric set element")
    bounds=value["range"]
    if type(bounds) is not list or len(bounds)!=2:
        fail("invalid UID range")
    low,high=map(number,bounds)
    if low>high: fail("reversed UID range")
    return (low,high)
try:
    data=json.load(sys.stdin,object_pairs_hook=unique,parse_constant=lambda _: fail("non-JSON numeric constant"))
    if type(data) is not dict or set(data)!={"nftables"} or type(data["nftables"]) is not list:
        fail("expected a complete nftables JSON object")
    matches=[]
    for entry in data["nftables"]:
        if type(entry) is not dict or len(entry)!=1:
            fail("invalid nftables object")
        kind,obj=next(iter(entry.items()))
        if kind not in {"metainfo","table","set"} or type(obj) is not dict:
            fail("unexpected object in the set response")
        if kind=="metainfo" and "json_schema_version" in obj:
            if type(obj["json_schema_version"]) is not int or obj["json_schema_version"]!=1:
                fail("unsupported nftables JSON schema")
        if kind=="set" and (obj.get("family"),obj.get("table"),obj.get("name"))==("inet","nsplit_uid","uids"):
            matches.append(obj)
    if len(matches)!=1: fail("expected exactly one set inet nsplit_uid uids")
    target=matches[0]
    if target.get("type")!="uid" or "map" in target:
        fail("the requested set is not of type uid")
    elements=target.get("elem",[])
    if type(elements) is not list: elements=[elements]
    ranges=[interval(value) for value in elements]
    if "count" in target:
        count=target["count"]
        if type(count) is not int or count<0 or bool(count)!=bool(ranges):
            fail("set count contradicts its listed elements")
    wanted=number(int(sys.argv[1]))
    state="listed" if any(low<=wanted<=high for low,high in ranges) else "missing"
    members=", ".join(str(low) if low==high else "%d-%d"%(low,high) for low,high in ranges)
    print(state+" "+(members or "(empty)"))
except (ValueError,TypeError,KeyError,RecursionError) as error:
    print(str(error))
    sys.exit(3)
' "$uid" <<<"$out") || { GUARD=unparsed; GUARD_WHY="nft answered, but the JSON for set inet nsplit_uid uids could not be interpreted (${v:-parser did not answer})"; return 0; }
	GUARD=${v%% *}; GUARD_WHY="the loaded set lists: ${v#* }"
	[ "$GUARD" = listed ] || GUARD_WHY="the set was read and lists: ${v#* }"
	return 0
}

# profile_status NAME -> S_STATE, S_DETAIL, S_CHECKS (lines "PASS|FAIL|UNKNOWN|INFO text")
profile_status() {
	local n=$1 ssh_now st_ns st_ts st_fw st_dns be js suffix ips host mgr mgr_ns want dns dns_rc pf sd sdo sdrc secfail="" noperm="" unverified="" mrows mrc mmatch=0 mst munit mdest mmn mwhy
	S_CHECKS=(); S_STATE=""; S_DETAIL=""
	profile_load "$n" || { S_STATE=Degraded; S_DETAIL="profile file unreadable"; return 1; }
	chk() { S_CHECKS+=("$1 $2"); }
	st_ns=$(unit_state "nsplit-netns@$n.service"); st_fw=$(unit_state nsplit-firewall.service); st_ts=$(unit_state "nsplit-tailscaled@$n.service")
	[ "$st_ns" = active ] && chk PASS "namespace $P_NS is up" || chk FAIL "namespace unit is $st_ns"
	[ "$st_fw" = active ] && chk PASS "firewall unit is active" || chk FAIL "firewall unit is $st_fw"
	[ "$st_ts" = active ] && chk PASS "the profile's Tailscale daemon is active" || chk FAIL "the profile's Tailscale daemon is $st_ts"
	be=""; js=""
	# the daemon's socket directory is reachable only by root and the profile's owner (nsplit-sockdir): for anyone else the profile cannot be read, which is not the profile being unhealthy
	sd=$(dirname "$(sock_of "$n")")
	if [ -d "$sd" ] && [ ! -x "$sd" ]; then noperm=1
	elif [ -S "$(sock_of "$n")" ]; then js=$(ts "$n" status --json 2>/dev/null); be=$(pyj 'd.get("BackendState","")' <<<"$js"); fi
	if [ -n "$be" ]; then
		suffix=$(pyj '(d.get("CurrentTailnet") or {}).get("MagicDNSSuffix","")' <<<"$js")
		ips=$(pyj '" ".join((d.get("Self") or {}).get("TailscaleIPs",[])[:1])' <<<"$js"); host=$(pyj '(d.get("Self") or {}).get("HostName","")' <<<"$js")
		[ "$be" = Running ] && chk PASS "Tailscale node ${host:-?} is Running${ips:+ ($ips)}${suffix:+, tailnet $suffix}" || chk FAIL "Tailscale node state is $be"
	elif [ -n "$noperm" ]; then chk UNKNOWN "Tailscale node state (not readable by you: this profile's daemon is reachable only by its owner and administrators; an administrator can check it: sudo nsplit status $n)"; unverified=1
	else chk UNKNOWN "Tailscale node state (daemon socket not answering)"; fi
	sdo=$("$LIB/nsplit-sockdir" "$n" check 2>&1); sdrc=$?
	case $sdrc in
	0) chk PASS "the daemon's socket directory is reachable only by root and $P_LOGIN; hard-link protection is enabled and any present socket has one link";;
	1) secfail="the daemon's socket protections are not in place (${sdo#loose: }); an administrator must resolve this and run: sudo nsplit start $n"; chk FAIL "$secfail";;
	3) chk INFO "the daemon's socket directory does not exist (its daemon is not running)";;
	*) chk UNKNOWN "whether the daemon's socket protections are in place (${sdo#unknown: })"; unverified=1;;
	esac
	dns=$(dns_state "$n")
	case $dns in
	split)
		chk INFO "private DNS: split resolver configured (current resolution is checked separately)"
		if [ "$be" = Running ]; then
			st_dns=$(unit_state "nsplit-dns@$n.service")
			case $st_dns in
			active)
				if is_admin; then
					# This verifier only reads the configuration and sends fresh queries. Never call the mutating scoped DNS operation from status.
					dns_verify "$n"; dns_rc=$?
					case $dns_rc in
					0) chk PASS "private DNS: $DNS_WHY";;
					1) chk FAIL "private DNS: $DNS_WHY";;
					*) chk UNKNOWN "private DNS: $DNS_WHY"; unverified=1;;
					esac
				else chk UNKNOWN "private DNS: current resolution inside the namespace needs administrator rights (sudo nsplit status $n)"; unverified=1; fi;;
			inactive|failed) chk FAIL "private DNS: the split resolver unit is $st_dns (an administrator can start it: sudo nsplit start $n)";;
			*) chk UNKNOWN "private DNS: the split resolver unit is $st_dns; current resolution was not verified"; unverified=1;;
			esac
		else chk INFO "private DNS: current resolution cannot be verified until the node is readable and Running"; fi;;
	public) [ "$be" = Running ] && chk FAIL "private DNS: still on public resolvers only (finish with: nsplit login $n; an administrator can run: sudo nsplit login $n)" || chk INFO "private DNS: public resolvers until sign-in";;
	*) chk FAIL "private DNS: resolver file is '$dns'";;
	esac
	case ${P_MANAGED:-} in
	owner) if [ -f "$SUDOERSDIR/nsplit-$n" ]; then chk PASS "owner-managed: $P_LOGIN may sign in and finish the DNS themselves (sudo rule $SUDOERSDIR/nsplit-$n)"
		elif ! is_admin && [ ! -x "$SUDOERSDIR" ]; then chk UNKNOWN "owner-managed: whether the sudo rule for $P_LOGIN exists (the sudoers directory is root-only, so it cannot be read without root)"
		else chk WARN "owner-managed, but the sudo rule for $P_LOGIN is missing ($SUDOERSDIR/nsplit-$n): sign-in needs an administrator: sudo nsplit login $n"; fi;;
	root) chk INFO "root-managed: only an administrator signs this node in (sudo nsplit login $n)";;
	*) chk WARN "the profile record does not say who manages it: treated as root-managed (only an administrator signs it in)";;
	esac
	# built-in Tailscale SSH: the node's real setting against the profile record (the record only says what nsplit set when it signed the node in; the node's operator can change it afterwards)
	if [ -n "$be" ]; then
		ssh_now=$(node_ssh "$n") || ssh_now=""
		case "${P_SSH:-none}:$ssh_now" in
		tailscale:on) chk WARN "Tailscale SSH is ON, as enrolled (--ssh tailscale): the SSH rules of this node's tailnet policy choose the local account, which can be any account on this machine including the administrator and root; nsplit can neither read nor limit that policy and its login gate does not cover these sessions";;
		tailscale:off) if [ "$be" = Running ]; then chk WARN "Tailscale SSH is OFF although the profile record says --ssh tailscale (the node's setting was changed after sign-in)"; else chk INFO "Tailscale SSH is not on yet (nsplit login switches it on with the sign-in)"; fi;;
		*:off) chk PASS "built-in Tailscale SSH is off, as the profile record says (--ssh ${P_SSH:-none})";;
		*:on) secfail="built-in Tailscale SSH is ON for this node although the profile record says --ssh ${P_SSH:-none}: its tailnet policy can authorize logins as other local accounts or root, which nsplit's login gate does not cover. An administrator can switch it off: sudo nsplit ts $n set --ssh=false"; chk FAIL "$secfail";;
		*) chk UNKNOWN "whether built-in Tailscale SSH is on (the node's preferences could not be read)"; unverified=1;;
		esac
	fi
	pf=$SDIR/user@$P_UIDN.service.d/50-nsplit.conf
	[ -f "$pf" ] && grep -q "NetworkNamespacePath=/run/netns/$P_NS" "$pf" && chk PASS "placement drop-in for user@$P_UIDN.service is installed" || chk FAIL "placement drop-in is missing or wrong ($pf)"
	if [ "$(profile_mode)" = headless ]; then
		# a headless profile: the manager is started by systemd-logind at boot (lingering), so its drop-in must make systemd bring the namespace and firewall up first and refuse to start without them
		grep -q "^Requires=nsplit-netns@$n.service nsplit-firewall.service" "$pf" 2>/dev/null && chk PASS "the placement drop-in requires the profile's namespace and the firewall before the manager starts (fail-closed at boot)" || chk FAIL "the headless placement drop-in does not require the namespace and the firewall ($pf)"
		chk INFO "headless profile: $P_LOGIN's user manager runs without a login (lingering) inside $P_NS and is reached through the namespace OpenSSH server only"
		case "$(linger_state "$P_LOGIN"):$([ -e "$LINGERMARK/$n" ] && echo mark || echo nomark)" in
		on:mark) chk PASS "lingering is on for $P_LOGIN, switched on by nsplit (nsplit remove switches it off again)";;
		on:nomark) chk WARN "lingering is on for $P_LOGIN, but nsplit has no record of switching it on (nsplit remove will leave it on)";;
		off:*) chk FAIL "lingering is OFF for $P_LOGIN: their user manager does not start at boot and their services stop at logout (an administrator can switch it on again: sudo loginctl enable-linger $P_LOGIN)";;
		*) chk UNKNOWN "whether lingering is on for $P_LOGIN ($LINGERDIR is not readable)"; unverified=1;;
		esac
		[ "$(unit_state "nsplit-sshd@$n.service")" = active ] && chk PASS "the namespace OpenSSH server is running" || chk FAIL "the namespace OpenSSH server is $(unit_state "nsplit-sshd@$n.service") (the only way into a headless profile)"
		grep -qx "PAMServiceName nsplit-sshd-$n" "$ETC/ssh/$n/sshd_config" 2>/dev/null && chk PASS "the namespace sshd uses its own PAM service nsplit-sshd-$n" || chk FAIL "the namespace sshd configuration does not name its own PAM service (PAMServiceName nsplit-sshd-$n)"
		grep -q "nsplit-pam-gate $P_LOGIN $P_UIDN $P_NS" "$PAMDIR/nsplit-sshd-$n" 2>/dev/null && [ -x "$GATE" ] && chk PASS "the PAM service $PAMDIR/nsplit-sshd-$n carries the placement gate after the host's sshd stack" || chk FAIL "the placement gate is missing from the PAM service $PAMDIR/nsplit-sshd-$n"
		local gfs=$PAMDIR/login gf gk=1; [ ! -e "$PAMDIR/plasmalogin" ] || gfs+=" $PAMDIR/plasmalogin"
		for gf in $gfs; do grep -q "nsplit-pam-gate $P_LOGIN $P_UIDN $P_NS" "$gf" 2>/dev/null || gk=0; done
		[ $gk = 1 ] && [ -x "$GATE" ] && chk PASS "login gate present in every login stack that exists here (console$( [ -e "$PAMDIR/plasmalogin" ] && echo ' and graphical'))" || chk FAIL "login gate missing from a login stack"
	elif grep -q "nsplit-pam-gate $P_LOGIN $P_UIDN $P_NS" "$PAMDIR/plasmalogin" 2>/dev/null && grep -q "nsplit-pam-gate $P_LOGIN $P_UIDN $P_NS" "$PAMDIR/login" 2>/dev/null && [ -x "$GATE" ]; then chk PASS "login gate present in the graphical and console login"
		grep -q "quiet  stdout  $GATE $P_LOGIN $P_UIDN $P_NS" "$PAMDIR/plasmalogin" 2>/dev/null && grep -q "quiet  stdout  $GATE $P_LOGIN $P_UIDN $P_NS" "$PAMDIR/login" 2>/dev/null \
			|| chk WARN "the login gate lines are from an older nsplit: a refused console login shows only 'System error' instead of the reason (the next nsplit add or remove rewrites them)"
	else chk FAIL "login gate missing from a login stack"; fi
	[ -f "$DBUSDIR/nsplit-$n.conf" ] && chk PASS "D-Bus policy installed" || chk FAIL "D-Bus policy missing"
	if is_admin; then
		guard_read "$P_UIDN"
		case $GUARD in
		listed) chk PASS "uid guard loaded for uid $P_UIDN"
			[ "$GUARD_TRIES" -le 1 ] || chk INFO "uid guard: the first read failed ($GUARD_FIRST); read correctly on attempt $GUARD_TRIES";;
		missing) secfail="uid guard does not list uid $P_UIDN ($GUARD_WHY)"; chk FAIL "$secfail";;
		absent) # the guard is loaded before any login can exist (Before=systemd-user-sessions); absent while the system is still starting is a state to look at again, absent later is a gap
			case $($SYSTEMCTL is-system-running 2>/dev/null) in initializing|starting) chk UNKNOWN "uid guard: $GUARD_WHY, and the system is still starting up (unit nsplit-uid-guard is $(unit_state nsplit-uid-guard.service)); look again in a moment"; unverified=1;;
			*) secfail="uid guard is not loaded: $GUARD_WHY (unit nsplit-uid-guard is $(unit_state nsplit-uid-guard.service))"; chk FAIL "$secfail";; esac;;
		unreadable) chk UNKNOWN "uid guard could not be read, so nothing is known about it: $GUARD_WHY"; unverified=1;;
		*) chk UNKNOWN "uid guard could not be interpreted, so nothing is known about it: $GUARD_WHY"; unverified=1;;
		esac
	else chk UNKNOWN "uid guard (reading the firewall needs root)"; fi
	mgr=$(manager_pid "$P_UIDN")
	if [ -z "$mgr" ]; then
		if [ "$(profile_mode)" = headless ]; then chk FAIL "$P_LOGIN's user manager is not running (a headless profile's manager runs without a login; an administrator can start it: sudo nsplit start $n)"
		else chk INFO "$P_LOGIN has no running user manager (placement applies at the next login)"; fi
		MGR=none
	elif [ -r "/proc/$mgr/ns/net" ] && [ -n "$(ns_obj "/proc/$mgr/ns/net")" ]; then
		want=$(ns_obj "$NETNSRUN/$P_NS")
		if [ -n "$want" ] && [ "$(ns_obj "/proc/$mgr/ns/net")" = "$want" ]; then chk PASS "$P_LOGIN's running user manager is inside $P_NS"; MGR=placed
		elif [ "$(profile_mode)" = headless ]; then secfail="$P_LOGIN's user manager is NOT inside $P_NS (its services run in the host's network): a headless profile's manager runs without a login, so no new login will place it; an administrator can restart it: sudo systemctl restart user@$P_UIDN.service"; chk FAIL "$secfail"; MGR=unplaced
		else chk WARN "$P_LOGIN's running user manager is NOT inside $P_NS (log out and back in)"; MGR=unplaced; fi
	else chk UNKNOWN "whether $P_LOGIN's running user manager is placed (needs root)"; MGR=unknown; [ "$(profile_mode)" != headless ] || unverified=1; fi
	# the mounts of the RUNNING consumers (the profile's daemon, its namespace sshd, the user manager). A lost bind is invisible to a fresh probe process, which always gets correct ones, so the
	# running processes' own mount tables are read. A missing mount is a failure; a view that could not be read (it needs root) is UNKNOWN and keeps the profile from being Ready.
	if [ -x "$LIB/nsplit-mounts" ]; then
		mrows=$("$LIB/nsplit-mounts" check --machine "$n" 2>/dev/null); mrc=$?
		case $mrc in 0|2|3) ;; *) mrows=""; chk UNKNOWN "profile mounts: the check could not run (try: nsplit mounts check)"; unverified=1;; esac
		while IFS=$'\t' read -r mst _ munit mdest mmn mwhy; do
			case $mst in
			MATCH) mmatch=$((mmatch+1));;
			MISMATCH) chk FAIL "profile mounts: $munit has lost its private $mdest ($mwhy)"
				[ -n "$secfail" ] || secfail="a running service of this profile lost its private $mdest ($munit); an administrator can re-attach it without restarting anything: sudo nsplit mounts repair $n";;
			NOT-DECLARED) chk FAIL "profile mounts: $munit is running but its definition no longer declares the private $mdest ($mwhy)"
				[ -n "$secfail" ] || secfail="a running service of this profile ($munit) no longer declares its private $mdest bind: its unit definition was changed; an administrator must restore it (nsplit will not attach a bind its unit does not declare)";;
			UNKNOWN) chk UNKNOWN "profile mounts: $munit $mdest ($mwhy)"; unverified=1;;
			esac
		done <<<"$mrows"
		[ "$mmatch" -eq 0 ] || chk PASS "profile mounts: $mmatch required view(s) of /etc/resolv.conf and /run/tailscale in the running services match their sources"
	fi
	# the headline
	if [ "$st_ns" != active ] || [ "$st_ts" != active ] || [ "$st_fw" != active ]; then S_STATE=Stopped; S_DETAIL="start it with: nsplit start $n"
	elif [ -n "$secfail" ]; then S_STATE=Degraded; S_DETAIL=$secfail   # an exposed daemon, or a uid the guard does not cover, is not hidden behind "Needs sign-in" (before sign-in the socket even carries the sign-in link)
	elif [ -z "$be" ] && [ -n "$noperm" ] && ! printf '%s\n' "${S_CHECKS[@]}" | grep -q '^FAIL'; then S_STATE="Not checked"; S_DETAIL="this profile's daemon is reachable only by its owner and administrators; an administrator can check it: sudo nsplit status $n"
	elif [ -n "$unverified" ] && { [ "$be" = NeedsLogin ] || [ "$be" = NoState ]; }; then S_STATE="Not checked"; S_DETAIL="something that keeps it safe could not be read: $(printf '%s\n' "${S_CHECKS[@]}" | grep -m1 '^UNKNOWN' | cut -d' ' -f2-) (nsplit status -v $n)"
	elif [ "$be" = NeedsLogin ] || [ "$be" = NoState ]; then S_STATE="Needs sign-in"; S_DETAIL="run: nsplit login $n   (the user approves their own Tailscale account)"
	elif [ -n "$be" ] && [ "$be" != Running ]; then S_STATE=Degraded; S_DETAIL="the Tailscale node is $be (nsplit status -v $n)"
	elif [ -z "$be" ] && [ -z "$noperm" ]; then S_STATE=Degraded; S_DETAIL="the daemon is not answering (nsplit status -v $n)"
	elif printf '%s\n' "${S_CHECKS[@]}" | grep -q '^FAIL'; then S_STATE=Degraded; S_DETAIL="$(printf '%s\n' "${S_CHECKS[@]}" | grep -m1 '^FAIL' | cut -d' ' -f2-)"
	elif [ "$MGR" = unplaced ]; then S_STATE="Needs new login"; S_DETAIL="placement applies at the next login: $P_LOGIN should log out and back in"
	elif [ -n "$unverified" ]; then S_STATE="Not checked"; S_DETAIL="something that keeps it safe could not be read: $(printf '%s\n' "${S_CHECKS[@]}" | grep -m1 '^UNKNOWN' | cut -d' ' -f2-) (nsplit status -v $n)"
	else S_STATE=Ready; S_DETAIL="personal tailnet connected (${host:-?}, ${ips:-no address yet})"; [ "$MGR" = unknown ] && S_DETAIL+="; running session not checked without root"
		[ "$(profile_mode)" != headless ] || S_DETAIL+="; headless: the user manager lingers inside $P_NS, reached through the namespace OpenSSH server only"
		[ "${P_SSH:-}" != tailscale ] || S_DETAIL+="; WARNING: Tailscale SSH is on and its tailnet policy, not nsplit, picks the local account (nsplit status -v $n)"; fi
}

cmd_status() {
	local verbose=0 only="" n rc=0 nc=0 line dflt
	while [ $# -gt 0 ]; do case $1 in -h|--help) usage_status; return 0;; -v|--verbose) verbose=1; shift;; -*) die "unknown option $1";; *) only=$1; shift;; esac; done
	local names; if [ -n "$only" ]; then n=$(resolve_profile "$only") || die "no nsplit profile '$only'"; names=$n; else names=$(profile_names); fi
	if [ -z "$names" ]; then say "No profiles are set up. Add one with: nsplit add USER"; return 0; fi
	printf '%-14s %-16s %s\n' PROFILE STATE NEXT
	for n in $names; do
		profile_status "$n"
		printf '%-14s %-16s %s\n' "$n" "$S_STATE" "$S_DETAIL"
		case $S_STATE in Ready) ;; "Not checked") nc=1;; *) rc=2;; esac
		if [ "$verbose" = 1 ]; then for line in "${S_CHECKS[@]}"; do printf '    %-8s %s\n' "${line%% *}" "${line#* }"; done; fi
	done
	if [ "$verbose" = 1 ]; then
		dflt=$($IP -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($1=="default"&&$i=="dev") print $(i+1)}' | head -1)
		say; say "host: uplinks $(conf_get UPLINKS)   default route via ${dflt:-none}$( [ -n "$dflt" ] && case " $(conf_get UPLINKS) " in *" $dflt "*) ;; *) echo "  (NOT an uplink: profiles have no internet through it; see: nsplit uplinks)";; esac )"
	fi
	[ "$rc" = 0 ] && [ "$nc" = 1 ] && rc=3
	return $rc
}
