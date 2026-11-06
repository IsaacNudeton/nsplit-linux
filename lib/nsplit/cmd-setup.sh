# shellcheck shell=bash
# nsplit setup --preset shared-gpu : a thin frontend over `nsplit add --mode headless` (and, with --recovery-user, `--host-ssh deny`) for a computer several people share for GPU work: every user gets their own
# network namespace and Tailscale node, their own services run in it across logouts and reboots, and they are reached only through their own OpenSSH server over their own tailnet.
# It adds nothing of its own to what `nsplit add` does: it runs that command, user after user, as a separate process, so the add/remove/status behaviour stays exactly what it is and stays testable on its own.

usage_setup() { cat <<'EOF2'
usage: nsplit setup --preset shared-gpu [--recovery-user ADMIN] [--no-session-check] [--dry-run] [--yes] USER[=NAME] [USER[=NAME]...]
  A frontend for a computer that several people share for GPU work. For every USER it runs exactly
      nsplit add USER --mode headless [--host-ssh deny --recovery-user ADMIN]
  (USER=NAME names the profile NAME instead of USER, as `nsplit add USER --name NAME` does; a login that is not a valid profile name needs it.)
  one user after the other (each add is checked and undone on failure by itself). The result: each user has their own network namespace, Tailscale node and DNS, their own `systemctl --user`
  services run in that namespace and keep running after they log out and across reboots, and they are reached only through their own OpenSSH server over their own tailnet. With --recovery-user the
  users are also refused at the host's own sshd (see: nsplit host-ssh --help), and the account named keeps host SSH access.
  Before anything is changed it checks every user (exists, regular account, not already set up another way, not logged in) and, with --recovery-user, the recovery account and its held session.
  It stops at the first user whose add fails and says who is done, who failed and who was not attempted; running it again skips the users that are already set up and finishes the rest.
  What it does NOT do: it does not install or configure a GPU driver, CUDA, device permissions or group membership (it only reports what it sees of /dev/nvidia*, /dev/dri and the video and render
  groups), it does not sign anybody in (an administrator runs `sudo nsplit login NAME` for each, and the user approves their own link), and it does not put anybody's SSH key anywhere.
  --dry-run shows the plan and what each add would do, and changes nothing.
EOF2
}

# the profile (name) of a login, by the record's LOGIN field only: another user's profile that happens to be called like this login is not this login's profile
setup_profile_of() { local n; for n in $(profile_names); do ( . "$PROFDIR/$n.env"; [ "$LOGIN" = "$1" ] ) && { printf %s "$n"; return 0; }; done; return 1; }

