// AppState.swift — 全局应用状态
import SwiftUI
import TVBoxMacCore

@MainActor
final class AppState: ObservableObject {
    @Published var configs: [ConfigStore.StoredEntry] = []
    @Published var selectedSite: Site?
    @Published var showHome: Bool = true         // 推荐首页（启动默认）
    @Published var showAllSearch: Bool = false   // 全站搜索模式（侧栏搜索框回车触发）
    @Published var showHistory: Bool = false     // 观看历史页面
    @Published var allSearchKeyword: String = "" // 全站搜索的已提交关键词
    @Published var selectedConfig: LoadedConfig?
    @Published var showSettings: Bool = false
    @Published var banner: String?   // 一次性提示（加载 warning 等）
    @Published var runtimeRestarting: Bool = false

    let client: TVBoxClient
    let managedAndroidRuntime: ManagedAndroidSpiderRuntime?
    let configStore = ConfigStore()
    let historyStore = HistoryStore()

    var hasConfig: Bool { !configs.isEmpty }

    var enabledSites: [Site] {
        configs.filter { $0.loaded.enabled }.flatMap { $0.loaded.config.sites }
    }

    init() {
        let (client, runtime) = Self.makeClient()
        self.client = client
        self.managedAndroidRuntime = runtime
        Task {
            await bootstrap()
            startAndroidRuntimePrewarmIfEnabled()
            await refreshEnabledRemoteConfigsOnStartup()
        }
    }

    private static func makeClient() -> (TVBoxClient, ManagedAndroidSpiderRuntime?) {
        guard let bridgeAPK = Bundle.main.url(
                  forResource: "AndroidDexBridge-release",
                  withExtension: "apk"
              ) else {
            return (TVBoxClient(), nil)
        }

        let sdkRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk", isDirectory: true)
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("TVBoxMac/managed-android-runtime", isDirectory: true)
        let controller = ManagedAndroidRuntimeController(
            sdkRoot: sdkRoot,
            avdName: "TVBoxMac_Runtime",
            avdHome: supportRoot.appendingPathComponent("avd", isDirectory: true),
            userHome: supportRoot.appendingPathComponent("home", isDirectory: true)
        )
        let runtime = ManagedAndroidSpiderRuntime(
            controller: controller,
            bridgeAPK: bridgeAPK
        )
        return (
            TVBoxClient(managedAndroidSpider: ManagedAndroidSpiderClient(transport: runtime)),
            runtime
        )
    }

    /// 手动重启托管 Android 运行时：模拟器内 DNS/网络卡死时使用。
    func restartManagedRuntime() async {
        guard let runtime = managedAndroidRuntime else {
            banner = "当前 App 包没有包含 Android Bridge，无法重启运行时"
            return
        }
        guard !runtimeRestarting else { return }
        runtimeRestarting = true
        defer { runtimeRestarting = false }
        PlayerLog.append("♻️ 手动重启 Android 运行时…")
        do {
            try await runtime.restart()
            banner = "Android 运行时已重启"
            PlayerLog.append("♻️ Android 运行时已重启")
        } catch {
            banner = "Android 运行时重启失败: \(error.localizedDescription)"
            PlayerLog.append("♻️ 重启失败: \(error.localizedDescription)")
        }
    }

    /// App 退出时清理托管安卓模拟器（有界等待，最多 3 秒）
    func shutdownManagedRuntime() {
        guard let runtime = managedAndroidRuntime else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await runtime.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
    }

