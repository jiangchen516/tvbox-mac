// DiscoverView.swift — 首页推荐（豆瓣）
// 打开 App 默认显示；按分类横向展示豆瓣推荐，点海报 = 全站搜索该标题。
import SwiftUI
import TVBoxMacCore

private struct SearchRequest: Identifiable {
    let keyword: String
    var id: String { keyword }
}

struct DiscoverView: View {
    @EnvironmentObject var appState: AppState

    @State private var rows: [DoubanCollection] = []
    @State private var loading: Bool = true
    @State private var failedTitles: [String] = []
    @State private var search: SearchRequest?

    private let douban = DoubanClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                content
            }
            .padding(.vertical, 18)
        }
        .navigationTitle("推荐首页")
        .task { await load() }
        .sheet(item: $search) { req in
            AllSitesSearchSheet(keyword: req.keyword)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("推荐").font(.largeTitle.bold())
                Text("来自豆瓣 · 点击海报可搜索全部启用源")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await load(force: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(loading)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        if loading, rows.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在加载豆瓣推荐…").foregroundStyle(.secondary).font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("推荐加载失败").font(.headline)
                Text("豆瓣接口可能暂时不可用，请检查网络后重试。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("重试") { Task { await load(force: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        } else {
            ForEach(rows, id: \.id) { row in
                collectionRow(row)
            }
            if !failedTitles.isEmpty {
                Text("部分分类加载失败：\(failedTitles.joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func collectionRow(_ row: DoubanCollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title)
                .font(.title3.bold())
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(row.subjects) { subject in
                        Button {
                            search = SearchRequest(keyword: subject.title)
                        } label: {
                            subjectCard(subject)
                        }
                        .buttonStyle(.plain)
                        .help("搜索「\(subject.title)」")
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func subjectCard(_ subject: DoubanSubject) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                // 豆瓣图床带 Referer 更稳（RemoteImage 会解析 @Referer 标记）
                RemoteImage(rawPic: subject.posterURL.map { "\($0)@Referer=\(DoubanClient.referer)" })
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let score = subject.scoreText {
                    Text(score)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            Text(subject.title)
                .font(.callout)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
            Text(subject.episodesInfo ?? subject.year ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func load(force: Bool = false) async {
        loading = true
        if force { failedTitles = [] }
        let result = await douban.home()
        rows = result.collections
        failedTitles = result.failures
        loading = false
        PlayerLog.append("🏠 推荐首页加载: \(rows.map { "\($0.title)(\($0.subjects.count))" }.joined(separator: "、")) 失败=\(failedTitles.joined(separator: "、"))")
    }
}
