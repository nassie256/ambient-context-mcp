import AppKit
import Foundation

/// メニューバー用のテンプレート画像。
///
/// `actool` が使えない (Command Line Tools のみ) ため Asset Catalog は持たず、
/// `Resources/MenuBarIcon.png` (build-app.sh が Contents/Resources へコピーする) を読む。
/// 見つからない場合 (`swift run` でリソース未配置など) は同じ絵を AppKit で描く。
/// どちらの経路でも `isTemplate = true` にするので、ダーク/ライトとメニューバーの
/// 色調に自動追従する。
enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static func makeImage() -> NSImage {
        if let image = loadFromResources() {
            return image
        }
        return draw()
    }

    private static func loadFromResources() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
              FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = pointSize
        image.isTemplate = true
        return image
    }

    /// PoC 4 と同じ「電波風」のマーク: 同心の弧 3 本 + 中心のドット。
    static func draw() -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            for (index, radius) in [3.0, 6.0, 8.0].enumerated() {
                let path = NSBezierPath()
                path.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY - 5),
                    radius: radius, startAngle: 35, endAngle: 145)
                path.lineWidth = 1.5 - Double(index) * 0.1
                path.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.5, y: rect.midY - 6.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
