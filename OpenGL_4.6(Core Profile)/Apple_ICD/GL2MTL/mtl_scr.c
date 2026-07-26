#include "pipe/p_screen.h"
#include "pipe/p_context.h"
#include "pipe/p_state.h"
#include "util/u_inlines.h"
#include "util/u_format.h"
#include "util/u_memory.h"
#include "util/u_math.h"
#include "util/u_debug.h"
#include "mtl_pub.h"

#include <stdlib.h>
#include <string.h>

/* Forward declarations */
static const struct pipe_screen *ao46_metal_screen;
static struct pipe_context *ao46_metal_context_create(struct pipe_screen *screen, void *priv);

/* ----------------------------------------------------------------------
 * Screen functions
 * ---------------------------------------------------------------------- */
static const char *ao46_metal_screen_get_name(struct pipe_screen *screen)
{
    return "AO46 Metal Gallium";
}

static const char *ao46_metal_screen_get_vendor(struct pipe_screen *screen)
{
    return "Khronos_AppleICDs";
}

static int ao46_metal_screen_get_param(struct pipe_screen *screen, enum pipe_cap param)
{
    switch (param) {
        case PIPE_CAP_GLSL_OPTIMIZE_CONSERVATIVELY: return 1;
        case PIPE_CAP_MAX_GL_VERSION: return 46; /* 4.6 */
        case PIPE_CAP_GL_EXTENSIONS: return 1;
        case PIPE_CAP_GL_EXTENSION_STRING: return 1;
        case PIPE_CAP_TEXTURE_2D_ARRAY: return 1;
        case PIPE_CAP_TEXTURE_CUBE_MAP_ARRAY: return 1;
        case PIPE_CAP_TEXTURE_3D: return 1;
        case PIPE_CAP_MAX_TEXTURE_2D_LEVELS: return 16;
        case PIPE_CAP_MAX_TEXTURE_3D_LEVELS: return 16;
        case PIPE_CAP_MAX_TEXTURE_CUBE_LEVELS: return 16;
        case PIPE_CAP_MAX_TEXTURE_ARRAY_LAYERS: return 256;
        case PIPE_CAP_MAX_STREAM_OUTPUT_BUFFERS: return 4;
        case PIPE_CAP_MAX_STREAM_OUTPUT_SEPARATE_COMPONENTS: return 4;
        case PIPE_CAP_MAX_STREAM_OUTPUT_INTERLEAVED_COMPONENTS: return 128;
        case PIPE_CAP_MAX_GS_INVOCATIONS: return 32;
        case PIPE_CAP_MAX_VARYINGS: return 32;
        case PIPE_CAP_MAX_VIEWPORTS: return 16;
        case PIPE_CAP_MAX_GEOMETRY_OUTPUT_VERTICES: return 1024;
        case PIPE_CAP_MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS: return 4096;
        case PIPE_CAP_MAX_TESS_PATCH_SIZE: return 32;
        case PIPE_CAP_MAX_TESS_OUTPUT_COMPONENTS: return 128;
        case PIPE_CAP_MAX_TESS_CONTROL_OUTPUT_COMPONENTS: return 128;
        case PIPE_CAP_MAX_TESS_EVAL_OUTPUT_COMPONENTS: return 128;
        case PIPE_CAP_MAX_TESS_CONTROL_TOTAL_OUTPUT_COMPONENTS: return 4096;
        case PIPE_CAP_MAX_SHADER_BUFFER_SIZE: return 1024*1024;
        case PIPE_CAP_MAX_COMPUTE_SHADER_BUFFERS: return 8;
        case PIPE_CAP_MAX_COMPUTE_IMAGES: return 8;
        case PIPE_CAP_MAX_COMPUTE_SHARED_MEMORY_SIZE: return 32768;
        case PIPE_CAP_MAX_COMPUTE_GRID_SIZE: return 1024;
        case PIPE_CAP_MAX_COMPUTE_BLOCK_SIZE: return 1024;
        default: return 0;
    }
}

