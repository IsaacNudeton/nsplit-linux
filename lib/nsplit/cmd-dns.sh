# shellcheck shell=bash
# The profile's private resolver: a dnsmasq INSIDE the namespace sends tailnet names (ts.net) only to Tailscale's resolver (100.100.100.100) and everything else to the public resolvers.
# A fallback list of nameservers is NOT split DNS (glibc falls through to the next server on timeout/REFUSED/SERVFAIL, which would send private names to the public resolvers),
# so the profile's resolv.conf has ONE nameserver: the local split resolver. If it is down, names fail; they never leak.
# Before sign-in the profile uses the public resolvers only. dns_apply verifies resolution after sign-in and repairs unmodified, recorded split files when their generated settings drift.
# A failed split repair restores the previous split files; only a failed FIRST setup can return to the previous public configuration.

resolv_path() { printf '%s/netns-%s/resolv.conf' "$NETNSETC" "$1"; }
dns_state() { local f; f=$(resolv_path "$1"); [ -r "$f" ] || { echo missing; return; }
	if grep -q '^# nsplit: split resolver' "$f"; then echo split; elif grep -q '^# nsplit: .*public resolvers' "$f"; then echo public; else echo unknown; fi; }
# write_inplace FILE: stdin replaces the file's content IN PLACE (same inode: processes that already bind-mount it see the change; nothing restarts)
write_inplace() { local f=$1 new; new=$(cat); printf '%s\n' "$new" > "$f" || return 1; [ "$(cat "$f")" = "$new" ]; }
resolv_split_text() { printf '# nsplit: split resolver for %s (dnsmasq inside the namespace). Undo with: nsplit remove %s\nnameserver 127.0.0.1\n%soptions edns0 timeout:2 attempts:2\n' "$1" "$1" "${2:+search $2
}"; }
dns_q() { "$LIB/nsplit-run" "$1" -- "${@:2}"; }
# The probe helpers and dns_verify set DNS_WHY and return 0 for success, 1 for an observed unmet requirement, or 2 when the observation could not be made/interpreted.
# Capture the whole command output and its exit status before parsing: a partial answer from a failed command is not a successful check.
dns_prove_public() { local t0 t1 got o rc; t0=$(date +%s%N)
	o=$(dns_q "$1" getent ahostsv4 example.com 2>/dev/null); rc=$?; t1=$(date +%s%N)
	[ "$rc" = 0 ] || { DNS_WHY="the public DNS check could not complete (exit $rc)"; return 2; }
	got=$(awk '$2=="STREAM"{print $1; exit}' <<<"$o")
	[ -n "$got" ] && [ $(( (t1 - t0) / 1000000 )) -ge 0 ] && [ $(( (t1 - t0) / 1000000 )) -lt 3000 ] \
		|| { DNS_WHY="a public name did not resolve within 3 s"; return 1; }
	return 0; }
