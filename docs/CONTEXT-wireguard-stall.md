# Background: why ifwatchdog?

> The motivation for this project — generalized (no concrete addresses/topology).

## The problem

A network can egress a subnet **fail-closed, exclusively** through a WireGuard tunnel (e.g. ProtonVPN)
— a deliberate kill switch: no tunnel, no egress.

If the uplink sits behind **CGNAT** (e.g. cellular, double NAT), such a long-lived WireGuard tunnel can
**stall silently**:

- The carrier re-assigns the outer NAT binding periodically or after a brief radio blip → the
  **return path breaks** and the tunnel **goes quiet**.
- WireGuard **logs nothing** and **does not self-heal** (silent by design). `persistent_keepalive`
  only guards against idle expiry, **not** against active NAT rebinding.
- The interface stays administratively **"up"** — so there is no "down" event to key off.

Result: the fail-closed subnet is **completely offline**, while the router and directly routed
networks stay online — until the tunnel is restarted **by hand**. Minutes quickly turn into half an
hour of downtime.

## Why built-ins don't fit cleanly

- **`watchcat`** restarts interfaces on ping failure, but **does not bind the ping to the interface**
  and has **no notion of WireGuard handshake age**. In a fail-closed / policy-routing setup where the
  router itself routes directly over WAN, a normal ping tests the **wrong path**.
- **`mwan3`** is multi-WAN **failover** — contrary to a deliberate fail-closed design.
- **Policy routing (`pbr`)** only reacts to **administrative** up/down of the interface; it does not
  notice the silent stall (the interface stays "up").

## The solution (= this project)

A watchdog that detects the failure **through the tunnel** and restarts it in a targeted way:

- an **interface-bound ping** (`ping -I <iface>`) — actually tests the tunnel path, not the WAN link;
- the **WireGuard handshake age** (`wg show <iface> latest-handshakes`) as an additional or
  alternative signal;
- on a detected stall, a targeted **`ifup <iface>`** (forces a fresh handshake), guarded by a
  **monitor default**, an **interface denylist**, **debounce** and a **circuit breaker**.

This turns a long stall into **self-healing within ~1–2 check cycles** — without weakening the kill
switch. That is exactly what `ifwatchdog` implements (details in [`SPEC.md`](SPEC.md)).
