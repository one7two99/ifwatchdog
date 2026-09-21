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
#   uci -q get network.<name>.ifname    -> CFG_NET_IFNAME_<name>
#   uci -q show network                 -> one 'network.<name>=interface' line
#                                          per CFG_NET_*/CFG_L3_* name currently exported
if [ "$2" = show ]; then
	[ "$3" = network ] || exit 0
	{ env | sed -n 's/^CFG_NET_\([A-Za-z0-9_]*\)=.*/\1/p'
	  env | sed -n 's/^CFG_L3_\([A-Za-z0-9_]*\)=.*/\1/p'; } \
		| sort -u | sed 's/^/network./; s/$/=interface/'
	exit 0
fi
key=$3
case "$key" in
	network.*.device)
		name=${key#network.}; name=${name%.device}
		eval "v=\${CFG_NET_${name}:-}" ;;
	network.*.ifname)
		name=${key#network.}; name=${name%.ifname}
		eval "v=\${CFG_NET_IFNAME_${name}:-}" ;;
	*)
		eval "v=\${CFG_${key##*.}:-}" ;;
esac
[ -n "${v:-}" ] && printf '%s\n' "$v"
exit 0
EOF
cat > "$STUBS/ifstatus" <<'EOF'
#!/bin/sh
# understands: ifstatus <name> -> {"l3_device":"<val>"} if CFG_L3_<name> is set, else {}
# (simulates the live netifd view, distinct from the static uci 'device' option)
n="$1"
eval "v=\${CFG_L3_${n}:-}"
if [ -n "$v" ]; then printf '{"l3_device":"%s"}\n' "$v"; else printf '{}\n'; fi
exit 0
EOF
cat > "$STUBS/jsonfilter" <<'EOF'
#!/bin/sh
# fake: only supports the '-e @.l3_device' usage this script makes
sed -n 's/.*"l3_device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
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
[ -z "${IFUP_FAIL:-}" ]   # IFUP_FAIL set -> exit non-zero
EOF
cat > "$STUBS/logger" <<'EOF'
#!/bin/sh
# LOGCAP set -> append the message for assertions; otherwise a no-op like syslog.
[ -n "${LOGCAP:-}" ] && printf '%s\n' "$*" >> "$LOGCAP"
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
export CFG_NET_officenet=br-lan CFG_NET_lan=br-lan
t_true  "is_protected alias sharing lan's device" is_protected officenet
unset CFG_NET_officenet CFG_NET_lan
# F1: alias protection must generalise to ANY protected-pattern network's
# device, not just 'lan' - a renamed/second management network protects its
# aliases too.
export CFG_NET_mgmt0=br-mgmt CFG_NET_opsaccess=br-mgmt
t_true  "is_protected alias sharing mgmt0's device (not just lan)" is_protected opsaccess
unset CFG_NET_mgmt0 CFG_NET_opsaccess
t_false "is_protected wg0 still allowed after F1 generalisation" is_protected wg0
# F1: a static 'option device' can be a UCI cross-reference ('@lan') that a
# plain 'uci get network.$n.device' cannot resolve; ifstatus (live netifd
# view) must be consulted first.
export CFG_NET_lan=br-lan CFG_NET_weirdalias='@lan' CFG_L3_weirdalias=br-lan
t_true  "is_protected alias via '@lan' uci reference (resolved through ifstatus)" is_protected weirdalias
unset CFG_NET_lan CFG_NET_weirdalias CFG_L3_weirdalias

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
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=0;       t_false "reject debounce=0 with action" validate_config
set_base_config; OPT_action=monitor; OPT_debounce=0;                            t_true  "accept debounce=0 in monitor" validate_config

echo "# 5D.3: automatic LAN-alias protection warns (never rejects) when no 'lan' section resolves"
LOGCAP="$TMP/logcap"; export LOGCAP
set_base_config; OPT_action=ifup; OPT_action_network=wg0
unset CFG_NET_lan                         # LAN renamed/absent -> heuristic inactive
: > "$LOGCAP"
t_true  "no lan: valid action_network still accepted (warning is not a rejection)" validate_config
t_true  "no lan: 'alias protection is inactive' warning is logged" grep -q "alias protection is inactive" "$LOGCAP"
export CFG_NET_lan=br-lan                  # LAN resolves -> heuristic active, no warning
: > "$LOGCAP"
t_true  "lan present: valid action_network accepted" validate_config
t_false "lan present: no alias-protection warning" grep -q "alias protection is inactive" "$LOGCAP"
unset CFG_NET_lan; unset LOGCAP
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_action_window=60; t_false "reject action_window<300 with action" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_max_actions=101;  t_false "reject max_actions>100 (F2)" validate_config
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_max_actions=100;  t_true  "accept max_actions=100 (F2)" validate_config

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

