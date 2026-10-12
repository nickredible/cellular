#!/bin/sh
# Builds Cellular for a GitHub release and zips it into build/.
#
# Releases are signed with a self-signed certificate (by default "nickredible") instead of an Apple team, so they don't
# carry the Apple ID or team of whoever builds them. Use the same certificate for every release: macOS ties Cellular's
# keychain items and its Bluetooth and Location permissions to it, so a different one makes users grant them again.
set -eu

identity="${CELLULAR_SIGNING_IDENTITY:-nickredible}"
root=$(cd "$(dirname "$0")/.." && pwd)
derived_data="$root/build/DerivedData"

xcodebuild -quiet -project "$root/Cellular.xcodeproj" -scheme Cellular -configuration Release -derivedDataPath "$derived_data" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
    DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS=--timestamp=none \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
    clean build

app="$derived_data/Build/Products/Release/Cellular.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
codesign --verify --deep --strict "$app"

# Plain builds keep debug symbols, which include the absolute paths of the source files
if find "$app" -type f -perm +111 -exec grep -l -a "$root" {} + >/dev/null; then
    echo "error: the app contains paths from $root" >&2
    exit 1
fi

archive="$root/build/Cellular-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
echo "Built $archive"
