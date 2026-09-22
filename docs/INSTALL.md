# Installing / uninstalling `ifwatchdog`

There is **no signed package feed yet** (tracked as open work — see `SPEC.md` → *Open items*, milestone
M3). Until then, install by copying the files directly onto the router over SSH. This is the exact
method used for the on-device UAT in `UAT.md`, verified end-to-end on real OpenWrt 25.12.5 hardware.

> ⚠️ Read `UAT.md` first if you're installing on a device you rely on. In particular: do the **pre-flight
> checklist** (console access, a way to disable the service if you get locked out, and config backups)
> *before* enabling any instance with a real action (`ifup`/`script`) — not after. A `monitor`-only
> instance cannot lock you out (it never runs `ifup`), so the pre-flight items 2–4 matter most before
> you flip an instance from `monitor` to `ifup`.

## Prerequisites

- OpenWrt with `procd`, `rpcd`, and LuCI (the JS-based CBI, i.e. current LuCI, not the old Lua one).
- `wireguard-tools` (`wg`) only if you want handshake-based detection (`method=handshake`/`both`); the
  service degrades to ping-only and logs a note if it's missing.
- BusyBox `pgrep` supporting `-P` (parent-pid filter) for full cleanup of a hung `action=script`'s child
  processes; without it, the script's own PID is still killed, just not necessarily its children.

## Install (sideload)

From a checkout of this repo, with `ROUTER` set to your router's address:

```sh
ROUTER=root@192.168.1.1   # adjust

ssh "$ROUTER" 'mkdir -p /www/luci-static/resources/view/ifwatchdog \
    /usr/libexec/rpcd /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/ifwatchdog.d'

ssh "$ROUTER" 'cat > /usr/libexec/ifwatchdog.sh'        < ifwatchdog/files/ifwatchdog.sh
ssh "$ROUTER" 'cat > /etc/init.d/ifwatchdog'            < ifwatchdog/files/ifwatchdog.init
# Only write the UCI defaults if nothing is there yet - never overwrite an existing config:
ssh "$ROUTER" 'test -f /etc/config/ifwatchdog || cat > /etc/config/ifwatchdog' \
    < ifwatchdog/files/ifwatchdog.config

ssh "$ROUTER" 'cat > /www/luci-static/resources/view/ifwatchdog/overview.js' \
    < luci-app-ifwatchdog/htdocs/luci-static/resources/view/ifwatchdog/overview.js
ssh "$ROUTER" 'cat > /usr/libexec/rpcd/ifwatchdog' \
    < luci-app-ifwatchdog/root/usr/libexec/rpcd/ifwatchdog
ssh "$ROUTER" 'cat > /usr/share/luci/menu.d/luci-app-ifwatchdog.json' \
    < luci-app-ifwatchdog/root/usr/share/luci/menu.d/luci-app-ifwatchdog.json
ssh "$ROUTER" 'cat > /usr/share/rpcd/acl.d/luci-app-ifwatchdog.json' \
    < luci-app-ifwatchdog/root/usr/share/rpcd/acl.d/luci-app-ifwatchdog.json

ssh "$ROUTER" '
    chmod +x /etc/init.d/ifwatchdog /usr/libexec/ifwatchdog.sh /usr/libexec/rpcd/ifwatchdog
    rm -f /tmp/luci-indexcache*
    /etc/init.d/rpcd restart
    /etc/init.d/ifwatchdog enable
'
```

Then open **LuCI → Services → ifwatchdog**. The shipped default (`ifwatchdog.config`) is a single
`example` instance with `enabled='0'` and `action='monitor'` — it does nothing until you edit it. Add or
edit an instance, pick the interface from the dropdown, leave `Action` on **Monitor only** for the first
day or two (see `UAT.md`'s staged rollout), then `Save & Apply`.

To start the service (or after any config change that needs the daemon actually running):

```sh
ssh "$ROUTER" '/etc/init.d/ifwatchdog start'   # or: restart
```

### Updating an existing install

Re-run the same block above (it's idempotent) except the `/etc/config/ifwatchdog` line — that one's
guarded by `test -f` specifically so a re-deploy never clobbers your instance configuration. Then:

```sh
ssh "$ROUTER" 'rm -f /tmp/luci-indexcache*; /etc/init.d/rpcd restart; /etc/init.d/ifwatchdog restart'
```

(A hard browser refresh may be needed to pick up a changed `overview.js`, since browsers cache it.)

### Once a signed feed exists (future)

The plan (see `SPEC.md`) is a one-click install: add the feed's public key and URL, then install
`ifwatchdog` + `luci-app-ifwatchdog` from **System → Software**, with a `.apk` attached to GitHub
Releases as a sideload fallback (`apk add --allow-untrusted ./ifwatchdog*.apk`). Neither exists yet;
this document will be updated when they do.

## Uninstall

**Soft removal** (keep your instance configuration around, e.g. to reinstall later):

```sh
ssh "$ROUTER" '
    /etc/init.d/ifwatchdog stop
    /etc/init.d/ifwatchdog disable
'
```

**Full removal** (also deletes your watchdog instance configuration — back it up first if you might want
it again, e.g. `cp /etc/config/ifwatchdog /root/ifwatchdog.uci.bak`):

```sh
ssh "$ROUTER" '
    /etc/init.d/ifwatchdog stop
    /etc/init.d/ifwatchdog disable
    rm -f /etc/init.d/ifwatchdog \
          /usr/libexec/ifwatchdog.sh \
          /usr/libexec/rpcd/ifwatchdog \
          /www/luci-static/resources/view/ifwatchdog/overview.js \
          /usr/share/luci/menu.d/luci-app-ifwatchdog.json \
          /usr/share/rpcd/acl.d/luci-app-ifwatchdog.json \
          /etc/config/ifwatchdog
    rm -rf /var/run/ifwatchdog /usr/libexec/ifwatchdog.d
    rm -f /tmp/luci-indexcache*
    /etc/init.d/rpcd restart
'
```

Once installed via a real package (`.apk`/feed, when that exists), `opkg`/`apk remove ifwatchdog
luci-app-ifwatchdog` will do the equivalent and — per the package manager's normal convention — keep
`/etc/config/ifwatchdog` as a conffile unless you also pass the "purge configs" option.

## Rollback without uninstalling

If a specific instance is doing something you don't want, you don't need to remove the package at all:

```sh
uci set ifwatchdog.<instance>.enabled='0'    # or: .action='monitor'
uci commit ifwatchdog
/etc/init.d/ifwatchdog restart
```

See `UAT.md` → *Rollback* for the full picture, including restoring a `network`/`pbr` backup if an
`ifup` action ever targeted the wrong thing.
