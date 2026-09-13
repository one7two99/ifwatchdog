# ifwatchdog

**Interface health watchdog for OpenWrt** — watches a network interface and restarts it when it
*silently* stalls. Ships with a LuCI web UI (pick the interface from a dropdown).

> ⚠️ **Status: in development (pre-release, `0.1.0-unreleased`).** Not yet released for production use.
> This package runs as `root` and can restart interfaces — it is meant to be installed on real hardware
> only after local tests, QEMU integration tests and an external code review.

## Why

WireGuard tunnels behind CGNAT (e.g. a cellular uplink) can **stall without the interface going
"down"**: WireGuard is silent by design and does not self-heal. If a network egresses **fail-closed**
exclusively through such a tunnel, it is completely offline during a stall — until the tunnel is
restarted by hand. Existing built-ins don't cover this cleanly:

- `watchcat` restarts interfaces on ping failure, but **does not bind the ping to the interface** and
  has **no notion of WireGuard handshake age** — in fail-closed / policy-routing setups it therefore
  tests the wrong path.
- `mwan3` is multi-WAN **failover** and runs against a deliberate fail-closed design.

`ifwatchdog` fills the gap: an **interface-bound ping** (`ping -I <iface>`) **and/or** the
**WireGuard handshake age** (`wg show <iface> latest-handshakes`) for detection, plus a targeted
`ifup` — with guard rails for running on a central device.

## Safety principles (design)

Because the plugin runs as `root` on a central device, these principles apply:

1. **Monitor by default** — ships disabled and observe-only; it only acts after you deliberately enable
   an action per instance.
2. **Interface protection** — protection covers `lan*`, `mgmt*`, `management*`, `admin`, `loopback`
   (glob patterns), any network sharing the LAN's L3 device, and any value that looks like an option
   (leading `-`), so an accidental or crafted `action_network` can never restart the admin's own path
   (self-lockout protection). Extend it via `protected_networks`.
3. **Input hardening** — every config value is strictly validated and quoted before use; no `eval`.
4. **Circuit breaker** — a cap on actions per time window prevents "flapping".
5. **Fail-safe** — on invalid/missing configuration it does nothing.
6. **No secrets** — only handshake age and ping results are logged; never keys or passphrases.

## Layout

- **`ifwatchdog/`** — base package: UCI config (`/etc/config/ifwatchdog`), procd service, check script.
- **`luci-app-ifwatchdog/`** — web UI (JS LuCI): interface dropdown, methods/thresholds, live status.
- **`tests/`** — mock tests (run without OpenWrt).
- **`docs/`** — design/spec, UAT, code-review handoff, background.

Both packages are `noarch` (pure shell + JS) → **one build runs on every target**.

## Installation

> Available after the review. Planned: a signed package feed (one-click in *System → Software*), with
> `.apk` sideload as a fallback.

## Development & testing

Two-stage, to protect the target device:

1. **Local:** `shellcheck` + mock tests (`tests/`) — prove the logic without a device.
2. **QEMU:** an OpenWrt x86-64 VM (`noarch` → representative) for procd/UCI/apk/LuCI integration,
   including a simulated WireGuard stall.

See `docs/` for the design/spec, acceptance test (UAT) and the code-review handoff.

## License

[GPL-2.0-or-later](LICENSE).
