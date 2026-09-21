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
- **H5:** the alias-protection heuristic now resolves each network's *live* L3 device via
  `ifstatus` (falling back to the static `device`/`ifname` UCI options when unavailable), and
  compares against **every** protected-pattern network, not only `lan` — a renamed or second
  management network (e.g. `mgmt0`) now protects its own aliases too, and a `device` set via a UCI
  cross-reference (`@lan`) resolves correctly where a raw string comparison could not.
  `DEFAULT_PROTECTED`'s `lan lan[0-9]*` broadened to `lan*` (also catches `lanmgmt`/`lan-guest`
  style names); the LuCI dropdown filter broadened to match.
- **M-neu-2/M-neu-3 (concurrency):** the shared-target action lock is an O_EXCL file create
  (`set -C`) — the POSIX atomic-create primitive, needing no cleanup beyond `rm`. A lock older than 2 minutes is
  treated as abandoned and broken once (`breaking stale lock`), so a SIGKILLed holder can no longer
  block every section sharing a tunnel forever; a failed lock is reported `lockbusy`, not as the
  breaker. `take_action` re-checks debounce **under** the lock, so two sections that both see a stall
  in the same second still emit only one `ifup`.
- **L-neu-5:** `action_network` is validated (`valid_ifname`) **before** it is used to build the
  actions-file path, so a crafted `../../…` value can never place the state/lock file outside the
  package state dir.
- **5D.1:** the O_EXCL lock file is cleared with `rm -f` on service start (was `rmdir`, which cannot
  remove a regular file) — a lock left by a SIGKILLed holder no longer forces a fresh instance to
  wait out the ~2 min stale-break before it can act after a restart.
- **5D.2:** a service restart (every LuCI "Save & Apply") no longer wipes the circuit-breaker history:
  the per-target `.actions` files are kept and reset only on reboot (tmpfs). Prevents an admin who
  re-tunes during an outage from repeatedly clearing the flapping brake.
- **5D.3:** when `action=ifup` is configured but no `lan` network resolves (e.g. LAN renamed to
  `trusted`), a one-time warning notes that automatic alias protection is inactive and
  `protected_networks` should cover the management network. It warns, never rejects.

### Fixed
- **F8:** `action=script` now runs under a 60 s bound (`run_action_script`, a portable
  background-process + `kill` pattern — the target BusyBox build has no `timeout` applet) — a
  hung/buggy custom script could previously block that section's entire check loop (no more checks,
  no more recovery) indefinitely.
- **F7:** `valid_uint` now caps input at 7 digits (well beyond any sane config value, keeps every
  arithmetic use safely in range) instead of accepting arbitrarily long digit strings; `max_handshake_age`
  must be >= 30 when `method` is `handshake`/`both` (below WireGuard's default `persistent_keepalive`
  cadence, a healthy tunnel would constantly re-register as stale between keepalives).
- **F6:** handshake freshness is now judged on monotonic time elapsed since the current handshake
  value was first observed, not a wall-clock diff recomputed against `wg show`'s reported epoch every
  cycle — a wall-clock step shortly after boot (no RTC) could otherwise flip a persisting handshake's
  classification either way for no real reason. The monotonic origin is seeded from the wall-clock age
  at first sight, so the initial classification of a never-before-seen value is unchanged; `method=both`
  mitigated most practical impact via the ping fallback, but this closes the gap directly.
- **F5:** `last_action_mono`/`last_action_wall` now always print a number, even against an empty or
  blank-trailing-line actions file (e.g. right after pruning empties it) — the previous bare
  pattern-action `awk` printed nothing for such input, which made a caller's `[ "$last_m" -gt 0 ]`
  fail with a raw shell "integer expression expected" error instead of the intended "no prior action"
  result. The rpcd `status` backend also skips any per-instance file that fails a `jsonfilter`
  validity check instead of `cat`-ing it unconditionally into the aggregated response.
- **F4:** the GUI staleness check compared wall-clock `Date.now()` against the status JSON's `updated`
  field only — inconsistent with the rest of the codebase's own reasoning for using monotonic time
  (routers have no RTC and may step wall clock at NTP sync). The status JSON now also carries
  `updated_mono` (`/proc/uptime`-based), the rpcd backend returns the router's current `now_mono`
  alongside `instances`, and the GUI compares monotonic time when both are present (falling back to
  wall time only for a status file written before this field existed).
- **F9:** `breaker` and `down` now render distinctly in the GUI (red / amber) instead of falling
  through to plain neutral text identical to `alive`/`monitor`. The status JSON also carries a sticky
  `breaker_tripped` boolean, true whenever the shared circuit breaker is currently engaged for this
  target regardless of the current cycle's transient state, so a row does not look falsely healthy in
  the gap between down-cycles while the breaker is still refusing actions.
- **F2:** `recent_action_count` no longer prunes the shared per-target actions file by the *calling*
  section's own `action_window` — two sections watching the same target with different windows (e.g.
  300 s vs 3600 s, an explicitly supported multi-instance setup) could otherwise have the shorter-window
  section silently erase history the longer-window section still needed, undercounting its breaker.
  Pruning is now a separate, window-independent step that caps the shared file at the most recent 200
  entries; counting is a pure read. `max_actions` is capped at 100 to keep headroom under that cap.
- **M1:** debounce and the circuit breaker now use monotonic time (`/proc/uptime`), so an NTP step at
  boot (routers have no RTC) can no longer reset the breaker or freeze debounce. The actions file line
  is `<mono> <wall>`; wall time is used only for display.
- **M2:** `debounce` (>= 30 s) and `action_window` (>= 300 s) have floors when an action is configured,
  so the breaker can actually trip and actions are spaced out; monitor mode still accepts 0.
- **M3:** breaker/debounce state is keyed on the target network (`act-<network>.actions`), so two
  sections watching the same tunnel share one counter; the prune+count+append is serialised by a lock.
- **M4:** invalid/disabled instances write a status file (`state=invalid`/`disabled`) before idling, so
  a refused "Save & Apply" is visible (prominently) in the GUI, not only in syslog.
- **M5:** stale status/actions/lock files are cleared on service start, and the GUI marks rows whose
  status stopped updating (> 180 s) as stale — a killed instance never shows as alive.
- **M-neu-1:** the check loop only writes `alive` when health was actually **measured**. An
  unmeasurable handshake (`method=handshake` on a non-WG/absent interface) now writes `holding` and
  does not reset the failure counter, so the GUI no longer shows a hollow `alive` for an instance
  that is only holding under uncertainty.
- **M-neu-4:** the GUI staleness threshold scales with the check interval
  (`max(180 s, 3 × interval)`), so an instance with `interval > 60` is no longer flagged stale on
  every poll; the status JSON now carries `interval`. `holding`/`lockbusy` render amber
  ("cannot measure / retry"), distinct from red (`invalid`/`disabled`/stale).
- Low: validate the section name; warn when `ifup` returns non-zero (a failed *action* is now
  distinguishable from a failed *tunnel*); rate-limit the breaker log; expose `ping_timeout` in the
  GUI; declare `protected_networks` as a `list` in the sample config to match the GUI/backend.
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
- Mock test harness (`tests/run.sh`, 103 checks) — runs without OpenWrt; shellcheck-clean.
- Project scaffold: LuCI app layout, GPL-2.0-or-later, README, docs/ (spec + background).

[Unreleased]: https://github.com/one7two99/ifwatchdog/compare/main...HEAD
