#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build -c release --product AgentUsageApp

app_dir="$project_dir/.build/AgentUsage.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/AgentUsageApp" "$app_dir/Contents/MacOS/AgentUsageApp"
chmod 755 "$app_dir/Contents/MacOS/AgentUsageApp"

printf '%s\n' "$app_dir"
