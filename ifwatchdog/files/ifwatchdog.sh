#!/bin/sh
# ifwatchdog - interface health watchdog for OpenWrt
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026  ifwatchdog contributors
#
# One instance per UCI 'watchdog' section. Detects a *silently* stalled
# interface (WireGuard handshake age and/or interface-bound ping) and, only
# when explicitly enabled, restarts it. Safety first: input validation, an
# interface denylist, monitor-by-default, debounce and a circuit breaker.
#
# shellcheck shell=dash
# shellcheck disable=SC3043  # 'local' is supported by BusyBox ash (the target)

set -u

PROG=ifwatchdog
STATE_DIR="${IFWATCHDOG_STATE_DIR:-/var/run/ifwatchdog}"

# Networks that must never be auto-restarted (self-lockout protection).
# Entries are shell glob patterns, matched case-sensitively. 'lan*' (not just
# 'lan'/'lan[0-9]*') also catches admin-path aliases like 'lanmgmt'/'lan-guest'.
# 'wan' is deliberately NOT protected: restarting wan is a legitimate use.
DEFAULT_PROTECTED="lan* mgmt* management* admin loopback"

# --- logging ---------------------------------------------------------------

# log LEVEL MESSAGE...
log() {
	local lvl="$1"; shift
	# Non-error chatter can be silenced via option 'log 0'.
	case "$lvl" in
		err|crit|warn) : ;;
		*) [ "${OPT_log:-1}" = "0" ] && return 0 ;;
	esac
	logger -t "$PROG" -p "daemon.$lvl" -- "[${SECTION:-?}] $*" 2>/dev/null
	# Mirror to stderr only when attached to a terminal (foreground/testing);
	# under procd this stays quiet so logger is the single syslog source.
	if [ -t 2 ]; then printf '%s: [%s] %s\n' "$lvl" "${SECTION:-?}" "$*" >&2; fi
}

# --- validation ------------------------------------------------------------

valid_uint() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_ifname() {
	local n="${1:-}"
	case "$n" in
		-*) return 1 ;;                       # never let a value become an option (e.g. ifup -a)
		''|*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	[ "${#n}" -le 15 ] || return 1   # Linux IFNAMSIZ - 1
	return 0
}

valid_host() {
	# IPv4 / IPv6 / hostname characters only; never an option.
	case "${1:-}" in
		-*) return 1 ;;
		''|*[!A-Za-z0-9.:-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Resolves a UCI network name's actual L3 device. Prefers the live netifd
# view (ifstatus): a static 'option device' can be a UCI cross-reference
# ('@lan') or absent (bridge auto-naming), neither of which a plain
# 'uci get network.$n.device' resolves correctly. Falls back to the static
# 'device'/'ifname' options when ifstatus is unavailable or the link is down.
resolve_l3_device() {
	local n="$1" dev=""
	if command -v ifstatus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		dev="$(ifstatus "$n" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)"
	fi
	[ -n "$dev" ] || dev="$(uci -q get "network.$n.device" 2>/dev/null)"
	[ -n "$dev" ] || dev="$(uci -q get "network.$n.ifname" 2>/dev/null | awk '{print $1}')"
	printf '%s' "$dev"
}

# All configured UCI network section names (one per line).
network_section_names() {
	uci -q show network 2>/dev/null | sed -n "s/^network\.\([A-Za-z0-9_]*\)=.*/\1/p"
}

is_protected() {
	local n="$1" p dev pn rc=1
	# set -f: DEFAULT_PROTECTED entries are glob patterns to MATCH against $n,
	# never to expand against the filesystem (guards protected_networks='*').
	set -f
	for p in $DEFAULT_PROTECTED ${OPT_protected:-}; do
		# shellcheck disable=SC2254  # unquoted $p is intentional: glob match
		case "$n" in $p) rc=0; break ;; esac
	done
	set +f
	[ "$rc" = 0 ] && return 0
	# Alias networks: protect anything sharing the L3 device of ANY network
	# whose NAME matches a protected pattern (not just 'lan' specifically) -
	# e.g. a renamed management network 'mgmt0' on its own bridge still
	# protects a second alias pointed at that same bridge under another name.
	dev="$(resolve_l3_device "$n")"
	[ -n "$dev" ] || return 1
	for pn in $(network_section_names); do
		[ "$pn" = "$n" ] && continue
		set -f
		rc=1
		for p in $DEFAULT_PROTECTED ${OPT_protected:-}; do
			# shellcheck disable=SC2254  # unquoted $p is intentional: glob match
			case "$pn" in $p) rc=0; break ;; esac
		done
		set +f
		[ "$rc" = 0 ] || continue
		[ "$(resolve_l3_device "$pn")" = "$dev" ] && return 0
	done
	return 1
}

