#!/bin/bash
# Linux Electron runtime download. Sourced by install.sh.

electron_arch() {
    case "$ARCH" in
        x86_64) echo "x64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7l" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac
}

download_electron_runtime() {
    local arch zip_name url cache_dir cached_zip partial_zip

    arch="$(electron_arch)"
    zip_name="electron-v${ELECTRON_VERSION}-linux-${arch}.zip"
    if [ -n "$ELECTRON_MIRROR" ]; then
        url="${ELECTRON_MIRROR%/}/v${ELECTRON_VERSION}/${zip_name}"
    else
        url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${zip_name}"
    fi

    cache_dir="${QWENWORK_ELECTRON_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/qwenwork-linux/electron}"
    cached_zip="$cache_dir/$zip_name"
    partial_zip="$cached_zip.part"
    mkdir -p "$cache_dir"

    if [ ! -f "$cached_zip" ]; then
        info "Downloading $zip_name"
        curl -L --fail --continue-at - --progress-bar -o "$partial_zip" "$url"
        mv "$partial_zip" "$cached_zip"
    else
        info "Using cached Electron runtime: $cached_zip"
    fi

    unzip -qo "$cached_zip" -d "$INSTALL_DIR"
    [ -x "$INSTALL_DIR/electron" ] || error "Electron binary was not extracted"

    # Electron's zip ships a generic "electron" entry binary. Rename it to the
    # product name so ps/top/desktop launchers show a recognizable process,
    # and keep a compatibility symlink for scripts that expect "electron".
    if [ -x "$INSTALL_DIR/electron" ] && [ ! -e "$INSTALL_DIR/$APP_ID" ]; then
        cp "$INSTALL_DIR/electron" "$INSTALL_DIR/$APP_ID"
    fi
}
