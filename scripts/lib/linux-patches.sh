#!/bin/bash
# Linux-specific patches applied to the packed app.asar.
#
# QwenWorkCN vs WorkBuddy patch surface (see docs/porting-notes.md):
#
#   NOT needed here:
#   - E2BIG env shim     — QwenWorkCN never puts a giant JSON into env vars
#   - tray menu fix      — upstream TrayService already calls setContextMenu()
#   - tray icon path fix — upstream already loads resources/tray-icon.png on Linux
#   - window controls    — upstream gives Linux a native frame + autoHideMenuBar
#
#   Needed here (see scripts/lib/apply-linux-patches.js):
#   1. Module.globalPaths prelude in out/main/index.js so asar code can
#      require() the Linux platform packages installed on disk.
#   2. NativeUpdaterProvider.init() early-return on Linux (no Updater binary
#      exists for Linux; avoids user-visible "Updater binary not found").
#   3. startVirtualHost()/startManifestCheck() skip on Linux (upstream ships
#      no linux-* VM artifact and no hvkit hypervisor for Linux hosts).
#   4. Header hygiene: drop unpacked references to files we deleted; register
#      the injected Linux platform packages as unpacked entries.

LINUX_PATCHES_SHIM_MARKER="__QWENWORK_LINUX_PATCHES_V4__"

apply_linux_runtime_patches() {
    local app_dir="$1"
    local asar_path="$app_dir/resources/app.asar"

    [ -f "$asar_path" ] || {
        warn "Linux patches: app.asar not found at $asar_path"
        return 0
    }

    info "=== Applying Linux runtime patches to app.asar ==="

    # The Node helper needs @electron/asar available. Install it into the
    # per-build WORK_DIR so we don't pollute the project with a persistent
    # node_modules tree.
    local asar_tool_dir="$WORK_DIR/asar-tool"
    if [ ! -x "$asar_tool_dir/node_modules/.bin/asar" ]; then
        info "  Installing @electron/asar for patcher"
        mkdir -p "$asar_tool_dir"
        (
            cd "$asar_tool_dir"
            npm init -y >/dev/null 2>&1
            npm install @electron/asar --no-audit --no-fund --silent 2>&1
        ) || {
            warn "  Failed to install @electron/asar; skipping Linux patches"
            return 0
        }
    fi

    NODE_PATH="$asar_tool_dir/node_modules" \
        node "$SCRIPT_DIR/scripts/lib/apply-linux-patches.js" \
             "$asar_path" \
             "$LINUX_PATCHES_SHIM_MARKER" \
        || {
        warn "  Failed to apply Linux patches; leaving app.asar untouched"
        return 0
    }
    info "  Linux runtime patches applied successfully"
}
