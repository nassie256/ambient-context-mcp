import AppKit

// storyboard / nib 無しの AppKit 起動。NSApplication を自分で組み立てる。
PocLog.start()
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dock に出さない = LSUIElement 相当
let delegate = AppDelegate()
app.delegate = delegate
app.run()
