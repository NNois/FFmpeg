/*
 * Compiles the RTX Video SDK sample wrapper (samples/RTX_Video_API/
 * rtx_video_api_cuda_impl.cpp, found through the include path) with two
 * changes needed inside a library:
 *
 *  - the sample's CHECK_* macros call getchar() then exit() on any failure,
 *    which would block a headless ffmpeg on stdin and then kill it. They are
 *    turned into a C++ exception that rtxvsr.cpp catches and reports.
 *  - APP_PATH (NGX application/log path, also searched for nvngx_*.dll) is
 *    the current directory in the sample; it becomes the directory holding
 *    rtxvsr.dll, i.e. next to ffmpeg.exe.
 *
 * Every header the sample needs is included first so the macros below only
 * affect the sample itself.
 */
#include <cuda.h>
#include <iostream>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

#include <nvsdk_ngx_defs.h>
#include <nvsdk_ngx_helpers_truehdr.h>
#include <nvsdk_ngx_helpers_vsr.h>
#include "rtx_video_api.h"
#include "utils.h"

const wchar_t *rtxvsr_ngx_app_path(void);

#undef APP_PATH
#define APP_PATH rtxvsr_ngx_app_path()

#define getchar() ((void)0)
#define exit(code) throw std::runtime_error("RTX Video SDK call failed (see stderr)")

#include "rtx_video_api_cuda_impl.cpp"
