#include "AO46MesaBridge.h"

#include "AppleOpenGL46Private.h"

#include <stdio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "pipe/p_context.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "frontend/api.h"
#include "state_tracker/st_context.h"
#include "state_tracker/st_manager.h"
#include "glapi/glapi.h"
#include "util/u_atomic.h"
#include "util/u_inlines.h"
#include "util/u_math.h"
#include "util/u_memory.h"

#include "mtl_pub.h"

struct AO46MesaDrawable {
    struct pipe_frontend_drawable base;
    struct st_visual visual;
    struct pipe_screen *screen;
    struct pipe_resource *textures[ST_ATTACHMENT_COUNT];
    struct pipe_resource *resolve_textures[ST_ATTACHMENT_COUNT];
    struct pipe_surface *present_surface;
    struct pipe_resource *pbuffer_storage;
    void *window_handle;
    void *baseaddr;
    unsigned width;
    unsigned height;
    unsigned rowbytes;
    unsigned pbuffer_level;
    unsigned pbuffer_layer;
    bool window_backed;
    bool double_buffer;
    bool pbuffer_backed;
};

struct AO46MesaFrontendScreen {
    struct pipe_frontend_screen base;
};

static struct pipe_screen *g_gl_screen = NULL;
static struct AO46MesaFrontendScreen g_frontend_screen = {0};
static pthread_mutex_t g_gl_screen_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_next_drawable_id = 1;

static void
ao46_mesa_query_versions(int *gl_core_version,
                         int *gl_compat_version,
                         int *gl_es1_version,
                         int *gl_es2_version)
{
    struct st_config_options options;

    memset(&options, 0, sizeof(options));
    st_api_query_versions(&g_frontend_screen.base,
                          &options,
                          gl_core_version,
                          gl_compat_version,
                          gl_es1_version,
                          gl_es2_version);
}

static inline struct AO46MesaDrawable *
ao46_mesa_drawable(struct pipe_frontend_drawable *drawable)
{
    return (struct AO46MesaDrawable *)drawable;
}

static enum st_attachment_type
ao46_mesa_color_attachment(const struct AO46MesaDrawable *drawable)
{
    return drawable->double_buffer ? ST_ATTACHMENT_BACK_LEFT : ST_ATTACHMENT_FRONT_LEFT;
}

static struct pipe_resource *
ao46_mesa_drawable_resolve_resource(const struct AO46MesaDrawable *drawable)
{
    enum st_attachment_type color_slot;

    if (!drawable) {
        return NULL;
    }

    color_slot = ao46_mesa_color_attachment(drawable);
    if (drawable->resolve_textures[color_slot]) {
        return drawable->resolve_textures[color_slot];
    }

    return drawable->textures[color_slot];
}

static unsigned
ao46_mesa_mip_size(unsigned base, unsigned level)
{
    return MAX2(u_minify(base, level), 1u);
}

static bool
ao46_mesa_target_to_pipe(GLenum target,
                         GLint max_level,
                         enum pipe_texture_target *out_target,
                         unsigned *out_array_size)
{
    switch (target) {
        case GL_TEXTURE_2D:
            *out_target = PIPE_TEXTURE_2D;
            *out_array_size = 1;
            return true;
        case GL_TEXTURE_RECTANGLE:
            if (max_level != 0) {
                return false;
            }
            *out_target = PIPE_TEXTURE_RECT;
            *out_array_size = 1;
            return true;
        case GL_TEXTURE_CUBE_MAP:
            *out_target = PIPE_TEXTURE_CUBE;
            *out_array_size = 6;
            return true;
        default:
            return false;
    }
}

static bool
ao46_mesa_internal_format_to_pipe(GLenum internal_format,
                                  enum pipe_format *out_format)
{
    switch (internal_format) {
        case GL_RGBA:
        case GL_RGBA8:
            *out_format = PIPE_FORMAT_R8G8B8A8_UNORM;
            return true;
        case GL_SRGB8_ALPHA8:
            *out_format = PIPE_FORMAT_R8G8B8A8_SRGB;
            return true;
        default:
            return false;
    }
}

static bool
ao46_mesa_face_to_layer(GLenum target, GLenum face, unsigned *out_layer)
{
    if (!out_layer) {
        return false;
    }

    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            if (face != 0 && face != target) {
                return false;
            }
            *out_layer = 0;
            return true;
        case GL_TEXTURE_CUBE_MAP:
            switch (face) {
                case 0:
                case GL_TEXTURE_CUBE_MAP:
                case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
                    *out_layer = 0;
                    return true;
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
                    *out_layer = 1;
                    return true;
                case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
                    *out_layer = 2;
                    return true;
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
                    *out_layer = 3;
                    return true;
                case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
                    *out_layer = 4;
                    return true;
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
                    *out_layer = 5;
                    return true;
                default:
                    return false;
            }
        default:
            return false;
    }
}

static GLenum
ao46_mesa_texture_binding(GLenum target)
{
    switch (target) {
        case GL_TEXTURE_2D:
            return GL_TEXTURE_BINDING_2D;
        case GL_TEXTURE_RECTANGLE:
            return GL_TEXTURE_BINDING_RECTANGLE;
        case GL_TEXTURE_CUBE_MAP:
            return GL_TEXTURE_BINDING_CUBE_MAP;
        default:
            return 0;
    }
}

static GLenum
ao46_mesa_texture_image_target(GLenum target, GLenum face)
{
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            return target;
        case GL_TEXTURE_CUBE_MAP:
            switch (face) {
                case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
                case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
                case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
                case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
                    return face;
                default:
                    return 0;
            }
        default:
            return 0;
    }
}

static bool
ao46_mesa_supported_pbuffer_source(GLenum source)
{
    switch (source) {
        case GL_FRONT:
        case GL_BACK:
        case GL_FRONT_LEFT:
        case GL_BACK_LEFT:
            return true;
        default:
            return false;
    }
}

static void
ao46_mesa_release_surface(struct pipe_surface **surface)
{
    if (!surface || !*surface) {
        return;
    }

    pipe_resource_reference(&(*surface)->texture, NULL);
    free(*surface);
    *surface = NULL;
}

