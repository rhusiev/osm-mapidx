#!/usr/bin/env bash
# Push the generated .obf to a phone over adb. OsmAnd must be restarted after.
set -euo pipefail

REGION="${1:-lviv}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBF=$(ls "$ROOT/out/"*"$(python3 -c "print('${REGION}'.capitalize())")"*.obf 2>/dev/null | head -1 || true)
DEST="/sdcard/Android/data/net.osmand.plus/files"

[ -n "$OBF" ] || { echo "no .obf for region $REGION - run ./build_obf.sh $REGION" >&2; exit 1; }
command -v adb >/dev/null || { echo "adb not installed" >&2; exit 1; }

echo "pushing $(basename "$OBF") ($(du -h "$OBF" | cut -f1)) to $DEST"
adb shell "mkdir -p $DEST"
adb push "$OBF" "$DEST/"
echo "done - force-stop and reopen OsmAnd, then check Settings > Maps for the new file"
