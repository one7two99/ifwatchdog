# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- **C1 (Critical):** reject a leading `-` in interface/network values (`valid_ifname`/`valid_host`),
  so an `action_network` like `-a` can no longer become `ifup -a` (bring up all interfaces) → instant
  self-lockout on a central router (option injection).
- **H1:** the interface denylist now covers `lan*`, `mgmt*`, `management*`, `admin`, `loopback` and
  any alias network sharing the LAN's L3 device; entries are glob patterns (extensible via
  `protected_networks`) matched with `set -f`, so `protected_networks='*'` can no longer expand
  against the process CWD. The LuCI dropdown no longer offers protected networks and validates the
  name client-side.
- **H2:** a truthy `enabled` value (`on`/`true`/`yes`/`enabled`) no longer makes the check script exit
  and procd respawn it every 5 s forever; disabled/invalid instances idle instead (fail-safe: only
  SIGTERM/SIGINT exits) and still write a status file, so they stay visible in the GUI.
- **H3:** detection is tri-state (`fresh`/`stale`/`unknown`). An unmeasurable handshake (wg missing,
  non-WG or absent interface, no handshake yet, clock step) is `unknown` and never drives an action —
  `method=handshake` on e.g. `eth0` holds instead of firing forever. Shown as an `HS state` GUI column.
- **H4:** `action=script` is confined to a root-owned, non-group/world-writable executable inside the
  package-owned `/usr/libexec/ifwatchdog.d/` (no `..`), checked via `test -O` + `find -perm` (BusyBox
  has no `stat`); the ACL description flags that write access to this package is root-equivalent.

### Fixed
- Observable clean shutdown: a SIGTERM handler logs `stopping (interface=…)` and removes the status
  file (the instance disappears from the GUI live-status table).
- The check-loop sleep is now signal-interruptible (background + `wait`); otherwise procd's SIGKILL
  beat the handler on stop and it never fired.
- The service is really restarted on a config change (`reload_service` → `restart`); previously a
  procd `reload` did not pick up new UCI values, so LuCI "Save & Apply" only took effect after a
  manual restart.

### Changed
- LuCI: **help text on every setting**; `protected_networks` gained a placeholder/hint.

### Added
- LuCI app `luci-app-ifwatchdog` (M2): JS web UI under *Services → ifwatchdog*.
  - Grid of instances, **interface dropdown** (from real network devices), all options in the modal
    (method/thresholds/action/debounce/circuit breaker/protected networks).
  - **Live status** (5 s poll) via the rpcd ubus object `ifwatchdog.status` (secret-free).
- Base service `ifwatchdog` (M1): procd init, UCI schema (`/etc/config/ifwatchdog`), check script
  `ifwatchdog.sh`.
  - Detection: interface-bound ping (`ping -I`) and/or WireGuard handshake age.
  - Safety: monitor by default, interface denylist (self-lockout protection), strict input validation
    (injection-safe), debounce, circuit breaker, fail-safe idle, secret-free status JSON.
- Mock test harness (`tests/run.sh`, 43 checks) — runs without OpenWrt; shellcheck-clean.
- Project scaffold: LuCI app layout, GPL-2.0-or-later, README, docs/ (spec + background).

[Unreleased]: https://github.com/one7two99/ifwatchdog/compare/main...HEAD
