#!/bin/zsh

set -euo pipefail

readonly runtime_dir="${SYNCHEALTH_RENEWAL_HOME:-$HOME/Library/Application Support/SyncHealth-renewal}"
readonly config_file="$runtime_dir/config.env"
readonly source_root="$runtime_dir/source/ios"
readonly project_path="$source_root/FreeReps.xcodeproj"
readonly scheme="FreeReps"
readonly derived_data="$runtime_dir/DerivedData"
readonly success_stamp="$runtime_dir/last-success-epoch"
readonly minimum_interval_seconds=$((5 * 24 * 60 * 60))

[[ -r "$config_file" ]] || { echo "missing renewal configuration: $config_file" >&2; exit 64; }
source "$config_file"
for required in XCODE_DEVICE_ID CORE_DEVICE_ID BUNDLE_ID; do
  [[ -n "${(P)required:-}" ]] || { echo "missing $required in $config_file" >&2; exit 64; }
done

force=0
[[ "${1:-}" == "--force" ]] && force=1
[[ -z "${1:-}" || "$force" == 1 ]] || { echo "Usage: $0 [--force]" >&2; exit 64; }

mkdir -p "$runtime_dir/logs" "$derived_data"
timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
exec > >(tee -a "$runtime_dir/logs/$timestamp.log") 2>&1
now="$(date +%s)"
if (( force == 0 )) && [[ -r "$success_stamp" ]]; then
  last="$(<"$success_stamp")"
  [[ "$last" == <-> ]] && (( now - last < minimum_interval_seconds )) && exit 0
fi

xcrun devicectl device info details --device "$CORE_DEVICE_ID" >/dev/null
xcodebuild -project "$project_path" -scheme "$scheme" -configuration Debug \
  -destination "platform=iOS,id=$XCODE_DEVICE_ID" -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic build
app_path="$derived_data/Build/Products/Debug-iphoneos/FreeReps.app"
[[ -d "$app_path" ]] || { echo "signed app was not produced" >&2; exit 1; }
xcrun devicectl device install app --device "$CORE_DEVICE_ID" "$app_path"
date +%s > "$success_stamp"
xcrun devicectl device process launch --device "$CORE_DEVICE_ID" "$BUNDLE_ID" || true
