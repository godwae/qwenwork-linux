#!/usr/bin/env node
/**
 * Patch the QwenWorkCN app.asar so it runs correctly on Linux.
 *
 * Compared with the WorkBuddy port, QwenWorkCN needs NO env-spill shim (it
 * never stuffs a giant JSON into process.env) and NO tray patches (upstream
 * already branches to resources/tray-icon.png + setContextMenu on Linux).
 *
 * Patches applied:
 *
 *   1. Prelude shim in out/main/index.js:
 *      add resources/app.asar.unpacked/node_modules to Module.globalPaths so
 *      asar-packed code can require() Linux platform packages that only exist
 *      on disk (@img/sharp-linux-x64, @esbuild/linux-x64, ...). Without this,
 *      require() from inside the asar cannot see packages that were never
 *      registered in the original macOS asar header.
 *
 *   2. NativeUpdaterProvider.init() (out/main/main.js):
 *      early-return with a "disabled" state on Linux. The updater drives a
 *      native Rust "Updater" binary that only ships for macOS/Windows; on
 *      Linux every check would end in a user-visible "Updater binary not
 *      found" error. The state service simply reports auto-update as
 *      disabled instead.
 *
 *   3. VM manifest check + virtual host start (out/main/main.js):
 *      skip cleanly on Linux. Upstream publishes VM artifacts only for
 *      darwin-* / windows-* (assets.qwenwork.cn/qwenworkcli/vm), and the host
 *      hypervisor (hvkit/vfkit) has no Linux build, so the agent sandbox VM
 *      cannot run on a Linux host. Without the patch the boot-time manifest
 *      check throws "No artifact found for platform key: linux-amd64" and
 *      startVirtualHost() would call the Windows code path.
 *
 *   4. Asar header hygiene + Linux package injection:
 *      the original header references hundreds of unpacked files that the
 *      macOS build stripped or that we deliberately deleted (SecurityGuard
 *      vendor framework, mac-only .node files). Those entries are dropped
 *      from the repacked header. Conversely, Linux platform packages
 *      installed on disk by install.sh (sharp/esbuild/rollup/libnut linux
 *      builds) are copied into the asar source tree and registered as
 *      unpacked entries so asar-internal require() finds them.
 *
 * Usage:
 *   node apply-linux-patches.js <path/to/app.asar> <marker>
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const asar = require('@electron/asar');

const [, , asarPath, marker] = process.argv;
if (!asarPath || !marker) {
    console.error('Usage: apply-linux-patches.js <app.asar> <marker>');
    process.exit(2);
}

function log(msg) { console.log('  [apply-linux-patches] ' + msg); }

// ---------------------------------------------------------------------------
// Quarantine helper. This project never hard-deletes build artifacts (see
// scripts/lib/common.sh): targets are moved to a quarantine directory via
// rename. Same end state for the app tree, fully reversible, and friendly
// to environments guarded by delete-interception hooks.
// ---------------------------------------------------------------------------
function quarantineRootFor(target) {
    if (process.env.QWENWORK_QUARANTINE_DIR) return process.env.QWENWORK_QUARANTINE_DIR;
    const abs = path.resolve(target);
    const tmp = os.tmpdir();
    if (abs.startsWith(tmp + path.sep) || abs.startsWith('/tmp/')) {
        return path.join(tmp, '.qwenwork-linux-quarantine');
    }
    const cacheHome = process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
    return path.join(cacheHome, 'qwenwork-linux', 'quarantine');
}
let quarantineSeq = 0;
function quarantine(target) {
    try {
        if (!fs.existsSync(target)) return;
        const dest = path.join(
            quarantineRootFor(target),
            new Date().toISOString().replace(/[:.]/g, '-') + '-' + (quarantineSeq++) + '-' + path.basename(target),
        );
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.renameSync(target, dest);
    } catch (err) {
        console.warn('  [apply-linux-patches] quarantine failed for ' + target + ': ' + (err && err.message));
    }
}

// ---------------------------------------------------------------------------
// 1. Extract the asar into a temp dir (same approach as the WorkBuddy port:
//    read bytes via asar.extractFile / copy unpacked entries from the sibling
//    <asar>.unpacked directory).
//
//    QwenWorkCN difference: unpacked entries whose file is MISSING on disk
//    (deleted macOS-only natives, vendor frameworks stripped by upstream)
//    are SKIPPED entirely so the repacked header no longer references them.
// ---------------------------------------------------------------------------
const { header } = asar.getRawHeader(asarPath);
const unpackedSiblingDir = asarPath + '.unpacked';
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qwenwork-asar-patch-'));
process.on('exit', () => {
    quarantine(tmpDir);
});

let keptUnpacked = 0;
let droppedMissing = 0;
function walk(node, prefix) {
    if (!node.files) return;
    for (const [name, entry] of Object.entries(node.files)) {
        const rel = prefix ? prefix + '/' + name : name;
        const abs = path.join(tmpDir, rel);
        if (entry.files) {
            fs.mkdirSync(abs, { recursive: true });
            walk(entry, rel);
        } else if (entry.link) {
            try {
                fs.mkdirSync(path.dirname(abs), { recursive: true });
                fs.symlinkSync(entry.link, abs);
            } catch (err) {
                console.warn('  [apply-linux-patches] skipped symlink ' + rel + ': ' + err.message);
            }
        } else {
            if (entry.unpacked) {
                const src = path.join(unpackedSiblingDir, rel);
                if (!fs.existsSync(src)) {
                    // File was purged (or never shipped) — drop the header
                    // reference so the new asar does not point at thin air.
                    droppedMissing++;
                    continue;
                }
                fs.mkdirSync(path.dirname(abs), { recursive: true });
                fs.copyFileSync(src, abs);
                const stat = fs.statSync(src);
                fs.chmodSync(abs, stat.mode & 0o777);
                keptUnpacked++;
            } else {
                fs.mkdirSync(path.dirname(abs), { recursive: true });
                const buf = asar.extractFile(asarPath, rel);
                fs.writeFileSync(abs, buf);
                if (entry.executable) {
                    fs.chmodSync(abs, 0o755);
                }
            }
        }
    }
}
walk(header, '');
log('Extracted packed entries + ' + keptUnpacked + ' unpacked files; dropped ' + droppedMissing + ' stale unpacked references');

// ---------------------------------------------------------------------------
// 2. Patch out/main/index.js with the module-resolution prelude.
//    The entry stub is small and stable across builds — a much safer anchor
//    than the 4.7MB minified main.js. It runs before require("./main").
// ---------------------------------------------------------------------------
const SHIM_BODY = `// ${marker} — QwenWorkCN Linux runtime patches
(function qwenworkLinuxShim() {
  if (process.platform !== "linux") return;
  try {
    // The original macOS asar header has no entries for the Linux platform
    // packages we install on disk (@img/sharp-linux-x64, @esbuild/linux-x64,
    // @rollup/rollup-linux-x64-gnu, ...). require() from inside the asar only
    // consults the asar header, then falls back to Module.globalPaths — so we
    // register resources/app.asar.unpacked/node_modules there.
    var pathMod = require("path");
    var fsMod = require("fs");
    var Module = require("module");
    var resourcesPath = typeof process.resourcesPath === "string"
      ? process.resourcesPath
      : pathMod.dirname(process.execPath);
    var unpackedNM = pathMod.join(resourcesPath, "app.asar.unpacked", "node_modules");
    if (fsMod.existsSync(unpackedNM)) {
      if (Module.globalPaths && !Module.globalPaths.includes(unpackedNM)) {
        Module.globalPaths.push(unpackedNM);
      }
    }
  } catch (err) {
    try { console.error("[qwenwork-linux-shim] install failed:", err); } catch (_) {}
  }
  try {
    // Wayland taskbar/dock icon association:
    // On Wayland the compositor resolves a window's icon through its
    // xdg-shell app_id -> matching .desktop file -> Icon= entry. Electron's
    // default app_id does not match our qwenwork-cn.desktop, so the taskbar
    // falls back to the generic "application" icon. app.setDesktopName()
    // (documented Electron API for Linux) pins the xdg app_id / X11 WM_CLASS
    // to the .desktop base name, making KDE/GNOME show the app icon.
    var electron = require("electron");
    var desktopName = process.env.QWENWORK_APP_ID || "qwenwork-cn";
    if (electron && electron.app && typeof electron.app.setDesktopName === "function") {
      electron.app.setDesktopName(desktopName);
    }
  } catch (err) {
    try { console.error("[qwenwork-linux-shim] setDesktopName failed:", err); } catch (_) {}
  }
})();
`;

const entryPath = path.join(tmpDir, 'out', 'main', 'index.js');
if (!fs.existsSync(entryPath)) {
    console.error('[apply-linux-patches] ERROR: out/main/index.js missing in asar');
    process.exit(3);
}

let entrySource = fs.readFileSync(entryPath, 'utf8');
if (entrySource.includes(marker)) {
    log('marker already present in out/main/index.js; skipping entry patch');
} else {
    entrySource = SHIM_BODY + entrySource;
    fs.writeFileSync(entryPath, entrySource);
    log('patched out/main/index.js (module resolution prelude)');
}

// ---------------------------------------------------------------------------
// 3. Patch out/main/main.js: disable the native updater + VM host on Linux.
//    Anchors are verbatim minified fragments of the audited 0.1.6 build
//    (build 26080702). Each patch is independently optional: if upstream
//    changes the code shape we warn and continue instead of failing hard.
// ---------------------------------------------------------------------------
const mainPath = path.join(tmpDir, 'out', 'main', 'main.js');
if (fs.existsSync(mainPath)) {
    let mainSource = fs.readFileSync(mainPath, 'utf8');
    if (mainSource.includes(marker)) {
        log('marker already present in out/main/main.js; skipping main patch');
    } else {
        let applied = 0;

        // Patch 3a — NativeUpdaterProvider.init(): disable on Linux.
        const updaterInitAnchor = 'async init(){if(this.initialized)return;if(this.initialized=!0,!constants$2.a){';
        const updaterInitIdx = mainSource.indexOf(updaterInitAnchor);
        if (updaterInitIdx >= 0) {
            const linuxGuard =
                'async init(){if(process.platform==="linux"){' +
                'this.initialized=!0;' +
                'try{log$1.info("[NativeUpdater] Auto-update is not available on the Linux port")}catch(_){}' +
                'this.stateService.setDisabled("auto update is not supported on Linux");' +
                'return}' +
                'if(this.initialized)return;if(this.initialized=!0,!constants$2.a){';
            mainSource = mainSource.slice(0, updaterInitIdx)
                + linuxGuard
                + mainSource.slice(updaterInitIdx + updaterInitAnchor.length);
            applied++;
            log('patched NativeUpdaterProvider.init (disabled on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: NativeUpdaterProvider.init anchor not found; updater left as-is (inert without Updater binary)');
        }

        // Patch 3b — startVirtualHost(): no hypervisor build exists for Linux
        // hosts; return false instead of falling into the Windows code path.
        // Anchor set covers 0.1.6 (constants$2.o) and 0.1.7+ (constants$2.q)
        // minification renames; the macOS-flag constant shifted between builds.
        let vmPatchedApplied = false;
        for (const vmConst of ['constants$2.o', 'constants$2.q']) {
            const vmStartAnchor = 'async function startVirtualHost(r){return ' + vmConst + '?startHvkitMac():startHvkitWin(r)}';
            const vmStartIdx = mainSource.indexOf(vmStartAnchor);
            if (vmStartIdx >= 0) {
                const vmPatched =
                    'async function startVirtualHost(r){' +
                    'if(process.platform==="linux"){' +
                    'try{logger$5I.warn("[VM] Agent sandbox VM is not supported on Linux hosts (upstream ships no hvkit-linux); running without VM")}catch(_){}' +
                    'return!1}' +
                    'return ' + vmConst + '?startHvkitMac():startHvkitWin(r)}';
                mainSource = mainSource.slice(0, vmStartIdx)
                    + vmPatched
                    + mainSource.slice(vmStartIdx + vmStartAnchor.length);
                vmPatchedApplied = true;
                break;
            }
        }
        if (vmPatchedApplied) {
            applied++;
            log('patched startVirtualHost (graceful skip on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: startVirtualHost anchor not found; VM start left as-is');
        }

        // Patch 3c — startManifestCheck(): the VM manifest has no linux-* key;
        // skip the boot-time check instead of erroring noisily.
        const manifestAnchor = 'function startManifestCheck(){if(manifestCheckState.status!=="idle"){';
        const manifestIdx = mainSource.indexOf(manifestAnchor);
        if (manifestIdx >= 0) {
            const manifestPatched =
                'function startManifestCheck(){' +
                'if(process.platform==="linux"){' +
                'try{logger$5J.info("[UpdateScope] VM manifest check skipped: no linux-* artifacts upstream")}catch(_){}' +
                'return}' +
                'if(manifestCheckState.status!=="idle"){';
            mainSource = mainSource.slice(0, manifestIdx)
                + manifestPatched
                + mainSource.slice(manifestIdx + manifestAnchor.length);
            applied++;
            log('patched startManifestCheck (skip on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: startManifestCheck anchor not found; VM manifest check left as-is');
        }

        // Patch 3f — Block the in-app update check entirely on Linux.
        // performCheckForUpdates() runs the upgrade query against the upstream
        // endpoint (clientupgrade.qwenwork.cn) whenever the user is
        // authenticated — after login the "Check for updates" menu/settings
        // entry detects a newer upstream version and starts downloading it,
        // which cannot work on Linux (no native Updater binary). Early-return
        // on Linux so every entry point (menu check, settings IPC, auto poll)
        // is a no-op. Also hide the "check for updates" app-menu item.
        const updAnchor = 'async performCheckForUpdates(e){const n=e.explicit,i=getUpgradeVersion();';
        const updIdx = mainSource.indexOf(updAnchor);
        if (updIdx >= 0) {
            const updPatched =
                'async performCheckForUpdates(e){' +
                'if(process.platform==="linux"){' +
                'try{log$1.info("[NativeUpdater] Update checks disabled on the Linux port")}catch(_){}' +
                'this.stateService.setDisabled("auto update is not supported on Linux");' +
                'return null}' +
                'const n=e.explicit,i=getUpgradeVersion();';
            mainSource = mainSource.slice(0, updIdx) + updPatched + mainSource.slice(updIdx + updAnchor.length);
            applied++;
            log('patched performCheckForUpdates (block update check on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: performCheckForUpdates anchor not found; update check left as-is');
        }

        const updMenuAnchor = 'constants$2.a?[{label:this.updateAvailable?';
        const updMenuIdx = mainSource.indexOf(updMenuAnchor);
        if (updMenuIdx >= 0) {
            const updMenuPatched = 'constants$2.a&&process.platform!=="linux"?[{label:this.updateAvailable?';
            mainSource = mainSource.slice(0, updMenuIdx) + updMenuPatched + mainSource.slice(updMenuIdx + updMenuAnchor.length);
            applied++;
            log('patched menu (hide "check for updates" item on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: update menu anchor not found; item left as-is');
        }

        // Patch 3e — TrayService.createTray(): upstream registers the tray
        // click/double-click/right-click handlers only for Windows (s) and
        // OpenHarmony (m); on Linux no click handler exists, so single-clicking
        // the tray icon does nothing (only the SNI/XEmbed context menu works).
        // Electron's Linux tray DOES emit 'click' (SNI Activate / GtkStatusIcon
        // activate), so we register the handlers on Linux too. The right-click
        // handler's popUpContextMenu() is skipped on Linux — the desktop shell
        // already shows the context menu natively via SNI ContextMenu, calling
        // it again would pop a duplicate menu.
        // Anchor set covers 0.1.6 ((s||m) with constants$2.n) and 0.1.7+
        // ((t||o) with process.platform check); minifier renames the platform
        // constants and the logger alias between builds.
        let trayPatchedApplied = false;
        for (const [clickAnchor, clickPatched] of [
            ['(constants$2.s||constants$2.m)&&(this.tray.on("click",',
             '(constants$2.s||constants$2.m||constants$2.n)&&(this.tray.on("click",'],
            ['(constants$2.t||constants$2.o)&&(this.tray.on("click",',
             '(constants$2.t||constants$2.o||process.platform==="linux")&&(this.tray.on("click",'],
        ]) {
            const trayIdx = mainSource.indexOf(clickAnchor);
            if (trayIdx < 0) continue;
            mainSource = mainSource.slice(0, trayIdx) + clickPatched + mainSource.slice(trayIdx + clickAnchor.length);

            const rcVariants = [
                ['logger$y', 'this.tray.on("right-click",()=>{logger$y.info("Tray icon right-clicked"),this.tray&&this.tray.popUpContextMenu()}))'],
                ['logger$B', 'this.tray.on("right-click",()=>{logger$B.info("Tray icon right-clicked"),this.tray&&this.tray.popUpContextMenu()}))'],
            ];
            for (const [, trayRcAnchor] of rcVariants) {
                const trayRcIdx = mainSource.indexOf(trayRcAnchor);
                if (trayRcIdx >= 0) {
                    const trayRcPatched = trayRcAnchor.replace(
                        'this.tray&&this.tray.popUpContextMenu()',
                        'process.platform!=="linux"&&this.tray&&this.tray.popUpContextMenu()');
                    mainSource = mainSource.slice(0, trayRcIdx) + trayRcPatched + mainSource.slice(trayRcIdx + trayRcAnchor.length);
                    break;
                }
            }
            trayPatchedApplied = true;
            break;
        }
        if (trayPatchedApplied) {
            applied++;
            log('patched TrayService.createTray (enable click restore on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: tray click anchor not found; tray click left as-is');
        }

        // Patch 3d — initGpuGuard(): upstream disables hardware acceleration on
        // every platform that is neither macOS nor OpenHarmony
        // (initGpuGuard: !isMac && !isOpenHarmony -> app.disableHardwareAcceleration()),
        // which on Linux forces SwiftShader software rendering — slow startup
        // and janky UI on machines with perfectly working GL/Vulkan drivers.
        // We keep the upstream behavior on macOS/OHOS/Windows identical and
        // only skip the disable call on Linux so the GPU process runs with
        // hardware acceleration.
        // Anchor set covers 0.1.6 (!o&&!m ... s) and 0.1.7+ (!q&&!o ... t).
        let gpuPatchedApplied = false;
        for (const gpuAnchor of [
            'function initGpuGuard(){!constants$2.o&&!constants$2.m&&electron.app.disableHardwareAcceleration(),constants$2.s&&(',
            'function initGpuGuard(){!constants$2.q&&!constants$2.o&&electron.app.disableHardwareAcceleration(),constants$2.t&&(',
        ]) {
            const gpuGuardIdx = mainSource.indexOf(gpuAnchor);
            if (gpuGuardIdx < 0) continue;
            let gpuGuardPatched = gpuAnchor.replace(
                'function initGpuGuard(){!',
                'function initGpuGuard(){(!');
            // insert `&&process.platform!=="linux"` before the disable call:
            //  (!A&&!B&&process.platform!=="linux")&&electron.app.disableHardwareAcceleration()
            gpuGuardPatched = gpuGuardPatched.replace(
                'electron.app.disableHardwareAcceleration()',
                'process.platform!=="linux")&&electron.app.disableHardwareAcceleration()');
            mainSource = mainSource.slice(0, gpuGuardIdx)
                + gpuGuardPatched
                + mainSource.slice(gpuGuardIdx + gpuAnchor.length);
            gpuPatchedApplied = true;
            break;
        }
        if (gpuPatchedApplied) {
            applied++;
            log('patched initGpuGuard (keep hardware acceleration on Linux)');
        } else {
            console.warn('  [apply-linux-patches] WARN: initGpuGuard anchor not found; GPU guard left as-is (software rendering)');
        }

        if (applied > 0) {
            mainSource = `// ${marker} main.js patches: ${applied}\n` + mainSource;
            fs.writeFileSync(mainPath, mainSource);
        }
    }
} else {
    console.warn('  [apply-linux-patches] WARN: out/main/main.js not found in asar; skipping main patches');
}

// ---------------------------------------------------------------------------
// 3b. Inject the Linux window icon. The Linux BrowserWindow branch loads
//     <asar>/build/icons/app/icon.png (see createMainWindow in main.js), but
//     the upstream macOS asar ships no build/ tree at all — without this the
//     Linux window/taskbar icon falls back to the default Electron icon.
//     install.sh stages the converted PNG via QWENWORK_WINDOW_ICON_PNG.
// ---------------------------------------------------------------------------
const windowIconPng = process.env.QWENWORK_WINDOW_ICON_PNG;
if (windowIconPng && fs.existsSync(windowIconPng)) {
    const iconDst = path.join(tmpDir, 'build', 'icons', 'app', 'icon.png');
    fs.mkdirSync(path.dirname(iconDst), { recursive: true });
    fs.copyFileSync(windowIconPng, iconDst);
    log('injected Linux window icon -> build/icons/app/icon.png');
}

// ---------------------------------------------------------------------------
// 4. Inject Linux platform packages from the on-disk app.asar.unpacked into
//    the asar source tree so the repack registers them as unpacked entries.
//    (require() inside the asar consults the header first — this makes the
//    resolution succeed without relying solely on the globalPaths fallback.)
// ---------------------------------------------------------------------------
const LINUX_INJECT_PACKAGES = [
    'node_modules/@img/sharp-linux-x64',
    'node_modules/@img/sharp-libvips-linux-x64',
    'node_modules/@esbuild/linux-x64',
    'node_modules/@rollup/rollup-linux-x64-gnu',
    'node_modules/@nut-tree-fork/libnut-linux',
];
const injectedDirs = [];
for (const rel of LINUX_INJECT_PACKAGES) {
    const src = path.join(unpackedSiblingDir, rel);
    const dst = path.join(tmpDir, rel);
    if (fs.existsSync(src) && !fs.existsSync(dst)) {
        fs.cpSync(src, dst, { recursive: true });
        injectedDirs.push(rel);
        log('injected ' + rel + ' into asar source for repack');
    }
}

// ---------------------------------------------------------------------------
// 5. Repack, preserving the original unpacked layout.
//
//    The unpacked set is recomputed from the NEW tmpDir tree: any directory
//    whose files were 100% unpacked in the original header (or that we just
//    injected) becomes an unpackDir glob entry. Files dropped in the walk
//    above simply disappear from the new header.
// ---------------------------------------------------------------------------
function collectFullyUnpackedDirs() {
    // Recompute from the ORIGINAL header: directories where 100% of files are
    // unpacked. Files that were dropped because they are missing on disk do
    // not affect the ratio — their parent dirs were fully unpacked upstream.
    const dirs = [];
    function visit(node, relPath) {
        if (!node.files) return { total: 0, unpacked: 0 };
        let total = 0, unpacked = 0;
        for (const [name, entry] of Object.entries(node.files)) {
            const child = relPath ? relPath + '/' + name : name;
            if (entry.files) {
                const sub = visit(entry, child);
                total += sub.total;
                unpacked += sub.unpacked;
            } else if (entry.link) {
                // links aren't packed or unpacked; ignore for the ratio
            } else {
                total++;
                if (entry.unpacked) unpacked++;
            }
        }
        if (total > 0 && total === unpacked && relPath) {
            dirs.push(relPath);
        }
        return { total, unpacked };
    }
    visit(header, '');
    // Keep only maximal directories (drop any dir whose parent is also in
    // the set), so the asar glob pattern stays minimal.
    const set = new Set(dirs);
    return dirs.filter(d => {
        const parts = d.split('/');
        for (let i = 1; i < parts.length; i++) {
            const parent = parts.slice(0, i).join('/');
            if (set.has(parent)) return false;
        }
        return true;
    });
}

const fullyUnpackedDirs = collectFullyUnpackedDirs();
for (const d of injectedDirs) {
    if (!fullyUnpackedDirs.includes(d)) {
        fullyUnpackedDirs.push(d);
    }
}
log('Fully-unpacked top directories: ' + fullyUnpackedDirs.length);

const unpackDirPattern = '{' + fullyUnpackedDirs.map(d =>
    d.replace(/[{}(),*?[\]!|+@\\]/g, ch => '\\' + ch)
).join(',') + '}';

// Individual unpacked files living in partially-packed directories.
const partialUnpackedFiles = [];
function findPartialFiles(node, relPath) {
    if (!node.files) return;
    if (fullyUnpackedDirs.includes(relPath)) return;
    for (const [name, entry] of Object.entries(node.files)) {
        const child = relPath ? relPath + '/' + name : name;
        if (entry.files) {
            if (!fullyUnpackedDirs.includes(child)) {
                findPartialFiles(entry, child);
            }
        } else if (entry.unpacked && !entry.link) {
            const parent = child.split('/').slice(0, -1).join('/');
            if (!fullyUnpackedDirs.some(d => parent === d || parent.startsWith(d + '/'))) {
                // Only carry files that actually survived the walk.
                if (fs.existsSync(path.join(tmpDir, child))) {
                    partialUnpackedFiles.push(child);
                }
            }
        }
    }
}
findPartialFiles(header, '');
log('Partially-unpacked individual files: ' + partialUnpackedFiles.length);

const unpackPattern = partialUnpackedFiles.length
    ? '{' + partialUnpackedFiles.map(p =>
        p.replace(/[{}(),*?[\]!|+@\\]/g, ch => '\\' + ch)
    ).join(',') + '}'
    : undefined;

// Pack. We replace app.asar only; the on-disk app.asar.unpacked (already
// containing the rebuilt Linux native modules) stays untouched. The repack's
// own staging sidecar is discarded.
(async () => {
    const outPath = asarPath + '.new';
    const stagingSidecar = outPath + '.unpacked';
    quarantine(outPath);
    quarantine(stagingSidecar);

    await asar.createPackageWithOptions(tmpDir, outPath, {
        unpackDir: unpackDirPattern,
        unpack: unpackPattern,
    });
    log('wrote ' + path.basename(outPath) + ' (' + fs.statSync(outPath).size + ' bytes)');

    fs.renameSync(asarPath, asarPath + '.prepatch');
    try {
        fs.renameSync(outPath, asarPath);
    } catch (err) {
        try { fs.renameSync(asarPath + '.prepatch', asarPath); } catch (_) {}
        throw err;
    }
    quarantine(asarPath + '.prepatch');
    quarantine(stagingSidecar);

    log('replaced app.asar in place (app.asar.unpacked left untouched)');
})().catch(err => {
    console.error('[apply-linux-patches] pack failed:', err);
    process.exit(6);
});
