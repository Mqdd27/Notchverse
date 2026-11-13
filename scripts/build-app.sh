#!/bin/bash
# Builds .build/Notchverse.app (ad-hoc signed). Pass --dmg to also build .build/Notchverse-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}

swift build -c release --product Notchverse
cmake -S Vendor/mediaremote-adapter -B .build/adapter -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build .build/adapter >/dev/null

APP=.build/Notchverse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/Notchverse" "$APP/Contents/MacOS/"
cp .build/adapter/MediaRemoteAdapterTestClient "$APP/Contents/MacOS/"
cp -R .build/adapter/MediaRemoteAdapter.framework "$APP/Contents/Frameworks/"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" scripts/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE=.build/dmg
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Notchverse -srcfolder "$STAGE" -ov -format UDZO ".build/Notchverse-$VERSION.dmg" >/dev/null
    echo "Built .build/Notchverse-$VERSION.dmg"
fi
