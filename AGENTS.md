# AGENTS.md — guidance for AI coding agents working on this repo

This repo ships shell scripts that run on **Asuswrt-Merlin routers under
busybox `sh`**, and they reprogram the router's Ethernet switch. A wrong write
can disconnect wired hosts — including the one you are SSHing through. Read this
before editing anything.

Sibling projects (same author, platform and house style):
[`nat-doctor`](https://github.com/deviationist/asuswrt-merlin-nat-doctor),
[`flowcache-doctor`](https://github.com/deviationist/asuswrt-merlin-flowcache-doctor),
[`accessctl`](https://github.com/deviationist/asuswrt-merlin-accessctl).

## Hard constraints

- **busybox `sh` only.** No bash, no arrays, no `[[`, no process substitution.
  `sh -n` on every script is the lint; also run the tests under `dash`.
- **No `command` builtin, no `timeout`, no `pgrep`/`pkill`** on the router.
  Probe with `which`. Find own processes by pidfile + `/proc/<pid>`, never
  `ps | grep`.
- **JFFS is flash.** Runtime state goes to `/tmp/vlanctl`. The only `/jffs`
  writes are the operator's config (by `add`/`del` only) and the history file
  (only when a re-apply actually happens).
- **No deployment specifics in the repo** — no real IPs, MACs, hostnames,
  SSIDs or VLAN assignments, not even in comments, examples or fixtures. A
  user's assignments live in `/jffs/scripts/vlanctl.conf` on their router,
  which the installer never writes and `.gitignore` excludes. Hardware facts
  about a *model* (its port map) are not deployment specifics and belong here.
- **Every artifact is inventoried** and **both uninstall paths**
  (`install.sh uninstall`, `uninstall.sh`) remove all of it.
- **Never overwrite a script in place** — busybox reads scripts incrementally.
  Install to `.new` and `mv`.

## Design invariants (do not weaken)

- **When in doubt, do nothing.** Unsupported model, unknown port label, a VID
  that is not an SDN profile's (`vlan_rl`), a target VLAN the firmware has not
  programmed, any unreadable switch answer: SKIP, zero writes. Tests 5–9, 14
  and 18 pin each of these; a new gate needs a new zero-writes fixture.
- **Read everything, gate, then write.** `apply_one` reads the target VLAN,
  VID 0, the PVID and every other SDN VLAN *before its first write*, and
  refuses if VID 0 or the target lacks the CPU port (unprogrammed or
  mid-rebuild). Masks computed from an empty VID 0 would cut off every wired
  host. Other SDN VLANs are written only if programmed AND carrying the port
  (test 15); unchanged masks are not rewritten (test 2).
- **Never hard-code masks.** Every write is computed from the live switch
  state (`plan_*` are pure functions over what was just read), touching only
  the assigned port's bit. Hard-coded masks would silently undo whatever the
  firmware (or a future firmware) puts on the other ports. Test 10 pins that
  unassigned ports are untouched.
- **Join before leave.** `apply_one` makes the port an untagged member of the
  target VLAN and sets its PVID *before* removing it from VID 0, so there is no
  instant where the port belongs to no VLAN.
- **Untagged-only ingress on assigned ports** (`rtkswitch 3953`). Without it a
  device could send frames tagged with another VLAN id and hop networks.
- **Read answers must be fresh.** The driver answers on the kernel log. Every
  read first writes a unique marker to `/dev/kmsg` and parses only lines after
  it, so a failed ioctl can never be mistaken for an answer by re-reading a
  stale line, and a wrapped ring buffer cannot blind the check. (Counting
  matching lines before/after fails both ways: a stale line passes once the
  count is past any threshold, and a full ring stops the count growing.)
- **Quiet when healthy.** Every switch read prints to the kernel log, which
  syslogd copies into `/tmp/syslog.log` — the log every other addon relies on.
  The per-minute watchdog therefore reads the switch only when a `createVlan`
  kernel line is newer than our last verdict line, or every `VERIFY_EVERY`
  seconds. Test 12 pins zero reads otherwise. Do not "simplify" this into a
  read every minute.
- **One verdict per verification, and only an honest one.** `APPLIED` /
  `VERIFIED` only when every port checked out; otherwise `UNRESOLVED`, which
  schedules a re-check after `RETRY_EVERY` instead of `VERIFY_EVERY`. A
  transient unreadable read must never buy an hour of silence with a port on
  the main LAN (test 17). Manual `check`/`status` never touch watchdog state.
- **One lock for every writer.** `mkdir`-atomic, taken by `watchdog`,
  `apply`, `add` and `del`, with pid + start time so a hung or recycled-pid
  holder is taken over after `LOCK_STALE` (test 19).
- **Bounded, per port.** `MAXHEALS` re-applies per `WINDOW` per port, then
  stand down (history on the transition only). A shared budget would let one
  flapping port silence the others.
- **`del` and uninstall reset via the firmware** (`service
  restart_apg_eth_vlan`), never by reconstructing "defaults" ourselves.
- **FAIL_CLOSED is opt-in.** Powering a port down is the only action not
  backed by the firmware's own configuration.

## Verified platform facts (RT-BE92U, Merlin 3006.102.8)

Re-verify before relying on any of these on another model.

- LAN ports are on an external **Realtek RTL8372** (`rtl8372.ko`), driven via
  `/dev/rtkswitch` and the `rtkswitch` applet (a symlink to `rc`). The
  Broadcom-side `ethswctl` tables are NOT where LAN VLANs live — reading them
  shows empty VLAN tables and an ARL with only the router's own MAC.
- Userspace source: `release/src/router/shared/sysdeps/broadcom/rtkswitch.c`
  in RMerl/asuswrt-merlin.ng. Almost every command takes ONE int, so
  multi-field VLAN writes pack it: **arg = (untag_mask << 16) | member_mask**,
  with the VID selected first by `rtkswitch 36 <vid>`. Verified by creating,
  reading back and deleting a scratch VLAN (`3900`, `399`, `3901`).
- Commands used: `36` select VID, `399` dump mbr/untag, `390` create without
  PVID (rc's variant for SDN VLANs), `3902` create with CPU in mbr/untag
  (rc's variant for VID 0), `3911 <mask>` set PVID of masked ports to the
  selected VID, `393` dump PVIDs, `3953 <mask>` untagged-only ingress,
  `13`/`12 <lanidx>` power a port down/up, `2 <lanidx>` MAC status.
- `771 <mac>` (find the port of a MAC) exists in source but is **not** in this
  build — no output.
- `3953 <mask>` sets accept-type only for the masked ports (`396` afterwards:
  p5 `vf_type 2` = untagged-only, p4/p6/p7 still `0`). The firmware rebuild
  resets it.
- Writing to `/dev/kmsg` as root works and appears in `dmesg` in order with
  the driver's answers — the basis of the freshness markers.
- Firmware layout at rest: VID 0 = main LAN, mbr/untag `0xE8`; every SDN VLAN
  tagged on `0xE8`; PVID 0 on p5–p7; p4 PVID 4094 (`vlan4094`, not in VID 0).
  `0xE8` = p3 (CPU uplink, 2.5G) + p5 + p6 + p7.
- Port map: **p5 = LAN2** proven (only 100M link, matches `ATE
  Get_WanLanStatus`, moving it moved the 100M device). **p6 = LAN3, p7 = LAN4
  inferred** from rtkswitch LAN-index order, NOT individually proven. LAN1 is
  unsupported (p4/vlan4094 path). The rtkswitch LAN index is NOT the
  front-panel number (index 1 = p5 = LAN2).
- The firmware rebuilds the whole table on `service restart_apg_eth_vlan`,
  at boot and on SDN changes, logging `createVlan_*` / `set_ports_pvid` kernel
  lines. Assignments made outside nvram are lost each time.
- The SDN GUI's `lanport` field in `apgN_dut_list` (`<mac>band>lanport`) is
  ignored on a standalone router — five formats tested, rc never set an
  access mask. It appears to serve AiMesh only.

## Adding a model

1. Confirm `rtkswitch` exists and `rtkswitch 36 0; rtkswitch 399; dmesg | tail`
   prints a VID 0 entry.
2. Read PVIDs (`393`) and per-port link (`2 <idx>` for each index), and map
   front-panel labels by link speed or by unplugging one cable at a time.
3. Identify the CPU-uplink bit (in every VLAN's member mask, no front-panel
   label).
4. Add a `model_map` case and a gate in `install.sh`; document what was
   *proven* versus *inferred*, as above.

## Testing

- `for f in install.sh uninstall.sh scripts/vlanctl tests/invariant.sh; do sh -n "$f"; done`
- `sh tests/invariant.sh` and `dash tests/invariant.sh` — a simulated RTL8372
  reproducing the driver contract above.
- **Negative control** — the fixtures must still have teeth:

  ```sh
  sed 's|^plan_lan()    {.*|plan_lan() { NMBR=$1; NUNTAG=$2; }|' scripts/vlanctl > /tmp/vlanctl-broken
  VLANCTL_SRC=/tmp/vlanctl-broken sh tests/invariant.sh   # must fail
  ```

- Real validation is on a router over SSH, with **out-of-band access** (Wi-Fi
  or console) — a bad write can cut the wired port you are connected through.

## Release checklist

Bump `VERSION` in `scripts/vlanctl`, tag `vX.Y.Z`, GitHub Release. Docs-only
changes get no release. `raw.githubusercontent.com` can lag a push by minutes.
