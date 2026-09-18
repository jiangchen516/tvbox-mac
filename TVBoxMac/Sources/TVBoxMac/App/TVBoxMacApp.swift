// TVBoxMacApp.swift — 应用入口
import SwiftUI
import TVBoxMacCore

@main
struct TVBoxMacApp: App {
    // 点窗口 x（关闭最后一个窗口）时直接退出 app
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var playerSession = PlayerSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(playerSession)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // 独立播放器窗口：单实例（普通 Window 场景，无 for 载荷）——
        // 内容读共享 PlayerSession，选新的一集时更新 session 即切集，openWindow 只聚焦
        Window("播放", id: "player") {
            PlayerWindowView()
                .environmentObject(appState)      // PlayerView 用 appState.client/historyStore（漏注入会 EnvironmentObject.error() 闪退）
                .environmentObject(playerSession)
        }
        .windowResizability(.contentSize)
    }
}

/// 播放器窗口的共享状态（Site/Vod/Episode 均可 Codable+Hashable）
@MainActor
final class PlayerSession: ObservableObject {
    @Published var payload: PlayerPayload?
}

/// 播放器窗口的载荷
struct PlayerPayload: Codable, Hashable {
    let site: Site
    let vod: Vod
    var episode: Episode     // 切集时更新（同窗口换集）
    let episodes: [Episode]
}

struct PlayerWindowView: View {
    @EnvironmentObject private var session: PlayerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let p = session.payload {
                let idx = p.episodes.firstIndex(where: { $0.id == p.episode.id }) ?? 0
                PlayerView(site: p.site, vod: p.vod, episode: p.episode,
                           episodes: p.episodes,
                           currentIndex: idx,
                           onSwitchEpisode: { newEp in
                               session.payload?.episode = newEp
                           })
                    .id(p.episode.id)   // 切集重建播放器（重新解析地址）
            } else {
                // 系统状态恢复出来的空播放窗口（崩溃/异常退出后残留）→ 自动关掉，
                // 不留下空白播放窗口
                Color.clear
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dismiss() }
                    }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(session.payload?.vod.vod_name ?? "播放")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动标记：日志第一行记录二进制路径/构建时间，便于确认跑的是哪份包
        PlayerLog.logAppLaunch()
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            HomeView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if appState.hasConfig {
                if let site = appState.selectedSite {
                    BrowseView(site: site)
                        .id(site.id)   // 站点切换时重建视图，重置 @State（否则显示旧站点内容）
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("从左侧选择一个站点").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "tv")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("欢迎使用 TVBox for macOS").font(.title2)
                    Text("先在「设置」里导入配置（iyouhun 聚合列表或单个配置 JSON）")
                        .foregroundStyle(.secondary)
                    Button("导入配置") { appState.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
        }
        // 站点切换时记录，重启后自动回到该站点
        .onChange(of: appState.selectedSite?.id) { _ in
            appState.rememberSelectedSite()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")
            }
        }
    }
}
