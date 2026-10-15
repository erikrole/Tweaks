#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run sequentially: compiling or measuring the other suite adds timing noise.
# Output stays local because process timings depend on this Mac's current workload.
output="$PWD/.build/validation"
mkdir -p "$output"
TWEAKS_BENCHMARKS=1 swift test --package-path Packages/FinderUtilitiesKit \
  -c release --filter PerformanceTests 2>&1 | tee "$output/benchmark-package.log"
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$output/DerivedData" \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  -only-testing:TweaksTests/BackgroundPerformanceTests test \
  > "$output/benchmark-app.log" 2>&1 || {
    tail -60 "$output/benchmark-app.log"
    exit 1
  }
grep -E 'PERF_RESULT|measured|Executed|TEST SUCCEEDED' "$output/benchmark-app.log"
