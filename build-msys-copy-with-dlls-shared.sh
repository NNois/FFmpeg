#!/bin/bash
# Copy FFmpeg executables with required DLLs to make them portable
# FFmpeg -  ♥♥ Alternative Development Broadcast Edition ♥♥ - 8.1.2

set -e

FFMPEG_PREFIX="${FFMPEG_PREFIX:-./build}"
FFMPEG_BIN="$FFMPEG_PREFIX/bin"
ISPCTEXCOMP_ROOT="${ISPCTEXCOMP_ROOT:-$PWD/thirdparty/ISPCTextureCompressor}"

# Set by report_dest when a bundle still depends on MINGW64; checked on exit.
BUNDLE_INCOMPLETE=0

# Explicit destination as $1 = copy there directly (no prompts). Without
# argument, each KNOWN destination is offered with a y/N prompt below.
DEST_DIR="${1:-}"
NNTOOLS_DIR="${NNTOOLS_DIR:-/c/AD/nnTools/tools/ffmpeg}"
FLOCON_DIR="${FLOCON_DIR:-/c/AD/AdFlocon/libs/ffmpeg}"

# mpv ships in the same bundle. It is deliberately copied by this script and
# not by one of its own: mpv links against the FFmpeg DLLs sitting next to it,
# so its dependencies can only be resolved correctly from the destination
# directory, once those DLLs are in place.
MPV_SRC="${MPV_SRC:-/c/ff/mpv}"
MPV_BUILD_DIR="${MPV_BUILD_DIR:-$MPV_SRC/build}"
MPV_EXE="$MPV_BUILD_DIR/mpv.exe"
MPV_COM="$MPV_BUILD_DIR/mpv.com"

if [ -n "$DEST_DIR" ] && [ ! -d "$DEST_DIR" ]; then
    echo "Error: Destination directory does not exist: $DEST_DIR"
    exit 1
fi
if [ ! -d "$FFMPEG_BIN" ]; then
    echo "Error: FFmpeg install bin not found: $FFMPEG_BIN"
    exit 1
fi

echo "=========================================="
echo "FFmpeg -  ♥♥ Alternative Development Broadcast Edition ♥♥ - 8.1.2"
echo "Copying with DLLs"
echo "=========================================="
echo ""

# Build mpv BEFORE copying, so a fresh mpv.exe lands in the same pass.
if [ -z "$DEST_DIR" ] && [ -f "$MPV_SRC/build-mpv.sh" ]; then
    echo "=========================================="
    echo "mpv : $MPV_SRC"
    echo "=========================================="
    read -p "Rebuild mpv against this FFmpeg first? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        ( cd "$MPV_SRC" && ./build-mpv.sh )
        echo ""
    fi
fi

if [ -f "$MPV_EXE" ]; then
    echo "mpv found, will be bundled: $MPV_EXE"
    echo "  built $(date -r "$MPV_EXE" '+%Y-%m-%d %H:%M')"
else
    echo "mpv not built — bundling FFmpeg only."
    echo "  (build it with: cd $MPV_SRC && ./build-mpv.sh)"
fi
echo ""

