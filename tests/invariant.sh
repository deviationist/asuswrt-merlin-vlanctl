#!/bin/sh
# tests/invariant.sh — drive vlanctl against a simulated RTL8372.
#
# The fake switch reproduces the driver's observable contract, as verified on
# a real RT-BE92U: answers go to the kernel log (dmesg), `36 <vid>` selects the
# VLAN for the next call, VLAN writes take (untag << 16) | mbr, `3911 <mask>`
# sets PVID to the selected VID, `393` dumps PVIDs of p4..p7. Userspace
# markers written to /dev/kmsg appear in dmesg in order.
#
# VLAN ids 101/102/103 are arbitrary fixtures, not anyone's network.
#
#   sh tests/invariant.sh                            # all cases
#   VLANCTL_SRC=/tmp/broken sh tests/invariant.sh    # negative control

SRC=${VLANCTL_SRC:-$(dirname "$0")/../scripts/vlanctl}
T=$(mktemp -d 2>/dev/null || echo /tmp/vlanctl-test.$$)
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
expect() { [ "$2" = "$3" ] && ok || bad "$1: expected '$3', got '$2'"; }

# --- fake platform ------------------------------------------------------------
factory_vlans() {
	S_0_M=232 S_0_U=232                       # VID 0: 0xE8 / 0xE8
	S_101_M=232 S_101_U=0 S_102_M=232 S_102_U=0 S_103_M=0 S_103_U=0
	PV_4=4094 PV_5=0 PV_6=0 PV_7=0
}
factory() {
	factory_vlans
	CUR=0; : > "$T/dmesg"; : > "$T/writes"; : > "$T/syslog"; : > "$T/history"
	rm -rf "$T/run"; mkdir -p "$T/run"
	PRODUCT=RT-BE92U; VLAN_RL='<1>101>0><2>102>0>'; READ_BROKEN=0
	FAIL_CLOSED=0; ACCESS_PORTS=""
}

nvram() {
	case "$2" in
		productid) echo "$PRODUCT" ;;
		vlan_rl)   echo "$VLAN_RL" ;;
	esac
}

rtkswitch() {
	case "$1" in
		36)   CUR=$2 ;;
		399)  [ "$READ_BROKEN" = 1 ] && return 1
		      eval "_m=\${S_${CUR}_M:-0} _u=\${S_${CUR}_U:-0}"
		      printf 'get vlan mbr/untag - vid = %s, mbrmsk = 0x%X untagmsk = 0x%X\n' "$CUR" "$_m" "$_u" >> "$T/dmesg" ;;
		390|3902)
		      _a=$(( $2 )); eval "S_${CUR}_M=$(( _a & 0xFFFF )) S_${CUR}_U=$(( _a >> 16 ))"
		      echo "$1 vid=$CUR $2" >> "$T/writes" ;;
		3911) _a=$(( $2 ))
		      for p in 4 5 6 7; do [ $(( _a & (1 << p) )) -ne 0 ] && eval "PV_$p=$CUR"; done
		      echo "3911 vid=$CUR $2" >> "$T/writes" ;;
		393)  [ "$READ_BROKEN" = 1 ] && return 1
		      for p in 4 5 6 7; do eval "echo \"rtl8372_ioctl, p$p pvid=\$PV_$p, priv=0\""; done >> "$T/dmesg" ;;
		3953|13|12) echo "$1 $2" >> "$T/writes" ;;
	esac
}
dmesg()   { cat "$T/dmesg"; }
logger()  { shift 2; echo "Jan  1 00:00:00 vlanctl: $*" >> "$T/syslog"; }
sleep()   { :; }
service() { echo "service $*" >> "$T/writes"; factory_vlans; }
cru()     { :; }
ATE()     { echo "W0=G;L1=X;L2=M;L3=G;L4=G;"; }

writes() { grep -cvE '^(13|12) ' "$T/writes"; }
# Commands take the lock and install an EXIT trap, as in a real process. In
# this single test shell, release both after each call.
run() { "$@"; _rr=$?; lock_drop; trap 'rm -rf "$T"' EXIT; trap - INT TERM; return $_rr; }

# --- load vlanctl as a library ---------------------------------------------------
export VLANCTL_LIB=1 VLANCTL_CONF="$T/conf" VLANCTL_RUN="$T/run" \
       VLANCTL_HISTORY="$T/history" VLANCTL_SYSLOG="$T/syslog" VLANCTL_KMSG="$T/dmesg" VLANCTL_PROC="$T/proc"
