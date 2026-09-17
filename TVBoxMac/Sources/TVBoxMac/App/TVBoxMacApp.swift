// TVBoxMacApp.swift — 应用入口
import SwiftUI
import TVBoxMacCore

@main
struct TVBoxMacApp: App {
    // 点窗口 x（关闭最后一个窗口）时直接退出 app
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
