#!/bin/bash
# Run the shared scheme on an explicitly selected, trusted physical device.
set -euo pipefail

device_id="${1:-}"
if [[ ! "$device_id" =~ ^[A-Fa-f0-9-]{16,40}$ ]]; then
    printf 'Usage: bash scripts/test-device.sh <DEVICE_UDID>\n' >&2
    printf 'Find a device with: xcrun devicectl list devices\n' >&2
    exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$project_root/Config/Local.xcconfig" ]]; then
    printf 'Configure DEVELOPMENT_TEAM in Config/Local.xcconfig first. See README.md.\n' >&2
    exit 2
fi
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/lot-bill-device-tests.XXXXXX")"
derived_data="${LOT_BILL_DEVICE_DERIVED_DATA:-/private/tmp/lot-bill-device-new-account}"
printf 'Test log and result bundle: %s\n' "$result_dir"

xcodebuild -project "$project_root/LotBill.xcodeproj" -scheme LotBill \
    -destination "platform=iOS,id=$device_id" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_dir/TestResults.xcresult" \
    test 2>&1 | tee "$result_dir/test.log"
