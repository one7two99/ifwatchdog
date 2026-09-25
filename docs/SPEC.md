# SPEC — `ifwatchdog`: interface health watchdog for OpenWrt (with LuCI GUI)

**Purpose of this document:** the design/architecture reference for the package — versioned (SemVer),
installable via the **web UI** (LuCI → System → Software), with the **interface to test selectable in
the GUI**. It grew out of a real incident: a WireGuard tunnel (ProtonVPN) behind CGNAT stalled
silently and took a fail-closed network offline (see [`CONTEXT-wireguard-stall.md`](CONTEXT-wireguard-stall.md)).

## Decisions

- **Scope:** a general **interface watchdog** — any interface selectable in the GUI; health check via
  an **interface-bound ping**, with **WireGuard detection (handshake age)** as a bonus method.
- **Distribution:** a **signed GitHub feed** is the goal; **`.apk` sideload** as a fallback until the
  feed is up.
- **Name:** `ifwatchdog` (service) + `luci-app-ifwatchdog` (GUI).
- **License:** GPL-2.0-or-later (the OpenWrt norm).

## Why (vs. existing tools)

- `watchcat` can restart interfaces on ping failure, but **pings over the normal routing table**
  (it cannot **bind the ping to an interface**) and has **no WireGuard handshake age**. In a
  fail-closed / policy-routing setup (router default = WAN) it therefore tests the wrong path.
- `mwan3` is multi-WAN **failover** — too heavy and contrary to a fail-closed design.
- **`ifwatchdog` fills the gap:** `ping -I <iface>` (interface-bound) **plus**
  `wg show <iface> latest-handshakes` (handshake age).

---

## Repo layout

```
ifwatchdog/                      # this repo
├─ ifwatchdog/                   # base package (service)
│  ├─ Makefile
│  └─ files/
│     ├─ ifwatchdog.init         # /etc/init.d/ifwatchdog (procd)
│     ├─ ifwatchdog.config       # /etc/config/ifwatchdog (UCI defaults)
│     └─ ifwatchdog.sh           # /usr/libexec/ifwatchdog.sh (check loop)
├─ luci-app-ifwatchdog/          # GUI package (LuCI, JS)
│  ├─ Makefile
│  ├─ htdocs/luci-static/resources/view/ifwatchdog/overview.js
│  └─ root/usr/share/{luci/menu.d,rpcd/acl.d}/…json
│     + root/usr/libexec/rpcd/ifwatchdog       # status ubus for the GUI
├─ .github/workflows/ci.yml      # shellcheck + tests/run.sh on every push/PR (SDK build + signed
│                                 # feed publish is still planned, not yet automated - see below)
├─ README.md  CHANGELOG.md  LICENSE
```

**Both packages are `noarch`** (pure shell + JS, like `pbr`/`luci-app-*`) → **one build runs on every
target**. This greatly simplifies the build and the feed.

---

## Package 1 — `ifwatchdog` (service)

### UCI schema `/etc/config/ifwatchdog` (multiple instances)

```
config watchdog 'example'
    option enabled           '1'
    option interface         'wg0'       # L3 device for ping -I / wg show
    option method            'both'      # handshake | ping | both
    option ping_host         '1.1.1.1'   # methods ping/both only
    option ping_timeout      '3'         # seconds; methods ping/both only
    option interval          '60'        # seconds between checks
    option max_handshake_age '150'       # s; methods handshake/both only
    option failures          '2'         # consecutive failures before action
    option action            'monitor'   # monitor | ifup | script
    option action_network    'wg0'       # UCI network for ifup (default = interface)
    option script            ''          # when action=script
    list   protected_networks 'mgmt*'    # extra denylist patterns, on top of the automatic ones
    option debounce          '120'       # minimum seconds between two actions
    option max_actions       '5'         # circuit breaker: max actions per action_window
    option action_window     '3600'      # circuit breaker window, seconds
    option log               '1'
```

- **Multiple `config watchdog` sections** = several interfaces watched at once.
- The split of **"test" (`interface`)** vs. **"restart" (`action_network`)** — identical by default,
  but flexible (e.g. test the WG device, restart the uplink network).

### Check logic `ifwatchdog.sh <section>`

