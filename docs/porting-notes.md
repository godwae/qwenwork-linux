# QwenWorkCN macOS → Linux 移植笔记

> 分析对象：`qwenworkcn-darwin-x64.dmg`（QwenWorkCN 0.1.6，构建号 26080702，2026-08-07 打包）
> 工具链蓝本：`workbuddy-linux`（WorkBuddy macOS→Linux 转换器）

## 1. 应用结构剖析

### 1.1 DMG 与 .app 布局

```
千问办公 Installer/
└── QwenWorkCN.app
    └── Contents/
        ├── Info.plist                 # CFBundleIdentifier=cn.qwenwork.desktop.mac
        │                              # CFBundleShortVersionString=0.1.6, build=26080702
        │                              # URL scheme: qwenwork-cn
        ├── MacOS/
        │   ├── QwenWorkCN             # 37KB Electron 入口壳（Mach-O x86_64）
        │   └── Updater                # 3.1MB 原生 Rust 更新器（Mach-O，仅 mac/win）
        ├── Frameworks/                # Electron Framework 37.10.3 + Squirrel/Mantle/ReactiveObjC
        │   └── QwenWorkCN Helper*.app # GPU/Renderer/Plugin 辅助进程
        └── Resources/
            ├── app.asar               # 152MB，446 个 npm 包 + out/ 构建产物
            ├── app.asar.unpacked/     # 原生模块与无法入 asar 的内容
            ├── app-update.yml         # electron-updater generic feed（static.qoder.com.cn）
            ├── icon.icns / tray-icon.png / trayTemplate*.png / window-icon.ico
            ├── bin/                   # qoderclicn(108MB Mach-O CLI)、open-with-helper、fn_key_tap.node
            ├── skills/ skills-market/ # Agent 技能包（平台无关 markdown）
            ├── legokits/              # canvas/writing/ai-slides 等工作流套件
            ├── migrations/            # drizzle-orm SQLite 迁移（better-sqlite3）
            ├── awareness-templates/   # SOUL.md 等 Agent 人格模板
            ├── canvas/ writing/       # 内嵌 Web 子应用（index.html）
            ├── chrome-extension/ + native-messaging-host/  # 浏览器扩展桥
            ├── vm-boot/               # VM 客户机 rootfs 覆盖层（qoderexecd 为 Linux ELF!）
            ├── ps/ qoder-auth-wasm/   # 安全数据 / 认证 WASM（平台无关）
            ├── commands/ dynamic-text/ plugins-example/
            └── plugin-market-data.json / skill-market-data.json
```

### 1.2 asar 内部结构（electron-vite 产物）

```
out/
├── main/
│   ├── index.js          # 入口 stub（10KB）：app 名/userData 初始化、关键模块自检、加载 main
│   ├── main.js           # 主 bundle（4.7MB minified）：全部主进程逻辑
│   ├── entry-harmony.js  # OpenHarmony 适配（process.platform==="openharmony"，Linux 下惰性）
│   ├── chunks/           # 20 个共享 chunk（含平台常量 constants-DjvoVeX3.js）
│   └── *-worker.js       # 5 个 worker（浏览器扩展中继/连接器/迁移等）
├── preload/index.js      # 渲染进程桥（contextIsolation）
└── renderer/             # index.html + assets（React 应用，平台无关）
```

平台常量（`out/main/chunks/constants-DjvoVeX3.js`，主 bundle 中记为 `constants$2`）：

| 导出键 | 语义 | 值 |
|--------|------|-----|
| `.o` | isMac | `platform==="darwin"` |
| `.s` | isWindows | `platform==="win32"` |
| `.n` | isLinux | `platform==="linux"` |
| `.m` | isOpenHarmony | `platform==="openharmony"` |
| `.a` | 非 MS Store 分发 | 恒 true（website 渠道） |
| `.l` | isDev | 恒 false（此构建） |
| `.y` | 产品名 | "千问办公"（按语言解析） |

**重要**：`process.platform` 分支统计 win32×16、darwin×10、linux×1——上游代码是显式跨平台设计（同一代码库出 mac/win 两包），大量分支是"mac 特例，否则走通用路径"，Linux 大多能落到合理默认路径。

## 2. 运行时架构关键发现

### 2.1 内置 Agent CLI（qoderclicn）——可完整移植

