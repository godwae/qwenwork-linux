#!/bin/bash
# Linux qoderclicn (built-in agent CLI) provisioning. Sourced by install.sh.
#
# The macOS DMG bundles a 108MB Mach-O single-file executable at
# Contents/Resources/bin/qoderclicn (Bun-compiled). That binary cannot run on
# Linux, but the upstream @qoder-ai/qoder-agent-sdk postinstall script
# (scripts/postinstall.cjs) documents official per-platform artifacts on the
# CN CDN, including linux-x64 / linux-x64-baseline / linux-x64-musl.
#
# The main process locates the CLI as:
#     path.join(process.resourcesPath, "bin", "qoderclicn")
# (getQoderCliBinaryName() returns the bare name on every non-Windows OS),
# so dropping the official Linux build at resources/bin/qoderclicn gives us a
# fully working built-in CLI — no source patch required.
#
# Artifact URL format (CN site):
#   https://static.qoder.com.cn/qoder-cli-cn/releases/<version>/qoderclicn-<target>.tar.gz
# where <target> is selected exactly like the SDK postinstall does:
#   musl libc            -> linux-x64-musl
#   glibc + AVX2         -> linux-x64
#   glibc, no AVX2       -> linux-x64-baseline

QODER_CLI_CN_BASE="${QODER_CLI_CN_BASE:-https://static.qoder.com.cn/qoder-cli-cn/releases}"
QODER_CLI_GLOBAL_BASE="${QODER_CLI_GLOBAL_BASE:-https://download.qoder.com/qodercli/releases}"

is_musl_libc() {
    # ldd on musl prints "musl libc" in the first line; glibc prints "GNU libc".
    local ldd_out
    ldd_out="$(ldd --version 2>&1 | head -n 1 || true)"
    case "$ldd_out" in
        *musl*) return 0 ;;
        *) return 1 ;;
    esac
}

linux_x64_has_avx2() {
    grep -qm1 'avx2' /proc/cpuinfo 2>/dev/null
}

# Echo the CDN artifact target for this machine, mirroring the SDK's
# getPlatformTarget() logic (aarch64 included for completeness).
qoder_cli_target() {
    if [ "$ARCH" = "aarch64" ]; then
        if is_musl_libc; then echo "linux-arm64-musl"; else echo "linux-arm64"; fi
        return 0
    fi
    [ "$ARCH" = "x86_64" ] || error "Unsupported architecture for qoderclicn: $ARCH"
    if is_musl_libc; then
        echo "linux-x64-musl"
    elif linux_x64_has_avx2; then
        echo "linux-x64"
    else
        echo "linux-x64-baseline"
    fi
}

# Read the CLI version pinned by the agent SDK inside the extracted app
# (package.json -> qoderCliVersion). Falls back to QODER_CLI_VERSION env.
detect_qoder_cli_version() {
    local unpacked_dir="$1"
    local sdk_pkg="$unpacked_dir/node_modules/@qoder-ai/qoder-agent-sdk/package.json"
    if [ -n "${QODER_CLI_VERSION:-}" ]; then
        echo "${QODER_CLI_VERSION#v}"
        return 0
    fi
    if [ -f "$sdk_pkg" ]; then
        node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.qoderCliVersion || p.version || ""));' "$sdk_pkg"
        return 0
    fi
    echo ""
}

install_linux_qoder_cli() {
    local install_dir="$1"
    local bin_dir="$install_dir/resources/bin"
    local target version base_url archive_name url cache_dir cached_archive tmp_extract cli_src

    [ -d "$bin_dir" ] || { warn "resources/bin missing; skipping qoderclicn provisioning"; return 0; }

    # Remove the macOS Mach-O binary regardless — it can only confuse users.
    if [ -f "$bin_dir/qoderclicn" ]; then
        if file "$bin_dir/qoderclicn" 2>/dev/null | grep -q "Mach-O"; then
            bulk_rm "$bin_dir/qoderclicn"
            info "  Removed macOS qoderclicn (Mach-O) from resources/bin"
        fi
    fi

    target="$(qoder_cli_target)"
    version="$(detect_qoder_cli_version "$install_dir/resources/app.asar.unpacked")"
    if [ -z "$version" ]; then
        warn "  Could not determine qoderclicn version; leaving resources/bin without CLI"
        return 0
    fi

    # CN site names the artifact prefix "qoderclicn"; the global site uses
    # "qodercli". Prefer CN (the app is QwenWorkCN), fall back to global.
    local -a candidates=(
        "$QODER_CLI_CN_BASE/$version/qoderclicn-$target.tar.gz|qoderclicn"
        "$QODER_CLI_GLOBAL_BASE/$version/qodercli-$target.tar.gz|qodercli"
    )

    cache_dir="${QWENWORK_CLI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/qwenwork-linux/qodercli}"
    mkdir -p "$cache_dir"

    local entry prefix cached ok=0
    for entry in "${candidates[@]}"; do
        url="${entry%%|*}"
        prefix="${entry##*|}"
        archive_name="$(basename "$url")"
        cached="$cache_dir/$archive_name"
        if [ ! -f "$cached" ]; then
            info "  Downloading $archive_name"
            if ! curl -L --fail --continue-at - --progress-bar -o "$cached.part" "$url"; then
                warn "  Download failed: $url"
                bulk_rm "$cached.part"
                continue
            fi
            mv "$cached.part" "$cached"
        else
            info "  Using cached CLI archive: $cached"
        fi

        tmp_extract="$WORK_DIR/qodercli-extract"
        bulk_rm "$tmp_extract"
        mkdir -p "$tmp_extract"
        if ! tar -xzf "$cached" -C "$tmp_extract" 2>/dev/null; then
            warn "  Failed to extract $cached; trying next source"
            bulk_rm "$cached"
            continue
        fi

        # The tarball ships the binary as qodercli / qoderclicn at the root or
        # one level down; find whichever ELF executable it contains.
        cli_src="$(find "$tmp_extract" -maxdepth 3 -type f \( -name "qodercli" -o -name "qoderclicn" \) | head -n 1)"
        if [ -z "$cli_src" ]; then
            cli_src="$(find "$tmp_extract" -maxdepth 3 -type f -size +10M | head -n 1)"
        fi
        if [ -n "$cli_src" ] && file "$cli_src" 2>/dev/null | grep -q "ELF 64-bit"; then
            cp "$cli_src" "$bin_dir/qoderclicn"
            chmod 0755 "$bin_dir/qoderclicn"
            info "  Installed Linux qoderclicn ($target, v$version) -> resources/bin/qoderclicn"
            ok=1
            break
        else
            warn "  Archive did not contain an ELF64 CLI binary; trying next source"
            bulk_rm "$cached"
        fi
    done

    if [ "$ok" -ne 1 ]; then
        warn "  Could not provision Linux qoderclicn automatically."
        warn "  Manual fallback: download qoderclicn-$target.tar.gz v$version from the"
        warn "  official site and place the binary at: $bin_dir/qoderclicn"
        warn "  Or set QODER_CLI_PATH at runtime to a custom CLI path."
    fi
}
