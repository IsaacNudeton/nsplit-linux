# shellcheck shell=bash
# nsplit common library: paths, output, validation, discovery, profile files, owned-file records, undo stack, temporary files.
# Sourced by bin/nsplit. Every path can be redirected with NSPLIT_* variables so the tool can be exercised against a scratch directory
# and fake system commands without touching the machine (the defaults are the real locations).

NSPLIT_VERSION=0.1.0
ETC=${NSPLIT_ETC:-/etc/nsplit}
PROFDIR=$ETC/profiles
CONF=$ETC/nsplit.conf
FWSET=$ETC/firewall-profiles   # the profiles the host firewall covers, one name per line: nsplit-fw up reads it (regenerated with the uid guard)
VAR=${NSPLIT_VAR:-/var/lib/nsplit}
OWNDIR=$VAR/owned          # one list per owner: "sha256  path" for every file nsplit created (removal deletes only unmodified files from here)
BKDIR=$VAR/backup          # first-time backups of files nsplit edits in place
STATEMARK=$VAR/node-state  # marker per profile: its Tailscale state directory was created by nsplit (kept on removal unless --purge)
LINGERMARK=$VAR/linger     # marker per headless profile: nsplit switched lingering on for the profile's user (removal switches it off again, and only then)
LINGERDIR=${NSPLIT_LINGER_DIR:-/var/lib/systemd/linger}   # where systemd-logind keeps one file per lingering user
RUNDIR=${NSPLIT_RUN:-/run/nsplit}
SDIR=${NSPLIT_SYSTEMD_DIR:-/etc/systemd/system}
UNITDIR=${NSPLIT_UNIT_DIR:-/usr/lib/systemd/system}
SUDOERSDIR=${NSPLIT_SUDOERS_DIR:-/etc/sudoers.d}
VISUDO=${NSPLIT_VISUDO:-visudo}
SUDO=${NSPLIT_SUDO:-sudo}
HOSTNS_PID=${NSPLIT_HOSTNS_PID:-1}              # a process that is certainly in the host network namespace (its namespace is the "host" side of every comparison)
PAMDIR=${NSPLIT_PAM_DIR:-/etc/pam.d}
PAMVENDOR=${NSPLIT_PAM_VENDOR:-/usr/lib/pam.d}
DBUSDIR=${NSPLIT_DBUS_DIR:-/etc/dbus-1/system.d}
NETNSETC=${NSPLIT_NETNS_ETC:-/etc/netns}
SYSTEMCTL=${NSPLIT_SYSTEMCTL:-systemctl}
TS_BIN=${NSPLIT_TAILSCALE:-/usr/bin/tailscale}
NETNSRUN=${NSPLIT_NETNS_RUN:-/run/netns}      # where `ip netns` keeps its namespace handles
TSRUN=${NSPLIT_TS_RUN:-/run}                    # the profile daemons keep their sockets in $TSRUN/tailscale-<profile>/
NFT=${NSPLIT_NFT:-nft}
IP=${NSPLIT_IP:-ip}
LOGINCTL=${NSPLIT_LOGINCTL:-loginctl}
DEFAULT_PUBLIC_DNS="9.9.9.9 1.1.1.1"
POOL_CANDIDATES="10.200 10.201 10.202 10.203 10.204 10.205 10.206 10.207"
GATE=$LIB/nsplit-pam-gate
SCOPED=$LIB/nsplit-scoped
DRY=0
UNDO=()
UNDO_FAILED=0              # set by rollback_all when an undo step failed: what the command then says must not claim a clean state
OWNER=_shared
APPLYING=0                 # 1 while `nsplit add` is applying changes: a failure or an interrupt then undoes them (nsplit_atexit)
INTR_SIG=""                # the exit status (128 + signal) of a HUP, INT or TERM that arrived while `nsplit add` was applying: acted on at the next safe point (intr_check)
NSPLIT_MAINPID=$$          # the main shell; a subshell that registers a temporary file cleans up its own

