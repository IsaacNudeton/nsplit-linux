# shellcheck shell=bash
# Managed denial of enrolled users through the host's ordinary sshd (issue #18): an OPTIONAL policy, never a default. The enrolled users may enter only through their profile's namespace OpenSSH server
# (nsplit-sshd@PROFILE, its own configuration, which this never touches); a named, non-enrolled recovery account keeps host SSH access. One aggregate sshd_config.d drop-in carries `DenyUsers`.
#   nsplit add USER --host-ssh deny --recovery-user ADMIN      nsplit host-ssh status | deny PROFILE --recovery-user ADMIN | allow PROFILE
# The policy of a profile is its record's HOSTSSH=deny; the drop-in is generated from the records, so removal of a profile and the drop-in cannot disagree. Nothing in the main sshd_config is ever edited,
# and nothing here touches the firewall, Tailscale, any PAM file, the host's keys or its sshd service definition (the service is only RELOADED).

HOSTSSH_DROPIN=$SSHD_DROPDIR/50-nsplit-host-ssh.conf

usage_hostssh() { cat <<'EOF2'
usage: nsplit host-ssh status
       nsplit host-ssh deny PROFILE --recovery-user ADMIN [--dry-run] [--yes] [--no-session-check]
       nsplit host-ssh allow PROFILE [--dry-run] [--yes]
  An enrolled user normally reaches this machine over the host's own sshd as well, and a shell from there runs in the HOST network namespace (the uid guard keeps it off the network, but it sees local files,
  loopback and unix sockets). This optional policy refuses the profile's user at the host's sshd, so the user can only come in through their profile's own OpenSSH server over their tailnet.
  It writes ONE drop-in, /etc/ssh/sshd_config.d/50-nsplit-host-ssh.conf, with `DenyUsers` for every profile that has the policy, only when the host's sshd_config includes that directory (the main file is never edited),
  validates the complete configuration with sshd -t and the effective result per user with sshd -T, and reloads sshd (it never restarts it: open sessions stay). Any failure leaves the previous policy in force.
  A recovery account is mandatory: an existing, non-enrolled account that the host's sshd (as configured now) lets in, with a login shell and an authorized key or an allowed password path. nsplit cannot prove
  that the account's owner still holds the key: keep an authenticated SSH session of that account open while the policy is applied (the command refuses unless one exists; --no-session-check overrides that, on your
  own responsibility). Removing a profile updates the list and removes the drop-in when no profile has the policy. `nsplit status` shows whether the policy is configured and effective, never claims more than sshd -T said.
EOF2
}

# ---- reading the host's sshd ----------------------------------------------------------------------------------------------
# hostssh_eff USER: the effective sshd configuration for a connection of USER from loopback (sshd -T -C), one `keyword value` line per setting, keywords in lower case. Fails (prints nothing) when it cannot be read.
hostssh_eff() { local o; o=$("$SSHD_BIN" -T -C "user=$1,host=localhost,addr=127.0.0.1" -f "$SSHD_CONFIG" 2>/dev/null) || return 1; [ -n "$o" ] || return 1; printf '%s\n' "$o" | awk '{k=tolower($1); $1=""; sub(/^ /,""); print k, $0}'; }
# hostssh_includes: the host's sshd_config has an Include that covers the drop-in path
hostssh_includes() {
	python3 -I -c '
import fnmatch,os,re,sys
cfg,drop=sys.argv[1:3]
base=os.path.dirname(cfg) or "/"
try: lines=open(cfg).read().splitlines()
except OSError: sys.exit(1)
for l in lines:
    m=re.match(r"\s*Include\s+(.*)$",l,re.I)
    if not m: continue
    for g in m.group(1).split():
        g=g.strip("\"")
        if not g.startswith("/"): g=os.path.join(base,g)
        if fnmatch.fnmatchcase(drop,g): sys.exit(0)
sys.exit(1)' "$SSHD_CONFIG" "$HOSTSSH_DROPIN"
}
# hostssh_denied_users: the logins of every profile whose record says HOSTSSH=deny (SKIP_PROFILE, a profile being removed, is left out), sorted, one per line
hostssh_denied_users() { local n; { for n in $(profile_names); do ( rec_clean; . "$PROFDIR/$n.env"; [ "${HOSTSSH:-}" = deny ] && printf '%s\n' "$LOGIN" ); done; [ -z "${HOSTSSH_EXTRA:-}" ] || printf '%s\n' "$HOSTSSH_EXTRA"; } | sort -u; }   # HOSTSSH_EXTRA: the user of an add in progress (a preview has no record yet)
# hostssh_recovery: the recovery account of the policy as the records say it (the first profile that has one)
hostssh_recovery() { local n r; for n in $(profile_names); do r=$( rec_clean; . "$PROFDIR/$n.env"; [ "${HOSTSSH:-}" = deny ] && printf %s "${HOSTSSH_RECOVERY:-}" ); [ -z "$r" ] || { printf %s "$r"; return 0; }; done; return 1; }
hostssh_text() { # hostssh_text RECOVERY USER...
	local rec=$1; shift
	cat <<EOF
# nsplit: host sshd denial for enrolled users. Written by 'nsplit add --host-ssh deny' / 'nsplit host-ssh deny'; change it with nsplit, not by hand.
# These users may log in only through their profile's own OpenSSH server over their tailnet. Recovery account that keeps host SSH access: $rec
DenyUsers $*
EOF
}

