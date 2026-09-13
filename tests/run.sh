#!/bin/sh
# ifwatchdog - unit/mock tests. Runs without OpenWrt.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Stubs wg/ping/ifup/uci/logger, sources the check script with IFWATCHDOG_TEST=1
# and asserts the security-relevant decision logic.
#
# The OPT_* variables below are consumed by the *sourced* script; shellcheck
# cannot see across the '. "$SCRIPT"' boundary, hence the file-level disables.
# shellcheck disable=SC2034  # OPT_*/HS_AGE/PING_RES/FAIL_COUNT used by sourced script
# shellcheck disable=SC2209  # 'both'/'monitor'/'ifup' etc. are string literals

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../ifwatchdog/files/ifwatchdog.sh"
[ -f "$SCRIPT" ] || { echo "cannot find $SCRIPT"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/bin"; mkdir -p "$STUBS"
export IFWATCHDOG_STATE_DIR="$TMP/state"
export IFUP_LOG="$TMP/ifup.log"; : > "$IFUP_LOG"

# --- stubs (env-driven) ----------------------------------------------------
cat > "$STUBS/uci" <<'EOF'
#!/bin/sh
# understands:
#   uci -q get ifwatchdog.<sec>.<opt>   -> CFG_<opt>
#   uci -q get network.<name>.device    -> CFG_NET_<name>
key=$3
case "$key" in
	network.*.device)
		name=${key#network.}; name=${name%.device}
		eval "v=\${CFG_NET_${name}:-}" ;;
	*)
		eval "v=\${CFG_${key##*.}:-}" ;;