- DMG 内 `Resources/bin/qoderclicn` 是 Bun 编译的 108MB Mach-O 单文件可执行体；
- 主进程定位逻辑：`path.join(process.resourcesPath, "bin", "qoderclicn")`（非 win32 一律用裸名），且支持 `QODER_CLI_PATH` 环境变量覆盖；
- `@qoder-ai/qoder-agent-sdk`（v1.0.15）的 `scripts/postinstall.cjs` 官方支持按平台下载 CLI：
  - CN 站：`https://static.qoder.com.cn/qoder-cli-cn/releases/<ver>/qoderclicn-<target>.tar.gz`
  - 全球站：`https://download.qoder.com/qodercli/releases/...`（前缀 `qodercli`）
  - target 选择：musl→`linux-x64-musl`；glibc+AVX2→`linux-x64`；glibc 无 AVX2→`linux-x64-baseline`（aarch64 另有 linux-arm64[-musl]）
  - 版本锁定：SDK package.json 的 `qoderCliVersion: 1.0.47`
- 已实测三个 Linux x64 变体在 CN CDN 均存在（HTTP 200）→ `scripts/lib/qwenwork-cli.sh` 自动下载安装，**CLI 功能零降级**。

### 2.2 Agent 沙盒 VM——不可移植（唯一核心降级）

- 架构：宿主机 hypervisor（macOS=vfkit 系 `startHvkitMac`、Windows=hvkit 系 `startHvkitWin`）+ 客户机 Linux（`vm-boot/root/usr/local/bin/qoderexecd/qoderexecd` 为静态链接 ELF x86-64）；
- VM 镜像运行时从 CDN 下载：`assets.qwenwork.cn/qwenworkcli/vm/releases/0.1.7/latest.json`，实测仅含 `darwin-arm64` / `darwin-amd64` / `windows-x86_64` 三种构件；
- `startVirtualHost()` 仅二分 darwin/win32，无 Linux 实现 → 补丁将其在 Linux 下短路为优雅跳过，Agent 任务回退为无沙盒直接执行（与 WorkBuddy 移植的沙盒降级同类）。

### 2.3 自动更新器——Linux 下显式禁用

- 自研原生更新器：`NativeUpdaterProvider` 驱动 `MacOS/Updater`（Rust 二进制，仅 mac/win）；OpenHarmony 走 `HarmonyUpdateProvider`；
- Linux 下 `resolveUpdaterBinaryPath()` 返回 null，各项操作会报 "Updater binary not found"；
- 更新菜单项由 `constants$2.a`（非 MS Store，恒 true）门控 → Linux 会显示，故打补丁：`init()` 在 Linux 直接 `setDisabled(...)`，UI 呈现"不支持自动更新"的干净状态。

### 2.4 托盘与窗口——上游已内置 Linux 支持（无需补丁）

- 托盘：`TrayService.createTray()` 非 darwin 平台使用 `resources/tray-icon.png`（DMG 内已提供），`buildMenu()` 通过 `setContextMenu()` 挂菜单——满足 AppIndicator 的要求；click/right-click 事件在 AppIndicator 下不触发属已知行为，菜单可用；
- 窗口：`(isWin||isLinux||isOHOS) && { frame: <isMainWindow>, autoHideMenuBar: true }`——Linux 主窗口为原生窗框（无需像 WorkBuddy 注入自定义窗口按钮），`titleBarStyle:"default"`；
- userData：入口 stub 已有 Linux 分支（`XDG_CONFIG_HOME || ~/.config` + `QwenWorkCN`）；
- 窗口图标：Linux 分支读 `<asar>/build/icons/app/icon.png`，上游 asar 无 `build/` 树 → 补丁注入转换后的 PNG，恢复正确窗口图标。

### 2.5 与 WorkBuddy 移植的差异对照

| 维度 | WorkBuddy 4.22.10 | QwenWorkCN 0.1.6 |
|------|-------------------|-------------------|
| Electron | 41.1.1 | 37.10.3 |
| 巨型 env（E2BIG） | 有（ACC_PRODUCT_CONFIG_V3，260KB）→ 需 Proxy shim | **无** → 不需要 |
| 托盘菜单/图标 | 需补丁 | 上游已支持 Linux |
| 窗口按钮 | frame:false 需注入按钮 | 原生 frame，无需处理 |
| 内置 CLI | sidecar + @lydell/node-pty 平台包注入 | qoderclicn 单文件，官方有 Linux 版可下载 |
| 沙盒 | 私有 sandbox（不可移植） | VM 镜像（不可移植） |
| 更新器 | ShipIt/Squirrel | 自研 Updater 二进制 |
| 散装 Resources | 少 | 多（16 目录+4 文件，必须拷贝） |

