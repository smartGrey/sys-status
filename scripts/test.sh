#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-quick}" in
    quick) plan=Quick ;;
    full) plan=Full ;;
    *) echo "用法: $0 [quick|full]" >&2; exit 2 ;;
esac
exec xcodebuild -project NetRate.xcodeproj -scheme NetRate -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "build/tests/$plan" \
    -parallel-testing-enabled NO -testPlan "$plan" test
