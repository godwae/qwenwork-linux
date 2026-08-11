# QwenWorkCN 原生模块审计报告

审计对象：`qwenworkcn-darwin-x64.dmg`（0.1.6 / 26080702 / Electron 37.10.3）
路径：`Contents/Resources/app.asar.unpacked/`（磁盘）与 asar 头部（409 个 unpacked 注册项）

## 1. `node_modules/node-pty` — **关键，源码重建**

| 文件 | 格式 | 处理 |
|------|------|------|
| `prebuilds/darwin-x64/pty.node` | Mach-O | 删除 |
| `build/Release/pty.node` | Mach-O | 重建 |

版本 1.1.0。内置终端（xterm 后端）依赖。从 npm 拉源码针对 Electron 37.10.3 + Linux 重编译，整包替换。

## 2. `node_modules/better-sqlite3` — **关键，源码重建**

| 文件 | 格式 | 处理 |
|------|------|------|
| `build/Release/better_sqlite3.node` | Mach-O | 重建 |

版本 11.10.0。本地数据层（drizzle-orm + migrations/）依赖，主 bundle 顶层静态 require，启动硬性依赖。

## 3. `node_modules/keytar` — **可选，源码重建**

| 文件 | 格式 | 处理 |
|------|------|------|
| `build/Release/keytar.node` | Mach-O | 重建 |

版本 7.9.0。OS 钥匙串；Linux 走 libsecret（构建需 `libsecret-devel`，运行需 `libsecret`）。入口 stub 将其列为关键模块做存在性检查（仅检查 package.json 存在）。

## 4. `node_modules/zstd-napi` — **可选，源码重建**

| 文件 | 格式 | 处理 |
|------|------|------|
| `build/Release/binding.node` | Mach-O | 重建 |

版本 0.0.12。压缩库，主 bundle 顶层静态 require。

## 5. `node_modules/uiohook-napi` — **可选，源码重建**

| 文件 | 格式 | 处理 |
|------|------|------|
| `prebuilds/darwin-x64/uiohook-napi.node` | Mach-O | 删除 |
| `build/Release/uiohook_napi.node` | Mach-O | 重建 |

版本 1.5.5。全局输入钩子（语音按键等）。Linux 构建需 `libXtst-devel`/`libX11-devel`。

## 6. `sharp` + `@img/sharp-darwin-x64` + `@img/sharp-libvips-darwin-x64` — **平台包替换**

| 包 | 版本 | 处理 |
|----|------|------|
| `sharp`（JS） | 0.34.5 | 保留（纯 JS 加载器） |
| `@img/sharp-darwin-x64` | 0.34.5 | 删除 → 安装 `@img/sharp-linux-x64@0.34.5` |
| `@img/sharp-libvips-darwin-x64` | 1.2.4 | 删除 → 安装 `@img/sharp-libvips-linux-x64@1.2.4` |

图像处理（缩略图/封面生成）。主 bundle 顶层静态 require sharp。

## 7. `@esbuild/darwin-x64` — **平台包替换**

版本 0.25.12。canvas/writing 内嵌 vite 服务（legokits/canvas/vite-server-worker.cjs）运行时依赖 esbuild 二进制。删除 darwin 版，安装 `@esbuild/linux-x64@0.25.12`。

## 8. `@rollup/rollup-darwin-x64` — **平台包替换**

版本 4.60.4。vite 构建链。删除，安装 `@rollup/rollup-linux-x64-gnu@4.60.4`（可选，失败仅告警）。

## 9. `@nut-tree-fork/libnut-darwin` — **平台包替换（关键）**

版本 2.7.5。桌面自动化（nut.js，鼠标/键盘模拟）。

