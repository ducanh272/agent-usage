#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

# The local app bundle does not ship a dSYM. Generating one with dsymutil fails
# inside restricted command sandboxes even when the binary itself builds.
swift build --disable-sandbox -debug-info-format none -c release --product AgentUsageApp

app_dir="$project_dir/.build/AgentUsage.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$(swift build --disable-sandbox -debug-info-format none -c release --show-bin-path)/AgentUsageApp" "$app_dir/Contents/MacOS/AgentUsageApp"
chmod 755 "$app_dir/Contents/MacOS/AgentUsageApp"
# Copying the SwiftPM binary into a bundle invalidates its embedded signature.
# Local builds use an ad hoc signature; release builds may supply a Developer ID.
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"

printf '%s\n' "$app_dir"