echo "# holding is not alive: an unmeasurable handshake suppresses an action without faking health (5A.1)"
set_base_config; OPT_method=handshake; OPT_interface=wg0
WG_HS=0; export WG_HS                       # peer never handshaked -> unknown
t_true  "hs-only: unknown handshake returns alive (holds, no action)" is_alive
t_eq 1 "$HOLDING"       "hs-only: HOLDING=1 marks a hold, not measured health"
t_eq unknown "$HS_STATE" "hs-only: HS_STATE is unknown while holding"
WG_HS=$((now-10)); export WG_HS             # fresh handshake -> measured health
t_true  "hs-only: fresh handshake returns alive" is_alive
t_eq 0 "$HOLDING"       "hs-only: fresh handshake is measured health (HOLDING=0)"

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

set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=5; OPT_action_window=300
: > "$IFUP_LOG"
nowm=$(now_mono); old=$(( nowm - 40 ))   # 40s ago: past debounce, inside window
n=0; while [ "$n" -lt 5 ]; do echo "$old $(date +%s)" >> "$ACTIONS_FILE"; n=$((n+1)); done
take_action
t_eq 0 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "circuit breaker refuses at max_actions"
t_eq breaker "$ACTION_OUTCOME" "outcome=breaker when refused"

echo "# monotonic guards survive an NTP step (M1)"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=120
nowm=$(now_mono); echo "$nowm $(( $(date +%s) + 999999 ))" > "$ACTIONS_FILE"
: > "$IFUP_LOG"; take_action
t_eq debounced "$ACTION_OUTCOME" "debounce uses monotonic time (immune to future wall clock)"
t_eq 0 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "no ifup while debounced despite wall jump"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=1; OPT_action_window=300
nowm=$(now_mono); echo "$(( nowm - 40 )) 0" > "$ACTIONS_FILE"   # wall=1970, mono recent
: > "$IFUP_LOG"; take_action
t_eq breaker "$ACTION_OUTCOME" "breaker counts a 1970-wall entry (uses monotonic)"

echo "# shared breaker key across sections (M3)"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=0; OPT_max_actions=2; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-wg0.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock" 2>/dev/null
: > "$IFUP_LOG"
take_action; take_action; take_action   # 3 actions on one shared counter, cap=2
t_eq 2 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "shared breaker caps at max_actions across sections"

echo "# F2: a short-window section's action must not erase actions-file history a longer-window section sharing the same target still needs"
set_base_config; OPT_action=ifup; OPT_action_network=mixedwin; OPT_debounce=0; OPT_max_actions=100; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-mixedwin.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock" 2>/dev/null
nowm=$(now_mono)
echo "$(( nowm - 1000 )) $(date +%s)" > "$ACTIONS_FILE"   # 1000s old: outside a 300s window, inside a 3600s one
: > "$IFUP_LOG"
take_action   # "section B" (short window) acts once
t_eq acted "$ACTION_OUTCOME" "section B (window=300) acts once"
t_eq 2 "$(wc -l < "$ACTIONS_FILE" | tr -d ' ')" "old entry survives B's prune+append (2 lines total)"
nowm2=$(now_mono)
cnt_b="$(recent_action_count "$nowm2")"
t_eq 1 "$cnt_b" "section B's own count (window=300) excludes the 1000s-old entry"
OPT_action_window=3600   # "section A" checking the SAME shared file with a longer window
cnt_a="$(recent_action_count "$nowm2")"
t_eq 2 "$cnt_a" "section A's count (window=3600) still sees the old entry B did not erase"

echo "# two sections sharing a target, CONCURRENT processes (5B.1 / M-neu-2)"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=5; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-wg0.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock" 2>/dev/null
: > "$IFUP_LOG"
for _ in 1 2 3 4; do ( take_action ) & done
wait
t_eq 1 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "concurrent: debounce allows exactly one ifup"
t_eq 1 "$(wc -l < "$ACTIONS_FILE" | tr -d ' ')" "concurrent: exactly one action recorded"

echo "# a stale lock (holder gone) is broken; a fresh lock still blocks (5B.2 / M-neu-3)"
set_base_config; OPT_action=ifup; OPT_action_network=stale; OPT_debounce=30; OPT_max_actions=5; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-stale.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock"
LOCK_TRIES=2; LOCK_SLEEP=0.05
: > "$ACTIONS_FILE.lock"                      # fresh lock held by a (simulated) live holder
if lock_acquire; then no "fresh lock: acquire must be refused (mutex intact)"; lock_release
else ok "fresh lock: acquire refused (mutex intact)"; fi
rm -f "$ACTIONS_FILE.lock"
: > "$ACTIONS_FILE.lock"                      # stale lock: holder gone > 2 min ago
touch -d '3 minutes ago' "$ACTIONS_FILE.lock" 2>/dev/null || touch -t 200001010000 "$ACTIONS_FILE.lock"
if lock_acquire; then ok "stale lock: broken and acquired"; lock_release
else no "stale lock: should be broken and acquired"; fi
rm -f "$ACTIONS_FILE.lock"
: > "$IFUP_LOG"; : > "$ACTIONS_FILE.lock"     # held fresh lock -> take_action must not act
LOCK_TRIES=2; LOCK_SLEEP=0.05
take_action
t_eq lockbusy "$ACTION_OUTCOME" "held fresh lock -> take_action reports lockbusy"
t_eq 0 "$(wc -l < "$IFUP_LOG" | tr -d ' ')" "held fresh lock -> no ifup while locked"
rm -f "$ACTIONS_FILE.lock"

