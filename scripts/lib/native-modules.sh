#!/bin/bash
# Native Node module rebuilds for the QwenWorkCN Linux payload.
#
# QwenWorkCN ships app.asar + app.asar.unpacked. The unpacked directory
# contains pre-compiled native modules for macOS (Mach-O) that CANNOT run on
# Linux. Strategy (mirrors the upstream package.json + entry-stub contract):
#
#   1. Purge every macOS/Windows-only binary and platform package:
#      - fsevents, node-mac-permissions (macOS-only APIs)
#      - @qoder/mac-notifier, @qoder/mac-drag-session  (macOS-only private addons;
#        their asar JS wrappers already no-op on non-darwin)
#      - @qoder/dji-mic-win, @qoder/windows-input-hook (Windows-only private addons)
#      - @qoder/security-guard native+vendor (gated: loadSecurityGuardNative()
#        returns an "unavailable" stub on Linux without touching the addon)
#      - darwin/win32 platform builds of sharp/libvips/esbuild/rollup/libnut
#   2. Rebuild from npm source against Linux Electron headers:
#      better-sqlite3, node-pty (critical); keytar, zstd-napi, uiohook-napi (optional)
#   3. Install Linux platform packages at the EXACT versions the macOS build
#      pinned (read from the darwin counterparts' package.json):
#      @img/sharp-linux-x64, @img/sharp-libvips-linux-x64, @esbuild/linux-x64,
#      @rollup/rollup-linux-x64-gnu, @nut-tree-fork/libnut-linux
#      (libnut-linux is mandatory: out/main/index.js treats it as a critical
#      module on Linux and refuses to boot without it.)
#   4. Replace the agent SDK's vendored ripgrep (x64-darwin -> x64-linux).
#
# clipboardy is pure JS and shells out to the system `xsel` on Linux — no
# build step, but xsel is declared as a runtime dependency in the packages.

native_module_report() {
    local search_dir="$1"
    find "$search_dir" -name "*.node" -o -name "*.so" -o -name "*.dylib" 2>/dev/null \
        | grep -v '__pycache__' | sort || true
}

# bulk_rm() is provided by scripts/lib/common.sh (sourced by install.sh first).

