<div align="center">

# QwenWorkCN for Linux (Unofficial)

</div>

<div align="center">

千问办公 (QwenWorkCN) 的非官方 Linux 自动化移植与安装构建脚本工具

</div>

<p align="middle">
  <img src="https://img.shields.io/badge/deb-Ubuntu_%7C_Debian_%7C_Linux_Mint-A81D33?style=flat&logo=debian&logoColor=white" alt="Debian Ubuntu Support">
  <img src="https://img.shields.io/badge/arch-ArchLinux_%7C_CachyOS_%7C_Manjaro-1793D1?style=flat&logo=arch-linux&logoColor=white" alt="AUR Package">
  <img src="https://img.shields.io/badge/rpm-Fedora_%7C_RHEL-006699?style=flat&logo=fedora&logoColor=white" alt="Fedora RHEL Support">
  <br>
  <img src="https://img.shields.io/badge/版本适配-1.0.0_(2026-08-24_正式版)-0052D9?style=flat&logo=probot&logoColor=white" alt="Supported Version">
  <img src="https://img.shields.io/badge/Electron-37.10.3-47307B?style=flat&logo=electron&logoColor=white" alt="Electron Version">
  <img src="https://img.shields.io/badge/状态-Unofficial-d73a49?style=flat" alt="Status Unofficial">
  <img src="https://img.shields.io/badge/借鉴-workbuddy--linux-2EA44F?style=flat&logo=heart&logoColor=white" alt="Based on workbuddy-linux">
</p>

---

## 目录

