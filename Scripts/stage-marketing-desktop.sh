#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$HOME/Desktop"
APP_SUPPORT="$HOME/Library/Application Support/Deskland"
MANIFEST_DIR="$ROOT_DIR/build/marketing-backup"
MODE="${1:-day}"

if [[ "$MODE" == "--restore" ]]; then
    echo "==> Restoring original Desktop..."
    if [[ -d "$DESKTOP_DIR/Screenshots" ]]; then
        find "$DESKTOP_DIR/Screenshots" -maxdepth 1 -type f -name "Screenshot *" -exec mv -n {} "$DESKTOP_DIR/" \;
    fi
    rm -rf \
        "$DESKTOP_DIR/Deskland" \
        "$DESKTOP_DIR/Design Studio" \
        "$DESKTOP_DIR/Inspiration" \
        "$DESKTOP_DIR/Field Trips" \
        "$DESKTOP_DIR/Shaders.metal" \
        "$DESKTOP_DIR/Island Concept.png" \
        "$DESKTOP_DIR/Architecture.pdf" \
        "$DESKTOP_DIR/Release Notes.md" \
        "$DESKTOP_DIR/Color Study.png" \
        "$DESKTOP_DIR/Ocean Waves.wav" \
        "$DESKTOP_DIR/Golden Hour.png" \
        "$DESKTOP_DIR/Roadmap.pdf" \
        "$DESKTOP_DIR/Field Notes.txt"
    rmdir "$DESKTOP_DIR/Screenshots" 2>/dev/null || true

    if [[ -f "$MANIFEST_DIR/settings.json.bak" ]]; then
        cp "$MANIFEST_DIR/settings.json.bak" "$APP_SUPPORT/settings.json"
    fi
    if [[ -f "$MANIFEST_DIR/icon-positions.json.bak" ]]; then
        cp "$MANIFEST_DIR/icon-positions.json.bak" "$APP_SUPPORT/icon-positions.json"
    fi

    pkill -x Deskland 2>/dev/null || true
    sleep 0.3
    open "$ROOT_DIR/build/Deskland.app"
    echo "==> Original Desktop restored."
    exit 0
fi

mkdir -p "$MANIFEST_DIR" "$APP_SUPPORT"

if [[ ! -f "$MANIFEST_DIR/settings.json.bak" && -f "$APP_SUPPORT/settings.json" ]]; then
    cp "$APP_SUPPORT/settings.json" "$MANIFEST_DIR/settings.json.bak"
fi
if [[ ! -f "$MANIFEST_DIR/icon-positions.json.bak" && -f "$APP_SUPPORT/icon-positions.json" ]]; then
    cp "$APP_SUPPORT/icon-positions.json" "$MANIFEST_DIR/icon-positions.json.bak"
fi

echo "==> Creating curated Desktop folders & rich preview files..."
mkdir -p \
    "$DESKTOP_DIR/Deskland" \
    "$DESKTOP_DIR/Design Studio" \
    "$DESKTOP_DIR/Inspiration" \
    "$DESKTOP_DIR/Screenshots" \
    "$DESKTOP_DIR/Field Trips"

find "$DESKTOP_DIR" -maxdepth 1 -type f -name "Screenshot *" -exec mv -n {} "$DESKTOP_DIR/Screenshots/" \;

SNAP_TMP="$(mktemp -d)"
"$ROOT_DIR/build/Deskland.app/Contents/MacOS/Deskland" --self-test --dump-snapshots "$SNAP_TMP" >/dev/null

cp "$SNAP_TMP/beach-sunset.png" "$DESKTOP_DIR/Golden Hour.png"
cp "$SNAP_TMP/meadow-day.png"   "$DESKTOP_DIR/Island Concept.png"

swift - "$DESKTOP_DIR" "$SNAP_TMP/forest-day.png" <<'SWIFT'
import Foundation
import AppKit
import CoreGraphics

let desktop = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

