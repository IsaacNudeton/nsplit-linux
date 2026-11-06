# shellcheck shell=bash
# nsplit start | stop | remove | uplinks | reload | run | ts

targets() { # targets ARG -> profile names ("--all" = every profile)
	if [ "${1:-}" = "--all" ]; then profile_names; return; fi
	[ -n "${1:-}" ] || { resolve_profile "" || die "name a profile (or --all); see: nsplit status"; return; }
	resolve_profile "$1" || die "no nsplit profile '$1' (see: nsplit status)"; }
# profile_busy N: is the profile's user in use? 0 = yes, 1 = not, 2 = could not tell; the callers treat 2 like 0.
# A desktop profile counts a login session OR a running user manager. A headless profile's manager is meant to be running (lingering), so only a login session counts.
profile_busy() { ( rec_clean; . "$PROFDIR/$1.env"; if [ "${MODE:-}" = headless ]; then user_sessions "$LOGIN" "$UIDN"; else user_busy "$LOGIN" "$UIDN"; fi ); }
# busy_what N: the words for what profile_busy found
busy_what() { local m; m=$( rec_clean; . "$PROFDIR/$1.env"; printf %s "${MODE:-}" ); if [ "$m" = headless ]; then printf 'has a login session'; else printf 'is logged in (or has a running user manager)'; fi; }
# profile_units N: the units one profile owns, in the order they are stopped (a headless profile's user manager is stopped before them: see stop_manager)
profile_units() { printf 'nsplit-sshd@%s.service nsplit-dns@%s.service nsplit-tailscaled@%s.service nsplit-netns@%s.service' "$1" "$1" "$1" "$1"; }
# manager_wait_down UID [TRIES]: 0 once user@UID.service is inactive or failed, 1 if it is still up or changing after TRIES seconds (default 30)
manager_wait_down() { local i st; for i in $(seq "${2:-30}"); do st=$(unit_state "user@$1.service"); case $st in inactive|failed) return 0;; esac; sleep 1; done; return 1; }
# manager_wait_up UID [TRIES]: 0 once user@UID.service is active with a main process
manager_wait_up() { local i; for i in $(seq "${2:-60}"); do [ "$(unit_state "user@$1.service")" = active ] && [ -n "$(manager_pid "$1")" ] && return 0; intr_check; sleep 1; done; return 1; }
# linger_release NAME LOGIN UID: take back the lingering nsplit switched on for a headless profile's user and make sure the manager that lingering kept alive is stopped.
# Lingering nsplit did not switch on (no marker) is never touched. With a login session nothing is changed. 0 = lingering is off, the manager is down and the marker is gone (or there was nothing of nsplit's to undo); 1 = something is still on (said on stderr).
linger_release() {
	local n=$1 l=$2 u=$3 mark; mark=$LINGERMARK/$n   # (not in the same local statement: its words are expanded before any of the assignments)
	if [ ! -e "$mark" ]; then
		[ "$(linger_state "$l")" != on ] || warn "lingering for $l is on, but nsplit did not switch it on for $n: it is left as it is"
		return 0; fi
	user_sessions "$l" "$u"; case $? in
	0) warn "$l has a login session: lingering for $l is left on and the user manager is left running"; return 1;;
	1) ;;
	*) warn "could not tell whether $l has a login session (loginctl did not answer): lingering for $l is left on"; return 1;;
	esac
	$LOGINCTL disable-linger "$l" >/dev/null 2>&1
	[ "$(linger_state "$l")" = off ] || { warn "lingering for $l is still on after loginctl disable-linger"; return 1; }
	$SYSTEMCTL stop "user@$u.service" >/dev/null 2>&1
	manager_wait_down "$u" 30 || { warn "user@$u.service is still $(unit_state "user@$u.service") after lingering was switched off and a stop was asked for"; return 1; }
	rm -f "$mark"; rmdir "$LINGERMARK" 2>/dev/null; return 0
}
# unit_facts UNIT: ActiveState, SubState, Result, MainPID and ControlPID of a unit, read together, into U_ACTIVE U_SUB U_RESULT U_MAIN U_CTRL.
# Fails (and leaves them empty) when any of the five is missing or a process id is not a number: nothing is concluded from a state that could not be read.
unit_facts() {
	local o a s r m c
	U_ACTIVE=; U_SUB=; U_RESULT=; U_MAIN=; U_CTRL=
	o=$($SYSTEMCTL show -p ActiveState -p SubState -p Result -p MainPID -p ControlPID "$1" 2>/dev/null) || return 1
	a=$(sed -n 's/^ActiveState=//p' <<<"$o"); s=$(sed -n 's/^SubState=//p' <<<"$o"); r=$(sed -n 's/^Result=//p' <<<"$o")
	m=$(sed -n 's/^MainPID=//p' <<<"$o"); c=$(sed -n 's/^ControlPID=//p' <<<"$o")
	[ -n "$a" ] && [ -n "$s" ] && [ -n "$r" ] || return 1
	case $m in ''|*[!0-9]*) return 1;; esac
	case $c in ''|*[!0-9]*) return 1;; esac
	U_ACTIVE=$a; U_SUB=$s; U_RESULT=$r; U_MAIN=$m; U_CTRL=$c
}
# killed_by_stop_timeout UNIT: true only for a unit that is `failed` because it did not exit within systemd's stop time-out and was killed (Result=timeout) and that has no process left (MainPID=0, ControlPID=0)
killed_by_stop_timeout() { unit_facts "$1" && [ "$U_ACTIVE" = failed ] && [ "$U_RESULT" = timeout ] && [ "$U_MAIN" = 0 ] && [ "$U_CTRL" = 0 ]; }
# stop_profile N [disable]: stop (optionally also disable) the profile's units, then CHECK the result: every unit inactive and the namespace gone.
# Needs profile_load N. Returns 0 only when that is true; otherwise says what is still up on stderr and returns 1. systemctl's own exit status is not enough.
# One state is accepted although it is not `inactive`: the Tailscale daemon killed after systemd's stop time-out (an open Tailscale SSH session keeps it from exiting in time: Tailscale's own behaviour,
# also seen on a node without nsplit). It counts as stopped only when systemctl itself succeeded, the unit has no main or control process, the namespace and every other unit of the profile are down,
# and its leftover failed state could be cleared and then read as inactive. The warning says it was not a graceful stop. Everything else (a surviving process or namespace, a state that cannot be read, a failure of another kind) stays a failure.
stop_profile() {
	local n=$1 how=${2:-stop} u st rc=0 left="" units nsl forced="" ts=nsplit-tailscaled@$1.service
	units=$(profile_units "$n")
	# shellcheck disable=SC2086
	$SYSTEMCTL reset-failed $units >/dev/null 2>&1   # a failed state seen below then comes from THIS attempt, not from an old crash
	# a headless profile's user manager (kept running by lingering) goes first: it is what the user's own services run under, and it must be gone before the namespace is
	if [ "$(profile_mode)" = headless ]; then $SYSTEMCTL reset-failed "user@$P_UIDN.service" >/dev/null 2>&1; $SYSTEMCTL stop "user@$P_UIDN.service" || rc=1; fi
	# shellcheck disable=SC2086
	if [ "$how" = disable ]; then $SYSTEMCTL disable --now $units || rc=1; else $SYSTEMCTL stop $units || rc=1; fi
	if [ "$(profile_mode)" = headless ]; then st=$(unit_state "user@$P_UIDN.service"); [ "$st" = inactive ] || left+="user@$P_UIDN.service is $st; "; fi
	for u in $units; do st=$(unit_state "$u")
		[ "$st" = inactive ] && continue
		if [ "$u" = "$ts" ] && [ "$st" = failed ] && [ $rc = 0 ] && killed_by_stop_timeout "$u"; then forced=$u; continue; fi
		left+="$u is $st; "
	done
	if nsl=$($IP netns list 2>/dev/null); then awk '{print $1}' <<<"$nsl" | grep -qx "$P_NS" && left+="the namespace $P_NS still exists; "
	else left+="could not list network namespaces to confirm $P_NS is gone; "; fi
	if [ -n "$forced" ]; then
		if [ -z "$left" ] && $SYSTEMCTL reset-failed "$forced" >/dev/null 2>&1 && [ "$(unit_state "$forced")" = inactive ]; then
			warn "$n's Tailscale daemon did not exit within systemd's stop time-out and was killed (an open Tailscale SSH session is the usual cause), so this was not a graceful stop. No process or namespace of $n is left and the daemon's failed state was cleared."
		else left+="$forced was killed after systemd's stop time-out and is still failed; "; fi
	fi
	[ $rc = 0 ] && [ -z "$left" ] && return 0
	warn "$n is NOT fully stopped: ${left:-systemctl reported an error while stopping its units}"
	return 1
}
# busy_hint N: what to add to a refusal because the user is logged in: an abandoned shell counts as logged in, and the administrator can end it explicitly (nsplit never does)
busy_hint() { local l m u ids; eval "$( rec_clean; . "$PROFDIR/$1.env"; printf 'l=%q m=%q u=%q' "$LOGIN" "${MODE:-}" "$UIDN" )"
	if [ "$m" = headless ]; then
		ids=$(user_session_ids "$l" "$u")
		printf 'A login left behind by an abruptly closed connection (session state "closing", its processes still running) counts as logged in. Its logind session(s): %s. If nobody is really using the account, an administrator can end one with: loginctl terminate-session ID (and, if its processes survive that, loginctl kill-session ID --signal=KILL). `loginctl terminate-user %s` is not suggested for a headless profile: it would also end the lingering user manager. nsplit never runs any of these for you.' "${ids:-?}" "$l"
	else
		printf 'A shell left behind by an abruptly closed Tailscale SSH connection counts as logged in. If nobody is really using the account, an administrator can end every process of that user with: loginctl terminate-user %s (nsplit never runs that for you).' "$l"
	fi
}