# dns_prove_private NAME SUFFIX FQDN ADDRS: check the node's own name and a negative name through the profile's resolver.
# A known name must return this node's own address; a negative SERVFAIL alone cannot pass. These are resolution checks, not observations of query destinations.
dns_a_records() { awk '$3=="IN" && $4=="A" {print $5}'; }
# dns_response_code: require one complete QUERY response header. Missing, malformed or multiple headers are not evidence of a particular DNS result.
dns_response_code() { awk '
/->>HEADER<<-/ {
    count++
    if ($0 !~ /^;;[[:space:]]+->>HEADER<<-[[:space:]]+opcode:[[:space:]]+QUERY,[[:space:]]+status:[[:space:]]+[[:upper:][:digit:]]+,[[:space:]]+id:[[:space:]]+[[:digit:]]+[[:space:]]*$/) { bad=1; next }
    code=$0; sub(/.*status:[[:space:]]+/,"",code); sub(/,.*/,"",code)
}
END { if (count!=1 || bad) exit 1; print code }'; }
dns_prove_private() { local n=$1 suffix=$2 fq=$3 addrs=$4 o t0 t1 a got rc rcode
	[ -n "$fq" ] && [ -n "$addrs" ] || { DNS_WHY="the node's private probe identity is unavailable"; return 2; }
	t0=$(date +%s%N); o=$(dns_q "$n" dig "$fq" A +time=2 +tries=1 +noall +comments +answer 2>/dev/null); rc=$?; t1=$(date +%s%N)
	[ "$rc" = 0 ] || { DNS_WHY="the known private-name check could not complete (exit $rc)"; return 2; }
	rcode=$(dns_response_code <<<"$o") || { DNS_WHY="the known private-name response did not contain one interpretable DNS header"; return 2; }
	[ $(( (t1 - t0) / 1000000 )) -ge 0 ] && [ $(( (t1 - t0) / 1000000 )) -lt 2000 ] && [ "$rcode" = NOERROR ] \
		|| { DNS_WHY="the node's own private name did not return NOERROR within 2 s"; return 1; }
	got=$(dns_a_records <<<"$o"); [ -n "$got" ] || { DNS_WHY="the node's own private name returned no IPv4 address"; return 1; }
	for a in $got; do
		[[ $a =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { DNS_WHY="the private-name answer could not be interpreted"; return 2; }
		case " $addrs " in *" $a "*) ;; *) DNS_WHY="the node's own private name returned an address that is not its own"; return 1;; esac
	done
	t0=$(date +%s%N); o=$(dns_q "$n" dig "nsplit-probe-$RANDOM.$suffix" A +time=2 +tries=1 +noall +comments +answer 2>/dev/null); rc=$?; t1=$(date +%s%N)
	[ "$rc" = 0 ] || { DNS_WHY="the negative private-name check could not complete (exit $rc)"; return 2; }
	rcode=$(dns_response_code <<<"$o") || { DNS_WHY="the negative private-name response did not contain one interpretable DNS header"; return 2; }
	case $rcode in NXDOMAIN|SERVFAIL|REFUSED) ;; *) DNS_WHY="the negative private-name response returned $rcode instead of an accepted negative result"; return 1;; esac
	[ $(( (t1 - t0) / 1000000 )) -ge 0 ] && [ $(( (t1 - t0) / 1000000 )) -lt 2000 ] && [ -z "$(dns_a_records <<<"$o")" ] \
		|| { DNS_WHY="the negative private-name check did not return an address-free negative response within 2 s"; return 1; }
	return 0; }

