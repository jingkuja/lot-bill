#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${LOT_BILL_MAC_DERIVED_DATA:-/private/tmp/lot-bill-mac-derived}"
output="$project_root/build/macos"
mkdir -p "$output"

xcodebuild -project "$project_root/LotBill.xcodeproj" -scheme LotBillMac \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" build

# Stage a complete bundle so removed build resources cannot linger in the package.
staging="$(mktemp -d /private/tmp/lot-bill-package.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
ditto "$derived_data/Build/Products/Release/LotBillMac.app" "$staging/LotBillMac.app"
codesign --verify --deep --strict "$staging/LotBillMac.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$staging/LotBillMac.app/Contents/Info.plist"
test -f "$staging/LotBillMac.app/Contents/Resources/AppIcon.icns"
ln -s /Applications "$staging/Applications"
hdiutil create -volname 'Lot Bill' -srcfolder "$staging" -format UDZO \
    -ov "$output/Lot-Bill.dmg"
hdiutil verify "$output/Lot-Bill.dmg"
ditto "$staging/LotBillMac.app" "$output/LotBillMac.app"
printf 'App: %s\nInstaller: %s\n' "$output/LotBillMac.app" "$output/Lot-Bill.dmg"
