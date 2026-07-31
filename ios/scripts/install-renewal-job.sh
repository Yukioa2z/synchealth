#!/bin/zsh

set -euo pipefail
usage() { echo "Usage: $0 --xcode-device ID --core-device ID --bundle-id ID" >&2; exit 64; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
xcode_device=""; core_device=""; bundle_id=""
while (( $# )); do
  case "$1" in
    --xcode-device) xcode_device="${2:-}"; shift 2 ;;
    --core-device) core_device="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$xcode_device" && -n "$core_device" && -n "$bundle_id" ]] || usage

runtime="$HOME/Library/Application Support/SyncHealth-renewal"
agents="$HOME/Library/LaunchAgents"
plist="$agents/com.synchealth.renew.plist"
service="gui/$(id -u)/com.synchealth.renew"
umask 077
mkdir -p "$runtime/source" "$agents"
rsync -a --delete "$root/ios/" "$runtime/source/ios/"
install -m 755 "$root/ios/scripts/resign-install.sh" "$runtime/resign-install.sh"
cat > "$runtime/config.env" <<EOF
XCODE_DEVICE_ID='$xcode_device'
CORE_DEVICE_ID='$core_device'
BUNDLE_ID='$bundle_id'
EOF
sed "s|__HOME__|$HOME|g" "$root/ios/scripts/com.synchealth.renew.plist" > "$plist"
launchctl bootout "$service" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl enable "$service"
echo "Installed daily SyncHealth renewal job."
