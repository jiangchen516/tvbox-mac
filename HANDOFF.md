# TVBoxMac 交接文档

> 交接时间：2026-09-17 ｜ 最后提交：`cd44ff2` ｜ 仓库：`jiangchen516/tvbox-mac`（private）
> 开发方式变更：从「Linux 服务器写码 + GitHub Actions CI 出包」转为 **Mac 本地开发**。

---

## 1. 当前状态（一句话）

核心功能链（配置导入 → CatVod 浏览/搜索/详情/选集 → 播放）已通，**卡在 1 个
未修复的 P0 bug：中文域名站点（IDN）无法发起网络请求**，导致导入多仓后
点任何中文域名站点都报「网络错误：不支持的URL」。

| 项 | 状态 |
|---|---|
| Linux 核心库 `TVBoxMacCore` | ✅ 编译通过，**50/50 测试全绿**（Swift 5.10.1） |
| macOS CI（macos-14 runner） | ❌ HEAD 红：仅 4 个 `IDNATests` 失败（runner 的 ICU 无 IDNA 变换，`applyingTransform("IDNA")` 返回 nil） |
| 最后一次全绿 CI | ✅ run `35232665274`（commit `0e28385`），artifact `TVBoxMac.app.zip`（435KB）仍可从 Actions 下载 |
| 用户实测已验证 | ✅ 窗口滚动、裸数组单仓源格式、`.app.zip` artifact 结构 |
| 已写代码待实测 | ⏳ 设置页「全部启用/全部禁用」按钮、JSON 错误信息（带响应片段） |

**注意**：HEAD（`cd44ff2`）相比最后全绿版（`0e28385`）多了：BOM 剥离、
友好 JSON 错误、IDNA 转换、全部启用/禁用。IDNA 转换在 ICU 失效时是
**no-op 回退**（原样返回），不引入新崩溃——所以旧包行为不变，新包等
IDNA 修好才有完整收益。

## 2. Mac 本地开发环境

### 2.1 需要的东西
| 组件 | 要求 | 说明 |
|---|---|---|
| macOS | **13 Ventura 及以上** | `Package.swift` 声明 `platforms: [.macOS(.v13)]` |
| Xcode Command Line Tools | Swift ≥ 5.9（装最新 Xcode 即可，自带） | `xcode-select --install` |
| git | 任意新版 | clone 用 |
| 网络 | 可访问 github.com + 各配置源站点 | 测试需要 |

**不需要**：SwiftPM 依赖全是系统框架（SwiftUI/AVFoundation/JavaScriptCore），
没有第三方包；没有 Podfile/Cartfile。`.build/` 产物本地生成。

### 2.2 搭建步骤
```bash
git clone https://github.com/jiangchen516/tvbox-mac.git
cd tvbox-mac
bash scripts/setup.sh            # 环境自检 + 编译 + 打 .app（一键）
bash scripts/setup.sh --test     # 加跑单测（期望 50 用例；IDNATests 若失败 → §4.1）
swift run TVBoxMac               # 或直接跑
```

### 2.3 本地构建排错
- `swift run` 报模块找不到 → 删 `.build/` 重来（`rm -rf .build`）
- App 打不开（Gatekeeper）→ `xattr -d com.apple.quarantine TVBoxMac.app`
- 播放器黑屏/失败 → 先看 Console.app 里 AVPlayer 日志，多为源站 m3u8
  需要特殊 UA/header（配置里 `header` 字段可覆盖）

## 3. 已完成工作清单

### 3.1 架构（全部完成）
- `TVBoxMacCore` 纯逻辑库：Models（宽容 JSON 解码）/ Config（单配置 +
  聚合列表 + 裸站点数组三格式）/ Networking（`HTTPFetching` 协议可 mock）/
  CatVod / Parser（type0 模板 + type1 JSON + `cat_ext` base64url）/
  AdFilter / Spider（JavaScriptCore 桥，复刻 TVBox spider API 面）/
  Player（AVFoundation 封装：续播/倍速/多播放组）/ History
- `TVBoxMac` SwiftUI 应用：Home / Browse / Detail / Player / Settings
- 跨平台：`#if canImport` 隔离，Linux 可编译核心库 + 跑测试（预检用）