# dns_probe_context NAME: read the current node, never a saved success marker. Sets DNS_SUFFIX, DNS_FQDN and DNS_ADDRS for this invocation only.
dns_probe_context() {
	local n=$1 be state rc
	DNS_SUFFIX=; DNS_FQDN=; DNS_ADDRS=
	be=$(ts "$n" status --json 2>/dev/null); rc=$?
	[ "$rc" = 0 ] || { DNS_WHY="the profile's Tailscale status could not be read (exit $rc)"; return 2; }
	state=$(pyj 'd.get("BackendState","")' <<<"$be") && [ -n "$state" ] || { DNS_WHY="the profile's Tailscale status could not be interpreted"; return 2; }
	[ "$state" = Running ] || { DNS_WHY="the profile's Tailscale node is $state, not Running"; return 1; }
	DNS_SUFFIX=$(pyj '(d.get("CurrentTailnet") or {}).get("MagicDNSSuffix","") or d.get("MagicDNSSuffix","")' <<<"$be") || { DNS_WHY="the node's MagicDNS suffix could not be read"; return 2; }
	case $DNS_SUFFIX in "") DNS_WHY="the node has no MagicDNS suffix, so private DNS cannot be verified"; return 1;; *.ts.net) ;; *) DNS_WHY="the node returned a MagicDNS suffix outside ts.net"; return 2;; esac
	case $DNS_SUFFIX in *[!A-Za-z0-9.-]*|.*|*..*) DNS_WHY="the node returned an invalid MagicDNS suffix"; return 2;; esac
	DNS_FQDN=$(pyj '(d.get("Self") or {}).get("DNSName","")' <<<"$be") || { DNS_WHY="the node's own DNS name could not be read"; return 2; }; DNS_FQDN=${DNS_FQDN%.}
	case $DNS_FQDN in *[!A-Za-z0-9.-]*|.*|*..*) DNS_WHY="the node returned an invalid private DNS name"; return 2;; *."$DNS_SUFFIX") ;; *) DNS_WHY="the node has no usable DNS name under its own tailnet suffix"; return 2;; esac
	DNS_ADDRS=$(pyj '" ".join((d.get("Self") or {}).get("TailscaleIPs") or [])' <<<"$be") && [ -n "$DNS_ADDRS" ] || { DNS_WHY="the node's own addresses could not be read"; return 2; }
	return 0
}
dns_config_text() { local n=$1 servers pub; servers=$(conf_get PUBLIC_DNS); servers=${servers:-$DEFAULT_PUBLIC_DNS}
	pub=$(for s in $servers; do printf 'server=%s\n' "$s"; done)
	PUB=$pub awk '{ if ($0=="@PUBLIC_SERVERS@") print ENVIRON["PUB"]; else print }' "$SHARE/dnsmasq.conf.in" | sed "s|@NAME@|$n|g"; }

