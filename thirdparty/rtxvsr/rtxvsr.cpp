/*
 * rtxvsr.dll - MSVC shim around the NVIDIA RTX Video SDK (VSR only).
 *
 * Built by build-msys-prepare-rtxvideosdk.sh together with the SDK sample
 * wrapper samples/RTX_Video_API/rtx_video_api_cuda_impl.cpp, which provides
 * rtx_video_api_cuda_create / _evaluate / _shutdown. Host RGBA in, host RGBA
 * out through CUDA arrays (any pitch), CUDA driver API only. Mirrors the host
 * path of RTXVideoProcessor (github.com/DrC0ns0le/RTXVideoProcessor, MIT).
 */
#define RTXVSR_BUILD_DLL
#include "rtxvsr.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <cuda.h>

#include <cstdio>
#include <cstring>
#include <exception>
#include <new>

#include "rtx_video_api.h"

/* Directory of this DLL, handed to NVSDK_NGX_CUDA_Init through the glue TU
 * (rtx_sdk_glue.cpp) so NGX finds nvngx_vsr.dll next to the executable. */
const wchar_t *rtxvsr_ngx_app_path(void)
{
    static wchar_t path[MAX_PATH] = L".";
    static bool resolved = false;
    if (!resolved) {
        HMODULE self = nullptr;
        if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               (LPCWSTR)&rtxvsr_ngx_app_path, &self) &&
            GetModuleFileNameW(self, path, MAX_PATH)) {
            wchar_t *slash = wcsrchr(path, L'\\');
            if (slash)
                *slash = 0;
        } else {
            wcscpy_s(path, L".");
        }
        resolved = true;
    }
    return path;
}

struct RtxVsr {
    CUdevice     device      = 0;
    CUcontext    ctx         = nullptr;
    CUarray      src_array   = nullptr;
    CUarray      dst_array   = nullptr;
    CUtexObject  src_tex     = 0;
    CUsurfObject dst_surf    = 0;
    unsigned     src_w = 0, src_h = 0, dst_w = 0, dst_h = 0;
    int          quality     = RTXVSR_QUALITY_MAX;
    bool         rtx_created = false;
};

/* The SDK sample wrapper is a singleton: refuse a second live instance. */
static int g_instances = 0;

static void set_err(char *err, size_t err_len, const char *msg)
{
    if (!err || !err_len)
        return;
    snprintf(err, err_len, "%s", msg);
    err[err_len - 1] = 0;
}

static void set_cu_err(char *err, size_t err_len, const char *what, CUresult r)
{
    const char *name = "unknown";
    cuGetErrorName(r, &name);
    if (err && err_len) {
        snprintf(err, err_len, "%s failed: %s (%d)", what, name ? name : "unknown", (int)r);
        err[err_len - 1] = 0;
    }
}

#define CU_TRY(call, what)                                  \
    do {                                                    \
        CUresult r_ = (call);                               \
        if (r_ != CUDA_SUCCESS) {                           \
            set_cu_err(err, err_len, what, r_);             \
            return false;                                   \
        }                                                   \
    } while (0)

/* Push / pop the instance context around every driver call so the caller may
 * use any thread. */
struct CtxScope {
    explicit CtxScope(CUcontext c) { cuCtxPushCurrent(c); }
    ~CtxScope() { CUcontext dummy; cuCtxPopCurrent(&dummy); }
};