static struct pipe_surface *
ao46_mesa_create_surface_view(struct pipe_resource *texture,
                              enum pipe_format format,
                              unsigned level,
                              unsigned first_layer,
                              unsigned last_layer)
{
    struct pipe_surface *surface;

    if (!texture) {
        return NULL;
    }

    surface = calloc(1, sizeof(*surface));
    if (!surface) {
        return NULL;
    }

    pipe_reference_init(&surface->reference, 1);
    pipe_resource_reference(&surface->texture, texture);
    surface->format = format;
    surface->nr_samples = texture->nr_samples;
    surface->level = level;
    surface->first_layer = first_layer;
    surface->last_layer = last_layer;
    return surface;
}

static void
ao46_mesa_profile_version(GLint profile, int *major, int *minor)
{
    *major = 4;
    *minor = 6;

    if (profile == kCGLOGLPVersion_GL3_Core) {
        *major = 3;
        *minor = 2;
    } else if (profile == kCGLOGLPVersion_GL4_Core) {
        *major = 4;
        *minor = 1;
    }
}

static void
ao46_mesa_fill_visual(AO46PixelFormatRef pix, struct st_visual *visual)
{
    GLint alpha_bits = 8;
    GLint depth_bits = 24;
    GLint stencil_bits = 8;
    GLint sample_buffers = 0;
    GLint samples = 0;
    GLint double_buffer = 1;

    memset(visual, 0, sizeof(*visual));

    AO46DescribePixelFormat(pix, 0, kCGLPFAAlphaSize, &alpha_bits);
    AO46DescribePixelFormat(pix, 0, kCGLPFADepthSize, &depth_bits);
    AO46DescribePixelFormat(pix, 0, kCGLPFAStencilSize, &stencil_bits);
    AO46DescribePixelFormat(pix, 0, kCGLPFASampleBuffers, &sample_buffers);
    AO46DescribePixelFormat(pix, 0, kCGLPFASamples, &samples);
    AO46DescribePixelFormat(pix, 0, kCGLPFADoubleBuffer, &double_buffer);

    visual->buffer_mask = ST_ATTACHMENT_FRONT_LEFT_MASK;
    if (double_buffer) {
        visual->buffer_mask |= ST_ATTACHMENT_BACK_LEFT_MASK;
    }
    if (depth_bits > 0 || stencil_bits > 0) {
        visual->buffer_mask |= ST_ATTACHMENT_DEPTH_STENCIL_MASK;
    }

    visual->color_format = alpha_bits > 0 ? PIPE_FORMAT_B8G8R8A8_UNORM
                                          : PIPE_FORMAT_B8G8R8X8_UNORM;
    visual->depth_stencil_format =
        (depth_bits > 0 || stencil_bits > 0) ? PIPE_FORMAT_Z24_UNORM_S8_UINT
                                             : PIPE_FORMAT_NONE;
    visual->accum_format = PIPE_FORMAT_NONE;
    visual->samples = sample_buffers > 0 ? (unsigned)samples : 0;
}

static struct pipe_resource *
ao46_mesa_create_texture_resource(struct pipe_screen *screen,
                                  enum pipe_texture_target target,
                                  enum pipe_format format,
                                  unsigned width,
                                  unsigned height,
                                  unsigned depth,
                                  unsigned array_size,
                                  unsigned last_level,
                                  unsigned samples,
                                  unsigned storage_samples,
                                  unsigned bind)
{
    struct pipe_resource templ;

    memset(&templ, 0, sizeof(templ));
    templ.target = target;
    templ.format = format;
    templ.width0 = width;
    templ.height0 = height;
    templ.depth0 = depth;
    templ.array_size = array_size;
    templ.last_level = last_level;
    templ.nr_samples = samples;
    templ.nr_storage_samples = storage_samples;
    templ.bind = bind;
    return screen->resource_create(screen, &templ);
}

static bool
ao46_mesa_sync_pbuffer_storage(AO46ContextRef ctx, bool from_drawable_to_pbuffer)
{
    struct AO46MesaDrawable *drawable;
    struct pipe_resource *stage;
    struct pipe_box src_box;

    if (!ctx || !ctx->pipe || !ctx->drawable || !ctx->pbuffer) {
        return true;
    }

    drawable = ctx->drawable;
    if (!drawable->pbuffer_backed || !drawable->pbuffer_storage) {
        return true;
    }

    stage = ao46_mesa_drawable_resolve_resource(drawable);
    if (!stage || !drawable->width || !drawable->height) {
        return false;
    }

    src_box.x = 0;
    src_box.y = 0;
    src_box.z = from_drawable_to_pbuffer ? 0 : (int)drawable->pbuffer_layer;
    src_box.width = (int)drawable->width;
    src_box.height = (int)drawable->height;
    src_box.depth = 1;

    if (from_drawable_to_pbuffer) {
        ctx->pipe->resource_copy_region(ctx->pipe,
                                        drawable->pbuffer_storage,
                                        drawable->pbuffer_level,
                                        0,
                                        0,
                                        drawable->pbuffer_layer,
                                        stage,
                                        0,
                                        &src_box);
    } else {
        ctx->pipe->resource_copy_region(ctx->pipe,
                                        stage,
                                        0,
                                        0,
                                        0,
                                        0,
                                        drawable->pbuffer_storage,
                                        drawable->pbuffer_level,
                                        &src_box);
    }

    return true;
}

static void
ao46_mesa_prepare_drawable_release(AO46ContextRef ctx)
{
    if (!ctx || !ctx->drawable) {
        return;
    }

    if (ctx->drawable->pbuffer_backed) {
        (void)ao46_mesa_sync_pbuffer_storage(ctx, true);
    }
}

static int
ao46_mesa_screen_get_param(struct pipe_frontend_screen *fscreen,
                           enum st_manager_param param)
{
    (void)fscreen;
    return param == ST_MANAGER_BROKEN_INVALIDATE ? 0 : 0;
}

static bool
ao46_mesa_sync_offscreen_storage(AO46ContextRef ctx)
{
    struct AO46MesaDrawable *drawable;
    struct pipe_resource *color;
    struct pipe_transfer *transfer = NULL;
    struct pipe_box box;
    unsigned char *map;

    if (!ctx || !ctx->drawable || !ctx->offscreen_baseaddr) {
        return true;
    }

    drawable = ctx->drawable;
    color = ao46_mesa_drawable_resolve_resource(drawable);
    if (!color) {
        return true;
    }

    box.x = 0;
    box.y = 0;
    box.z = 0;
    box.width = drawable->width;
    box.height = drawable->height;
    box.depth = 1;

    map = ctx->pipe->texture_map(ctx->pipe, color, 0, PIPE_MAP_READ, &box, &transfer);
    if (!map) {
        return false;
    }

    for (unsigned y = 0; y < drawable->height; ++y) {
        memcpy((unsigned char *)ctx->offscreen_baseaddr + (y * drawable->rowbytes),
               map + (y * transfer->stride),
               drawable->width * 4u);
    }

    ctx->pipe->texture_unmap(ctx->pipe, transfer);
    return true;
}

