#!/bin/bash
set -Eeuo pipefail

# QwenWorkCN (千问办公) macOS -> Linux x64 port builder.
#
# Pipeline:
#   1. Extract the official macOS DMG (7z)
#   2. Detect the Electron version from the app bundle metadata
#   3. Download the matching Linux Electron runtime
#   4. Copy the app payload: app.asar + app.asar.unpacked + all loose
#      Resources payload directories (see RESOURCE_PAYLOAD below)
#   5. Purge/rebuild native modules for Linux (scripts/lib/native-modules.sh)
#   6. Provision the official Linux qoderclicn agent CLI (scripts/lib/qwenwork-cli.sh)
#   7. Patch app.asar for Linux (scripts/lib/apply-linux-patches.js)
#   8. Convert the .icns icon, write launcher + desktop entry + build metadata

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ID="${QWENWORK_APP_ID:-qwenwork-cn}"
APP_DISPLAY_NAME="${QWENWORK_APP_DISPLAY_NAME:-QwenWorkCN}"
INSTALL_DIR="${QWENWORK_INSTALL_DIR:-$SCRIPT_DIR/qwenwork-app}"
ELECTRON_VERSION="${ELECTRON_VERSION:-37.10.3}"
ELECTRON_HEADERS_URL="${ELECTRON_HEADERS_URL:-${npm_config_disturl:-${NPM_CONFIG_DISTURL:-https://artifacts.electronjs.org/headers/dist}}}"
ELECTRON_MIRROR="${ELECTRON_MIRROR:-}"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"
PROVIDED_INPUT=""
FRESH=0

. "$SCRIPT_DIR/scripts/lib/common.sh"
. "$SCRIPT_DIR/scripts/lib/dmg.sh"
. "$SCRIPT_DIR/scripts/lib/electron.sh"
. "$SCRIPT_DIR/scripts/lib/native-modules.sh"
. "$SCRIPT_DIR/scripts/lib/qwenwork-cli.sh"
. "$SCRIPT_DIR/scripts/lib/linux-patches.sh"

# Loose payload under Contents/Resources that the app references through
# process.resourcesPath at runtime. Unlike WorkBuddy (everything inside the
# asar), QwenWorkCN keeps skills/legokits/migrations/VM guest payloads etc.
# as plain files, so they must be copied verbatim.
RESOURCE_PAYLOAD_DIRS=(
    awareness-templates
    bin
    canvas
    chrome-extension
    commands
    dynamic-text
    legokits
    migrations
    native-messaging-host
    plugins-example
    ps
    qoder-auth-wasm
    skills
    skills-market
    vm-boot
    writing
)
RESOURCE_PAYLOAD_FILES=(
    app-update.yml
    plugin-market-data.json
    skill-market-data.json
    tray-icon.png
)

usage() {
    cat <<'HELP'
Usage: ./install.sh [--fresh] [path/to/QwenWorkCN.dmg | path/to/QwenWorkCN.app]

Builds a local Linux Electron app from a user-owned official QwenWorkCN
(千问办公) macOS Intel/x64 DMG or extracted .app bundle. With no path, the
installer expects exactly one official DMG in downloads/.

Environment:
  QWENWORK_INSTALL_DIR     Output app directory (default: ./qwenwork-app)
  ELECTRON_MIRROR          Optional Electron runtime mirror
  ELECTRON_HEADERS_URL     Electron headers dist URL for native rebuilds
  QODER_CLI_VERSION        Override the qoderclicn CLI version to download
HELP
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                exit 2
                ;;
            *)
                [ -z "$PROVIDED_INPUT" ] || error "Only one input path can be provided"
                PROVIDED_INPUT="$1"
                ;;
        esac
        shift
    done
}

check_deps() {
    require_cmd python3
    require_cmd curl
    require_cmd unzip
    require_cmd node
    require_cmd npm
    require_cmd npx
    require_cmd tar
    find_7z >/dev/null
}

prepare_install_dir() {
    if [ -e "$INSTALL_DIR" ]; then
        if [ "$FRESH" -eq 1 ]; then
            bulk_rm "$INSTALL_DIR"
        else
            info "Replacing existing install dir: $INSTALL_DIR"
            bulk_rm "$INSTALL_DIR"
        fi
    fi
    mkdir -p "$INSTALL_DIR"
}

