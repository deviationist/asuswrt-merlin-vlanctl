#!/bin/sh
# install.sh — vlanctl installer for Asuswrt-Merlin.
#
# Run ON the router (after enabling SSH + JFFS scripts, see README):
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-vlanctl/main/install.sh | sh
#
# Or from a clone of this repo copied to the router:
#   sh install.sh
#
# Uninstall (removes the watchdog, hooks, state, alias — and returns every
# assigned port to the main LAN):
#   sh install.sh uninstall

REPO_RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-vlanctl/main"
DEST=/jffs/scripts
SS=$DEST/services-start
SEE=$DEST/service-event-end
CRU_ID=vlanctl-wd
PROFILE=/jffs/configs/profile.add
ALIAS_TAG="# vlanctl"
HOOK_LINE="$DEST/vlanctl hook \"\$1\" \"\$2\"   $ALIAS_TAG"
CRU_LINE="cru a $CRU_ID \"* * * * * $DEST/vlanctl watchdog\"   $ALIAS_TAG"

fail() { echo "ERROR: $1" >&2; exit 1; }

[ -d /jffs ] || fail "no /jffs mount — is this an Asuswrt-Merlin router?"

if [ "$1" = "uninstall" ]; then
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
    # Let the firmware rebuild its own defaults: every port back on the main LAN.
    service restart_apg_eth_vlan >/dev/null 2>&1
    echo "vlanctl uninstalled; switch VLANs reset to firmware defaults."
    echo "(devices on formerly assigned ports keep their old lease until they re-DHCP)"
  else
    echo "vlanctl uninstalled. (nothing was assigned; switch left as is)"
  fi
  exit 0
fi

[ "$(nvram get jffs2_scripts)" = "1" ] || fail "JFFS custom scripts are disabled.
Enable: Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
hit Apply, then re-run this installer."

case "$(nvram get productid)" in
  RT-BE92U) ;;
  *) fail "model $(nvram get productid) has no port map yet — see AGENTS.md 'Adding a model'." ;;
esac
which rtkswitch >/dev/null 2>&1 || fail "no rtkswitch applet — this model has no external Realtek switch."

# append_line <file> <line> — create with a shebang if missing, never fuse onto
# a last line without a newline, and refuse a file that ends in `exit` (our
# line would never run).
append_line() {
  if [ ! -f "$1" ]; then printf '#!/bin/sh\n' > "$1"; chmod 755 "$1"; fi
  grep -qF "$2" "$1" && return 0
  if grep -v '^[[:space:]]*$' "$1" | tail -n 1 | grep -q '^[[:space:]]*exit'; then
    fail "$1 ends with 'exit' — add this line above it by hand, then re-run:
  $2"
  fi
  [ -n "$(tail -c 1 "$1")" ] && echo >> "$1"
  echo "$2" >> "$1"
}

mkdir -p "$DEST"
for f in vlanctl; do
  if [ -f "./scripts/$f" ]; then
    cp "./scripts/$f" "$DEST/$f.new"
  else
    curl -fsSL "$REPO_RAW/scripts/$f?cb=$(date +%s)" -o "$DEST/$f.new" || fail "download of $f failed"
  fi
  # Never replace a working script with a truncated or broken one.
  [ -s "$DEST/$f.new" ] && sh -n "$DEST/$f.new" || { rm -f "$DEST/$f.new"; fail "$f is empty or does not parse — not installed"; }
  chmod 755 "$DEST/$f.new"
  # mv, never overwrite in place: a running watchdog may be reading the old file.
  mv "$DEST/$f.new" "$DEST/$f"
done

# Watchdog (re-added every boot by services-start: cru entries do not persist)
# and the fast path after firmware VLAN rebuilds.
append_line "$SS" "$CRU_LINE"
append_line "$SEE" "$HOOK_LINE"

mkdir -p /jffs/configs
[ -f "$PROFILE" ] || { : > "$PROFILE"; chmod 644 "$PROFILE"; }
grep -q "^alias vlanctl=" "$PROFILE" || echo "alias vlanctl='$DEST/vlanctl'   $ALIAS_TAG" >> "$PROFILE"

cru a "$CRU_ID" "* * * * * $DEST/vlanctl watchdog"

echo ""
"$DEST/vlanctl" status

cat <<'EOF'

Installed. Nothing is assigned until you say so:

  vlanctl ports              # which label is which switch port, link status
  vlanctl status             # your SDN profiles' VLAN ids + live switch table
  vlanctl add LAN2 <vid>     # LAN2 untagged into that SDN profile's VLAN
  vlanctl del LAN2           # back to the main LAN
  sh install.sh uninstall    # remove everything, reset switch to defaults
EOF