# ---------------------------------------------------------------------------
# Phase 1: Delete ALL non-Linux platform binaries and packages
# ---------------------------------------------------------------------------
purge_all_non_linux_artifacts() {
    local app_dir="$1"

    info "=== Phase 1: Purging all non-Linux platform artifacts ==="

    # -- macOS-only Node modules --
    bulk_rm "$app_dir/node_modules/fsevents" \
            "$app_dir/node_modules/node-mac-permissions"
    info "  Removed fsevents / node-mac-permissions (macOS-only)"

    # -- @qoder private addons: macOS / Windows only --
    # mac-notifier & mac-drag-session: asar JS wrapper returns a noop on
    # non-darwin, so deleting the .node is sufficient and safe.
    bulk_rm "$app_dir/node_modules/@qoder/mac-notifier/qoderwork_mac_notifier.node" \
            "$app_dir/node_modules/@qoder/mac-drag-session/qoderwork_mac_drag_session.node" \
            "$app_dir/node_modules/@qoder/dji-mic-win" \
            "$app_dir/node_modules/@qoder/windows-input-hook"
    info "  Removed @qoder/mac-* native files and @qoder/*-win packages"

    # -- @qoder/security-guard: platform-gated by the main bundle (returns an
    #    "unavailable" stub on Linux). The bundled SecurityGuardSDKMac.framework
    #    is ~hundreds of Mach-O/resource files; remove the whole package. --
    bulk_rm "$app_dir/node_modules/@qoder/security-guard"
    info "  Removed @qoder/security-guard (macOS SDK, Linux-gated stub upstream)"

    # -- darwin platform packages replaced by Linux equivalents in Phase 4 --
    bulk_rm "$app_dir/node_modules/@esbuild/darwin-x64" \
            "$app_dir/node_modules/@img/sharp-darwin-x64" \
            "$app_dir/node_modules/@img/sharp-libvips-darwin-x64" \
            "$app_dir/node_modules/@rollup/rollup-darwin-x64" \
            "$app_dir/node_modules/@nut-tree-fork/libnut-darwin" \
            "$app_dir/node_modules/@nut-tree-fork/node-mac-permissions"
    info "  Removed darwin builds of esbuild / sharp / libvips / rollup / libnut"

    # -- node-pty / uiohook-napi prebuilds for foreign platforms --
    local prebuild_dirs=()
    while IFS= read -r -d '' d; do prebuild_dirs+=("$d"); done < <(
        find "$app_dir/node_modules" \( -path "*/prebuilds/darwin-*" -o -path "*/prebuilds/win32-*" \) -type d -prune -print0 2>/dev/null || true)
    if [ "${#prebuild_dirs[@]}" -gt 0 ]; then
        bulk_rm "${prebuild_dirs[@]}"
    fi
    info "  Removed all darwin-*/win32-* prebuilds directories"

    # -- better-sqlite3 macOS prebuilt bin (if any) --
    local bs3_bins=()
    while IFS= read -r -d '' d; do bs3_bins+=("$d"); done < <(
        find "$app_dir/node_modules/better-sqlite3/bin" -maxdepth 1 -type d -name "darwin-*" -print0 2>/dev/null || true)
    if [ "${#bs3_bins[@]}" -gt 0 ]; then
        bulk_rm "${bs3_bins[@]}"
    fi

    # -- Resources/bin: macOS-only helpers (Linux qoderclicn is provisioned
    #    separately by scripts/lib/qwenwork-cli.sh) --
    bulk_rm "$app_dir/../bin/open-with-helper" \
            "$app_dir/../bin/fn_key_tap.node"
    info "  Removed macOS helpers from resources/bin (open-with-helper, fn_key_tap.node)"

    # -- agent SDK vendored macOS ripgrep (Linux rg installed in Phase 4) --
    bulk_rm "$app_dir/node_modules/@qoder-ai/qoder-agent-sdk/dist/_worker/vendor/ripgrep/x64-darwin"
    info "  Removed x64-darwin ripgrep from @qoder-ai/qoder-agent-sdk worker vendor"
}

# ---------------------------------------------------------------------------
# Phase 2: Deep scan and remove any remaining Mach-O / PE binaries
# ---------------------------------------------------------------------------
purge_remaining_foreign_binaries() {
    local app_dir="$1"
    local native_file description

    info "=== Phase 2: Deep scan for remaining non-Linux binaries ==="

    command -v file >/dev/null 2>&1 || {
        warn "  'file' command not available; skipping deep binary scan"
        return 0
    }

    local removed=0
    local -a foreign=()
    while IFS= read -r native_file; do
        description="$(file "$native_file" 2>/dev/null || true)"
        case "$description" in
            *Mach-O*)
                warn "  Removing Mach-O binary: $native_file"
                foreign+=("$native_file")
                ;;
            *"PE32"*|*"PE32+"*|*"MS Windows"*)
                warn "  Removing Windows PE binary: $native_file"
                foreign+=("$native_file")
                ;;
        esac
    done < <(find "$app_dir" \( -name "*.node" -o -name "*.dylib" -o -name "*.so" -o -name "*.dll" -o -name "*.exe" \) -type f 2>/dev/null | sort || true)

    if [ "${#foreign[@]}" -gt 0 ]; then
        bulk_rm "${foreign[@]}"
        removed="${#foreign[@]}"
    fi

    if [ "$removed" -gt 0 ]; then
        info "  Removed $removed remaining non-Linux binaries"
    else
        info "  No remaining non-Linux binaries found (clean)"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Rebuild native modules from npm source
# ---------------------------------------------------------------------------

read_module_version() {
    local app_dir="$1"
    local module_name="$2"
    local pkg="$app_dir/node_modules/$module_name/package.json"
    [ -f "$pkg" ] || return 1
    node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version||"")' "$pkg"
}

