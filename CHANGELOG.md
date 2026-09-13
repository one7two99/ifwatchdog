# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