# True if at least one protected-pattern network name resolves an L3 device -
# i.e. the alias check above has something to compare against. Used only for
# the startup warning (validate_config), never to refuse a config.
protected_device_exists() {
	local pn p
	for pn in $(network_section_names); do
		set -f
		for p in $DEFAULT_PROTECTED ${OPT_protected:-}; do
			# shellcheck disable=SC2254  # unquoted $p is intentional: glob match
			case "$pn" in
				$p)
					if [ -n "$(resolve_l3_device "$pn")" ]; then
						set +f; return 0
					fi ;;
			esac
		done
		set +f
	done
	return 1
}

# --- config ----------------------------------------------------------------

uget() { uci -q get "ifwatchdog.$1.$2" 2>/dev/null; }

load_config() {
	OPT_enabled="$(uget "$SECTION" enabled)";                       OPT_enabled="${OPT_enabled:-0}"
	OPT_interface="$(uget "$SECTION" interface)"
	OPT_method="$(uget "$SECTION" method)";                         OPT_method="${OPT_method:-both}"
	OPT_ping_host="$(uget "$SECTION" ping_host)"
	OPT_ping_timeout="$(uget "$SECTION" ping_timeout)";             OPT_ping_timeout="${OPT_ping_timeout:-3}"
	OPT_interval="$(uget "$SECTION" interval)";                     OPT_interval="${OPT_interval:-60}"
	OPT_max_handshake_age="$(uget "$SECTION" max_handshake_age)";   OPT_max_handshake_age="${OPT_max_handshake_age:-150}"
	OPT_failures="$(uget "$SECTION" failures)";                     OPT_failures="${OPT_failures:-2}"
	OPT_action="$(uget "$SECTION" action)";                         OPT_action="${OPT_action:-monitor}"
	OPT_action_network="$(uget "$SECTION" action_network)"
	OPT_script="$(uget "$SECTION" script)"
	OPT_debounce="$(uget "$SECTION" debounce)";                     OPT_debounce="${OPT_debounce:-120}"
	OPT_max_actions="$(uget "$SECTION" max_actions)";               OPT_max_actions="${OPT_max_actions:-5}"
	OPT_action_window="$(uget "$SECTION" action_window)";           OPT_action_window="${OPT_action_window:-3600}"
	OPT_protected="$(uget "$SECTION" protected_networks)"
	OPT_log="$(uget "$SECTION" log)";                               OPT_log="${OPT_log:-1}"
}

