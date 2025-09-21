#!/usr/bin/env bash
set -euo pipefail

# Repo root (script resides in scripts/)
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_XCODEPROJ="$REPO_DIR/inhashapp.xcodeproj"
PBXPROJ="$PROJ_XCODEPROJ/project.pbxproj"
SCHEME="inhashapp"
ARCHIVE_PATH="$REPO_DIR/build/inhashapp.xcarchive"
EXPORT_DIR="$REPO_DIR/build/export"
EXPORT_PLIST="$REPO_DIR/build/ExportOptions.plist"
TEAM_ID="${TEAM_ID:-F9BCX5LCAW}"
ISSUER_ID="${ISSUER_ID:-db34b5e9-2b84-4b0c-9a85-eb86a116d271}"

# Resolve API Key ID from secrets or env
DEFAULT_KEY_FILE=$(ls -1 "$REPO_DIR"/secrets/AuthKey_*.p8 2>/dev/null | head -n 1 || true)
if [[ -n "${DEFAULT_KEY_FILE:-}" ]]; then
  KEY_ID="${KEY_ID:-$(basename "$DEFAULT_KEY_FILE" | sed -E 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/') }"
else
  KEY_ID="${KEY_ID:-}"
fi

if [[ -z "$KEY_ID" ]]; then
  echo "[ERROR] API Key not found. Place AuthKey_<KEYID>.p8 in $REPO_DIR/secrets or set KEY_ID env var." >&2
  exit 1
fi

KEY_SRC_PATH="$REPO_DIR/secrets/AuthKey_${KEY_ID}.p8"
KEY_DST_DIR="$HOME/.appstoreconnect/private_keys"
KEY_DST_PATH="$KEY_DST_DIR/AuthKey_${KEY_ID}.p8"

echo "[1/6] Ensuring App Store Connect API key is installed (~/.appstoreconnect/private_keys)"
mkdir -p "$KEY_DST_DIR"
if [[ -f "$KEY_SRC_PATH" ]]; then
  install -m 600 "$KEY_SRC_PATH" "$KEY_DST_PATH"
elif [[ -f "$KEY_DST_PATH" ]]; then
  echo "Key already present at $KEY_DST_PATH"
else
  echo "[ERROR] Missing key at $KEY_SRC_PATH and $KEY_DST_PATH" >&2
  exit 1
fi

echo "[2/6] Bumping CURRENT_PROJECT_VERSION in target 'inhashapp'"
python3 - "$PBXPROJ" <<'PY'
import re, sys, pathlib
pbx = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')

# Split into XCBuildConfiguration blocks
blocks = re.split(r"(\t\t[0-9A-F]{24} /\* .*? \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{)" , pbx, flags=re.S)

def bump_in_block(text: str) -> str:
    # operate only if this block is for main app target by checking bundle id
    if 'PRODUCT_BUNDLE_IDENTIFIER = Audora.inhashapp;' not in text:
        return text
    def repl(m):
        num = int(m.group(1))
        return f"CURRENT_PROJECT_VERSION = {num+1};"
    text = re.sub(r"CURRENT_PROJECT_VERSION = (\d+);", repl, text)
    return text

if len(blocks) == 1:
    # Fallback simple replace of first two occurrences near our bundle id
    new = re.sub(r"(PRODUCT_BUNDLE_IDENTIFIER = Audora\.inhashapp;[\s\S]*?CURRENT_PROJECT_VERSION = )(\d+)(;)",
                 lambda m: m.group(1)+str(int(m.group(2))+1)+m.group(3),
                 pbx, count=2)
else:
    new_parts = []
    it = iter(blocks)
    for head in it:
        new_parts.append(head)
        try:
            start = next(it)
            body = next(it)
            body_bumped = bump_in_block(body)
            new_parts.extend([start, body_bumped])
        except StopIteration:
            break
    new = ''.join(new_parts)

pathlib.Path(sys.argv[1]).write_text(new, encoding='utf-8')
print('Bumped build number in project file.')
PY

echo "[3/6] Archiving (Release, unsigned)"
xcodebuild \
  -scheme "$SCHEME" \
  -project "$PROJ_XCODEPROJ" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  clean archive | cat

echo "[4/6] Preparing ExportOptions.plist"
mkdir -p "$REPO_DIR/build"
/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :method string app-store-connect" \
  -c "Add :teamID string $TEAM_ID" \
  -c "Add :uploadSymbols bool true" \
  -c "Add :compileBitcode bool false" \
  -c "Add :signingStyle string automatic" \
  -c "Add :destination string export" \
  -c "Add :generateAppStoreInformation bool true" \
  "$EXPORT_PLIST"

echo "[5/6] Exporting IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates | cat

IPA="$EXPORT_DIR/inhashapp.ipa"
if [[ ! -f "$IPA" ]]; then
  echo "[ERROR] IPA not found at $IPA" >&2
  exit 1
fi

echo "[6/6] Uploading to TestFlight (altool)"
xcrun altool --upload-app \
  -f "$IPA" -t ios \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER_ID" \
  --verbose | cat

echo "Done. Check App Store Connect processing status."


