# shellcheck shell=bash
# nsplit common library: paths, output, validation, discovery, profile files, owned-file records, undo stack.
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
OWNER=_shared

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

# ---------------------------------------------------------------- dry run / actions
# run CMD...: execute, or only print in a preview (--dry-run)
run() { if [ "$DRY" = 1 ]; then printf '    would run: %s\n' "$*"; return 0; fi; "$@"; }
# undo_push CMD...: remember how to take back the step just done; rollback_all runs them newest first
undo_push() { local s; s=$(printf '%q ' "$@"); UNDO+=("$s"); }
rollback_all() { local i n=${#UNDO[@]}; [ "$n" -gt 0 ] || return 0; warn "undoing $n step(s) done by this command"
	for ((i=n-1; i>=0; i--)); do eval "${UNDO[$i]}" >/dev/null 2>&1 || warn "undo step failed: ${UNDO[$i]}"; done; UNDO=(); }

# ---------------------------------------------------------------- ownership records
own_file() { printf '%s/%s.list' "$OWNDIR" "$1"; }
own_record() { local o=$1 p=$2 f; f=$(own_file "$o"); mkdir -p "$OWNDIR"; touch "$f"; grep -v "  $p\$" "$f" > "$f.new" || true; printf '%s  %s\n' "$(sha "$p")" "$p" >> "$f.new"; mv -f "$f.new" "$f"; }
own_forget() { local o=$1 p=$2 f; f=$(own_file "$o"); [ -f "$f" ] || return 0; grep -v "  $p\$" "$f" > "$f.new" || true; mv -f "$f.new" "$f"
	[ -s "$f" ] || { rm -f "$f"; rmdir --ignore-fail-on-non-empty "$OWNDIR" 2>/dev/null; }; return 0; }
own_sha() { local f; f=$(own_file "$1"); [ -f "$f" ] && awk -v p="$2" '{s=$1; $1=""; sub(/^ +/,""); if ($0==p) print s}' "$f" | tail -1; }
own_paths() { local f; f=$(own_file "$1"); [ -f "$f" ] && awk '{$1=""; sub(/^ +/,""); print}' "$f"; }

# put PATH MODE : write stdin to PATH as the current OWNER. In a preview only says what it would do.
# Refuses to overwrite a file nsplit did not create, or that was changed since nsplit wrote it. Atomic (write beside, rename). Registers its own undo.
# Feed it with `put PATH MODE < <(generator)`, NEVER `generator | put ...`: the right side of a pipe runs in a subshell and its undo registration would be lost.
put() {
	local path=$1 mode=${2:-644} new prev had=0 cur want
	new=$(mktemp "${TMPDIR:-/tmp}/nsplit.XXXXXX"); cat > "$new"
	if [ -e "$path" ]; then
		had=1; cur=$(sha "$path"); want=$(sha "$new")
		if [ "$cur" = "$want" ]; then
			if [ "$DRY" = 1 ]; then printf '    unchanged: %s\n' "$path"; rm -f "$new"; return 0; fi
			own_record "$OWNER" "$path"; rm -f "$new"; return 0
		fi
		[ "$(own_sha "$OWNER" "$path")" = "$cur" ] || { rm -f "$new"; die "refusing to overwrite $path: nsplit did not create it, or it was changed since"; }
	fi
	if [ "$DRY" = 1 ]; then printf '    would %s: %s (mode %s)\n' "$([ $had = 1 ] && echo update || echo create)" "$path" "$mode"; rm -f "$new"; return 0; fi
	mkdir -p "$(dirname "$path")"
	if [ $had = 1 ]; then prev=$(mktemp "${TMPDIR:-/tmp}/nsplit.XXXXXX"); cp -p "$path" "$prev"; fi
	install -m "$mode" "$new" "$path.nsplit-new" && mv -f "$path.nsplit-new" "$path"; rm -f "$new"
	own_record "$OWNER" "$path"
	if [ $had = 1 ]; then undo_push put_restore "$OWNER" "$path" "$prev"; else undo_push put_remove "$OWNER" "$path"; fi
}
# rmdir_ours DIR: remove DIR when it is empty, except a directory that belongs to another package and exists without nsplit (sudo's)
rmdir_ours() { [ "$1" = "$SUDOERSDIR" ] || rmdir --ignore-fail-on-non-empty "$1" 2>/dev/null; return 0; }
put_remove() { rm -f "$2"; own_forget "$1" "$2"; rmdir_ours "$(dirname "$2")"; true; }
put_restore() { cat "$3" > "$2" && own_record "$1" "$2"; rm -f "$3"; }

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
	eval "$( . "$PROFDIR/$1.env"; for v in NAME LOGIN UIDN NS VH VN HOST_IP NS_IP PLEN TS_IF TS_PORT TS_HOSTNAME SSH MANAGED; do printf 'P_%s=%q\n' "$v" "${!v-}"; done )"
}
# profile_operator: the Tailscale operator this profile's enrolment calls for, printed (nothing = root only). Needs profile_load.
# MANAGED=owner: the profile's user may run tailscale / nsplit login themselves. Anything else, INCLUDING a record that says nothing (written before the policy was recorded),
# is root-managed: unknown never widens who may operate the node.
profile_operator() { [ "${P_MANAGED:-}" = owner ] && printf %s "$P_LOGIN"; return 0; }
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