static int ao46_metal_screen_get_shader_param(struct pipe_screen *screen,
                                              enum pipe_shader_type shader,
                                              enum pipe_shader_cap param)
{
    /* Return reasonable defaults for OpenGL 4.6 */
    switch (param) {
        case PIPE_SHADER_CAP_MAX_CONST_BUFFER_SIZE: return 64*1024;
        case PIPE_SHADER_CAP_MAX_CONST_BUFFERS: return 16;
        case PIPE_SHADER_CAP_MAX_TEMPS: return 256;
        case PIPE_SHADER_CAP_MAX_INDIRECT_ADDRESSES: return 1;
        case PIPE_SHADER_CAP_MAX_TEXTURE_SAMPLERS: return 16;
        case PIPE_SHADER_CAP_MAX_SAMPLER_VIEWS: return 16;
        case PIPE_SHADER_CAP_PREFERRED_IR: return PIPE_SHADER_IR_NIR;
        default: return 0;
    }
}

static struct pipe_context *ao46_metal_screen_context_create(struct pipe_screen *screen,
                                                             void *priv,
                                                             unsigned flags)
{
    return ao46_metal_context_create(screen, priv);
}

static void ao46_metal_screen_destroy(struct pipe_screen *screen)
{
    free(screen);
}

/* Resource creation – stub */
static struct pipe_resource *ao46_metal_screen_resource_create(struct pipe_screen *screen,
                                                               const struct pipe_resource *templ)
{
    /* Allocate a dummy resource */
    struct pipe_resource *res = calloc(1, sizeof(struct pipe_resource));
    if (!res) return NULL;
    *res = *templ;
    res->screen = screen;
    return res;
}

static struct pipe_surface *ao46_metal_screen_create_surface(struct pipe_screen *screen,
                                                             struct pipe_resource *res,
                                                             const struct pipe_surface *templ)
{
    struct pipe_surface *surf = calloc(1, sizeof(struct pipe_surface));
    if (!surf) return NULL;
    surf->texture = res;
    surf->format = res->format;
    surf->width = res->width0;
    surf->height = res->height0;
    return surf;
}

static void ao46_metal_screen_destroy_surface(struct pipe_screen *screen,
                                              struct pipe_surface *surf)
{
    free(surf);
}

static void ao46_metal_screen_resource_destroy(struct pipe_screen *screen,
                                               struct pipe_resource *res)
{
    free(res);
}

/* Mapping stubs */
static void *ao46_metal_screen_resource_map(struct pipe_screen *screen,
                                            struct pipe_resource *res,
                                            unsigned level,
                                            unsigned usage,
                                            struct pipe_transfer **transfer)
{
    *transfer = calloc(1, sizeof(struct pipe_transfer));
    if (!*transfer) return NULL;
    /* Allocate a fake buffer */
    size_t size = res->width0 * res->height0 * 4;
    void *data = calloc(1, size);
    if (!data) { free(*transfer); return NULL; }
    (*transfer)->data = data;
    return data;
}

static void ao46_metal_screen_resource_unmap(struct pipe_screen *screen,
                                             struct pipe_transfer *transfer)
{
    free(transfer->data);
    free(transfer);
}

/* Initialise the screen */
struct pipe_screen *ao46_metal_screen_create(void)
{
    struct pipe_screen *screen = calloc(1, sizeof(struct pipe_screen));
    if (!screen) return NULL;

    screen->get_name = ao46_metal_screen_get_name;
    screen->get_vendor = ao46_metal_screen_get_vendor;
    screen->get_param = ao46_metal_screen_get_param;
    screen->get_shader_param = ao46_metal_screen_get_shader_param;
    screen->context_create = ao46_metal_screen_context_create;
    screen->destroy = ao46_metal_screen_destroy;
    screen->resource_create = ao46_metal_screen_resource_create;
    screen->resource_destroy = ao46_metal_screen_resource_destroy;
    screen->resource_create_surface = ao46_metal_screen_create_surface;
    screen->surface_destroy = ao46_metal_screen_destroy_surface;
    screen->resource_map = ao46_metal_screen_resource_map;
    screen->resource_unmap = ao46_metal_screen_resource_unmap;

    return screen;
}