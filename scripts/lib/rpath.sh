#!/bin/bash
# Toolchain / RPATH hygiene helpers. Sourced by scripts; do not run directly.
#
# Why this file exists
# --------------------
# Conda (Anaconda/Miniconda/Mamba) and Linuxbrew place their own gcc/g++ on
# PATH *ahead* of the system compiler. Those toolchains inject
#   -Wl,-rpath,<conda-prefix>/lib
# into every shared object they link, so that their bundled libstdc++/libgcc
# is found at runtime. When node-gyp rebuilds node-pty / better-sqlite3 with a
# conda compiler, the resulting .node files carry a build-machine-only RPATH
# such as /home/<user>/anaconda3/lib. Consequences:
#   * rpmbuild's check-rpaths rejects it -> "ERROR 0002 ... invalid rpath"
#     -> "Bad exit status from /var/tmp/rpm-tmp.* (%install)" (make rpm fails)
#   * the binary is silently tied to a private, non-redistributable lib dir
# Two defences are provided: force the system toolchain at build time, and
# scrub offending RPATH entries afterwards as a safety net.

# Directories considered legitimate (redistributable) RPATH entries.
# Anything else that is an absolute path is treated as build-machine-local.
_rpath_is_system_dir() {
    case "$1" in
        /lib|/lib64|/usr/lib|/usr/lib64|/usr/local/lib|/usr/local/lib64) return 0 ;;
        /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*|/usr/local/lib/*|/usr/local/lib64/*) return 0 ;;
    esac
    return 1
}

# Resolve the system compiler directory, deliberately ignoring conda/brew
# toolchains. Echoes the directory containing both gcc and g++.
resolve_system_toolchain_dir() {
    local dir
    for dir in /usr/bin /usr/local/bin /bin; do
        if [ -x "$dir/gcc" ] && [ -x "$dir/g++" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Emit `eval`-able assignments that pin the compiler and clear the variables
# which make the linker bake extra search paths into DT_RPATH.
# Usage inside a subshell:
#   eval "$(build_toolchain_env)"
#   export CC CXX LINK LDFLAGS LD_RUN_PATH LIBRARY_PATH CPPFLAGS
build_toolchain_env() {
    local dir
    dir="$(resolve_system_toolchain_dir || true)"
    if [ -n "$dir" ]; then
        echo "CC=$dir/gcc"
        echo "CXX=$dir/g++"
        echo "LINK=$dir/g++"
    fi
    # Each of these can turn into an unwanted DT_RPATH/DT_RUNPATH entry.
    echo "LDFLAGS="
    echo "LD_RUN_PATH="
    echo "LIBRARY_PATH="
    echo "CPPFLAGS="
}

# scrub_local_rpaths <root>
#
# Walk every ELF addon under <root> and strip RPATH/RUNPATH entries that point
# at build-machine-private locations, KEEPING $ORIGIN-relative entries (sharp /
# libvips legitimately use them to locate their shared libraries) and standard
# system library directories.
scrub_local_rpaths() {
    local root="$1"
    local scanned=0 fixed=0 file current kept entry dropped saved_ifs

    if [ ! -d "$root" ]; then
        warn "  rpath scrub: $root does not exist; skipping"
        return 0
    fi

    if ! command -v patchelf >/dev/null 2>&1; then
        warn "  patchelf not found; skipping RPATH sanitation"
        warn "  Install it (dnf/apt/pacman: patchelf) if native modules keep build-machine rpaths"
        return 0
    fi
    if ! command -v readelf >/dev/null 2>&1; then
        warn "  readelf not found; skipping RPATH sanitation"
        return 0
    fi

    while IFS= read -r -d '' file; do
        scanned=$((scanned + 1))
        current="$(patchelf --print-rpath "$file" 2>/dev/null || true)"

        # An empty rpath is itself flagged by check-rpaths (0x0010); normalise.
        if [ -z "$current" ]; then
            if readelf -d "$file" 2>/dev/null | grep -qE '\(RPATH\)|\(RUNPATH\)'; then
                patchelf --remove-rpath "$file" 2>/dev/null || true
                fixed=$((fixed + 1))
                info "  scrubbed empty rpath: ${file#$root/}"
            fi
            continue
        fi

        kept=""
        dropped=""
        local saved_ifs="$IFS"
        IFS=':'
        for entry in $current; do
            [ -n "$entry" ] || continue
            case "$entry" in
                '$ORIGIN'*|'${ORIGIN}'*) kept="${kept:+$kept:}$entry" ;;
                *)
                    if _rpath_is_system_dir "$entry"; then
                        kept="${kept:+$kept:}$entry"
                    else
                        dropped="${dropped:+$dropped:}$entry"
                    fi
                    ;;
            esac
        done
        IFS="$saved_ifs"

        [ -n "$dropped" ] || continue

        if [ -n "$kept" ]; then
            if readelf -d "$file" 2>/dev/null | grep -q '(RUNPATH)'; then
                patchelf --set-rpath "$kept" "$file" 2>/dev/null || true
            else
                patchelf --force-rpath --set-rpath "$kept" "$file" 2>/dev/null || true
            fi
        else
            patchelf --remove-rpath "$file" 2>/dev/null || true
        fi
        fixed=$((fixed + 1))
        info "  scrubbed rpath [$dropped] from ${file#$root/}"
    done < <(find "$root" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)

    if [ "$fixed" -gt 0 ]; then
        info "RPATH sanitation: cleaned $fixed of $scanned ELF files"
    else
        info "RPATH sanitation: $scanned ELF files checked, no build-machine rpaths found"
    fi
    return 0
}
