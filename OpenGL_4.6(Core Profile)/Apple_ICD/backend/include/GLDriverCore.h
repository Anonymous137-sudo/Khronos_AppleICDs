#ifndef GL_DRIVER_CORE_H
#define GL_DRIVER_CORE_H

#include "glcorearb.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    GL_DRIVER_MAX_COLOR_ATTACHMENTS = 8,
    GL_DRIVER_MAX_VERTEX_ATTRIBS = 16,
    GL_DRIVER_MAX_TEXTURE_UNITS = 16
};

typedef struct {
    GLenum format;
    GLenum type;
} GLDriverPixelFormat;

typedef struct {
    GLboolean blend;
    GLboolean multisample;
    GLboolean sample_alpha_to_coverage;
    GLboolean sample_alpha_to_one;
    GLboolean sample_coverage;
    GLboolean rasterizer_discard;
    GLboolean framebuffer_srgb;
    GLboolean depth_clamp;
    GLboolean texture_cube_map_seamless;
    GLboolean sample_mask;
    GLboolean sample_shading;
    GLboolean debug_output_synchronous;
    GLboolean debug_output;
    GLboolean line_smooth;
    GLboolean polygon_smooth;
    GLboolean cull_face;
    GLboolean depth_test;
    GLboolean stencil_test;
    GLboolean dither;
    GLboolean scissor_test;
    GLboolean color_logic_op;
    GLboolean polygon_offset_point;
    GLboolean polygon_offset_line;
    GLboolean polygon_offset_fill;
    GLboolean index_logic_op;
    GLboolean primitive_restart;
    GLboolean primitive_restart_fixed_index;
} GLDriverCapabilities;

typedef struct {
    GLenum line_smooth_hint;
    GLenum polygon_smooth_hint;
    GLenum texture_compression_hint;
    GLenum fragment_shader_derivative_hint;
} GLDriverHints;

typedef struct {
    GLenum error_code;
    GLenum draw_buffer;
    GLenum read_buffer;
    GLint max_color_attachments;
    GLint max_vertex_attribs;
    GLint max_samples;
    GLint max_texture_size;
    GLint viewport[4];
    GLint scissor_box[4];
    GLfloat clear_color[4];
    GLdouble clear_depth;
    GLint clear_stencil;
    GLboolean color_mask[4];
    GLboolean depth_mask;
    GLfloat line_width;
    GLfloat point_size;
    GLenum polygon_mode;
    GLenum cull_face_mode;
    GLenum front_face;
    GLdouble depth_range[2];
    GLenum depth_func;
    GLboolean scissor_test;
    GLDriverCapabilities capabilities;
    GLDriverHints hints;
} GLDriverState;

typedef struct {
    void *object;
    void *view;
} GLDriverMetalBinding;

typedef struct {
    GLuint context_flags;
    GLDriverPixelFormat color_format;
    GLDriverPixelFormat depth_format;
    GLDriverPixelFormat stencil_format;
    GLDriverMetalBinding metal;
    GLDriverState state;
} GLDriverContext;

void GLDriverInitializeContext(GLDriverContext *ctx,
                               GLenum color_format,
                               GLenum color_type,
                               GLenum depth_format,
                               GLenum depth_type,
                               GLenum stencil_format,
                               GLenum stencil_type);

const char *GLDriverCoreIdentity(void);

#ifdef __cplusplus
}
#endif

#endif