# Returns 0 if config is usable, 1 on any fatal problem (fail-safe -> idle).
validate_config() {
	valid_ifname "${OPT_interface:-}"   || { log crit "invalid or missing 'interface'"; return 1; }
	valid_uint "$OPT_interval" && [ "$OPT_interval" -ge 5 ] \
		|| { log crit "invalid 'interval' (must be integer >= 5)"; return 1; }
	valid_uint "$OPT_max_handshake_age" || { log crit "invalid 'max_handshake_age'"; return 1; }
	valid_uint "$OPT_failures" && [ "$OPT_failures" -ge 1 ] \
		|| { log crit "invalid 'failures' (must be integer >= 1)"; return 1; }
	valid_uint "$OPT_debounce"          || { log crit "invalid 'debounce'"; return 1; }
	valid_uint "$OPT_max_actions" && [ "$OPT_max_actions" -ge 1 ] && [ "$OPT_max_actions" -le 100 ] \
		|| { log crit "invalid 'max_actions' (must be 1-100 - the shared actions file keeps the last $ACTIONS_FILE_KEEP entries)"; return 1; }
	valid_uint "$OPT_action_window"     || { log crit "invalid 'action_window'"; return 1; }
	valid_uint "$OPT_ping_timeout" && [ "$OPT_ping_timeout" -ge 1 ] \
		|| { log crit "invalid 'ping_timeout' (>= 1)"; return 1; }

	case "$OPT_method" in
		handshake|ping|both) : ;;
		*) log crit "invalid 'method' (handshake|ping|both)"; return 1 ;;
	esac
	case "$OPT_method" in
		ping|both)
			valid_host "${OPT_ping_host:-}" \
				|| { log crit "method '$OPT_method' needs a valid 'ping_host'"; return 1; } ;;
	esac

	case "$OPT_action" in
		monitor) : ;;
		ifup)
			valid_ifname "${OPT_action_network:-}" \
				|| { log crit "action 'ifup' needs a valid 'action_network'"; return 1; }
			# Automatic alias protection compares against protected-pattern
			# networks' L3 devices; if every admin network was renamed away
			# from lan*/mgmt*/... it resolves nothing, so the heuristic is
			# silently inactive. Warn once (validate_config runs once per start);
			# do NOT refuse - a router legitimately may have no 'lan' section.
			if ! protected_device_exists; then
				log warn "no protected network (lan/mgmt/...) resolves an L3 device - automatic alias protection is inactive; verify 'protected_networks' covers your management network"
			fi
			if is_protected "$OPT_action_network"; then
				log crit "refusing: 'action_network=$OPT_action_network' is protected"; return 1
			fi ;;
		script)
			[ -n "${OPT_script:-}" ] || { log crit "action 'script' needs 'script'"; return 1; }
			# Confine to a package-owned directory. Absolute + executable is not
			# enough: an account delegated only this UCI ACL could point at /tmp
			# and get root execution. (IFWATCHDOG_SCRIPT_DIR is a test hook.)
			_sdir="${IFWATCHDOG_SCRIPT_DIR:-/usr/libexec/ifwatchdog.d}"
			case "$OPT_script" in
				"$_sdir"/*[!/]) : ;;
				*) log crit "'script' must live in $_sdir/"; return 1 ;;
			esac
			case "$OPT_script" in
				*/../*|*/..) log crit "'script' must not contain '..'"; return 1 ;;
			esac
			[ -f "$OPT_script" ] && [ -x "$OPT_script" ] \
				|| { log crit "'script' not an executable file: $OPT_script"; return 1; }
			# root-owned and not group/world-writable. validate_config takes no
			# args, so clobbering $@ via 'set --' here is safe.
			# Owned by the service user (root at runtime) and not writable by
			# group/other, so a non-root user cannot alter what root executes.
			# stat(1) is not in stock BusyBox, so use test -O + find -perm.
			# shellcheck disable=SC3013  # -O is supported by BusyBox ash test
			[ -O "$OPT_script" ] \
				|| { log crit "'script' must be owned by the service user (root)"; return 1; }
			if find "$OPT_script" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null | grep -q .; then
				log crit "'script' is group/world-writable"; return 1
			fi ;;
		*) log crit "invalid 'action' (monitor|ifup|script)"; return 1 ;;
	esac

	# When an action is configured, the debounce/window floors ensure the
	# breaker can actually trip and consecutive actions are spaced out.
	# 0 stays legal in monitor mode (useful for testing, cannot act).
	if [ "$OPT_action" != monitor ]; then
		[ "$OPT_debounce" -ge 30 ] \
			|| { log crit "'debounce' must be >= 30 when an action is configured"; return 1; }
		[ "$OPT_action_window" -ge 300 ] \
			|| { log crit "'action_window' must be >= 300 when an action is configured"; return 1; }
	fi
	return 0
}

# --- detection -------------------------------------------------------------