# FFmpeg's own shared libraries, produced by the build.
copy_own_dlls() {
    local dest="$1"

    shopt -s nullglob
    local dlls=("$FFMPEG_BIN"/*.dll)
    shopt -u nullglob

    if [ ${#dlls[@]} -eq 0 ]; then
        echo "Warning: no DLL in $FFMPEG_BIN (shared build expected)."
        return
    fi
    for dll in "${dlls[@]}"; do
        cp -v "$dll" "$dest/"
    done
}

# Third-party runtime dependencies pulled out of MINGW64.
#
# These MUST be bundled, not left to the PATH. Without them the executables
# only run where MSYS2 happens to be installed, and they silently bind to
# whatever version the PATH offers first — which is how a stale libx265.dll
# elsewhere on the PATH produced "entry point x265_api_get_216 not found".
#
# ldd runs from inside $dest so the FFmpeg DLLs copied just above resolve from
# the application directory; everything else resolves from MINGW64. Each pass
# can expose dependencies of the DLLs added by the previous one, so repeat
# until nothing new is copied.
#
# PATH is forced to /mingw64/bin first: ldd follows the PATH, and another
# bundle earlier on it (tools/ffmpeg of nnTools, AdFlocon...) would otherwise
# shadow MINGW64 and be dropped by the grep. A DLL already in $dest is
# REPLACED when it differs from MINGW64: the bundle must match the library
# FFmpeg was just built against (libvpx 1.15 vs 1.17 = "ABI version mismatch").
copy_mingw_deps() {
    local dest="$1"
    local pass=0 added=1 dll required target

    while [ "$added" -ne 0 ] && [ "$pass" -lt 10 ]; do
        added=0
        pass=$((pass + 1))
        required=$(cd "$dest" && PATH="/mingw64/bin:$PATH" ldd ./*.exe ./*.dll 2>/dev/null \
                   | grep -i mingw64 | awk '{print $3}' | sort -u) || true
        for dll in $required; do
            [ -f "$dll" ] || continue
            target="$dest/$(basename "$dll")"
            if [ ! -f "$target" ]; then
                cp -v "$dll" "$target"
                added=$((added + 1))
            elif ! cmp -s "$dll" "$target"; then
                echo "updating stale $(basename "$dll")"
                cp -v "$dll" "$target"
                added=$((added + 1))
            fi
        done
    done

    if [ "$pass" -ge 10 ]; then
        echo "Warning: dependency scan did not settle after $pass passes."
    fi
}

# Fail loudly rather than shipping a bundle that only runs on this machine.
verify_bundle() {
    local dest="$1"
    local missing=""
    local dll

    for dll in $(cd "$dest" && PATH="/mingw64/bin:$PATH" ldd ./*.exe ./*.dll 2>/dev/null \
                 | grep -i mingw64 | awk '{print $3}' | sort -u); do
        [ -f "$dest/$(basename "$dll")" ] || missing="$missing $(basename "$dll")"
    done

    if [ -n "$missing" ]; then
        echo "✗ INCOMPLETE bundle in $dest, still resolved from MINGW64:"
        echo "   $missing"
        return 1
    fi
    echo "✓ Self-contained: no remaining MINGW64 dependency."
}

# The whole portable bundle (executables + DLLs + extras) into ONE directory.
copy_bundle() {
    local dest="$1"

    echo "Copying executables to $dest..."
    cp -v "$FFMPEG_BIN/ffmpeg.exe" "$dest/"
    cp -v "$FFMPEG_BIN/ffplay.exe" "$dest/"
    cp -v "$FFMPEG_BIN/ffprobe.exe" "$dest/"

    # mpv goes in before the dependency scan below, so its own libraries
    # (libass, libplacebo, lua51...) are picked up in the same pass.
    if [ -f "$MPV_EXE" ]; then
        cp -v "$MPV_EXE" "$dest/"
        if [ -f "$MPV_COM" ]; then
            cp -v "$MPV_COM" "$dest/"
        fi
    fi

    echo ""
    echo "Copying FFmpeg DLLs..."
    copy_own_dlls "$dest"

    echo ""
    echo "Copying third-party DLLs from MINGW64..."
    copy_mingw_deps "$dest"

    # Copy ISPCTextureCompressor runtime assets if present.
    if [ -f "$FFMPEG_BIN/ispc_texcomp.dll" ]; then
        cp -v "$FFMPEG_BIN/ispc_texcomp.dll" "$dest/"
    elif [ -f "$ISPCTEXCOMP_ROOT/lib/ispc_texcomp.dll" ]; then
        cp -v "$ISPCTEXCOMP_ROOT/lib/ispc_texcomp.dll" "$dest/"
    fi

    # Super-resolution shaders (libplacebo custom_shader_path), runtime assets.
    # rtxvsr.dll / nvngx_vsr.dll live in $FFMPEG_BIN and are already covered
    # by copy_own_dlls above.
    if [ -d "$FFMPEG_BIN/shaders" ]; then
        rm -rf "$dest/shaders"
        cp -r "$FFMPEG_BIN/shaders" "$dest/"
        echo "Copied shaders/ ($(find "$dest/shaders" -type f | wc -l) files)"
    fi

    # Ensure SDL2.dll is included for ffplay (not linked by ffprobe)
    if [ ! -f "$dest/SDL2.dll" ]; then
        for sdl in /mingw64/bin/SDL2.dll /c/msys64/mingw64/bin/SDL2.dll; do
            if [ -f "$sdl" ]; then
                cp -v "$sdl" "$dest/"
                break
            fi
        done
    fi
}

report_dest() {
    local dest="$1"
    echo ""
    echo "✓ Copied to: $dest ($(ls "$dest"/*.dll 2>/dev/null | wc -l) DLLs)"
    ls -lh "$dest"/{ffmpeg.exe,ffplay.exe,ffprobe.exe,mpv.exe,mpv.com,*.dll} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    echo ""
    verify_bundle "$dest" || BUNDLE_INCOMPLETE=1
    echo ""
}

# Prompted copy towards one known destination (skipped if absent/declined).
offer_copy() {
    local dest="$1"
    local label="$2"
    if [ ! -d "$dest" ]; then
        echo "($label absent — ignoré : $dest)"
        return
    fi
    echo "=========================================="
    echo "$label : $dest"
    echo "=========================================="
    read -p "Copy into $label? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        copy_bundle "$dest"
        report_dest "$dest"
    else
        echo "Skipping $label (later: $0 \"$dest\")."
        echo ""
    fi
}

if [ -n "$DEST_DIR" ]; then
    # Explicit destination: direct copy, no questions asked.
    copy_bundle "$DEST_DIR"
    report_dest "$DEST_DIR"
else
    # AD tools (shared CLI toolbox) then AdFlocon libs/ffmpeg/ (the runtime the
    # app and its NSIS installer embed — mpv.exe there is built separately).
    offer_copy "$NNTOOLS_DIR" "AD tools (nnTools)"
    offer_copy "$FLOCON_DIR" "AdFlocon libs/ffmpeg"
fi

echo "You can now use these executables from PowerShell or CMD."
echo ""

if [ "$BUNDLE_INCOMPLETE" -ne 0 ]; then
    echo ""
    echo "✗ At least one destination is still missing DLLs (listed above)."
    echo "  Those executables will bind to whatever the PATH provides, which"
    echo "  is how a stale libx265.dll breaks them after an x265 version bump."
    exit 1
fi

