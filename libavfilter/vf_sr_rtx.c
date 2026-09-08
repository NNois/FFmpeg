/*
 * Copyright (c) 2026 NNois
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * Super resolution through NVIDIA RTX Video SDK (VSR).
 *
 * The SDK is reached through rtxvsr.dll (thirdparty/rtxvsr), a small MSVC
 * shim loaded at runtime, so nothing NVIDIA-specific is linked here.
 * Colour goes through VSR as opaque RGBA. When the input carries alpha, the
 * alpha plane is upscaled in a second pass (VSR on the alpha as a grey image,
 * or bicubic) so yuva / rgba sources keep a matching alpha. Straight alpha is
 * premultiplied before VSR and unpremultiplied after, which avoids fringes on
 * transparent edges.
 */

#include <math.h>

#include "libavutil/mathematics.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libswscale/swscale.h"
#include "compat/w32dlfcn.h"

#include "avfilter.h"
#include "filters.h"
#include "formats.h"
#include "video.h"

#include <rtxvsr.h>

enum AlphaMethod {
    ALPHA_VSR,
    ALPHA_BICUBIC,
    ALPHA_NB
};

typedef struct SrRtxContext {
    const AVClass *class;

    double scale;
    int    w, h;
    int    quality;
    int    gpu;
    int    alpha_method;
    int    premult;

    void              *dll;
    rtxvsr_create_fn   create;
    rtxvsr_process_fn  process;
    rtxvsr_destroy_fn  destroy;
    RtxVsr            *vsr;

    int      has_alpha;
    uint8_t *src_buf;
    int      src_pitch;
    uint8_t *dst_buf;
    int      dst_pitch;
    uint8_t *alpha_in;
    uint8_t *alpha_out;
    struct SwsContext *sws;
} SrRtxContext;

#define OFFSET(x) offsetof(SrRtxContext, x)
#define FLAGS (AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_FILTERING_PARAM)