    func bootstrap() async {
        let entries = await configStore.load()
        // 多配置共存：每份配置的 csp_ 站点绑定【该配置自己】解析出的 spider jar。
        // 必须在这里绑定（UI 的站点列表来自 appState.configs）——只在 TVBoxClient
        // 侧绑定的话，UI 传下来的 site 仍是未绑定副本，会回退到全局 spiderURL
        // （第一份配置的 jar），盖掉其他配置的 jar（实测：摸鱼的 qiniu jar 盖掉
        // 饭太硬的 fan.txt → DouDouGuard 等 Guard 站点全空）
        var bound = entries
        for i in bound.indices {
            guard let spiderURL = bound[i].loaded.resolvedGlobalSpiderURL() else { continue }
            for j in bound[i].loaded.config.sites.indices {
                let s = bound[i].loaded.config.sites[j]
                let jarEmpty = s.jar == nil || s.jar?.isEmpty == true
                let siteSpiderEmpty = s.spider == nil || s.spider?.isEmpty == true
                if jarEmpty && siteSpiderEmpty && s.api.lowercased().hasPrefix("csp_") {
                    let api = s.api.lowercased()
                    let knownMismatchedJar = spiderURL.contains("qiniu.gongxueyun.com")
                        || spiderURL.contains("file.icve.com.cn/file_doc/874/405/DAB654F794")
                    if Self.verifiedGuardAPIs.contains(api), knownMismatchedJar {
                        bound[i].loaded.config.sites[j].jar = Self.verifiedGuardSpiderURL
                        PlayerLog.append("Guard jar fallback: \(s.api) 使用兼容性实测 fty0903.jar")
                    } else {
                        bound[i].loaded.config.sites[j].jar = spiderURL
                    }
                }
            }
        }
        configs = bound
        let boundCount = bound.reduce(0) { $0 + $1.loaded.config.sites.filter { $0.jar != nil }.count }
        PlayerLog.append("配置加载: \(bound.count) 份（\(bound.map { $0.loaded.name }.joined(separator: "、"))），已绑定 spider jar 的站点 \(boundCount) 个")
        await client.loadConfigs(bound.map { $0.loaded })
        // 启动默认进入推荐首页，不再自动连回上次的站点。
        showHome = true
        showAllSearch = false
        showHistory = false
        selectedSite = nil
    }

    /// 启动时刷新已启用的远程配置一次。界面先使用本地缓存立即启动；远程失败时保留缓存。
    private func refreshEnabledRemoteConfigsOnStartup() async {
        let storedEntries = await configStore.load()
        let entries = storedEntries.filter { $0.loaded.enabled }
        let remoteEntries = entries.filter { entry in
            guard let url = URL(string: entry.loaded.url),
                  let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        guard !remoteEntries.isEmpty else { return }

        PlayerLog.append("配置启动刷新: 开始检查已启用远程配置 \(remoteEntries.count) 份（先使用本地缓存）")
        var refreshedCount = 0
        for entry in remoteEntries {
            guard let url = URL(string: entry.loaded.url) else { continue }
            do {
                let config = try await ConfigLoader.load(single: url)
                let refreshed = LoadedConfig(
                    name: entry.loaded.name,
                    url: entry.loaded.url,
                    config: config,
                    enabled: entry.loaded.enabled
                )
                _ = try await configStore.add(refreshed)
                refreshedCount += 1
                PlayerLog.append("配置启动刷新: \(entry.loaded.name) 已更新")
            } catch {
                // 保留上一份有效配置；配置服务器可能离线、返回反爬 HTML 或有临时故障。
                PlayerLog.append("配置启动刷新: \(entry.loaded.name) 失败，保留本地缓存（\(error.localizedDescription.prefix(120))）")
            }
        }
        if refreshedCount > 0 {
            await bootstrap()
        } else {
            PlayerLog.append("配置启动刷新: 没有远程配置更新成功，继续使用本地缓存")
        }
    }

    private static let lastSiteKey = "tvboxmac.lastSiteID"
    private static let prewarmAndroidRuntimeKey = "tvboxmac.prewarmManagedAndroidRuntime"

    private func startAndroidRuntimePrewarmIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.prewarmAndroidRuntimeKey) else { return }
        guard let runtime = managedAndroidRuntime else {
            PlayerLog.append("Android Runtime 预热已启用，但当前 App 包没有 Bridge APK")
            return
        }
        guard enabledSites.contains(where: { $0.type == 3 || $0.api.lowercased().hasPrefix("csp_") }) else {
            PlayerLog.append("Android Runtime 预热跳过：没有启用的 Dex Spider 站点")
            return
        }