static bool
ao46_mesa_download_texture_image(struct pipe_context *pipe,
                                 struct pipe_resource *texture,
                                 unsigned level,
                                 unsigned layer,
                                 unsigned width,
                                 unsigned height,
                                 unsigned rowbytes,
                                 unsigned char *dst)
{
    struct pipe_transfer *transfer = NULL;
    struct pipe_box box;
    unsigned char *map;

    if (!pipe || !texture || !dst || !width || !height) {
        return false;
    }

    box.x = 0;
    box.y = 0;
    box.z = (int)layer;
    box.width = (int)width;
    box.height = (int)height;
    box.depth = 1;

    map = pipe->texture_map(pipe, texture, level, PIPE_MAP_READ, &box, &transfer);
    if (!map) {
        return false;
    }

    for (unsigned y = 0; y < height; ++y) {
        memcpy(dst + (y * rowbytes),
               map + (y * transfer->stride),
               width * 4u);
    }

    pipe->texture_unmap(pipe, transfer);
    return true;
}

static bool
ao46_mesa_flush_front(struct st_context *st,
                      struct pipe_frontend_drawable *pdrawable,
                      enum st_attachment_type statt)
{
    struct AO46MesaDrawable *drawable = ao46_mesa_drawable(pdrawable);
    AO46ContextRef ctx = (AO46ContextRef)st->frontend_context;

    (void)statt;

    if (drawable->window_backed && drawable->present_surface) {
        return ao46_metal_present(st->pipe, drawable->present_surface) == kCGLNoError;
    }

    if (drawable->pbuffer_backed) {
        return ao46_mesa_sync_pbuffer_storage(ctx, true);
    }

    return ao46_mesa_sync_offscreen_storage(ctx);
}

static bool
ao46_mesa_flush_swapbuffers(struct st_context *st,
                            struct pipe_frontend_drawable *pdrawable)
{
    struct AO46MesaDrawable *drawable = ao46_mesa_drawable(pdrawable);
    AO46ContextRef ctx = (AO46ContextRef)st->frontend_context;

    if (drawable->window_backed && drawable->present_surface) {
        return ao46_metal_present(st->pipe, drawable->present_surface) == kCGLNoError;
    }

    if (drawable->pbuffer_backed) {
        return ao46_mesa_sync_pbuffer_storage(ctx, true);
    }

    return ao46_mesa_sync_offscreen_storage(ctx);
}

static void
ao46_mesa_release_drawable_surfaces(struct AO46MesaDrawable *drawable)
{
    for (unsigned i = 0; i < ST_ATTACHMENT_COUNT; ++i) {
        pipe_resource_reference(&drawable->textures[i], NULL);
        pipe_resource_reference(&drawable->resolve_textures[i], NULL);
    }

    ao46_mesa_release_surface(&drawable->present_surface);
    pipe_resource_reference(&drawable->pbuffer_storage, NULL);
    drawable->pbuffer_level = 0;
    drawable->pbuffer_layer = 0;
    drawable->pbuffer_backed = false;
}

static void
ao46_mesa_destroy_drawable(struct AO46MesaDrawable *drawable)
{
    if (!drawable) {
        return;
    }

    st_api_destroy_drawable(&drawable->base);
    ao46_mesa_release_drawable_surfaces(drawable);
    free(drawable);
}

static struct AO46MesaDrawable *
ao46_mesa_create_drawable(const struct st_visual *visual,
                          bool window_backed,
                          bool double_buffer)
{
    struct AO46MesaDrawable *drawable = calloc(1, sizeof(*drawable));
    if (!drawable) {
        return NULL;
    }

    drawable->visual = *visual;
    drawable->screen = g_gl_screen;
    drawable->window_backed = window_backed;
    drawable->double_buffer = double_buffer;

    drawable->base.visual = &drawable->visual;
    drawable->base.fscreen = &g_frontend_screen.base;
    drawable->base.flush_front = ao46_mesa_flush_front;
    drawable->base.flush_swapbuffers = ao46_mesa_flush_swapbuffers;
    drawable->base.validate = NULL;
    p_atomic_set(&drawable->base.stamp, 1);
    drawable->base.ID = p_atomic_inc_return((int32_t *)&g_next_drawable_id);

    return drawable;
}

static bool
ao46_mesa_ensure_depth_buffer(struct AO46MesaDrawable *drawable)
{
    struct pipe_resource templ;

    if (drawable->visual.depth_stencil_format == PIPE_FORMAT_NONE) {
        return true;
    }
    if (drawable->textures[ST_ATTACHMENT_DEPTH_STENCIL]) {
        return true;
    }

    memset(&templ, 0, sizeof(templ));
    templ.target = PIPE_TEXTURE_2D;
    templ.format = drawable->visual.depth_stencil_format;
    templ.width0 = drawable->width;
    templ.height0 = drawable->height;
    templ.depth0 = 1;
    templ.array_size = 1;
    templ.last_level = 0;
    templ.nr_samples = drawable->visual.samples;
    templ.nr_storage_samples = drawable->visual.samples;
    templ.bind = PIPE_BIND_DEPTH_STENCIL;

    drawable->textures[ST_ATTACHMENT_DEPTH_STENCIL] =
        drawable->screen->resource_create(drawable->screen, &templ);
    return drawable->textures[ST_ATTACHMENT_DEPTH_STENCIL] != NULL;
}

static struct pipe_resource *
ao46_mesa_create_resolve_texture(const struct AO46MesaDrawable *drawable,
                                 enum pipe_format format,
                                 unsigned bind)
{
    if (!drawable || drawable->visual.samples <= 1) {
        return NULL;
    }

    return ao46_mesa_create_texture_resource(drawable->screen,
                                             PIPE_TEXTURE_2D,
                                             format,
                                             drawable->width,
                                             drawable->height,
                                             1,
                                             1,
                                             0,
                                             1,
                                             1,
                                             bind);
}

