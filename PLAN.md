# TVBox for macOS — 开发计划

> 目标：在 macOS 上尽量完整复刻 TVBox 的点播功能，兼容第三方
> TVBox 配置/源仓生态（含聚合列表、CatVod 源、JS Spider 源、parse 解析、
> 去广告规则）。技术栈：Swift + SwiftUI + AVFoundation + JavaScriptCore。

## 1. 背景与约束

- 原版 TVBox 安卓源码（xiaoya852/TVBox）已被作者删除，现有 fork：
  `wuqi0430/TVBox_code_tvbox-_tvbox-`（~197 个 Java 文件，约 4.5 万行，
  app 137 文件 + player 模块 60 文件 + 3 个 native .so）。
- 不做"逐行翻译"：Android UI 层、ijkplayer native 内核、native JS 引擎
  在 macOS 无对应物。正确路径 = **协议层忠实移植 + UI/播放器原生重写**。
- 我（AI）在 Linux 服务器上写代码，无法本地编译 macOS 产物。
  构建走 **GitHub Actions macOS runner** 出 .app → Release，用户在 Mac 上测试。
- 用户有一台 Mac（测试环境）；GitHub 账号 + fine-grained PAT 明天到位
  （权限：单仓库 Contents R/W + Actions R/W）。

## 2. TVBox 功能清单（复刻范围）

### L1 核心点播（第一优先）
- [ ] 加载本地/远程配置文件（TVBox 标准 JSON）
- [ ] 加载**聚合列表**（`{"urls":[{name,url}...]}` 格式）
  → 展开成多个配置源
- [ ] 站点（站点数组 `urls[]`）管理：启用/禁用、排序
- [ ] **CatVod 标准接口**：`/api.php/provide/vod/` 的
  classify（分类列表）、detail（详情）、vod_search（搜索）、
  vod_play_url（播放地址解析）
- [ ] 列表页：分类 tab、排序、筛选（filter 数组）
- [ ] 详情页：海报、简介、演员、更新信息、**选集列表**（播放组切换）
- [ ] 播放：HLS(m3u8)/mp4 起播、断点续播
- [ ] **parse 解析规则**（`parse` 数组）：对播放地址做二次解析
  （header 注入、URL 替换、正则提取 m3u8、JSON 取字段）
- [ ] 历史记录（本地持久化）

### L2 完整体验
- [ ] 自定义头（`header` 配置项）
- [ ] **去广告规则**（`filter_url` / 广告正则）
- [ ] **JS Spider 引擎**：JavaScriptCore 加载源内 JS 脚本，
  复刻 TVBox 暴露给 spider 的 API 面：
  - `fetch()`（带 headers/UA/cookie）
  - `parseText/parseJson/parseJS`
  - `cache`（localStorage 封装）、`writeCache/readCache`
  - `java` 桥接的常用方法（log、base64、md5、sha1 等）
  - `spider` 入口约定：`search_video/home_video/detail_video/play_video`
- [ ] 收藏 / 历史 / 最近播放
- [ ] 播放设置：倍速、字幕（外挂 srt）、画质选择（多线路播放组）
- [ ] 多源搜索聚合（跨站点搜索合并）
- [ ] 缓存/下载（L2 后期）

### L3 长尾（尽量，可延后）
- [x] 直播 IPTV（`lives` 配置 + 在线 txt/m3u 源；spider 动态直播/EPG/回看未做）
- [ ] 主题换肤
- [ ] 小程序框架（TVBox 内嵌 JS 应用）——评估后决定，工作量最大
- [ ] 账号/登录类源（部分站点需 token 的 `登录` 机制）
- [ ] 本地媒体导入 / 网盘源（AList）

### 明确不做
- 安卓 UI 的逐像素复刻（按 macOS 习惯重设计，保留信息结构）
- 播放 DRM 内容（爱奇艺/腾讯 VIP 流的私有 DRM 不碰）

## 3. 架构

