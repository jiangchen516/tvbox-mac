# Managed Android Runtime 设计

本分支探索在 macOS App 内按需管理 Android/Dex Spider 运行时。目标是让 `type=3` / `csp_` 源不依赖用户外接 Android 设备。

## 当前阶段

已完成：

- 运行时目录约定：`~/Library/Application Support/TVBoxMac/managed-android-runtime`
- `runtime.json` 清单模型
- Apple Silicon、相对路径、Bridge 可执行文件校验
- Dex Bridge JSON 请求/响应模型
- `ManagedAndroidSpiderClient`，统一转换分类、VodPage、Vod 和播放 URL
- `TVBoxClient` 的可选 backend 插槽

尚未完成：

- 将签名 Bridge APK 纳入正式 App bundle
- runtime 下载、签名/哈希校验和原子安装
- macOS 到 Bridge 的进程生命周期管理
- 真实 `csp_` jar 的端到端验证

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

## 目标数据流

```text
TVBoxMac
  -> ManagedAndroidSpiderClient
  -> Bridge transport (Unix socket / localhost)
  -> macOS 内部管理的 Android Runtime
  -> DexClassLoader + TVBox Spider host API
  -> VodPage / Vod / play URL
```

这不是 Android 设备方案。用户只运行 macOS App；Android Runtime 作为 App Support 下的可选组件按需安装。

## 安全边界

- 只接受固定版本清单和预期架构。
- Bridge 路径必须位于 runtime 根目录内，拒绝绝对路径和 `..` 穿越。
- 远程 runtime 必须在安装前完成 HTTPS、SHA-256 和签名校验。
- 未安装或校验失败时，站点应显示为“不支持”，不能静默执行未知二进制。