usage_start() { cat <<'EOF2'
usage: nsplit start (PROFILE | --all)
  Start a profile's managed networking now: namespace, firewall, Tailscale daemon, private DNS, and its SSH server if it has one.
  A headless profile's user manager (kept running by lingering that nsplit switched on) is started last, inside the profile's namespace.
  (They also start at boot; this is for starting one after nsplit stop.)
  An already-running daemon with unsafe socket permissions or multiple socket hard links is restarted to replace the listener and close its existing connections.
  This can interrupt that profile's connections, including its Tailscale SSH sessions. An already-running daemon whose current socket checks pass is not restarted.
  fs.protected_hardlinks must remain 1; nsplit checks it but never changes machine policy. After known prior exposure, explicitly restart the affected nsplit-tailscaled@PROFILE.service:
  restoring the setting or removing an external link does not close clients already connected through it, and a link count of 1 cannot reveal them.
EOF2
}
cmd_start() {
	local a n st_ts repair sd sdo sdrc
	case ${1:-} in -h|--help) usage_start; return 0;; esac
	need_root; a=$(targets "${1:-}"); [ -n "$a" ] || die "no profiles"
	# An upgrade may have replaced the unit template: load its pre-listen permission check before any start or migration restart.
	$SYSTEMCTL daemon-reload || die "could not reload the service definitions"
	$SYSTEMCTL start nsplit-uid-guard.service || die "could not start the uid guard"
	for n in $a; do
		profile_load "$n" || die "could not read the profile $n"
		repair=0; st_ts=$(unit_state "nsplit-tailscaled@$n.service")
		case $st_ts in
		active|inactive|failed) ;;
		*) die "the Tailscale daemon for $n is '$st_ts'; wait for a stable state and retry (no start or restart attempted)";;
		esac
		# Refuse unsafe path objects before systemd processes RuntimeDirectory. This is read-only: changing active permissions here could lose a required revocation if restart failed before stopping the old daemon.
		sd=$(dirname "$(sock_of "$n")")
		if [ -L "$sd" ] || { [ -e "$sd" ] && [ ! -d "$sd" ]; }; then
			die "$sd is not a real directory; no start or restart attempted"
		fi
		sdo=$("$LIB/nsplit-sockdir" "$n" check 2>&1); sdrc=$?
		case $sdrc in
		0) ;;
		1) [ "$st_ts" != active ] || repair=1;;
		3) [ "$st_ts" != active ] || die "the running daemon's socket directory for $n is absent; no start or restart attempted: $sdo";;
		*) die "could not inspect the daemon's socket protections for $n, so it was not started or restarted: $sdo";;
		esac
		$SYSTEMCTL start "nsplit-netns@$n.service" || die "namespace for $n did not start"
		if unit_active nsplit-firewall.service; then $SYSTEMCTL reload nsplit-firewall.service; else $SYSTEMCTL start nsplit-firewall.service; fi || die "firewall did not start"
		if [ "$repair" = 1 ]; then
			# Permission changes or re-enabling hard-link protection cannot revoke established connections or old inode aliases. Restart closes this listener; tailscaled creates its replacement.
			say "restarting $n's Tailscale daemon to replace its unsafe socket and close existing connections"
			$SYSTEMCTL restart "nsplit-tailscaled@$n.service" || die "the Tailscale daemon for $n could not restart with verified socket protections (see: journalctl -u nsplit-tailscaled@$n)"
		else $SYSTEMCTL start "nsplit-tailscaled@$n.service" || die "the Tailscale daemon for $n did not start"; fi
		if ! sdo=$("$LIB/nsplit-sockdir" "$n" check 2>&1); then
			# No successful start is reported without the permission check; also close any daemon that unexpectedly started without the promised protection.
			$SYSTEMCTL stop "nsplit-tailscaled@$n.service" >/dev/null 2>&1
			st_ts=$(unit_state "nsplit-tailscaled@$n.service")
			die "could not confirm the socket protections for $n: $sdo; a stop was requested and the daemon is now '$st_ts' (check nsplit status -v $n)"
		fi
		[ -f "$ETC/dns/$n.conf" ] && { $SYSTEMCTL start "nsplit-dns@$n.service" || warn "private DNS for $n did not start"; }
		[ "$P_SSH" = openssh ] && { $SYSTEMCTL start "nsplit-sshd@$n.service" || warn "the namespace sshd for $n did not start"; }
		# a headless profile's user manager (lingering) comes back last, after the namespace, the firewall and the daemon it is placed with; if nsplit did not switch lingering on there is no manager to bring back
		if [ "$(profile_mode)" = headless ] && [ -e "$LINGERMARK/$n" ] && [ "$(linger_state "$P_LOGIN")" = on ]; then
			$SYSTEMCTL start "user@$P_UIDN.service" || warn "the user manager of $P_LOGIN did not start (see: journalctl -u user@$P_UIDN.service); nsplit status $n shows what is missing"
		fi
		say "started $n"
	done
	# the start boundary: a service of ANY profile that was already running may have lost a mount while the host paths were replaced (nothing is restarted by this)
	mounts_refresh || warn "could not switch the mount watcher (nsplit-mounts.path, nsplit-mounts.timer); look with: nsplit mounts check"
	"$LIB/nsplit-mounts" repair --auto || { [ $? != 2 ] || warn "a profile mount is not in place and could not be repaired: nsplit mounts check"; }
}