do {
    let w = 640, h = 440
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    if let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let swatches: [(CGFloat, CGFloat, CGFloat)] = [
            (0.07, 0.44, 0.68),
            (0.16, 0.76, 0.80),
            (0.95, 0.87, 0.68),
            (0.96, 0.48, 0.34),
            (0.19, 0.56, 0.36)
        ]
        let pad: CGFloat = 28
        let gap: CGFloat = 16
        let swW = (CGFloat(w) - pad * 2 - gap * 4) / 5.0
        for (i, c) in swatches.enumerated() {
            let rx = pad + CGFloat(i) * (swW + gap)
            let path = CGPath(roundedRect: CGRect(x: rx, y: 84, width: swW, height: 320), cornerWidth: 18, cornerHeight: 18, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillPath()
        }
        if let cg = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: desktop.appendingPathComponent("Color Study.png"))
            }
        }
    }
}

func makeCardPDF(to url: URL, accent: NSColor, title: String, subtitle: String, bars: [CGFloat]) {
    var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 540)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1))
    pdf.fill(mediaBox)

    let header = CGRect(x: 36, y: 400, width: 348, height: 96)
    pdf.addPath(CGPath(roundedRect: header, cornerWidth: 16, cornerHeight: 16, transform: nil))
    pdf.setFillColor(accent.cgColor)
    pdf.fillPath()

    for (idx, frac) in bars.enumerated() {
        let y = CGFloat(330 - idx * 54)
        let bg = CGRect(x: 36, y: y, width: 348, height: 30)
        pdf.addPath(CGPath(roundedRect: bg, cornerWidth: 8, cornerHeight: 8, transform: nil))
        pdf.setFillColor(CGColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 1))
        pdf.fillPath()

        let fg = CGRect(x: 36, y: y, width: 348 * frac, height: 30)
        pdf.addPath(CGPath(roundedRect: fg, cornerWidth: 8, cornerHeight: 8, transform: nil))
        pdf.setFillColor(accent.withAlphaComponent(0.65).cgColor)
        pdf.fillPath()
    }
    pdf.endPDFPage()
    pdf.closePDF()
}

makeCardPDF(
    to: desktop.appendingPathComponent("Architecture.pdf"),
    accent: NSColor(srgbRed: 0.10, green: 0.58, blue: 0.78, alpha: 1),
    title: "Metal Terrain Pipeline",
    subtitle: "120Hz ProMotion -> 0Hz Idle",
    bars: [0.88, 0.72, 0.94, 0.64, 0.80]
)

makeCardPDF(
    to: desktop.appendingPathComponent("Roadmap.pdf"),
    accent: NSColor(srgbRed: 0.94, green: 0.49, blue: 0.32, alpha: 1),
    title: "Deskland 0.1.0",
    subtitle: "macOS 27 Native Desktop",
    bars: [1.0, 0.85, 0.68, 0.52]
)

do {
    let sampleRate: UInt32 = 8000
    let numSamples: UInt32 = 2000
    let dataSize = numSamples * 2
    var wav = Data()
    wav.append("RIFF".data(using: .ascii)!)
    var chunkSize: UInt32 = 36 + dataSize
    wav.append(Data(bytes: &chunkSize, count: 4))
    wav.append("WAVEfmt ".data(using: .ascii)!)
    var fmtSize: UInt32 = 16
    var audioFmt: UInt16 = 1
    var channels: UInt16 = 1
    var byteRate: UInt32 = sampleRate * 2
    var blockAlign: UInt16 = 2
    var bitsPerSample: UInt16 = 16
    wav.append(Data(bytes: &fmtSize, count: 4))
    wav.append(Data(bytes: &audioFmt, count: 2))
    wav.append(Data(bytes: &channels, count: 2))
    var sr = sampleRate
    wav.append(Data(bytes: &sr, count: 4))
    wav.append(Data(bytes: &byteRate, count: 4))
    wav.append(Data(bytes: &blockAlign, count: 2))
    wav.append(Data(bytes: &bitsPerSample, count: 2))
    wav.append("data".data(using: .ascii)!)
    var ds = dataSize
    wav.append(Data(bytes: &ds, count: 4))
    for i in 0..<Int(numSamples) {
        let env = sin(Double.pi * Double(i) / Double(numSamples))
        let sample = Int16(sin(Double(i) * 0.08) * 3000.0 * env)
        var s = sample
        wav.append(Data(bytes: &s, count: 2))
    }
    try? wav.write(to: desktop.appendingPathComponent("Ocean Waves.wav"))
}
SWIFT

