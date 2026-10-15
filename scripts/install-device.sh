#!/bin/bash
# Build and install the personal trial version, preserving its existing app container.
set -euo pipefail

device_id="${1:-}"
if [[ ! "$device_id" =~ ^[A-Fa-f0-9-]{16,40}$ ]]; then
    printf 'Usage: bash scripts/install-device.sh <DEVICE_UDID>\n' >&2
    exit 2
fi
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$project_root/Config/Local.xcconfig" ]]; then
    printf 'Configure local signing in Config/Local.xcconfig first. See README.md.\n' >&2
    exit 2
fi
derived_data="${LOT_BILL_RELEASE_DERIVED_DATA:-/private/tmp/lot-bill-release}"
xcodebuild -project "$project_root/LotBill.xcodeproj" -scheme LotBill \
    -configuration Release -destination "platform=iOS,id=$device_id" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -derivedDataPath "$derived_data" build
app_path="$derived_data/Build/Products/Release-iphoneos/LotBill.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")"
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id"
printf 'Installed Release build: %s\n' "$app_path"
