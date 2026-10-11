#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

# This Command Line Tools installation defaults to the macOS 27 SDK, whose
# SwiftUI interface needs SwiftUIMacros unavailable in the installed toolchain.
# Select the known-compatible SDK when present, while honoring an explicit SDKROOT.
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ] &&
   [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    export SDKROOT
fi

mkdir -p "$project_dir/.build/clang-module-cache" "$project_dir/.build/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-$project_dir/.build/clang-module-cache}
SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-$project_dir/.build/swiftpm-module-cache}
export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE

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
