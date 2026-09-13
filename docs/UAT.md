# UAT — User Acceptance Test: ifwatchdog

**Purpose:** accept the plugin **before** production use on the central OpenWrt device.
Safety first: monitor mode first, console fallback ready, reversible at any time.

> **Context:** ifwatchdog was verified end-to-end beforehand in a **QEMU OpenWrt 25.12.5 VM** against a
> realistic test bed (a real ProtonVPN WireGuard tunnel + a policy-routing kill switch + a simulated
> client on the fail-closed network). The steps below are the **acceptance on the real device**.

## Preconditions
- `ifwatchdog` + `luci-app-ifwatchdog` installed; the service is enabled (`/etc/init.d/ifwatchdog enabled`).
- **Console / serial access ready** (recovery in case SSH/networking drops).
- Optional safety net: a scheduled **auto-disable** (e.g. a cron `/etc/init.d/ifwatchdog stop` after
  30 min) until acceptance is done.

## Safety gate (always first)
1. A new instance starts with **`action='monitor'`** and a **small test window**.
2. **Verify the interface denylist** before ever setting `action='ifup'`.
3. Only switch to `ifup` after a clean monitor run — **one** change per step.

## Test cases (expected results)

| # | Step | Expected result | ✓ |
|---|---|---|---|
| 1 | Install the packages, open LuCI **Services → ifwatchdog** | GUI with live status + grid; the **interface dropdown** lists real interfaces | ☐ |
| 2 | Instance: `interface=<wg>`, `method=both`, `action=monitor`, short timings | On a stall: log `MONITOR … would act (no-op)`, status `state=monitor`, **no** action | ☐ |
| 3 | Set `action=ifup`, `action_network=lan` (denylist test) | **Refused**: log `refusing: … 'lan' is protected` → safe idle; **`lan` untouched** | ☐ |
| 4 | `action=ifup`, `action_network=<wg>`; let the tunnel stall | ifwatchdog runs `ifup <wg>` → **fresh handshake**, interface recovers | ☐ |
| 5 | Produce repeated failures | **Debounce** + **circuit breaker** hold (log `debounce …`, `circuit breaker … refusing`) | ☐ |
| 6 | Invalid config (e.g. empty `interface`) | **Fail-safe**: `invalid configuration - safe idle`, **no** action | ☐ |
| 7 | Review logs/status | **No** secrets (only handshake age, ping, states); status JSON is secret-free | ☐ |

## Acceptance criteria
- All 7 cases as expected; **lan/management never restarted**; no secrets in logs/status;
  recovery reproducible within ~1–2 cycles; no flapping over a quiet night.

## Rollback
- `uci set ifwatchdog.<inst>.action='monitor'` (or `enabled='0'`) → `/etc/init.d/ifwatchdog restart`.
- Full: remove the package; `/etc/config/ifwatchdog` is kept as a conffile.