# dns_verify NAME: read-only, fresh verification of the intended configuration and its public/private resolution. It never starts/stops a service or rewrites a file.
# DNS_WHY describes the result. Return 0 = verified now; 1 = observed unmet requirement; 2 = unable to obtain/interpret a required observation.
dns_verify() {
	local n=$1 f cfg actual expected rc suffix fqdn addrs
	DNS_WHY=
	profile_load "$n" || { DNS_WHY="the profile record could not be read"; return 2; }
	dns_probe_context "$n"; rc=$?; [ "$rc" = 0 ] || return "$rc"
	suffix=$DNS_SUFFIX; fqdn=$DNS_FQDN; addrs=$DNS_ADDRS
	f=$(resolv_path "$n"); cfg=$ETC/dns/$n.conf
	actual=$(cat -- "$f" 2>/dev/null) || { DNS_WHY="the profile's resolver file could not be read"; return 2; }
	expected=$(resolv_split_text "$n" "$DNS_SUFFIX")
	[ "$actual" = "$expected" ] || { DNS_WHY="the profile's resolver file is not the expected split configuration"; return 1; }
	actual=$(cat -- "$cfg" 2>/dev/null) || { DNS_WHY="the profile's split-resolver configuration could not be read"; return 2; }
	expected=$(dns_config_text "$n") || { DNS_WHY="the expected split-resolver configuration could not be generated"; return 2; }
	[ "$actual" = "$expected" ] || { DNS_WHY="the split-resolver configuration does not match this profile's intended routing"; return 1; }
	dns_prove_public "$n"; rc=$?; [ "$rc" = 0 ] || return "$rc"
	dns_prove_private "$n" "$suffix" "$fqdn" "$addrs"; rc=$?; [ "$rc" = 0 ] || return "$rc"
	# A node can change tailnets while the probes run. Do not commit a repair or
	# report success for a context that is already observably stale.
	dns_probe_context "$n"; rc=$?
	[ "$rc" = 0 ] || { DNS_WHY="after the DNS checks: $DNS_WHY"; return "$rc"; }
	if [ "$DNS_SUFFIX" != "$suffix" ] || [ "$DNS_FQDN" != "$fqdn" ] || [ "$DNS_ADDRS" != "$addrs" ]; then
		DNS_WHY="the node's private DNS context changed during the DNS checks"; return 1
	fi
	DNS_WHY="public and private DNS resolution checks passed during this invocation"
	return 0
}
# A split repair may restore these bytes on failure, so verify both their ownership
# records and the supported private-routing shape. A marker or matching desired
# text alone does not give permission to overwrite a file. Empty RECORD checks
# staged files only; it is never used to authorize writes to the live paths.
dns_split_files_check() { python3 -I - "$1" "$2" "$3" "${4:-}" "$(id -u)" <<'PY'
import collections, hashlib, ipaddress, os, pathlib, re, stat, sys
n, resolver, config, record, uid = sys.argv[1:]
uid = int(uid)
class Refusal(Exception): pass
def read(path):
    p = pathlib.Path(path)
    if not p.is_absolute() or str(p.resolve(strict=True)) != str(p):
        raise Refusal("refusing a DNS path with a symlink or noncanonical parent")
    st = p.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise Refusal("refusing a DNS file that is not a single regular file")
    if st.st_uid != uid or st.st_mode & 0o022:
        raise Refusal("refusing a DNS file not protected by its administrator")
    for parent in p.parents:
        stp = parent.lstat()
        if stp.st_uid not in (0, uid) or (stp.st_mode & 0o022 and not stp.st_mode & stat.S_ISVTX):
            raise Refusal("refusing a DNS path with an unprotected parent")
    return p.read_bytes()
try:
    rb, cb = read(resolver), read(config)
    if record:
        entries = {}
        for line in read(record).decode('utf-8').splitlines():
            m = re.fullmatch(r'([0-9a-f]{64})  (/.+)', line)
            if not m or m[2] in entries:
                raise Refusal("the profile's ownership record is malformed or contains duplicate paths")
            entries[m[2]] = m[1]
        for path, data in ((resolver, rb), (config, cb)):
            if path not in entries:
                raise Refusal("a split DNS file has no ownership record for this profile")
            if entries[path] != hashlib.sha256(data).hexdigest():
                raise Refusal("a split DNS file was changed since nsplit recorded it; refusing to overwrite it")
    lines = rb.decode('utf-8').splitlines()
    header = '# nsplit: split resolver for %s (dnsmasq inside the namespace). Undo with: nsplit remove %s' % (n, n)
    expected = [header, 'nameserver 127.0.0.1']
    if len(lines) == 4 and lines[2].startswith('search '):
        suffix = lines[2][7:]
        if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.ts\.net', suffix) or '..' in suffix:
            raise Refusal("the previous split resolver has an unsupported search suffix")
        expected.append('search ' + suffix)
    expected.append('options edns0 timeout:2 attempts:2')
    if lines != expected:
        raise Refusal("the previous resolver file is not a supported loopback-only split configuration")
    lines = cb.decode('utf-8').splitlines()
    header = '# generated by nsplit for profile %s. Runs INSIDE netns-%s as user dnsmasq (nsplit-dns@%s.service).' % (n, n, n)
    if not lines or lines[0] != header:
        raise Refusal("the split-resolver configuration does not identify this profile")
    fixed = collections.Counter(['listen-address=127.0.0.1', 'bind-interfaces', 'port=53', 'pid-file=',
                                 'log-facility=-', 'no-resolv', 'no-hosts', 'domain-needed', 'cache-size=0',
                                 'server=/ts.net/100.100.100.100'])
    public = 0
    for line in lines[1:]:
        line = line.strip()
        if not line or line.startswith('#'): continue
        if fixed[line]:
            fixed[line] -= 1
        elif line.startswith('server='):
            address = line[7:]
            if '%' in address: raise Refusal("the public DNS upstream is not a plain IP address")
            try: ipaddress.ip_address(address)
            except ValueError: raise Refusal("the split-resolver configuration contains an unsupported DNS route")
            public += 1
        else:
            raise Refusal("the split-resolver configuration contains an unsupported directive")
    if any(fixed.values()) or not public:
        raise Refusal("the split-resolver configuration is missing its private-routing controls or public upstreams")
except Refusal as e:
    print(e); sys.exit(1)
except (OSError, UnicodeError) as e:
    print("the split DNS files or ownership record could not be inspected (%s)" % type(e).__name__); sys.exit(2)
PY
}

