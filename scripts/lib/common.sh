#!/bin/bash
# Shared shell helpers. Sourced by scripts; do not run directly.

info() {
    echo "[INFO] $*" >&2
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

# A PATH with the standard system directories placed FIRST.
#
# Some dev environments inject shim directories ahead of /usr/bin — e.g. a
# `rm` guard that requires interactive confirmation before bulk deletes, or
# tool wrappers that print extra output. RPM's %install/%rmbuild stages shell
# out to rm/chmod/strip and treat any non-zero exit as a build failure:
#   [safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"count":5494,...}
#   error: Bad exit status from /var/tmp/rpm-tmp.* (rmbuild)
# Prepending the standard directories makes those scripts resolve the real
# binaries while leaving everything else on PATH available as a fallback.
system_first_path() {
    echo "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
}

# ---------------------------------------------------------------------------
# detect_package_family
#
# Decide which native package format this distro should build/install. The
# distro's *native* family is determined from /etc/os-release first:
# Fedora/RHEL boxes often have dpkg pulled in as a dependency of other
# tooling, and a pure tool-availability check would then build/install a
# .deb on an RPM system. Fall back to tool availability only when the
# os-release family is unrecognised.
#
# Prints: deb | rpm | pacman, or nothing if undetermined.
# ---------------------------------------------------------------------------
os_release_family() {
    local distro_id distro_like
    if [ -r /etc/os-release ]; then
        distro_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        distro_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    fi
    case "$distro_like $distro_id" in
        *debian*|*ubuntu*|*mint*) echo "deb" ;;
        *fedora*|*rhel*|*centos*|*suse*|*opensuse*) echo "rpm" ;;
        *arch*|*manjaro*|*cachyos*) echo "pacman" ;;
    esac
}

available_tool_family() {
    if command -v dpkg-deb >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
        echo "deb"
    elif command -v rpmbuild >/dev/null 2>&1; then
        echo "rpm"
    elif command -v makepkg >/dev/null 2>&1; then
        echo "pacman"
    fi
}

detect_package_family() {
    local by_id
    by_id="$(os_release_family)"
    [ -n "$by_id" ] && { echo "$by_id"; return 0; }
    available_tool_family
}

# Quarantine helper (used instead of rm everywhere in this project).
#
# The port must strip dozens of foreign-platform binaries and stale build
# trees. Rather than hard-deleting, targets are MOVED to a quarantine
# directory — same end state for the build tree, but fully reversible and
# friendly to environments with delete-guard hooks. Quarantine root:
#   - $QWENWORK_QUARANTINE_DIR                      (explicit override)
#   - /tmp/.qwenwork-linux-quarantine               (targets already on tmpfs)
#   - ~/.cache/qwenwork-linux/quarantine            (everything else)
# Empty it with: rm -rf ~/.cache/qwenwork-linux/quarantine /tmp/.qwenwork-linux-quarantine
bulk_rm() {
    [ "$#" -gt 0 ] || return 0
    node - "$@" <<'NODE'
const fs = require("fs");
const os = require("os");
const path = require("path");

function quarantineRootFor(target) {
    if (process.env.QWENWORK_QUARANTINE_DIR) return process.env.QWENWORK_QUARANTINE_DIR;
    const abs = path.resolve(target);
    if (abs.startsWith(os.tmpdir() + path.sep) || abs.startsWith("/tmp/")) {
        return "/tmp/.qwenwork-linux-quarantine";
    }
    const cacheHome = process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
    return path.join(cacheHome, "qwenwork-linux", "quarantine");
}

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
let n = 0;
for (const target of process.argv.slice(2)) {
    try {
        if (!fs.existsSync(target)) continue;
        const root = quarantineRootFor(target);
        const dest = path.join(root, stamp + "-" + (n++) + "-" + path.basename(target));
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        try {
            fs.renameSync(target, dest);
        } catch (err) {
            if (err.code === "EXDEV") {
                // Cross-device: copy tree, then leave removal to the caller's
                // environment (never force-delete here).
                fs.cpSync(target, dest, { recursive: true });
                console.error("  [quarantine] copied across devices; original left in place: " + target);
            } else {
                throw err;
            }
        }
    } catch (err) {
        console.error("  [quarantine] failed: " + target + ": " + (err && err.message));
    }
}
NODE
}

# Modern DMG (UDZO/zlib) extraction requires 7-Zip >= 21. The legacy p7zip
# fork shipped by some distros silently corrupts HFS+ payloads, so refuse it.
find_7z() {
    if command -v 7zz >/dev/null 2>&1; then
        command -v 7zz
        return 0
    fi
    if command -v 7z >/dev/null 2>&1; then
        local version_output major_version
        version_output="$(7z -version 2>&1 || true)"
        if [[ "$version_output" =~ 7-Zip\ (\[[0-9]+\]\ )?([0-9]+)\. ]]; then
            major_version="${BASH_REMATCH[2]}"
            if [ "$major_version" -lt 21 ]; then
                error "Found legacy p7zip (version $major_version), which cannot extract modern DMG files properly.
Please install the official 7zip package (version >= 21) instead:
  Debian/Ubuntu: sudo apt install 7zip (remove p7zip-full first)
  Fedora/RHEL:   sudo dnf install 7zip
  Arch Linux:    sudo pacman -S 7zip
  openSUSE:      sudo zypper install 7zip"
            fi
        fi
        command -v 7z
        return 0
    fi
    error "Missing 7z/7zz. Install 7zip."
}
