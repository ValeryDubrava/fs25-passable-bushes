#!/usr/bin/env bash
# Build FS25_PassableBushes.zip for distribution.
# Run from anywhere; the zip will be placed at the project root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_NAME="FS25_PassableBushes.zip"
OUT="$SCRIPT_DIR/$ZIP_NAME"

# FS25 requires modDesc.xml at the root of the zip (not inside a subfolder).
cd "$SCRIPT_DIR"

rm -f "$OUT"
zip -r "$OUT" modDesc.xml icon.dds scripts/

echo "Built: $OUT"
