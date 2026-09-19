#!/bin/sh
set -eu
GUARD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD_APP="$GUARD_DIR/Siri Flow Guard.app"
GUARD_BINARY="$GUARD_APP/Contents/MacOS/SiriFlowGuard"
GUARD_MODE=${1:-observe}
case "$GUARD_MODE" in
  build)
    mkdir -p "$GUARD_APP/Contents/MacOS" "$GUARD_APP/Contents/Resources"
    ICONSET="$GUARD_DIR/.build/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in \
      '16 icon_16x16.png' \
      '32 icon_16x16@2x.png' \
      '32 icon_32x32.png' \
      '64 icon_32x32@2x.png' \
      '128 icon_128x128.png' \
      '256 icon_128x128@2x.png' \
      '256 icon_256x256.png' \
      '512 icon_256x256@2x.png' \
      '512 icon_512x512.png' \
      '1024 icon_512x512@2x.png'; do
      set -- $spec
      /usr/bin/sips -s format png -z "$1" "$1" "$GUARD_DIR/assets/icon.png" --out "$ICONSET/$2" >/dev/null
    done
    /usr/bin/iconutil -c icns "$ICONSET" -o "$GUARD_APP/Contents/Resources/AppIcon.icns"
    /usr/bin/python3 - "$GUARD_APP/Contents/Info.plist" <<'PY'
import plistlib
import sys

data = {
    'CFBundleExecutable': 'SiriFlowGuard',
    'CFBundleIdentifier': 'com.github.shivexe.siri-flow-guard',
    'CFBundleIconFile': 'AppIcon.icns',
    'CFBundleName': 'Siri Flow Guard',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'LSUIElement': True,
}
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(data, stream)
PY
    /usr/bin/xcrun swiftc -O "$GUARD_DIR/flow-siri-guard.swift" -o "$GUARD_BINARY"
    /usr/bin/codesign --force --sign - "$GUARD_APP"
    ;;
  run|observe|start|stop|status)
    if [ ! -x "$GUARD_BINARY" ] || [ "$GUARD_DIR/flow-siri-guard.swift" -nt "$GUARD_BINARY" ] || [ "$0" -nt "$GUARD_BINARY" ]; then
      "$0" build
    fi
    case "$GUARD_MODE" in
      start|stop|status) exec /usr/bin/python3 "$GUARD_DIR/guard-control.py" "$GUARD_MODE" "$GUARD_BINARY" ;;
      *) exec "$GUARD_BINARY" "--$GUARD_MODE" ;;
    esac
    ;;
  *) printf '%s\n' 'Usage: ./guard.sh start|stop|status|run|observe|build' 'start installs a login service; stop removes it. run/observe stop with Ctrl-C.' >&2; exit 64 ;;
esac
