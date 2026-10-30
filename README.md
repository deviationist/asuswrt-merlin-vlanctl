# asuswrt-merlin-vlanctl

Put a wired LAN port into a **Guest Network Pro (SDN)** network on
Asuswrt-Merlin — the per-port VLAN assignment the GUI does not offer on a
standalone router — and keep it there every time the firmware rebuilds its
switch VLANs.

Typical use: a smart TV, games console or other IoT device that is wired to
the router but should live on the isolated IoT network (internet only, no LAN,
no router admin), not on your main LAN next to your NAS and laptops.

> **Supported model: RT-BE92U** (Merlin 3006.102.8). Other models are refused
> until someone maps their switch ports — see [AGENTS.md](AGENTS.md#adding-a-model).

## The problem

Guest Network Pro gives each profile its own VLAN, bridge, subnet, DHCP and
firewall isolation, and the firmware already carries those VLANs *tagged* on
every LAN port. What is missing is a way to say *"this port is an untagged
member of the IoT VLAN"*:

- the **LAN → VLAN** page that would do it is not shipped on every
  model/firmware (absent on the RT-BE92U);
- the hidden `lanport` field in the profile's device list is ignored outside
  AiMesh;
- programming the switch by hand works, but the firmware silently undoes it at
  every boot and every SDN change — and the device just lands back on your
  main LAN with nothing telling you.

## What vlanctl does

- Programs the router's external Realtek switch with the same `rtkswitch`
  calls the firmware itself uses: the port becomes an **untagged member of the
  profile's VLAN**, its PVID is set to it, it is removed from the main LAN and
  every other SDN VLAN, and it accepts **untagged frames only** (no VLAN
  hopping).
- Computes every mask from the live switch state and touches only the
  assigned port's bit.
- Re-asserts the assignment seconds after any firmware VLAN rebuild
  (`service-event-end` hook), with a per-minute watchdog as a backstop.
- **Quiet when healthy**: switch reads print to the kernel log, so it reads
  the switch only after the firmware has visibly rebuilt the table, or hourly.
- **When in doubt, does nothing**: unknown model, unknown port, a VLAN that is
  not an SDN profile's, a profile that was deleted, an unreadable switch —
  all skipped, zero writes. Optional `FAIL_CLOSED=1` powers the port down
  instead of leaving the device on the LAN.

Your assignments live only in `/jffs/scripts/vlanctl.conf` on the router.

## Install

Prerequisites (router web UI, Administration → System): *Enable JFFS custom
scripts and configs* = Yes, *Enable SSH* = LAN only. Have **out-of-band
access** (Wi-Fi) while experimenting: a wrong port can be the one you are
wired through.

On the router:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-vlanctl/main/install.sh | sh
```

Then:

```sh
vlanctl ports          # labels, switch ports, PVIDs, link status
vlanctl status         # your SDN profiles' VLAN ids + live switch table
vlanctl add LAN2 101   # LAN2 -> the SDN profile on VLAN 101
```

The device on that port is power-cycled off the port briefly so it re-DHCPs
into the profile's subnet.

## Commands

| Command | |
|---|---|
| `vlanctl status` | model, assignments, live switch VLAN table, check |
| `vlanctl check` | verify each assignment (exit 0 ok, 1 drifted, 2 unknown) |
| `vlanctl ports` | front-panel label → switch port, PVID, link status |
| `vlanctl add <port> <vid>` | assign and persist |
| `vlanctl del <port>` | back to the main LAN, persist |
| `vlanctl apply` | program all assignments now (idempotent) |
| `vlanctl log` / `history` | recent syslog lines / durable record of re-applies |

## Configuration

`/jffs/scripts/vlanctl.conf` (see [`vlanctl.conf.example`](vlanctl.conf.example)).
The installer never writes it; `add`/`del` rewrite only `ACCESS_PORTS`.

| Setting | Default | |
|---|---|---|
| `ACCESS_PORTS` | empty | `<port>:<vid>` pairs, e.g. `LAN2:101` |
| `FAIL_CLOSED` | `0` | `1` = power the port down if its VLAN disappears |
| `VERIFY_EVERY` | `3600` | backstop full check interval, seconds |
| `RETRY_EVERY` | `300` | re-check this soon after an unresolved check |
| `MAXHEALS` / `WINDOW` | `6` / `3600` | per-port re-apply budget before standing down |

## Port map (RT-BE92U)

| Label | Switch port | Status |
|---|---|---|
| LAN2 | p5 | proven |
| LAN3 | p6 | inferred — confirm with `vlanctl ports` + unplugging |
| LAN4 | p7 | inferred — confirm with `vlanctl ports` + unplugging |
| LAN1 | p4 | unsupported |

## What you give up

A device on an isolated SDN network cannot be reached from your main LAN:
casting/AirPlay from phones, DLNA, and LAN-side control apps stop working for
it. Media servers on the LAN are reached via your public address and port
forwards, if at all — e.g. Plex then treats the device as remote unless you
add the SDN subnet to Plex's *LAN Networks*.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-vlanctl/main/uninstall.sh | sh
```

Removes every artifact below and lets the firmware rebuild its switch
defaults, returning every assigned port to the main LAN.

| Artifact | Where |
|---|---|
| control script | `/jffs/scripts/vlanctl` |
| config | `/jffs/scripts/vlanctl.conf` |
| history | `/jffs/scripts/vlanctl.history` |
| watchdog | `cru` entry `vlanctl-wd` + its line in `/jffs/scripts/services-start` |
| fast hook | its line in `/jffs/scripts/service-event-end` |
| alias | its line in `/jffs/configs/profile.add` |
| runtime state | `/tmp/vlanctl` |

## License

MIT
