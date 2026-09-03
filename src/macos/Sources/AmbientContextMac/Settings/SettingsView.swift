import AppKit
import SwiftUI

/// C# `SettingsWindow.xaml` (Pivot 2 タブ + 下部ステータス + 保存/閉じる) の SwiftUI 版。
/// 項目・並び・文言は Windows 版に合わせる。
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    let onClose: () -> Void

    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                mcpServerTab
                    .tabItem { Text(Strings.tabMcpServer) }
                transmissionTab
                    .tabItem { Text(Strings.tabTransmission) }
            }

            Text(model.statusMessage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.top, 10)
                .padding(.bottom, 4)

            HStack(spacing: 8) {
                Spacer()
                Button(Strings.buttonSave) {
                    Task { await model.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving)
                Button(Strings.buttonClose, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }

    // MARK: - MCP サーバ タブ

    private var mcpServerTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text(Strings.labelStatus).frame(width: labelWidth, alignment: .leading)
                            Text(model.mcpStatusText).gridCellColumns(2)
                        }
                        GridRow {
                            Text(Strings.labelEndpoint).frame(width: labelWidth, alignment: .leading)
                            readOnlyField(model.endpoint)
                            Button(Strings.buttonCopy) { model.copyEndpoint() }
                        }
                        GridRow {
                            Text(Strings.labelToken).frame(width: labelWidth, alignment: .leading)
                            readOnlyField(model.token)
                            Button(Strings.buttonCopy) { model.copyToken() }
                        }
                        GridRow {
                            Text(Strings.labelPort).frame(width: labelWidth, alignment: .leading)
                            TextField("", text: $model.portText)
                                .textFieldStyle(.roundedBorder)
                            Text(Strings.portChangeNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Toggle(Strings.autoStartCheckbox, isOn: $model.autoStart)
                                .gridCellColumns(3)
                        }
                        if !model.autostartMessage.isEmpty {
                            GridRow {
                                Text(model.autostartMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .gridCellColumns(3)
                            }
                        }
                        GridRow {
                            Toggle(Strings.persistEventLogCheckbox, isOn: $model.persistEventLog)
                                .gridCellColumns(3)
                        }
                        GridRow {
                            Text(Strings.persistEventLogNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridCellColumns(3)
                        }
                        GridRow {
                            Button(Strings.copyClaudeCodeSnippet) { model.copyClaudeCodeSnippet() }
                                .gridCellColumns(3)
                        }
                    }
                    .padding(4)
                } label: {
                    Text(Strings.mcpServerGroup).fontWeight(.semibold)
                }

                HStack(spacing: 8) {
                    Text(Strings.labelLanguage).frame(width: labelWidth, alignment: .leading)
                    Picker("", selection: $model.languageSetting) {
                        Text(Strings.languageSystemDefault).tag("")
                        Text(Strings.languageJapanese).tag("ja")
                        Text(Strings.languageEnglish).tag("en")
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                    Spacer()
                }
            }
            .padding(12)
        }
    }

    private func readOnlyField(_ value: String) -> some View {
        Text(value)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor)))
    }

    // MARK: - 送信設定 タブ

    private var transmissionTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.transmissionExplanation)
                .fixedSize(horizontal: false, vertical: true)

            TriStateCheckbox(
                title: Strings.allowAllCheckbox,
                state: model.allowAllState,
                onClick: { model.setAllOptions(allowed: $0) })

            GroupBox {
                HStack(spacing: 8) {
                    Text(Strings.labelRetention)
                    Picker("", selection: $model.retentionHours) {
                        Text(Strings.retention1Hour).tag(1)
                        Text(Strings.retention6Hours).tag(6)
                        Text(Strings.retention24Hours).tag(24)
                        Text(Strings.retention7Days).tag(168)
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Spacer().frame(width: 24)

                    Text(Strings.labelMaxCount)
                    Picker("", selection: $model.maxEventCount) {
                        Text(Strings.count100).tag(100)
                        Text(Strings.count500).tag(500)
                        Text(Strings.count1000).tag(1000)
                        Text(Strings.count5000).tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                }
                .padding(4)
            } label: {
                Text(Strings.eventHistoryGroup).fontWeight(.semibold)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.groups.indices, id: \.self) { groupIndex in
                        groupSection(groupIndex)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor)))

            Text(Strings.sensitivityLegend)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func groupSection(_ groupIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.groups[groupIndex].title).fontWeight(.semibold)
            ForEach(model.groups[groupIndex].options.indices, id: \.self) { optionIndex in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: $model.groups[groupIndex].options[optionIndex].isAllowed)
                        .labelsHidden()
                    Text(model.groups[groupIndex].options[optionIndex].label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(model.groups[groupIndex].options[optionIndex].sensitivity)
                        .frame(width: 88, alignment: .trailing)
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
    }
}

/// 「すべてのコンテキストを許可する」用のチェックボックス。
/// SwiftUI の `Toggle` は 3 状態を表現できないので `NSButton` を借りる。
/// クリック時の意味は Windows 版と同じ (全 ON でなければ全 ON にする / 全 ON なら全 OFF)。
struct TriStateCheckbox: NSViewRepresentable {
    let title: String
    let state: NSControl.StateValue
    let onClick: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title,
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.state = state
        context.coordinator.onClick = onClick
        nsView.title = title
        // 表示状態は常にモデル側が決める (NSButton 自身の off→on→mixed 巡回は使わない)。
        nsView.state = state
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onClick: onClick)
    }

    @MainActor
    final class Coordinator: NSObject {
        var state: NSControl.StateValue
        var onClick: (Bool) -> Void

        init(state: NSControl.StateValue, onClick: @escaping (Bool) -> Void) {
            self.state = state
            self.onClick = onClick
            super.init()
        }

        @objc func clicked(_ sender: NSButton) {
            onClick(state != .on)
        }
    }
}
