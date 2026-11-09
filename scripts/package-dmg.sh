#!/bin/bash
# Experimental direct download. Does not notarize or upload.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP="$PROJECT_ROOT/dist/package/Cortala.app"
if [[ ! -d "$APP" ]]; then printf 'Run scripts/package.sh first.\n' >&2; exit 1; fi
python3 scripts/audit-bundle.py "$APP"
STAGING="$(mktemp -d "$PROJECT_ROOT/dist/dmg-staging.XXXXXX")"
chmod 755 "$STAGING"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto --norsrc --noextattr --noacl "$APP" "$STAGING/Cortala.app"
/bin/ln -s /Applications "$STAGING/Applications"
python3 - "$APP" "$STAGING/READ-ME-FIRST.txt" <<'PY'
import pathlib, plistlib, sys
app, output = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
output.write_text(f'''Cortala — experimental evaluation build

Requires an Apple Silicon Mac running macOS {info['LSMinimumSystemVersion']} or later.
Drag Cortala to Applications before opening it.

This build has NOT been notarized by Apple. macOS may
block the first launch. Review Apple's current guidance for apps from
unidentified developers: https://support.apple.com/102445
Do not disable Gatekeeper globally or ignore malware/damaged-app alerts.
Managed Macs may not permit this experimental app.

Speech runtime is included. Model weights, personal settings, recordings,
API credentials and Ollama are NOT included. Choose/download a model in the
app for local recognition, or configure your own cloud provider. Cloud
services may charge separately. No cloud provider is selected on your behalf.

Grant Microphone access to dictate. Accessibility is needed only for
auto-paste; system audio permission is needed for meeting system audio.
The app is not a sandboxed or certified security product. Review recording
retention and local/cloud settings before using it with sensitive material.

Copyright (C) 2026 CortexKinematics.
Cortala's original code is licensed under GNU GPL version 3 only.
Commercial redistribution is permitted under the GPL's terms, including
corresponding-source obligations. See LICENSE.txt and COPYRIGHT.txt.
Third-party notices are included inside the app bundle and retain their terms.
''')
PY
if [[ -f LICENSE ]]; then cp LICENSE "$STAGING/LICENSE.txt"; fi
if [[ -f COPYRIGHT ]]; then cp COPYRIGHT "$STAGING/COPYRIGHT.txt"; fi
ARCH="$(uname -m)"
DMG="$PROJECT_ROOT/dist/Cortala-experimental-macOS-$ARCH.dmg"
/usr/bin/hdiutil create -ov -format UDZO -fs HFS+ -volname Cortala -srcfolder "$STAGING" "$DMG"
/usr/bin/hdiutil verify "$DMG"
(cd "$PROJECT_ROOT/dist" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Prepared experimental DMG: %s\nNot notarized. Nothing uploaded.\n' "$DMG"
