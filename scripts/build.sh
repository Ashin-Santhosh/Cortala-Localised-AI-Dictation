#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" == release ]]; then
    # SwiftPM embeds its generated resource-bundle location as a string literal.
    # Keep release products outside personal home directories as well as mapping
    # source locations, so that literal cannot reveal the developer's account.
    SWIFT_OPTIONS+=(--scratch-path /tmp/justwhisper-public-release-build)
    SWIFT_OPTIONS+=(-Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=." -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_ROOT=." -Xcc "-ffile-prefix-map=$PROJECT_ROOT=.")
fi
swift build "${SWIFT_OPTIONS[@]}" -c "$CONFIGURATION"
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" -c "$CONFIGURATION" --show-bin-path)"
APP="$PROJECT_ROOT/dist/Cortala.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cortala" "$APP/Contents/MacOS/Cortala"
if [[ "$CONFIGURATION" == release ]]; then /usr/bin/strip -S "$APP/Contents/MacOS/Cortala"; fi
# SwiftPM may embed an absolute toolchain search path under the build directory.
# The release uses system Swift libraries; keep only portable/system rpaths.
python3 - "$APP/Contents/MacOS/Cortala" <<'PY'
import re, subprocess, sys
executable = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', executable], text=True)
paths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', commands)
for path in paths:
    if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
        subprocess.run(['install_name_tool', '-delete_rpath', path, executable], check=True)
PY
cp "$PROJECT_ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
ICON_PATH="$("$PROJECT_ROOT/scripts/build-icon.sh")"
cp "$ICON_PATH" "$APP/Contents/Resources/Cortala.icns"
# FluidAudio's resource bundle serves only the unused LuxTts frontend.
# The offline diarizer loads the separately verified user-selected CoreML assets.
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
ditto "$PROJECT_ROOT/ThirdPartyNotices" "$APP/Contents/Resources/ThirdPartyNotices"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$PROJECT_ROOT/COPYRIGHT" "$APP/Contents/Resources/COPYRIGHT.txt"
mkdir -p "$APP/Contents/Resources/CLI"
cp "$PROJECT_ROOT/tools/justwisper.py" "$APP/Contents/Resources/CLI/justwisper.py"
/usr/bin/codesign --force --sign "${CORTALA_SIGNING_IDENTITY:--}" "$APP"
printf 'Built %s\n' "$APP"