usage_stop() { cat <<'EOF2'
usage: nsplit stop (PROFILE | --all) [--force]
  Stop a profile's managed networking now (it starts again at boot, or with nsplit start). Stopping the namespace ends every process inside it,
  so it refuses while the user is logged in (or when that cannot be checked) unless --force. --all also stops the shared firewall.
  A headless profile's user manager is meant to be running, so only a login session (SSH or console) counts as "logged in" for it; the manager is stopped first and lingering stays on (nsplit start brings the manager back).
  It reports "stopped" only after checking that every unit is down and the namespace is gone; otherwise it says what is still up and exits 1.
  With a Tailscale SSH session open the Tailscale daemon may not exit within systemd's stop time-out and is killed (Tailscale's own behaviour). When nothing of the profile is left running
  nsplit clears the daemon's leftover failed state, reports "stopped" and warns that the stop was not graceful. A daemon or namespace that is still there is never reported as stopped.
EOF2
}
cmd_stop() {
	local force=0 arg="" a n bad=""
	while [ $# -gt 0 ]; do case $1 in -h|--help) usage_stop; return 0;; --force) force=1; shift;; *) arg=$1; shift;; esac; done
	need_root; a=$(targets "$arg"); [ -n "$a" ] || die "no profiles"
	if [ "$force" != 1 ]; then for n in $a; do profile_busy "$n"; case $? in
		0) die "$n $(busy_what "$n"). Log them out first, or use --force to end their session. $(busy_hint "$n")";;
		1) ;;
		*) die "could not tell whether $n is logged in (loginctl or systemctl did not answer), so nothing was stopped. Check that systemd-logind is running, or use --force.";;
	esac; done; fi
	for n in $a; do
		profile_load "$n"
		if stop_profile "$n" stop; then say "stopped $n"; else bad+="$n "; fi
	done
	if [ "$arg" = "--all" ]; then
		if [ -n "$bad" ]; then warn "the shared firewall was left running because not every profile stopped"
		else
			if $SYSTEMCTL stop nsplit-firewall.service && [ "$(unit_state nsplit-firewall.service)" = inactive ]; then say "stopped the shared firewall"
			else warn "the shared firewall is NOT stopped"; bad+="firewall "; fi
		fi
	fi
	[ -z "$bad" ] || die "not stopped: ${bad% }. Fix what is listed above and run the stop again (nsplit status shows what is up now)."
}