# Sets HS_AGE (seconds, may be empty) and HS_STATE (fresh|stale|unknown).
# 'unknown' = "cannot measure" (wg missing, not a wg iface, iface absent, peer
# never handshaked, clock stepped) and must NEVER drive an action.
handshake_probe() {
	HS_AGE=""
	HS_STATE=unknown
	command -v wg >/dev/null 2>&1 || return 0
	local out now latest
	out="$(wg show "$OPT_interface" latest-handshakes 2>/dev/null)" || return 0
	[ -n "$out" ] || return 0
	latest="$(printf '%s\n' "$out" | awk '{ if ($2+0 > m) m=$2 } END { print m+0 }')"
	[ "$latest" -gt 0 ] 2>/dev/null || return 0      # peer never handshaked yet
	now="$(date +%s)"
	HS_AGE=$(( now - latest ))
	if [ "$HS_AGE" -lt 0 ]; then                      # clock stepped backwards / future stamp
		HS_AGE=""
		return 0
	fi
	if [ "$HS_AGE" -le "$OPT_max_handshake_age" ]; then
		HS_STATE=fresh
	else
		HS_STATE=stale
	fi
	return 0
}

ping_ok() {
	ping -I "$OPT_interface" -c 1 -W "$OPT_ping_timeout" "$OPT_ping_host" >/dev/null 2>&1
}

# Sets HS_AGE/HS_STATE/PING_RES for status; returns 0 if the interface looks
# alive. With method=handshake, an unmeasurable handshake HOLDS (returns alive):
# never act under uncertainty. method=both still falls through to the ping.
is_alive() {
	# HOLDING=1 means "returned alive to SUPPRESS an action, not measured healthy".
	HOLDING=0
	HS_AGE=""
	HS_STATE=n/a
	PING_RES="n/a"
	case "$OPT_method" in
		handshake|both)
			handshake_probe
			[ "$HS_STATE" = fresh ] && { HS_UNKNOWN_LOGGED=0; return 0; } ;;
	esac
	case "$OPT_method" in
		ping|both)
			if ping_ok; then PING_RES="ok"; return 0; else PING_RES="fail"; fi
			return 1 ;;
	esac
	# method=handshake only, and the handshake was not fresh:
	if [ "$HS_STATE" = unknown ]; then
		if [ "${HS_UNKNOWN_LOGGED:-0}" = 0 ]; then
			log err "handshake unmeasurable on '$OPT_interface' - holding (no action)"
			HS_UNKNOWN_LOGGED=1
		else
			log info "handshake still unmeasurable on '$OPT_interface' - holding"
		fi
		HOLDING=1
		return 0
	fi
	HS_UNKNOWN_LOGGED=0
	return 1
}

# --- action (debounce + circuit breaker) -----------------------------------

# Monotonic seconds (routers have no RTC and may step wall clock at NTP sync).
now_mono() { awk '{ printf "%d\n", $1; exit }' /proc/uptime 2>/dev/null || echo 0; }

# Detected once at startup: BusyBox may be built without fractional sleep, so a
# 20x0.1s retry would otherwise become 20x1s and block the check loop for ~20s.
lock_tuning() {
	if sleep 0.1 2>/dev/null; then
		LOCK_SLEEP=0.1; LOCK_TRIES=20      # ~2s worst case
	else
		LOCK_SLEEP=1;   LOCK_TRIES=3       # ~3s worst case
	fi
}

# Cheap mutex around the shared actions file via an O_EXCL file create ("set -C"
# noclobber): O_EXCL is the POSIX atomic-create primitive and needs no cleanup
# semantics beyond rm. A lock older than 2 minutes cannot belong to a live holder
# (every path holds it for milliseconds), so break it - otherwise a SIGKILLed
# holder stops every section sharing this target forever. Do NOT tie the
# threshold to 'interval'.
lock_acquire() {
	local i=0
	while ! ( set -C; : > "$ACTIONS_FILE.lock" ) 2>/dev/null; do
		i=$((i+1))
		[ "$i" -ge "${LOCK_TRIES:-20}" ] && return 1
		if find "$ACTIONS_FILE.lock" -maxdepth 0 -mmin +2 2>/dev/null | grep -q .; then
			log err "breaking stale lock on $ACTIONS_FILE (holder gone)"
			rm -f "$ACTIONS_FILE.lock"
			continue
		fi
		sleep "${LOCK_SLEEP:-1}"
	done
	return 0
}
lock_release() { rm -f "$ACTIONS_FILE.lock"; }

