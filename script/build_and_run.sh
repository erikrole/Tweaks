#!/usr/bin/env bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_MODE="${1:-run}"
TASK_DERIVED="$TASK_ROOT/.build/local-run"
TASK_APP="$TASK_DERIVED/Build/Products/Release/Tweaks.app"
TASK_INSTALLED="/Applications/Tweaks.app"

case "$TASK_MODE" in
  run|--verify|--build-only|--install-built) ;;
  *) echo "Usage: $0 [run|--verify|--build-only|--install-built]" >&2; exit 2 ;;
esac

# Tweaks may own dimming, Wi-Fi restoration and file work. Its normal Quit path
# releases those safely; a build helper must never kill that process.
if [[ "$TASK_MODE" != --build-only ]] && pgrep -x Tweaks >/dev/null; then
  echo "Quit Tweaks using its Quit command first, so it can finish work and restore its state." >&2
  exit 1
fi

cd "$TASK_ROOT"
TASK_REVISION="$(git rev-parse HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then TASK_REVISION="$TASK_REVISION-dirty"; fi
if [[ "$TASK_MODE" != --install-built ]]; then
  xcodegen generate
  # The existing extension's copy phase always rewrites its embedded media
  # bundle. A clean build ensures every enclosing code signature is regenerated.
  xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$TASK_DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' \
    TWEAKS_SOURCE_REVISION="$TASK_REVISION" clean build
else
  TASK_BUILT_REVISION="$(plutil -extract TweaksSourceRevision raw -o - "$TASK_APP/Contents/Info.plist")"
  if [[ "$TASK_REVISION" == *-dirty || "$TASK_BUILT_REVISION" != "$TASK_REVISION" ]]; then
    echo "Build the clean current commit with --build-only before installing it." >&2
    exit 1
  fi
fi
codesign --verify --deep --strict "$TASK_APP"
if [[ "$TASK_MODE" == --build-only ]]; then exit 0; fi

if pgrep -x Tweaks >/dev/null; then
  echo "Tweaks started during the build. Quit it normally, then run this script again." >&2
  exit 1
fi
TASK_REQUIREMENT="$(codesign -d -r- "$TASK_APP" 2>&1 | sed -n 's/^designated => //p')"
if [[ -d "$TASK_INSTALLED" ]]; then
  TASK_OLD_REQUIREMENT="$(codesign -d -r- "$TASK_INSTALLED" 2>&1 | sed -n 's/^designated => //p')"
  if [[ "$TASK_REQUIREMENT" != "$TASK_OLD_REQUIREMENT" ]]; then
    echo "The new signing requirement differs from the installed app. Installation stopped." >&2
    exit 1
  fi
fi

TASK_BACKUPS="$HOME/Code Support/Tweaks/local-builds/$(date +%Y%m%d-%H%M%S)-$$"
TASK_STAGE="/Applications/.Tweaks-build-$$.app"
mkdir -p "$TASK_BACKUPS"
ditto "$TASK_APP" "$TASK_STAGE"
codesign --verify --deep --strict "$TASK_STAGE"
if [[ -d "$TASK_INSTALLED" ]]; then mv "$TASK_INSTALLED" "$TASK_BACKUPS/Tweaks.app"; fi
if ! mv "$TASK_STAGE" "$TASK_INSTALLED"; then
  if [[ -d "$TASK_BACKUPS/Tweaks.app" ]]; then mv "$TASK_BACKUPS/Tweaks.app" "$TASK_INSTALLED"; fi
  exit 1
fi
open "$TASK_INSTALLED"
if [[ "$TASK_MODE" == --verify || "$TASK_MODE" == --install-built ]]; then
  for TASK_ATTEMPT in {1..30}; do
    if pgrep -x Tweaks >/dev/null; then echo "Built, signed, installed and launched Tweaks. Backup: $TASK_BACKUPS"; exit 0; fi
    sleep 0.2
  done
  echo "Tweaks did not remain running after launch." >&2
  exit 1
fi