# Use raw files for transaction copies: shell substitutions discard trailing
# newlines. The resolver is always written through its existing inode, including
# on rollback. A different inode or a symlink is not our transaction's target.
dns_copy_inplace() {
	local from=$1 to=$2 identity=$3
	[ -f "$to" ] && [ ! -L "$to" ] && [ "$(stat -c '%d:%i' -- "$to" 2>/dev/null)" = "$identity" ] || return 1
	cat -- "$from" > "$to" && cmp -s -- "$from" "$to"
}
# dnsmasq does not bind-mount its configuration file. Replace complete files
# atomically so even an automatic daemon restart cannot read a truncated config.
dns_replace_file() {
	local from=$1 to=$2 stage
	[ -f "$to" ] && [ ! -L "$to" ] || return 1
	stage=$(mktemp "$(dirname "$to")/.nsplit-dns.XXXXXX") || return 1
	if cp -p -- "$from" "$stage" && mv -fT -- "$stage" "$to"; then return 0; fi
	rm -f -- "$stage"; return 1
}
dns_repair_record_text() { python3 -I - "$1" "$2" "$3" <<'PY'
import hashlib, pathlib, sys
record, resolver, config = map(pathlib.Path, sys.argv[1:])
try:
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (resolver, config)}
    for line in record.read_text().splitlines():
        path = line[66:]
        print(hashes.get(path, line[:64]) + '  ' + path)
except (OSError, UnicodeError):
    sys.exit(1)
PY
}

# Restore only this transaction's split files, never a public resolver list. If
# restoring the config fails, request a stop instead of loading an uncertain file.
dns_split_restore() {
	local n=$1 tx=$2 f=$3 cfg=$4 record=$5 identity=$6 was=$7 cfg_changed=$8 service_changed=$9 record_changed=${10} bad= cfg_ok=1
	dns_copy_inplace "$tx/resolv" "$f" "$identity" || bad="resolver file; "
	if [ "$cfg_changed" = 1 ] && ! dns_replace_file "$tx/config" "$cfg"; then bad+="dnsmasq configuration; "; cfg_ok=0; fi
	if [ "$record_changed" = 1 ] && ! dns_replace_file "$tx/owned" "$record"; then bad+="ownership record; "; fi
	if [ "$cfg_changed" = 1 ] || [ "$service_changed" = 1 ]; then
		if [ "$was" = active ] && [ "$cfg_ok" = 1 ]; then
			$SYSTEMCTL restart "nsplit-dns@$n.service" >/dev/null 2>&1 && [ "$(unit_state "nsplit-dns@$n.service")" = active ] || bad+="previous resolver service; "
		else
			$SYSTEMCTL stop "nsplit-dns@$n.service" >/dev/null 2>&1 && [ "$(unit_state "nsplit-dns@$n.service")" = inactive ] || bad+="resolver stop; "
		fi
	fi
	DNS_RESTORE_WHY=${bad%; }; [ -z "$bad" ]
}