## 3. 原生模块处置总表

详见 `docs/native-module-audit.md`。摘要：

| 策略 | 模块 |
|------|------|
| 源码重建（关键） | `node-pty@1.1.0`、`better-sqlite3@11.10.0` |
| 源码重建（可选） | `keytar@7.9.0`、`zstd-napi@0.0.12`、`uiohook-napi@1.5.5` |
| 安装 Linux 平台包（版本对齐） | `@img/sharp-linux-x64@0.34.5`、`@img/sharp-libvips-linux-x64@1.2.4`、`@esbuild/linux-x64@0.25.12`、`@rollup/rollup-linux-x64-gnu@4.60.4`、`@nut-tree-fork/libnut-linux@2.7.5` |
| 官方 CDN 下载 Linux 版 | `resources/bin/qoderclicn@1.0.47`（qwenwork-cli.sh） |
| 替换 Linux 二进制 | agent-sdk `vendor/ripgrep/x64-darwin` → `x64-linux`（@vscode/ripgrep） |
| 直接删除（macOS 专用） | `fsevents`、`node-mac-permissions`、`@qoder/mac-notifier`、`@qoder/mac-drag-session`、`@qoder/security-guard`、`bin/fn_key_tap.node`、`bin/open-with-helper` |
| 直接删除（Windows 专用） | `@qoder/dji-mic-win`、`@qoder/windows-input-hook` |
| 纯 JS 无需处理 | `clipboardy@2.3.0`（运行时依赖系统 `xsel`）、`jszip` 等 |

### 平台门控审计（删除安全性依据）

以下模块的 JS 包装层已做平台门控，Linux 下删除原生文件不会引发崩溃：

- `@qoder/mac-notifier`：`if (process.platform !== "darwin") module.exports = noop`
- `@qoder/mac-drag-session`：仅 darwin 加载，否则导出 noop
- `@qoder/security-guard`：`loadSecurityGuardNative()` 非 win32/darwin/openharmony 直接返回 unavailable 桩
- `fn_key_tap`：`loadMacAddon(){ if(!constants$2.o) return null; ... }`
- `node-mac-permissions`：optionalDependency + 仅 darwin 引用

## 4. asar 补丁明细（scripts/lib/apply-linux-patches.js）

| # | 目标文件 | 锚点 | 内容 |
|---|----------|------|------|
| 1 | `out/main/index.js` | 文件头 prepend | `Module.globalPaths` 注入 `app.asar.unpacked/node_modules`（让 asar 内代码能 require 到磁盘上的 Linux 平台包） |
| 2 | `out/main/main.js` | `NativeUpdaterProvider.async init(){...` | Linux 下 `setDisabled` 并 return |
| 3 | `out/main/main.js` | `async function startVirtualHost(r){...}` | Linux 下告警并返回 false |
| 4 | `out/main/main.js` | `function startManifestCheck(){...` | Linux 下跳过一次性的 VM 清单检查 |
| 5 | asar 结构 | — | 注入 `build/icons/app/icon.png`（Linux 窗口图标）；注入 5 个 Linux 平台包为 unpacked 条目；丢弃已删除文件的头部引用 |

重打包保留原 unpacked 布局（按原头部计算"完全 unpacked 目录"集合生成 `unpackDir` glob），磁盘上的 `app.asar.unpacked/`（含重建好的 Linux 原生模块）保持不动。

## 5. 首次 Linux 验证清单

```bash
bash scripts/install-deps.sh
make check
make build-app
./qwenwork-app/start.sh --verbose
```

- 若窗口不出现：检查 GPU 子进程（启动器已带 `--in-process-gpu`）；
- 若终端失败：`ldd qwenwork-app/resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node`；
- 若数据库失败：`ldd .../better-sqlite3/build/Release/better_sqlite3.node`；
- 若 Agent 无法启动 CLI：确认 `resources/bin/qoderclicn` 为 ELF x86-64 且可执行；
- 剪贴板异常：确认已安装 `xsel`。