static bool
ao46_mesa_validate_drawable(struct st_context *st,
                            struct pipe_frontend_drawable *pdrawable,
                            const enum st_attachment_type *statts,
                            unsigned count,
                            struct pipe_resource **out,
                            struct pipe_resource **resolve)
{
    struct AO46MesaDrawable *drawable = ao46_mesa_drawable(pdrawable);
    enum st_attachment_type color_slot = ao46_mesa_color_attachment(drawable);
    struct pipe_resource *resolve_resource = ao46_mesa_drawable_resolve_resource(drawable);
    bool needs_resolve = false;

    (void)st;

    if (!drawable->textures[color_slot]) {
        return false;
    }
    if (!ao46_mesa_ensure_depth_buffer(drawable)) {
        return false;
    }

    for (unsigned i = 0; i < count; ++i) {
        struct pipe_resource *resource = NULL;

        switch (statts[i]) {
            case ST_ATTACHMENT_FRONT_LEFT:
            case ST_ATTACHMENT_BACK_LEFT:
                resource = drawable->textures[color_slot];
                needs_resolve = drawable->resolve_textures[color_slot] != NULL;
                break;
            case ST_ATTACHMENT_DEPTH_STENCIL:
                resource = drawable->textures[ST_ATTACHMENT_DEPTH_STENCIL];
                break;
            default:
                break;
        }

        pipe_resource_reference(&out[i], resource);
    }

    if (resolve) {
        pipe_resource_reference(resolve, needs_resolve ? resolve_resource : NULL);
    }
    return true;
}

static void
ao46_mesa_mark_drawable_dirty(AO46ContextRef ctx)
{
    if (ctx && ctx->drawable) {
        p_atomic_inc(&ctx->drawable->base.stamp);
    }
}

static CGLError
ao46_mesa_bind_current_drawable(AO46ContextRef ctx)
{
    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }

    if (!st_api_make_current(ctx->st,
                             ctx->drawable ? &ctx->drawable->base : NULL,
                             ctx->drawable ? &ctx->drawable->base : NULL)) {
        return kCGLBadContext;
    }

    return kCGLNoError;
}

static void
ao46_mesa_clear_pbuffer_binding(AO46ContextRef ctx)
{
    if (ctx && ctx->pbuffer) {
        ao46_mesa_prepare_drawable_release(ctx);
        AO46DestroyPBuffer(ctx->pbuffer);
        ctx->pbuffer = NULL;
    }
}

static CGLError
ao46_mesa_build_window_target(AO46ContextRef ctx, struct AO46MesaDrawable *drawable)
{
    struct pipe_resource *color = NULL;
    struct pipe_resource *msaa_color = NULL;
    struct pipe_surface *present_surface = NULL;
    enum st_attachment_type color_slot = ao46_mesa_color_attachment(drawable);
    CGLError err;

    ao46_mesa_release_drawable_surfaces(drawable);

    err = ao46_metal_create_window_surface(ctx->pipe,
                                           drawable->window_handle,
                                           &color,
                                           &present_surface);
    if (err != kCGLNoError) {
        return err;
    }

    drawable->width = color->width0;
    drawable->height = color->height0;
    drawable->rowbytes = color->width0 * 4u;
    if (drawable->visual.samples > 1) {
        msaa_color = ao46_mesa_create_texture_resource(drawable->screen,
                                                       PIPE_TEXTURE_2D,
                                                       color->format,
                                                       drawable->width,
                                                       drawable->height,
                                                       1,
                                                       1,
                                                       0,
                                                       drawable->visual.samples,
                                                       drawable->visual.samples,
                                                       PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW);
        if (!msaa_color) {
            ao46_mesa_release_surface(&present_surface);
            pipe_resource_reference(&color, NULL);
            return kCGLBadAlloc;
        }
    }

    pipe_resource_reference(&drawable->textures[color_slot], msaa_color ? msaa_color : color);
    pipe_resource_reference(&drawable->resolve_textures[color_slot], msaa_color ? color : NULL);
    drawable->present_surface = present_surface;
    pipe_resource_reference(&ctx->tex, ao46_mesa_drawable_resolve_resource(drawable));
    pipe_resource_reference(&msaa_color, NULL);
    pipe_resource_reference(&color, NULL);
    return kCGLNoError;
}

static CGLError
ao46_mesa_attach_existing_texture(AO46ContextRef ctx,
                                  struct AO46MesaDrawable *drawable,
                                  struct pipe_resource *texture,
                                  struct pipe_resource *resolve_texture,
                                  unsigned width,
                                  unsigned height,
                                  unsigned rowbytes,
                                  void *baseaddr)
{
    enum st_attachment_type color_slot = ao46_mesa_color_attachment(drawable);

    ao46_mesa_release_drawable_surfaces(drawable);
    pipe_resource_reference(&drawable->textures[color_slot], texture);
    pipe_resource_reference(&drawable->resolve_textures[color_slot], resolve_texture);
    pipe_resource_reference(&ctx->tex,
                            resolve_texture ? resolve_texture : texture);

    drawable->width = width;
    drawable->height = height;
    drawable->rowbytes = rowbytes;
    drawable->baseaddr = baseaddr;
    return kCGLNoError;
}

static CGLError
ao46_mesa_upload_offscreen(AO46ContextRef ctx,
                           struct pipe_resource *texture,
                           const void *baseaddr,
                           GLsizei width,
                           GLsizei height,
                           GLint rowbytes)
{
    struct pipe_transfer *transfer = NULL;
    struct pipe_box box;
    unsigned char *map;

    if (!baseaddr) {
        return kCGLNoError;
    }

    box.x = 0;
    box.y = 0;
    box.z = 0;
    box.width = width;
    box.height = height;
    box.depth = 1;

    map = ctx->pipe->texture_map(ctx->pipe, texture, 0, PIPE_MAP_WRITE, &box, &transfer);
    if (!map) {
        return kCGLBadAlloc;
    }

    for (GLsizei y = 0; y < height; ++y) {
        memcpy(map + (y * transfer->stride),
               (const unsigned char *)baseaddr + (y * rowbytes),
               (size_t)width * 4u);
    }

    ctx->pipe->texture_unmap(ctx->pipe, transfer);
    return kCGLNoError;
}

static struct pipe_resource *
ao46_mesa_create_color_texture(const struct AO46MesaDrawable *drawable)
{
    return ao46_mesa_create_texture_resource(drawable->screen,
                                             PIPE_TEXTURE_2D,
                                             drawable->visual.color_format,
                                             drawable->width,
                                             drawable->height,
                                             1,
                                             1,
                                             0,
                                             drawable->visual.samples,
                                             drawable->visual.samples,
                                             PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW);
}

