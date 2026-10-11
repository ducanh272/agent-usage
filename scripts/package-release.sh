#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
case "$version" in
    ''|*[!0-9A-Za-z.-]*) printf '%s\n' 'Invalid app version in Info.plist' >&2; exit 1 ;;
esac

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' 'NOTARY_PROFILE requires SIGNING_IDENTITY.' >&2
    exit 1
fi
if [ "${SIGNING_IDENTITY:-}" = - ]; then
    printf '%s\n' 'Use an actual Developer ID identity or omit SIGNING_IDENTITY for a preview.' >&2
    exit 1
fi

sh scripts/build-app.sh
app_dir="$project_dir/.build/AgentUsage.app"
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
if [ "$bundle_version" != "$version" ]; then
    printf '%s\n' 'Built app version does not match Resources/Info.plist.' >&2
    exit 1
fi
if ! grep -Fq "Agent Usage $version" RELEASE_NOTES.md; then
    printf '%s\n' 'Release notes do not match the app version.' >&2
    exit 1
fi

mkdir -p dist
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        archive="AgentUsage-$version-macos.zip"
    else
        archive="AgentUsage-$version-signed-unnotarized.zip"
    fi
    codesign --verify --deep --strict --verbose=2 "$app_dir"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        submission="$project_dir/dist/.AgentUsage-$version-notary.zip"
        result="$project_dir/dist/.AgentUsage-$version-notary-result.plist"
        ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$app_dir" "$submission"
        xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$result"
        status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")
        if [ "$status" != Accepted ]; then
            printf 'Notarization status: %s\n' "$status" >&2
            exit 1
        fi
        xcrun stapler staple "$app_dir"
        xcrun stapler validate "$app_dir"
        rm "$submission" "$result"
    fi
else
    archive="AgentUsage-$version-unsigned-preview.zip"
fi

destination="$project_dir/dist/$archive"
rm -f "$destination"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$app_dir" "$destination"
cp RELEASE_NOTES.md "dist/AgentUsage-$version-release-notes.md"
(cd dist && shasum -a 256 "$archive" "AgentUsage-$version-release-notes.md" > "AgentUsage-$version-SHA256SUMS.txt")
printf 'Release package: %s\n' "$destination"
printf 'Checksums: %s\n' "$project_dir/dist/AgentUsage-$version-SHA256SUMS.txt"
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' 'Unsigned preview: ad hoc signed for local launch; not Developer ID signed or notarized.'
elif [ -z "${NOTARY_PROFILE:-}" ]; then
    printf '%s\n' 'Developer ID signed; not notarized.'
else
    printf '%s\n' 'Developer ID signed and notarized.'
fi
