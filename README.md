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
  <img src="https://img.shields.io/badge/版本适配-1.0.1_(2026--08--26_正式版)-0052D9?style=flat&logo=probot&logoColor=white" alt="Supported Version">
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

非官方社区工具，将你自行获取的官方**千问办公 (QwenWorkCN) macOS Intel/x64 DMG**转换为可在 Linux x64 运行的 Electron 应用。

本仓库**仅作为转换工具**，不分发任何官方软件：请从官方渠道下载正版 DMG 放入 `downloads/`，产物仅保留本地且已加入 Git 忽略规则。

工具链架构借鉴 [workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux)，并针对 QwenWorkCN 做了适配（差异对照见 [docs/porting-notes.md](docs/porting-notes.md)）。

## 特性亮点

- **一键转换**：DMG 放入 `downloads/`，四条命令完成构建，自动识别发行版产出 deb / rpm / pkg.tar.zst
- **CLI 完整移植**：自动下载官方 Linux 版 `qoderclicn`（按 glibc/musl 与 AVX2 选择变体）
- **原生模块 Linux 化**：5 个原生模块针对 Electron 37.10.3 重建，平台包版本对齐 DMG，产物 100% ELF
- **最小补丁面**：asar 补丁覆盖 8 处关键点，采用正则化锚点，上游 minifier 重命名常量时自动适配
- **安全构建**：零硬删除（隔离式移动），依赖自动识别（apt / dnf5 / dnf / pacman / zypper）

## 版本适配说明

已基于官方 **1.0.0**（2026-08-24）与 **1.0.1**（build `26082607`，Electron `37.10.3`）验证通过，并在 `0.1.6` / `0.1.7` / `0.1.8` 上完成实测。补丁采用正则化锚点，上游发版重命名常量时自动适配，不会硬失败。

遇到构建失败或运行异常，请附上 DMG 版本号提 Issue。

## 快速安装

1. 克隆本项目；
2. 从官方渠道下载 **Intel/x64** 架构 DMG，放入 `downloads/`（仅放**唯一一份**）；
3. 依次执行：

```bash
make deps
make build-app
make package
make install
```

`scripts/install-deps.sh` 会自动识别包管理器（apt / dnf5 / dnf / pacman / zypper），一键装齐依赖。

## 构建与运行

```bash
make build-app                     # 使用 downloads/ 下唯一的 DMG
make build-app DMG=/path/to/dmg    # 手动指定 DMG 路径
make run-app                       # 直接运行生成的应用（未安装）
make fix-rpaths                    # 就地清理原生模块里的构建机私有 RPATH
make package                       # 按当前发行版生成 deb/rpm/pkg.tar.zst（按 /etc/os-release 自动识别）
make install                       # 本地安装最新产物
make check-update                  # 查询官方是否发布新版本（免登录）
make clean                         # 清理构建产物
make check                         # bash 语法自检
```

## 实现原理

1. `7z` 提取 DMG 内的 `QwenWorkCN.app`，识别上游 Electron 版本并替换为 Linux 运行时；
2. 复制应用载荷（`app.asar` + unpacked + 16 个资源目录）；
3. 原生模块（`node-pty`、`better-sqlite3`、`keytar`、`zstd-napi`、`uiohook-napi`）从源码重建为 ELF，Linux 平台包按 DMG 版本对齐安装，并下载官方 Linux 版 `qoderclicn`；
4. 对 `app.asar` 应用 Linux 补丁并重打包，生成启动器、桌面入口、图标与各发行版安装包。

## 移植后的已知限制

1. **Agent 沙盒 VM 不可用**：上游仅发布 darwin/windows 构件，Linux 下自动跳过，Agent 回退无沙盒直接执行。**这是唯一的核心功能降级。**
2. **自动更新禁用**：原生 Updater 仅 macOS/Windows 版。需更新请下载新版 DMG 重新构建。
3. **macOS 专属能力降级**：原生通知、拖拽面板、mac 权限等回退 Electron 标准 API，不影响主流程。
4. **剪贴板依赖 xsel**：Wayland 会话下的体验取决于 XWayland 的 xsel 兼容性。

## 常用自定义配置

```bash
PACKAGE_FORMAT=rpm make package                # 强制指定打包格式（deb/rpm/pacman）
QWENWORK_INSTALL_DIR=/opt/tmp/qwenwork-app bash install.sh               # 自定义安装目录
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ bash install.sh  # Electron 镜像源
ELECTRON_HEADERS_URL=https://artifacts.electronjs.org/headers/dist bash install.sh  # 头文件地址
QODER_CLI_VERSION=1.0.47 bash install.sh                                 # 指定内置 CLI 版本
QODER_CLI_PATH=/path/to/qoderclicn bash qwenwork-app/start.sh            # 运行时自定义 CLI 路径
QWENWORK_OZONE_PLATFORM=wayland ./qwenwork-app/start.sh                  # 切换 ozone 平台
```

## 排障