CGLError
AO46MesaInit(void)
{
    pthread_mutex_lock(&g_gl_screen_lock);

    if (!g_gl_screen) {
        g_gl_screen = ao46_metal_screen_create();
        if (!g_gl_screen) {
            pthread_mutex_unlock(&g_gl_screen_lock);
            return kCGLBadContext;
        }

        memset(&g_frontend_screen, 0, sizeof(g_frontend_screen));
        g_frontend_screen.base.screen = g_gl_screen;
        g_frontend_screen.base.get_param = ao46_mesa_screen_get_param;
    }

    pthread_mutex_unlock(&g_gl_screen_lock);
    return kCGLNoError;
}

CGLError
AO46MesaCreateContext(AO46PixelFormatRef pix,
                      AO46ContextRef share,
                      AO46ContextRef *out_ctx)
{
    struct st_context_attribs attribs;
    int gl_core_version = 0;
    int gl_compat_version = 0;
    int gl_es1_version = 0;
    int gl_es2_version = 0;
    int requested_core_version = 0;
    int realized_core_version = 0;
    struct st_context *shared_st = share ? share->st : NULL;
    struct st_visual visual;
    enum st_context_error error = ST_CONTEXT_SUCCESS;
    GLint profile = kCGLOGLPVersion_GL4_6_Core;
    AO46ContextRef ctx;
    CGLError err;

    if (!pix || !out_ctx) {
        return kCGLBadAddress;
    }

    err = AO46MesaInit();
    if (err != kCGLNoError) {
        return err;
    }

    ao46_mesa_fill_visual(pix, &visual);
    AO46DescribePixelFormat(pix, 0, kCGLPFAOpenGLProfile, &profile);

    memset(&attribs, 0, sizeof(attribs));
    attribs.profile = API_OPENGL_CORE;
    attribs.visual = visual;
    ao46_mesa_profile_version(profile, &attribs.major, &attribs.minor);
    requested_core_version = attribs.major * 10 + attribs.minor;

    ao46_mesa_query_versions(&gl_core_version,
                             &gl_compat_version,
                             &gl_es1_version,
                             &gl_es2_version);
    if (getenv("AO46_TRACE_RUNTIME")) {
        fprintf(stderr,
                "[AO46Mesa] requested core=%d.%d supported core=%d.%d compat=%d.%d es1=%d.%d es2=%d.%d\n",
                attribs.major,
                attribs.minor,
                gl_core_version / 10,
                gl_core_version % 10,
                gl_compat_version / 10,
                gl_compat_version % 10,
                gl_es1_version / 10,
                gl_es1_version % 10,
                gl_es2_version / 10,
                gl_es2_version % 10);
    }
    if (gl_core_version <= 0) {
        return kCGLBadPixelFormat;
    }
    realized_core_version = MIN2(gl_core_version, 46);
    if (realized_core_version < requested_core_version) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr,
                    "[AO46Mesa] falling back to supported core=%d.%d for requested core=%d.%d\n",
                    realized_core_version / 10,
                    realized_core_version % 10,
                    requested_core_version / 10,
                    requested_core_version % 10);
        }
    }
    attribs.major = realized_core_version / 10;
    attribs.minor = realized_core_version % 10;

    ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        return kCGLBadAlloc;
    }

    ctx->retain_count = 1;
    ctx->pixel_format = AO46RetainPixelFormat(pix);
    ctx->virtual_screen = 0;

    ctx->st = st_api_create_context(&g_frontend_screen.base, &attribs, &error, shared_st);
    if (!ctx->st) {
        AO46DestroyPixelFormat(ctx->pixel_format);
        free(ctx);
        return error == ST_CONTEXT_ERROR_BAD_VERSION ? kCGLBadPixelFormat : kCGLBadAlloc;
    }

    ctx->pipe = ctx->st->pipe;
    ctx->st->frontend_context = ctx;

    if (share) {
        ctx->share_group = share->share_group;
    }

    *out_ctx = ctx;
    return kCGLNoError;
}

void
AO46MesaDestroyContext(AO46ContextRef ctx)
{
    if (!ctx) {
        return;
    }

    if (ctx->retain_count > 1) {
        ctx->retain_count--;
        return;
    }

    ao46_mesa_clear_pbuffer_binding(ctx);

    if (ctx->drawable) {
        ao46_mesa_prepare_drawable_release(ctx);
        ao46_mesa_destroy_drawable(ctx->drawable);
        ctx->drawable = NULL;
    }

    if (ctx->st && st_api_get_current() == ctx->st) {
        st_api_make_current(NULL, NULL, NULL);
    }

    if (ctx->st) {
        st_destroy_context(ctx->st);
        ctx->st = NULL;
    }

    pipe_resource_reference(&ctx->tex, NULL);
    if (ctx->pixel_format) {
        AO46DestroyPixelFormat(ctx->pixel_format);
    }
    free(ctx);
}

CGLError
AO46MesaMakeCurrent(AO46ContextRef ctx)
{
    CGLError err = AO46MesaInit();
    if (err != kCGLNoError) {
        return err;
    }

    if (!ctx) {
        return st_api_make_current(NULL, NULL, NULL) ? kCGLNoError : kCGLBadContext;
    }

    if (!ctx->st) {
        return kCGLBadContext;
    }

    return ao46_mesa_bind_current_drawable(ctx);
}

AO46ContextRef
AO46MesaGetCurrent(void)
{
    struct st_context *st = st_api_get_current();
    return st ? (AO46ContextRef)st->frontend_context : NULL;
}

CGLError
AO46MesaAttachWindow(AO46ContextRef ctx, void *window)
{
    struct st_visual visual;
    struct AO46MesaDrawable *drawable;
    GLint double_buffer = 1;
    CGLError err;

    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }
    if (!window) {
        return kCGLBadWindow;
    }

    AO46DescribePixelFormat(ctx->pixel_format, 0, kCGLPFADoubleBuffer, &double_buffer);
    ao46_mesa_fill_visual(ctx->pixel_format, &visual);
    visual.color_format = PIPE_FORMAT_R8G8B8A8_UNORM;

    if (ctx->drawable) {
        ao46_mesa_prepare_drawable_release(ctx);
        ao46_mesa_destroy_drawable(ctx->drawable);
        ctx->drawable = NULL;
    }

    drawable = ao46_mesa_create_drawable(&visual, true, double_buffer != 0);
    if (!drawable) {
        return kCGLBadAlloc;
    }

    drawable->base.validate = ao46_mesa_validate_drawable;
    drawable->window_handle = window;
    ctx->drawable = drawable;
    ctx->window_handle = window;
    ctx->drawable_kind = AO46DrawableKindWindow;
    ctx->offscreen = false;
    ctx->offscreen_baseaddr = NULL;
    ctx->offscreen_width = 0;
    ctx->offscreen_height = 0;
    ctx->offscreen_rowbytes = 0;
    ao46_mesa_clear_pbuffer_binding(ctx);

    err = ao46_mesa_build_window_target(ctx, drawable);
    if (err != kCGLNoError) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        return err;
    }

    ao46_mesa_mark_drawable_dirty(ctx);
    if (AO46MesaGetCurrent() == ctx) {
        return ao46_mesa_bind_current_drawable(ctx);
    }
    return kCGLNoError;
}