Pseudo-code:
```
alive=0
[ method in {handshake,both} ] && age(wg show $if latest-handshakes) <= max_handshake_age && alive=1
[ alive=0 ] && [ method in {ping,both} ] && ping -I $if -c1 -W3 $ping_host && alive=1
if alive: fail_count=0
else: fail_count++
      if fail_count >= failures and (now - last_action) >= debounce and breaker ok:
          logger; action (ifup $action_network | script); last_action=now; fail_count=0
write status to /var/run/ifwatchdog/$section.json (for the GUI)
sleep interval; loop
```
- **`both` = OR-friendly:** alive if the **handshake is fresh OR the ping is ok** → fewer false alarms.
- **Debounce + failures + circuit breaker** prevent ifup loops on a genuine uplink outage.
- The **status JSON** (last handshake age, last ping, last action, fail_count) drives the live GUI.

### procd init `/etc/init.d/ifwatchdog`
`USE_PROCD=1`; `config_foreach start_instance watchdog`; one `procd_open_instance` per enabled section
with `command /usr/libexec/ifwatchdog.sh <section>`, `respawn`, a reload trigger on `ifwatchdog`, and
`reload_service` → `restart` so config changes are picked up.

### Safety / validation
- Every UCI value is validated before use; strings that could become a command-line **option** are
  rejected (a leading `-` never passes `valid_ifname`/`valid_host`), so a value can never turn into
  `ifup -a` or a `ping` flag.
- **Interface denylist** (`is_protected`): `DEFAULT_PROTECTED` holds glob patterns
  (`lan* mgmt* management* admin loopback`), matched under `set -f` so a pattern is never expanded
  against the filesystem. Additionally, any network whose *live* L3 device (resolved via `ifstatus`,
  falling back to the static `device`/`ifname` UCI options) equals the L3 device of **any** network
  whose name matches a protected pattern — not only `lan` — is protected (alias-network self-lockout,
  e.g. a renamed/second management network protects its own aliases too). `wan` is deliberately **not**
  protected. Admins extend the list via `protected_networks` (a `list` of glob patterns).
- **Detection is tri-state.** `handshake_probe` sets `HS_STATE` = `fresh|stale|unknown`; `unknown`
  ("cannot measure": wg missing, non-WG/absent interface, no handshake yet, clock step) never drives
  an action, and with `method=handshake` the instance holds — the loop then writes `state=holding`
  (not `alive`) and keeps the failure counter, so a hold is never reported as measured health. The
  status JSON carries `handshake_state`. Freshness is judged on **monotonic** time elapsed since the
  current handshake value was first observed (seeded from the wall-clock age at that first sight), not
  a wall-clock diff recomputed every cycle — a later NTP step can no longer flip a persisting value's
  classification either way.
- **`action=script` is confined** to a root-owned, non-group/world-writable executable inside
  `/usr/libexec/ifwatchdog.d/` (no `..`). Ownership/permissions are checked with `test -O` + `find`
  (stock BusyBox has no `stat`). Write access to the UCI package is root-equivalent by design.
- **Fail-safe invariant:** the process exits only on SIGTERM/SIGINT; every other "cannot work"
  condition writes a status file (`disabled`/`invalid`) and idles — so it never storms procd and never
  vanishes from the GUI.
- **Breaker/debounce use monotonic time** (`/proc/uptime`), immune to an NTP step at boot. The actions
  file `act-<target>.actions` (shared across sections with the same target) stores `<mono> <wall>` per
  action; wall time is display-only. The `.actions` files are **kept across a service restart** (a
  config change goes through `restart`, and wiping them would reset the flapping brake on every LuCI
  "Save & Apply"); the monotonic stamps stay valid across a restart and entries age out via
  `action_window`. The breaker resets only on **reboot** (tmpfs is cleared), which is the intended reset.
  `debounce`/`action_window` have floors (30 s / 300 s) when an action is configured.
  Enabled sections sharing a target must use identical `max_actions` and `action_window` values;
  conflicting or unreadable policies refuse the action rather than letting a permissive section
  bypass another section's breaker.
- **The shared-target lock is an O_EXCL file create** (`set -C; : > act-<target>.actions.lock`):
  O_EXCL is the POSIX atomic-create primitive and needs no cleanup semantics beyond `rm`. The prune +
  count + append run under this lock, and `take_action` re-checks debounce **under** the lock, so two
  sections seeing a stall in the same second still emit only one action. A lock older than **2 minutes**
  is treated as abandoned and broken once (`breaking stale lock`), so a SIGKILLed holder cannot block
  the shared target forever; a lock that cannot be taken is reported `lockbusy` (not the breaker).
