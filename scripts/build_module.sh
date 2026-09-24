#!/usr/bin/env bash
# build_module.sh — package the wa_sd_media Magisk module.
#   usage: scripts/build_module.sh [output-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/module"
OUT_DIR="${1:-$HERE/dist}"

[ -f "$SRC/module.prop" ] || { echo "module.prop missing" >&2; exit 1; }

# stage in a temp dir so the source tree stays clean
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$SRC/." "$STAGE/"

# ship the GPT-repair helper inside the module so service.sh can self-heal a wiped GPT.
install -m 0755 "$HERE/scripts/fix_gpt.sh" "$STAGE/fix_gpt.sh"

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/wa_sd_media.zip"
rm -f "$OUT"

( cd "$STAGE" && zip -q -r "$OUT" . )

echo "built: $OUT"
sha256sum "$OUT"
unzip -l "$OUT"
