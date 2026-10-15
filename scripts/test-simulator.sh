#!/bin/bash
# Run the shared scheme on an explicitly selected simulator.
set -euo pipefail

device_id="${1:-}"
if [[ ! "$device_id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
    printf 'Usage: bash scripts/test-simulator.sh <SIMULATOR_UDID>\n' >&2
    printf 'Find a device with: xcrun simctl list devices available\n' >&2
    exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/lot-bill-tests.XXXXXX")"
derived_data="${LOT_BILL_DERIVED_DATA:-/private/tmp/lot-bill-derived-data}"
printf 'Test log and result bundle: %s\n' "$result_dir"

xcodebuild -project "$project_root/LotBill.xcodeproj" -scheme LotBill \
    -destination "platform=iOS Simulator,id=$device_id" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_dir/TestResults.xcresult" \
    test 2>&1 | tee "$result_dir/test.log"