### 3.2 已修复（按轮次）
1. Linux 编译：XCTAssert autoclosure、Combine stub、FoundationNetworking（44→50 测试绿）
2. macOS CI 首编：CoreMedia import、`CMTimeIsValid`（改 `.isFinite`）、
   `AVURLAssetHTTPHeaderFieldsKey`（字符串字面量）、JSContext 桥接 API
3. **JSC overlay 裁剪**：`JSValue` 下标/`isFunction`/`objectForProperty`
   全缺失 → 入口调用整体挪进 `evaluateScript` 执行，参数走 `@objc` 属性透传
4. Artifact 结构：`upload-artifact` 传目录会剥掉 `.app` 外壳 →
   `make-app-bundle.sh` 用 `ditto --keepParent` 出 `TVBoxMac.app.zip` 单文件
5. 设置窗口被列表撑爆 → 固定 560×620 + `ScrollView`
6. 单仓源（裸站点数组 `[...]`）解析 → `parseConfig` 按首字节分流
7. 响应带 UTF-8 BOM → `parseConfig` 剥离 BOM
8. 「配置不是合法JSON」报错 → 现在分三类说人话（HTML 反爬页/空响应/
   结构不符）+ 带响应开头 80 字符
9. 设置页加「全部启用 / 全部禁用」按钮（`AppState.setAllConfigsEnabled`）

### 3.3 参考材料（仓库内）
- `PLAN.md` — 功能清单 + 里程碑（M1 已基本完成）
- `references/tvbox-android-ref/` — 安卓参考源码（**.gitignore 不入库**，
  服务器上有；如需在 Mac 上用，从服务器拷或从原 fork 重新下载）
- `docs/punycode-reference.js` — RFC 3492 权威参考实现（bestiejs/punycode.js
  v2.3.1），修 IDNA 时对照用，标准答案用 `python3 -c "print('饭太硬'.encode('punycode'))"` 对拍

## 4. 遗留问题（按优先级）

### 4.1 P0：IDN 中文域名站点全部请求失败 ⬅ 唯一阻断项
- **现象**：导入 iyouhun 聚合后，点任何 api 为中文域名的站点
  （`www.饭太硬.net` 等，聚合源里占多数）→「加载失败：网络错误：不支持的URL」
- **根因**（已定位）：`URL(string:)` 能构造非 ASCII host，但 **URLSession
  拒绝发送**，报 `URLError` "unsupported URL"。中文域名必须先转 Punycode
  （`www.饭太硬.net` → `www.xn--sss604efuw.net`）
- **现状**：`IDNA.swift` 用 Apple ICU（`applyingTransform(StringTransform(rawValue:"IDNA"))`）
  转换，已接入 `HTTPClient.get` 与 Spider 的 `fetchImpl`。但在 GitHub
  macos-14 runner 上该变换**返回 nil**（runner 的 ICU 被裁剪），4 个
  IDNATests 挂掉 → CI 红。
- **下一步（二选一）**：
  a. **先在你 Mac 上验证**：`swift test --filter IDNATests`。本机 ICU 是
     完整的，大概率能过 → 若过，则只修 CI（把 IDNATests 里"转换结果"
     断言改成 `if let` 条件断言/标记 skip），IDNA 功能即告完成。
  b. 若本机也返回 nil → 实现**纯 Swift Punycode**（RFC 3492 编码，参考
     `docs/punycode-reference.js`，本地用 Python stdlib 生成标准答案对拍，
     不用烧 CI）。`IDNA.swift` 的 `idnHost` 改成「ICU 优先，失败走手写」。
- **验证方式**：修复后导入 iyouhun → 点中文域名站点 → 能出分类/列表即通

### 4.2 P1：单仓源导入失败「配置不是合法JSON」
- **现象**：导入 `http://www.饭太硬.net/tv` 报 `配置不是合法JSON`
- **排查到的**：服务器（欧洲 IP）curl 该地址各种姿势都返回 **360 反爬导航页**
  （15KB HTML），拿不到真 JSON。你 Mac 上大概率能拿到真数据，所以
  HEAD 里已把报错改成带**响应开头 80 字符**——用 HEAD 构建的包再导一次，
  把红色报错原文发出来即可定位（HTML=反爬拦截要换 UA/换入口；
  真 JSON 但结构不符=补解析分支）
- 顺带注意：该站正确入口可能是 `https://www.饭太硬.net/tv`（https）
  或 `/api.php/provide/vod` 形式，可在浏览器里先打开确认返回的是 JSON

