# Code-review handoff

**Please review this code critically.** It runs **as root on a central OpenWrt security router** that
protects an entire home network. Mistakes here are expensive — focus on security, robustness and
"cannot lock itself out".

## What it is
`ifwatchdog` watches a network interface and restarts it when it **silently** stalls (WireGuard
handshake age and/or an interface-bound ping). Motivation: a WireGuard tunnel behind CGNAT can stall
without going "down"; a fail-closed network that egresses only through it is then offline until the
tunnel is restarted.

## Threat model / assumptions
- Runs as **root** via procd; configured through UCI (`/etc/config/ifwatchdog`).
- Untrusted-ish inputs = UCI values (settable via LuCI / an attacker) → they **must** be strictly
  validated before they reach `ping`/`wg`/`ifup`/the shell.
- **Self-lockout risk:** an accidental `ifup` on LAN/management locks the admin out.

## Review focus (please check specifically)
1. **Command injection:** `ifwatchdog/files/ifwatchdog.sh` — `valid_ifname`/`valid_host`/`valid_uint`,
   quoting, **no `eval`**. Does any UCI value reach a command line unchecked?
2. **Interface denylist:** `is_protected` + `validate_config` — can `action_network=lan/loopback`
   (or management) still slip through? Is the default denylist sufficient?
3. **Fail-safe:** invalid/missing config, missing `wg` → **do nothing** instead of acting wrongly.
   Is there a path that triggers an action under uncertainty?
4. **Flapping protection:** `debounce` + circuit breaker (`max_actions`/`action_window`) — race
   conditions, the count/prune logic in `recent_action_count`, the state file under `/var/run`.
5. **Secret-freedom:** only handshake age/ping/states in logs + status JSON; **never** keys.
   The rpcd backend `luci-app-ifwatchdog/root/usr/libexec/rpcd/ifwatchdog` — does it leak anything?
6. **procd/init:** `ifwatchdog.init` — respawn behaviour, no respawn storms on misconfiguration.
7. **LuCI/ACL:** `acl.d/luci-app-ifwatchdog.json` — least privilege (only `uci ifwatchdog` +
   `ubus ifwatchdog.status`)? The JS view `overview.js` — sensible?

## File map
- `ifwatchdog/files/ifwatchdog.sh` — core (detection, validation, action, debounce/breaker, status).
- `ifwatchdog/files/ifwatchdog.init` — procd service.
- `ifwatchdog/files/ifwatchdog.config` — UCI defaults (disabled, monitor).
- `luci-app-ifwatchdog/…/overview.js` — GUI; `…/rpcd/ifwatchdog` — status ubus; `…/acl.d/…` — ACL.
- `tests/run.sh` — 198 mock checks (run without OpenWrt).

## How it was verified
- **Static:** `shellcheck` (style level, clean) for all shell files; a GitHub Actions workflow
  (`.github/workflows/ci.yml`) now runs it, plus a real BusyBox `ash -n` syntax check and the full
  `tests/run.sh` suite, on every push to `main` and every pull request.
- **Unit/mock:** `tests/run.sh` — 198 checks (validators, denylist, `validate_config`, detection,
  `take_action`/debounce/breaker, status JSON, `prepare_state_dir()`'s directory validation, symlink
  safety on every predictable-path write).
- **Integration (QEMU, real OpenWrt 25.12.5):** against a **real ProtonVPN tunnel** + a
  **policy-routing kill switch** + a simulated client on the fail-closed network. Demonstrated:
  monitor detection with no action; the denylist refuses `lan` (LAN stayed reachable);
  **stall → fail-closed network offline / router online**; ifwatchdog `ifup` → **recovery in one
  cycle**; the circuit breaker actually prevented flapping; **two sections on one tunnel emit one
  `ifup`**, and when the lock holder is `kill -9`ed mid-action the survivor logs `breaking stale lock`
  exactly once and still heals the stall (`lock_tuning` picks the integer-sleep fallback because this
  build's BusyBox `sleep` has no fractional support).

## Known limits / open questions
- Heals **stalls**, not a genuine uplink outage (then fail-closed stays correctly offline).
- Is the default `max_actions=5 / 3600 s` circuit breaker right for a **cellular** uplink, where a
  legitimate re-handshake after a tower/NAT change may need several `ifup`s in a short window?
- Should the breaker survive a **reboot**? Today the `.actions` state lives in `/var/run` (tmpfs) and
  resets on reboot by design, but is kept across a service restart (a config change) since 5D.2.
- Is the **2-minute stale-lock** threshold right for a heavily loaded router, or could a real holder
  legitimately be paused that long (making the break premature)?
- Suggestions for additional guards that make sense on a security device are welcome.

## Not done yet (explicitly out of scope so far)
No signed package feed (a `.apk` builds correctly from the tagged GitHub release via
`PKG_SOURCE`/`PKG_HASH` and has been sideloaded on production hardware repeatedly via
`apk add --allow-untrusted`, but there is no automated build+publish pipeline or one-click
`System → Software` install yet); no out-of-band alerting when an instance itself stops updating
(tracked as an issue; the alert path must not traverse the fail-closed network).

On-device UAT is no longer pending: the QEMU run above was the pre-UAT gate, and extensive real-hardware
acceptance has since run on the actual production router (see `docs/UAT.md`) — staged activation through
`action=ifup`, deliberate stall simulations (full WAN outage, WireGuard-only path block, denylist
refusal, stale-lock recovery, concurrent-section shared-lock contention, `action=script`, each detection
method in isolation), and CI (`.github/workflows/ci.yml`) now runs shellcheck + the full test suite on
every push/PR.
