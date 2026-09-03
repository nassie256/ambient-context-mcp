import AppKit

// nib / storyboard を持たない AppKit 起動 (C# の Program.cs 相当)。
// `.accessory` = Dock にもアプリメニューにも出さない常駐アプリ。Info.plist の
// LSUIElement と同義だが、`swift run` (バンドル外) でも同じ挙動にするためここでも設定する。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