# hostssh_words KEYWORD EFF: the values of one keyword of sshd -T output, one per line. Always captured into a variable first: a pipeline that ends in `grep -q` is a SIGPIPE race under pipefail (sshd -T output is
# longer than a pipe's first write, so the writer can be killed after grep has already answered, and the pipeline then reports the opposite).
hostssh_words() { grep -i "^$1 " <<<"$2" | awk '{for(i=2;i<=NF;i++) print $i}'; }

# ---- the recovery account ---------------------------------------------------------------------------------------------------
# hostssh_check_recovery ADMIN USER...: prints one line per problem (nothing = acceptable). The account is judged by what the host's sshd would do with it now, not by what its files say.
hostssh_check_recovery() {
	local a=$1 d u eff pw home shell st exp ok=0 f k uidn uid_min dn al
	shift
	pw=$(getent passwd "$a") || { echo "the recovery account '$a' does not exist"; return 0; }
	for d in "$@"; do [ "$d" != "$a" ] || echo "the recovery account '$a' is one of the users being denied"; done
	for u in $(profile_names); do ( . "$PROFDIR/$u.env"; [ "$LOGIN" = "$a" ] ) && echo "the recovery account '$a' is enrolled in nsplit (profile $u): it would be shut out of host SSH by the same mechanism it is meant to survive"; done
	IFS=: read -r _ _ uidn _ _ home shell <<<"$pw"
	uid_min=$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null); : "${uid_min:=1000}"
	{ [ "$uidn" = 0 ] || { [ "$uidn" -ge "$uid_min" ] && [ "$uidn" != 65534 ]; }; } || echo "the recovery account '$a' (uid $uidn) is a system account"
	case $shell in */nologin|*/false|"") echo "the recovery account '$a' has no login shell ($shell)";; esac
	[ -d "$home" ] || echo "the recovery account '$a' has no home directory ($home)"
	eff=$(hostssh_eff "$a") || { echo "the effective sshd configuration for '$a' cannot be read (sshd -T failed): nothing can be judged"; return 0; }
	grep -qx 'authenticationmethods any' <<<"$eff" || echo "the host's sshd requires '$(sed -n 's/^authenticationmethods //p' <<<"$eff")' for '$a' (not 'any'): this cannot be judged here, so the policy is refused"
	st=$(passwd -S "$a" 2>/dev/null | awk '{print $2}')
	if grep -qx 'usepam no' <<<"$eff" && [ "$st" = L ]; then echo "the recovery account '$a' is locked and the host's sshd does not use PAM (UsePAM no): a locked account cannot log in at all"; fi
	exp=$(chage -l "$a" 2>/dev/null | sed -n 's/^Account expires[[:space:]]*:[[:space:]]*//p')
	case $exp in ""|never) ;; *) [ "$(date -d "$exp" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ] || echo "the recovery account '$a' has expired ($exp)";; esac
	dn=$(hostssh_words denyusers "$eff"); ! grep -qxF "$a" <<<"$dn" || echo "the host's sshd already denies '$a' (DenyUsers)"
	al=$(hostssh_words allowusers "$eff"); if [ -n "$al" ]; then grep -qxF "$a" <<<"$al" || echo "the host's sshd has AllowUsers and '$a' is not in it"; fi
	if [ "$uidn" = 0 ]; then grep -qx 'permitrootlogin no' <<<"$eff" && echo "the host's sshd refuses root logins (PermitRootLogin no)"; fi
	# an allowed path in: a usable authorized key, or an allowed password for an account that has one
	if grep -qx 'pubkeyauthentication yes' <<<"$eff"; then
		for f in $(sed -n 's/^authorizedkeysfile //p' <<<"$eff"); do
			k=${f//%h/$home}; k=${k//%u/$a}; k=${k//%%/%}; case $k in /*) ;; *) k=$home/$k;; esac
			[ -r "$k" ] && ssh-keygen -l -f "$k" >/dev/null 2>&1 && ok=1
		done
	fi
	if [ $ok = 0 ] && grep -qx 'passwordauthentication yes' <<<"$eff" && [ "$st" = P ]; then ok=1; fi
	[ $ok = 1 ] || echo "the recovery account '$a' has no way in under the host's sshd as configured now: no authorized key it accepts (AuthorizedKeysFile $(sed -n 's/^authorizedkeysfile //p' <<<"$eff")) and no allowed password"
	return 0
}
# hostssh_has_session ADMIN: the recovery account has an authenticated login session over sshd right now (the held session of the procedure)
# A loop with explicit returns, not a pipeline: under pipefail a `while` whose LAST iteration is false (the user's manager session, which comes after the login session in some orders) fails the whole pipeline although a
# session was found (seen in the guest: the check said "no session" for a recovery account that had one).
hostssh_has_session() { local s; for s in $($LOGINCTL list-sessions --no-legend 2>/dev/null | awk -v u="$1" '$3==u {print $1}'); do [ "$($LOGINCTL show-session "$s" -p Service --value 2>/dev/null)" = sshd ] && return 0; done; return 1; }

# ---- applying ----------------------------------------------------------------------------------------------------------------
# hostssh_preflight RECOVERY USER...: problems for the whole change, one per line on stdout (nothing = go ahead)
hostssh_preflight() {
	local rec=$1; shift
	[ -x "$SSHD_BIN" ] || { echo "the host's sshd ($SSHD_BIN) is not installed: there is nothing to restrict"; return 0; }
	[ -r "$SSHD_CONFIG" ] || { echo "the host's sshd configuration ($SSHD_CONFIG) cannot be read"; return 0; }
	hostssh_includes || echo "the host's $SSHD_CONFIG does not include $SSHD_DROPDIR/*.conf: nsplit never edits the main sshd configuration, so the policy cannot be installed here"
	"$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1 || echo "the host's sshd configuration is already invalid (sshd -t fails): nothing is changed until that is fixed"
	[ ! -e "$HOSTSSH_DROPIN" ] || [ "$(own_sha _shared "$HOSTSSH_DROPIN")" = "$(sha "$HOSTSSH_DROPIN")" ] || echo "$HOSTSSH_DROPIN exists and was not made by nsplit (or was changed since): not overwriting it"
	local cur; cur=$(hostssh_recovery) && [ "$cur" != "$rec" ] && echo "the host-SSH policy already names '$cur' as its recovery account: one policy, one recovery account"
	hostssh_check_recovery "$rec" "$@"
}
# hostssh_verify RECOVERY USER...: the effective configuration says what it must: each user denied, the recovery account allowed (prints a problem per line, nothing = as intended)
hostssh_verify() {
	local rec=$1 u eff dn; shift
	"$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1 || { echo "sshd -t rejects the configuration"; return 0; }
	for u in "$@"; do
		eff=$(hostssh_eff "$u") || { echo "the effective configuration for $u cannot be read"; continue; }
		dn=$(hostssh_words denyusers "$eff"); grep -qxF "$u" <<<"$dn" || echo "sshd -T does not list $u in DenyUsers"
	done
	eff=$(hostssh_eff "$rec") || { echo "the effective configuration for the recovery account $rec cannot be read"; return 0; }
	dn=$(hostssh_words denyusers "$eff")
	! grep -qxF "$rec" <<<"$dn" || echo "sshd -T lists the recovery account $rec in DenyUsers"
}
sshd_reload_now() { $SYSTEMCTL reload "$SSHD_UNIT" >/dev/null 2>&1; }
# hostssh_apply RECOVERY: regenerate the drop-in from the records (denied users = hostssh_denied_users, which the caller has already updated), validate, reload. Returns 1 with the reason on stderr and the old policy in force.
# Used by `add` (undo registered by put) and by `remove` (through refresh_shared). No denied user left = the drop-in is removed.
hostssh_apply() {
	local rec=$1 users prob t; users=$(hostssh_denied_users | tr '\n' ' '); users=${users% }
	OWNER=_shared
	if [ -z "$users" ]; then
		[ -e "$HOSTSSH_DROPIN" ] || return 0
		[ "$DRY" = 1 ] && { printf '    would remove: %s (no profile has the policy any more) and reload %s\n' "$HOSTSSH_DROPIN" "$SSHD_UNIT"; return 0; }
		[ "$(own_sha _shared "$HOSTSSH_DROPIN")" = "$(sha "$HOSTSSH_DROPIN")" ] || { warn "$HOSTSSH_DROPIN was changed after nsplit wrote it: not removing it"; return 1; }
		tmp_new keep; cat "$HOSTSSH_DROPIN" > "$keep"   # the removal is undoable like a write: a failure after it (or a signal) puts the drop-in back and tells sshd again
		undo_push sshd_reload_quiet; undo_push put_restore _shared "$HOSTSSH_DROPIN" "$keep"
		rm -f "$HOSTSSH_DROPIN"; own_forget _shared "$HOSTSSH_DROPIN"
		"$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1 || { warn "the host's sshd configuration is invalid after the drop-in was removed"; return 1; }
		unit_active "$SSHD_UNIT" && { sshd_reload_now || { warn "$SSHD_UNIT did not reload"; return 1; }; HOSTSSH_RELOADED=1; }
		return 0
	fi
	# shellcheck disable=SC2086
	if [ "$DRY" = 1 ]; then put "$HOSTSSH_DROPIN" 644 < <(hostssh_text "$rec" $users); printf '    would check: sshd -t, and sshd -T for each of: %s (denied) and %s (recovery); then reload %s (never restart: open sessions stay)\n' "$users" "$rec" "$SSHD_UNIT"; return 0; fi
	undo_push sshd_reload_quiet   # the newest undo step: after the drop-in is back, the daemon is told to read it again
	# shellcheck disable=SC2086
	put "$HOSTSSH_DROPIN" 644 < <(hostssh_text "$rec" $users)
	# shellcheck disable=SC2086
	prob=$(hostssh_verify "$rec" $users)
	if [ -n "$prob" ]; then warn "the new host-SSH policy was NOT put in force, and the previous one is unchanged: $(tr '\n' ';' <<<"$prob")"; return 1; fi
	if unit_active "$SSHD_UNIT"; then sshd_reload_now || { warn "$SSHD_UNIT did not reload with the new policy"; return 1; }; HOSTSSH_RELOADED=1; fi
	return 0
}
# undo step: when sshd was told to read the new drop-in, tell it to read the restored one (never when the configuration would not parse; never when it was not told anything)
sshd_reload_quiet() { [ "${HOSTSSH_RELOADED:-0}" = 1 ] || return 0; unit_active "$SSHD_UNIT" || return 0; "$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1 && sshd_reload_now; }

# ---- the command -------------------------------------------------------------------------------------------------------------
cmd_hostssh() {
	local sub=${1:-status} n arg="" rec="" dry=0 yes=0 nosess=0 ans rc prob users f
	case $sub in -h|--help) usage_hostssh; return 0;; esac
	[ $# -gt 0 ] && shift
	case $sub in
	status) hostssh_status_all; return $?;;
	deny|allow) ;;
	*) die "usage: nsplit host-ssh status | deny PROFILE --recovery-user ADMIN | allow PROFILE (see --help)";;
	esac
	while [ $# -gt 0 ]; do case $1 in
		-h|--help) usage_hostssh; return 0;;
		--recovery-user) rec=${2:?--recovery-user needs an account name}; shift 2;;
		--dry-run) dry=1; shift;; --yes|-y) yes=1; shift;; --no-session-check) nosess=1; shift;;
		-*) die "unknown option $1 (see: nsplit host-ssh --help)";;
		*) [ -z "$arg" ] || die "one profile at a time"; arg=$1; shift;;
	esac; done
	[ -n "$arg" ] || die "name a profile: nsplit host-ssh $sub PROFILE"
	n=$(resolve_profile "$arg") || die "no nsplit profile '$arg'"
	[ "$dry" = 1 ] || need_root
	profile_load "$n"; f=$PROFDIR/$n.env
	if [ "$sub" = deny ]; then
		[ -n "$rec" ] || die "host-ssh deny needs --recovery-user ADMIN: an existing, non-enrolled account that keeps host SSH access"
		[ "${P_HOSTSSH:-}" != deny ] || [ "${P_HOSTSSH_RECOVERY:-}" != "$rec" ] || die "$n already has the policy with recovery account $rec"
		# shellcheck disable=SC2046
		prob=$(HOSTSSH_EXTRA=$P_LOGIN hostssh_preflight "$rec" $(HOSTSSH_EXTRA=$P_LOGIN hostssh_denied_users))
		if [ -z "$nosess" ] || [ "$nosess" = 0 ]; then hostssh_has_session "$rec" || prob+=$'\n'"no authenticated SSH session of the recovery account $rec exists: log in as $rec over SSH in another terminal and keep that session open while the policy is applied (nsplit cannot prove the account still works; --no-session-check overrides this on your own responsibility)"; fi
		prob=$(printf '%s\n' "$prob" | sed '/^$/d')
		if [ -n "$prob" ]; then printf '%s\n' "$prob" | sed 's/^/  PROBLEM: /' >&2; say "Nothing was changed."; exit 1; fi
		users=$(HOSTSSH_EXTRA=$P_LOGIN hostssh_denied_users | tr '\n' ' ')
		say "nsplit host-ssh deny: $P_LOGIN (profile $n), recovery account $rec"
		say "  the host's sshd will refuse: ${users% }   (the profile's own OpenSSH over the tailnet is not affected; $rec keeps host SSH)"
		say "  Changes:"; DRY=1; HOSTSSH_EXTRA=$P_LOGIN hostssh_apply "$rec"; DRY=0
		[ "$dry" = 1 ] && { say "Dry run: nothing was changed."; return 0; }
		if [ "$yes" != 1 ]; then read -r -p "Apply? Keep your SSH session of $rec open. [y/N] " ans </dev/tty || ans=n; case $ans in y|Y|yes) ;; *) say "Nothing was changed."; return 1;; esac; fi
		trap_hostssh_apply "$n" deny "$rec" "$f"; rc=$?
		[ $rc = 0 ] && say "Done: $P_LOGIN is refused at the host's sshd; check from another terminal: ssh $P_LOGIN@localhost must be refused and ssh $rec@localhost must work (nsplit status shows what sshd -T says)."
		return $rc
	fi
	# allow
	[ "${P_HOSTSSH:-}" = deny ] || die "$n has no host-SSH policy"
	say "nsplit host-ssh allow: $P_LOGIN (profile $n) may use the host's sshd again (unless something else in its configuration says otherwise)"
	[ "$dry" = 1 ] && { say "Dry run: nothing was changed."; return 0; }
	trap_hostssh_apply "$n" allow "" "$f"; rc=$?
	[ $rc = 0 ] && say "Done."
	return $rc
}
# trap_hostssh_apply PROFILE deny|allow RECOVERY RECORD: change the profile's record and apply the aggregate; if the apply fails the record is put back (the old policy is in force: the drop-in was restored by its undo)
trap_hostssh_apply() {
	local n=$1 how=$2 rec=$3 f=$4 old rc
	tmp_new old; cat "$f" > "$old"   # the record's exact bytes (a command substitution would drop its trailing blank line)
	APPLYING=1
	own_edit_env "$n" "$f" "$how" "$rec"
	if ! hostssh_apply "$(hostssh_recovery || printf %s "$rec")"; then rc=1; rollback_all; APPLYING=0; cat "$old" > "$f"; own_record "$n" "$f"; warn "the previous host-SSH policy is unchanged"; return 1; fi
	# a signal that arrived during the apply was only noted (bin/nsplit says it will undo): keep that promise, as `add` does
	if [ -n "${INTR_SIG:-}" ]; then rollback_all; APPLYING=0; cat "$old" > "$f"; own_record "$n" "$f"; warn "interrupted: the previous host-SSH policy is unchanged"; exit "$INTR_SIG"; fi
	APPLYING=0; return 0
}
# own_edit_env PROFILE FILE deny|allow RECOVERY: set or clear HOSTSSH and HOSTSSH_RECOVERY in the profile's record, and record the new hash (nsplit's own edit is not "changed by hand")
own_edit_env() {
	local n=$1 f=$2 how=$3 rec=$4
	grep -v '^HOSTSSH=\|^HOSTSSH_RECOVERY=' "$f" > "$f.nsplit-new"; tmp_adopt "$f.nsplit-new"
	[ "$how" != deny ] || printf 'HOSTSSH=deny\nHOSTSSH_RECOVERY=%s\n' "$rec" >> "$f.nsplit-new"
	cat "$f.nsplit-new" > "$f"; tmp_drop "$f.nsplit-new"; own_record "$n" "$f"
}
# hostssh_status_all: read-only; what is configured and what sshd -T says now (the configuration sshd would load, not the running daemon's memory)
hostssh_status_all() {
	local n any=0 u rec prob eff rc=0 dn
	for n in $(profile_names); do ( rec_clean; . "$PROFDIR/$n.env"; [ "${HOSTSSH:-}" = deny ] ) && any=1; done
	if [ $any = 0 ]; then say "host SSH: no profile has the policy (nothing in $SSHD_DROPDIR from nsplit: $( [ -e "$HOSTSSH_DROPIN" ] && echo "BUT $HOSTSSH_DROPIN exists" || echo "none")); to add it: nsplit host-ssh deny PROFILE --recovery-user ADMIN"; [ ! -e "$HOSTSSH_DROPIN" ]; return $?; fi
	rec=$(hostssh_recovery); say "host SSH denial: recovery account ${rec:-?}; drop-in $HOSTSSH_DROPIN"
	[ -e "$HOSTSSH_DROPIN" ] && [ "$(own_sha _shared "$HOSTSSH_DROPIN")" = "$(sha "$HOSTSSH_DROPIN")" ] && say "  PASS  the drop-in exists and is exactly what nsplit wrote" || { say "  FAIL  the drop-in is missing or was changed after nsplit wrote it"; rc=2; }
	if [ "$(id -u)" != 0 ] && [ -z "${NSPLIT_TEST:-}" ]; then say "  UNKNOWN  what sshd -T says needs administrator rights (sudo nsplit host-ssh status): nothing is claimed as enforced"; return 3; fi
	for u in $(hostssh_denied_users); do
		eff=$(hostssh_eff "$u") || { say "  UNKNOWN  the effective configuration for $u cannot be read: not reported as enforced"; [ $rc != 0 ] || rc=3; continue; }
		dn=$(hostssh_words denyusers "$eff"); grep -qxF "$u" <<<"$dn" && say "  PASS  sshd -T lists $u in DenyUsers (the host's sshd refuses $u; a running daemon needs the reload that nsplit did)" || { say "  FAIL  sshd -T does not list $u in DenyUsers: the host's sshd would let $u in"; rc=2; }
	done
	if hostssh_eff "$rec" >/dev/null; then
		prob=$(hostssh_check_recovery "$rec" $(hostssh_denied_users))
		[ -z "$prob" ] && say "  PASS  the recovery account $rec is allowed by the host's sshd as configured now" || { printf '%s\n' "$prob" | sed 's/^/  FAIL  /'; rc=2; }
	else say "  UNKNOWN  the effective configuration for the recovery account $rec cannot be read: not reported as allowed"; [ $rc != 0 ] || rc=3; fi
	unit_active "$SSHD_UNIT" && say "  INFO  $SSHD_UNIT is running" || say "  INFO  $SSHD_UNIT is not running: the policy applies whenever it starts"
	return $rc
}
