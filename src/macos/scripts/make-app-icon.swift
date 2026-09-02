// AppIcon の元画像 (1024x1024 PNG) をコードで描いて書き出す。
//
// Asset Catalog (actool) は Xcode 必須なので使わない。ここで生成した 1 枚を
// `src/macos/Resources/AppIcon-1024.png` としてコミットし、build-app.sh は
// それを `sips` で各サイズに縮小して `iconutil` で .icns にする
// (= 通常のビルドに swiftc は不要)。
//
// 使い方 (アイコンを描き直したいときだけ):
//   swiftc -O -o /tmp/make-app-icon src/macos/scripts/make-app-icon.swift
//   /tmp/make-app-icon src/macos/Resources/AppIcon-1024.png
import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "src/macos/Resources/AppIcon-1024.png"

let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS 風の角丸スクエア (squircle 近似) の背景。
    let inset = size * 0.06
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.72, alpha: 1),
                              ending: NSColor(calibratedRed: 0.11, green: 0.25, blue: 0.47, alpha: 1))
    gradient?.draw(in: bg, angle: -90)

    // 同心の弧 3 本 + ドット (「まわりの状況を拾う」メタファ)。
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let originY = rect.midY - size * 0.22
    for (index, factor) in [0.16, 0.27, 0.38].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: originY),
                      radius: size * factor, startAngle: 35, endAngle: 145)
        arc.lineWidth = size * (0.055 - Double(index) * 0.008)
        arc.lineCapStyle = .round
        arc.stroke()
    }
    let dot = size * 0.09
    NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: originY - dot / 2,
                                width: dot, height: dot)).fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count) bytes)")
