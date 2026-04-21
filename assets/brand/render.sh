#!/bin/bash
# Render brand PNGs from their HTML sources using headless Chrome.
#
# Usage:
#   ./assets/brand/render.sh                     # hero (1600×620)
#   ./assets/brand/render.sh hero                # same
#   ./assets/brand/render.sh social-preview      # 1280×640 OpenGraph card
#
# Outputs:
#   assets/<target>.png
#
# Chrome headless on macOS reserves ~80-100px of chrome even with
# --headless=new, which clips content positioned near the viewport
# edge. Workaround: render into a taller window, then crop the PNG
# down to the intended content size.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

TARGET="${1:-hero}"

case "$TARGET" in
    hero)
        CONTENT_W=1600
        CONTENT_H=620
        ;;
    social-preview)
        CONTENT_W=1280
        CONTENT_H=640
        ;;
    *)
        echo "Unknown target: $TARGET" >&2
        echo "Valid targets: hero, social-preview" >&2
        exit 2
        ;;
esac

SRC="$HERE/${TARGET}.source.html"
OUT="$REPO_ROOT/assets/${TARGET}.png"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "Google Chrome.app not found at default path." >&2
    echo "Install Chrome, or edit CHROME in this script." >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi

TMP_PROFILE=$(mktemp -d)
trap 'rm -rf "$TMP_PROFILE"' EXIT

WINDOW_H=$((CONTENT_H + 120))

# Chrome sometimes doesn't exit cleanly after writing the screenshot;
# cap it at 15s so the renderer always makes forward progress.
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --user-data-dir="$TMP_PROFILE" \
    --window-size="${CONTENT_W},${WINDOW_H}" \
    --force-device-scale-factor=2 \
    --default-background-color=00000000 \
    --run-all-compositor-stages-before-draw \
    --screenshot="$OUT" \
    --virtual-time-budget=5000 \
    "file://$SRC" >/dev/null 2>&1 &
CHROME_PID=$!
( sleep 15 && kill "$CHROME_PID" 2>/dev/null ) &
WAIT_PID=$!
wait "$CHROME_PID" 2>/dev/null || true
kill "$WAIT_PID" 2>/dev/null || true

if [ ! -f "$OUT" ]; then
    echo "Chrome ran but no PNG was produced at $OUT" >&2
    exit 1
fi

# Crop to content dimensions (at 2× DPR the raw PNG is CONTENT_W*2 wide).
python3 - "$OUT" "$CONTENT_W" "$CONTENT_H" <<'PY'
import sys
from PIL import Image
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
img = Image.open(path)
target = (w * 2, h * 2)
if img.size != target:
    img.crop((0, 0, target[0], target[1])).save(path)
    print(f"cropped to {target[0]}×{target[1]}")
PY

echo "wrote $OUT"
ls -lh "$OUT"
