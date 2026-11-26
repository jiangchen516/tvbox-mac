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
    @AppStorage("tvboxmac.prewarmManagedAndroidRuntime") private var prewarmAndroidRuntime = false
    @AppStorage("tvboxmac.bilibiliSESSDATA") private var bilibiliSESSDATA = ""

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

                    GroupBox("Android Spider 性能") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("启动时预热 Android Runtime", isOn: $prewarmAndroidRuntime)
                                .disabled(appState.managedAndroidRuntime == nil)
                            Text("开启后，下次启动 App 时会在后台启动 Android 模拟器和 Bridge，但不读取任何站点。第一次启动仍需等待；之后首次打开 jar 源会更快。此选项会额外占用内存和 CPU。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button(appState.runtimeRestarting ? "正在重启…" : "重启 Android 运行时") {
                                    Task { await appState.restartManagedRuntime() }
                                }
                                .disabled(appState.runtimeRestarting || appState.managedAndroidRuntime == nil)
                                if appState.runtimeRestarting { ProgressView().controlSize(.small) }
                            }
                            Text("模拟器内 DNS 失效时，所有 jar 源会同时打不开；重启运行时通常可恢复。")
                                .font(.caption).foregroundStyle(.secondary)
                            if appState.managedAndroidRuntime == nil {
                                Text("当前 App 包没有包含 Android Bridge，预热不可用。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(4)
                    }

                    GroupBox("B 站") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("SESSDATA（可留空）", text: $bilibiliSESSDATA)
                                .textFieldStyle(.roundedBorder)
                            Text("登录 bilibili 后从浏览器 Cookie 复制 SESSDATA，可尝试 1080P；留空则匿名 360P。只保存在本机。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }

                    // 已导入配置
                    GroupBox("已导入的配置") {
                        if appState.configs.isEmpty {
                            Text("还没有配置").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 12) {
                                Text("\(appState.configs.count) 个")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("全部启用") {
                                    Task { await appState.setAllConfigsEnabled(true) }
                                }
                                .font(.caption)
                                Button("全部禁用") {
                                    Task { await appState.setAllConfigsEnabled(false) }
                                }
                                .font(.caption)
                            }
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
                    Text("TVBoxMac v0.4.0")
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
