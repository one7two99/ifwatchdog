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
- `tests/run.sh` — 43 mock checks (run without OpenWrt).

## How it was verified
- **Static:** `shellcheck` (style level, clean) for all shell files.
- **Unit/mock:** `tests/run.sh` — 43 checks (validators, denylist, `validate_config`, detection,
  `take_action`/debounce/breaker, status JSON).
- **Integration (QEMU, real OpenWrt 25.12.5):** against a **real ProtonVPN tunnel** + a
  **policy-routing kill switch** + a simulated client on the fail-closed network. Demonstrated:
  monitor detection with no action; the denylist refuses `lan` (LAN stayed reachable);
  **stall → fail-closed network offline / router online**; ifwatchdog `ifup` → **recovery in one
  cycle**; the circuit breaker actually prevented flapping.

## Known limits / open questions
- Heals **stalls**, not a genuine uplink outage (then fail-closed stays correctly offline).
- `action=script` — **answered:** absolute + executable was **not** enough; it is now confined to a
  root-owned, non-group/world-writable file inside the package-owned `/usr/libexec/ifwatchdog.d/`
  (checked via `test -O` + `find -perm`, since stock BusyBox has no `stat`).
- Is the default `max_actions=5 / 3600s` right? Should the state file survive a reboot (currently
  `/var/run`, i.e. no — by design)?
- Suggestions for additional guards that make sense on a security device are welcome.
