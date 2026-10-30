#!/bin/sh
# uninstall.sh — remove vlanctl completely from an Asuswrt-Merlin router.
#
# Run ON the router:
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-vlanctl/main/uninstall.sh | sh
#
# Removes: the control script, the cron watchdog, the services-start line, the
# service-event-end line, the shell alias, the config, the history and runtime
# state. If any port was assigned, lets the firmware rebuild its switch VLAN
# defaults, which returns every assigned port to the main LAN.

DEST=/jffs/scripts
SS=$DEST/services-start
SEE=$DEST/service-event-end
CRU_ID=vlanctl-wd
PROFILE=/jffs/configs/profile.add
ALIAS_TAG="# vlanctl"

_had=$(sed -n 's/^ACCESS_PORTS="\(.*\)"/\1/p' "$DEST/vlanctl.conf" 2>/dev/null)

cru d "$CRU_ID" 2>/dev/null
# Let a watchdog that is mid-heal finish before pulling the rug.
_i=0; while [ -d /tmp/vlanctl/lock.d ] && [ "$_i" -lt 30 ]; do sleep 1; _i=$((_i + 1)); done
[ -f "$SS" ] && sed -i "/^cru a $CRU_ID /d" "$SS"
[ -f "$SEE" ] && sed -i "\\|^$DEST/vlanctl hook |d" "$SEE"
[ -f "$PROFILE" ] && sed -i "/^alias vlanctl=.*$ALIAS_TAG\$/d" "$PROFILE"

rm -f "$DEST/vlanctl" "$DEST/vlanctl.conf" "$DEST/vlanctl.history"
rm -rf /tmp/vlanctl

if [ -n "$_had" ]; then
  service restart_apg_eth_vlan >/dev/null 2>&1
  logger -t vlanctl "uninstalled; switch VLANs reset to firmware defaults" 2>/dev/null
  echo "vlanctl uninstalled; switch VLANs reset to firmware defaults."
else
  logger -t vlanctl "uninstalled" 2>/dev/null
  echo "vlanctl uninstalled. (nothing was assigned; switch left as is)"
fi
echo "(services-start / service-event-end kept, minus our lines; the 'vlanctl' alias stays live in THIS shell until you log out)"