- [项目简介](#项目简介)
- [特性亮点](#特性亮点)
- [版本适配说明](#版本适配说明)
- [快速安装](#快速安装)
- [构建与运行](#构建与运行)
- [实现原理](#实现原理)
- [移植后的已知限制](#移植后的已知限制)
- [常用自定义配置](#常用自定义配置)
- [排障](#排障)
- [目录结构与维护规范](#目录结构与维护规范)
- [致谢](#致谢)
- [免责声明](#免责声明)
- [开源许可证](#开源许可证)
- [English Summary](#english-summary)

---

## 项目简介

这是一款非官方社区工具，核心作用是将你自行获取的官方 **千问办公 (QwenWorkCN) macOS Intel/x64 版本 DMG 安装包**，转换为可在本地 Linux x64 系统运行的 Electron 应用。

本仓库**仅作为转换工具**，绝不充当软件分发渠道。请务必前往官方渠道下载正版 Intel/x64 架构 DMG 安装包，放置于项目 `downloads/` 目录下；所有生成的应用目录、安装包产物均仅保留在本地，且已加入 Git 忽略规则，不会被提交至仓库。

移植工具链的架构设计借鉴了 [workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux)（WorkBuddy macOS→Linux 转换器）的成熟方案，并针对 QwenWorkCN 的应用结构做了全面适配（详见 [docs/porting-notes.md](docs/porting-notes.md) 的架构分析与差异对照表）。

## 特性亮点

- **一键转换**：官方 DMG 放入 `downloads/`，`make deps && make build-app && make package && make install` 四步完成构建安装，自动识别发行版产出 deb / rpm / pkg.tar.zst；
- **内置 CLI 完整移植**：从上游官方 CDN 自动下载 Linux 版 `qoderclicn`（按 glibc/musl 与 AVX2 自动选择变体），Agent 命令行能力零降级；
- **原生模块全量 Linux 化**：5 个原生模块从源码针对 Electron 37.10.3 重建，5 个平台包版本严格对齐 DMG 内 darwin 版本，产物 100% ELF、零 Mach-O 残留（构建期自动终扫校验）；
- **最小补丁面**：QwenWorkCN 无 WorkBuddy 的 E2BIG 环境变量问题，托盘/窗口上游已内置 Linux 分支。asar 补丁覆盖 8 处关键点（模块解析 prelude、桌面入口 `setDesktopName`、更新器禁用、VM 优雅降级 / 清单跳过、GPU 硬件加速守卫、托盘单击恢复窗口、应用内更新检查屏蔽），全部采用"双版本锚点 + 找不到则告警跳过"的容错设计，minifier 重命名常量时自动适配；
- **安全构建**：全程零硬删除（隔离式移动），跨发行版依赖自动识别（apt / dnf5 / dnf / pacman / zypper）。

## 版本适配说明

当前补丁已基于官方 QwenWorkCN **1.0.0**（2026-08-24 正式版，Electron `37.10.3`）验证通过，并已在 `0.1.6` / `0.1.7` / `0.1.8` / `1.0.0` 多个上游版本上完成实测。补丁脚本对每处修改均采用"双版本锚点 + 找不到锚点则告警跳过"的容错设计：上游每次发版 minifier 可能重命名常量（如 `0.1.6→0.1.7` 中 `constants$2.o→q`、`s→t`），脚本会自动尝试多个版本的锚点并选取命中的那一个，不会因常量重命名而硬失败。如遇到构建失败或运行异常，请附上所使用的 DMG 版本号提 Issue。

## 快速安装

1. 克隆本项目至本地 Linux 机器；
2. 自行从官方渠道下载 Intel/x64 架构 DMG 安装包，放入 `downloads/` 目录（仅放**唯一一份**）；
3. 依次执行：

```bash
make deps
make build-app
make package
make install
```

`scripts/install-deps.sh` 会自动识别当前系统的包管理器（支持 `apt`、`dnf5`、`dnf`、`pacman`、`zypper`），一键安装 DMG 提取、Electron 运行时下载、原生模块重建、安装包生成所需的全部依赖。

## 构建与运行

```bash
make build-app                     # 使用 downloads/ 下唯一的 DMG
make build-app DMG=/path/to/dmg    # 手动指定 DMG 路径
make run-app                       # 直接运行生成的应用（未安装）
make package                       # 按当前发行版生成 deb/rpm/pkg.tar.zst
make install                       # 本地安装最新产物
make check-update                  # 查询官方是否发布了新版本（免登录）
make clean                         # 清理构建产物
make check                         # bash 语法自检
```

## 实现原理

1. 以用户自行提供的官方 macOS DMG 安装包作为输入源，用 `7z` 提取 `千问办公 Installer/QwenWorkCN.app`；
2. 从 `Electron Framework.framework` 的 Info.plist 自动识别上游 Electron 版本（37.10.3），下载匹配的 Linux Electron 运行时替换 macOS 运行时；
3. 复制应用载荷：`app.asar` + `app.asar.unpacked` + `Contents/Resources` 下的散装资源目录（`skills/`、`legokits/`、`migrations/`、`bin/`、`vm-boot/` 等 16 个目录与 4 个数据文件，见 `install.sh` 的 `RESOURCE_PAYLOAD_*`）；
4. **原生模块从源码重新编译**：`node-pty`、`better-sqlite3`（关键）与 `keytar`、`zstd-napi`、`uiohook-napi`（可选）针对 Linux Electron 头文件重建为 ELF；
5. **安装 Linux 平台包**（版本与 DMG 内 darwin 包严格对齐）：`@img/sharp-linux-x64`、`@img/sharp-libvips-linux-x64`、`@esbuild/linux-x64`、`@rollup/rollup-linux-x64-gnu`、`@nut-tree-fork/libnut-linux`；
6. **内置 CLI 完整移植**：从上游官方 CDN（`static.qoder.com.cn/qoder-cli-cn`）下载与 SDK 锁定版本一致的 Linux 版 `qoderclicn`（glibc+AVX2 / glibc baseline / musl 三种变体按本机自动选择），放入 `resources/bin/`——主进程无需任何修改即可识别；
7. 对 `app.asar` 应用 Linux 运行时补丁（模块解析 prelude、更新器/VM 优雅降级、Linux 平台包注入、窗口图标注入），重打包时保留原有 unpacked 布局；
8. 生成 Linux 启动器、桌面入口与图标，产出对应发行版的原生安装包。

与 WorkBuddy 移植的关键差异：QwenWorkCN **不存在** `ACC_PRODUCT_CONFIG_V3` 超大环境变量（无 E2BIG 问题）、托盘与窗口代码**上游已内置 Linux 分支**（`tray-icon.png` + `setContextMenu` + 原生窗框），因此补丁面大幅缩小，详见 [docs/porting-notes.md](docs/porting-notes.md)。

## 移植后的已知限制

1. **Agent 沙盒 VM 不可用**：QwenWork 的代码执行沙盒是一个从 CDN 下载的 VM 镜像（宿主机 hypervisor 为 macOS 的 vfkit / Windows 的 hvkit）。上游 `assets.qwenwork.cn/qwenworkcli/vm` 仅发布 darwin/windows 构件，无 Linux 版本。Linux 移植版会在启动时干净地跳过 VM 检查（补丁 3b/3c），Agent 任务回退为无沙盒直接执行。**这是唯一的核心功能降级。**
2. **自动更新禁用**：应用内更新依赖仅提供 macOS/Windows 版本的原生 Rust `Updater` 二进制。Linux 下更新器被显式置为 disabled（补丁 3a）。如需更新，下载新版 DMG 重新执行构建即可。
3. **macOS 专属能力降级**：原生通知面板（`@qoder/mac-notifier`）、拖拽授权面板（`@qoder/mac-drag-session`）、`node-mac-permissions`、`fn_key_tap` 等 macOS 私有能力在 Linux 不可用——上游 JS 包装层已做平台门控，会自动回退到 Electron 标准 API（如 Electron Notification），不影响主流程。
4. **剪贴板依赖 xsel**：主进程剪贴板模块（clipboardy）在 Linux 下调用系统 `xsel`，已声明为安装包依赖（Wayland 会话下剪贴板体验取决于 XWayland 的 xsel 兼容性）。

## 常用自定义配置

```bash
# 自定义安装目录
QWENWORK_INSTALL_DIR=/opt/tmp/qwenwork-app bash install.sh
# 切换 Electron 镜像源
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ bash install.sh
# 自定义 Electron 头文件下载地址
ELECTRON_HEADERS_URL=https://artifacts.electronjs.org/headers/dist bash install.sh
# 指定内置 CLI 版本（默认读取 agent-sdk 的 qoderCliVersion 锁定值）
QODER_CLI_VERSION=1.0.47 bash install.sh
# 运行时使用自定义 CLI 路径（应用原生支持）
QODER_CLI_PATH=/path/to/qoderclicn bash qwenwork-app/start.sh
```

## 排障

- **界面卡顿 / 启动慢（NVIDIA + Wayland）**：Chromium 原生 Wayland 下 NVIDIA 驱动会触发 GPU 进程崩溃循环（`Context was lost` / dmabuf modifier 错误）并静默回退 SwiftShader 软件渲染。启动器默认使用 XWayland（`--ozone-platform=x11`，已验证 NVIDIA GLX 硬件加速正常）；若你使用 Intel/AMD 显卡或驱动已修复，可切回原生 Wayland：`QWENWORK_OZONE_PLATFORM=wayland ./qwenwork-app/start.sh`。核验方法：`ps -eo args | grep qwenwork-app/electron | grep gpu-process`，其 `/proc/<pid>/maps` 中出现 `libGLX_nvidia` 即为硬件渲染。
- **`make package` 在部分开发壳环境下失败（Bad exit status from rpm-tmp）**：若 shell 环境设置了 `BASH_ENV`/`NODE_OPTIONS`（如某些 AI 助手会话注入的 rm 安全垫片），rpmbuild 内部清理脚本会被劫持。在干净 shell 中构建，或使用：
  `env -u BASH_ENV -u NODE_OPTIONS PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin make package`
- **升级新版 DMG 重建后界面卡顿**：上游每次发版 minifier 可能重命名常量（0.1.6→0.1.7 中 `constants$2.o→q`、`s→t`，1.0.0 亦曾重排常量），导致部分 asar 补丁锚点失效、GPU 硬件加速等补丁静默未应用。本工具已支持多版本锚点自动适配（`0.1.6` / `0.1.7` / `0.1.8` / `1.0.0`）；重建后请检查构建日志中全部 `patched ...` 行是否齐全，若有 `WARN: ... anchor not found` 需更新锚点。可用 `scripts/check-upstream-version.sh` 之外，用 `grep -c "libGLX_nvidia" /proc/<gpu-pid>/maps` 核验硬件渲染。
- **隔离目录**：本工具链对"删除"采用隔离式移动（rename），不会硬删任何文件。被替换的 macOS 二进制与旧构建树存放在 `~/.cache/qwenwork-linux/quarantine/`（/tmp 下的目标在 `/tmp/.qwenwork-linux-quarantine/`），可随时清空。
- **启动报 `bad option: --no-sandbox`**：当前 shell 导出了 `ELECTRON_RUN_AS_NODE=1`（Node 开发环境常见）。`start.sh` 已内置防御性 `unset`，或手动 `env -u ELECTRON_RUN_AS_NODE ./qwenwork-app/start.sh`。

## 目录结构与维护规范

```
qwenwork-linux/
├── install.sh                 # 主构建脚本（编排全部 8 个阶段）
├── Makefile                   # make deps/build-app/package/install 等入口
├── scripts/
│   ├── install-deps.sh        # 发行版依赖一键安装（apt/dnf/pacman/zypper）
│   ├── package.sh             # 自动识别打包格式
│   ├── build-{deb,rpm,pacman}.sh
│   ├── install-package.sh
│   └── lib/
│       ├── common.sh          # 日志/工具 + 隔离式删除（bulk_rm）
│       ├── dmg.sh             # DMG 提取与 Electron 版本识别
│       ├── electron.sh        # Linux Electron 运行时下载
│       ├── native-modules.sh  # 原生模块清理/重建/平台包安装
│       ├── qwenwork-cli.sh    # 官方 Linux qoderclicn 下载
│       ├── linux-patches.sh   # asar 补丁编排
│       └── apply-linux-patches.js  # asar 补丁实现（重打包）
├── packaging/linux/           # deb control 与 desktop 模板
├── docs/                      # 架构分析笔记与原生模块审计报告
├── downloads/                 # [忽略] 存放官方 DMG
├── qwenwork-app/              # [忽略] 构建产物（应用目录）
└── dist/                      # [忽略] 安装包产物
```

以下目录因会存放上游软件、生成类安装包文件，已被 Git 忽略，**切勿手动提交**：

- `downloads/`
- `build/`
- `qwenwork-app/`
- `dist/`

禁止提交 DMG 安装包、解压后的 `.app` 应用包、生成的 Linux 应用目录及各类原生安装包产物。

## 致谢

本项目的工具链架构、构建流水线与打包方案深度借鉴了以下开源项目，在此致以诚挚感谢：

- **[workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux)**（作者 [@JipZeonGit](https://github.com/JipZeonGit)，MIT License）—— WorkBuddy macOS→Linux 转换器。本项目的 `install.sh` 流水线设计、原生模块重建策略（`@electron/rebuild` 隔离目录编译）、asar 补丁与重打包方案（unpacked 布局保留）、三格式打包脚本均以它为蓝本，并针对 QwenWorkCN 的载荷结构与平台特性做了适配与扩展（内置 CLI 的官方 Linux 构件下载、更小的补丁面、隔离式删除等）；
- **[codebuddy-ide-cn-linux](https://github.com/JipZeonGit/codebuddy-ide-cn-linux)**（同作者的另一成功移植案例）—— workbuddy-linux 所参考的早期移植实践，为整个方法论奠定了基础。

如果你喜欢本项目，也请为上游项目点个 Star 支持原作者。

## 免责声明

本项目为**非官方社区开源工具**，与阿里巴巴/钉钉官方无任何关联。QwenWorkCN（千问办公）是阿里巴巴集团旗下产品。本工具不分发任何官方软件，仅自动化实现用户对自有正版安装包的格式转换流程。使用本工具产生的应用仍受官方协议约束。使用本工具即表示您已知悉：您有责任确保 DMG 来源合法并遵守 EULA；本工具按"现状"提供、无任何担保；官方不为 Linux 移植环境提供技术支持；一切后果由用户自行承担。如权利方存在异议，请联系维护者，将在收到合理异议后立即处理。

## 开源许可证

本项目（转换脚本及相关 recipe）采用 MIT 开源许可证，详细内容请查看 [LICENSE](LICENSE) 文件。MIT 许可仅覆盖本仓库中的转换工具，**不延伸到通过本工具安装的 QwenWorkCN 二进制文件**——后者仍受官方私有协议约束。

---

## English Summary

This is an unofficial community tool that converts your legally obtained official QwenWorkCN (千问办公) macOS Intel/x64 DMG into a locally-built Linux x64 Electron application. It never redistributes upstream software: you place the official DMG into `downloads/`, then run `make deps && make build-app && make package && make install`.

Verified against the official QwenWorkCN **1.0.0** stable release (2026-08-24, Electron `37.10.3`), and tested across `0.1.6` / `0.1.7` / `0.1.8` / `1.0.0`. The asar patches use dual-version anchors with graceful fallback, so they survive upstream minifier constant renames between releases.

The port replaces the macOS Electron runtime (37.10.3) with the Linux one, rebuilds native modules (`node-pty`, `better-sqlite3`, `keytar`, `zstd-napi`, `uiohook-napi`) from npm source against Linux Electron headers, installs exact-version Linux platform packages (`@img/sharp-linux-x64`, `@esbuild/linux-x64`, `@rollup/rollup-linux-x64-gnu`, `@nut-tree-fork/libnut-linux`, ...), downloads the official Linux build of the bundled agent CLI (`qoderclicn`) from the upstream CDN, and applies a small set of asar patches (module-resolution prelude, graceful updater/VM degradation, Linux package injection, window icon injection).

Known limitations: the agent sandbox VM is unavailable (upstream ships no Linux hypervisor/VM artifacts — agent tasks fall back to unsandboxed execution); auto-update is disabled (native Updater binary is macOS/Windows-only); macOS-only integrations (native notifier, drag panel, mac permissions) degrade to their upstream-gated Electron fallbacks. See `docs/porting-notes.md` for the full architecture analysis.

### Acknowledgements

This project's toolchain architecture and build pipeline are deeply inspired by:

- **[workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux)** by [@JipZeonGit](https://github.com/JipZeonGit) (MIT License) — the WorkBuddy macOS→Linux converter that serves as our blueprint for the pipeline design, native-module rebuild strategy, asar patching/repacking, and packaging scripts;
- **[codebuddy-ide-cn-linux](https://github.com/JipZeonGit/codebuddy-ide-cn-linux)** — the author's earlier porting practice that laid the foundation for this methodology.

Huge thanks to the upstream author for their excellent work. Please consider starring the original repositories if you find them useful.
