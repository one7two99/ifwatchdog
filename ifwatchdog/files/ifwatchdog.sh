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
DEFAULT_PROTECTED="lan loopback"

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
		''|*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	[ "${#n}" -le 15 ] || return 1   # Linux IFNAMSIZ - 1
	return 0
}

valid_host() {
	# IPv4 / IPv6 / hostname characters only.
	case "${1:-}" in
		''|*[!A-Za-z0-9.:-]*) return 1 ;;
		*) return 0 ;;
	esac
}

is_protected() {
	local n="$1" p
	for p in $DEFAULT_PROTECTED ${OPT_protected:-}; do
		[ "$n" = "$p" ] && return 0
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
	valid_uint "$OPT_max_actions" && [ "$OPT_max_actions" -ge 1 ] \
		|| { log crit "invalid 'max_actions' (>= 1)"; return 1; }
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
			if is_protected "$OPT_action_network"; then
				log crit "refusing: 'action_network=$OPT_action_network' is protected"; return 1
			fi ;;
		script)
			[ -n "${OPT_script:-}" ] || { log crit "action 'script' needs 'script'"; return 1; }
			case "$OPT_script" in
				/*) : ;;
				*) log crit "'script' must be an absolute path"; return 1 ;;
			esac
			[ -x "$OPT_script" ] || { log crit "'script' not executable: $OPT_script"; return 1; } ;;
		*) log crit "invalid 'action' (monitor|ifup|script)"; return 1 ;;
	esac
	return 0
}

# --- detection -------------------------------------------------------------

# Echoes handshake age in seconds, or nothing if it cannot be determined.
handshake_age() {
	command -v wg >/dev/null 2>&1 || return 0
	local now latest
	now="$(date +%s)"
	latest="$(wg show "$OPT_interface" latest-handshakes 2>/dev/null \
		| awk '{ if ($2+0 > m) m=$2 } END { print m+0 }')"
	[ -n "$latest" ] && [ "$latest" -gt 0 ] 2>/dev/null || return 0
	echo $(( now - latest ))
}

ping_ok() {
	ping -I "$OPT_interface" -c 1 -W "$OPT_ping_timeout" "$OPT_ping_host" >/dev/null 2>&1
}

# Sets HS_AGE and PING_RES for status; returns 0 if the interface looks alive.
is_alive() {
	HS_AGE=""
	PING_RES="n/a"
	case "$OPT_method" in
		handshake|both)
			HS_AGE="$(handshake_age)"
			if [ -n "$HS_AGE" ] && [ "$HS_AGE" -le "$OPT_max_handshake_age" ]; then
				return 0
			fi ;;
	esac
	case "$OPT_method" in
		ping|both)
			if ping_ok; then PING_RES="ok"; return 0; else PING_RES="fail"; fi ;;
	esac
	return 1
}

# --- action (debounce + circuit breaker) -----------------------------------

last_action_time() {
	[ -f "$ACTIONS_FILE" ] || { echo 0; return; }
	tail -n1 "$ACTIONS_FILE" 2>/dev/null | awk '{ print $1+0 }'
}

# Prunes entries older than the window and echoes how many remain.
recent_action_count() {
	local now="$1" cut
	cut=$(( now - OPT_action_window ))
	[ -f "$ACTIONS_FILE" ] || { echo 0; return; }
	awk -v c="$cut" '$1+0 >= c { print }' "$ACTIONS_FILE" > "$ACTIONS_FILE.tmp" 2>/dev/null \
		&& mv "$ACTIONS_FILE.tmp" "$ACTIONS_FILE"
	awk 'END { print NR }' "$ACTIONS_FILE" 2>/dev/null || echo 0
}

# Performs the configured action, honouring debounce + circuit breaker.
# 'monitor' is handled by the caller and never reaches here.
take_action() {
	local now last cnt
	# ACTION_OUTCOME is a global set for the loop: acted|debounced|breaker
	ACTION_OUTCOME=acted
	now="$(date +%s)"
	last="$(last_action_time)"
	if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "$OPT_debounce" ]; then
		log info "debounce: $(( now - last ))s < ${OPT_debounce}s - skip"
		ACTION_OUTCOME=debounced
		return 0
	fi
	cnt="$(recent_action_count "$now")"
	if [ "$cnt" -ge "$OPT_max_actions" ]; then
		log err "circuit breaker: ${cnt} actions in ${OPT_action_window}s >= ${OPT_max_actions} - refusing"
		ACTION_OUTCOME=breaker
		return 0
	fi
	case "$OPT_action" in
		ifup)
			log warn "restarting network '$OPT_action_network' (ifup)"
			ifup "$OPT_action_network" ;;
		script)
			log warn "running action script: $OPT_script"
			"$OPT_script" "$SECTION" "$OPT_interface" "${OPT_action_network:-}" </dev/null ;;
	esac
	echo "$now" >> "$ACTIONS_FILE"
}

# --- status ----------------------------------------------------------------

write_status() {
	local state="$1" f tmp
	mkdir -p "$STATE_DIR" 2>/dev/null
	f="$STATE_DIR/$SECTION.json"
	tmp="$f.$$"
	# All embedded values are validated (ifname/method/action) or numeric.
	cat > "$tmp" <<-JSON
	{
	  "section": "$SECTION",
	  "interface": "$OPT_interface",
	  "method": "$OPT_method",
	  "action": "$OPT_action",
	  "state": "$state",
	  "handshake_age": ${HS_AGE:-null},
	  "ping": "$PING_RES",
	  "fail_count": ${FAIL_COUNT:-0},
	  "last_action": $(last_action_time),
	  "updated": $(date +%s)
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
	exit 0
}

main() {
	SECTION="${1:-}"
	[ -n "$SECTION" ] || { echo "usage: $0 <section>" >&2; exit 2; }
	ACTIONS_FILE="$STATE_DIR/$SECTION.actions"
	mkdir -p "$STATE_DIR" 2>/dev/null

	load_config
	trap cleanup INT TERM
	if [ "${OPT_enabled:-0}" != "1" ]; then
		log info "section disabled - exiting"
		exit 0
	fi
	if ! validate_config; then
		log crit "invalid configuration - safe idle (no action taken)"
		safe_idle
	fi

	# Degrade gracefully if wg is unavailable.
	case "$OPT_method" in
		handshake|both)
			if ! command -v wg >/dev/null 2>&1; then
				if [ "$OPT_method" = handshake ]; then
					log err "'wg' not found and method=handshake - safe idle"; safe_idle
				fi
				log warn "'wg' not found - degrading method 'both' -> 'ping'"
				OPT_method=ping
				valid_host "${OPT_ping_host:-}" \
					|| { log crit "no valid 'ping_host' after degrade - safe idle"; safe_idle; }
			fi ;;
	esac

	FAIL_COUNT=0
	log info "started: iface=$OPT_interface method=$OPT_method action=$OPT_action interval=${OPT_interval}s"

	while :; do
		if is_alive; then
			[ "$FAIL_COUNT" -ne 0 ] && log info "recovered (reset fail_count from $FAIL_COUNT)"
			FAIL_COUNT=0
			write_status alive
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
