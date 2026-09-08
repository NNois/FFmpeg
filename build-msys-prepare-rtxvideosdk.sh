#!/bin/bash
# Prepare the NVIDIA RTX Video SDK (Video Super Resolution) for the MinGW64
# FFmpeg build.
#
# The SDK only ships an MSVC static library (nvsdk_ngx_s.lib, C++ runtime
# bound) which MinGW cannot link. So this script builds a tiny MSVC DLL,
# rtxvsr.dll (thirdparty/rtxvsr/rtxvsr.cpp + the SDK's CUDA sample wrapper),
# exposing a flat C API that libavfilter/vf_sr_rtx.c loads at runtime with
# LoadLibrary. Nothing NVIDIA-specific is linked into FFmpeg itself.
#
# Requirements (host):
#   - RTX Video SDK unpacked under thirdparty/rtxvideosdk (any subfolder depth)
#     https://developer.nvidia.com/rtx-video-sdk  (NVIDIA developer account)
#   - CUDA Toolkit 12.x  (only headers + cuda.lib / cudart_static.lib are used)
#   - Visual Studio 2022 with the C++ x64 toolset (found through vswhere)
#
# Usage: bash build-msys-prepare-rtxvideosdk.sh [path-to-RTX-Video-SDK]
# Output: thirdparty/rtxvsr/include/rtxvsr.h           (header for configure)
#         thirdparty/rtxvsr/build_mingw/rtxvsr.dll      (runtime, bundled)
#         thirdparty/rtxvsr/build_mingw/nvngx_vsr.dll   (SDK runtime, bundled,
#                                                        NOT redistributable)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTXVSR_ROOT="${RTXVSR_ROOT:-$SCRIPT_DIR/thirdparty/rtxvsr}"
RTXSDK_SEARCH="${RTXSDK_SEARCH:-$SCRIPT_DIR/thirdparty/rtxvideosdk}"
RTX_SDK_DIR="${1:-${RTX_SDK_DIR:-}}"
OUT_DIR="$RTXVSR_ROOT/build_mingw"
INC_DIR="$RTXVSR_ROOT/include"
LOG_FILE="${RTXSDK_PREPARE_LOG:-$SCRIPT_DIR/build-msys-prepare-rtxvideosdk.log}"

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Preparing NVIDIA RTX Video SDK (VSR) for MinGW64"
echo "=========================================="
echo "Date: $(date)"
echo "RTXVSR_ROOT=$RTXVSR_ROOT"
echo "Log: $LOG_FILE"
echo ""

# ---------------------------------------------------------------------------
echo "Step 1: Locating the RTX Video SDK..."
if [ -z "$RTX_SDK_DIR" ] || [ ! -d "$RTX_SDK_DIR" ]; then
    API_H="$(find "$RTXSDK_SEARCH" -maxdepth 6 -type f -name rtx_video_api.h -print -quit 2>/dev/null || true)"
    if [ -n "$API_H" ]; then
        RTX_SDK_DIR="$(cd "$(dirname "$API_H")/../.." && pwd)"
    fi
fi
if [ -z "$RTX_SDK_DIR" ] || [ ! -f "$RTX_SDK_DIR/samples/RTX_Video_API/rtx_video_api.h" ]; then
    echo "ERROR: RTX Video SDK not found."
    echo "  Unpack the SDK under: $RTXSDK_SEARCH"
    echo "  (expected <sdk>/samples/RTX_Video_API/rtx_video_api.h, <sdk>/include, <sdk>/lib, <sdk>/bin)"
    echo "  or pass the SDK root as first argument / RTX_SDK_DIR."
    exit 1
fi
SDK_API_DIR="$RTX_SDK_DIR/samples/RTX_Video_API"
SDK_INC_DIR="$RTX_SDK_DIR/include"
# x64 only: the SDK also ships arm64 binaries under bin/Windows/arm64 and
# lib/Windows/arm64, which must never be picked ("arm64" would match '*64*').
SDK_NGX_LIB="$(find "$RTX_SDK_DIR" -type f -name nvsdk_ngx_s.lib -path '*/Windows/x64/*' -print -quit 2>/dev/null || true)"
[ -n "$SDK_NGX_LIB" ] || SDK_NGX_LIB="$(find "$RTX_SDK_DIR" -type f -name nvsdk_ngx_s.lib -path '*/x64/*' -not -path '*arm64*' -print -quit 2>/dev/null || true)"
SDK_VSR_DLL="$(find "$RTX_SDK_DIR" -type f -name nvngx_vsr.dll -path '*/Windows/x64/rel/*' -print -quit 2>/dev/null || true)"
[ -n "$SDK_VSR_DLL" ] || SDK_VSR_DLL="$(find "$RTX_SDK_DIR" -type f -name nvngx_vsr.dll -path '*/x64/*' -not -path '*arm64*' -print -quit 2>/dev/null || true)"
SDK_IMPL_CPP="$SDK_API_DIR/rtx_video_api_cuda_impl.cpp"

echo "  SDK root:      $RTX_SDK_DIR"
echo "  API wrapper:   $SDK_API_DIR"
echo "  NGX lib:       ${SDK_NGX_LIB:-NOT FOUND}"
echo "  nvngx_vsr.dll: ${SDK_VSR_DLL:-NOT FOUND}"
for f in "$SDK_IMPL_CPP" "$SDK_NGX_LIB" "$SDK_VSR_DLL"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        echo "ERROR: required SDK file missing (see above)."
        exit 1
    fi
