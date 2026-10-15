#!/bin/bash
# Read-only checks; does not install software, accept licenses, or change settings.
set -u

missing=0
printf 'Lot Bill development environment\n'
sw_vers
printf '\nActive developer directory: '
xcode-select -p || missing=1

if xcodebuild -version; then
    xcrun swift --version || missing=1
    sdks="$(xcodebuild -showsdks)" || missing=1
    printf '%s\n' "$sdks"
    if ! printf '%s\n' "$sdks" | grep -q 'iphonesimulator'; then
        printf 'Missing iOS Simulator SDK.\n'
        missing=1
    fi
    xcrun simctl list runtimes || missing=1
    devices="$(xcrun simctl list devices available)" || missing=1
    printf '%s\n' "$devices"
    if ! printf '%s\n' "$devices" | grep -q 'iPhone.*('; then
        printf 'No available iPhone simulator found.\n'
        missing=1
    fi
else
    printf '\nFull Xcode is unavailable or not selected. Install and initialize Xcode first.\n'
    missing=1
fi

printf '\nGit: '
git --version || missing=1
if [ "$missing" -ne 0 ]; then
    printf '\nEnvironment checks did not pass; see docs/environment.md.\n'
    exit 1
fi
printf '\nTools responded successfully. Build, simulator launch and device signing still require verification.\n'