cmd_setup() {
	local preset="" rec="" dry=0 yes=0 nosess=0 users=() unames=() u n uidn problems=() out rc mode first=1 done_=() failed="" skipped=() todo=() extra=() p ans gpu gr left seen allnames
	while [ $# -gt 0 ]; do case $1 in
		-h|--help) usage_setup; return 0;;
		--preset) preset=${2:?--preset needs a name (shared-gpu)}; shift 2;;
		--preset=*) preset=${1#--preset=}; shift;;
		--recovery-user) rec=${2:?--recovery-user needs an account name}; shift 2;;
		--no-session-check) nosess=1; shift;;
		--dry-run) dry=1; shift;; --yes|-y) yes=1; shift;;
		-*) die "unknown option $1 (see: nsplit setup --help)";;
		*=*) users+=("${1%%=*}"); unames+=("${1#*=}"); shift;;
		*) users+=("$1"); unames+=(""); shift;;
	esac; done
	[ "$preset" = shared-gpu ] || die "name the preset: nsplit setup --preset shared-gpu USER... (shared-gpu is the only preset in this release)"
	[ ${#users[@]} -gt 0 ] || die "name at least one user: nsplit setup --preset shared-gpu USER..."
	[ -n "$rec" ] || [ "$nosess" != 1 ] || die "--no-session-check only goes with --recovery-user"
	[ "$dry" = 1 ] || need_root
	problem() { problems+=("$*"); }
	# nm LOGIN: the name the add is given ("" = the default, the login itself)
	nm() { local i; for i in "${!users[@]}"; do [ "${users[i]}" = "$1" ] && { printf %s "${unames[i]}"; return 0; }; done; }
	# mkargs LOGIN: the arguments of the add for that login, in AARGS
	mkargs() { local x; x=$(nm "$1"); AARGS=("$1"); [ -z "$x" ] || AARGS+=(--name "$x"); AARGS+=(--mode headless ${extra[@]+"${extra[@]}"}); }
	# the users
	local i seen_names=" "
	for i in "${!users[@]}"; do u=${users[i]}
		for p in "${todo[@]:-}" "${skipped[@]:-}"; do [ "$p" != "$u" ] || { problem "$u is named twice"; continue 2; }; done
		case ${unames[i]} in -*) problem "the profile name for $u must not start with a dash: ${unames[i]}"; continue;; esac
		case $seen_names in *" ${unames[i]:-$u} "*) problem "the profile name ${unames[i]:-$u} is used twice"; continue;; esac
		seen_names+="${unames[i]:-$u} "
		uidn=$(user_uid "$u") || uidn=""
		if [ -z "$uidn" ]; then problem "no such user: $u"; continue; fi
		n=$(setup_profile_of "$u") || n=""
		if [ -n "$n" ]; then
			mode=$( . "$PROFDIR/$n.env"; printf %s "${MODE:-desktop}" )
			if [ "$mode" = headless ]; then skipped+=("$u"); else problem "$u already has a profile ($n) that is not a headless one: remove it first (nsplit remove $n) or keep it as it is and leave $u out"; fi
			continue
		fi
		# the names are captured first: a pipeline that ends in `grep -q` is a SIGPIPE race under pipefail
		allnames=$(profile_names); if grep -qx "${unames[i]:-$u}" <<<"$allnames"; then problem "a profile named ${unames[i]:-$u} already exists for another user (nsplit status); name this one differently: nsplit setup --preset shared-gpu $u=NAME"; continue; fi
		if user_busy "$u" "$uidn"; then problem "$u is logged in or has a running user manager: have them log out completely first"; fi
		todo+=("$u")
	done
	# the recovery account, once, for everybody: the same checks `nsplit add --host-ssh deny` makes, before the first user is touched
	if [ -n "$rec" ] && [ ${#todo[@]} -gt 0 ]; then
		while IFS= read -r p; do [ -z "$p" ] || problem "host SSH: $p"; done < <(hostssh_preflight "$rec" $(hostssh_denied_users) "${todo[@]:-}" 2>/dev/null | sed '/^$/d')
		if [ "$nosess" != 1 ]; then hostssh_has_session "$rec" || problem "no authenticated SSH session of the recovery account $rec exists: log in as $rec over SSH in another terminal and keep it open while this runs (nsplit cannot prove the account still works; --no-session-check overrides this on your own responsibility)"; fi
	fi
	[ ${#todo[@]} -eq 0 ] || [ -z "$rec" ] || extra=(--host-ssh deny --recovery-user "$rec"); [ -z "$rec" ] || [ "$nosess" != 1 ] || extra+=(--no-session-check)
	say "nsplit setup --preset shared-gpu: ${users[*]}"
	[ ${#skipped[@]} -eq 0 ] || say "  already set up (left as they are): ${skipped[*]}"
	# what is there of the GPU (informational: nothing about it is changed)
	gpu=$(ls /dev/nvidia[0-9]* /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')
	if [ -n "$gpu" ]; then say "  GPU devices seen: ${gpu% } (their permissions and the users' groups are not changed by this command)"; else say "  GPU devices seen: none under /dev/nvidia* or /dev/dri (informational: the profiles do not depend on a GPU being present)"; fi
	for u in "${todo[@]:-}"; do [ -n "$u" ] || continue
		gr=$(id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -xE 'video|render' | tr '\n' ' ')
		say "  $u: groups giving GPU device access: ${gr:-none of video/render} (not changed by this command)"
	done
	if [ ${#problems[@]} -gt 0 ]; then printf '  PROBLEM: %s\n' "${problems[@]}" >&2; say "Nothing was changed."; exit 1; fi
	if [ ${#todo[@]} -eq 0 ]; then say "Nothing to do: every named user is already set up."; return 0; fi
	say "  plan:"
	for u in "${todo[@]}"; do mkargs "$u"; say "    nsplit add ${AARGS[*]}"; done
	# what each add would say, so a problem that only the add can see (an address pool, a port, a unit, a name) is found before the first change
	for u in "${todo[@]}"; do
		mkargs "$u"; out=$("$SELF" add "${AARGS[@]}" --dry-run 2>&1); rc=$?
		if [ $rc != 0 ]; then printf '%s\n' "$out" | grep -E 'PROBLEM|nsplit:' | sed 's/^/  /' >&2; say "Nothing was changed: the add for $u would be refused."; exit 1; fi
		[ "$first" = 1 ] && { first=0; say "  what the add for $u would change (the others look the same, with their own names and addresses):"; printf '%s\n' "$out" | sed -n '/^Changes:/,/^Dry run/p' | sed '$d' | sed 's/^/    /'; }
	done
	[ "$dry" = 1 ] && { say "Dry run: nothing was changed."; return 0; }
	if [ "$yes" != 1 ]; then read -r -p "Set these users up? [y/N] " ans </dev/tty || ans=n; case $ans in y|Y|yes) ;; *) say "Nothing was changed."; return 1;; esac; fi
	for u in "${todo[@]}"; do
		say; say "== $u"
		mkargs "$u"
		if "$SELF" add "${AARGS[@]}" --yes; then done_+=("$u")
		else failed=$u; break; fi
	done
	say
	if [ -n "$failed" ]; then
		left=(); seen=0; for u in "${todo[@]}"; do [ "$u" = "$failed" ] && { seen=1; continue; }; [ $seen = 1 ] && left+=("$u"); done
		say "nsplit setup: STOPPED at $failed (its add failed and was undone: see above)."
		say "  done: ${done_[*]:-none}   failed: $failed   not attempted: ${left[*]:-none}"
		say "  Fix what the add reported, then run the same command again: users that are already set up are skipped."
		return 1
	fi
	say "nsplit setup: done for ${done_[*]}${skipped[*]:+ (already set up: ${skipped[*]})}."
	say "Next, for each user (an administrator for the first step; the user for the rest):"
	for u in "${done_[@]}" "${skipped[@]:-}"; do [ -n "$u" ] || continue
		n=$(setup_profile_of "$u") || continue
		say "  $u:  sudo nsplit login $n   (they open the link it prints and approve with their own Tailscale account)"
	done
	say "  then each user puts a public key in their ~/.ssh/authorized_keys, connects with ordinary OpenSSH to their profile's Tailscale address, and starts their services with systemctl --user enable --now NAME."
	say "  Check everything with: nsplit status -v     A service that listens on all addresses inside a profile is also reachable from this machine's own processes over the profile's private link."
	[ -z "$rec" ] || say "  Host SSH: these users are refused at the host's sshd; $rec keeps host SSH access (nsplit host-ssh status)."
	return 0
}