        PlayerLog.append("Android Runtime 预热: 后台启动 Emulator/Bridge（不会请求站点数据）")
        Task.detached(priority: .utility) {
            let start = Date()
            do {
                try await runtime.prepare()
                let elapsed = Date().timeIntervalSince(start)
                PlayerLog.append(String(format: "Android Runtime 预热完成，耗时 %.1fs", elapsed))
            } catch {
                PlayerLog.append("Android Runtime 预热失败，首次打开 Dex 源时将重试: \(error.localizedDescription)")
            }
        }
    }

    // 已验证包含多种 Guard 实现的 dex jar。对 qiniu 镜像表现异常、且在此 jar
    // 上直接验证可返回有效分类的 API，优先使用该版本；不是仅凭类名存在就判定兼容。
    private static let verifiedGuardSpiderURL = "https://tv.菜妮丝.top/jar/fty0903.jar"
    private static let verifiedGuardAPIs: Set<String> = [
        "csp_woggguard", "csp_wogg", "csp_nmyswvguard", "csp_doudouguard", "csp_ycyzguard",
        "csp_jpysguard"
    ]

    /// 记录当前选中站点（站点切换时调用）
    func rememberSelectedSite() {
        showAllSearch = false
        if let id = selectedSite?.id {
            showHome = false
            showHistory = false
            UserDefaults.standard.set(id, forKey: Self.lastSiteKey)
        }
    }

    /// 导入配置（URL，可能是单配置或聚合列表；按响应内容自动判断）
    func importConfig(from url: URL) async {
        let http = HttpClient()
        do {
            let (data, _) = try await http.get(url, headers: nil)
            let text = String(data: data, encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAggregate = trimmed.hasPrefix("{") && trimmed.contains("\"urls\"")
                && !trimmed.contains("\"sites\"")
            if isAggregate {
                let result = try await ConfigLoader.load(aggregate: url, http: http)
                for cfg in result.configs {
                    _ = try await configStore.add(cfg)
                }
                if !result.warnings.isEmpty {
                    banner = "部分源加载失败:\n" + result.warnings.joined(separator: "\n")
                }
            } else {
                let config = try await ConfigLoader.load(single: url, http: http)
                let name = config.sites.first?.name ?? url.lastPathComponent
                _ = try await configStore.add(LoadedConfig(name: name, url: url.absoluteString, config: config))
            }
            await bootstrap()
        } catch {
            banner = "导入失败: \(error.localizedDescription)"
        }
    }

    /// 导入本地 JSON 文件
    func importConfig(fromFile url: URL) async {
        do {
            let config = try ConfigLoader.load(localFile: url)
            let name = config.sites.first?.name ?? url.lastPathComponent
            _ = try await configStore.add(LoadedConfig(name: name, url: "local:\(url.lastPathComponent)", config: config))
            await bootstrap()
        } catch {
            banner = "导入失败: \(error.localizedDescription)"
        }
    }

    func removeConfig(id: String) async {
        _ = try? await configStore.remove(id: id)
        if selectedSite == nil || enabledSites.allSatisfy({ $0.id != selectedSite?.id }) {
            selectedSite = nil
        }
        await bootstrap()
    }

    func setConfigEnabled(id: String, enabled: Bool) async {
        _ = try? await configStore.setEnabled(id: id, enabled: enabled)
        await bootstrap()
    }

    /// 全部启用/禁用
    func setAllConfigsEnabled(_ enabled: Bool) async {
        for entry in configs {
            _ = try? await configStore.setEnabled(id: entry.id, enabled: enabled)
        }
        await bootstrap()
    }
}
