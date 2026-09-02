import SwiftUI

/// 設定ウィンドウ (2 タブ)。本実装では「MCP サーバ」「送信設定」に相当。
struct SettingsView: View {
    @State private var loginItemOn: Bool = LoginItem.isEnabled
    @State private var loginItemStatus: String = LoginItem.statusText()
    @State private var loginItemError: String = ""
    @State private var port: String = "37690"
    @State private var allowAll = false
    @State private var historyMinutes = 120.0

    var body: some View {
        TabView {
            mcpServerTab
                .tabItem { Text(L.t("settings.tab.mcpServer")) }
            transmissionTab
                .tabItem { Text(L.t("settings.tab.transmission")) }
        }
        .padding(12)
        .frame(minWidth: 460, minHeight: 300)
    }

    private var mcpServerTab: some View {
        Form {
            LabeledContent(L.t("settings.endpoint")) {
                Text("http://127.0.0.1:37690/mcp").textSelection(.enabled)
            }
            TextField(L.t("settings.port"), text: $port)
            Toggle(L.t("settings.launchAtLogin"), isOn: $loginItemOn)
                .onChange(of: loginItemOn) { _, newValue in
                    loginItemError = newValue ? LoginItem.register() : LoginItem.unregister()
                    loginItemStatus = LoginItem.statusText()
                    // 実際の状態に合わせ直す (失敗時にトグルが嘘をつかないように)
                    loginItemOn = LoginItem.isEnabled
                }
            LabeledContent("SMAppService.status") { Text(loginItemStatus).font(.caption) }
            if !loginItemError.isEmpty {
                Text(loginItemError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var transmissionTab: some View {
        Form {
            Toggle(L.t("settings.allowAll"), isOn: $allowAll)
            LabeledContent(L.t("settings.historyMinutes")) {
                Slider(value: $historyMinutes, in: 5...1440)
            }
            Text(String(format: "%.0f", historyMinutes)).font(.caption)
        }
        .formStyle(.grouped)
    }
}