esac
[ -n "${v:-}" ] && printf '%s\n' "$v"
exit 0
EOF
cat > "$STUBS/wg" <<'EOF'
#!/bin/sh
# WG_FAIL set -> behave like 'wg show <missing-iface>' (non-zero exit).
[ -n "${WG_FAIL:-}" ] && exit 1
printf 'PUBKEYxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\t%s\n' "${WG_HS:-0}"
EOF
cat > "$STUBS/ping" <<'EOF'
#!/bin/sh
[ "${PING_RESULT:-fail}" = ok ]
EOF
cat > "$STUBS/ifup" <<'EOF'
#!/bin/sh
echo "ifup $*" >> "${IFUP_LOG:-/dev/null}"
EOF
cat > "$STUBS/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBS"/*
PATH="$STUBS:$PATH"; export PATH

# --- source script under test ---------------------------------------------
export IFWATCHDOG_TEST=1
# shellcheck disable=SC1090
. "$SCRIPT"

# --- harness ---------------------------------------------------------------
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
t_true(){ d="$1"; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
t_false(){ d="$1"; shift; if "$@"; then no "$d"; else ok "$d"; fi; }
t_eq(){ if [ "$2" = "$1" ]; then ok "$3"; else no "$3 (got '$2', want '$1')"; fi; }
t_ge(){ if [ "$2" -ge "$1" ]; then ok "$3"; else no "$3 (got '$2', want >= '$1')"; fi; }

set_base_config(){
	SECTION=test; OPT_enabled=1; OPT_interface=wg0; OPT_method=both
	OPT_ping_host=1.1.1.1; OPT_ping_timeout=3; OPT_interval=60
	OPT_max_handshake_age=150; OPT_failures=2; OPT_action=monitor
	OPT_action_network=''; OPT_script=''; OPT_debounce=120
	OPT_max_actions=5; OPT_action_window=3600; OPT_protected=''; OPT_log=1
	HS_AGE=''; PING_RES='n/a'; FAIL_COUNT=0
	ACTIONS_FILE="$TMP/state/$SECTION.actions"
	mkdir -p "$TMP/state"; rm -f "$ACTIONS_FILE"
}

echo "# validators"
t_true  "valid_uint 5"                 valid_uint 5
t_false "valid_uint empty"             valid_uint ""
t_false "valid_uint 5a"                valid_uint 5a
t_false "valid_uint -1"                valid_uint -1
t_true  "valid_ifname wg0"             valid_ifname wg0
t_true  "valid_ifname br-lan"          valid_ifname br-lan
t_false "valid_ifname injection ;"     valid_ifname "wg0;reboot"
t_false "valid_ifname space"           valid_ifname "wg 0"
t_false "valid_ifname empty"           valid_ifname ""
t_false "valid_ifname >15 chars"       valid_ifname "abcdefghijklmnop"
t_true  "valid_host ipv4"              valid_host 1.1.1.1
t_true  "valid_host hostname"          valid_host example.com
t_false "valid_host injection"         valid_host "a;rm -rf /"
t_false "valid_host empty"             valid_host ""
t_false "valid_ifname leading dash"    valid_ifname "-a"
t_false "valid_ifname lone dash"       valid_ifname "-"
t_false "valid_host leading dash"      valid_host "-I"

echo "# denylist"
set_base_config
t_true  "is_protected lan"             is_protected lan
t_true  "is_protected lan2"            is_protected lan2
t_true  "is_protected mgmt"            is_protected mgmt
t_true  "is_protected management"      is_protected management
t_true  "is_protected admin"           is_protected admin
t_true  "is_protected loopback"        is_protected loopback
t_false "is_protected wg0"             is_protected wg0
t_false "is_protected wan (allowed)"   is_protected wan
OPT_protected="corp*"
t_true  "is_protected extra glob"      is_protected corpnet
# The denylist must be deterministic and never depend on the process CWD.
# 'set -f' makes a '*' entry a literal match-all glob instead of a CWD filename
# expansion. Verify CWD-independence (the actual defect), and that '*' protects
# all (safe over-protection, not a hole).
OPT_protected='*'
r1=$( (cd / && is_protected wg0) && echo P || echo N )
r2=$( (cd "$TMP" && is_protected wg0) && echo P || echo N )
t_eq "$r1" "$r2" "denylist result is CWD-independent (set -f)"
t_eq P "$r1" "glob '*' protects all (safe over-protection)"
OPT_protected=''
export CFG_NET_lanmgmt=br-lan CFG_NET_lan=br-lan
t_true  "is_protected alias on br-lan" is_protected lanmgmt
unset CFG_NET_lanmgmt CFG_NET_lan

echo "# validate_config"
set_base_config; t_true  "good both config"           validate_config
set_base_config; OPT_interface="wg0;reboot";              t_false "reject bad interface" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=lan; t_false "reject ifup->lan (protected)" validate_config
set_base_config; OPT_action=ifup; OPT_action_network='';  t_false "reject ifup w/o network" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=wg0; t_true  "accept ifup->wg0" validate_config
set_base_config; OPT_method=ping; OPT_ping_host="a;b";    t_false "reject ping bad host" validate_config
set_base_config; OPT_action=script; OPT_script="rel/x";   t_false "reject relative script path" validate_config
set_base_config; OPT_interval=2;                          t_false "reject interval < 5" validate_config
set_base_config; OPT_action=ifup; OPT_action_network='-a';  t_false "reject ifup->'-a' (option injection)" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=mgmt;  t_false "reject ifup->mgmt (denylist)" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=lan2;  t_false "reject ifup->lan2 (denylist)" validate_config
set_base_config; OPT_action=script; OPT_script="/tmp/x";    t_false "reject script outside ifwatchdog.d" validate_config
set_base_config; OPT_action=script; OPT_script="/usr/libexec/ifwatchdog.d/../../../tmp/x"; t_false "reject script with .. traversal" validate_config
# test -O checks ownership by the *effective* user, so this runs unprivileged:
# the file is owned by the test user (= root on the device at runtime).
mkdir -p "$TMP/sdir"; printf '#!/bin/sh\n' > "$TMP/sdir/ok.sh"; chmod 0755 "$TMP/sdir/ok.sh"
IFWATCHDOG_SCRIPT_DIR="$TMP/sdir"
set_base_config; OPT_action=script; OPT_script="$TMP/sdir/ok.sh"
t_true  "accept owned non-writable script in dir" validate_config
chmod 0777 "$TMP/sdir/ok.sh"
set_base_config; OPT_action=script; OPT_script="$TMP/sdir/ok.sh"
t_false "reject world-writable script in dir"      validate_config
chmod 0755 "$TMP/sdir/ok.sh"
unset IFWATCHDOG_SCRIPT_DIR

echo "# handshake tri-state"
set_base_config; OPT_method=handshake
now=$(date +%s)
WG_HS=$((now-10)); export WG_HS
handshake_probe; t_eq fresh "$HS_STATE" "fresh handshake -> HS_STATE=fresh"
if [ -n "$HS_AGE" ] && [ "$HS_AGE" -ge 9 ] && [ "$HS_AGE" -le 13 ]; then ok "HS_AGE ~10s"; else no "HS_AGE ~10s (got '$HS_AGE')"; fi
WG_HS=$((now-500)); export WG_HS
handshake_probe; t_eq stale "$HS_STATE" "stale handshake -> HS_STATE=stale"
WG_HS=0; export WG_HS
handshake_probe; t_eq unknown "$HS_STATE" "no handshake yet -> HS_STATE=unknown"
WG_HS=$((now+3600)); export WG_HS
handshake_probe; t_eq unknown "$HS_STATE" "future timestamp -> HS_STATE=unknown"
WG_FAIL=1; export WG_FAIL
handshake_probe; t_eq unknown "$HS_STATE" "wg error (iface not found) -> HS_STATE=unknown"
unset WG_FAIL

echo "# no action under uncertainty"
set_base_config; OPT_method=handshake; OPT_action=ifup; OPT_action_network=wg0
WG_HS=0; export WG_HS
: > "$IFUP_LOG"
t_true "unknown handshake holds (alive)" is_alive
n=0; while [ "$n" -lt 5 ]; do is_alive >/dev/null; n=$((n+1)); done
t_eq 0 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "unmeasurable handshake never triggers ifup"

echo "# main() entry behaviour (no respawn storm on any 'enabled' spelling)"
export CFG_interface=wg0 CFG_action=monitor CFG_method=ping CFG_ping_host=1.1.1.1
export IFWATCHDOG_STATE_DIR_SAVE="$IFWATCHDOG_STATE_DIR"
export IFWATCHDOG_STATE_DIR="$TMP/state-main"
for v in 1 on true yes enabled 0 '' bogus; do
	export CFG_enabled="$v"
	if command -v timeout >/dev/null 2>&1; then
		IFWATCHDOG_TEST=0 timeout 2 sh "$SCRIPT" test >/dev/null 2>&1; rc=$?
	else
		( IFWATCHDOG_TEST=0 sh "$SCRIPT" test >/dev/null 2>&1 ) & p=$!
		sleep 2
		if kill -0 "$p" 2>/dev/null; then kill -TERM "$p" 2>/dev/null; rc=124; else wait "$p"; rc=$?; fi
	fi
	t_eq 124 "$rc" "enabled='$v' does not exit on its own (rc=124=still running)"
done
unset CFG_enabled CFG_interface CFG_action CFG_method CFG_ping_host
export IFWATCHDOG_STATE_DIR="$IFWATCHDOG_STATE_DIR_SAVE"; unset IFWATCHDOG_STATE_DIR_SAVE

echo "# is_alive (method=both)"
set_base_config; OPT_method=both
WG_HS=$((now-10)); export WG_HS
t_true  "both: fresh handshake -> alive"      is_alive
WG_HS=$((now-500)); export WG_HS; PING_RESULT=ok; export PING_RESULT
t_true  "both: stale hs + ping ok -> alive"   is_alive
PING_RESULT=fail; export PING_RESULT
t_false "both: stale hs + ping fail -> down"  is_alive

echo "# is_alive (method=handshake / ping)"
set_base_config; OPT_method=handshake
WG_HS=$((now-10)); export WG_HS;  t_true  "hs-only: fresh -> alive"  is_alive
WG_HS=$((now-500)); export WG_HS; t_false "hs-only: stale -> down"   is_alive
set_base_config; OPT_method=ping
PING_RESULT=ok;   export PING_RESULT; t_true  "ping-only: ok -> alive" is_alive
PING_RESULT=fail; export PING_RESULT; t_false "ping-only: fail -> down" is_alive

echo "# take_action + debounce + circuit breaker"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=120
: > "$IFUP_LOG"
take_action
t_eq 1 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "ifup called once"
t_eq acted "$ACTION_OUTCOME" "outcome=acted on real action"
if [ -f "$ACTIONS_FILE" ]; then
	t_ge 1 "$(wc -l < "$ACTIONS_FILE" | tr -d ' ')" "action timestamp recorded"
else
	no "action timestamp recorded (no file)"
fi
take_action   # within debounce -> no new ifup
t_eq 1 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "debounce blocks 2nd action"
t_eq debounced "$ACTION_OUTCOME" "outcome=debounced when skipped"

set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=0; OPT_max_actions=5
: > "$IFUP_LOG"
nowb=$(date +%s)
n=0; while [ "$n" -lt 5 ]; do echo "$nowb" >> "$ACTIONS_FILE"; n=$((n+1)); done
take_action
t_eq 0 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "circuit breaker refuses at max_actions"
t_eq breaker "$ACTION_OUTCOME" "outcome=breaker when refused"

echo "# write_status JSON"
set_base_config; OPT_action=monitor; HS_AGE=42; PING_RES=ok; FAIL_COUNT=1
write_status alive
SF="$TMP/state/$SECTION.json"
if [ -f "$SF" ]; then
	if grep -q '"state": "alive"' "$SF" && grep -q '"handshake_age": 42' "$SF"; then
		ok "status JSON fields present"
	else
		no "status JSON fields present"
	fi
	if command -v python3 >/dev/null 2>&1; then
		if python3 -m json.tool "$SF" >/dev/null 2>&1; then ok "status JSON parses"; else no "status JSON parses"; fi
	else
		ok "(python3 absent: JSON parse skipped)"
	fi
else
	no "status JSON written"
fi

echo
echo "==================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