# Last recorded action: monotonic seconds (debounce) / wall seconds (display).
# Actions file line format is "<mono> <wall>".
# awk's END block always fires (even on zero/blank input), so these always
# print a number - unlike a bare pattern-action, which prints nothing for an
# empty or blank-trailing-line file (e.g. right after prune_actions_file
# empties it), which would otherwise make a caller's '[ "$x" -gt 0 ]' error out.
last_action_mono() {
	[ -f "$ACTIONS_FILE" ] || { echo 0; return; }
	tail -n1 "$ACTIONS_FILE" 2>/dev/null | awk '{ v=$1+0 } END { print v+0 }'
}
last_action_wall() {
	[ -f "$ACTIONS_FILE" ] || { echo 0; return; }
	tail -n1 "$ACTIONS_FILE" 2>/dev/null | awk '{ v=$2+0 } END { print v+0 }'
}

# Caps the shared actions file at this many lines regardless of any single
# section's action_window - see prune_actions_file.
ACTIONS_FILE_KEEP=200

# Trims the shared actions file to the most recent ACTIONS_FILE_KEEP lines.
# Deliberately NOT keyed on the calling section's own action_window: two
# sections sharing a target can have different windows (e.g. 300s vs 3600s),
# and pruning by the shorter one would silently erase history the
# longer-window section still needs to count correctly. The caller holds the
# lock.
prune_actions_file() {
	[ -f "$ACTIONS_FILE" ] || return 0
	awk -v keep="$ACTIONS_FILE_KEEP" \
		'{ line[NR]=$0 } END { s=(NR>keep)?NR-keep+1:1; for (i=s;i<=NR;i++) print line[i] }' \
		"$ACTIONS_FILE" > "$ACTIONS_FILE.tmp" 2>/dev/null && mv "$ACTIONS_FILE.tmp" "$ACTIONS_FILE"
}

# Counts entries within the last OPT_action_window seconds (by monotonic
# time). Pure read - never modifies the file (pruning is prune_actions_file's
# job, run once per take_action() regardless of which section is calling).
recent_action_count() {
	local now_m="$1" cut
	cut=$(( now_m - OPT_action_window ))
	[ -f "$ACTIONS_FILE" ] || { echo 0; return; }
	awk -v c="$cut" '$1+0 >= c { n++ } END { print n+0 }' "$ACTIONS_FILE" 2>/dev/null
}