usage_remove() { cat <<'EOF2'
usage: nsplit remove PROFILE [--purge] [--dry-run] [--yes]
  Take a profile's nsplit configuration away: stops its units, removes the placement, login gate, D-Bus policy, guard entry, firewall entry and the files nsplit made.
  The user's account, home directory and files are never touched. The user then uses the host's network normally again.
  A root-managed key file for the namespace OpenSSH server (/etc/nsplit/ssh/PROFILE/authorized_keys) is the administrator's: nsplit never deletes it and reports it as kept,
  and it does not make the removal fail. (The one exception is a copy that is still exactly what nsplit 0.1.0-12/-13 wrote, which holds no keys.)
  The profile's Tailscale node identity (/var/lib/tailscale-PROFILE) is KEPT so adding the profile again needs no new sign-in; --purge deletes it
  (the node stays listed in the user's tailnet admin console until they remove it there).
  Refuses while the user is logged in (or when that cannot be checked). A headless profile's lingering user manager does not count as a login (only a session does): it is stopped, the lingering nsplit switched on for it is
  switched off, and only then is the placement taken away; if lingering cannot be switched off the placement stays and the removal is reported as not finished. Lingering that nsplit did not switch on is never touched.
  If any part cannot be completed, or a file nsplit made was changed by hand
  (it is never deleted or overwritten), the profile and its records are kept, the unresolved items are listed, the exit status is 1, and the same command finishes the job once they are dealt with.
EOF2
}
cmd_remove() {
	local purge=0 arg="" dry=0 yes=0 n ans fails=0 kept=0 f rest pl rec rc unresolved="" keyfile lingerok
	while [ $# -gt 0 ]; do case $1 in -h|--help) usage_remove; return 0;; --purge) purge=1; shift;; --dry-run) dry=1; shift;; --yes|-y) yes=1; shift;; -*) die "unknown option $1";; *) arg=$1; shift;; esac; done
	[ -n "$arg" ] || { usage_remove >&2; exit 2; }
	n=$(resolve_profile "$arg") || die "no nsplit profile '$arg'"
	[ "$dry" = 1 ] || need_root
	profile_load "$n"
	ensure_logged_out "$n"
	say "nsplit remove: $n ($P_LOGIN, uid $P_UIDN)"
	say "  will stop: nsplit-netns@$n nsplit-tailscaled@$n nsplit-dns@$n nsplit-sshd@$n (the firewall stays while other profiles remain)"
	[ "$(profile_mode)" != headless ] || say "  headless profile: $P_LOGIN's user manager is stopped first and the lingering nsplit switched on for it is switched off again (refused while $P_LOGIN has a login session; the account and home stay)"
	[ "${P_HOSTSSH:-}" != deny ] || say "  host-SSH policy: $P_LOGIN comes out of the host sshd's DenyUsers (the drop-in is rewritten, or removed when no profile has the policy left) and sshd is reloaded; $P_LOGIN may then use the host's sshd again"
	say "  will remove: the placement drop-in, the login-gate lines for $P_LOGIN, the D-Bus policy, the uid-guard entry, the ufw route rules, and every file nsplit created for $n:"
	keyfile=$ETC/ssh/$n/authorized_keys
	own_paths "$n" | while IFS= read -r f; do
		if [ "$f" = "$keyfile" ] && [ -e "$f" ] && ! owned_unchanged "$n" "$f"; then continue   # the administrator's key file, which nsplit 0.1.0-12/-13 recorded as its own: listed below as kept
		elif [ -e "$f" ] && [ "$(own_sha "$n" "$f")" != "$(sha "$f")" ]; then printf '    %s   (CHANGED since nsplit wrote it: it will be KEPT and reported as unresolved)\n' "$f"; else printf '    %s\n' "$f"; fi; done
	say "  will keep: the user's account and files; the node identity /var/lib/tailscale-$n$( [ $purge = 1 ] && echo " (--purge: DELETED)")"
	[ ! -e "$keyfile" ] || { [ -n "$(own_sha "$n" "$keyfile")" ] && [ "$(own_sha "$n" "$keyfile")" = "$(sha "$keyfile")" ]; } || say "  will keep: $keyfile (the administrator's key file: left in place, and not an error)"
	[ "$dry" = 1 ] && { say "Dry run: nothing was changed."; return 0; }
	if [ "$yes" != 1 ]; then read -r -p "Remove? [y/N] " ans </dev/tty || ans=n; case $ans in y|Y|yes) ;; *) say "Nothing was changed."; return 1;; esac; fi
	ensure_logged_out "$n"   # re-checked after the confirmation: it may have waited a long time
	# 1. the units. If they cannot be stopped nothing else is touched: the profile stays whole and this can simply be run again.
	stop_profile "$n" disable || die "$n's units could not be stopped, so no configuration was removed and $n is still registered. Fix what is listed above and run: nsplit remove $n"
	say "  done: units stopped and disabled"
	# 2. everything else. Each step is attempted and counted; what does not complete stays on record (profile file + ownership list) so a retry can finish it.
	step() { local d=$1 r; shift; ( "$@" ) && r=0 || r=$?
		case $r in
		0) printf '  done: %s\n' "$d";;
		3) printf '  KEPT: %s (changed after nsplit wrote it; left alone)\n' "$d" >&2; kept=$((kept+1)); unresolved+="$d: changed after nsplit wrote it; left as it is"$'\n';;
		4) printf '  kept: %s (the administrator'"'"'s key file: left in place and no longer recorded as nsplit'"'"'s; not an error)\n' "$d";;
		*) printf '  FAILED: %s\n' "$d" >&2; fails=$((fails+1)); unresolved+="$d: did not complete"$'\n';;
		esac; return $r; }
	rest=$(profile_names | grep -vx "$n" | tr '\n' ' ')
	pl="$SDIR/user@$P_UIDN.service.d/50-nsplit.conf"
	# a headless profile's lingering goes first: with lingering off nothing restarts the user manager, and only then is its placement taken away (a manager that came back without it would run in the host network)
	lingerok=1
	if [ "$(profile_mode)" = headless ]; then step "lingering and the user manager of $P_LOGIN" linger_release "$n" "$P_LOGIN" "$P_UIDN" || lingerok=0; fi
	# the placement goes before the gate: while the gate is still there a user who tries to log in is refused instead of landing half-placed
	if [ "$lingerok" = 1 ] && step "placement drop-in $pl" remove_owned_file "$n" "$pl"; then
		step "systemd reloaded" $SYSTEMCTL daemon-reload
		# shellcheck disable=SC2086
		step "login gate lines for $P_LOGIN" pam_remove_for $n $rest
	else
		printf '  SKIPPED: the login gate lines for %s stay while their placement does (they refuse a login that would run unplaced)\n' "$P_LOGIN" >&2
		unresolved+="login gate lines for $P_LOGIN: left in place because the placement drop-in is still there"$'\n'
	fi
	step "ufw route rules" "$LIB/nsplit-ufw" del "$n"
	if [ -e "$VAR/scoped-$n.lock" ] || [ -L "$VAR/scoped-$n.lock" ]; then step "DNS lock file $VAR/scoped-$n.lock" remove_scoped_lock "$n"; fi
	step "D-Bus policy" remove_owned_file "$n" "$DBUSDIR/nsplit-$n.conf"
	# a key file nsplit never recorded (an administrator made it after this fix) is not in the ownership list at all: it stays, and is said to (looked at before the loop, which forgets a recorded one)
	if [ -e "$keyfile" ] && [ -z "$(own_sha "$n" "$keyfile")" ]; then printf '  kept: %s (the administrator'"'"'s key file: left in place; not an error)\n' "$keyfile"; fi
	for f in $(own_paths "$n"); do
		[ "$f" = "$PROFDIR/$n.env" ] && continue
		[ "$lingerok" = 1 ] || [ "$f" != "$pl" ] || continue   # lingering could not be switched off: the placement stays, or a manager that came back would run in the host network
		if [ "$f" = "$keyfile" ]; then step "$f" remove_key_file "$n" "$f"; else step "$f" remove_owned_file "$n" "$f"; fi
	done
	step "bus policy reloaded" dbus_reload
	# 3. only when all of that completed: regenerate what the profiles share without this one, then drop the profile record itself.
	# The record is what lets a retry find the profile, and the guard and firewall are what protect the host from its user, so the record is checked FIRST,
	# the shared files are rebuilt only if it can go, and they are put back as they were if it then does not.
	if [ $fails = 0 ] && [ $kept = 0 ]; then
		rec="$PROFDIR/$n.env"
		if ! owned_unchanged "$n" "$rec"; then
			printf '  KEPT: profile record %s (changed after nsplit wrote it; left alone)\n' "$rec" >&2; kept=$((kept+1))
			unresolved+="profile record $rec: changed after nsplit wrote it; left as it is"$'\n'
			printf '  SKIPPED: the firewall and uid guard stay as they are for as long as the profile record does\n' >&2
		else
			SKIP_PROFILE=$n; step "firewall and uid guard now reflect the remaining profiles" refresh_shared; rc=$?; SKIP_PROFILE=
			if [ $rc = 0 ] && step "profile record $rec" remove_owned_file "$n" "$rec"; then
				rm -f "$(own_file "$n")"
				[ -n "$(profile_names)" ] || remove_owned_file _shared "$CONF" || true   # the last profile: the shared settings go too, unless the administrator changed them (said above)
				rmdir "$ETC/ssh/$n" "$NETNSETC/netns-$n" 2>/dev/null; rmdir "$ETC/ssh" "$ETC/dns" "$PROFDIR" 2>/dev/null; rmdir "$ETC" 2>/dev/null
				if [ "$purge" = 1 ]; then rm -rf "/var/lib/tailscale-$n" "$STATEMARK/$n" && say "  done: node identity deleted" || warn "could not delete /var/lib/tailscale-$n: delete it yourself"; fi
				[ ! -e "$keyfile" ] || say "  The key file $keyfile was kept (it is the administrator's); delete it if it is not wanted."
				say "Removed $n. $P_LOGIN now uses the host's network normally."
				return 0
			fi
			# the profile stays registered, so what protects the host from its user stays too
			step "firewall and uid guard put back for $P_LOGIN, whose profile stays registered" refresh_shared
		fi
	fi
	{ printf '\nnsplit remove: %s is NOT fully removed. Unresolved:\n' "$n"
	  printf '%s' "$unresolved" | sed 's/^/  - /'
	  printf '%s stays registered, with its records, so this can be finished: nothing you changed was deleted or overwritten.\n' "$n"
	  printf 'Its units are stopped and some of its configuration may already be gone. Until it is finished %s has no network on this host (the uid guard stays).\n' "$P_LOGIN"
	  printf 'Review or remove the listed items yourself, then run: nsplit remove %s\n' "$n"; } >&2
	return 1
}
# ensure_logged_out N: dies unless the profile's user has no session and no user manager; a check that could not run is a refusal too
ensure_logged_out() { profile_busy "$1"; case $? in
	0) die "$P_LOGIN $(busy_what "$1"): log them out first. $(busy_hint "$1")";;
	1) ;;
	*) die "could not tell whether $P_LOGIN is logged in (loginctl or systemctl did not answer), so nothing was removed. Check that systemd-logind is running and try again.";;
	esac; }