# ---------------------------------------------------------------- output
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'nsplit: warning: %s\n' "$*" >&2; }
die()  { printf 'nsplit: %s\n' "$*" >&2; exit 1; }
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'; else C_OK=; C_BAD=; C_DIM=; C_OFF=; fi

# is_admin: running with administrator rights (root). NSPLIT_TEST_AS_USER makes the checks behave as an ordinary user even though they run unprivileged with fakes.
is_admin() { [ -z "${NSPLIT_TEST_AS_USER:-}" ] || return 1; [ "$(id -u)" = 0 ] || [ -n "${NSPLIT_TEST:-}" ]; }
need_root() { [ "$(id -u)" = 0 ] && return 0; [ -n "${NSPLIT_TEST:-}" ] && return 0
	if command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then say "nsplit: this needs administrator rights; re-running with sudo"; exec sudo -- "$SELF" "${ARGV[@]}"; fi
	die "this command needs root: run it with sudo"; }

# ---------------------------------------------------------------- small helpers
valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,11}$ ]]; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
pyj() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }   # eval of OUR OWN literal expressions over d, never over input text
user_uid() { id -u "$1" 2>/dev/null; }
unit_active() { [ "$($SYSTEMCTL is-active "$1" 2>/dev/null)" = active ]; }
unit_state() { local o; o=$($SYSTEMCTL is-active "$1" 2>/dev/null); case $o in active|inactive|failed|activating|deactivating|reloading) printf %s "$o";; *) printf unknown;; esac; }