CGLError
AO46MesaAttachOffscreen(AO46ContextRef ctx,
                        void *baseaddr,
                        GLsizei width,
                        GLsizei height,
                        GLint rowbytes)
{
    struct st_visual visual;
    struct AO46MesaDrawable *drawable;
    struct pipe_resource *color;
    struct pipe_resource *resolve = NULL;
    GLint double_buffer = 0;
    CGLError err;

    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }
    if (!baseaddr || width <= 0 || height <= 0 || rowbytes <= 0) {
        return kCGLBadOffScreen;
    }

    AO46DescribePixelFormat(ctx->pixel_format, 0, kCGLPFADoubleBuffer, &double_buffer);
    ao46_mesa_fill_visual(ctx->pixel_format, &visual);
    visual.color_format = PIPE_FORMAT_R8G8B8A8_UNORM;

    if (ctx->drawable) {
        ao46_mesa_prepare_drawable_release(ctx);
        ao46_mesa_destroy_drawable(ctx->drawable);
        ctx->drawable = NULL;
    }

    drawable = ao46_mesa_create_drawable(&visual, false, double_buffer != 0);
    if (!drawable) {
        return kCGLBadAlloc;
    }

    drawable->base.validate = ao46_mesa_validate_drawable;
    drawable->width = (unsigned)width;
    drawable->height = (unsigned)height;
    drawable->rowbytes = (unsigned)rowbytes;
    drawable->baseaddr = baseaddr;

    color = ao46_mesa_create_color_texture(drawable);
    if (!color) {
        ao46_mesa_destroy_drawable(drawable);
        return kCGLBadAlloc;
    }

    resolve = ao46_mesa_create_resolve_texture(drawable,
                                               visual.color_format,
                                               PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW);
    if (drawable->visual.samples > 1 && !resolve) {
        pipe_resource_reference(&color, NULL);
        ao46_mesa_destroy_drawable(drawable);
        return kCGLBadAlloc;
    }

    ctx->drawable = drawable;
    ctx->drawable_kind = AO46DrawableKindHeadless;
    ctx->offscreen = true;
    ctx->offscreen_baseaddr = baseaddr;
    ctx->offscreen_width = width;
    ctx->offscreen_height = height;
    ctx->offscreen_rowbytes = rowbytes;
    ctx->window_handle = NULL;
    ao46_mesa_clear_pbuffer_binding(ctx);

    err = ao46_mesa_attach_existing_texture(ctx,
                                            drawable,
                                            color,
                                            resolve,
                                            drawable->width,
                                            drawable->height,
                                            drawable->rowbytes,
                                            baseaddr);
    pipe_resource_reference(&color, NULL);
    pipe_resource_reference(&resolve, NULL);
    if (err != kCGLNoError) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        return err;
    }

    err = ao46_mesa_upload_offscreen(ctx, ctx->tex, baseaddr, width, height, rowbytes);
    if (err != kCGLNoError) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        return err;
    }

    ao46_mesa_mark_drawable_dirty(ctx);
    if (AO46MesaGetCurrent() == ctx) {
        return ao46_mesa_bind_current_drawable(ctx);
    }
    return kCGLNoError;
}

CGLError
AO46MesaAttachPBuffer(AO46ContextRef ctx,
                      AO46PBufferRef pbuffer,
                      GLenum face,
                      GLint level,
                      GLint screen)
{
    struct st_visual visual;
    struct AO46MesaDrawable *drawable;
    struct pipe_resource *color = NULL;
    unsigned layer = 0;
    unsigned mip_width;
    unsigned mip_height;
    GLint double_buffer = 0;
    CGLError err;

    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }
    if (!pbuffer) {
        return kCGLBadValue;
    }
    if (level < 0 || level > pbuffer->max_level) {
        return kCGLBadValue;
    }
    if (!ao46_mesa_face_to_layer(pbuffer->target, face, &layer)) {
        return kCGLBadValue;
    }

    AO46DescribePixelFormat(ctx->pixel_format, 0, kCGLPFADoubleBuffer, &double_buffer);
    ao46_mesa_fill_visual(ctx->pixel_format, &visual);
    visual.color_format = pbuffer->tex->format;
    visual.buffer_mask &= ~ST_ATTACHMENT_BACK_LEFT_MASK;
    double_buffer = 0;

    if (ctx->drawable) {
        ao46_mesa_prepare_drawable_release(ctx);
        ao46_mesa_destroy_drawable(ctx->drawable);
        ctx->drawable = NULL;
    }

    drawable = ao46_mesa_create_drawable(&visual, false, false);
    if (!drawable) {
        return kCGLBadAlloc;
    }

    drawable->base.validate = ao46_mesa_validate_drawable;
    ctx->drawable = drawable;
    ctx->drawable_kind = AO46DrawableKindHeadless;
    ctx->offscreen = true;
    ctx->offscreen_baseaddr = NULL;
    mip_width = ao46_mesa_mip_size((unsigned)pbuffer->width, (unsigned)level);
    mip_height = ao46_mesa_mip_size((unsigned)pbuffer->height, (unsigned)level);
    ctx->offscreen_width = (GLsizei)mip_width;
    ctx->offscreen_height = (GLsizei)mip_height;
    ctx->offscreen_rowbytes = (GLint)(mip_width * 4u);
    ctx->pbuffer_face = face;
    ctx->pbuffer_level = level;
    ctx->pbuffer_screen = screen;
    ctx->window_handle = NULL;

    ao46_mesa_clear_pbuffer_binding(ctx);
    ctx->pbuffer = AO46RetainPBuffer(pbuffer);

    color = ao46_mesa_create_texture_resource(drawable->screen,
                                              PIPE_TEXTURE_2D,
                                              pbuffer->tex->format,
                                              mip_width,
                                              mip_height,
                                              1,
                                              1,
                                              0,
                                              pbuffer->tex->nr_samples,
                                              pbuffer->tex->nr_storage_samples,
                                              PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW);
    if (!color) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        ao46_mesa_clear_pbuffer_binding(ctx);
        return kCGLBadAlloc;
    }

    err = ao46_mesa_attach_existing_texture(ctx,
                                            drawable,
                                            color,
                                            NULL,
                                            mip_width,
                                            mip_height,
                                            mip_width * 4u,
                                            NULL);
    pipe_resource_reference(&color, NULL);
    if (err != kCGLNoError) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        ao46_mesa_clear_pbuffer_binding(ctx);
        return err;
    }

    pipe_resource_reference(&drawable->pbuffer_storage, pbuffer->tex);
    drawable->pbuffer_level = (unsigned)level;
    drawable->pbuffer_layer = layer;
    drawable->pbuffer_backed = true;

    if (!ao46_mesa_sync_pbuffer_storage(ctx, false)) {
        ao46_mesa_destroy_drawable(drawable);
        ctx->drawable = NULL;
        ao46_mesa_clear_pbuffer_binding(ctx);
        return kCGLBadDrawable;
    }

    ao46_mesa_mark_drawable_dirty(ctx);
    if (AO46MesaGetCurrent() == ctx) {
        return ao46_mesa_bind_current_drawable(ctx);
    }
    return kCGLNoError;
}