- **Status states:** `alive`, `holding`, `down`, `invalid`, `disabled`, and the transient
  `debounced`/`breaker`/`lockbusy`/`acted`, plus a GUI-side `stale` when the status file stopped
  updating for `max(180 s, 3 × interval)` (scales with the interval so a slow instance is not flagged
  every poll). Staleness is measured against the router's own monotonic clock (`updated_mono` in the
  status JSON, `now_mono` returned by the rpcd `status` call) rather than wall time, so an NTP step at
  boot cannot make a fresh row look stale or a truly stale one look fresh; wall time (`updated`) is a
  fallback only. The status JSON carries `interval` and a sticky `breaker_tripped` boolean (true whenever
  the shared breaker is currently engaged for this target, independent of the current cycle's
  transient state, so a row does not look falsely healthy between down-cycles). `holding`/`lockbusy`/
  `down` are amber ("cannot measure / early warning"); `invalid`/`disabled`/`stale`/`breaker`/
  `breaker_tripped` are red.
  On service start the per-process **status** files and any leftover **lock** file (an O_EXCL regular
  file, removed with `rm -f`) are cleared; the per-target `.actions` breaker files are kept (see above).
  The status file is written to a `mktemp`-created temp path (`$f.XXXXXXXX`, a random suffix, not a
  predictable one) inside a `( umask 077; mktemp ... )` command substitution before the atomic `mv`, so
  it is created at mode 0600 from the first byte on and its name cannot be guessed in advance.
