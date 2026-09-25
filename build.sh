#!/bin/bash
# Builds "Millstone Solutions HX Bridge.app". Usage: ./build.sh [--clean] [--install] [--run] [--selftest]
set -eo pipefail
cd "$(dirname "$0")"
if [[ "$1" == "--git" ]]; then shift; exec tools/dev-git.sh "$@"; fi
SDK="/Library/NDI Advanced SDK for Apple"
NAME="Millstone Solutions HX Bridge"
APP="build/$NAME.app"
LOG="build/build.log"
mkdir -p build
if [[ " $* " == *" --clean "* ]]; then rm -rf .build build/*.app; fi
echo "== swift build $(date)" | tee "$LOG"
swift build -c release --arch arm64 2>&1 | tee -a "$LOG"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/HXBridge"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HXBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$SDK/lib/macOS/libndi_advanced.dylib" "$APP/Contents/Frameworks/"
codesign --force --sign - "$APP/Contents/Frameworks/libndi_advanced.dylib" 2>&1 | tee -a "$LOG"
codesign --force --sign - "$APP" 2>&1 | tee -a "$LOG"
echo "== built $APP" | tee -a "$LOG"
if [[ " $* " == *" --install "* ]]; then
  pkill -x NDIHXBridge && sleep 2 || true      # app's earlier name
  rm -rf "/Applications/NDI HX Bridge.app"
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$NAME.app"
  echo "== installed to $APP" | tee -a "$LOG"
fi
if [[ " $* " == *" --selftest "* ]]; then
  echo "== opus self-test" | tee -a "$LOG"
  "$APP/Contents/MacOS/HXBridge" --opus-selftest 2>&1 | grep "opus-selftest" | tee -a "$LOG"
fi
if [[ " $* " == *" --run "* ]]; then
  pkill -x HXBridge && sleep 3 || true
  open "$APP"
fi