build_native_module_fresh() {
    local app_dir="$1"
    local module_name="$2"
    local module_version="$3"
    local allow_fail="${4:-0}"

    local build_dir="$WORK_DIR/native-build/${module_name//@/_}_${module_version}"
    local rc=0
    bulk_rm "$build_dir"
    mkdir -p "$build_dir"

    info "  Building $module_name@$module_version from source for Electron $ELECTRON_VERSION"
    (
        cd "$build_dir"

        # Pin the SYSTEM toolchain. Conda/Linuxbrew compilers inject
        # "-Wl,-rpath,<prefix>/lib" into every .node they link, which both
        # ties the binary to a private directory and makes rpmbuild's
        # check-rpaths fail with "ERROR 0002 ... invalid rpath".
        eval "$(build_toolchain_env)"
        export CC CXX LINK LDFLAGS LD_RUN_PATH LIBRARY_PATH CPPFLAGS

        echo '{"private":true}' > package.json

        # Install Electron (headers only, skip the full download)
        npm install "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts --no-audit --no-fund 2>&1 >/dev/null

        # Install the module's full source
        npm install "$module_name@$module_version" --ignore-scripts --no-audit --no-fund 2>&1 >/dev/null

        # Rebuild for the target Electron
        npm_config_disturl="$ELECTRON_HEADERS_URL" \
        NPM_CONFIG_DISTURL="$ELECTRON_HEADERS_URL" \
        npx --yes @electron/rebuild \
            -v "$ELECTRON_VERSION" \
            --force \
            --dist-url "$ELECTRON_HEADERS_URL" \
            --only "$module_name" 2>&1
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ "$allow_fail" -eq 1 ]; then
            warn "  Failed to build $module_name@$module_version (optional, continuing)"
            return 0
        else
            error "Failed to build $module_name@$module_version"
        fi
    fi

    # Verify at least one .node was produced
    local built_path="$build_dir/node_modules/$module_name"
    local node_count
    node_count="$(find "$built_path" -name '*.node' -type f 2>/dev/null | wc -l)"
    if [ "$node_count" -eq 0 ] && [ "$allow_fail" -eq 0 ]; then
        error "No .node files produced for $module_name@$module_version"
    fi

    # Merge-copy the freshly built module back into the app. Same npm
    # package + same version => identical file set; overwriting in place
    # replaces Mach-O binaries with fresh ELF builds without tree deletion.
    local target_path="$app_dir/node_modules/$module_name"
    mkdir -p "$target_path"
    cp -a "$built_path/." "$target_path/"
    info "  Installed fresh $module_name@$module_version (${node_count} native files)"
}

rebuild_critical_modules() {
    local app_dir="$1"

    info "=== Phase 3: Rebuilding native modules from source ==="
    info "  Target: Electron $ELECTRON_VERSION | Headers: $ELECTRON_HEADERS_URL"

    local module_name module_version

    # --- Critical modules (build failure = fatal error) ---
    # node-pty: built-in terminal. better-sqlite3: local data layer (drizzle-orm).
    local -a critical_modules=(
        "node-pty"
        "better-sqlite3"
    )

    for module_name in "${critical_modules[@]}"; do
        module_version="$(read_module_version "$app_dir" "$module_name" 2>/dev/null || true)"
        if [ -z "$module_version" ]; then
            warn "  Module $module_name not found in app; skipping"
            continue
        fi
        build_native_module_fresh "$app_dir" "$module_name" "$module_version" 0
    done

    # --- Optional modules (build failure = warning only) ---
    # keytar: OS keychain (libsecret on Linux). zstd-napi: compression.
    # uiohook-napi: global input hooks (needs X11/Xtst dev headers).
    local -a optional_modules=(
        "keytar"
        "zstd-napi"
        "uiohook-napi"
    )

    for module_name in "${optional_modules[@]}"; do
        module_version="$(read_module_version "$app_dir" "$module_name" 2>/dev/null || true)"
        if [ -z "$module_version" ]; then
            continue
        fi
        build_native_module_fresh "$app_dir" "$module_name" "$module_version" 1
    done
}

# ---------------------------------------------------------------------------
# Phase 4: Install Linux platform packages (exact-version parity with the
# darwin builds found in the DMG)
# ---------------------------------------------------------------------------

