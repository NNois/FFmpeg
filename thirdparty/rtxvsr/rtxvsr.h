/*
 * rtxvsr - minimal C API over the NVIDIA RTX Video SDK (Video Super Resolution)
 *
 * The RTX Video SDK ships an MSVC-only static library (nvsdk_ngx_s.lib) that
 * cannot be linked from MinGW. This header describes a small DLL, built with
 * MSVC by build-msys-prepare-rtxvideosdk.sh, that FFmpeg loads at runtime
 * (LoadLibrary) from libavfilter/vf_sr_rtx.c.
 *
 * Pixel format on both sides: 8-bit R8G8B8A8 (FFmpeg "rgba"), row-major,
 * top-down, any pitch. Output size is free (the SDK accepts any ratio, 1:1
 * only sharpens/deblocks). One instance per process (the SDK sample wrapper
 * keeps global state) and the NGX API is not thread safe: serialize calls.
 * Requirements: RTX 20xx or newer, driver >= 550.58 (R570+ for the CUDA
 * path), CUDA runtime from the driver. rtxvsr.dll and nvngx_vsr.dll are
 * looked up next to the HOST executable (ffmpeg.exe, mpv.exe...), not next
 * to avfilter.
 */
#ifndef RTXVSR_H
#define RTXVSR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RTXVSR_API_VERSION 1
#define RTXVSR_DLL_NAME    "rtxvsr.dll"

/* 0 = SDK bicubic (reference), 1..4 = VSR levels, 4 = best / slowest. */
#define RTXVSR_QUALITY_MIN 0
#define RTXVSR_QUALITY_MAX 4

#if defined(RTXVSR_BUILD_DLL)
#  define RTXVSR_API __declspec(dllexport)
#else
#  define RTXVSR_API
#endif

typedef struct RtxVsr RtxVsr;

/* Returns RTXVSR_API_VERSION of the DLL. */
RTXVSR_API int rtxvsr_version(void);

/*
 * Creates a CUDA context on gpu_index, initialises the RTX SDK and allocates
 * the src (src_w x src_h) and dst (dst_w x dst_h) surfaces.
 * quality: RTXVSR_QUALITY_MIN..RTXVSR_QUALITY_MAX (0 = bicubic, 4 = best).
 * On failure returns NULL and writes a message into err (if err_len > 0).
 */
RTXVSR_API RtxVsr *rtxvsr_create(int gpu_index,
                                 unsigned src_w, unsigned src_h,
                                 unsigned dst_w, unsigned dst_h,
                                 int quality,
                                 char *err, size_t err_len);

/*
 * Upscales one RGBA frame. src_pitch / dst_pitch are in bytes.
 * dst must hold dst_h rows of dst_w * 4 bytes.
 * Returns 0 on success, negative on failure (message in err).
 */
RTXVSR_API int rtxvsr_process(RtxVsr *ctx,
                              const uint8_t *src, size_t src_pitch,
                              uint8_t *dst, size_t dst_pitch,
                              char *err, size_t err_len);

RTXVSR_API void rtxvsr_destroy(RtxVsr *ctx);

/* Function pointer types for LoadLibrary / GetProcAddress users. */
typedef int      (*rtxvsr_version_fn)(void);
typedef RtxVsr  *(*rtxvsr_create_fn)(int, unsigned, unsigned, unsigned, unsigned,
                                     int, char *, size_t);
typedef int      (*rtxvsr_process_fn)(RtxVsr *, const uint8_t *, size_t,
                                      uint8_t *, size_t, char *, size_t);
typedef void     (*rtxvsr_destroy_fn)(RtxVsr *);

#ifdef __cplusplus
}
#endif

#endif /* RTXVSR_H */
