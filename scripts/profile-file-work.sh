#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/validation
TEST_RUNNER_TWEAKS_FILE_PROFILE=1 xcodebuild \
  -project Tweaks.xcodeproj -scheme Tweaks -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  -only-testing:TweaksTests/FileWorkProfileTests test \
  > .build/validation/file-work-profile.log 2>&1 || {
    tail -60 .build/validation/file-work-profile.log
    exit 1
  }
rg 'FILE_PROFILE|Executed|TEST SUCCEEDED' .build/validation/file-work-profile.log
