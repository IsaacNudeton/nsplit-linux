# shellcheck shell=bash
# nsplit mounts [check|repair] [PROFILE] : the private /etc/resolv.conf and /run/tailscale of each profile's RUNNING services, and the repair when the host replaced what they were attached to.

usage_mounts() { cat <<'EOF2'
usage: nsplit mounts [check|repair] [PROFILE]
  check (the default)  For each running service of the profile (its Tailscale daemon, its namespace sshd, the user's session manager) say whether it still sees the profile's own
                       /etc/resolv.conf and /run/tailscale: MATCH, MISMATCH (a mount was lost), NOT-DECLARED (the running service's unit no longer declares the bind: a failure that is never
                       repaired automatically) or UNKNOWN (could not be read; what a running service sees can only be read with root).
  repair               Re-attach what a check reports as MISMATCH, with `systemctl bind` into the RUNNING service: nothing is restarted and nobody is logged out. Each repair is checked again;
                       success is only reported when the check afterwards says MATCH.
  Why: a bind mount belongs to the file or directory it was made on. When the host replaces that object (NetworkManager rewrites /etc/resolv.conf; the host's tailscaled is restarted and
  /run/tailscale is re-created) the services that were already running silently lose the mount, and a fresh process still looks fine. nsplit repairs this by itself (nsplit-mounts.path watches both
  host paths, nsplit-mounts.timer is a safety net, `nsplit start` checks); this command is for looking and for repairing right now.
  Exit status: 0 everything matches (or was repaired); 2 a mount is missing, a declaration is missing or a repair failed; 3 something could not be read.
EOF2
}

# mounts_refresh: watch the two host paths (and run the safety-net timer) while any profile exists; stop when none is left
mounts_refresh() {
	if [ -z "$(profile_names)" ]; then $SYSTEMCTL disable --now nsplit-mounts.path nsplit-mounts.timer; return; fi
	$SYSTEMCTL enable --now nsplit-mounts.path nsplit-mounts.timer
}

cmd_mounts() {
	local sub=check names=() n a rc
	case ${1:-} in -h|--help|help) usage_mounts; return 0;; check|repair) sub=$1; shift;; esac
	for a in "$@"; do case $a in -h|--help) usage_mounts; return 0;; -*) die "unknown option $a";; *) n=$(resolve_profile "$a") || die "no nsplit profile '$a'"; names+=("$n");; esac; done
	[ "$sub" = repair ] && need_root
	"$LIB/nsplit-mounts" "$sub" "${names[@]}"; rc=$?
	if [ "$rc" = 3 ] && ! is_admin; then say "(What a running service sees can only be read with root: sudo nsplit mounts $sub)"; fi
	return $rc
}