### 4.3 P2：UI 细节待实测
- 「全部启用/全部禁用」按钮：已实现未实测（逻辑 = 遍历 `setEnabled` 后
  `bootstrap`，模式与单条启用一致）
- 播放页/详情页细节交互尚未过真实源完整流程

### 4.4 明确未做（见 PLAN.md L2/L3）
直播 IPTV、小程序框架、跨站聚合搜索、下载/缓存、登录类源

## 5. 关键坑（踩过的，别再踩）

### macOS CI（macos-14 runner, Swift 5.10）工具链裁剪
1. **JSC overlay 缺失**：`JSValue[name]` / `.isFunction` /
   `.objectForProperty` / `.isProperty` 全没有。解法：JS 入口调用走
   `context.evaluateScript("...")` 字符串执行，Swift→JS 参数用 `@objc`
   属性透传（`SpiderBridge`）。
2. **C 符号缺失**：`CMTimeIsValid`、`AVURLAssetHTTPHeaderFieldsKey` 未导出。
   替代：`CMTime` 用 `.isFinite`；header key 用字符串字面量。
3. **StringTransform**：无 `.idnaConvert` 成员；`StringTransform(rawValue:)`
   是**单参、非可选** init；`kCFStringIDNAConvertTransform` 常量未导出。
   且即使构造成功，runner 上 IDNA 变换运行时返回 nil。
4. **upload-artifact 剥目录**：`path:` 指目录时只传其**内容**。要保留
   顶层 `.app/` 外壳必须传单文件（zip/dmg，`ditto --keepParent`）。
5. **拉 CI 日志**：`/actions/jobs/{id}/logs` 端点返回 **302**，curl 必须
   `-L`；annotations 端点 403（PAT 无 checks 权限），别用。

### 跨平台（Linux 预检 vs macOS 实机）
6. **URL(string:) 对非 ASCII host**：Linux 直接返回 nil；macOS 能构造但
   发请求被拒。涉及 IDN 的测试必须 `#if` 平台门控。
7. Linux 无 `CFStringTransform` / `JSContext` → `#if canImport` 兜底 stub。
8. `HTTPURLResponse` Linux 不可构造 → 自封 `HTTPResponse` 结构体 +
   `HTTPFetching` 协议（测试全 mock）。

### 配置格式
9. TVBox 单文件源有**三种**顶层形态：完整对象 `{...}`、裸站点数组 `[...]`、
   带 BOM 的任意一种。`ConfigLoader.parseConfig` 按「剥离 BOM 后首字节」分流。
10. 聚合列表 = `{"urls":[{"name","url"}...]}`，导入时逐条展开。

## 6. 工作流约定（延续）
- 用户风格：**直接执行优先**，别啰嗦分析；「然后呢？」= 立即行动；
  查代码→基于代码回答；不越界，重要操作先确认；README/文档保持简洁
- 评审/写作：物理表述优先、最小改动、不防御
- 临时验证脚本用 `/tmp/hermes-verify-` 前缀，验完清理
- 本地验证节奏：改 `TVBoxMacCore` → Linux `swift test`（服务器）→
  push → macOS CI/本地 → 实测。Mac 本地后核心库可跳过 Linux 直接本机测
- **永远不要** 把 PAT/token 提交进仓库（`.env` 已在 .gitignore；
  git remote URL 里嵌了 PAT，Mac 上 clone 后建议 `git remote set-url`
  换成自己的凭据）
- 服务器 Swift 工具链：`~/swift-toolchain/swift-5.10.1-RELEASE-ubuntu22.04/`
  （仅 Linux 预检用，Mac 上不需要）

## 7. 快速命令速查
```bash
swift build -c release          # 编译（含 SwiftUI 应用）
swift test                      # 50 个单测（mock，不联网）
swift test --filter IDNATests   # 只测 IDNA（判断本机 ICU 是否可用）
swift run TVBoxMac              # 直接跑应用
bash scripts/make-app-bundle.sh # 出 TVBoxMac.app + dist/TVBoxMac.app.zip
xattr -d com.apple.quarantine TVBoxMac.app   # 首次运行解除隔离

# IDNA 标准答案对拍（修 punycode 时）
python3 -c "print('饭太硬'.encode('punycode'))"   # sss604efuw
```