```
TVBoxMac/
├── App/                  # SwiftUI 入口、导航、设置
├── Core/
│   ├── Config/           # 配置加载：单配置、聚合列表、站点管理
│   ├── CatVod/           # CatVod API 客户端（主力源协议）
│   ├── Parser/           # parse 规则引擎（header/替换/正则/JSON 抽取）
│   ├── AdFilter/         # 去广告规则
│   └── Spider/           # JS Spider 运行时（JavaScriptCore 桥）
├── Player/               # AVFoundation 封装：HLS/MP4、倍速、字幕、续播
├── Data/                 # SwiftData/CoreData：历史、收藏、续播点
├── UI/
│   ├── Home/             # 首页（站点+分类）
│   ├── Browse/           # 列表/筛选/搜索
│   ├── Detail/           # 详情+选集
│   └── Player/           # 播放页
└── Tests/
```

### 关键设计决策
1. **协议兼容优先于 UI 还原**：凡是"能不能用用户的源"，看协议层。
   CatVod 是纯 HTTP+JSON，优先做通；JS Spider 是深水区，第二梯队。
2. **Spider 用 JavaScriptCore**（macOS 系统自带，无需打包 JS 引擎）。
   用 JSContext 注入 TVBox spider API 面；网络调用走桥接回 Swift
   （URLSession），避免 JS 侧实现网络栈。
3. **播放器 AVFoundation**：m3u8 走 AVPlayer(HLS)，mp4 直接播；
   需要 seek 精度/硬解控制时再评估 VideoToolbox 直调。
4. **配置持久化**：用户导入的配置存 App Support；历史/收藏用 SwiftData。
5. **无签名分发**：自签 + `xattr -d com.apple.quarantine` 说明写进 README，
   用户本地运行（个人自用，不上 Mac App Store，避免审核风险）。

## 4. 里程碑

| 里程碑 | 内容 | 验收标准 | 预计 |
|---|---|---|---|
| M0 | 项目骨架 + CI 跑通 | GitHub Actions macOS 构建出 .app | 第 1 天 |
| M1 | 配置加载（含聚合列表）+ CatVod 浏览 | 导入用户配置成功，能看到站点/分类/列表 | 第 1~2 周 |
| M2 | 详情页 + 选集 + 起播 + 续播 | 任选一部剧能看完 | 第 3~4 周 |
| M3 | parse 规则 + 去广告 + 多播放组 | 主流源播放成功率 ≥ 安卓端体感 | 第 5~6 周 |
| M4 | JS Spider 引擎 | 抽 5 个用自定义 JS 源的站点可搜索可播放 | 第 7~9 周 |
| M5 | 多源聚合搜索 + 收藏 + 历史完善 | 跨站搜索合并、收藏/历史可用 | 第 10 周 |
| M6 | 直播 + 长尾 + 打磨 | IPTV 可看（已完成）；打包签名说明完善 | 之后 |

## 5. 风险与对策

| 风险 | 对策 |
|---|---|
| 部分源强依赖 spider 的冷门 API，JSC 桥接不完 | 先做 API 覆盖表（统计各源用到的 spider API），按需实现；兜底：标记"不支持"并提示 |
| 反爬：源站对非安卓 UA 拦（部分源站已验证会拦部分 IP/UA） | 可配置 UA/headers；用户端网络一般不受限，重点测用户实网 |
| macOS 无 Xcode 在服务器 → 编译全靠 CI，迭代慢 | 每 PR 必过 CI 构建；测试脚本（Swift Testing）在 CI 跑；UI 逻辑与 UI 分层，逻辑可测 |
| AVFoundation 对个别编码（如部分 HEVC 硬解）表现差异 | 播放失败时回退软解；记录失败 case 到 issue |
| 法律风险（灰色源） | 代码只兼容协议不内置任何源；README 声明用户自担源合法性 |

## 6. 待办（等用户输入）

- [ ] GitHub 账号 + 建仓库（建议名 `tvbox-mac`，private）
- [ ] fine-grained PAT（单仓库 Contents R/W + Actions R/W）→ 存本机 `.env`
- [ ] 用户 Mac 的 macOS 版本 / Apple 芯片型号（CI 编译 target 参考）
- [x] 直播已实现（lives → 在线 txt/m3u）
- [ ] 确认：小程序框架做不做（L3，开放工期）

## 7. 工作流约定

- 我（AI）：写代码 + 推 GitHub + 触发 CI + 读 CI 日志修错
- 用户：下载 Release 的 .app → 测试 → 反馈（截图/录屏/描述）
- 每完成一个里程碑打 tag（v0.1-m1 …），Release 附测试清单
- 临时验证脚本用 `/tmp/hermes-verify-` 前缀，验证后清理
