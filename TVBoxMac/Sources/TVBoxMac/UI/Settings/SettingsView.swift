// SettingsView.swift — 配置导入 / 管理 / 关于
import SwiftUI
import TVBoxMacCore
#if canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var configURL: String = ""
    @State private var importing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2).bold()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 导入配置
                    GroupBox("导入配置") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("粘贴配置 URL（单配置 JSON / 裸站点数组 / iyouhun 聚合列表均可）")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                TextField("https://…/config.json", text: $configURL)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { startImport() }
                                Button("导入") { startImport() }
                                    .disabled(importing || configURL.isEmpty)
                                Button("选择文件…") { pickFile() }
                                    .disabled(importing)
                            }
                            if importing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("导入中…").foregroundStyle(.secondary)
                                }
                            }
                            if let banner = appState.banner {
                                Text(banner)
                                    .font(.caption)
                                    .foregroundStyle(banner.hasPrefix("导入失败") ? .red : .orange)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(4)
                    }

                    // 已导入配置
                    GroupBox("已导入的配置") {
                        if appState.configs.isEmpty {
                            Text("还没有配置").foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(appState.configs) { entry in
                                    HStack {
                                        Toggle(isOn: Binding(
                                            get: { entry.loaded.enabled },
                                            set: { _ in
                                                Task {
                                                    await appState.setConfigEnabled(
                                                        id: entry.id, enabled: !entry.loaded.enabled)
                                                }
                                            }
                                        )) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(entry.loaded.name).lineLimit(1)
                                                Text(entry.loaded.url)
                                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                            }
                                        }
                                        Button(role: .destructive) {
                                            Task { await appState.removeConfig(id: entry.id) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // 历史 + 关闭（始终可见，不随列表滚动）
            HStack {
                Button("清空历史记录") {
                    Task { await appState.historyStore.clearHistory() }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox("关于") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TVBox for macOS v0.1 (骨架版)")
                    Text("原生 Swift/SwiftUI 重写，协议层兼容 TVBox 配置生态（CatVod + JS Spider）。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("仅供个人学习使用；影视源合法性由使用者自行负责。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }

    private func startImport() {
        guard let url = URL(string: configURL.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil else {
            appState.banner = "URL 无效"
            return
        }
        importing = true
        appState.banner = nil
        Task {
            await appState.importConfig(from: url)
            importing = false
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await appState.importConfig(fromFile: url) }
        }
    }
}