CGLError
AO46MesaDetachDrawable(AO46ContextRef ctx)
{
    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }

    if (ctx->drawable) {
        ao46_mesa_prepare_drawable_release(ctx);
        ao46_mesa_destroy_drawable(ctx->drawable);
        ctx->drawable = NULL;
    }

    pipe_resource_reference(&ctx->tex, NULL);
    ctx->drawable_kind = AO46DrawableKindNone;
    ctx->window_handle = NULL;
    ctx->offscreen = false;
    ao46_mesa_clear_pbuffer_binding(ctx);

    if (AO46MesaGetCurrent() == ctx) {
        return ao46_mesa_bind_current_drawable(ctx);
    }
    return kCGLNoError;
}

CGLError
AO46MesaUpdateDrawable(AO46ContextRef ctx)
{
    if (!ctx || !ctx->st) {
        return kCGLBadContext;
    }
    if (!ctx->drawable) {
        return kCGLNoError;
    }

    if (ctx->drawable_kind == AO46DrawableKindWindow) {
        CGLError err = ao46_mesa_build_window_target(ctx, ctx->drawable);
        if (err != kCGLNoError) {
            return err;
        }
        ao46_mesa_mark_drawable_dirty(ctx);
        if (AO46MesaGetCurrent() == ctx) {
            return ao46_mesa_bind_current_drawable(ctx);
        }
    }

    return kCGLNoError;
}

CGLError
AO46MesaSwapBuffers(AO46ContextRef ctx)
{
    if (!ctx || !ctx->st || !ctx->drawable) {
        return kCGLBadContext;
    }

    st_context_flush(ctx->st, ST_FLUSH_END_OF_FRAME, NULL, NULL, NULL);
    return ao46_mesa_flush_swapbuffers(ctx->st, &ctx->drawable->base) ? kCGLNoError
                                                                       : kCGLBadDrawable;
}

CGLError
AO46MesaImportPBufferToBoundTexture(AO46ContextRef ctx,
                                    AO46PBufferRef pbuffer,
                                    GLenum source)
{
    AO46ContextRef previous_ctx;
    PFNGLGETINTEGERVPROC get_integerv;
    PFNGLGETTEXLEVELPARAMETERIVPROC get_tex_level_parameteriv;
    PFNGLGETTEXPARAMETERIVPROC get_tex_parameteriv;
    PFNGLTEXIMAGE2DPROC tex_image_2d;
    PFNGLTEXSUBIMAGE2DPROC tex_sub_image_2d;
    GLenum binding;
    GLenum image_target;
    GLenum face;
    unsigned level = 0;
    unsigned layer = 0;
    unsigned width;
    unsigned height;
    unsigned rowbytes;
    unsigned char *pixels = NULL;
    GLint bound_texture = 0;
    GLint immutable_format = 0;
    GLint existing_width = 0;
    GLint existing_height = 0;
    CGLError err = kCGLNoError;
    bool switched = false;

    if (!ctx || !ctx->st || !ctx->pipe) {
        return kCGLBadContext;
    }
    if (!pbuffer || !pbuffer->tex) {
        return kCGLBadValue;
    }
    if (!ao46_mesa_supported_pbuffer_source(source)) {
        return kCGLBadValue;
    }

    get_integerv = (PFNGLGETINTEGERVPROC)_mesa_glapi_get_proc_address("glGetIntegerv");
    get_tex_level_parameteriv =
        (PFNGLGETTEXLEVELPARAMETERIVPROC)_mesa_glapi_get_proc_address("glGetTexLevelParameteriv");
    get_tex_parameteriv =
        (PFNGLGETTEXPARAMETERIVPROC)_mesa_glapi_get_proc_address("glGetTexParameteriv");
    tex_image_2d = (PFNGLTEXIMAGE2DPROC)_mesa_glapi_get_proc_address("glTexImage2D");
    tex_sub_image_2d = (PFNGLTEXSUBIMAGE2DPROC)_mesa_glapi_get_proc_address("glTexSubImage2D");
    if (!get_integerv || !get_tex_level_parameteriv || !get_tex_parameteriv ||
        !tex_image_2d || !tex_sub_image_2d) {
        return kCGLBadContext;
    }

    previous_ctx = AO46MesaGetCurrent();
    if (previous_ctx != ctx) {
        err = AO46MesaMakeCurrent(ctx);
        if (err != kCGLNoError) {
            return err;
        }
        switched = true;
    }

    if (ctx->pbuffer == pbuffer) {
        level = (unsigned)MAX2(ctx->pbuffer_level, 0);
        face = ctx->pbuffer_face;
        if (!ao46_mesa_face_to_layer(pbuffer->target, face, &layer)) {
            err = kCGLBadValue;
            goto out;
        }
        if (ctx->drawable && ao46_mesa_drawable(&ctx->drawable->base)->pbuffer_backed) {
            st_context_flush(ctx->st, ST_FLUSH_END_OF_FRAME, NULL, NULL, NULL);
            if (!ao46_mesa_sync_pbuffer_storage(ctx, true)) {
                err = kCGLBadDrawable;
                goto out;
            }
        }
    } else {
        face = pbuffer->target == GL_TEXTURE_CUBE_MAP ? GL_TEXTURE_CUBE_MAP_POSITIVE_X : pbuffer->target;
    }

    binding = ao46_mesa_texture_binding(pbuffer->target);
    image_target = ao46_mesa_texture_image_target(pbuffer->target, face);
    if (!binding || !image_target) {
        err = kCGLBadValue;
        goto out;
    }

    width = ao46_mesa_mip_size((unsigned)pbuffer->width, level);
    height = ao46_mesa_mip_size((unsigned)pbuffer->height, level);
    rowbytes = width * 4u;

    get_integerv(binding, &bound_texture);
    if (bound_texture == 0) {
        err = kCGLNoError;
        goto out;
    }

    pixels = calloc(height, rowbytes);
    if (!pixels) {
        err = kCGLBadAlloc;
        goto out;
    }

    if (!ao46_mesa_download_texture_image(ctx->pipe,
                                          pbuffer->tex,
                                          level,
                                          layer,
                                          width,
                                          height,
                                          rowbytes,
                                          pixels)) {
        err = kCGLBadDrawable;
        goto out;
    }

    get_tex_parameteriv(pbuffer->target, GL_TEXTURE_IMMUTABLE_FORMAT, &immutable_format);
    if (immutable_format) {
        get_tex_level_parameteriv(image_target, 0, GL_TEXTURE_WIDTH, &existing_width);
        get_tex_level_parameteriv(image_target, 0, GL_TEXTURE_HEIGHT, &existing_height);
        if ((unsigned)existing_width != width || (unsigned)existing_height != height) {
            err = kCGLBadValue;
            goto out;
        }
        tex_sub_image_2d(image_target,
                         0,
                         0,
                         0,
                         (GLsizei)width,
                         (GLsizei)height,
                         GL_BGRA,
                         GL_UNSIGNED_BYTE,
                         pixels);
    } else {
        tex_image_2d(image_target,
                     0,
                     (GLint)(pbuffer->internal_format ? pbuffer->internal_format : GL_RGBA8),
                     (GLsizei)width,
                     (GLsizei)height,
                     0,
                     GL_BGRA,
                     GL_UNSIGNED_BYTE,
                     pixels);
    }

out:
    free(pixels);
    if (switched) {
        (void)AO46MesaMakeCurrent(previous_ctx);
    }
    return err;
}