# Performs the configured action, honouring debounce + circuit breaker on
# monotonic time. The breaker file is keyed on the target network (see main()),
# so sections sharing a target share one counter; the prune+count+append is
# serialised by a lock. 'monitor' is handled by the caller and never reaches here.
take_action() {
	local now_m last_m cnt
	# ACTION_OUTCOME is a global set for the loop: acted|debounced|breaker|lockbusy
	ACTION_OUTCOME=acted
	now_m="$(now_mono)"
	last_m="$(last_action_mono)"
	# Fast path: avoid taking the lock when we are obviously debounced.
	if [ "$last_m" -gt 0 ] && [ $(( now_m - last_m )) -lt "$OPT_debounce" ]; then
		log info "debounce: $(( now_m - last_m ))s < ${OPT_debounce}s - skip"
		ACTION_OUTCOME=debounced
		return 0
	fi
	lock_acquire || { log err "action lock busy - refusing this cycle"; ACTION_OUTCOME=lockbusy; return 0; }
	# Authoritative re-check: a section sharing this target may have acted between
	# the fast path above and the lock being granted (preserves debounce spacing).
	now_m="$(now_mono)"
	last_m="$(last_action_mono)"
	if [ "$last_m" -gt 0 ] && [ $(( now_m - last_m )) -lt "$OPT_debounce" ]; then
		lock_release
		log info "debounce (under lock): $(( now_m - last_m ))s < ${OPT_debounce}s - skip"
		ACTION_OUTCOME=debounced
		return 0
	fi
	prune_actions_file
	cnt="$(recent_action_count "$now_m")"
	if [ "$cnt" -ge "$OPT_max_actions" ]; then
		# Rate-limit: err once on entry to the tripped state, info thereafter.
		if [ "${BREAKER_LOGGED:-0}" = 0 ]; then
			log err "circuit breaker: ${cnt} actions in ${OPT_action_window}s >= ${OPT_max_actions} - refusing"
			BREAKER_LOGGED=1
		else
			log info "circuit breaker still tripped (${cnt}/${OPT_max_actions}) - refusing"
		fi
		lock_release
		ACTION_OUTCOME=breaker
		return 0
	fi
	BREAKER_LOGGED=0
	echo "$now_m $(date +%s)" >> "$ACTIONS_FILE"
	lock_release
	case "$OPT_action" in
		ifup)
			log warn "restarting network '$OPT_action_network' (ifup)"
			ifup "$OPT_action_network" \
				|| log warn "ifup '$OPT_action_network' returned non-zero (action may have failed)" ;;
		script)
			log warn "running action script: $OPT_script"
			"$OPT_script" "$SECTION" "$OPT_interface" "${OPT_action_network:-}" </dev/null ;;
	esac
}

# --- status ----------------------------------------------------------------

# Echo $1 if it is a safe token, else '?'. write_status runs on the invalid and
# disabled paths too, where fields are NOT yet validated, so keep any crafted
# UCI value out of the JSON the GUI parses.
json_str() {
	case "${1:-}" in
		''|*[!A-Za-z0-9_.:/-]*) printf '?' ;;
		*) printf '%s' "$1" ;;
	esac
}

# True if the shared breaker for this target is CURRENTLY tripped (>=
# max_actions within the window), independent of whether this cycle itself
# attempted an action. Feeds the GUI's sticky 'breaker_tripped' indicator, so
# a row does not look falsely healthy between down-cycles while the breaker
# is still engaged. Fails safe (false) on any missing/invalid input.
breaker_is_tripped() {
	case "${OPT_action:-monitor}" in monitor|'') return 1 ;; esac
	valid_uint "${OPT_max_actions:-}" || return 1
	local cnt
	cnt="$(recent_action_count "$(now_mono)" 2>/dev/null)"
	valid_uint "${cnt:-}" || return 1
	[ "$cnt" -ge "$OPT_max_actions" ]
}

write_status() {
	local state="$1" f tmp age iv bt
	mkdir -p "$STATE_DIR" 2>/dev/null
	f="$STATE_DIR/$SECTION.json"
	tmp="$f.$$"
	case "${HS_AGE:-}" in ''|*[!0-9]*) age=null ;; *) age="$HS_AGE" ;; esac
	# interval drives the GUI staleness threshold; unvalidated on the invalid path.
	case "${OPT_interval:-}" in ''|*[!0-9]*) iv=null ;; *) iv="$OPT_interval" ;; esac
	bt=false; breaker_is_tripped && bt=true
	cat > "$tmp" <<-JSON
	{
	  "section": "$(json_str "$SECTION")",
	  "interface": "$(json_str "${OPT_interface:-}")",
	  "method": "$(json_str "${OPT_method:-}")",
	  "action": "$(json_str "${OPT_action:-}")",
	  "state": "$(json_str "$state")",
	  "handshake_age": $age,
	  "handshake_state": "$(json_str "${HS_STATE:-n/a}")",
	  "ping": "$(json_str "${PING_RES:-n/a}")",
	  "fail_count": ${FAIL_COUNT:-0},
	  "last_action": $(last_action_wall),
	  "interval": $iv,
	  "breaker_tripped": $bt,
	  "updated": $(date +%s),
	  "updated_mono": $(now_mono)
	}
	JSON
	chmod 0600 "$tmp" 2>/dev/null
	mv "$tmp" "$f"
}

# --- main loop -------------------------------------------------------------