- **Every predictable-path write is symlink-safe (CWE-61):** `write_status` and `prune_actions_file`
  create their temp files with `mktemp "$f.XXXXXXXX"` — a random suffix, not the process PID — so there
  is no predictable path left for a local attacker to pre-plant a symlink at in the first place; the
  subsequent `mv` needs no extra guard either way, since POSIX `rename()` replaces whatever sits at the
  destination (including a symlink) without ever following it. The shared `.actions` file itself is
  appended to, not create-and-renamed (it must persist across restarts — see above), so it cannot use
  the same mktemp-on-create idiom; `take_action` instead refuses and reports the breaker outcome if
  `ACTIONS_FILE` is itself a symlink before appending (the one case a `mv`-based prune can't neutralize
  on its own — a *dangling* symlink, which `prune_actions_file`'s own `[ -f ]` guard skips untouched).
- **The state directory itself is validated before every start (`prepare_state_dir`, CWE-61):** the
  default `/var/run/ifwatchdog` and any `IFWATCHDOG_STATE_DIR` override (test-harness only — never read
  by the real init script) must resolve to a directory owned by the daemon with no group/other-write
  bit, and every parent directory up to `/` must be either not group/other-writable or, if it is (e.g. a
  shared `/tmp`), have the sticky bit set with the child still owned by the daemon — the standard
  shared-tmp-safe pattern real OpenWrt hardware needs, since `/var/run` is itself commonly a symlink to
  a shared `/tmp`. Startup safe-idles (logging once) on any validation failure rather than running
  against an untrusted directory.

### Dependencies
- `ping -I` → **BusyBox ping supports `-I`** (no extra package needed).
- `wg` → `wireguard-tools` only for `method=handshake/both` — a **soft dependency** (the script checks
  whether `wg` exists; otherwise it degrades the method to `ping` and logs a note). Keeps the base
  package small.
- `action=script` is bounded by a portable background-process + `kill` pattern rather than the
  coreutils `timeout` applet, which stock BusyBox builds do not ship.

---

## Package 2 — `luci-app-ifwatchdog` (web UI, JS LuCI)

Modern LuCI = **client-side JS** (`form`, `network`, `ubus`), not the old Lua CBI.

- **`overview.js`** — `form.Map('ifwatchdog')`, `form.GridSection` over `watchdog`:
  - **Enabled** (`form.Flag`).
  - **Interface dropdown** (the key requirement): populated from real devices via
    `require('network')` → `network.getDevices()`/`getNetworks()`.
  - **Method**, **ping_host**, **interval**, **max_handshake_age**, **failures**, **debounce**,
    **action** (+ dependent fields `action_network`/`script` via `.depends`).
  - **Live status**: last handshake age / last ping / last action — from the status ubus below,
    refreshed via `poll.add(...)`.
- **Status ubus** `root/usr/libexec/rpcd/ifwatchdog` (shell rpcd): method `status` reads the
  `/var/run/ifwatchdog/*.json` files and returns them together → clean ACL instead of raw file access.
- **Menu** `menu.d/luci-app-ifwatchdog.json`: entry under **Services** → `admin/services/ifwatchdog`.
- **ACL** `acl.d/luci-app-ifwatchdog.json`: `uci ifwatchdog` read/write + `ubus ifwatchdog status`.

---

## Build & CI

- **OpenWrt SDK** (matching the target release, e.g. 25.12). Because it is **noarch**, a single SDK
  run is enough.
- **GitHub Actions** (`openwrt/gh-action-sdk` or an SDK container): builds both `.apk` on each tag.
- **Publish the feed:** build an apk repo index and publish it to **GitHub Pages** (or release assets),
  **signed** (ed25519 key as a CI secret; the public key goes to `/etc/apk/keys/` on the routers).
  **Sideload fallback:** attach the raw `.apk` to the release (`apk add --allow-untrusted …`).

### Installation via the web UI (end user)
1. **Feed:** add the public key + feed URL on the router → **System → Software → "Update lists…"** →
   `ifwatchdog` + `luci-app-ifwatchdog` appear → **Install**. Updates become one-click.
2. **Sideload (until the feed exists):** download the `.apk` from Releases,
   **System → Software → "Upload Package…"** (or via SSH `apk add --allow-untrusted ./…apk`).

---

## Versioning

- **SemVer** in `PKG_VERSION` (start `0.1.0`), release = git tag; `PKG_RELEASE` for rebuilds without a
  source change. `luci-app-*` has its own version and depends on `ifwatchdog` via `DEPENDS`.
- `CHANGELOG.md` follows Keep a Changelog.
- **`ifwatchdog/Makefile` pulls from the tagged GitHub release** (`PKG_SOURCE_URL`/`PKG_SOURCE`/`PKG_HASH`
  against `github.com/one7two99/ifwatchdog/archive/refs/tags/vX.Y.Z.tar.gz`), not the repo's live HEAD —
  required by `openwrt/packages`' contribution guidelines. On every version bump: push the matching
  `vX.Y.Z` tag **first**, then recompute `PKG_HASH` against that tag's real archive and update
  `PKG_VERSION`/`PKG_HASH` together (the build fails closed on a hash mismatch, so a forgotten update is
  loud, not silent). `luci-app-ifwatchdog/Makefile` is unaffected — LuCI apps are conventionally vendored
  directly in whichever repo hosts them, no `PKG_SOURCE` needed.

---

## Test / verification

1. Sideload the `.apk` → `/etc/config/ifwatchdog` + init present; `service ifwatchdog start`.
2. An instance with `method=both` → no action while healthy; the status JSON shows a fresh handshake age.
3. **Simulate a stall** (block the endpoint / age the handshake) → after `failures`×`interval` **one**
   `ifup`, tunnel fresh, the fail-closed network back within ~1–2 min; `logread | grep ifwatchdog` clean.
4. **Debounce/breaker** hold: no ifup loop on a persistent outage.
5. **GUI**: the interface dropdown lists real devices; saved values take effect; live status updates.
6. **noarch confirmed**: the `.apk` installs regardless of the target.

---

## Open items / later

- **Signing-key handling** in CI (secret, rotation, key docs in the README).
- **`interface` = L3 device vs. UCI network**: keep the mapping consistent (wg/ping need the device,
  `ifup` needs the network).
- **Submission to `openwrt/packages`/`openwrt/luci`**: attempted (PR openwrt/packages#30593,
  openwrt/luci#9068) and withdrawn — their automated Formality Check hard-requires a "First Last"-style
  author/committer name (a bare GitHub handle is rejected, not just discouraged), which the maintainer
  chose not to provide. The prepared branches still exist on the forks (`one7two99/packages` branch
  `add-ifwatchdog`, `one7two99/luci` branch `add-luci-app-ifwatchdog`); resubmission is a `commit --amend`
  away if that decision ever changes. Not pursued further otherwise.

---

## Milestones

1. **M1 — base service** (`ifwatchdog`): UCI + procd + check script; stall fix proven. ✅ done.
2. **M2 — GUI** (`luci-app-ifwatchdog`): form + interface dropdown + live status. ✅ done.
3. **M3 — CI + feed**: split into two halves. **CI (shellcheck + `tests/run.sh` on every push/PR)** is
   ✅ done (`.github/workflows/ci.yml`). **A signed feed with an automated SDK build + Pages publish**
   is still not done — the `.apk` build itself works and has been used repeatedly (`ifwatchdog/Makefile`
   pulls from a tagged GitHub release, builds cleanly via the OpenWrt SDK, and has been sideloaded onto
   production hardware via `apk add --allow-untrusted` for every release from v0.2.1 onward), but there
   is no CI job that builds and publishes it automatically, and no `System → Software` one-click install.
4. **M4 — polish / release `0.1.0`**: superseded by how the project actually shipped — instead of one
   gated "0.1.0 polish" release, every meaningful change since has gone out as its own tagged point
   release (`v0.1.0` through the current `v0.2.4`, see `CHANGELOG.md`), each backed by the regression
   suite and, from `v0.2.0` onward, extensive real-hardware on-device UAT (`docs/UAT.md`).