# remove_key_file OWNER FILE: the root-managed authorized_keys that nsplit 0.1.0-12/-13 created and recorded as its own, although the file itself tells the administrator to put keys in it.
# A changed one is the administrator's data: the ownership record is dropped, the file stays, and that is success (4 = kept). One still exactly as nsplit wrote it holds nothing and is removed.
remove_key_file() { local o=$1 f=$2
	if [ -e "$f" ] && ! owned_unchanged "$o" "$f"; then own_forget "$o" "$f"; return 4; fi
	remove_owned_file "$o" "$f"; }
# owned_unchanged OWNER FILE: true when FILE is gone or is still exactly what nsplit wrote
owned_unchanged() { local want; [ -e "$2" ] || return 0; want=$(own_sha "$1" "$2"); [ -n "$want" ] && [ "$want" = "$(sha "$2")" ]; }
remove_owned_file() { local o=$1 f=$2; [ -e "$f" ] || { own_forget "$o" "$f"; return 0; }
	if owned_unchanged "$o" "$f"; then
		rm -f "$f"; [ ! -e "$f" ] || return 1
		own_forget "$o" "$f"; rmdir_ours "$(dirname "$f")"; return 0
	fi
	warn "$f was changed after nsplit wrote it: not deleting it"; return 3; }
