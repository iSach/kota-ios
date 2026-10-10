#!/bin/sh
# Builds build/Kota.ipa for AltStore/SideStore, which re-sign it with your own Apple ID on the phone.
# The build is ad-hoc signed only so the App Group entitlement is embedded for the re-signer to read.
set -e
cd "$(dirname "$0")/.."
rm -rf build/dd build/Payload build/Kota.ipa
xcodebuild -project Kota.xcodeproj -scheme Kota -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true
app=build/dd/Build/Products/Release-iphoneos/Kota.app
[ -d "$app" ] || { echo "build failed" >&2; exit 1; }
codesign -f -s - --entitlements Config/KotaWidget.entitlements "$app/PlugIns/KotaWidget.appex"
codesign -f -s - --entitlements Config/Kota.entitlements "$app"
mkdir -p build/Payload
cp -R "$app" build/Payload/
(cd build && zip -qry Kota.ipa Payload)
rm -rf build/Payload
echo "build/Kota.ipa"