copy_app_payload() {
    local app_bundle="$1"
    local resources_dir="$app_bundle/Contents/Resources"
    local app_asar="$resources_dir/app.asar"
    local app_asar_unpacked="$resources_dir/app.asar.unpacked"

    [ -f "$app_asar" ] || error "app.asar not found in: $resources_dir"

    info "Copying QwenWorkCN app.asar payload"
    mkdir -p "$INSTALL_DIR/resources"
    cp "$app_asar" "$INSTALL_DIR/resources/app.asar"

    if [ -d "$app_asar_unpacked" ]; then
        info "Copying app.asar.unpacked"
        # Merge-copy idiom: safe even if the destination already exists
        mkdir -p "$INSTALL_DIR/resources/app.asar.unpacked"
        cp -a "$app_asar_unpacked/." "$INSTALL_DIR/resources/app.asar.unpacked/"
    fi

    # Loose Resources payload. 7z extracts macOS code-signature sidecars as
    # "<name>:com.apple.cs.*" files — they are AppleDouble artifacts and must
    # never be copied to the Linux payload.
    local entry base
    for entry in "${RESOURCE_PAYLOAD_DIRS[@]}"; do
        if [ -d "$resources_dir/$entry" ]; then
            info "Copying resources/$entry"
            mkdir -p "$INSTALL_DIR/resources/$entry"
            (cd "$resources_dir/$entry" && tar --exclude='*:com.apple.cs.*' -cf - .) | (cd "$INSTALL_DIR/resources/$entry" && tar -xf -)
        else
            warn "resources/$entry not found in app bundle (skipped)"
        fi
    done
    for base in "${RESOURCE_PAYLOAD_FILES[@]}"; do
        if [ -f "$resources_dir/$base" ]; then
            cp "$resources_dir/$base" "$INSTALL_DIR/resources/$base"
        else
            warn "resources/$base not found in app bundle (skipped)"
        fi
    done
}

write_icon() {
    local app_bundle="$1"
    local icon_source="$app_bundle/Contents/Resources/icon.icns"
    local meta_dir="$INSTALL_DIR/.qwenwork-linux"
    local icon_target="$meta_dir/qwenwork-cn.png"
    local icon_tmp="$WORK_DIR/icon"

    mkdir -p "$meta_dir" "$icon_tmp"

    if [ ! -f "$icon_source" ]; then
        warn "QwenWorkCN icon not found in app bundle"
        return 0
    fi

    if command -v icns2png >/dev/null 2>&1; then
        icns2png -x -s 256 -o "$icon_tmp" "$icon_source" >/dev/null 2>&1 || true
        local generated
        generated="$(find "$icon_tmp" -type f -name "*.png" | sort | tail -n 1)"
        if [ -n "$generated" ]; then
            cp "$generated" "$icon_target"
            stage_window_icon
            return 0
        fi
    fi

    if command -v magick >/dev/null 2>&1; then
        magick "$icon_source" "$icon_target" >/dev/null 2>&1 && { stage_window_icon; return 0; }
    elif command -v convert >/dev/null 2>&1; then
        convert "$icon_source" "$icon_target" >/dev/null 2>&1 && { stage_window_icon; return 0; }
    fi

    # Fallback: extract PNG directly from ICNS with python3 (no extra libs).
    # ICNS 256x256+ entries embed raw PNG data located by signature.
    if python3 - "$icon_source" "$icon_target" <<'PY' 2>/dev/null; then
import struct, sys

def extract(icns_path, out_path):
    wanted = [b'ic08', b'ic09', b'ic13', b'ic14', b'ic10', b'ic07']
    png_sig = b'\x89PNG'
    with open(icns_path, 'rb') as f:
        if f.read(4) != b'icns':
            return False
        total = struct.unpack('>I', f.read(4))[0]
        found = {}
        while f.tell() < total:
            etype = f.read(4)
            if len(etype) < 4:
                break
            esize = struct.unpack('>I', f.read(4))[0]
            edata = f.read(esize - 8)
            if etype in wanted and edata[:4] == png_sig:
                found[etype] = edata
        for t in wanted:
            if t in found:
                with open(out_path, 'wb') as o:
                    o.write(found[t])
                return True
    return False

sys.exit(0 if extract(sys.argv[1], sys.argv[2]) else 1)
PY
        stage_window_icon
        return 0
    fi

    warn "Could not convert QwenWorkCN .icns icon; desktop entry will use theme icon name"
}

# The Linux BrowserWindow code path loads its window icon from
# <asar>/build/icons/app/icon.png (fs.existsSync-guarded; the upstream macOS
# asar ships no build/ tree, so Linux windows would show the default Electron
# icon). Stage the converted PNG so the asar patcher can inject it.
stage_window_icon() {
    if [ -f "$INSTALL_DIR/.qwenwork-linux/qwenwork-cn.png" ]; then
        mkdir -p "$WORK_DIR/window-icon"
        cp "$INSTALL_DIR/.qwenwork-linux/qwenwork-cn.png" "$WORK_DIR/window-icon/icon.png"
        export QWENWORK_WINDOW_ICON_PNG="$WORK_DIR/window-icon/icon.png"
    fi
}

