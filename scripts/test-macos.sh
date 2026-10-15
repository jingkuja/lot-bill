#!/bin/bash
# Run shared business tests and native Mac UI tests against synthetic ledgers.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/lot-bill-mac-tests.XXXXXX")"
derived_data="${LOT_BILL_MAC_DERIVED_DATA:-/private/tmp/lot-bill-mac-derived}"
printf 'Test log and result bundle: %s\n' "$result_dir"
xcodebuild -project "$project_root/LotBill.xcodeproj" -scheme LotBillMac \
    -destination 'platform=macOS' \
    -parallel-testing-enabled NO \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_dir/TestResults.xcresult" \
    test 2>&1 | tee "$result_dir/test.log"
