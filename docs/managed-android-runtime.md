# Managed Android Runtime 设计与实测记录

本分支探索在 macOS App 内按需管理 Android/Dex Spider 运行时。目标是让 `type=3` / `csp_` 源不依赖用户外接 Android 设备。

## 当前阶段（2026-09-20 更新）

已完成：

- 运行时目录约定：`~/Library/Application Support/TVBoxMac/managed-android-runtime`
- `runtime.json` 清单模型 + Apple Silicon、相对路径、Bridge 可执行文件校验
- Dex Bridge JSON 请求/响应模型（`AndroidDexBridgeRequest/Response`）
- `ManagedAndroidSpiderClient`：分类（name→type_id 映射 + 失败回退）、浏览、搜索、详情、播放 URL
- `TVBoxClient` 可选 backend 插槽：有 Bridge APK 时 `type=3`/`csp_` 走托管运行时，否则降级为「不支持」提示
- 惰性启动（`ManagedAndroidSpiderRuntime`）：只有真正请求 jar/csp 站点才拉起模拟器，原生 CatVod 路径零开销
- Bridge APK 构建脚本（`scripts/build-android-bridge.sh`）+ 打包进 App Resources（存在才打包）
- **端到端实测通过**（见下文「实测记录」）

尚未完成：

- runtime 远程下载、签名/哈希校验和原子安装（目前 APK 随 App 分发或本地构建）
- 模拟器进程随 App 退出的清理（现在退出后模拟器进程可能残留）
- 模拟器启动期间的 UI 进度提示（首启 + 装 APK 约 10–30 秒，用户侧像卡顿）
- 更多真实 `csp_` jar 的兼容性回归

## 实测记录（2026-09-18/20，全部手动验证）

### 端到端链路 ✅

```
AVD（手动创建）→ headless 模拟器启动（M3 上约 5 秒 boot）
→ adb install Bridge APK → am start BridgeActivity → adb forward tcp:19978→tcp:9978
→ GET /health（{"ok":true,"version":"0.3.44"...}）
→ POST /v1/invoke（真实 jar 下载 + DexClassLoader + spider 类加载 + init() 调用）
→ categories 返回完整 class/list JSON（首次调用约 11 秒，含 jar 下载）
```

### 踩过的坑（重要）

1. **AVD 创建**：brew 的 `avdmanager`（15859902）枚举不出 Android Studio 装的系统镜像
   （报 "Valid system image paths are: null"），且 `--avd-home` 位置随版本变化。
   解法：手写 AVD 文件结构（`TVBoxMac_Runtime.ini` + `TVBoxMac_Runtime.avd/config.ini`），
   放在 `ANDROID_AVD_HOME`（= controller.launchEmulator 用的 App Support avd 目录）下。
   系统镜像用已装好的 `system-images;android-35;google_apis;arm64-v8a`。
2. **interactionID 编码**：Swift 端曾把 `interactionID/interactionKind` 编码为 JSON `null`，
   Android 的 `optString` 会把 JSON null 变成字符串 `"null"`（非空）→ 被判为 interactive
   请求 → 走交互生命周期 → 409 "Interaction is no longer current"。当前代码编码为 `nil`
   （字段省略），配合后续修复已实测不触发 409。
3. **KVC 读取 accessLog**：`observedBitrate` 返回 double 基础类型，`perform()` 会把原始位
   重解释成对象指针 → SIGSEGV。全部改用 KVC `value(forKey:)`（自动装箱 NSNumber），
   且每个键先 `responds(to:)` 预检——键不存在时 KVC 抛 ObjC 异常（Swift 接不住 → abort），
   实测崩过一次（`numberOfStalls` 键）。
4. **adb 端口转发方向**：`forward tcp:19978 tcp:9978`（宿主 19978 → 模拟器内 9978），
   写反会得到空响应（Bridge 只监听模拟器内 127.0.0.1:9978）。