echo "# an action_network that tries to escape the state dir cannot build a path outside it (5A.5)"
esc_network(){ n="$1"; valid_ifname "${n:-}" || n=""; printf '%s' "$TMP/state/act-${n:-SEC}.actions"; }
case "$(esc_network '../../tmp/x')" in *..*) esc=OUTSIDE ;; *) esc=INSIDE ;; esac
t_eq INSIDE "$esc" "action_network '../../tmp/x' is rejected -> path stays inside the state dir"
case "$(esc_network 'wg1')" in */act-wg1.actions) esc=KEPT ;; *) esc=LOST ;; esac
t_eq KEPT "$esc" "a valid action_network is preserved for the path"

echo "# low-severity hardening"
IFWATCHDOG_TEST=0 sh "$SCRIPT" 'bad;name' >/dev/null 2>&1; t_eq 2 "$?" "invalid section name exits 2"
IFWATCHDOG_TEST=0 sh "$SCRIPT" '' >/dev/null 2>&1;         t_eq 2 "$?" "empty section name exits 2"
# a failing ifup is still recorded as an attempted action (does not crash)
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=5; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-fail.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock" 2>/dev/null
: > "$IFUP_LOG"; IFUP_FAIL=1; export IFUP_FAIL
take_action
unset IFUP_FAIL
t_eq acted "$ACTION_OUTCOME" "failing ifup still counts as an attempted action"
t_ge 1 "$(wc -l < "$ACTIONS_FILE" | tr -d ' ')" "failing ifup is still recorded (breaker counts it)"

echo "# status + json hardening on the invalid path (M4)"
set_base_config; OPT_interface='a"; rm -rf /'   # crafted, unvalidated
rm -f "$STATE_DIR/$SECTION.json"
HS_AGE=""; HS_STATE=n/a; PING_RES=n/a; FAIL_COUNT=0
write_status invalid
SF="$STATE_DIR/$SECTION.json"
if grep -q '"state": "invalid"' "$SF"; then ok "invalid status written"; else no "invalid status written"; fi
if grep -q '"interface": "?"' "$SF"; then ok "crafted interface sanitised to '?'"; else no "crafted interface sanitised"; fi
if command -v python3 >/dev/null 2>&1; then
	if python3 -m json.tool "$SF" >/dev/null 2>&1; then ok "invalid status JSON parses"; else no "invalid status JSON parses"; fi
else ok "(python3 absent)"; fi

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

echo "# F9: breaker_tripped is sticky - true even when the current cycle's transient state looks healthy"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=1; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-wg0.actions"; rm -f "$ACTIONS_FILE" "$ACTIONS_FILE.lock" 2>/dev/null
nowm=$(now_mono); echo "$nowm $(date +%s)" > "$ACTIONS_FILE"   # 1 recorded action -> breaker tripped (max_actions=1)
HS_AGE=5; HS_STATE=fresh; PING_RES=ok; FAIL_COUNT=0
write_status alive
SF="$STATE_DIR/$SECTION.json"
t_true "breaker_tripped=true while engaged, even though this cycle's state is 'alive'" \
	grep -q '"breaker_tripped": true' "$SF"
rm -f "$ACTIONS_FILE"
write_status alive
t_true "breaker_tripped=false once no recent actions remain" grep -q '"breaker_tripped": false' "$SF"
set_base_config; OPT_action=monitor
write_status alive
t_true "breaker_tripped=false in monitor mode (never trips)" grep -q '"breaker_tripped": false' "$SF"

echo "# F4: status JSON carries a monotonic timestamp for GUI staleness (immune to NTP steps)"
t_true "updated_mono present in status JSON" grep -Eq '"updated_mono": [0-9]+' "$SF"

echo "# F5: last_action_mono/wall stay numeric against an empty or blank actions file"
set_base_config; OPT_action=ifup; OPT_action_network=wg0; OPT_debounce=30; OPT_max_actions=5; OPT_action_window=300
ACTIONS_FILE="$TMP/state/act-empty.actions"
: > "$ACTIONS_FILE"                       # 0 bytes, e.g. right after prune_actions_file empties it
t_eq 0 "$(last_action_mono)" "last_action_mono is numeric 0 on an empty file"
t_eq 0 "$(last_action_wall)" "last_action_wall is numeric 0 on an empty file"
printf '\n' > "$ACTIONS_FILE"             # blank trailing line, no fields
t_eq 0 "$(last_action_mono)" "last_action_mono is numeric 0 on a blank-line file"
: > "$IFUP_LOG"; take_action              # must not error out / must still act (no valid last action)
t_eq acted "$ACTION_OUTCOME" "take_action still acts against an empty actions file"
rm -f "$ACTIONS_FILE"

echo
echo "==================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