dns_apply_split() {
	local n=$1 f cfg record expected_resolv expected_cfg why rc tx identity was cfg_changed=0 service_changed=0 record_changed=0
	local failure= result=2 saved_traps dns_repair_signal=
	f=$(resolv_path "$n"); cfg=$ETC/dns/$n.conf; record=$(own_file "$n")
	why=$(dns_split_files_check "$n" "$f" "$cfg" "$record"); rc=$?
	[ "$rc" = 0 ] || { DNS_WHY="$why; split DNS was not changed"; return "$rc"; }
	dns_probe_context "$n"; rc=$?; [ "$rc" = 0 ] || return "$rc"
	expected_resolv=$(resolv_split_text "$n" "$DNS_SUFFIX")
	expected_cfg=$(dns_config_text "$n") || { DNS_WHY="the expected split-resolver configuration could not be generated"; return 2; }
	if [ "$(cat -- "$f")" = "$expected_resolv" ] && [ "$(cat -- "$cfg")" = "$expected_cfg" ]; then dns_verify "$n"; return $?; fi
	was=$(unit_state "nsplit-dns@$n.service")
	case $was in active|inactive|failed) ;; *) DNS_WHY="the resolver unit is $was; refusing to repair while its state cannot be established"; return 2;; esac
	identity=$(stat -c '%d:%i' -- "$f") || { DNS_WHY="the resolver inode could not be read"; return 2; }
	tx=$(mktemp -d "$VAR/dns-$n.XXXXXX") || { DNS_WHY="a private DNS repair backup could not be created"; return 2; }
	if ! { cp -p -- "$f" "$tx/resolv" && cp -p -- "$cfg" "$tx/config" && cp -p -- "$record" "$tx/owned" \
		&& printf '%s\n' "$expected_resolv" > "$tx/nextresolv" && printf '%s\n' "$expected_cfg" > "$tx/nextconfig" \
		&& chmod --reference="$cfg" "$tx/nextconfig"; }; then
		rm -rf -- "$tx"; DNS_WHY="the split DNS repair could not preserve its original files"; return 2
	fi
	why=$(dns_split_files_check "$n" "$tx/nextresolv" "$tx/nextconfig"); rc=$?
	if [ "$rc" != 0 ]; then rm -rf -- "$tx"; DNS_WHY="the generated DNS repair is not supported: $why"; return "$rc"; fi
	if ! cmp -s -- "$tx/config" "$tx/nextconfig" && ! dnsmasq --test --conf-file="$tx/nextconfig" >/dev/null 2>&1; then
		rm -rf -- "$tx"; DNS_WHY="the generated split-resolver configuration failed its syntax check; split DNS was not changed"; return 1
	fi
	# Refuse a concurrent edit observed since the snapshot. The profile lock covers
	# cooperating DNS calls; it cannot serialize arbitrary administrator file edits.
	if ! cmp -s -- "$tx/resolv" "$f" || ! cmp -s -- "$tx/config" "$cfg" || ! cmp -s -- "$tx/owned" "$record"; then
		rm -rf -- "$tx"; DNS_WHY="split DNS changed while preparing its repair; nothing was overwritten"; return 2
	fi
	# Defer these signals to the checked rollback path once editing begins. SIGKILL
	# and power loss cannot guarantee rollback; no split transition writes a public
	# nameserver list, even if execution is terminated before recovery completes.
	saved_traps=$(trap -p HUP INT TERM)
	trap 'dns_repair_signal=HUP' HUP; trap 'dns_repair_signal=INT' INT; trap 'dns_repair_signal=TERM' TERM
	while :; do
		if ! cmp -s -- "$tx/config" "$tx/nextconfig"; then
			# A rename may complete even if its process cannot report success.
			# From this point recovery must assume the new config became visible.
			cfg_changed=1
			if ! dns_replace_file "$tx/nextconfig" "$cfg"; then failure="the new dnsmasq configuration could not be installed"; break; fi
		fi
		[ -z "$dns_repair_signal" ] || { failure="DNS repair was interrupted ($dns_repair_signal)"; break; }
		if ! cmp -s -- "$tx/resolv" "$tx/nextresolv" && ! dns_copy_inplace "$tx/nextresolv" "$f" "$identity"; then failure="the new resolver text could not be written in place"; break; fi
		[ -z "$dns_repair_signal" ] || { failure="DNS repair was interrupted ($dns_repair_signal)"; break; }
		if [ "$cfg_changed" = 1 ] || [ "$was" != active ]; then
			service_changed=1
			if [ "$cfg_changed" = 1 ]; then $SYSTEMCTL restart "nsplit-dns@$n.service" >/dev/null 2>&1; rc=$?
			else $SYSTEMCTL start "nsplit-dns@$n.service" >/dev/null 2>&1; rc=$?; fi
			if [ "$rc" != 0 ]; then failure="the repaired split resolver could not start"; result=1; break; fi
		fi
		[ -z "$dns_repair_signal" ] || { failure="DNS repair was interrupted ($dns_repair_signal)"; break; }
		dns_verify "$n"; result=$?
		[ "$result" = 0 ] || { failure=$DNS_WHY; break; }
		[ -z "$dns_repair_signal" ] || { failure="DNS repair was interrupted ($dns_repair_signal)"; result=2; break; }
		if ! cmp -s -- "$tx/owned" "$record" || ! dns_repair_record_text "$tx/owned" "$f" "$cfg" > "$tx/nextowned" \
			|| ! chmod --reference="$record" "$tx/nextowned"; then failure="the DNS repair ownership update could not be prepared"; result=2; break; fi
		record_changed=1
		if ! dns_replace_file "$tx/nextowned" "$record" || ! cmp -s -- "$tx/nextowned" "$record"; then failure="the DNS repair ownership update could not be committed"; result=2; break; fi
		[ -z "$dns_repair_signal" ] || { failure="DNS repair was interrupted ($dns_repair_signal)"; result=2; break; }
		break
	done
	if [ -n "$failure" ]; then
		if dns_split_restore "$n" "$tx" "$f" "$cfg" "$record" "$identity" "$was" "$cfg_changed" "$service_changed" "$record_changed"; then
			DNS_WHY="$failure; the previous split files and ownership were restored (no public fallback)"
		else DNS_WHY="$failure; rollback incomplete: $DNS_RESTORE_WHY; DNS is NOT verified (no public fallback)"; result=2; fi
	fi
	trap - HUP INT TERM; [ -z "$saved_traps" ] || eval "$saved_traps"
	if [ -n "$failure" ] && [ "$result" = 2 ] && [ -n "${DNS_RESTORE_WHY:-}" ]; then
		warn "$n: recovery copies were retained in $tx"
	else rm -rf -- "$tx"; fi
	return "$result"
}