rm -rf "$SNAP_TMP"

cat > "$DESKTOP_DIR/Shaders.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;

fragment float4 beachFragment(float2 uv [[stage_in]], texture2d<half> terrain [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float shore = float(terrain.sample(s, uv).r);
    return float4(smoothstep(-28.0, 120.0, shore), 0.78, 0.86, 1.0);
}
METAL

cat > "$DESKTOP_DIR/Release Notes.md" <<'MD'
# Deskland 0.1.0 for macOS 27

- Pure Metal shaders (Beach, Meadow, Forest) with dynamic solar time-of-day shifts
- 120 Hz ProMotion island morphing during drag, 0 Hz idle when covered
- Automatic iCloud Desktop & Finder native underlay support
MD

cat > "$DESKTOP_DIR/Field Notes.txt" <<'TXT'
Archipelago Layout Ideas:
- Group active projects on the eastern peninsula
- Keep creative references on the northwest lagoon
- Leave open turquoise water in the center for kayaks
TXT

THEME="beach"
TOD="day"
case "$MODE" in
    --sunset|sunset) THEME="beach";  TOD="sunset" ;;
    --night|night)   THEME="beach";  TOD="night"  ;;
    --dawn|dawn)     THEME="beach";  TOD="dawn"   ;;
    --meadow|meadow) THEME="meadow"; TOD="day"    ;;
    --forest|forest) THEME="forest"; TOD="day"    ;;
    *)               THEME="beach";  TOD="day"    ;;
esac

swift - "$DESKTOP_DIR" "$APP_SUPPORT" "$THEME" "$TOD" <<'SWIFT'
import Foundation
import AppKit
import CoreGraphics

let desktopPath = CommandLine.arguments[1]
let appSupport  = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let theme       = CommandLine.arguments[3]
let tod         = CommandLine.arguments[4]

let primaryScreen = NSScreen.screens.first
let screen = primaryScreen?.frame ?? CGRect(x: 0, y: 0, width: 1728, height: 1117)
let visible = primaryScreen?.visibleFrame ?? CGRect(x: 0, y: 77, width: 1728, height: 1007)
let W = Double(screen.width)
let H = Double(screen.height)
let menuBarTop = Double(H - Double(visible.maxY))
let dockLimitY = Double(H - Double(visible.minY - screen.minY)) - 115.0

var widgetRects: [CGRect] = []
if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
    let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
    for info in infoList {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              layer > iconLayer && layer < 0,
              let owner = info[kCGWindowOwnerName as String] as? String,
              owner.contains("Notification") || owner.contains("Widget") || owner.contains("Chrono"),
              let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.1,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict),
              rect.width > 40, rect.height > 40, rect.width < screen.width * 0.9 else { continue }
        widgetRects.append(rect.insetBy(dx: -34, dy: -34))
    }
}

let hasTopLeftWidgets = widgetRects.contains { $0.minX < screen.width * 0.45 && $0.minY < screen.height * 0.45 }

