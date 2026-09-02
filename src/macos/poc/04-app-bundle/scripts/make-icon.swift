// AppIcon をコードで描いて .iconset 用 PNG を書き出す。
// actool / Asset Catalog を使わないための代替 (CLT のみで動く)。
// 使い方: swiftc -O -o /tmp/make-icon scripts/make-icon.swift && /tmp/make-icon <out-iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        // 角丸の背景
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.06, dy: s * 0.06),
                              xRadius: s * 0.22, yRadius: s * 0.22)
        NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.62, alpha: 1).setFill()
        bg.fill()
        // 同心の弧 + ドット
        NSColor.white.setStroke()
        NSColor.white.setFill()
        for (i, f) in [0.16, 0.27, 0.38].enumerated() {
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY - s * 0.22),
                        radius: s * f, startAngle: 35, endAngle: 145)
            p.lineWidth = s * (0.055 - Double(i) * 0.008)
            p.lineCapStyle = .round
            p.stroke()
        }
        let d = s * 0.09
        NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - s * 0.22 - d / 2,
                                    width: d, height: d)).fill()
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

// icns に必要なファイル名セット
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
    guard let data = draw(size: px) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(entries.count) pngs to \(outDir)")