### jar 类名不匹配（重要发现）

「🚀游魂┃饭太硬」镜像配置的配置级 spider 指向 qiniu 的 jar（2026-09-18 上传），
但该 jar（二进制级验证：1413 个类全量解析）里**没有** `DouDouGuard`/`YCyzGuard`/
`NewCzGuard` 类——只有 `YGP`。因此这些站点返回空（按 FongMi 约定：可选 spider 缺失
→ 空结果）。

- 同一 jar 里**有** `WenCai`（文采）、`CZ`、`YGP`、`Buguyy`（不卡影院）等 82+ 个
  spider 类；用真实类名 `csp_WenCai` + 同一 jar 实测 → HTTP 200 完整分类/列表。
- 原版饭太硬配置（qist/tvbox 的 `fty.json`）配置级 spider 是
  `./jar/fan.txt;md5;dab654f794a271c3d7a33d18acfbfa95`——**另一个 jar**（已验证为合法
  jar、MD5 匹配）。镜像配置把 config.spider 换成了 qiniu jar，导致类名对不上。
- 结论：**类名缺失不是 Bridge 的问题，是镜像配置的 jar 与 api 名不匹配**。
  `ManagedAndroidSpiderClient` 已对此给出明确提示（"jar 里可能没有 XXX 类…"）。

### 分段 CDN 抖动（「缓冲慢」的根因）

同一分段 CDN（`c.baisiweiting.com:18443`）一小时内从「所有 UA 全超时」变为
「HTTP 200 / 429KB / 2.3s」——同一 app 同一代码，唯一变量是时间。灰产 CDN 的常态，
app 无法修复，只能：初始加载超时提示 + 看门狗轻推 + 换线路/换源。

## 诊断设施

- `PlayerLog`：`~/Library/Application Support/TVBoxMac/player.log`，首行记录二进制
  路径 + 构建时间（确认跑的是哪份包）；含解析/加载/缓冲/看门狗/错误全链路
- 初始加载超时：12 秒无数据 → 提示分段 CDN 无响应并触发换线路
- `scripts/check-sources.py`：批量实测已导入 type=1 源的三环（API → m3u8 → 分段），
  输出可用性排名（实测 44 个源仅 8 个能播）
- 模拟器/Bridge 状态：`adb devices` + `curl http://127.0.0.1:19978/health`

## Bridge 来源

当前选择复用 OKVideoMac 的开源 Android Dex Bridge，而不是重新实现完整的
FongMi/CatVod Android 宿主。构建脚本固定 OKVideoMac commit
`25155f52fb8c416f3245c9a829a93175dec9857b`：

```bash
bash scripts/build-android-bridge.sh
```

该 Bridge 及其 FongMi/CatVod 宿主代码受 GPL-3.0 及相关第三方许可证约束。
在正式分发前必须随产品提供对应源码、许可证和修改说明；本仓库目前只保存构建脚本，
不复制第三方源码。

## 数据流（已验证）

```text
TVBoxMac
  -> ManagedAndroidSpiderClient
  -> Bridge transport (HTTP, adb forward tcp:19978 -> tcp:9978)
  -> macOS 内部管理的 Android Emulator (headless, arm64)
  -> DexClassLoader + TVBox Spider host API
  -> VodPage / Vod / play URL
```

这不是 Android 设备方案。用户只运行 macOS App；Android Runtime 作为 App Support 下的可选组件按需安装。

## 安全边界

- 只接受固定版本清单和预期架构。
- Bridge 路径必须位于 runtime 根目录内，拒绝绝对路径和 `..` 穿越。
- 远程 runtime 必须在安装前完成 HTTPS、SHA-256 和签名校验。
- 未安装或校验失败时，站点应显示为「不支持」，不能静默执行未知二进制。
- Bridge 的 invoke 请求禁止携带 `interactionID`/`interactionKind` 的 JSON null
  （见上文坑 2）。