# the profile's DNS step creates $VAR/scoped-NAME.lock and nothing records it, so only the exact kind of file the step makes (an empty regular file, one link) is removed
remove_scoped_lock() { local l=$VAR/scoped-$1.lock
	if [ -f "$l" ] && [ ! -L "$l" ] && [ ! -s "$l" ] && [ "$(stat -c %h "$l")" = 1 ]; then rm -f "$l"; [ ! -e "$l" ] || return 1; return 0; fi
	warn "$l is not the empty lock file nsplit makes: not deleting it"; return 3; }
refresh_shared() { # regenerate what is shared between profiles from the profiles that remain
	local uids n; uids=$(for n in $(profile_names); do ( . "$PROFDIR/$n.env"; echo "$UIDN" ); done | sort -nu | tr '\n' ' ')
	OWNER=_shared
	if [ -z "$uids" ]; then   # the last profile is gone: nothing is left to protect or forward for (nsplit.conf is removed by the caller once the profile record is gone, see remove)
		local rc=0; rm -f "$ETC/uid-guard.nft" "$FWSET"; own_forget _shared "$ETC/uid-guard.nft"; own_forget _shared "$FWSET"; guard_refresh || rc=1; fw_refresh || rc=1
		hostssh_apply "" || rc=1   # no profile is left: no host-SSH policy either (the drop-in goes, sshd reloads)
		return $rc; fi
	# the firewall reads its profiles from $FWSET, not from the profile records, so a profile being removed (SKIP_PROFILE) is out of the ruleset the reload loads
	# shellcheck disable=SC2086
	put "$ETC/uid-guard.nft" 644 < <(guard_text $uids) && put "$FWSET" 644 < <(fw_set_text $(profile_names)) && guard_refresh && fw_refresh && hostssh_apply "$(hostssh_recovery || true)"; }   # the host-SSH drop-in is regenerated from the remaining records (none = removed)