static const AVOption sr_rtx_options[] = {
    { "scale",   "output scale factor (used when w and h are 0)", OFFSET(scale),   AV_OPT_TYPE_DOUBLE, { .dbl = 2.0 }, 1.0, 8.0, FLAGS },
    { "w",       "output width (0: from scale)",                  OFFSET(w),       AV_OPT_TYPE_INT,    { .i64 = 0 },   0, INT_MAX, FLAGS },
    { "h",       "output height (0: from scale)",                 OFFSET(h),       AV_OPT_TYPE_INT,    { .i64 = 0 },   0, INT_MAX, FLAGS },
    { "quality", "VSR quality level (0: SDK bicubic, 4: best)",   OFFSET(quality), AV_OPT_TYPE_INT,    { .i64 = 4 },   RTXVSR_QUALITY_MIN, RTXVSR_QUALITY_MAX, FLAGS },
    { "gpu",     "CUDA device index",                             OFFSET(gpu),     AV_OPT_TYPE_INT,    { .i64 = 0 },   0, 15, FLAGS },
    { "alpha",   "alpha plane upscaling method",                  OFFSET(alpha_method), AV_OPT_TYPE_INT, { .i64 = ALPHA_VSR }, 0, ALPHA_NB - 1, FLAGS, .unit = "alpha" },
        { "vsr",     "run VSR on the alpha as a grey image", 0, AV_OPT_TYPE_CONST, { .i64 = ALPHA_VSR },     0, 0, FLAGS, .unit = "alpha" },
        { "bicubic", "swscale bicubic",                     0, AV_OPT_TYPE_CONST, { .i64 = ALPHA_BICUBIC }, 0, 0, FLAGS, .unit = "alpha" },
    { "premult", "premultiply straight alpha around VSR (-1: auto)", OFFSET(premult), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(sr_rtx);

/* dlsym returns FARPROC on Windows; go through void * to avoid the
 * incompatible function type cast warning. */
static void *load_sym(void *dll, const char *name)
{
    return (void *)dlsym(dll, name);
}

static av_cold int init(AVFilterContext *ctx)
{
    SrRtxContext *s = ctx->priv;
    rtxvsr_version_fn version;

    s->dll = dlopen(RTXVSR_DLL_NAME, RTLD_NOW);
    if (!s->dll) {
        av_log(ctx, AV_LOG_ERROR, "Cannot load %s. It must sit next to the host "
               "executable (ffmpeg.exe, mpv.exe...) together with nvngx_vsr.dll "
               "(see nnWork/SUPER-RESOLUTION.md).\n", RTXVSR_DLL_NAME);
        return AVERROR(ENOSYS);
    }

    version    = (rtxvsr_version_fn)load_sym(s->dll, "rtxvsr_version");
    s->create  = (rtxvsr_create_fn) load_sym(s->dll, "rtxvsr_create");
    s->process = (rtxvsr_process_fn)load_sym(s->dll, "rtxvsr_process");
    s->destroy = (rtxvsr_destroy_fn)load_sym(s->dll, "rtxvsr_destroy");
    if (!version || !s->create || !s->process || !s->destroy) {
        av_log(ctx, AV_LOG_ERROR, "%s does not export the rtxvsr API.\n", RTXVSR_DLL_NAME);
        return AVERROR(ENOSYS);
    }
    if (version() != RTXVSR_API_VERSION) {
        av_log(ctx, AV_LOG_ERROR, "%s API version %d, expected %d: rebuild it with "
               "build-msys-prepare-rtxvideosdk.sh.\n",
               RTXVSR_DLL_NAME, version(), RTXVSR_API_VERSION);
        return AVERROR(ENOSYS);
    }
    return 0;
}

static void free_buffers(SrRtxContext *s)
{
    av_freep(&s->src_buf);
    av_freep(&s->dst_buf);
    av_freep(&s->alpha_in);
    av_freep(&s->alpha_out);
    sws_freeContext(s->sws);
    s->sws = NULL;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    SrRtxContext *s = ctx->priv;

    if (s->vsr)
        s->destroy(s->vsr);
    s->vsr = NULL;
    free_buffers(s);
    if (s->dll)
        dlclose(s->dll);
    s->dll = NULL;
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    SrRtxContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    char err[256] = { 0 };
    int out_w, out_h;

    if (s->w > 0 && s->h > 0) {
        out_w = s->w;
        out_h = s->h;
    } else if (s->w > 0) {
        out_w = s->w;
        out_h = av_rescale(inlink->h, s->w, inlink->w);
    } else if (s->h > 0) {
        out_h = s->h;
        out_w = av_rescale(inlink->w, s->h, inlink->h);
    } else {
        out_w = lrint(inlink->w * s->scale);
        out_h = lrint(inlink->h * s->scale);
    }
    if (out_w < inlink->w || out_h < inlink->h) {
        av_log(ctx, AV_LOG_ERROR, "VSR only upscales: %dx%d -> %dx%d is not allowed.\n",
               inlink->w, inlink->h, out_w, out_h);
        return AVERROR(EINVAL);
    }

    outlink->w = out_w;
    outlink->h = out_h;
    if (inlink->sample_aspect_ratio.num)
        outlink->sample_aspect_ratio = av_mul_q((AVRational){ out_h * inlink->w, out_w * inlink->h },
                                                inlink->sample_aspect_ratio);
    else
        outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;

    s->has_alpha = inlink->format == AV_PIX_FMT_RGBA;

    free_buffers(s);
    s->src_pitch = FFALIGN(inlink->w * 4, 64);
    s->dst_pitch = FFALIGN(out_w * 4, 64);
    s->src_buf = av_malloc((size_t)s->src_pitch * inlink->h);
    if (!s->src_buf)
        return AVERROR(ENOMEM);
    if (s->has_alpha) {
        if (s->alpha_method == ALPHA_VSR) {
            s->dst_buf = av_malloc((size_t)s->dst_pitch * out_h);
            if (!s->dst_buf)
                return AVERROR(ENOMEM);
        } else {
            s->alpha_in  = av_malloc((size_t)FFALIGN(inlink->w, 32) * inlink->h);
            s->alpha_out = av_malloc((size_t)FFALIGN(out_w, 32) * out_h);
            s->sws = sws_getContext(inlink->w, inlink->h, AV_PIX_FMT_GRAY8,
                                    out_w, out_h, AV_PIX_FMT_GRAY8,
                                    SWS_BICUBIC, NULL, NULL, NULL);
            if (!s->alpha_in || !s->alpha_out || !s->sws)
                return AVERROR(ENOMEM);
        }
    }

    if (s->vsr)
        s->destroy(s->vsr);
    s->vsr = s->create(s->gpu, inlink->w, inlink->h, out_w, out_h, s->quality,
                       err, sizeof(err));
    if (!s->vsr) {
        av_log(ctx, AV_LOG_ERROR, "RTX VSR init failed: %s\n", err);
        return AVERROR_EXTERNAL;
    }

    av_log(ctx, AV_LOG_VERBOSE, "RTX VSR %dx%d -> %dx%d, quality %d, alpha %s\n",
           inlink->w, inlink->h, out_w, out_h, s->quality,
           !s->has_alpha ? "none" : s->alpha_method == ALPHA_VSR ? "vsr" : "bicubic");
    return 0;
}

static int filter_frame(AVFilterLink *inlink, AVFrame *in)
{
    AVFilterContext *ctx = inlink->dst;
    SrRtxContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    const int in_w = inlink->w, in_h = inlink->h;
    const int out_w = outlink->w, out_h = outlink->h;
    char err[256] = { 0 };
    AVFrame *out;
    unsigned transparent;
    int premult, x, y, ret;

    out = ff_get_video_buffer(outlink, out_w, out_h);
    if (!out) {
        av_frame_free(&in);
        return AVERROR(ENOMEM);
    }
    ret = av_frame_copy_props(out, in);
    if (ret < 0)
        goto fail;
    out->alpha_mode = outlink->alpha_mode;

    premult = s->has_alpha &&
              (s->premult == 1 ||
               (s->premult < 0 && inlink->alpha_mode != AVALPHA_MODE_PREMULTIPLIED));

    /* transparent stays 0 when every source alpha is 255: the alpha pass is
     * then skipped (opaque sources may still be negotiated as rgba). */
    transparent = 0;
    for (y = 0; y < in_h; y++) {
        const uint8_t *src = in->data[0] + y * in->linesize[0];
        uint8_t *dst = s->src_buf + y * s->src_pitch;
        if (premult) {
            for (x = 0; x < in_w; x++, src += 4, dst += 4) {
                const unsigned a = src[3];
                transparent |= a ^ 255;
                dst[0] = (src[0] * a + 127) / 255;
                dst[1] = (src[1] * a + 127) / 255;
                dst[2] = (src[2] * a + 127) / 255;
                dst[3] = 255;
            }
        } else {
            for (x = 0; x < in_w; x++, src += 4, dst += 4) {
                transparent |= src[3] ^ 255;
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
                dst[3] = 255;
            }
        }
    }

    if (s->process(s->vsr, s->src_buf, s->src_pitch,
                   out->data[0], out->linesize[0], err, sizeof(err)) < 0) {
        av_log(ctx, AV_LOG_ERROR, "RTX VSR colour pass failed: %s\n", err);
        ret = AVERROR_EXTERNAL;
        goto fail;
    }

    if (s->has_alpha && !transparent) {
        for (y = 0; y < out_h; y++) {
            uint8_t *dst = out->data[0] + y * out->linesize[0];
            for (x = 0; x < out_w; x++, dst += 4)
                dst[3] = 255;
        }
    } else if (s->has_alpha) {
        if (s->alpha_method == ALPHA_VSR) {
            for (y = 0; y < in_h; y++) {
                const uint8_t *src = in->data[0] + y * in->linesize[0];
                uint8_t *dst = s->src_buf + y * s->src_pitch;
                for (x = 0; x < in_w; x++, src += 4, dst += 4) {
                    dst[0] = dst[1] = dst[2] = src[3];
                    dst[3] = 255;
                }
            }
            if (s->process(s->vsr, s->src_buf, s->src_pitch,
                           s->dst_buf, s->dst_pitch, err, sizeof(err)) < 0) {
                av_log(ctx, AV_LOG_ERROR, "RTX VSR alpha pass failed: %s\n", err);
                ret = AVERROR_EXTERNAL;
                goto fail;
            }
            for (y = 0; y < out_h; y++) {
                const uint8_t *src = s->dst_buf + y * s->dst_pitch;
                uint8_t *dst = out->data[0] + y * out->linesize[0];
                for (x = 0; x < out_w; x++, src += 4, dst += 4)
                    dst[3] = src[1];
            }
        } else {
            const int in_pitch = FFALIGN(in_w, 32), out_pitch = FFALIGN(out_w, 32);
            const uint8_t *sws_src[4] = { s->alpha_in };
            uint8_t *sws_dst[4] = { s->alpha_out };
            int sws_src_stride[4] = { in_pitch };
            int sws_dst_stride[4] = { out_pitch };

            for (y = 0; y < in_h; y++) {
                const uint8_t *src = in->data[0] + y * in->linesize[0];
                uint8_t *dst = s->alpha_in + y * in_pitch;
                for (x = 0; x < in_w; x++, src += 4)
                    dst[x] = src[3];
            }
            sws_scale(s->sws, sws_src, sws_src_stride, 0, in_h, sws_dst, sws_dst_stride);
            for (y = 0; y < out_h; y++) {
                const uint8_t *src = s->alpha_out + y * out_pitch;
                uint8_t *dst = out->data[0] + y * out->linesize[0];
                for (x = 0; x < out_w; x++, dst += 4)
                    dst[3] = src[x];
            }
        }

        if (premult) {
            for (y = 0; y < out_h; y++) {
                uint8_t *px = out->data[0] + y * out->linesize[0];
                for (x = 0; x < out_w; x++, px += 4) {
                    const unsigned a = px[3];
                    if (a && a < 255) {
                        px[0] = FFMIN(255, (px[0] * 255 + a / 2) / a);
                        px[1] = FFMIN(255, (px[1] * 255 + a / 2) / a);
                        px[2] = FFMIN(255, (px[2] * 255 + a / 2) / a);
                    }
                }
            }
        }
    }

    av_frame_free(&in);
    return ff_filter_frame(outlink, out);

fail:
    av_frame_free(&in);
    av_frame_free(&out);
    return ret;
}

static const AVFilterPad sr_rtx_inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .filter_frame = filter_frame,
    },
};

static const AVFilterPad sr_rtx_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = config_output,
    },
};

const FFFilter ff_vf_sr_rtx = {
    .p.name        = "sr_rtx",
    .p.description = NULL_IF_CONFIG_SMALL("Upscale with NVIDIA RTX Video Super Resolution."),
    .p.priv_class  = &sr_rtx_class,
    .priv_size     = sizeof(SrRtxContext),
    .init          = init,
    .uninit        = uninit,
    FILTER_INPUTS(sr_rtx_inputs),
    FILTER_OUTPUTS(sr_rtx_outputs),
    FILTER_PIXFMTS(AV_PIX_FMT_RGBA, AV_PIX_FMT_RGB0),
};
