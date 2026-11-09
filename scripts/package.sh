#!/bin/bash
# Build a distributable local ZIP. No downloads, model weights, identity, or notarization required.
set -euo pipefail
PROJECT_ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
SKIP_BUILD=0
BUNDLE_ENGINE=1
ENGINE="${JUSTWISPER_WHISPER_CLI:-/opt/homebrew/bin/whisper-cli}"
for option in "$@"; do
    case "$option" in
        --skip-build) SKIP_BUILD=1 ;;
        --without-engine) BUNDLE_ENGINE=0 ;;
        *) printf 'Unknown option: %s\n' "$option" >&2; exit 2 ;;
    esac
done
if [[ "$SKIP_BUILD" == 0 ]]; then scripts/build.sh release; fi
SOURCE_APP="$PROJECT_ROOT/dist/Cortala.app"
STAGING="$PROJECT_ROOT/dist/package"
APP="$STAGING/Cortala.app"
mkdir -p "$STAGING"
# Only replace this script's generated staging product.
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
/usr/bin/ditto "$SOURCE_APP" "$APP"
if [[ "$BUNDLE_ENGINE" == 1 ]]; then
    if [[ ! -x "$ENGINE" ]]; then printf 'whisper-cli is missing: %s\n' "$ENGINE" >&2; exit 1; fi
    python3 scripts/bundle-whisper.py "$APP" "$ENGINE"
else
    # A source-only runtime package still has an explicit empty native inventory.
    python3 - "$APP" <<'PYTHON'
import json, pathlib, sys
app = pathlib.Path(sys.argv[1])
(app / 'Contents/Resources/runtime-manifest.json').write_text(json.dumps({
    'format_version': 1, 'components': [], 'license_sha256': {}
}, indent=2) + '\n')
PYTHON
fi
# Runtime payloads were signed before manifest hashes were recorded. Sign only
# the outer bundle here so those hashes stay stable.
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp COPYRIGHT "$APP/Contents/Resources/COPYRIGHT.txt"
python3 scripts/release-metadata.py "$APP"
/usr/bin/codesign --force --sign "${CORTALA_SIGNING_IDENTITY:--}" "$APP"
python3 scripts/audit-bundle.py "$APP"
ARCH="$(/usr/bin/uname -m)"
ARCHIVE="$PROJECT_ROOT/dist/Cortala-macOS-$ARCH.zip"
/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ARCHIVE"
printf 'Packaged %s\nApp: %s\nNot notarized. Model weights are downloaded separately.\n' "$ARCHIVE" "$APP"
