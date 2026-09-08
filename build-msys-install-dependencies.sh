#!/bin/bash
# Install all MSYS2 dependencies for FFmpeg compilation with HAP support
# FFmpeg -  ♥♥ Alternative Development Broadcast Edition ♥♥ - 8.1.2
# Run this in MSYS2 MINGW64 terminal

set -e

echo "=========================================="
echo "FFmpeg -  ♥♥ Alternative Development Broadcast Edition ♥♥ - 8.1.2"
echo "Build Dependencies Installer"
echo "=========================================="
echo ""

# Check if we're in MSYS2
if ! command -v pacman &> /dev/null; then
    echo "❌ ERROR: pacman not found!"
    echo ""
    echo "You must run this script in MSYS2 MINGW64 terminal."
    echo "Please open MSYS2 MINGW64 and try again."
    exit 1
fi

echo "✓ Running in MSYS2 environment"
echo ""

# Update package database
echo "Step 1: Updating package database..."
pacman -Sy --noconfirm

echo ""
echo "Step 2: Installing build tools..."
pacman -S --needed --noconfirm \
    mingw-w64-x86_64-gcc \
    mingw-w64-x86_64-yasm \
    mingw-w64-x86_64-nasm \
    mingw-w64-x86_64-cmake \
    mingw-w64-x86_64-pkgconf \
    make \
    diffutils \
    curl \
    unzip

echo ""
echo "Step 3: Installing codec libraries..."

# x265 is NEVER taken from MSYS2: the package has neither alpha nor the
# 8+10+12 bit multilib this fork needs. It is built from source into /mingw64
# by build-msys-prepare-x265-with-alpha.sh. Detect what is installed so the
# script never overwrites a good build and only offers the source build when
# it is actually missing.
X265_OK=false
if command -v /mingw64/bin/x265 >/dev/null 2>&1 && \
   /mingw64/bin/x265 --version 2>&1 | grep -q "8bit+10bit+12bit" && \
   /mingw64/bin/x265 --help 2>/dev/null | grep -qi -- "--alpha"; then
    X265_OK=true
fi
if pacman -Q mingw-w64-x86_64-x265 >/dev/null 2>&1; then
    echo "⚠️  The MSYS2 package mingw-w64-x86_64-x265 is installed: a future"
    echo "   'pacman -Syu' can overwrite the source-built x265 (alpha + multilib)."
    echo "   Remove it with: pacman -Rdd mingw-w64-x86_64-x265"
    echo "   then re-run ./build-msys-prepare-x265-with-alpha.sh"
fi

# Install all codecs EXCEPT x265 (built from source, see above)
pacman -S --needed --noconfirm \
    mingw-w64-x86_64-snappy \
    mingw-w64-x86_64-x264 \
    mingw-w64-x86_64-libvpx \
    mingw-w64-x86_64-aom \
    mingw-w64-x86_64-svt-av1 \
    mingw-w64-x86_64-dav1d \
    mingw-w64-x86_64-libvorbis \
    mingw-w64-x86_64-opus \
    mingw-w64-x86_64-lame \
    mingw-w64-x86_64-fdk-aac

echo ""
echo "Step 4: Installing additional libraries..."
pacman -S --needed --noconfirm \
    mingw-w64-x86_64-openexr \
    mingw-w64-x86_64-libwebp \
    mingw-w64-x86_64-SDL2 \
    mingw-w64-x86_64-zlib \
    mingw-w64-x86_64-bzip2 \
    mingw-w64-x86_64-zimg \
    mingw-w64-x86_64-srt

echo ""
echo "Step 5: Installing Vulkan libraries..."
pacman -S --needed --noconfirm \
    mingw-w64-x86_64-vulkan-headers \
    mingw-w64-x86_64-vulkan-loader \
    mingw-w64-x86_64-shaderc \
    mingw-w64-x86_64-libplacebo

echo ""
echo ""
echo "=========================================="
echo "✓ All Dependencies Installed!"
echo "=========================================="
echo ""
echo "Installed packages:"
echo "  Build Tools:"
echo "    - GCC compiler"
echo "    - YASM & NASM assemblers"
echo "    - CMake & pkgconf"
echo ""
echo "  Codec Libraries:"
echo "    - Snappy (for HAP encoder) ⭐"
echo "    - x264 (H.264 encoder)"
if [ "$X265_OK" = "true" ]; then
    echo "    - x265 (H.265 encoder) - source build with alpha + multilib already in /mingw64 ⭐"
else
    echo "    - x265 (H.265 encoder) - NOT installed yet: run ./build-msys-prepare-x265-with-alpha.sh"
fi
echo "    - libvpx (VP8/VP9 encoder)"
echo "    - libaom (AV1 reference encoder)"
echo "    - SVT-AV1 (fast AV1 encoder)"
echo "    - dav1d (fast AV1 decoder)"
echo "    - libvorbis (Vorbis audio)"
echo "    - Opus (Opus audio)"
echo "    - LAME (MP3 encoder)"
echo "    - FDK-AAC (high-quality AAC encoder)"
echo ""
echo "  Additional Libraries:"
echo "    - OpenEXR (EXR support)"
echo "    - libwebp (WebP support)"
echo "    - SDL2 (video playback for ffplay)"
echo "    - zlib & bzip2 (compression)"
echo "    - zimg (zscale filter for high-quality scaling)"
echo "    - libsrt (Secure Reliable Transport protocol)"
echo ""
echo "  Vulkan Libraries:"
echo "    - Vulkan headers & loader (GPU acceleration)"
echo "    - Shaderc (SPIR-V shader compiler)"
echo ""
echo ""

if [ "$X265_OK" != "true" ]; then
    echo "Next steps:"
    echo "  1) ./build-msys-prepare-x265-with-alpha.sh  (build x265 with alpha support)"
    echo "  2) ./build-msys-shared.sh           (build FFmpeg)"
    echo ""
    echo "Run x265 build now? (Y/n)"
    read -r RUN_X265
    if [ -z "$RUN_X265" ] || [ "$RUN_X265" = "y" ] || [ "$RUN_X265" = "Y" ]; then
        ./build-msys-prepare-x265-with-alpha.sh
    fi
else
    echo "x265 (alpha + multilib) already prepared."
    echo "Optional SDK/asset preparation (each is picked up automatically by build-msys-shared.sh):"
    echo "  ./build-msys-prepare-shaders.sh       (SR shaders for the libplacebo filter)"
    echo "  ./build-msys-prepare-rtxvideosdk.sh   (RTX VSR shim, needs the SDK + MSVC + CUDA)"
    echo ""
    echo "You can now build FFmpeg with:"
    echo "  ./build-msys-shared.sh"
fi
echo ""
echo "⚠️  'pacman -Sy' + 'pacman -S' above UPGRADES already installed packages"
echo "   (libvpx, aom, dav1d, srt...). FFmpeg links against the new versions:"
echo "   rebuild it (./build-msys-shared.sh) AND redeploy every bundle"
echo "   (./build-msys-copy-with-dlls-shared.sh), otherwise the old DLLs left in"
echo "   nnTools/AdFlocon fail with e.g. libvpx 'ABI version mismatch'."
echo ""