safe_idle() { while :; do sleep 3600 & wait "$!"; done; }

# Clean shutdown (procd sends SIGTERM on stop/restart): make it observable and
# drop the stale status file so the GUI no longer lists this instance.
cleanup() {
	log info "stopping (interface=${OPT_interface:-?})"
	rm -f "$STATE_DIR/$SECTION.json" 2>/dev/null
	[ -n "${ACTIONS_FILE:-}" ] && rm -f "${ACTIONS_FILE}.lock"
	exit 0
}

main() {
	SECTION="${1:-}"
	# UCI section names are [A-Za-z0-9_]; validate so it is safe to interpolate
	# into a path and into the status JSON (write_status assumes this).
	case "$SECTION" in
		''|*[!A-Za-z0-9_]*) echo "usage: $0 <section> (invalid section name)" >&2; exit 2 ;;
	esac
	mkdir -p "$STATE_DIR" 2>/dev/null

	load_config
	# Only a validated name may become part of a path (validate_config still
	# decides whether the instance runs); guards action_network='../../x'.
	valid_ifname "${OPT_action_network:-}" || OPT_action_network=""
	# Breaker/debounce state is keyed on the TARGET network, so multiple sections
	# watching the same tunnel share one counter (not 2x the cap).
	ACTIONS_FILE="$STATE_DIR/act-${OPT_action_network:-$SECTION}.actions"
	trap cleanup INT TERM
	lock_tuning
	HS_AGE=""; HS_STATE=n/a; PING_RES="n/a"; FAIL_COUNT=0; HS_UNKNOWN_LOGGED=0; BREAKER_LOGGED=0; HOLDING=0

	# Fail-safe invariant: only SIGTERM/SIGINT may exit. Every "cannot work"
	# condition writes a status file and idles, so the GUI still lists it.
	case "${OPT_enabled:-0}" in
		1|on|true|yes|enabled) : ;;
		*)
			log info "section disabled - idle"
			write_status disabled
			safe_idle ;;
	esac

	if ! validate_config; then
		log crit "invalid configuration - safe idle (no action taken)"
		write_status invalid
		safe_idle
	fi

	# Degrade gracefully if wg is unavailable.
	case "$OPT_method" in
		handshake|both)
			if ! command -v wg >/dev/null 2>&1; then
				if [ "$OPT_method" = handshake ]; then
					log err "'wg' not found and method=handshake - safe idle"
					write_status invalid; safe_idle
				fi
				log warn "'wg' not found - degrading method 'both' -> 'ping'"
				OPT_method=ping
				valid_host "${OPT_ping_host:-}" \
					|| { log crit "no valid 'ping_host' after degrade - safe idle"; write_status invalid; safe_idle; }
			fi ;;
	esac

	log info "started: iface=$OPT_interface method=$OPT_method action=$OPT_action interval=${OPT_interval}s"

	while :; do
		if is_alive; then
			if [ "${HOLDING:-0}" = 1 ]; then
				# Not measured healthy: do not claim recovery, keep the counter.
				write_status holding
			else
				[ "$FAIL_COUNT" -ne 0 ] && log info "recovered (reset fail_count from $FAIL_COUNT)"
				FAIL_COUNT=0
				write_status alive
			fi
		else
			FAIL_COUNT=$(( FAIL_COUNT + 1 ))
			log info "down signal ${FAIL_COUNT}/${OPT_failures} (hs_age=${HS_AGE:-NA} ping=${PING_RES})"
			if [ "$FAIL_COUNT" -ge "$OPT_failures" ]; then
				if [ "$OPT_action" = monitor ]; then
					log warn "MONITOR: threshold reached on '$OPT_interface' - would act (no-op)"
					write_status monitor
				else
					ACTION_OUTCOME=acted
					take_action
					write_status "$ACTION_OUTCOME"
				fi
				FAIL_COUNT=0
			else
				write_status down
			fi
		fi
		sleep "$OPT_interval" &
		wait "$!"
	done
}

if [ "${IFWATCHDOG_TEST:-0}" != "1" ]; then
	main "$@"
fi
