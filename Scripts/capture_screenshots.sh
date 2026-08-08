#!/usr/bin/env bash
# Capture branded product screenshots into docs/images/.
# Requires Screen Recording permission for the terminal running this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/docs/images"
mkdir -p "$OUT"

APP="${ZEPHYRFLOW_APP:-$ROOT/Dist/ZephyrFlow.app}"
if [[ ! -d "$APP" ]]; then
  echo "→ Building release app…"
  ./Scripts/build_app.sh release
  APP="$ROOT/Dist/ZephyrFlow.app"
fi

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "→ Generating app icon…"
  if [[ -x "$ROOT/.venv/bin/python" ]]; then
    "$ROOT/.venv/bin/python" Scripts/generate_app_icon.py
  else
    python3 Scripts/generate_app_icon.py
  fi
  ./Scripts/build_app.sh release
fi

echo "→ Quitting existing ZephyrFlow…"
pkill -f 'ZephyrFlow.app/Contents/MacOS/ZephyrFlow' 2>/dev/null || true
sleep 1

rm -rf /tmp/zephyrflow-ui-tour
mkdir -p /tmp/zephyrflow-ui-tour
echo "setup" > /tmp/zephyrflow-ui-tour/stage

export ZEPHYRFLOW_UI_TOUR=1
echo "→ Launching UI tour…"
open "$APP"
sleep 3

# list: id \t name \t WxH \t area
list_windows() {
  swift -e '
import Cocoa
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(0) }
for w in info {
  let owner = w[kCGWindowOwnerName as String] as? String ?? ""
  guard owner == "ZephyrFlow" else { continue }
  let id = w[kCGWindowNumber as String] as? Int ?? 0
  let name = w[kCGWindowName as String] as? String ?? ""
  let bounds = w[kCGWindowBounds as String] as? [String: Any]
  let wdt = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
  let hgt = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
  if wdt < 50 || hgt < 50 { continue }
  let area = Int(wdt * hgt)
  print("\(id)\t\(name)\t\(Int(wdt))x\(Int(hgt))\t\(area)")
}
'
}

capture_id() {
  local id="$1"
  local dest="$2"
  if screencapture -x -o -l "$id" "$dest" 2>/dev/null; then
    if [[ -s "$dest" ]]; then
      echo "  ✓ $dest (id $id)"
      return 0
    fi
  fi
  echo "  ! screencapture failed for id $id → $dest"
  return 1
}

largest_window_id() {
  list_windows | sort -t$'\t' -k4 -nr | head -1 | cut -f1
}

window_id_min_size() {
  local min_w="$1"
  local min_h="$2"
  list_windows | while IFS=$'\t' read -r id _ dim _; do
    local w="${dim%x*}"
    local h="${dim#*x}"
    if (( w >= min_w && h >= min_h )); then
      echo "$id"
      break
    fi
  done
}

echo "→ Windows now:"
list_windows || true

echo "→ Capture Setup…"
sleep 1
id="$(window_id_min_size 400 400 || true)"
if [[ -n "${id:-}" ]]; then
  capture_id "$id" "$OUT/01-setup.png" || true
else
  echo "  ! no setup-sized window"
fi

echo "→ Open Settings…"
echo "settings" > /tmp/zephyrflow-ui-tour/stage
sleep 3
echo "→ Windows:"
list_windows || true
# Settings is typically wide
id="$(list_windows | awk -F'\t' '$3 ~ /^[0-9]+x[0-9]+$/ {
  split($3,a,"x"); if (a[1]>=600 && a[2]>=400) print $1, $4
}' | sort -k2 -nr | head -1 | awk '{print $1}')"
if [[ -n "${id:-}" ]]; then
  capture_id "$id" "$OUT/02-settings.png" || true
else
  # fallback largest
  id="$(largest_window_id || true)"
  [[ -n "${id:-}" ]] && capture_id "$id" "$OUT/02-settings.png" || true
fi

echo "→ Open listening panel…"
echo "panel" > /tmp/zephyrflow-ui-tour/stage
sleep 2
echo "→ Windows:"
list_windows || true
# Panel is smaller floating chrome
id="$(list_windows | awk -F'\t' '$3 ~ /^[0-9]+x[0-9]+$/ {
  split($3,a,"x"); if (a[1]>=70 && a[1]<=500 && a[2]>=60 && a[2]<=400) print $1, $4
}' | sort -k2 -nr | head -1 | awk '{print $1}')"
if [[ -n "${id:-}" ]]; then
  capture_id "$id" "$OUT/03-panel.png" || true
else
  echo "  ! panel window not found — capturing interactive region fallback"
  # Capture near mouse / center as last resort
  screencapture -x -R"480,240,420,280" "$OUT/03-panel.png" 2>/dev/null || true
fi

echo "→ Menu bar strip…"
# Primary display top strip
read -r sw _ <<<"$(swift -e 'import AppKit; let f=NSScreen.main!.frame; print(Int(f.width), Int(f.height))')"
screencapture -x -R"0,0,${sw},48" "$OUT/04-menubar.png" 2>/dev/null || true
[[ -f "$OUT/04-menubar.png" ]] && echo "  ✓ $OUT/04-menubar.png"

# App icon in Finder context: generate a simple showcase card via python
echo "→ Icon showcase card…"
if [[ -x "$ROOT/.venv/bin/python" ]]; then
  "$ROOT/.venv/bin/python" - <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw
root = Path(".")
icon = Image.open(root / "docs/images/app-icon-1024.png").convert("RGBA")
icon = icon.resize((512, 512), Image.Resampling.LANCZOS)
card = Image.new("RGBA", (960, 640), (12, 14, 22, 255))
# subtle gradient dots
d = ImageDraw.Draw(card)
d.rounded_rectangle((48, 48, 912, 592), radius=32, fill=(22, 24, 34, 255), outline=(80, 220, 240, 60), width=2)
card.paste(icon, ((960 - 512) // 2, (640 - 512) // 2 - 10), icon)
card.save(root / "docs/images/05-app-icon.png", "PNG")
print("  ✓ docs/images/05-app-icon.png")
PY
fi

echo "done" > /tmp/zephyrflow-ui-tour/stage
sleep 0.5

echo ""
echo "=== Captured ==="
ls -la "$OUT"/*.png 2>/dev/null || echo "(none)"
echo ""
echo "If captures are missing, grant Screen Recording to Terminal:"
echo "  System Settings → Privacy & Security → Screen Recording"