- 删除 `libnut-darwin`，安装 `@nut-tree-fork/libnut-linux@2.7.5`；
- **关键**：入口 stub `out/main/index.js` 的 criticalModules 检查在 Linux 平台强制要求 `app.asar.unpacked/node_modules/@nut-tree-fork/libnut-linux/package.json` 存在，否则弹窗拒绝启动；
- asar 头部已注册 libnut-linux 的全部条目（含 `build/Release/libnut.node`），但 macOS DMG 的磁盘 sidecar 未附带该目录——必须从 npm 补齐。

## 10. `node_modules/fsevents` — **macOS 专用，直接删除**

版本 2.3.3。macOS 文件系统事件 API；Linux 用 inotify（chokidar 自动适配）。

## 11. `node_modules/node-mac-permissions` + `@nut-tree-fork/node-mac-permissions` — **macOS 专用，删除**

版本 2.5.0。optionalDependency，仅 darwin 代码路径引用。

## 12. `@qoder/*` 私有原生包 — **门控确认后删除**

| 包 | 内容 | 处理 |
|----|------|------|
| `@qoder/mac-notifier` | `qoderwork_mac_notifier.node`（Mach-O） | 删除；asar 内 JS 包装层非 darwin 返回 noop，上层回退 Electron Notification |
| `@qoder/mac-drag-session` | `qoderwork_mac_drag_session.node`（Mach-O） | 删除；同上 noop 门控 |
| `@qoder/security-guard` | `build/Release/qoderwork_security_guard.node` + `vendor/mac/SecurityGuardSDKMac.framework`（数百文件） | 整包删除；主 bundle `loadSecurityGuardNative()` 平台门控，Linux 返回 unavailable 桩 |
| `@qoder/dji-mic-win` | Windows 专用 | 整包删除 |
| `@qoder/windows-input-hook` | Windows 专用 | 整包删除 |

## 13. `Resources/bin/` — **逐个处置**

| 文件 | 格式 | 处理 |
|------|------|------|
| `qoderclicn`（108MB） | Mach-O 可执行 | 删除，从官方 CDN 下载 Linux 版（见 docs/porting-notes.md §2.1） |
| `open-with-helper` | Mach-O 可执行 | 删除（macOS "打开方式"辅助） |
| `fn_key_tap.node` | Mach-O | 删除（`loadMacAddon()` darwin 门控） |

## 14. `@qoder-ai/qoder-agent-sdk/dist/_worker/vendor/ripgrep/x64-darwin/` — **替换**

`rg`（Mach-O）→ 安装 `@vscode/ripgrep` 的 Linux 二进制到 `x64-linux/rg`。Agent 工作线程的文件搜索依赖。

## 15. 平台无关（保留不动）

`clipboardy@2.3.0`（Linux 走系统 `xsel`，声明为运行时依赖）、`jszip`、`@qoder-ai/qoder-agent-sdk` 的 JS/worker 运行时、`qoder-auth-wasm`（WASM）、`vm-boot/`（VM 客户机 rootfs 覆盖层，客户机本就是 Linux ELF，但宿主机 hypervisor 无 Linux 版，VM 功能整体降级）、全部 skills/legokits/migrations/模板资源。

## 处理策略总结

| 策略 | 模块 |
|------|------|
| 源码重建（关键） | `node-pty@1.1.0`、`better-sqlite3@11.10.0` |
| 源码重建（可选） | `keytar@7.9.0`、`zstd-napi@0.0.12`、`uiohook-napi@1.5.5` |
| 平台包替换（版本对齐） | sharp/libvips/esbuild/rollup/libnut 的 linux-x64 版 |
| 官方 CDN 下载 | `qoderclicn` Linux x64（glibc+baseline+musl 三变体自动选择） |
| 替换 Linux 二进制 | agent-sdk 的 vendored ripgrep |
| 直接删除（门控保护） | fsevents、node-mac-permissions×2、@qoder/mac-*、@qoder/*-win、@qoder/security-guard、bin 内 Mach-O |
| 不可移植（降级） | VM 沙盒（无 Linux hypervisor/镜像）、原生 Updater（无 Linux 二进制） |