CGLError
AO46MesaDescribePixelFormat(AO46PixelFormatRef pix,
                            GLint pix_num,
                            CGLPixelFormatAttribute attrib,
                            GLint *value)
{
    if (!pix || !value) {
        return kCGLBadAddress;
    }
    if (pix_num != 0) {
        return kCGLBadValue;
    }

    switch (attrib) {
        case kCGLPFAAccelerated:
            *value = 1;
            return kCGLNoError;
        case kCGLPFAWindow:
        case kCGLPFAOffScreen:
        case kCGLPFAPBuffer:
            *value = 1;
            return kCGLNoError;
        case kCGLPFAClosestPolicy:
        case kCGLPFABackingStore:
            *value = 0;
            return kCGLNoError;
        default:
            return kCGLBadAttribute;
    }
}

CGLError
AO46MesaCreatePBuffer(GLsizei width,
                      GLsizei height,
                      GLenum target,
                      GLenum internal_format,
                      GLint max_level,
                      AO46PBufferRef *out_pbuffer)
{
    enum pipe_texture_target pipe_target;
    enum pipe_format pipe_format;
    unsigned array_size;
    struct AO46PBufferRec *pbuffer;
    CGLError err;

    if (!out_pbuffer) {
        return kCGLBadAddress;
    }
    if (width <= 0 || height <= 0) {
        return kCGLBadValue;
    }
    if (max_level < 0) {
        return kCGLBadValue;
    }
    if (!ao46_mesa_target_to_pipe(target, max_level, &pipe_target, &array_size)) {
        return kCGLBadValue;
    }
    if (!ao46_mesa_internal_format_to_pipe(internal_format, &pipe_format)) {
        return kCGLBadValue;
    }
    if (pipe_target == PIPE_TEXTURE_CUBE && width != height) {
        return kCGLBadValue;
    }

    err = AO46MesaInit();
    if (err != kCGLNoError) {
        return err;
    }

    pbuffer = calloc(1, sizeof(*pbuffer));
    if (!pbuffer) {
        return kCGLBadAlloc;
    }

    pbuffer->tex = ao46_mesa_create_texture_resource(g_gl_screen,
                                                     pipe_target,
                                                     pipe_format,
                                                     (unsigned)width,
                                                     (unsigned)height,
                                                     1,
                                                     array_size,
                                                     (unsigned)max_level,
                                                     0,
                                                     0,
                                                     PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW);
    if (!pbuffer->tex) {
        free(pbuffer);
        return kCGLBadAlloc;
    }

    pbuffer->retain_count = 1;
    pbuffer->width = width;
    pbuffer->height = height;
    pbuffer->target = target;
    pbuffer->internal_format = internal_format;
    pbuffer->max_level = max_level;

    *out_pbuffer = pbuffer;
    return kCGLNoError;
}

void
AO46MesaDestroyPBuffer(AO46PBufferRef pbuffer)
{
    if (!pbuffer) {
        return;
    }

    if (pbuffer->retain_count > 1) {
        pbuffer->retain_count--;
        return;
    }

    pipe_resource_reference(&pbuffer->tex, NULL);
    free(pbuffer);
}

CGLError
AO46MesaDescribePBuffer(AO46PBufferRef pbuffer,
                        GLsizei *width,
                        GLsizei *height,
                        GLenum *target,
                        GLenum *internal_format,
                        GLint *mipmap)
{
    if (!pbuffer) {
        return kCGLBadValue;
    }

    if (width) {
        *width = pbuffer->width;
    }
    if (height) {
        *height = pbuffer->height;
    }
    if (target) {
        *target = pbuffer->target;
    }
    if (internal_format) {
        *internal_format = pbuffer->internal_format;
    }
    if (mipmap) {
        *mipmap = pbuffer->max_level;
    }
    return kCGLNoError;
}

void *
AO46MesaGetProcAddress(const char *procname)
{
    return procname ? _mesa_glapi_get_proc_address(procname) : NULL;
}