: > "$T/conf"
factory
. "$SRC"

# 1. Fresh firmware state, one assignment: exact masks after apply.
factory; ACCESS_PORTS="LAN2:102"
run cmd_apply >/dev/null
expect "1 VID0 mbr"     "$S_0_M"   $((0xC8))
expect "1 VID0 untag"   "$S_0_U"   $((0xC8))
expect "1 VID102 mbr"   "$S_102_M" $((0xE8))
expect "1 VID102 untag" "$S_102_U" $((0x20))
expect "1 VID101 mbr"   "$S_101_M" $((0xC8))
expect "1 PVID p5"      "$PV_5"    102
expect "1 PVID p6"      "$PV_6"    0
expect "1 p4 untouched" "$PV_4"    4094
grep -q '^3953 0x20$' "$T/writes" && ok || bad "1 untag-only not set on p5"
cmd_check >/dev/null; expect "1 check after apply" "$?" 0
grep -q 'vlanctl: APPLIED' "$T/syslog" && ok || bad "1 no APPLIED marker"

# 2. Idempotent: a second apply on an applied switch writes nothing.
: > "$T/writes"
run cmd_apply >/dev/null
expect "2 no writes when already applied" "$(writes)" 0

# 3. Firmware rebuild puts the port back: check reports drift (1), read-only.
factory_vlans; : > "$T/writes"; rm -f "$T/run/lastverify"
cmd_check >/dev/null; expect "3 drift detected" "$?" 1
expect "3 check writes nothing" "$(writes)" 0
[ -f "$T/run/lastverify" ] && bad "3 check touched watchdog state" || ok

# 4. Watchdog heals drift and records history.
run cmd_watchdog
expect "4 healed VID0" "$S_0_M" $((0xC8))
grep -q REAPPLIED "$T/history" && ok || bad "4 no REAPPLIED history line"

# 5. Unsupported model: refuse, zero writes.
factory; PRODUCT=RT-XX000; ACCESS_PORTS="LAN2:102"
run cmd_apply >/dev/null; expect "5 unsupported model writes" "$(writes)" 0

# 6. VID that is not an SDN profile VLAN: refuse, zero writes.
factory; ACCESS_PORTS="LAN2:999"
run cmd_apply >/dev/null; expect "6 non-SDN vid writes" "$(writes)" 0

# 7. Unknown port label: refuse, zero writes.
factory; ACCESS_PORTS="LAN9:102"
run cmd_apply >/dev/null; expect "7 unknown port writes" "$(writes)" 0

# 8. Target VLAN declared but not programmed (profile disabled): no writes...
factory; S_102_M=0; ACCESS_PORTS="LAN2:102"
run cmd_apply >/dev/null; expect "8 vlan gone writes" "$(writes)" 0
grep -q '^13 ' "$T/writes" && bad "8 port powered down without FAIL_CLOSED" || ok
# ...unless FAIL_CLOSED=1, which powers the port down and nothing else.
: > "$T/writes"; FAIL_CLOSED=1
run cmd_apply >/dev/null
grep -q '^13 1$' "$T/writes" && ok || bad "8 FAIL_CLOSED did not power down LAN2"
expect "8 FAIL_CLOSED vlan writes" "$(writes)" 0

# 9. Unreadable switch: never write on a guess.
factory; READ_BROKEN=1; ACCESS_PORTS="LAN2:102"
run cmd_apply >/dev/null; expect "9 unreadable switch writes" "$(writes)" 0

# 10. Two ports: both moved, the third untouched.
factory; ACCESS_PORTS="LAN2:102 LAN3:101"
run cmd_apply >/dev/null
expect "10 VID0 mbr"        "$S_0_M"   $((0x88))
expect "10 VID101 untag"    "$S_101_U" $((0x40))
expect "10 VID102 untag"    "$S_102_U" $((0x20))
expect "10 VID101 lacks p5" $(( S_101_M & 0x20 )) 0
expect "10 VID102 lacks p6" $(( S_102_M & 0x40 )) 0
expect "10 p7 PVID"         "$PV_7" 0