let normalizedLayout: [(String, Double, Double)]
if hasTopLeftWidgets {
    normalizedLayout = [
        ("Deskland",           1475.0 / 1728.0, 150.0 / 1117.0),
        ("Shaders.metal",      1345.0 / 1728.0, 220.0 / 1117.0),
        ("Island Concept.png", 1485.0 / 1728.0, 300.0 / 1117.0),
        ("Architecture.pdf",   1360.0 / 1728.0, 390.0 / 1117.0),
        ("Release Notes.md",   1490.0 / 1728.0, 470.0 / 1117.0),
        ("Design Studio",      165.0  / 1728.0, 560.0 / 1117.0),
        ("Inspiration",        298.0  / 1728.0, 540.0 / 1117.0),
        ("Color Study.png",    190.0  / 1728.0, 680.0 / 1117.0),
        ("Ocean Waves.wav",    325.0  / 1728.0, 665.0 / 1117.0),
        ("Screenshots",        255.0  / 1728.0, 785.0 / 1117.0),
        ("Golden Hour.png",    765.0  / 1728.0, 765.0 / 1117.0),
        ("Field Trips",        1225.0 / 1728.0, 650.0 / 1117.0),
        ("Roadmap.pdf",        1155.0 / 1728.0, 755.0 / 1117.0),
        ("Field Notes.txt",    1295.0 / 1728.0, 780.0 / 1117.0)
    ]
} else {
    normalizedLayout = [
        ("Deskland",           1475.0 / 1728.0, 155.0 / 1117.0),
        ("Shaders.metal",      1345.0 / 1728.0, 225.0 / 1117.0),
        ("Island Concept.png", 1485.0 / 1728.0, 305.0 / 1117.0),
        ("Architecture.pdf",   1360.0 / 1728.0, 395.0 / 1117.0),
        ("Release Notes.md",   1490.0 / 1728.0, 475.0 / 1117.0),
        ("Design Studio",      165.0  / 1728.0, 175.0 / 1117.0),
        ("Inspiration",        295.0  / 1728.0, 148.0 / 1117.0),
        ("Color Study.png",    190.0  / 1728.0, 295.0 / 1117.0),
        ("Ocean Waves.wav",    320.0  / 1728.0, 275.0 / 1117.0),
        ("Screenshots",        235.0  / 1728.0, 690.0 / 1117.0),
        ("Field Trips",        365.0  / 1728.0, 720.0 / 1117.0),
        ("Golden Hour.png",    270.0  / 1728.0, 795.0 / 1117.0),
        ("Roadmap.pdf",        1175.0 / 1728.0, 745.0 / 1117.0),
        ("Field Notes.txt",    1310.0 / 1728.0, 780.0 / 1117.0)
    ]
}

var placedRects: [CGRect] = widgetRects
var positions: [String: [Double]] = [:]

for (name, nx, ny) in normalizedLayout {
    var x = round(nx * W)
    var y = min(dockLimitY, max(menuBarTop + 16.0, round(ny * H)))
    var candidate = CGRect(x: x, y: y, width: 88, height: 96)

    if widgetRects.contains(where: { $0.intersects(candidate) }) {
        outer: for radius in stride(from: 60.0, through: 600.0, by: 45.0) {
            for deg in stride(from: 0.0, to: 360.0, by: 30.0) {
                let rad = deg * .pi / 180.0
                let tx = min(W - 104.0, max(24.0, round(x + cos(rad) * radius)))
                let ty = min(dockLimitY, max(menuBarTop + 16.0, round(y + sin(rad) * radius)))
                let test = CGRect(x: tx, y: ty, width: 88, height: 96)
                if !placedRects.contains(where: { $0.intersects(test) }) {
                    x = tx
                    y = ty
                    candidate = test
                    break outer
                }
            }
        }
    }
    placedRects.append(candidate)
    let fullPath = (desktopPath as NSString).appendingPathComponent(name)
    positions[fullPath] = [x, y]
}

let posData = try JSONSerialization.data(withJSONObject: positions, options: [.prettyPrinted, .sortedKeys])
try posData.write(to: appSupport.appendingPathComponent("icon-positions.json"), options: .atomic)

let settings: [String: Any] = [
    "ambientCap": 60,
    "customHour": 18.15,
    "desktopSource": "auto",
    "iconMode": "interactive",
    "lang": "auto",
    "params": [
        "beach": [
            "birds": 4,
            "kayaks": 3,
            "palms": 8,
            "shallow": 285,
            "shoal": 120,
            "sigma": 86,
            "warp": 36
        ],
        "meadow": [
            "flow": 0.65,
            "sigma": 82
        ],
        "forest": [
            "birds": 6,
            "sigma": 84,
            "wind": 1.3
        ]
    ],
    "paused": false,
    "seed": 528491,
    "snapToGrid": false,
    "theme": theme,
    "timeOfDayMode": tod
]

let setData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
try setData.write(to: appSupport.appendingPathComponent("settings.json"), options: .atomic)
SWIFT

echo "==> Relaunching Deskland.app in 120Hz Interactive Archipelago mode ($THEME / $TOD)..."
pkill -x Deskland 2>/dev/null || true
sleep 0.3
open "$ROOT_DIR/build/Deskland.app"
echo "==> Done! Marketing desktop is live."
