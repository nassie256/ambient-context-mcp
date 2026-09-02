import AppKit
import Foundation

import AmbientContextCore

/// C# `Win32/DisplayEnumerator` (`EnumDisplayMonitors` + `GetMonitorInfo`) の macOS 版。
///
/// `NSScreen` は**左下原点**の座標系なので、Windows と同じ**左上原点**の整数座標に変換する。
/// 変換の基準は主ディスプレイ (`NSScreen.screens.first`) の `frame.maxY`。
/// `bitsPerPixel` は `CGDisplayBitsPerPixel` が deprecated のため 32 固定 (設計書 §3.3)。
@MainActor
public struct DisplayCollector {
    /// Windows 版 `DisplayEnumerator.BitsPerPixelDefault` と同値。
    public static let bitsPerPixelDefault = 32

    public init() {}

    public func collect() -> [DisplayContext] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return Self.map(screens: screens.map { ($0.localizedName, $0.frame, $0.visibleFrame) },
                        primaryTopY: primary.frame.maxY)
    }

    /// 純ロジック部分 (テスト可能)。`screens` は `NSScreen.screens` と同じ順序で、
    /// 先頭が主ディスプレイであることを前提にする。
    public static func map(
        screens: [(name: String, frame: CGRect, visibleFrame: CGRect)],
        primaryTopY: CGFloat
    ) -> [DisplayContext] {
        screens.enumerated().map { index, screen in
            let bounds = topLeftRect(screen.frame, primaryTopY: primaryTopY)
            let workArea = topLeftRect(screen.visibleFrame, primaryTopY: primaryTopY)
            return DisplayContext(
                deviceName: screen.name,
                // NSScreen.screens[0] はメニューバーを持つ主ディスプレイで原点 (0,0)。
                primary: index == 0,
                left: bounds.left,
                top: bounds.top,
                width: bounds.width,
                height: bounds.height,
                workAreaLeft: workArea.left,
                workAreaTop: workArea.top,
                workAreaWidth: workArea.width,
                workAreaHeight: workArea.height,
                bitsPerPixel: bitsPerPixelDefault)
        }
    }

    /// 左下原点 (AppKit) → 左上原点 (Windows / `DisplayContext`) の変換。単位は points。
    static func topLeftRect(
        _ rect: CGRect,
        primaryTopY: CGFloat
    ) -> (left: Int, top: Int, width: Int, height: Int) {
        (
            left: Int(rect.minX.rounded()),
            top: Int((primaryTopY - rect.maxY).rounded()),
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded())
        )
    }
}
