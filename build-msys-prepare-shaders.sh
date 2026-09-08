#!/bin/bash
# Fetch the CNN super-resolution user shaders (mpv .hook / .glsl format) used
# by the libplacebo filter (custom_shader_path=...). They are runtime assets,
# nothing is linked: build-msys-shared.sh only copies them next to ffmpeg.exe
# in a "shaders/" folder.
#
#   FSRCNNX  (igv, GPL-3.0)      x2 luma CNN, best on real footage
#   Anime4K  (bloc97, MIT)       x2 CNN family tuned for animation / graphics
#   RAVU     (bjin, LGPL-3.0)    x2 / zoom, learned non-CNN upscaler, cheap
#   NNEDI3   (bjin, LGPL-3.0)    x2 neural doubler, slow but very clean
#
# Usage: bash build-msys-prepare-shaders.sh
# Output: thirdparty/shaders/*.glsl *.hook  (+ LICENSES.txt)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHADERS_ROOT="${SHADERS_ROOT:-$SCRIPT_DIR/thirdparty/shaders}"
LOG_FILE="${SHADERS_PREPARE_LOG:-$SCRIPT_DIR/build-msys-prepare-shaders.log}"
TMP_DIR="$SHADERS_ROOT/.tmp"

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Preparing super-resolution shaders (libplacebo custom_shader)"
echo "=========================================="
echo "Date: $(date)"
echo "SHADERS_ROOT=$SHADERS_ROOT"
echo "Log: $LOG_FILE"
echo ""

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: 'curl' not found. Install it with: pacman -S curl"
    exit 1
fi

# unzip is not in the MSYS2 base install; bsdtar (libarchive, always present
# as a pacman dependency) reads zip files just as well.
extract_zip() {
    local zip="$1" dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -oq "$zip" -d "$dest"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$zip" -C "$dest"
    else
        echo "ERROR: neither 'unzip' nor 'bsdtar' found. Install one: pacman -S unzip"
        exit 1
    fi
}

mkdir -p "$SHADERS_ROOT" "$TMP_DIR"

fetch() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        echo "  (exists) $(basename "$dest")"
        return 0
    fi
    echo "  GET $url"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
}

echo "Step 1: FSRCNNX (igv/FSRCNN-TensorFlow release 1.1)..."
FSRCNNX_BASE="https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1"
fetch "$FSRCNNX_BASE/FSRCNNX_x2_8-0-4-1.glsl"  "$SHADERS_ROOT/FSRCNNX_x2_8-0-4-1.glsl"
fetch "$FSRCNNX_BASE/FSRCNNX_x2_16-0-4-1.glsl" "$SHADERS_ROOT/FSRCNNX_x2_16-0-4-1.glsl"

echo ""
echo "Step 2: Anime4K v4.0.1 (bloc97/Anime4K)..."
ANIME4K_ZIP="$TMP_DIR/Anime4K_v4.0.zip"
fetch "https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip" "$ANIME4K_ZIP"
mkdir -p "$SHADERS_ROOT/Anime4K"
extract_zip "$ANIME4K_ZIP" "$SHADERS_ROOT/Anime4K"
echo "  extracted $(ls "$SHADERS_ROOT/Anime4K"/*.glsl 2>/dev/null | wc -l) shaders into shaders/Anime4K/"

echo ""
echo "Step 3: RAVU + NNEDI3 (bjin/mpv-prescalers, master)..."
PRESCALERS_BASE="https://raw.githubusercontent.com/bjin/mpv-prescalers/master"
for f in ravu-r3.hook ravu-zoom-r3.hook ravu-lite-r3.hook nnedi3-nns32-win8x4.hook; do
    fetch "$PRESCALERS_BASE/$f" "$SHADERS_ROOT/$f"
done

echo ""
echo "Step 4: Writing LICENSES.txt..."
cat > "$SHADERS_ROOT/LICENSES.txt" <<'EOF'
Shaders bundled in shaders/ (runtime assets for the libplacebo filter):

FSRCNNX_x2_*.glsl        igv/FSRCNN-TensorFlow   GPL-3.0
Anime4K/*.glsl           bloc97/Anime4K          MIT
ravu-*.hook              bjin/mpv-prescalers     LGPL-3.0
nnedi3-*.hook            bjin/mpv-prescalers     LGPL-3.0

They are loaded at runtime from text files and are not linked into FFmpeg.
EOF

rm -rf "$TMP_DIR"

echo ""
echo "=========================================="
echo "✓ Shaders prepared"
echo "=========================================="
ls -1 "$SHADERS_ROOT"
echo ""
echo "build-msys-shared.sh copies them to <prefix>/bin/shaders/ automatically."
echo "Usage example (yuva420p, x2, alpha kept):"
echo '  ffmpeg -i in.mov -vf "libplacebo=w=iw*2:h=ih*2:custom_shader_path=shaders/FSRCNNX_x2_16-0-4-1.glsl:format=yuva444p" ...'