done
if [ ! -d "$SDK_INC_DIR" ]; then
    echo "ERROR: $SDK_INC_DIR not found (NGX headers)."
    exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "Step 2: Locating CUDA Toolkit..."
CUDA_DIR=""
if [ -n "$CUDA_PATH" ]; then
    CUDA_DIR="$(cygpath -u "$CUDA_PATH" 2>/dev/null || echo "$CUDA_PATH")"
fi
if [ -z "$CUDA_DIR" ] || [ ! -f "$CUDA_DIR/include/cuda.h" ]; then
    CUDA_DIR="$(ls -d "/c/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12."* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$CUDA_DIR" ] || [ ! -f "$CUDA_DIR/include/cuda.h" ]; then
    echo "ERROR: CUDA Toolkit 12.x not found (set CUDA_PATH)."
    exit 1
fi
if [ ! -f "$CUDA_DIR/lib/x64/cuda.lib" ]; then
    echo "ERROR: $CUDA_DIR/lib/x64/cuda.lib not found."
    exit 1
fi
echo "  CUDA: $CUDA_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "Step 3: Locating Visual Studio (vcvars64.bat)..."
VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
VCVARS=""
if [ -f "$VSWHERE" ]; then
    VS_PATH="$("$VSWHERE" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null | tr -d '\r' | head -1)"
    if [ -n "$VS_PATH" ]; then
        VCVARS="$(cygpath -u "$VS_PATH")/VC/Auxiliary/Build/vcvars64.bat"
    fi
fi
if [ -z "$VCVARS" ] || [ ! -f "$VCVARS" ]; then
    for e in Community Professional Enterprise BuildTools; do
        c="/c/Program Files/Microsoft Visual Studio/2022/$e/VC/Auxiliary/Build/vcvars64.bat"
        if [ -f "$c" ]; then VCVARS="$c"; break; fi
    done
fi
if [ -z "$VCVARS" ] || [ ! -f "$VCVARS" ]; then
    echo "ERROR: vcvars64.bat not found (Visual Studio 2022 with C++ x64 tools required)."
    exit 1
fi
echo "  vcvars64: $VCVARS"

# ---------------------------------------------------------------------------
echo ""
echo "Step 4: Building rtxvsr.dll with MSVC..."
mkdir -p "$OUT_DIR" "$INC_DIR"
rm -f "$OUT_DIR"/rtxvsr.* "$OUT_DIR"/*.obj

W_OUT="$(cygpath -w "$OUT_DIR")"
W_SRC="$(cygpath -w "$RTXVSR_ROOT/rtxvsr.cpp")"
# The SDK sample impl is compiled through rtx_sdk_glue.cpp (getchar/exit
# neutralised, APP_PATH = DLL directory); it is found via /I on the SDK dir.
W_GLUE="$(cygpath -w "$RTXVSR_ROOT/rtx_sdk_glue.cpp")"
W_INC_SELF="$(cygpath -w "$RTXVSR_ROOT")"
W_INC_API="$(cygpath -w "$SDK_API_DIR")"
W_INC_SDK="$(cygpath -w "$SDK_INC_DIR")"
W_INC_CUDA="$(cygpath -w "$CUDA_DIR/include")"
W_LIB_CUDA="$(cygpath -w "$CUDA_DIR/lib/x64")"
W_LIB_NGX="$(cygpath -w "$(dirname "$SDK_NGX_LIB")")"
W_VCVARS="$(cygpath -w "$VCVARS")"

BAT="$OUT_DIR/build-rtxvsr.bat"
cat > "$BAT" <<EOF
@echo off
call "$W_VCVARS" >nul
if errorlevel 1 exit /b 1
cd /d "$W_OUT"
cl /nologo /O2 /MT /EHsc /std:c++17 /W3 /DWIN32_LEAN_AND_MEAN /DNOMINMAX ^
   /I"$W_INC_SELF" /I"$W_INC_API" /I"$W_INC_SDK" /I"$W_INC_CUDA" ^
   "$W_SRC" "$W_GLUE" ^
   /link /DLL /OUT:rtxvsr.dll /LIBPATH:"$W_LIB_CUDA" /LIBPATH:"$W_LIB_NGX" ^
   cuda.lib cudart_static.lib nvsdk_ngx_s.lib user32.lib shell32.lib advapi32.lib
exit /b %ERRORLEVEL%
EOF

if ! MSYS2_ARG_CONV_EXCL="*" cmd.exe /c "$(cygpath -w "$BAT")" || [ ! -f "$OUT_DIR/rtxvsr.dll" ]; then
    echo "ERROR: rtxvsr.dll was not produced (see compiler output above)."
    exit 1
fi
rm -f "$OUT_DIR"/*.obj "$OUT_DIR"/rtxvsr.exp "$OUT_DIR"/rtxvsr.lib

# ---------------------------------------------------------------------------
echo ""
echo "Step 5: Copying header and SDK runtime..."
cp -v "$RTXVSR_ROOT/rtxvsr.h" "$INC_DIR/"
cp -v "$SDK_VSR_DLL" "$OUT_DIR/"

echo ""
echo "=========================================="
echo "✓ RTX Video SDK prepared"
echo "=========================================="
echo "Header:   $INC_DIR/rtxvsr.h"
echo "Runtime:  $OUT_DIR/rtxvsr.dll + nvngx_vsr.dll"
echo "Log:      $LOG_FILE"
echo ""
echo "build-msys-shared.sh will now pick it up automatically (--enable-librtxvsr)"
echo "and bundle both DLLs next to ffmpeg.exe. nvngx_vsr.dll is NVIDIA property:"
echo "do not redistribute the bundle outside the SDK license terms."
