#!/bin/bash
set -euo pipefail

project=$(cd "$(dirname "$0")" && pwd)
destination=${1:-"$project/dist"}
build_root=${TOUCHTILES_BUILD_DIR:-${DRIFTTILE_BUILD_DIR:-"$project/.build"}}
identity=${TOUCHTILES_SIGN_IDENTITY:-${DRIFTTILE_SIGN_IDENTITY:--}}
release=${TOUCHTILES_RELEASE:-0}
if [[ "$release" == 1 && "$identity" == - ]]; then
    echo "A release requires a Developer ID Application signing identity." >&2
    exit 1
fi
mkdir -p "$destination" "$build_root"
build_root=$(cd "$build_root" && pwd)
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
swift_options=(--package-path "$project" --scratch-path "$build_root/products"
               --cache-path "$build_root/cache" --config-path "$build_root/config"
               --security-path "$build_root/security" -c release
               -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
if [[ ${TOUCHTILES_UNIVERSAL:-0} == 1 ]]; then
    swift_options+=(--arch arm64 --arch x86_64)
fi
swift build "${swift_options[@]}"
binary_dir=$(swift build "${swift_options[@]}" --show-bin-path)

stage=$(mktemp -d "$build_root/bundle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/TouchTiles.app"
iconset="$stage/TouchTiles.iconset"
framework="$app/Contents/Frameworks/Sparkle.framework"
sparkle="$build_root/products/artifacts/sparkle/Sparkle"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$iconset"
install -m 755 "$binary_dir/TouchTiles" "$app/Contents/MacOS/TouchTiles"
install -m 644 "$project/Resources/Info.plist" "$app/Contents/Info.plist"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
install -m 644 "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
if [[ ${TOUCHTILES_UNIVERSAL:-0} == 1 ]]; then
    for arch in arm64 x86_64; do
        lipo -verify_arch "$arch" "$app/Contents/MacOS/TouchTiles"
        lipo -verify_arch "$arch" "$framework/Sparkle"
    done
fi
sips -s format png "$project/Resources/TouchTiles.svg" --out "$stage/icon.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" "$stage/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/TouchTiles.icns"
sign=(codesign --force --sign "$identity")
if [[ "$identity" != - ]]; then
    sign+=(--options runtime --timestamp)
fi
# Sparkle's download service has network sandbox entitlements of its own.
helpers="$framework/Versions/Current"
"${sign[@]}" "$helpers/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$helpers/XPCServices/Downloader.xpc"
"${sign[@]}" "$helpers/Autoupdate"
"${sign[@]}" "$helpers/Updater.app"
"${sign[@]}" "$framework"
"${sign[@]}" --identifier local.drifttile.desktop "$app"
codesign --verify --deep --strict "$app"
if [[ "$release" == 1 ]]; then
    codesign --verify -R 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
fi
ditto "$app" "$destination/TouchTiles.app"
codesign --verify --deep --strict "$destination/TouchTiles.app"
printf '%s\n' "$destination/TouchTiles.app"