static bool alloc_surfaces(RtxVsr *v, char *err, size_t err_len)
{
    CUDA_ARRAY_DESCRIPTOR src_desc = {};
    src_desc.Width       = v->src_w;
    src_desc.Height      = v->src_h;
    src_desc.Format      = CU_AD_FORMAT_UNSIGNED_INT8;
    src_desc.NumChannels = 4;
    CU_TRY(cuArrayCreate(&v->src_array, &src_desc), "cuArrayCreate(src)");

    CUDA_RESOURCE_DESC src_res = {};
    src_res.resType          = CU_RESOURCE_TYPE_ARRAY;
    src_res.res.array.hArray = v->src_array;

    CUDA_TEXTURE_DESC tex_desc = {};
    tex_desc.addressMode[0] = CU_TR_ADDRESS_MODE_CLAMP;
    tex_desc.addressMode[1] = CU_TR_ADDRESS_MODE_CLAMP;
    tex_desc.filterMode     = CU_TR_FILTER_MODE_LINEAR;
    tex_desc.flags          = CU_TRSF_NORMALIZED_COORDINATES;
    CU_TRY(cuTexObjectCreate(&v->src_tex, &src_res, &tex_desc, nullptr), "cuTexObjectCreate");

    CUDA_ARRAY_DESCRIPTOR dst_desc = {};
    dst_desc.Width       = v->dst_w;
    dst_desc.Height      = v->dst_h;
    dst_desc.Format      = CU_AD_FORMAT_UNSIGNED_INT8;
    dst_desc.NumChannels = 4;
    CU_TRY(cuArrayCreate(&v->dst_array, &dst_desc), "cuArrayCreate(dst)");

    CUDA_RESOURCE_DESC dst_res = {};
    dst_res.resType          = CU_RESOURCE_TYPE_ARRAY;
    dst_res.res.array.hArray = v->dst_array;
    CU_TRY(cuSurfObjectCreate(&v->dst_surf, &dst_res), "cuSurfObjectCreate");
    return true;
}

static void free_surfaces(RtxVsr *v)
{
    if (v->src_tex)   { cuTexObjectDestroy(v->src_tex);   v->src_tex = 0; }
    if (v->dst_surf)  { cuSurfObjectDestroy(v->dst_surf); v->dst_surf = 0; }
    if (v->src_array) { cuArrayDestroy(v->src_array);     v->src_array = nullptr; }
    if (v->dst_array) { cuArrayDestroy(v->dst_array);     v->dst_array = nullptr; }
}