# ---------------------------------------------------------------- temporary files
# Every temporary file nsplit makes (the undo backups, the generated login files, the sudoers check copy, the staging file beside a target) is registered by its exact path the moment it exists,
# and this code removes nothing else: no glob, no directory listing, and a registered path is removed only while it is still the regular file (device:inode) that was registered.
# tmp_new VAR makes a private file with mktemp and puts its path in VAR: call it as a command, never inside $(...), where the path would die with the substitution's subshell.
# tmp_adopt PATH registers a file nsplit has just created at an exact path. tmp_drop PATH removes a registered file now (rollback helpers do). tmp_sweep removes whatever this process still has registered and
# is safe to repeat. The EXIT handler runs it after any undo has used the files; a subshell that registers a file cleans up its own entries when it ends (traps do not survive into subshells).
TMPREG_PATH=(); TMPREG_ID=(); TMPREG_PID=()
tmp_id() { stat -c '%d:%i' -- "$1" 2>/dev/null; }
tmp_adopt() {
	local p=$1 id i j
	case $p in ''|*$'\n'*) return 1;; esac
	[ -f "$p" ] && [ ! -L "$p" ] && id=$(tmp_id "$p") || return 1
	i=${#TMPREG_PATH[@]}   # a path registered before (a staging name used again) keeps its single entry
	for j in "${!TMPREG_PATH[@]}"; do [ "${TMPREG_PATH[$j]}" = "$p" ] && { i=$j; break; }; done
	TMPREG_PATH[i]=$p; TMPREG_ID[i]=$id; TMPREG_PID[i]=$BASHPID
	[ "$BASHPID" = "$NSPLIT_MAINPID" ] || trap tmp_sweep EXIT
	return 0
}
tmp_new() {
	local p; p=$(mktemp "${TMPDIR:-/tmp}/nsplit.XXXXXX") || die "cannot create a temporary file in ${TMPDIR:-/tmp}"
	case $p in /*) ;; *) p=$PWD/$p;; esac
	tmp_adopt "$p" || { rm -f -- "$p"; die "cannot register the temporary file $p"; }
	printf -v "$1" %s "$p"
}
tmp_rm() { # tmp_rm INDEX: remove that registered file if it is still the one registered, then forget it; a file that is gone is nothing to report
	local i=$1 p=${TMPREG_PATH[$1]}
	[ -n "$p" ] || return 0
	if [ -e "$p" ] || [ -L "$p" ]; then
		if [ -f "$p" ] && [ ! -L "$p" ] && [ "$(tmp_id "$p")" = "${TMPREG_ID[$i]}" ]; then rm -f -- "$p"
		else warn "not removing $p: it is no longer the temporary file nsplit made"; fi
	fi
	TMPREG_PATH[i]=""
}
tmp_drop() { local i; for i in "${!TMPREG_PATH[@]}"; do [ "${TMPREG_PATH[$i]}" = "$1" ] && tmp_rm "$i"; done; return 0; }
tmp_sweep() { local i; for i in "${!TMPREG_PATH[@]}"; do [ "${TMPREG_PID[$i]}" = "$BASHPID" ] && tmp_rm "$i"; done; return 0; }
# nsplit_signal N: what HUP, INT and TERM do (bin/nsplit installs it; N is 128 plus the signal number). While `nsplit add` is applying changes the FIRST signal is only noted: the step in progress finishes with its
# undo registered, and the command then ends at the next safe point (intr_check) and undoes everything, so an interrupt never lands between a change and the registration of its undo. A second signal, or any signal
# outside an apply, ends the command at once (an apply is still undone from what is registered by then).
nsplit_signal() { if [ "${APPLYING:-0}" = 1 ] && [ -z "${INTR_SIG:-}" ]; then INTR_SIG=$1; warn "interrupted: finishing the step in progress, then undoing what this command did (send the signal again to stop at once)"; else exit "$1"; fi; }
intr_check() { [ -z "${INTR_SIG:-}" ] || exit "$INTR_SIG"; }
# nsplit_atexit: the one EXIT handler of the command (bin/nsplit installs it, with traps that turn HUP, INT and TERM into a failing exit: a signal alone leaves $? at 0 in an EXIT trap,
# which used to skip the undo). The undo of an interrupted `add` comes first because it still needs the backup files; a second signal must not cut the undo or the cleanup short.
nsplit_atexit() {
	local rc=$?
	trap '' HUP INT TERM
	if [ "$rc" -ne 0 ] && [ "${APPLYING:-0}" = 1 ]; then APPLYING=0; rollback_all; fi
	tmp_sweep
	exit "$rc"
}

# ---------------------------------------------------------------- dry run / actions
# run CMD...: execute, or only print in a preview (--dry-run)
run() { if [ "$DRY" = 1 ]; then printf '    would run: %s\n' "$*"; return 0; fi; "$@"; }
# undo_push CMD...: remember how to take back the step just done; rollback_all runs them newest first
undo_push() { local s; s=$(printf '%q ' "$@"); UNDO+=("$s"); }
rollback_all() { local i n=${#UNDO[@]}; [ "$n" -gt 0 ] || return 0; warn "undoing $n step(s) done by this command"
	for ((i=n-1; i>=0; i--)); do eval "${UNDO[$i]}" >/dev/null 2>&1 || { UNDO_FAILED=1; warn "undo step failed: ${UNDO[$i]}"; }; done; UNDO=(); }

# ---------------------------------------------------------------- ownership records
own_file() { printf '%s/%s.list' "$OWNDIR" "$1"; }
own_record() { local o=$1 p=$2 f; f=$(own_file "$o"); mkdir -p "$OWNDIR"; touch "$f"; grep -v "  $p\$" "$f" > "$f.new" || true; tmp_adopt "$f.new"; printf '%s  %s\n' "$(sha "$p")" "$p" >> "$f.new"; mv -f "$f.new" "$f"; }
own_forget() { local o=$1 p=$2 f; f=$(own_file "$o"); [ -f "$f" ] || return 0; grep -v "  $p\$" "$f" > "$f.new" || true; tmp_adopt "$f.new"; mv -f "$f.new" "$f"
	[ -s "$f" ] || { rm -f "$f"; rmdir --ignore-fail-on-non-empty "$OWNDIR" 2>/dev/null; }; return 0; }
own_sha() { local f; f=$(own_file "$1"); [ -f "$f" ] && awk -v p="$2" '{s=$1; $1=""; sub(/^ +/,""); if ($0==p) print s}' "$f" | tail -1; }
own_paths() { local f; f=$(own_file "$1"); [ -f "$f" ] && awk '{$1=""; sub(/^ +/,""); print}' "$f"; }

# put PATH MODE : write stdin to PATH as the current OWNER. In a preview only says what it would do.
# Refuses to overwrite a file nsplit did not create, or that was changed since nsplit wrote it. Atomic (write beside, rename). Registers its own undo.
# Feed it with `put PATH MODE < <(generator)`, NEVER `generator | put ...`: the right side of a pipe runs in a subshell and its undo registration would be lost.
put() {
	local path=$1 mode=${2:-644} new prev had=0 cur want
	tmp_new new; cat > "$new"
	if [ -e "$path" ]; then
		had=1; cur=$(sha "$path"); want=$(sha "$new")
		if [ "$cur" = "$want" ]; then
			if [ "$DRY" = 1 ]; then printf '    unchanged: %s\n' "$path"; tmp_drop "$new"; return 0; fi
			own_record "$OWNER" "$path"; tmp_drop "$new"; return 0
		fi
		[ "$(own_sha "$OWNER" "$path")" = "$cur" ] || { tmp_drop "$new"; die "refusing to overwrite $path: nsplit did not create it, or it was changed since"; }
	fi
	if [ "$DRY" = 1 ]; then printf '    would %s: %s (mode %s)\n' "$([ $had = 1 ] && echo update || echo create)" "$path" "$mode"; tmp_drop "$new"; return 0; fi
	mkdir -p "$(dirname "$path")"
	# the undo is registered BEFORE the file is touched (restoring a file that was not changed, or removing one that was not made, does nothing), so no failure or interrupt can leave a change without its undo
	if [ $had = 1 ]; then tmp_new prev; cp -p "$path" "$prev"; undo_push put_restore "$OWNER" "$path" "$prev"   # the rollback copy: dropped by put_restore, or swept at exit when nothing needed to be undone
	else undo_push put_remove "$OWNER" "$path"; fi
	install -m "$mode" "$new" "$path.nsplit-new" && { tmp_adopt "$path.nsplit-new"; mv -f "$path.nsplit-new" "$path"; }; tmp_drop "$new"
	own_record "$OWNER" "$path"
}
# rmdir_ours DIR: remove DIR when it is empty, except a directory that belongs to another package and exists without nsplit (sudo's)
rmdir_ours() { [ "$1" = "$SUDOERSDIR" ] || rmdir --ignore-fail-on-non-empty "$1" 2>/dev/null; return 0; }
put_remove() { rm -f "$2"; own_forget "$1" "$2"; rmdir_ours "$(dirname "$2")"; true; }
put_restore() { cat "$3" > "$2" && own_record "$1" "$2"; tmp_drop "$3"; }

# ---------------------------------------------------------------- global configuration (/etc/nsplit/nsplit.conf)
conf_get() { [ -r "$CONF" ] || return 1; ( . "$CONF" 2>/dev/null; eval "printf %s \"\${$1-}\"" ); }
# SKIP_PROFILE (internal): a profile being removed, left out while the shared firewall/guard are regenerated without it
profile_names() { local f n; for f in "$PROFDIR"/*.env; do [ -e "$f" ] || continue; n=$(basename "${f%.env}"); [ "$n" = "${SKIP_PROFILE:-}" ] || printf '%s\n' "$n"; done; return 0; }
# fw_set_text NAME...: the content of $FWSET for exactly those profiles (sorted, once each; nothing for none)
fw_set_text() { [ $# -eq 0 ] || printf '%s\n' "$@" | sort -u; }
profile_exists() { [ -r "$PROFDIR/$1.env" ]; }
# profile_load NAME: read the profile into P_* variables
profile_load() {
	profile_exists "$1" || return 1
	# shellcheck disable=SC1090
	eval "$( . "$PROFDIR/$1.env"; for v in NAME LOGIN UIDN NS VH VN HOST_IP NS_IP PLEN TS_IF TS_PORT TS_HOSTNAME SSH MANAGED MODE; do printf 'P_%s=%q\n' "$v" "${!v-}"; done )"
}
# profile_operator: the Tailscale operator this profile's enrolment calls for, printed (nothing = root only). Needs profile_load.
# MANAGED=owner: the profile's user may run tailscale / nsplit login themselves. Anything else, INCLUDING a record that says nothing (written before the policy was recorded),
# is root-managed: unknown never widens who may operate the node.
profile_operator() { [ "${P_MANAGED:-}" = owner ] && printf %s "$P_LOGIN"; return 0; }
# profile_mode: desktop or headless. Needs profile_load. A record written before the mode existed says nothing and is desktop; any other value is treated as desktop too (nothing unknown turns headless behaviour on).
profile_mode() { [ "${P_MODE:-}" = headless ] && printf headless || printf desktop; }
# linger_state LOGIN: on | off | unknown, from the file systemd-logind keeps (an unreadable directory is not "off")
linger_state() { if [ -e "$LINGERDIR/$1" ]; then printf on; elif [ -d "$LINGERDIR" ] && [ -r "$LINGERDIR" ]; then printf off; else printf unknown; fi; }
sock_of() { printf '%s/tailscale-%s/tailscaled.sock' "$TSRUN" "$1"; }
ts() { local n=$1; shift; "$TS_BIN" --socket="$(sock_of "$n")" "$@"; }
backend_state() { ts "$1" status --json 2>/dev/null | pyj 'd.get("BackendState","")'; }
# resolve the profile an argument (or the calling user) refers to
resolve_profile() {
	local want=${1:-} n
	if [ -z "$want" ]; then want=${SUDO_USER:-$(id -un)}; fi
	for n in $(profile_names); do ( . "$PROFDIR/$n.env"; [ "$n" = "$want" ] || [ "$LOGIN" = "$want" ] ) && { printf %s "$n"; return 0; }; done
	return 1
}
# user_busy LOGIN UID: 0 = the user has a login session or a user manager that is running/starting/stopping, 1 = neither, 2 = could not be determined.
# A failed inspection is never "nobody is there": every caller treats 2 like 0.
user_busy() {
	local login=$1 uid=$2 s o st
	s=$($LOGINCTL list-sessions --no-legend 2>/dev/null) || return 2
	awk -v u="$login" -v i="$uid" '$2==i || $3==u {f=1} END{exit !f}' <<<"$s" && return 0
	o=$($SYSTEMCTL show -p ActiveState -p MainPID "user@$uid.service" 2>/dev/null) || return 2
	st=$(sed -n 's/^ActiveState=//p' <<<"$o"); case $st in inactive|failed) ;; active|activating|deactivating|reloading) return 0;; *) return 2;; esac
	st=$(sed -n 's/^MainPID=//p' <<<"$o"); case $st in ''|*[!0-9]*) return 2;; esac
	[ "$st" -gt 1 ] && return 0
	return 1
}

# user_sessions LOGIN UID: 0 = the user has a login session (SSH, console, graphical), 1 = none, 2 = could not be determined. The user MANAGER is not looked at: a headless profile's manager is
# supposed to be running (lingering), so only a session counts as "somebody is logged in". systemd-logind gives every user manager a session of its own (class manager or manager-early, service
# systemd-user: seen in `loginctl list-sessions` of a lingering user), which is not a login; any other class counts, and so does a session whose class cannot be read (it may have ended a moment ago:
# the conservative answer is "in use"). A failed listing is never "nobody is there".
user_sessions() {
	local login=$1 uid=$2 s id cls
	s=$($LOGINCTL list-sessions --no-legend 2>/dev/null) || return 2
	for id in $(awk -v u="$login" -v i="$uid" '$2==i || $3==u {print $1}' <<<"$s"); do
		cls=$($LOGINCTL show-session "$id" -p Class --value 2>/dev/null) || cls=unreadable
		case $cls in manager|manager-early) ;; *) return 0;; esac
	done
	return 1
}

# user_session_ids LOGIN UID: the logind sessions of the user that are not the manager's own, space separated (for the text of a refusal)
user_session_ids() {
	local login=$1 uid=$2 id cls o=""
	for id in $($LOGINCTL list-sessions --no-legend 2>/dev/null | awk -v u="$login" -v i="$uid" '$2==i || $3==u {print $1}'); do
		cls=$($LOGINCTL show-session "$id" -p Class --value 2>/dev/null) || cls=unreadable
		case $cls in manager|manager-early) ;; *) o+="${o:+ }$id";; esac
	done
	printf %s "$o"
}

# ---------------------------------------------------------------- discovery
# physical network interfaces (a device behind them: Wi-Fi, Ethernet, USB); virtual ones (tailscale, docker, bridges, veth) have none
discover_uplinks() { local i o=""; for i in /sys/class/net/*; do i=${i##*/}; [ "$i" = lo ] && continue; [ -e "/sys/class/net/$i/device" ] || continue; o+="${o:+ }$i"; done; printf %s "$o"; }
# IPv4 networks the host already uses (addresses and routes of every table), one CIDR per line
host_nets() { { $IP -4 -o addr show 2>/dev/null | awk '{print $4}'; $IP -4 route show table all 2>/dev/null | awk '$1 ~ /^[0-9]/ {print $1}'; } | sort -u; }
# pick_pool: first candidate /16 that overlaps nothing the host uses
pick_pool() {
	local c nets; nets=$(host_nets)
	for c in $POOL_CANDIDATES; do
		printf '%s\n' "$nets" | python3 -I -c '
import ipaddress,sys
pool=ipaddress.ip_network(sys.argv[1])
for l in sys.stdin:
    l=l.strip()
    if not l or l=="default": continue
    try: n=ipaddress.ip_network(l,strict=False)
    except ValueError: continue
    if n.prefixlen==0: continue
    if n.overlaps(pool): sys.exit(1)
' "$c.0.0/16" && { printf '%s.0.0/16' "$c"; return 0; }
	done
	return 1
}
# next_slot POOLPREFIX: lowest 1..254 whose third octet no profile uses
next_slot() { local used n s; used=" "; for n in $(profile_names); do used+="$( . "$PROFDIR/$n.env"; echo "${HOST_IP}" | cut -d. -f3 ) "; done
	for s in $(seq 1 254); do case $used in *" $s "*) ;; *) printf %s "$s"; return 0;; esac; done; return 1; }
port_in_use() { ss -H -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
# next_port FROM: first UDP port >= FROM that nothing listens on and no profile uses
next_port() { local p=$1 n used; used=" $(for n in $(profile_names); do ( . "$PROFDIR/$n.env"; echo "$TS_PORT" ); done | tr '\n' ' ')"
	while [ "$p" -lt 65000 ]; do case $used in *" $p "*) ;; *) port_in_use "$p" || { printf %s "$p"; return 0; };; esac; p=$((p+1)); done; return 1; }
manager_pid() { local p; p=$($SYSTEMCTL show -p MainPID --value "user@$1.service" 2>/dev/null); [ "${p:-0}" -gt 1 ] 2>/dev/null && printf %s "$p"; }
ns_obj() { stat -L -c %d:%i "$1" 2>/dev/null; }