# install_linux_platform_package <app_dir> <linux_pkg> <version> [optional]
# Installs the matching Linux package from npm and copies it into place.
install_linux_platform_package() {
    local app_dir="$1"
    local linux_pkg="$2"
    local version="$3"
    local optional="${4:-0}"

    local build_dir source_path target_path
    if [ -z "$version" ]; then
        warn "  No version resolved for $linux_pkg; skipping"
        return 0
    fi

    build_dir="$WORK_DIR/platform-pkgs/${linux_pkg//@/_}"
    bulk_rm "$build_dir"
    mkdir -p "$build_dir"

    info "  Installing $linux_pkg@$version"
    (
        cd "$build_dir"
        npm init -y >/dev/null 2>&1
        npm install "$linux_pkg@$version" --no-audit --no-fund 2>&1
    ) || {
        if [ "$optional" -eq 1 ]; then
            warn "  Failed to install $linux_pkg@$version (optional, continuing)"
            return 0
        fi
        error "Failed to install $linux_pkg@$version"
    }

    source_path="$build_dir/node_modules/$linux_pkg"
    [ -d "$source_path" ] || {
        [ "$optional" -eq 1 ] && { warn "  $linux_pkg not found after install"; return 0; }
        error "$linux_pkg was not installed correctly"
    }

    target_path="$app_dir/node_modules/$linux_pkg"
    mkdir -p "$target_path"
    cp -a "$source_path/." "$target_path/"
    info "  Installed $linux_pkg@$version"
}

install_linux_ripgrep_for_agent_sdk() {
    local app_dir="$1"
    local rg_vendor="$app_dir/node_modules/@qoder-ai/qoder-agent-sdk/dist/_worker/vendor/ripgrep"

    [ -d "$rg_vendor" ] || return 0

    local linux_dir
    case "$ARCH" in
        x86_64) linux_dir="x64-linux" ;;
        aarch64) linux_dir="arm64-linux" ;;
        *) warn "  No ripgrep binary for $ARCH"; return 0 ;;
    esac

    local build_dir="$WORK_DIR/agent-sdk-ripgrep"
    bulk_rm "$build_dir"
    mkdir -p "$build_dir"

    info "  Installing Linux ripgrep for agent SDK worker vendor"
    (
        cd "$build_dir"
        npm init -y >/dev/null 2>&1
        npm install @vscode/ripgrep --no-audit --no-fund 2>&1
    ) || {
        warn "  Failed to install @vscode/ripgrep (optional, continuing)"
        return 0
    }

    local rg_bin
    rg_bin="$(node -e "try { console.log(require('$build_dir/node_modules/@vscode/ripgrep').rgPath) } catch(e) {}" 2>/dev/null)"
    if [ -z "$rg_bin" ] || [ ! -x "$rg_bin" ]; then
        rg_bin="$build_dir/node_modules/@vscode/ripgrep/bin/rg"
    fi

    if [ -x "$rg_bin" ]; then
        mkdir -p "$rg_vendor/$linux_dir"
        cp "$rg_bin" "$rg_vendor/$linux_dir/rg"
        chmod +x "$rg_vendor/$linux_dir/rg"
        info "  Installed Linux rg -> agent-sdk vendor/ripgrep/$linux_dir/rg"
    else
        warn "  Could not find rg binary after installing @vscode/ripgrep"
    fi
}

install_linux_platform_packages() {
    local app_dir="$1"

    info "=== Phase 4: Installing Linux platform packages ==="

    # Versions were captured in rebuild_native_modules BEFORE Phase 1 purged
    # the darwin packages (DARWIN_PKG_VERSIONS: name=version pairs).
    local sharp_ver esbuild_ver rollup_ver libvips_ver libnut_ver
    sharp_ver="${DARWIN_PKG_VERSIONS[@img/sharp-darwin-x64]:-${QWENWORK_PIN_SHARP:-0.34.5}}"
    libvips_ver="${DARWIN_PKG_VERSIONS[@img/sharp-libvips-darwin-x64]:-${QWENWORK_PIN_LIBVIPS:-1.2.4}}"
    esbuild_ver="${DARWIN_PKG_VERSIONS[@esbuild/darwin-x64]:-${QWENWORK_PIN_ESBUILD:-0.25.12}}"
    rollup_ver="${DARWIN_PKG_VERSIONS[@rollup/rollup-darwin-x64]:-${QWENWORK_PIN_ROLLUP:-4.60.4}}"
    libnut_ver="${DARWIN_PKG_VERSIONS[@nut-tree-fork/libnut-darwin]:-${QWENWORK_PIN_LIBNUT:-2.7.5}}"

    install_linux_platform_package "$app_dir" "@img/sharp-linux-x64" "$sharp_ver"
    install_linux_platform_package "$app_dir" "@img/sharp-libvips-linux-x64" "$libvips_ver"
    install_linux_platform_package "$app_dir" "@esbuild/linux-x64" "$esbuild_ver"
    install_linux_platform_package "$app_dir" "@rollup/rollup-linux-x64-gnu" "$rollup_ver" 1

    # @nut-tree-fork/libnut-linux is CRITICAL on Linux: out/main/index.js
    # refuses to boot without it (criticalModules platform=linux check).
    install_linux_platform_package "$app_dir" "@nut-tree-fork/libnut-linux" "$libnut_ver"

    install_linux_ripgrep_for_agent_sdk "$app_dir"
}