extern "C" {

RTXVSR_API int rtxvsr_version(void)
{
    return RTXVSR_API_VERSION;
}

RTXVSR_API RtxVsr *rtxvsr_create(int gpu_index,
                                 unsigned src_w, unsigned src_h,
                                 unsigned dst_w, unsigned dst_h,
                                 int quality,
                                 char *err, size_t err_len)
{
    if (g_instances > 0) {
        set_err(err, err_len, "only one rtxvsr instance per process is supported");
        return nullptr;
    }
    if (!src_w || !src_h || !dst_w || !dst_h) {
        set_err(err, err_len, "invalid dimensions");
        return nullptr;
    }
    if (quality < RTXVSR_QUALITY_MIN || quality > RTXVSR_QUALITY_MAX) {
        set_err(err, err_len, "quality out of range");
        return nullptr;
    }

    RtxVsr *v = new (std::nothrow) RtxVsr();
    if (!v) {
        set_err(err, err_len, "out of memory");
        return nullptr;
    }
    v->src_w = src_w; v->src_h = src_h;
    v->dst_w = dst_w; v->dst_h = dst_h;
    v->quality = quality;

    CUresult r = cuInit(0);
    if (r != CUDA_SUCCESS) {
        set_cu_err(err, err_len, "cuInit", r);
        delete v;
        return nullptr;
    }
    int count = 0;
    cuDeviceGetCount(&count);
    if (count <= 0) {
        set_err(err, err_len, "no CUDA device found");
        delete v;
        return nullptr;
    }
    if (gpu_index < 0 || gpu_index >= count)
        gpu_index = 0;
    r = cuDeviceGet(&v->device, gpu_index);
    if (r == CUDA_SUCCESS)
        r = cuCtxCreate(&v->ctx, 0, v->device);
    if (r != CUDA_SUCCESS) {
        set_cu_err(err, err_len, "cuCtxCreate", r);
        delete v;
        return nullptr;
    }

    /* cuCtxCreate leaves the context current on this thread. The sample
     * wrapper throws (see rtx_sdk_glue.cpp) instead of exiting on failure. */
    API_BOOL created = API_BOOL_FAIL;
    try {
        created = rtx_video_api_cuda_create(v->ctx, nullptr, gpu_index,
                                            API_BOOL_FAIL, API_BOOL_SUCCESS);
    } catch (const std::exception &e) {
        set_err(err, err_len, e.what());
    }
    if (!created) {
        if (err && err_len && !err[0])
            set_err(err, err_len, "rtx_video_api_cuda_create failed (VSR not available: "
                                  "check nvngx_vsr.dll next to the host executable, "
                                  "driver >= 550.58 (R570+ for CUDA) and an RTX 20xx+ GPU)");
        /* The wrapper has already run NVSDK_NGX_CUDA_Init and allocated its
         * state when it reports VSR unavailable: release it so a retry does
         * not double-init. */
        try { rtx_video_api_cuda_shutdown(); } catch (...) {}
        cuCtxDestroy(v->ctx);
        delete v;
        return nullptr;
    }
    v->rtx_created = true;

    if (!alloc_surfaces(v, err, err_len)) {
        free_surfaces(v);
        try { rtx_video_api_cuda_shutdown(); } catch (...) {}
        cuCtxDestroy(v->ctx);
        delete v;
        return nullptr;
    }

    CUcontext dummy;
    cuCtxPopCurrent(&dummy);
    g_instances++;
    return v;
}

RTXVSR_API int rtxvsr_process(RtxVsr *v,
                              const uint8_t *src, size_t src_pitch,
                              uint8_t *dst, size_t dst_pitch,
                              char *err, size_t err_len)
{
    if (!v || !src || !dst) {
        set_err(err, err_len, "null argument");
        return -1;
    }
    if (src_pitch < (size_t)v->src_w * 4 || dst_pitch < (size_t)v->dst_w * 4) {
        set_err(err, err_len, "pitch smaller than row size");
        return -1;
    }

    CtxScope scope(v->ctx);

    CUDA_MEMCPY2D in = {};
    in.srcMemoryType = CU_MEMORYTYPE_HOST;
    in.srcHost       = src;
    in.srcPitch      = src_pitch;
    in.dstMemoryType = CU_MEMORYTYPE_ARRAY;
    in.dstArray      = v->src_array;
    in.WidthInBytes  = (size_t)v->src_w * 4;
    in.Height        = v->src_h;
    CUresult r = cuMemcpy2D(&in);
    if (r != CUDA_SUCCESS) {
        set_cu_err(err, err_len, "cuMemcpy2D(upload)", r);
        return -1;
    }

    API_RECT src_rect = { 0u, 0u, v->src_w, v->src_h };
    API_RECT dst_rect = { 0u, 0u, v->dst_w, v->dst_h };
    API_VSR_Setting vsr = {};
    vsr.QualityLevel = v->quality;

    API_BOOL ok = API_BOOL_FAIL;
    try {
        ok = rtx_video_api_cuda_evaluate(v->src_tex, v->dst_surf, src_rect, dst_rect,
                                         &vsr, nullptr);
    } catch (const std::exception &e) {
        set_err(err, err_len, e.what());
        return -1;
    }
    if (!ok) {
        set_err(err, err_len, "rtx_video_api_cuda_evaluate failed");
        return -1;
    }
    /* VSR runs on NGX's own streams; a plain cuMemcpy2D only orders against
     * the legacy default stream, so wait for the whole context first. */
    r = cuCtxSynchronize();
    if (r != CUDA_SUCCESS) {
        set_cu_err(err, err_len, "cuCtxSynchronize", r);
        return -1;
    }

    CUDA_MEMCPY2D out = {};
    out.srcMemoryType = CU_MEMORYTYPE_ARRAY;
    out.srcArray      = v->dst_array;
    out.dstMemoryType = CU_MEMORYTYPE_HOST;
    out.dstHost       = dst;
    out.dstPitch      = dst_pitch;
    out.WidthInBytes  = (size_t)v->dst_w * 4;
    out.Height        = v->dst_h;
    r = cuMemcpy2D(&out);
    if (r != CUDA_SUCCESS) {
        set_cu_err(err, err_len, "cuMemcpy2D(download)", r);
        return -1;
    }
    return 0;
}

RTXVSR_API void rtxvsr_destroy(RtxVsr *v)
{
    if (!v)
        return;
    if (v->ctx) {
        cuCtxPushCurrent(v->ctx);
        cuCtxSynchronize();
        free_surfaces(v);
        if (v->rtx_created) {
            try { rtx_video_api_cuda_shutdown(); } catch (...) {}
        }
        CUcontext dummy;
        cuCtxPopCurrent(&dummy);
        cuCtxDestroy(v->ctx);
    }
    delete v;
    g_instances--;
}

} /* extern "C" */
