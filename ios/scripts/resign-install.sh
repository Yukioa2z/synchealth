#!/bin/zsh

set -euo pipefail

readonly runtime_dir="${SYNCHEALTH_RENEWAL_HOME:-$HOME/Library/Application Support/SyncHealth-renewal}"
readonly config_file="$runtime_dir/config.env"
readonly source_root="$runtime_dir/source/ios"
readonly project_path="$source_root/FreeReps.xcodeproj"
readonly scheme="FreeReps"
readonly derived_data="$runtime_dir/DerivedData"
readonly success_stamp="$runtime_dir/last-success-epoch"
readonly renewal_window_seconds=$((2 * 24 * 60 * 60))

profile_expiration_epoch() {
  local app_path="$1"
  local expiration
  [[ -r "$app_path/embedded.mobileprovision" ]] || return 1
  expiration="$(
    security cms -D -i "$app_path/embedded.mobileprovision" 2>/dev/null \
      | plutil -extract ExpirationDate raw -o - - 2>/dev/null
  )" || return 1
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null
}

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
app_path="$derived_data/Build/Products/Debug-iphoneos/FreeReps.app"
if (( force == 0 )); then
  existing_expiration="$(profile_expiration_epoch "$app_path" || true)"
  if [[ "$existing_expiration" == <-> ]]; then
    remaining_seconds=$(( existing_expiration - now ))
    profile_mtime="$(stat -f '%m' "$app_path/embedded.mobileprovision" 2>/dev/null || true)"
    last_success="$(<"$success_stamp" 2>/dev/null || true)"
    if (( remaining_seconds > renewal_window_seconds )) \
      && [[ "$profile_mtime" == <-> && "$last_success" == <-> ]] \
      && (( last_success >= profile_mtime )); then
      remaining_hours=$(( remaining_seconds / 3600 ))
      echo "Existing provisioning profile is valid for about ${remaining_hours} more hours."
      exit 0
    fi
    if (( remaining_seconds <= renewal_window_seconds )); then
      echo "Provisioning profile is expired or expires within 48 hours; renewing now."
    else
      echo "The signed build has not been installed successfully; retrying now."
    fi
  else
    echo "No readable provisioning profile found; building a newly signed app."
  fi
fi

xcrun devicectl device info details --device "$CORE_DEVICE_ID" >/dev/null
xcodebuild -project "$project_path" -scheme "$scheme" -configuration Debug \
  -destination "platform=iOS,id=$XCODE_DEVICE_ID" -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic build
[[ -d "$app_path" ]] || { echo "signed app was not produced" >&2; exit 1; }
new_expiration="$(profile_expiration_epoch "$app_path" || true)"
[[ "$new_expiration" == <-> ]] || { echo "signed app has no readable provisioning profile expiration" >&2; exit 1; }
(( new_expiration > now )) || { echo "signed app provisioning profile is already expired" >&2; exit 1; }
xcrun devicectl device install app --device "$CORE_DEVICE_ID" "$app_path"
date +%s > "$success_stamp"
date -r "$new_expiration" '+Provisioning profile expires at %Y-%m-%d %H:%M:%S %Z.'
xcrun devicectl device process launch --device "$CORE_DEVICE_ID" "$BUNDLE_ID" || true