pam_remove_for() { local gone=$1; shift; pam_install "$@"; }

usage_uplinks() { cat <<'EOF2'
usage: nsplit uplinks [--set "IF IF ..."]
  Show (or set) the physical network interfaces profile traffic may leave through. After setting, the firewall is reloaded.
EOF2
}
cmd_uplinks() {
	case ${1:-} in
	-h|--help) usage_uplinks;;
	--set) need_root; [ -r "$CONF" ] || die "nsplit is not set up yet (nsplit add USER)"; local u=${2:?--set needs a list} i old gone=""; for i in $u; do [ -e "/sys/class/net/$i" ] || die "no such interface: $i"; done
		[ "$(sha "$CONF")" = "$(own_sha _shared "$CONF")" ] || die "$CONF was changed by hand; edit UPLINKS there and run: nsplit reload"
		u=$(printf '%s\n' $u | tr '\n' ' '); u=${u% }
		# the ufw route rules of an uplink that leaves the list can only be named while the list still has it, so they go first; if they cannot be removed nothing is changed and this can be run again
		old=$(conf_get UPLINKS); for i in $old; do case " $u " in *" $i "*) ;; *) gone+="${gone:+ }$i";; esac; done
		if [ -n "$gone" ]; then NSPLIT_UFW_UPLINKS=$gone "$LIB/nsplit-ufw" del || die "the ufw route rules of the uplinks being dropped ($gone) could not be removed, so the uplinks were not changed: fix what is listed above and run this again"; fi
		sed -i "s|^UPLINKS=.*|UPLINKS=\"$u\"|" "$CONF"; own_record _shared "$CONF"; cmd_reload;;
	"") say "uplinks: $(conf_get UPLINKS || echo '(not set up yet)')"; say "physical interfaces here: $(discover_uplinks)";;
	*) die "usage: nsplit uplinks [--set \"IF IF\"]";;
	esac
}
cmd_reload() { need_root; unit_active nsplit-firewall.service || die "the firewall is not running (nsplit start --all)"; "$LIB/nsplit-ufw" add; $SYSTEMCTL reload nsplit-firewall.service && say "firewall reloaded"; }

cmd_run() { # nsplit run PROFILE -- command...
	local pn; need_root; pn=$(resolve_profile "${1:-}") || die "usage: nsplit run PROFILE -- command..."; shift
	exec "$LIB/nsplit-run" "$pn" "$@"; }
cmd_ts() { # nsplit ts PROFILE tailscale-arguments...
	local pn; pn=$(resolve_profile "${1:-}") || die "usage: nsplit ts PROFILE tailscale-arguments..."; shift
	exec "$TS_BIN" --socket="$(sock_of "$pn")" "$@"; }