- **界面卡顿 / 启动慢（NVIDIA + Wayland）**：原生 Wayland 下 NVIDIA 触发 GPU 崩溃循环并回退软件渲染 → 启动器默认 XWayland（`--ozone-platform=x11`）；改用原生 Wayland：`QWENWORK_OZONE_PLATFORM=wayland ./qwenwork-app/start.sh`。核验：`grep -c libGLX_nvidia /proc/<gpu-pid>/maps`。
- **升级新版 DMG 后卡顿**：上游 minifier 重排常量导致补丁锚点静默失效 → 重建后检查构建日志的 `patched ...` 行是否齐全、有无 `WARN: ... anchor not found`。
- **`make rpm` 报 `ERROR 0002: file '...' contains an invalid rpath '/home/<user>/anaconda3/lib'`**：conda / Anaconda / Linuxbrew 的 `gcc` 排在 `PATH` 前面，它每链接一个动态库都会注入 `-Wl,-rpath,<前缀>/lib`（为了找到自带的 libstdc++），于是 `node-pty`、`better-sqlite3` 等源码重建的 `.node` 被烙上构建机私有路径，rpmbuild 的 `check-rpaths` 因此拒绝打包 → 旧产物执行 `make fix-rpaths` 就地剥离（保留 `$ORIGIN` 相对路径）；新构建已强制使用系统编译器（`/usr/bin/gcc`）并清空 `LDFLAGS`/`LD_RUN_PATH`/`LIBRARY_PATH`，另在重建后自动做一遍 RPATH 清理，无需手动干预。
- **`make rpm` / `make package` 报 `Bad exit status from rpm-tmp ... (%install)/(rmbuild)`**：本机若运行着 WorkBuddy（或其它通过 `$BASH_ENV` 注入命令垫片的工具），其 `rm` 垫片会在 rpmbuild/makepkg 的构建与清理阶段拦截批量删除并提示确认，导致 rpmbuild 中途失败。已内置修复：打包脚本用 `env -i`（纯净环境）启动 rpmbuild / makepkg，自动丢弃继承的 PATH 垫片、`$BASH_ENV` 与 `BASH_FUNC_rm*` 函数，无需手动干预。若仍失败，可手动验证：`command -v rm` 应为 `/usr/bin/rm`。
- **启动报 `bad option: --no-sandbox`**：环境导出了 `ELECTRON_RUN_AS_NODE=1` → `env -u ELECTRON_RUN_AS_NODE ./qwenwork-app/start.sh`
- **安装包/产物含 `:com.apple.provenance` 之类的侧车文件**：7z 解包 DMG 会把 macOS 的 APFS 扩展属性写成 `<名字>:com.apple.*` 的独立侧车文件（非法冒号文件名，Linux 无用，还会混进 RPM）。已在拷贝 `app.asar.unpacked` 与 Resources 载荷时统一排除（`tar --exclude='*:com.apple.*'`）。旧产物清理：隔离到 `~/.cache/qwenwork-linux/quarantine/` 后重新 `make package`。
- **隔离目录**：被替换的 macOS 二进制与旧构建树移至 `~/.cache/qwenwork-linux/quarantine/`，不硬删，可随时清空。

## 目录结构与维护规范

```
qwenwork-linux/
├── install.sh          # 主构建脚本
├── Makefile            # make deps/build-app/package/install 等入口
├── scripts/            # 依赖安装、打包、DMG 提取、原生模块、asar 补丁
│   └── lib/            # 各阶段实现（dmg/electron/native-modules/cli/linux-patches）
├── packaging/linux/    # deb control 与 desktop 模板
├── docs/               # 架构分析笔记与原生模块审计报告
├── downloads/          # [忽略] 官方 DMG
├── qwenwork-app/       # [忽略] 构建产物
└── dist/               # [忽略] 安装包产物
```

`downloads/`、`build/`、`qwenwork-app/`、`dist/` 已被 Git 忽略，**切勿手动提交** DMG、解压后的 `.app`、生成的应用目录与安装包产物。

## 致谢

工具链架构深度借鉴 [workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux)（[@JipZeonGit](https://github.com/JipZeonGit)，MIT）及其早期实践 [codebuddy-ide-cn-linux](https://github.com/JipZeonGit/codebuddy-ide-cn-linux)。喜欢本项目也请为上游点个 Star。

## 免责声明

本项目为**非官方社区开源工具**，与阿里巴巴/钉钉官方无任何关联。本工具不分发任何官方软件，仅自动化格式转换流程；使用产生的应用仍受官方协议约束。请自行确保 DMG 来源合法并遵守 EULA，工具按"现状"提供、无任何担保。

## 开源许可证

转换脚本采用 MIT 许可，详见 [LICENSE](LICENSE)。MIT 仅覆盖本仓库的转换工具，**不延伸到通过本工具安装的 QwenWorkCN 二进制文件**。

---

## English Summary

An unofficial community tool that converts your legally obtained official QwenWorkCN (千问办公) macOS Intel/x64 DMG into a locally-built Linux x64 Electron application. It never redistributes upstream software: place the DMG into `downloads/`, then run `make deps && make build-app && make package && make install`.

Verified against the official **1.0.0** (2026-08-24) and **1.0.1** (build `26082607`, Electron `37.10.3`), and tested across `0.1.6` / `0.1.7` / `0.1.8`. The asar patches use regex-generalized anchors, so they survive upstream minifier constant renames.

The port swaps in the Linux Electron runtime, rebuilds native modules from source, installs version-aligned Linux platform packages, downloads the official Linux build of the bundled CLI (`qoderclicn`), and applies a small set of asar patches.

Known limitations: the agent sandbox VM is unavailable (no Linux artifacts upstream — agent tasks fall back to unsandboxed execution); auto-update is disabled (Updater binary is macOS/Windows-only); macOS-only integrations degrade to their Electron fallbacks. See `docs/porting-notes.md` for the full analysis.

### Acknowledgements

Toolchain architecture is deeply inspired by [workbuddy-linux](https://github.com/JipZeonGit/workbuddy-linux) by [@JipZeonGit](https://github.com/JipZeonGit) (MIT) and [codebuddy-ide-cn-linux](https://github.com/JipZeonGit/codebuddy-ide-cn-linux). Please consider starring the original repositories.
