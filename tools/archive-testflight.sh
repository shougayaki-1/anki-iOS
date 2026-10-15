#!/bin/bash
# Local signed archive only. Never registers, exports, uploads, or installs.
set -euo pipefail
if [[ $# != 2 || ! "$1" =~ ^[1-9][0-9]{0,3}$ || "$2" != /* ]]; then
  echo "Usage: $0 BUILD_NUMBER(1..9999) NEW_ABSOLUTE_OUTPUT_DIRECTORY" >&2
  exit 2
fi
build_number="$1"
output="$2"
# Refuse to overwrite archives/logs from an earlier attempt.
mkdir "$output"
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "Confirm this build number is unused and greater than all uploaded/local distribution builds."
echo "Archiving build $build_number with the project marketing version; log: $output/archive.log"
if ! xcodebuild -project "$root/AnkiIOS.xcodeproj" -scheme AnkiIOS \
    -configuration Release -destination 'generic/platform=iOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -archivePath "$output/AnkiIOS.xcarchive" -derivedDataPath "$output/DerivedData" \
    CURRENT_PROJECT_VERSION="$build_number" archive > "$output/archive.log" 2>&1; then
  echo "Archive failed. Inspect $output/archive.log locally; do not publish signing logs." >&2
  exit 1
fi
app="$output/AnkiIOS.xcarchive/Products/Applications/AnkiIOS.app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign --verify --strict "$app/PlugIns/StudyProgressWidget.appex"
echo "Local archive/signature check succeeded. App Store Connect Validate remains a separate manual step."
echo "Archive: $output/AnkiIOS.xcarchive"
