#include "GLDriverCore.h"

#include <string.h>

static void gl_driver_initialize_capabilities(GLDriverCapabilities *caps)
{
    memset(caps, 0, sizeof(*caps));
    caps->multisample = GL_TRUE;
    caps->dither = GL_TRUE;
}

static void gl_driver_initialize_hints(GLDriverHints *hints)
{
    hints->line_smooth_hint = GL_DONT_CARE;
    hints->polygon_smooth_hint = GL_DONT_CARE;
    hints->texture_compression_hint = GL_DONT_CARE;
    hints->fragment_shader_derivative_hint = GL_DONT_CARE;
}

void GLDriverInitializeContext(GLDriverContext *ctx,
                               GLenum color_format,
                               GLenum color_type,
                               GLenum depth_format,
                               GLenum depth_type,
                               GLenum stencil_format,
                               GLenum stencil_type)
{
    if (!ctx) {
        return;
    }

    memset(ctx, 0, sizeof(*ctx));

    if (color_format == 0 && color_type == 0) {
        color_format = GL_BGRA;
        color_type = GL_UNSIGNED_INT_8_8_8_8_REV;
    }

    ctx->color_format.format = color_format;
    ctx->color_format.type = color_type;
    ctx->depth_format.format = depth_format;
    ctx->depth_format.type = depth_type;
    ctx->stencil_format.format = stencil_format;
    ctx->stencil_format.type = stencil_type;
    ctx->context_flags = 0;

    ctx->state.error_code = GL_NO_ERROR;
    ctx->state.draw_buffer = GL_BACK;
    ctx->state.read_buffer = GL_BACK;
    ctx->state.max_color_attachments = GL_DRIVER_MAX_COLOR_ATTACHMENTS;
    ctx->state.max_vertex_attribs = GL_DRIVER_MAX_VERTEX_ATTRIBS;
    ctx->state.max_samples = 4;
    ctx->state.max_texture_size = 16384;
    ctx->state.clear_color[3] = 1.0f;
    ctx->state.clear_depth = 1.0;
    ctx->state.color_mask[0] = GL_TRUE;
    ctx->state.color_mask[1] = GL_TRUE;
    ctx->state.color_mask[2] = GL_TRUE;
    ctx->state.color_mask[3] = GL_TRUE;
    ctx->state.depth_mask = GL_TRUE;
    ctx->state.line_width = 1.0f;
    ctx->state.point_size = 1.0f;
    ctx->state.polygon_mode = GL_FILL;
    ctx->state.cull_face_mode = GL_BACK;
    ctx->state.front_face = GL_CCW;
    ctx->state.depth_range[0] = 0.0;
    ctx->state.depth_range[1] = 1.0;
    ctx->state.depth_func = GL_LESS;

    gl_driver_initialize_capabilities(&ctx->state.capabilities);
    gl_driver_initialize_hints(&ctx->state.hints);
}

const char *GLDriverCoreIdentity(void)
{
    return "GLDriverCore";
}