# All callers, including the administrator path and the fixed owner helper,
# share this lock. Keep the body in this shell so DNS_WHY survives its return.
dns_lock_path_check() { python3 -I - "$1" "$(id -u)" <<'PY'
import os, pathlib, stat, sys
p = pathlib.Path(sys.argv[1]); uid = int(sys.argv[2])
try:
    if not p.is_absolute() or str(p.resolve(strict=False)) != str(p):
        print("the DNS lock path contains a symlink or noncanonical parent"); sys.exit(1)
    for parent in p.parents:
        if not parent.exists(): continue
        st = parent.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid not in (0, uid) or (st.st_mode & 0o022 and (parent == p.parent or not st.st_mode & stat.S_ISVTX)):
            print("the DNS lock has an unprotected parent directory"); sys.exit(1)
    if os.path.lexists(p):
        st = p.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != uid or st.st_mode & 0o022:
            print("the DNS lock is not a protected single regular file"); sys.exit(1)
except OSError:
    print("the DNS lock path could not be inspected"); sys.exit(2)
PY
}
dns_apply() {
	local n=$1 dns_lock_fd rc lock why
	DNS_WHY=; valid_name "$n" || { DNS_WHY="invalid profile name"; return 1; }
	lock=$VAR/scoped-$n.lock
	why=$(dns_lock_path_check "$lock"); rc=$?
	[ "$rc" = 0 ] || { DNS_WHY=$why; warn "$DNS_WHY"; return "$rc"; }
	if ! command -v flock >/dev/null 2>&1 || ! mkdir -p "$VAR"; then DNS_WHY="the profile's DNS lock could not be prepared"; warn "$DNS_WHY"; return 2; fi
	# Recheck after creating any missing parent, then open without truncation.
	# An existing hardlink must never become a write to an unrelated root file.
	why=$(dns_lock_path_check "$lock"); rc=$?
	[ "$rc" = 0 ] || { DNS_WHY=$why; warn "$DNS_WHY"; return "$rc"; }
	if ! exec {dns_lock_fd}<>"$lock"; then DNS_WHY="the profile's DNS lock could not be opened"; warn "$DNS_WHY"; return 2; fi
	if ! flock -w "${NSPLIT_LOCK_WAIT:-60}" "$dns_lock_fd"; then
		exec {dns_lock_fd}>&-; DNS_WHY="another DNS operation for $n is still running"; warn "$DNS_WHY"; return 2
	fi
	dns_apply_locked "$n"; rc=$?
	exec {dns_lock_fd}>&-
	return "$rc"
}
dns_apply_locked() {
	local n=$1 f state pub cfg text rc i o ready=0; DNS_WHY=; f=$(resolv_path "$n")
	profile_load "$n" || { DNS_WHY="the profile record could not be read"; return 2; }
	state=$(dns_state "$n")
	if [ "$state" = split ]; then
		dns_apply_split "$n"; rc=$?
		if [ "$rc" = 0 ]; then say "DNS for $n: $DNS_WHY."
		else warn "$n: $DNS_WHY; no public DNS fallback was applied"; fi
		return "$rc"
	fi
	[ "$state" = public ] || { DNS_WHY="the resolver file is not in the state nsplit expects ($state); it was not changed"; warn "$n: $DNS_WHY"; return 1; }
	dns_probe_context "$n"; rc=$?; [ "$rc" = 0 ] || { warn "$n: $DNS_WHY; DNS was not changed"; return "$rc"; }
	text=$(dns_config_text "$n") || { DNS_WHY="the split-resolver configuration could not be generated"; return 2; }
	pub=$(cat -- "$f") || { DNS_WHY="the previous public resolver file could not be read"; return 2; }
	OWNER=$n; cfg=$ETC/dns/$n.conf
	put "$cfg" 644 <<<"$text"
	if ! $SYSTEMCTL enable --now "nsplit-dns@$n.service" >/dev/null 2>&1; then DNS_WHY="the split resolver did not start"; dns_revert "$n" "$pub"; warn "$n: $DNS_WHY; the first setup was rolled back"; return 1; fi
	for i in $(seq 20); do
		if o=$(dns_q "$n" dig @127.0.0.1 example.com A +time=1 +tries=1 2>/dev/null) && grep -q 'status: NOERROR' <<<"$o"; then ready=1; break; fi
		sleep 0.25
	done
	[ "$ready" = 1 ] || { DNS_WHY="the split resolver did not answer inside the namespace"; dns_revert "$n" "$pub"; warn "$n: $DNS_WHY; the first setup was rolled back"; return 1; }
	resolv_split_text "$n" "$DNS_SUFFIX" | write_inplace "$f" && own_record "$n" "$f" \
		|| { DNS_WHY="the split resolver file could not be written"; dns_revert "$n" "$pub"; warn "$n: $DNS_WHY; the first setup was rolled back"; return 1; }
	dns_verify "$n"; rc=$?
	if [ "$rc" = 0 ]; then say "DNS for $n: $DNS_WHY."
	else dns_revert "$n" "$pub"; warn "$n: $DNS_WHY; the first setup was rolled back to the previous public resolver"; fi
	return "$rc"
}
# dns_revert NAME PUBLIC_TEXT: back to public-only resolution (byte-identical file), resolver stopped and its config removed
dns_revert() { local n=$1 f; f=$(resolv_path "$1"); printf '%s\n' "$2" | write_inplace "$f" && own_record "$n" "$f"; $SYSTEMCTL disable --now "nsplit-dns@$n.service" >/dev/null 2>&1; OWNER=$n; put_remove "$n" "$ETC/dns/$n.conf"; }