# 11. Rebuild detector: quiet after any verdict, wakes after a rebuild.
printf 'x kernel: createVlan_nopvid : vid = 102\nx vlanctl: APPLIED LAN2:102\n' > "$T/syslog"
firmware_rebuilt; expect "11 no rebuild" "$?" 1
echo 'x kernel: createVlan_nopvid : vid = 102' >> "$T/syslog"
firmware_rebuilt; expect "11 rebuild seen" "$?" 0
echo 'x vlanctl: UNRESOLVED LAN2:102' >> "$T/syslog"
firmware_rebuilt; expect "11 unresolved counts as verdict" "$?" 1
: > "$T/syslog"
firmware_rebuilt; expect "11 rotated log -> verify" "$?" 0

# 12. Healthy watchdog with no rebuild and verify not due: zero switch reads.
factory; ACCESS_PORTS="LAN2:102"; run cmd_apply >/dev/null
printf 'x vlanctl: APPLIED LAN2:102\n' > "$T/syslog"; now > "$T/run/lastverify"
: > "$T/dmesg"
run cmd_watchdog
expect "12 quiet watchdog reads" "$(wc -l < "$T/dmesg" | tr -d ' ')" 0

# 13. A rebuild that left the port correct: one verify, then quiet again.
echo 'x kernel: createVlan_nopvid : vid = 102' >> "$T/syslog"
run cmd_watchdog
grep -q 'vlanctl: VERIFIED' "$T/syslog" && ok || bad "13 no VERIFIED marker after clean verify"
: > "$T/dmesg"
run cmd_watchdog
expect "13 quiet after VERIFIED" "$(wc -l < "$T/dmesg" | tr -d ' ')" 0

# 14. VID 0 reads as unprogrammed (mid-rebuild): never write masks from it.
factory; ACCESS_PORTS="LAN2:102"; S_0_M=0; S_0_U=0
run cmd_apply >/dev/null; expect "14 VID0 unprogrammed writes" "$(writes)" 0
expect "14 VID0 left alone" "$S_0_M" 0

# 15. Other SDN VLANs: unprogrammed or not carrying the port -> not written.
factory; VLAN_RL='<1>101>0><2>102>0><3>103>0>'; S_101_M=$((0xC8)); ACCESS_PORTS="LAN2:102"
run cmd_apply >/dev/null
grep -q 'vid=103' "$T/writes" && bad "15 wrote unprogrammed VID 103" || ok
grep -q 'vid=101' "$T/writes" && bad "15 wrote VID 101 that never carried p5" || ok
expect "15 VID 103 still empty" "$S_103_M" 0

# 16. del with another port still assigned bounces the REMOVED port.
factory; ACCESS_PORTS="LAN2:102 LAN3:101"; run cmd_apply >/dev/null
: > "$T/writes"
run cmd_del LAN2 >/dev/null
expect "16 last bounce is LAN2" "$(grep '^13 ' "$T/writes" | tail -1)" "13 1"
expect "16 LAN3 still assigned" "$S_101_U" $((0x40))
expect "16 LAN2 back on VID0" $(( S_0_M & 0x20 )) $((0x20))
expect "16 config rewritten" "$ACCESS_PORTS" "LAN3:101"

# 17. Unreadable switch in the watchdog: no VERIFIED, retry soon, not in 1h.
factory; ACCESS_PORTS="LAN2:102"; READ_BROKEN=1
run cmd_watchdog
grep -q 'vlanctl: VERIFIED' "$T/syslog" && bad "17 VERIFIED after unreadable" || ok
grep -q 'vlanctl: UNRESOLVED' "$T/syslog" && ok || bad "17 no UNRESOLVED marker"
_lv=$(cat "$T/run/lastverify"); _next=$(( _lv + VERIFY_EVERY - $(now) ))
[ "$_next" -le "$RETRY_EVERY" ] && [ "$_next" -gt 0 ] && ok || bad "17 next verify in ${_next}s, want <= $RETRY_EVERY"

# 18. Duplicate labels and non-numeric VIDs: refuse everything, zero writes.
factory; ACCESS_PORTS="LAN2:101 LAN2:102"
run cmd_apply >/dev/null; expect "18 duplicate label writes" "$(writes)" 0
factory; ACCESS_PORTS="LAN2:1*"
run cmd_apply >/dev/null; expect "18 glob vid writes" "$(writes)" 0

# 19. Lock held by a live, fresh holder: apply refuses, zero writes.
factory; ACCESS_PORTS="LAN2:102"
mkdir -p "$T/proc/$$" "$T/run/lock.d"; echo "$$ $(now)" > "$T/run/lock.d/pid"
cmd_apply >/dev/null; expect "19 busy apply rc" "$?" 2
expect "19 busy apply writes" "$(writes)" 0
lock_drop

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
