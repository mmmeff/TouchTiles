#!/bin/bash
set -euo pipefail

project=$(cd "$(dirname "$0")" && pwd)
destination=${1:-"$project/dist"}
build_root=${TOUCHTILES_BUILD_DIR:-${DRIFTTILE_BUILD_DIR:-"$project/.build"}}
mkdir -p "$destination" "$build_root"
build_root=$(cd "$build_root" && pwd)
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
swift_options=(--package-path "$project" --scratch-path "$build_root/products"
               --cache-path "$build_root/cache" --config-path "$build_root/config"
               --security-path "$build_root/security" -c release)
swift build "${swift_options[@]}"
binary_dir=$(swift build "${swift_options[@]}" --show-bin-path)

stage=$(mktemp -d "$build_root/bundle.XXXXXX")
app="$stage/TouchTiles.app"
iconset="$stage/TouchTiles.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
install -m 755 "$binary_dir/TouchTiles" "$app/Contents/MacOS/TouchTiles"
install -m 644 "$project/Resources/Info.plist" "$app/Contents/Info.plist"
sips -s format png "$project/Resources/TouchTiles.svg" --out "$stage/icon.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" "$stage/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/TouchTiles.icns"
identity=${TOUCHTILES_SIGN_IDENTITY:-${DRIFTTILE_SIGN_IDENTITY:--}}
codesign --force --sign "$identity" --identifier local.drifttile.desktop "$app"
codesign --verify --strict "$app"
ditto "$app" "$destination/TouchTiles.app"
codesign --verify --strict "$destination/TouchTiles.app"
printf '%s\n' "$destination/TouchTiles.app"