# ---------------------------------------------------------------------------
# Main entry point: rebuild_native_modules
# ---------------------------------------------------------------------------
rebuild_native_modules() {
    local app_dir="$1"

    [ -d "$app_dir/node_modules" ] || {
        warn "No node_modules directory found; skipping native rebuild"
        return 0
    }

    info "╔════════════════════════════════════════════════════╗"
    info "║  QwenWorkCN Native Module Rebuild for Linux       ║"
    info "╚════════════════════════════════════════════════════╝"
    info ""

    # Capture the versions of the darwin platform packages BEFORE Phase 1
    # deletes them — Phase 4 installs the Linux counterparts at the exact
    # same versions to guarantee JS/native ABI parity with the asar code.
    declare -gA DARWIN_PKG_VERSIONS=()
    local pkg
    for pkg in "@img/sharp-darwin-x64" "@img/sharp-libvips-darwin-x64" \
               "@esbuild/darwin-x64" "@rollup/rollup-darwin-x64" \
               "@nut-tree-fork/libnut-darwin"; do
        DARWIN_PKG_VERSIONS[$pkg]="$(read_module_version "$app_dir" "$pkg" 2>/dev/null || true)"
    done
    info "Darwin package pins: sharp=${DARWIN_PKG_VERSIONS[@img/sharp-darwin-x64]:-?} libvips=${DARWIN_PKG_VERSIONS[@img/sharp-libvips-darwin-x64]:-?} esbuild=${DARWIN_PKG_VERSIONS[@esbuild/darwin-x64]:-?} rollup=${DARWIN_PKG_VERSIONS[@rollup/rollup-darwin-x64]:-?} libnut=${DARWIN_PKG_VERSIONS[@nut-tree-fork/libnut-darwin]:-?}"

    info "Native modules BEFORE cleanup:"
    native_module_report "$app_dir" >&2
    info ""

    # Phase 1: Delete all non-Linux binaries
    purge_all_non_linux_artifacts "$app_dir"
    info ""

    # Phase 2: Deep scan for any missed Mach-O / PE binaries
    purge_remaining_foreign_binaries "$app_dir"
    info ""

    # Phase 3: Rebuild native modules from npm source
    rebuild_critical_modules "$app_dir"
    info ""

    # Phase 4: Install Linux platform packages
    install_linux_platform_packages "$app_dir"
    info ""

    # Phase 5: Final sweep — the fresh npm packages merge-copied in Phase 3/4
    # ship their own darwin/win32 prebuilds (e.g. node-pty prebuilds/darwin-*);
    # quarantine them so the payload is 100% Linux-clean.
    purge_remaining_foreign_binaries "$app_dir"
    info ""

    # Phase 6: Strip build-machine-only RPATH/RUNPATH entries.
    # Safety net for Phase 3/4 modules whose build system ignored CC/CXX
    # (or when an existing tree was built before this hygiene step existed).
    info "=== Phase 6: Sanitizing RPATH/RUNPATH ==="
    scrub_local_rpaths "$app_dir"
    info ""

    # Final verification
    info "Native modules AFTER rebuild:"
    native_module_report "$app_dir" >&2

    info ""
    info "Native module rebuild complete."
}
