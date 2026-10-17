#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="Tweaks.xcodeproj"
SCHEME="Tweaks"
CONFIGURATION="Release"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/.release}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

for command in xcodegen xcodebuild security codesign ditto xcrun shasum lipo; do
    require_command "$command"
done

TEAM_ID="${TEAM_ID:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "TEAM_ID is required for Developer ID distribution." >&2
    exit 2
fi

DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    DEVELOPER_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    echo "No Developer ID Application certificate is installed." >&2
    echo "Install one from the Apple Developer account before creating a release." >&2
    exit 2
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_PRIVATE_KEY_PATH="${NOTARY_PRIVATE_KEY_PATH:-}"
if [[ -z "$NOTARY_PROFILE" && ( -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" || -z "$NOTARY_PRIVATE_KEY_PATH" ) ]]; then
    echo "Provide NOTARY_PROFILE or NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_PRIVATE_KEY_PATH." >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
if [[ "$OUTPUT_DIR" == "/" || "$OUTPUT_DIR" == "$ROOT_DIR" || "$OUTPUT_DIR" == "${HOME:-}" ]]; then
    echo "Refusing unsafe OUTPUT_DIR: $OUTPUT_DIR" >&2
    exit 2
fi

ARCHIVE_PATH="$OUTPUT_DIR/Tweaks.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/Tweaks-export"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

xcodegen generate

VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings \
    | sed -n 's/^    MARKETING_VERSION = //p' | head -n 1)"
if [[ -z "$VERSION" ]]; then
    echo "Could not read MARKETING_VERSION from Xcode build settings." >&2
    exit 1
fi

ZIP_PATH="$OUTPUT_DIR/Tweaks-${VERSION}-arm64.zip"
SHA_PATH="$ZIP_PATH.sha256"
rm -f "$ZIP_PATH" "$SHA_PATH"

SOURCE_REVISION="$(git rev-parse HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then
    SOURCE_REVISION="${SOURCE_REVISION}-dirty"
fi

xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    TWEAKS_SOURCE_REVISION="$SOURCE_REVISION" \
    ENABLE_HARDENED_RUNTIME=YES \
    ARCHS=arm64

EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/Tweaks.app"

test -d "$APP_PATH" || {
    echo "Export did not produce $APP_PATH" >&2
    exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
[[ "$SIGNING_DETAILS" == *"Authority=Developer ID Application"* ]] || {
    echo "Export is not signed with Developer ID Application: $DEVELOPER_IDENTITY" >&2
    exit 1
}
[[ "$SIGNING_DETAILS" == *"Timestamp="* ]] || {
    echo "Export does not contain a secure signing timestamp." >&2
    exit 1
}

ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/Tweaks")"
[[ "$ARCHITECTURES" == "arm64" ]] || {
    echo "Export contains unexpected architectures: $ARCHITECTURES" >&2
    exit 1
}

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
else
    xcrun notarytool submit "$ZIP_PATH" \
        --key "$NOTARY_PRIVATE_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")"
) > "$SHA_PATH"

echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $SHA_PATH"
