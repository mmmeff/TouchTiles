#!/bin/bash
set -euo pipefail
umask 077

: "${APPLE_CERTIFICATE:?Missing base64-encoded Developer ID Application PKCS#12}"
: "${APPLE_CERTIFICATE_PASSWORD:?Missing PKCS#12 passphrase}"
: "${APPLE_SIGNING_IDENTITY:?Missing Developer ID Application signing identity}"
: "${APPLE_TEAM_ID:?Missing Apple developer team}"
: "${APPLE_ID:?Missing Apple notarization account}"
: "${APPLE_PASSWORD:?Missing app-specific notarization password}"
: "${SPARKLE_PRIVATE_KEY:?Missing TouchTiles Sparkle signing key}"
update_key=$SPARKLE_PRIVATE_KEY
unset SPARKLE_PRIVATE_KEY

destination=${1:?Pass the release output directory}
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)
cd "$(dirname "$0")/.."
export GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-mmmeff/TouchTiles}
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/touchtiles-release.XXXXXXXX")
keychain="$scratch/signing.keychain-db"
previous_keychains=()
while IFS= read -r line; do
    previous_keychains+=("$line")
done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
cleanup() {
    if [[ -e "$keychain" ]]; then
        security list-keychains -d user -s "${previous_keychains[@]}" || true
        security delete-keychain "$keychain" || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT

keychain_password=$(openssl rand -hex 24)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" "${previous_keychains[@]}"
printf '%s' "$APPLE_CERTIFICATE" | base64 -D > "$scratch/certificate.p12"
security import "$scratch/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
rm "$scratch/certificate.p12"
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD keychain_password

xcrun notarytool store-credentials touchtiles-notary --keychain "$keychain" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID"
unset APPLE_ID APPLE_PASSWORD

notarize() {
    xcrun notarytool submit "$1" --keychain "$keychain" --keychain-profile touchtiles-notary \
        --wait --output-format json > "$scratch/notary-result.json"
    python3 - "$scratch/notary-result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as result:
    submission = json.load(result)
print(f"Notarization {submission['id']}: {submission['status']}")
if submission["status"] != "Accepted":
    sys.exit(1)
PY
}

export TOUCHTILES_BUILD_DIR=${TOUCHTILES_BUILD_DIR:-"$scratch/build"}
export TOUCHTILES_RELEASE=1 TOUCHTILES_UNIVERSAL=1 TOUCHTILES_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"
./build-app.sh "$scratch/bundle"
app="$scratch/bundle/TouchTiles.app"
info="$app/Contents/Info.plist"
team=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$team" == "$APPLE_TEAM_ID" ]] || { echo "Bundle was signed for a different Apple team" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw "$info")
name="TouchTiles-$version-universal"
archive="$destination/$name.zip"
image="$destination/$name.dmg"
feed="$destination/appcast.xml"

ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/submission.zip"
notarize "$scratch/submission.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

mkdir "$scratch/installer"
ditto "$app" "$scratch/installer/TouchTiles.app"
ln -s /Applications "$scratch/installer/Applications"
hdiutil create -ov -volname TouchTiles -srcfolder "$scratch/installer" -fs HFS+ -format UDZO "$image"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$image"
notarize "$image"
xcrun stapler staple "$image"
xcrun stapler validate "$image"

# SwiftPM verifies the package archive containing the framework and signing CLI.
sparkle_signer="$TOUCHTILES_BUILD_DIR/products/artifacts/sparkle/Sparkle/bin/sign_update"
sign_update() {
    printf '%s\n' "$update_key" | "$sparkle_signer" --ed-key-file - "$@"
}
signature=$(sign_update -p "$archive")
public_key=$(plutil -extract SUPublicEDKey raw "$info")
xcrun swift scripts/verify-update.swift "$archive" "$public_key" "$signature"
python3 scripts/release.py appcast "$info" "$archive" "$signature" "$feed"
sign_update "$feed"
sign_update --verify "$feed"