write_launcher() {
    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash
set -euo pipefail

APP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export CHROME_DESKTOP="${APP_ID}.desktop"
export ELECTRON_FORCE_IS_PACKAGED=1
# The in-app Linux prelude calls app.setDesktopName() with this value so the
# Wayland xdg app_id matches the .desktop base name (taskbar icon).
export QWENWORK_APP_ID="${APP_ID}"

# Defensive: when launched from a Node/Electron development shell, inherited
# ELECTRON_RUN_AS_NODE=1 would make the Electron binary behave as plain Node
# and reject all Chromium flags ("bad option: --no-sandbox").
unset ELECTRON_RUN_AS_NODE

# NOTE on --ozone-platform: we default to X11 (XWayland) because Chromium's
# native Wayland GPU process crash-loops on NVIDIA+Wayland sessions
# ("Context was lost", dmabuf modifier errors) and silently falls back to
# SwiftShader software rendering — slow startup + janky UI. Under XWayland the
# NVIDIA GLX path delivers full hardware acceleration (verified). Users on
# Intel/AMD GPUs (or fixed NVIDIA drivers) can switch back to native Wayland:
#   QWENWORK_OZONE_PLATFORM=wayland ./start.sh
exec "\$APP_DIR/electron" \\
  --no-sandbox \\
  --disable-dev-shm-usage \\
  --disable-gpu-sandbox \\
  --ozone-platform="\${QWENWORK_OZONE_PLATFORM:-x11}" \\
  --enable-wayland-ime \\
  "\$@"
EOF
    chmod +x "$INSTALL_DIR/start.sh"
}

write_desktop_entry() {
    local icon_value="$APP_ID"
    if [ -f "$INSTALL_DIR/.qwenwork-linux/qwenwork-cn.png" ]; then
        icon_value="$INSTALL_DIR/.qwenwork-linux/qwenwork-cn.png"
    fi

    mkdir -p "$INSTALL_DIR/.qwenwork-linux"
    cat > "$INSTALL_DIR/.qwenwork-linux/$APP_ID.desktop" <<EOF
[Desktop Entry]
Name=$APP_DISPLAY_NAME
Comment=Run QwenWorkCN (千问办公) on Linux
Exec=$INSTALL_DIR/start.sh %F
Icon=$icon_value
Type=Application
Categories=Office;Productivity;Development;
StartupNotify=true
StartupWMClass=QwenWorkCN
MimeType=x-scheme-handler/qwenwork-cn;
EOF
}

write_build_metadata() {
    local app_bundle="$1"
    local version
    version="$(read_app_version "$app_bundle")"
    mkdir -p "$INSTALL_DIR/.qwenwork-linux"
    cat > "$INSTALL_DIR/.qwenwork-linux/build-info.json" <<EOF
{
  "appId": "$APP_ID",
  "displayName": "$APP_DISPLAY_NAME",
  "upstreamVersion": "$version",
  "electronVersion": "$ELECTRON_VERSION",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

main() {
    parse_args "$@"
    check_deps

    local input_path app_bundle
    input_path="$(resolve_input_path "$PROVIDED_INPUT")"
    app_bundle="$(resolve_app_bundle "$input_path")"
    ELECTRON_VERSION="$(detect_electron_version "$app_bundle")"

    info "Using app bundle: $app_bundle"
    info "Using Electron: $ELECTRON_VERSION"

    prepare_install_dir
    download_electron_runtime
    copy_app_payload "$app_bundle"

    # Rebuild native modules in app.asar.unpacked (where the .node files live)
    local native_dir="$INSTALL_DIR/resources/app.asar.unpacked"
    if [ -d "$native_dir/node_modules" ]; then
        rebuild_native_modules "$native_dir"
    fi

    # Provision the official Linux build of the bundled agent CLI
    # (resources/bin/qoderclicn), downloaded from the upstream CDN.
    install_linux_qoder_cli "$INSTALL_DIR"

    # Convert the icon BEFORE the asar patch so the window icon can be
    # injected into the asar (build/icons/app/icon.png) in the same pass.
    write_icon "$app_bundle"

    # Apply Linux-specific runtime patches inside app.asar (module resolution
    # prelude + updater/VM graceful degradation + linux package injection).
    apply_linux_runtime_patches "$INSTALL_DIR"

    write_launcher
    write_desktop_entry
    write_build_metadata "$app_bundle"

    info "Build complete: $INSTALL_DIR"
    info "Run: $INSTALL_DIR/start.sh"
}

trap 'bulk_rm "$WORK_DIR"' EXIT
main "$@"
