# UAT — User Acceptance Test: ifwatchdog

**Purpose:** accept the plugin **before** production use on the central OpenWrt device.
Safety first: monitor mode first, console fallback ready, reversible at any time.

> **Context:** ifwatchdog was verified end-to-end beforehand in a **QEMU OpenWrt 25.12.5 VM** against a
> realistic test bed (a real ProtonVPN WireGuard tunnel + a policy-routing kill switch + a simulated
> client on the fail-closed network). The steps below are the **acceptance on the real device**.

## Preconditions
- `ifwatchdog` + `luci-app-ifwatchdog` installed; the service is enabled (`/etc/init.d/ifwatchdog enabled`).

## Before the first enable (pre-flight — do all four)
The residual risk lives in commissioning, not in the code. Before enabling **any** instance with an
action on the real router:
1. **Serial/console access tested now** — physically confirm the console gives a root shell, so a lost
   SSH/LAN path is recoverable. Do not rely on it untested.
2. **Auto-disable armed *before* start** — schedule a safety net that stops the watchdog even if you
   are locked out, e.g. `echo '*/5 * * * * /etc/init.d/ifwatchdog stop' >> /etc/crontabs/root` for the
   acceptance window (remove it once accepted). Arm it **before** the first enable, not after.
3. **Config backup + rollback command ready** — `cp /etc/config/ifwatchdog /root/ifwatchdog.uci.bak`;
   know the rollback: `uci set ifwatchdog.<inst>.enabled='0' && /etc/init.d/ifwatchdog restart`.
4. **Known-good `network`/pbr snapshot** — `cp /etc/config/network /root/network.uci.bak`
   (and the pbr config if used), so a bad `ifup` target can be restored from a known-good copy.

## Safety gate (always first)
1. A new instance starts with **`action='monitor'`** and a **small test window**.
2. **Verify the interface denylist** before ever setting `action='ifup'`.
3. Only switch to `ifup` after a clean monitor run — **one** change per step.

## Test cases (expected results)

| # | Step | Expected result | ✓ |
|---|---|---|---|
| 1 | Install the packages, open LuCI **Services → ifwatchdog** | GUI with live status + grid; the **interface dropdown** lists real interfaces | ☐ |
| 2 | Instance: `interface=<wg>`, `method=both`, `action=monitor`, short timings | On a stall: log `MONITOR … would act (no-op)`, status `state=monitor`, **no** action | ✅ (Stage 1, 2026-09-22, 48h real nightly outage, zero actions) |
| 3 | Set `action=ifup`, `action_network=lan` (denylist test) | **Refused**: log `refusing: … 'lan' is protected` → safe idle; **`lan` untouched** | ✅ (2026-09-23, real device used `management` instead of `lan` — same `is_protected()` path; `lan` itself never touched) |
| 3b | Set `action_network='-a'` (option-injection), then `mgmt` / `lan2` | **Refused** each time → safe idle, `ifup` never runs; **LAN still reachable** | ☐ (covered in the mock/QEMU suite, not re-run on the real device) |
| 3c | Invalid config (`action_network=lan`, or `debounce=0` with an action) | Status shows **`state=invalid` in the GUI** (red), not only in syslog | ☐ (status JSON confirmed `state: invalid`; LuCI's red rendering itself not screenshotted) |
| 3d | `kill -9` a running instance | Its row shows **stale (no update)** in the GUI, never a frozen "alive" | ☐ |
| 3e | `method=handshake` on a **non-WireGuard/absent** interface | Status shows **`holding`** (amber), **no** action — an unmeasurable handshake never fires and is not shown as `alive` | ☐ |
| 4 | `action=ifup`, `action_network=<wg>`; let the tunnel stall | ifwatchdog runs `ifup <wg>` → **fresh handshake**, interface recovers | ✅ (2026-09-23, twice: full 4G/WAN outage and a targeted WireGuard-only firewall block) |
| 5 | Produce repeated failures | **Debounce** + **circuit breaker** hold (log `debounce …`, `circuit breaker … refusing`) | ✅ (2026-09-23, breaker trip predicted to the minute and confirmed live in the LuCI log view) |
| 5a | **Two** sections with the same `action_network=<wg>`, both `ifup`; make the tunnel stall so both act in the same cycle | **Exactly one** `ifup`; the second logs `debounce (under lock)` — the shared-target lock + under-lock re-check serialise them | ✅ (2026-09-23, both sections hit "down signal 2/2" in the same second; only one `ifup` executed) |
| 5b | With the two sections of 5a, `kill -9` the section **holding the lock** mid-action | The survivor logs **`breaking stale lock`** exactly **once** (after ~2 min) and still heals the stall; the killed row goes **stale** | ☐ (a stale lock was instead simulated via a pre-aged lock file, not a live `kill -9` mid-action — see UAT status notes) |
| 5c | Set `interval=300` on an instance and let one poll pass | The row is **not** flagged stale — the GUI threshold scales as `max(180 s, 3 × interval)` | ☐ |
| 6 | Invalid config (e.g. empty `interface`) | **Fail-safe**: `invalid configuration - safe idle`, **no** action | ✅ (2026-09-23, triggered via a protected `action_network` rather than an empty `interface` — same `validate_config` fail-safe path) |
| 7 | Review logs/status | **No** secrets (only handshake age, ping, states); status JSON is secret-free | ✅ (2026-09-23, extensive log/status review across all test runs — no keys/handshake secrets ever logged) |

### Additional real-hardware coverage beyond this table (2026-09-23)
- **`action=script`:** a root-owned, mode-755 test script was invoked correctly on a real stall, with
  the documented positional args (`section interface action_network`), under the `SCRIPT_TIMEOUT` guard.
- **`method=ping` / `method=handshake` in isolation:** each drove detection and `ifup` correctly on its
  own (the other signal staying `n/a`) — previously only exercised together as `method=both`.
- Full narrative, timestamps and log excerpts for all of the above live in this session's on-device UAT
  notes (not duplicated here to keep this file a checklist, not a log).

## Staged activation (production roll-out)
One change per step; do not bundle. Advance only if the previous stage was clean.
1. **Monitor, one section, 48 h** — `action=monitor` on the real tunnel; confirm stalls are detected
   and logged, with zero actions.
2. **`ifup`, one section, 7 days** — switch that section to `ifup`; confirm real recoveries, debounce
   and breaker behaviour, and no flapping over several quiet nights.
3. **Second section** — only then add a second watchdog on the same or another target; re-check 5a/5b.

## Acceptance criteria
- All cases (1–7, 3b–3e, 5a–5c) as expected; **lan/management never restarted**; no secrets in
  logs/status; recovery reproducible within ~1–2 cycles; no flapping over a quiet night; two sections
  on one target emit **one** action per stall and survive a killed lock holder.

## Rollback
- `uci set ifwatchdog.<inst>.action='monitor'` (or `enabled='0'`) → `/etc/init.d/ifwatchdog restart`.
- Full: remove the package; `/etc/config/ifwatchdog` is kept as a conffile.
