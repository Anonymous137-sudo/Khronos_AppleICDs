#include "AppleOpenGL46Backend.h"
#include "GLDriverCore.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct GLBackendShaderRec GLBackendShader;
typedef struct GLBackendProgramRec GLBackendProgram;
typedef struct GLBackendBufferRec GLBackendBuffer;
typedef struct GLBackendVertexArrayRec GLBackendVertexArray;
typedef struct GLBackendTextureRec GLBackendTexture;

typedef struct {
    GLboolean enabled;
    GLint size;
    GLenum type;
    GLboolean normalized;
    GLsizei stride;
    uintptr_t offset;
    GLuint buffer_name;
} GLBackendVertexAttrib;

struct GLBackendShaderRec {
    GLuint name;
    GLenum type;
    char *source;
    GLsizei source_length;
    GLboolean compiled;
    GLboolean delete_pending;
    GLsizei attach_count;
    char info_log[256];
    GLBackendShader *next;
};

struct GLBackendProgramRec {
    GLuint name;
    GLuint vertex_shader_name;
    GLuint fragment_shader_name;
    GLboolean linked;
    GLboolean delete_pending;
    GLboolean validated;
    GLboolean uses_texture_2d;
    GLint active_attribute_count;
    GLint active_uniform_count;
    GLint sampler_binding_unit;
    GLint bound_attribute_location[GL_DRIVER_MAX_VERTEX_ATTRIBS];
    char bound_attribute_name[GL_DRIVER_MAX_VERTEX_ATTRIBS][64];
    char sampler_name[64];
    char info_log[256];
    GLBackendProgram *next;
};

struct GLBackendBufferRec {
    GLuint name;
    GLenum usage;
    size_t size;
    uint8_t *data;
    GLBackendBuffer *next;
};

struct GLBackendVertexArrayRec {
    GLuint name;
    GLBackendVertexAttrib attribs[GL_DRIVER_MAX_VERTEX_ATTRIBS];
    GLuint element_array_buffer_name;
    GLBackendVertexArray *next;
};

typedef struct {
    GLuint texture_2d_name;
} GLBackendTextureUnit;

struct GLBackendTextureRec {
    GLuint name;
    GLenum target;
    GLboolean defined;
    GLsizei width;
    GLsizei height;
    GLint internal_format;
    GLint min_filter;
    GLint mag_filter;
    GLint wrap_s;
    GLint wrap_t;
    uint8_t *data;
    GLBackendTexture *next;
};

struct AO46BackendContextRec {
    GLDriverContext core;
    void *renderer_handle;
    void *window_handle;
    uint8_t *drawable_storage;
    GLsizei drawable_width;
    GLsizei drawable_height;
    GLint drawable_rowbytes;
    bool headless;
    GLuint next_shader_name;
    GLuint next_program_name;
    GLuint next_buffer_name;
    GLuint next_vertex_array_name;
    GLuint next_texture_name;
    GLuint array_buffer_binding;
    GLuint current_program_name;
    GLuint current_vertex_array_name;
    GLuint active_texture_unit_index;
    GLBackendShader *shaders;
    GLBackendProgram *programs;
    GLBackendBuffer *buffers;
    GLBackendVertexArray *vertex_arrays;
    GLBackendTextureUnit texture_units[GL_DRIVER_MAX_TEXTURE_UNITS];
    GLBackendTexture *textures;
};

typedef struct {
    GLfloat position[4];
    GLfloat color[4];
    GLfloat texcoord[2];
} GLBackendVertex;

static _Thread_local AO46BackendContextRef g_backend_current_context;

static const GLubyte kGLVendorString[] = "OpenGL_4.6 Project";
static const GLubyte kGLRendererString[] = "OpenGL 4.6 Core Profile Driver";
static const GLubyte kGLVersionString[] = "4.6 OpenGL_4.6";
static const GLubyte kGLSLVersionString[] = "4.60";

static AO46BackendContextRef gl_backend_current_context(void)
{
    return g_backend_current_context;
}

static GLfloat gl_backend_clampf(GLfloat value)
{
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

static GLdouble gl_backend_clampd(GLdouble value)
{
    if (value < 0.0) {
        return 0.0;
    }
    if (value > 1.0) {
        return 1.0;
    }
    return value;
}

static uint8_t gl_backend_to_unorm8(GLfloat value)
{
    return (uint8_t)(gl_backend_clampf(value) * 255.0f + 0.5f);
}

static void gl_backend_set_error(AO46BackendContextRef ctx, GLenum error_code)
{
    if (!ctx || error_code == GL_NO_ERROR) {
        return;
    }

    if (ctx->core.state.error_code == GL_NO_ERROR) {
        ctx->core.state.error_code = error_code;
    }
}

static bool gl_backend_has_drawable_storage(AO46BackendContextRef ctx)
{
    return ctx &&
           ctx->drawable_storage &&
           ctx->drawable_width > 0 &&
           ctx->drawable_height > 0 &&
           ctx->drawable_rowbytes >= (GLint)(ctx->drawable_width * 4);
}

static void gl_backend_store_bgra8(uint8_t *dst,
                                   uint8_t red,
                                   uint8_t green,
                                   uint8_t blue,
                                   uint8_t alpha,
                                   const GLboolean color_mask[4])
{
    if (color_mask[2]) {
        dst[0] = blue;
    }
    if (color_mask[1]) {
        dst[1] = green;
    }
    if (color_mask[0]) {
        dst[2] = red;
    }
    if (color_mask[3]) {
        dst[3] = alpha;
    }
}

static void gl_backend_write_pixel(AO46BackendContextRef ctx,
                                   GLint x,
                                   GLint y,
                                   GLfloat red,
                                   GLfloat green,
                                   GLfloat blue,
                                   GLfloat alpha)
{
    uint8_t *pixel;

    if (!gl_backend_has_drawable_storage(ctx)) {
        return;
    }

    if (x < 0 || y < 0 || x >= ctx->drawable_width || y >= ctx->drawable_height) {
        return;
    }

    pixel = ctx->drawable_storage + (size_t)y * (size_t)ctx->drawable_rowbytes + (size_t)x * 4u;
    gl_backend_store_bgra8(pixel,
                           gl_backend_to_unorm8(red),
                           gl_backend_to_unorm8(green),
                           gl_backend_to_unorm8(blue),
                           gl_backend_to_unorm8(alpha),
                           ctx->core.state.color_mask);
}

static void gl_backend_clear_color_buffer(AO46BackendContextRef ctx)
{
    GLint x0 = 0;
    GLint y0 = 0;
    GLint x1 = ctx->drawable_width;
    GLint y1 = ctx->drawable_height;
    uint8_t red = gl_backend_to_unorm8(ctx->core.state.clear_color[0]);
    uint8_t green = gl_backend_to_unorm8(ctx->core.state.clear_color[1]);
    uint8_t blue = gl_backend_to_unorm8(ctx->core.state.clear_color[2]);
    uint8_t alpha = gl_backend_to_unorm8(ctx->core.state.clear_color[3]);

    if (!gl_backend_has_drawable_storage(ctx)) {
        return;
    }

    if (ctx->core.state.scissor_test) {
        x0 = ctx->core.state.scissor_box[0] < 0 ? 0 : ctx->core.state.scissor_box[0];
        y0 = ctx->core.state.scissor_box[1] < 0 ? 0 : ctx->core.state.scissor_box[1];
        x1 = ctx->core.state.scissor_box[0] + ctx->core.state.scissor_box[2];
        y1 = ctx->core.state.scissor_box[1] + ctx->core.state.scissor_box[3];
        if (x1 > ctx->drawable_width) {
            x1 = ctx->drawable_width;
        }
        if (y1 > ctx->drawable_height) {
            y1 = ctx->drawable_height;
        }
    }

    if (x0 >= x1 || y0 >= y1) {
        return;
    }

    for (GLint y = y0; y < y1; ++y) {
        uint8_t *row = ctx->drawable_storage + (size_t)y * (size_t)ctx->drawable_rowbytes;

        for (GLint x = x0; x < x1; ++x) {
            uint8_t *pixel = row + (size_t)x * 4u;
            gl_backend_store_bgra8(pixel, red, green, blue, alpha, ctx->core.state.color_mask);
        }
    }
}

static void gl_backend_read_bgra8_pixel(const uint8_t *src, GLenum format, uint8_t *dst)
{
    if (format == GL_BGRA) {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
        return;
    }

    dst[0] = src[2];
    dst[1] = src[1];
    dst[2] = src[0];
    dst[3] = src[3];
}

static bool gl_backend_valid_pixel_alignment(GLint alignment)
{
    return alignment == 1 || alignment == 2 || alignment == 4 || alignment == 8;
}

static size_t gl_backend_aligned_row_stride(GLsizei width, size_t bytes_per_pixel, GLint alignment)
{
    size_t row_bytes = (size_t)width * bytes_per_pixel;
    size_t align = alignment > 0 ? (size_t)alignment : 1u;
    size_t remainder = row_bytes % align;

    return remainder == 0 ? row_bytes : row_bytes + align - remainder;
}

static GLuint gl_backend_next_name(GLuint *slot)
{
    (*slot)++;
    if (*slot == 0) {
        (*slot)++;
    }
    return *slot;
}

static void gl_backend_set_log(char *dst, size_t dst_size, const char *message)
{
    if (!dst || dst_size == 0) {
        return;
    }

    if (!message) {
        dst[0] = '\0';
        return;
    }

    strncpy(dst, message, dst_size - 1);
    dst[dst_size - 1] = '\0';
}

static bool gl_backend_source_has_main(const char *source)
{
    return source && strstr(source, "void main") != NULL;
}

static GLBackendShader *gl_backend_find_shader(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendShader *shader = ctx ? ctx->shaders : NULL;

    while (shader) {
        if (shader->name == name) {
            return shader;
        }
        shader = shader->next;
    }

    return NULL;
}

static GLBackendProgram *gl_backend_find_program(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendProgram *program = ctx ? ctx->programs : NULL;

    while (program) {
        if (program->name == name) {
            return program;
        }
        program = program->next;
    }

    return NULL;
}

static GLBackendBuffer *gl_backend_find_buffer(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendBuffer *buffer = ctx ? ctx->buffers : NULL;

    while (buffer) {
        if (buffer->name == name) {
            return buffer;
        }
        buffer = buffer->next;
    }

    return NULL;
}

static GLBackendVertexArray *gl_backend_find_vertex_array(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendVertexArray *vertex_array = ctx ? ctx->vertex_arrays : NULL;

    while (vertex_array) {
        if (vertex_array->name == name) {
            return vertex_array;
        }
        vertex_array = vertex_array->next;
    }

    return NULL;
}

static GLBackendTexture *gl_backend_find_texture(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendTexture *texture = ctx ? ctx->textures : NULL;

    while (texture) {
        if (texture->name == name) {
            return texture;
        }
        texture = texture->next;
    }

    return NULL;
}

static void gl_backend_initialize_texture_state(GLBackendTexture *texture)
{
    if (!texture) {
        return;
    }

    texture->defined = GL_FALSE;
    texture->width = 0;
    texture->height = 0;
    texture->internal_format = GL_RGBA8;
    texture->min_filter = GL_NEAREST_MIPMAP_LINEAR;
    texture->mag_filter = GL_LINEAR;
    texture->wrap_s = GL_REPEAT;
    texture->wrap_t = GL_REPEAT;
}

static GLBackendTexture *gl_backend_create_texture_record(AO46BackendContextRef ctx, GLuint name)
{
    GLBackendTexture *texture;

    if (!ctx || name == 0) {
        return NULL;
    }

    texture = calloc(1, sizeof(*texture));
    if (!texture) {
        gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
        return NULL;
    }

    texture->name = name;
    gl_backend_initialize_texture_state(texture);
    texture->next = ctx->textures;
    ctx->textures = texture;
    if (name > ctx->next_texture_name) {
        ctx->next_texture_name = name;
    }
    return texture;
}

static GLuint *gl_backend_texture_binding_slot(AO46BackendContextRef ctx, GLenum target)
{
    if (!ctx || ctx->active_texture_unit_index >= GL_DRIVER_MAX_TEXTURE_UNITS) {
        return NULL;
    }

    switch (target) {
        case GL_TEXTURE_2D:
            return &ctx->texture_units[ctx->active_texture_unit_index].texture_2d_name;
        default:
            return NULL;
    }
}

static GLBackendTexture *gl_backend_bound_texture(AO46BackendContextRef ctx, GLenum target)
{
    GLuint *binding = gl_backend_texture_binding_slot(ctx, target);

    if (!binding || *binding == 0) {
        return NULL;
    }

    return gl_backend_find_texture(ctx, *binding);
}

static void gl_backend_remove_texture(AO46BackendContextRef ctx, GLBackendTexture *texture)
{
    GLBackendTexture **slot = ctx ? &ctx->textures : NULL;

    while (slot && *slot) {
        if (*slot == texture) {
            *slot = texture->next;
            free(texture->data);
            free(texture);
            return;
        }
        slot = &(*slot)->next;
    }
}

static bool gl_backend_source_mentions_texcoord(const char *source)
{
    return source &&
           (strstr(source, "texCoord") != NULL ||
            strstr(source, "TexCoord") != NULL ||
            strstr(source, "uv") != NULL ||
            strstr(source, "UV") != NULL);
}

static bool gl_backend_source_mentions_texture_sampling(const char *source)
{
    return source &&
           (strstr(source, "sampler2D") != NULL ||
            strstr(source, "texture(") != NULL);
}

static void gl_backend_extract_sampler_name(const char *source, char *dst, size_t dst_size)
{
    const char *sampler;
    size_t length = 0;

    if (!dst || dst_size == 0) {
        return;
    }

    dst[0] = '\0';
    if (!source) {
        return;
    }

    sampler = strstr(source, "sampler2D");
    if (!sampler) {
        return;
    }

    sampler += strlen("sampler2D");
    while (*sampler == ' ' || *sampler == '\t' || *sampler == '\n' || *sampler == '\r') {
        sampler++;
    }

    if (!((*sampler >= 'A' && *sampler <= 'Z') ||
          (*sampler >= 'a' && *sampler <= 'z') ||
          *sampler == '_')) {
        return;
    }

    while (((sampler[length] >= 'A' && sampler[length] <= 'Z') ||
            (sampler[length] >= 'a' && sampler[length] <= 'z') ||
            (sampler[length] >= '0' && sampler[length] <= '9') ||
            sampler[length] == '_') &&
           length + 1 < dst_size) {
        dst[length] = sampler[length];
        length++;
    }

    dst[length] = '\0';
}

static GLuint *gl_backend_buffer_binding_slot(AO46BackendContextRef ctx, GLenum target)
{
    GLBackendVertexArray *vertex_array;

    if (!ctx) {
        return NULL;
    }

    switch (target) {
        case GL_ARRAY_BUFFER:
            return &ctx->array_buffer_binding;
        case GL_ELEMENT_ARRAY_BUFFER:
            vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
            return vertex_array ? &vertex_array->element_array_buffer_name : NULL;
        default:
            return NULL;
    }
}

static GLBackendBuffer *gl_backend_bound_buffer(AO46BackendContextRef ctx, GLenum target)
{
    GLuint *binding = gl_backend_buffer_binding_slot(ctx, target);

    if (!binding || *binding == 0) {
        return NULL;
    }

    return gl_backend_find_buffer(ctx, *binding);
}

static char *gl_backend_copy_shader_source(GLsizei count,
                                           const GLchar *const *strings,
                                           const GLint *lengths,
                                           GLsizei *out_length)
{
    size_t total_length = 0;
    char *joined;
    char *dst;

    if (!strings || count <= 0) {
        return NULL;
    }

    for (GLsizei index = 0; index < count; ++index) {
        size_t part_length;

        if (!strings[index]) {
            continue;
        }

        if (lengths && lengths[index] >= 0) {
            part_length = (size_t)lengths[index];
        } else {
            part_length = strlen(strings[index]);
        }

        total_length += part_length;
    }

    joined = calloc(total_length + 1, 1);
    if (!joined) {
        return NULL;
    }

    dst = joined;
    for (GLsizei index = 0; index < count; ++index) {
        size_t part_length;

        if (!strings[index]) {
            continue;
        }

        if (lengths && lengths[index] >= 0) {
            part_length = (size_t)lengths[index];
        } else {
            part_length = strlen(strings[index]);
        }

        memcpy(dst, strings[index], part_length);
        dst += part_length;
    }

    *dst = '\0';
    if (out_length) {
        *out_length = (GLsizei)total_length;
    }
    return joined;
}

static void gl_backend_remove_shader(AO46BackendContextRef ctx, GLBackendShader *shader)
{
    GLBackendShader **slot = ctx ? &ctx->shaders : NULL;

    while (slot && *slot) {
        if (*slot == shader) {
            *slot = shader->next;
            free(shader->source);
            free(shader);
            return;
        }
        slot = &(*slot)->next;
    }
}

static void gl_backend_remove_program(AO46BackendContextRef ctx, GLBackendProgram *program)
{
    GLBackendProgram **slot = ctx ? &ctx->programs : NULL;

    while (slot && *slot) {
        if (*slot == program) {
            *slot = program->next;
            free(program);
            return;
        }
        slot = &(*slot)->next;
    }
}

static void gl_backend_remove_buffer(AO46BackendContextRef ctx, GLBackendBuffer *buffer)
{
    GLBackendBuffer **slot = ctx ? &ctx->buffers : NULL;

    while (slot && *slot) {
        if (*slot == buffer) {
            *slot = buffer->next;
            free(buffer->data);
            free(buffer);
            return;
        }
        slot = &(*slot)->next;
    }
}

static void gl_backend_remove_vertex_array(AO46BackendContextRef ctx, GLBackendVertexArray *vertex_array)
{
    GLBackendVertexArray **slot = ctx ? &ctx->vertex_arrays : NULL;

    while (slot && *slot) {
        if (*slot == vertex_array) {
            *slot = vertex_array->next;
            free(vertex_array);
            return;
        }
        slot = &(*slot)->next;
    }
}

static GLuint gl_backend_create_shader(GLenum type)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;

    if (!ctx) {
        return 0;
    }

    if (type != GL_VERTEX_SHADER && type != GL_FRAGMENT_SHADER) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return 0;
    }

    shader = calloc(1, sizeof(*shader));
    if (!shader) {
        gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
        return 0;
    }

    shader->name = gl_backend_next_name(&ctx->next_shader_name);
    shader->type = type;
    shader->next = ctx->shaders;
    ctx->shaders = shader;
    return shader->name;
}

static void gl_backend_shader_source(GLuint shader_name,
                                     GLsizei count,
                                     const GLchar *const *strings,
                                     const GLint *lengths)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;
    char *source;
    GLsizei source_length = 0;

    if (!ctx) {
        return;
    }

    if (count < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    shader = gl_backend_find_shader(ctx, shader_name);
    if (!shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    source = gl_backend_copy_shader_source(count, strings, lengths, &source_length);
    if (!source && count > 0) {
        gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
        return;
    }

    free(shader->source);
    shader->source = source;
    shader->source_length = source_length;
    shader->compiled = GL_FALSE;
    gl_backend_set_log(shader->info_log, sizeof(shader->info_log), NULL);
}

static void gl_backend_compile_shader(GLuint shader_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;

    if (!ctx) {
        return;
    }

    shader = gl_backend_find_shader(ctx, shader_name);
    if (!shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (!gl_backend_source_has_main(shader->source)) {
        shader->compiled = GL_FALSE;
        gl_backend_set_log(shader->info_log, sizeof(shader->info_log), "shader source is missing a main function");
        return;
    }

    shader->compiled = GL_TRUE;
    gl_backend_set_log(shader->info_log, sizeof(shader->info_log), NULL);
}

static void gl_backend_get_shader_iv(GLuint shader_name, GLenum pname, GLint *params)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;

    if (!ctx || !params) {
        return;
    }

    shader = gl_backend_find_shader(ctx, shader_name);
    if (!shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    switch (pname) {
        case GL_SHADER_TYPE:
            params[0] = (GLint)shader->type;
            return;
        case GL_COMPILE_STATUS:
            params[0] = shader->compiled;
            return;
        case GL_DELETE_STATUS:
            params[0] = shader->delete_pending;
            return;
        case GL_INFO_LOG_LENGTH:
            params[0] = (GLint)strlen(shader->info_log) + 1;
            return;
        case GL_SHADER_SOURCE_LENGTH:
            params[0] = shader->source ? shader->source_length + 1 : 0;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            params[0] = 0;
            return;
    }
}

static void gl_backend_copy_text_to_log(const char *src, GLsizei buf_size, GLsizei *length, GLchar *dst)
{
    size_t src_length = src ? strlen(src) : 0;
    size_t copied = 0;

    if (dst && buf_size > 0) {
        copied = src_length < (size_t)(buf_size - 1) ? src_length : (size_t)(buf_size - 1);
        if (copied > 0) {
            memcpy(dst, src, copied);
        }
        dst[copied] = '\0';
    }

    if (length) {
        *length = (GLsizei)copied;
    }
}

static void gl_backend_get_shader_info_log(GLuint shader_name,
                                           GLsizei buf_size,
                                           GLsizei *length,
                                           GLchar *info_log)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;

    if (!ctx) {
        return;
    }

    if (buf_size < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    shader = gl_backend_find_shader(ctx, shader_name);
    if (!shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_copy_text_to_log(shader->info_log, buf_size, length, info_log);
}

static GLboolean gl_backend_is_shader(GLuint shader_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    return ctx && gl_backend_find_shader(ctx, shader_name) != NULL ? GL_TRUE : GL_FALSE;
}

static void gl_backend_delete_shader(GLuint shader_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendShader *shader;

    if (!ctx || shader_name == 0) {
        return;
    }

    shader = gl_backend_find_shader(ctx, shader_name);
    if (!shader) {
        return;
    }

    if (shader->attach_count > 0) {
        shader->delete_pending = GL_TRUE;
        return;
    }

    gl_backend_remove_shader(ctx, shader);
}

static GLuint gl_backend_create_program(void)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return 0;
    }

    program = calloc(1, sizeof(*program));
    if (!program) {
        gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
        return 0;
    }

    program->name = gl_backend_next_name(&ctx->next_program_name);
    program->active_attribute_count = 2;
    program->sampler_binding_unit = 0;
    for (int index = 0; index < GL_DRIVER_MAX_VERTEX_ATTRIBS; ++index) {
        program->bound_attribute_location[index] = -1;
    }
    program->next = ctx->programs;
    ctx->programs = program;
    return program->name;
}

static void gl_backend_program_attach_shader(GLBackendProgram *program, GLBackendShader *shader)
{
    GLuint *slot = NULL;

    if (shader->type == GL_VERTEX_SHADER) {
        slot = &program->vertex_shader_name;
    } else if (shader->type == GL_FRAGMENT_SHADER) {
        slot = &program->fragment_shader_name;
    }

    if (!slot) {
        return;
    }

    if (*slot == shader->name) {
        return;
    }

    *slot = shader->name;
    shader->attach_count++;
}

static void gl_backend_attach_shader(GLuint program_name, GLuint shader_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendShader *shader;

    if (!ctx) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    shader = gl_backend_find_shader(ctx, shader_name);
    if (!program || !shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_program_attach_shader(program, shader);
}

static void gl_backend_detach_shader(GLuint program_name, GLuint shader_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendShader *shader;
    GLuint *slot = NULL;

    if (!ctx) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    shader = gl_backend_find_shader(ctx, shader_name);
    if (!program || !shader) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (program->vertex_shader_name == shader_name) {
        slot = &program->vertex_shader_name;
    } else if (program->fragment_shader_name == shader_name) {
        slot = &program->fragment_shader_name;
    }

    if (!slot) {
        return;
    }

    *slot = 0;
    if (shader->attach_count > 0) {
        shader->attach_count--;
    }

    if (shader->delete_pending && shader->attach_count == 0) {
        gl_backend_remove_shader(ctx, shader);
    }
}

static void gl_backend_bind_attrib_location(GLuint program_name, GLuint index, const GLchar *name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (index >= GL_DRIVER_MAX_VERTEX_ATTRIBS) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    program->bound_attribute_location[index] = (GLint)index;
    if (name) {
        strncpy(program->bound_attribute_name[index], name, sizeof(program->bound_attribute_name[index]) - 1);
        program->bound_attribute_name[index][sizeof(program->bound_attribute_name[index]) - 1] = '\0';
    } else {
        program->bound_attribute_name[index][0] = '\0';
    }
}

static void gl_backend_link_program(GLuint program_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendShader *vertex_shader;
    GLBackendShader *fragment_shader;

    if (!ctx) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    vertex_shader = gl_backend_find_shader(ctx, program->vertex_shader_name);
    fragment_shader = gl_backend_find_shader(ctx, program->fragment_shader_name);

    if (!vertex_shader || !fragment_shader) {
        program->linked = GL_FALSE;
        gl_backend_set_log(program->info_log, sizeof(program->info_log), "program requires one compiled vertex shader and one compiled fragment shader");
        return;
    }

    if (!vertex_shader->compiled || !fragment_shader->compiled) {
        program->linked = GL_FALSE;
        gl_backend_set_log(program->info_log, sizeof(program->info_log), "attached shaders must compile successfully before linking");
        return;
    }

    program->linked = GL_TRUE;
    program->validated = GL_TRUE;
    program->uses_texture_2d = gl_backend_source_mentions_texture_sampling(fragment_shader->source) ? GL_TRUE : GL_FALSE;
    program->active_attribute_count = gl_backend_source_mentions_texcoord(vertex_shader->source) ? 3 : 2;
    program->active_uniform_count = program->uses_texture_2d ? 1 : 0;
    program->sampler_binding_unit = 0;
    gl_backend_extract_sampler_name(fragment_shader->source, program->sampler_name, sizeof(program->sampler_name));
    gl_backend_set_log(program->info_log, sizeof(program->info_log), NULL);
}

static void gl_backend_use_program(GLuint program_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return;
    }

    if (program_name == 0) {
        ctx->current_program_name = 0;
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (!program->linked) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    ctx->current_program_name = program_name;
}

static void gl_backend_validate_program(GLuint program_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    program->validated = program->linked;
    if (!program->linked) {
        gl_backend_set_log(program->info_log, sizeof(program->info_log), "program must link before it can validate");
    }
}

static void gl_backend_get_program_iv(GLuint program_name, GLenum pname, GLint *params)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx || !params) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    switch (pname) {
        case GL_LINK_STATUS:
            params[0] = program->linked;
            return;
        case GL_VALIDATE_STATUS:
            params[0] = program->validated;
            return;
        case GL_DELETE_STATUS:
            params[0] = program->delete_pending;
            return;
        case GL_INFO_LOG_LENGTH:
            params[0] = (GLint)strlen(program->info_log) + 1;
            return;
        case GL_ATTACHED_SHADERS:
            params[0] = (program->vertex_shader_name ? 1 : 0) + (program->fragment_shader_name ? 1 : 0);
            return;
        case GL_ACTIVE_ATTRIBUTES:
            params[0] = program->active_attribute_count;
            return;
        case GL_ACTIVE_UNIFORMS:
            params[0] = program->active_uniform_count;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            params[0] = 0;
            return;
    }
}

static void gl_backend_get_program_info_log(GLuint program_name,
                                            GLsizei buf_size,
                                            GLsizei *length,
                                            GLchar *info_log)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return;
    }

    if (buf_size < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_copy_text_to_log(program->info_log, buf_size, length, info_log);
}

static GLint gl_backend_get_attrib_location(GLuint program_name, const GLchar *name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return -1;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program || !name) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return -1;
    }

    for (int index = 0; index < GL_DRIVER_MAX_VERTEX_ATTRIBS; ++index) {
        if (program->bound_attribute_name[index][0] != '\0' &&
            strcmp(program->bound_attribute_name[index], name) == 0) {
            return program->bound_attribute_location[index] >= 0 ? program->bound_attribute_location[index] : index;
        }
    }

    if (strcmp(name, "position") == 0 || strcmp(name, "aPosition") == 0 || strcmp(name, "inPosition") == 0) {
        return 0;
    }
    if (strcmp(name, "color") == 0 || strcmp(name, "aColor") == 0 || strcmp(name, "inColor") == 0) {
        return 1;
    }
    if (strcmp(name, "texCoord") == 0 ||
        strcmp(name, "aTexCoord") == 0 ||
        strcmp(name, "inTexCoord") == 0 ||
        strcmp(name, "uv") == 0 ||
        strcmp(name, "aUV") == 0) {
        return 2;
    }
    return -1;
}

static GLint gl_backend_get_uniform_location(GLuint program_name, const GLchar *name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return -1;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program || !name) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return -1;
    }

    if (!program->uses_texture_2d) {
        return -1;
    }

    if (program->sampler_name[0] != '\0' && strcmp(program->sampler_name, name) == 0) {
        return 0;
    }

    if ((strcmp(name, "tex") == 0 ||
         strcmp(name, "uTexture") == 0 ||
         strcmp(name, "diffuseTexture") == 0) &&
        program->active_uniform_count > 0) {
        return 0;
    }

    return -1;
}

static void gl_backend_uniform_1i(GLint location, GLint v0)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;

    if (!ctx) {
        return;
    }

    if (location == -1) {
        return;
    }

    program = gl_backend_find_program(ctx, ctx->current_program_name);
    if (!program || !program->linked) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (location != 0 || !program->uses_texture_2d) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    program->sampler_binding_unit = v0;
}

static GLboolean gl_backend_is_program(GLuint program_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    return ctx && gl_backend_find_program(ctx, program_name) != NULL ? GL_TRUE : GL_FALSE;
}

static void gl_backend_delete_program(GLuint program_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendShader *shader;

    if (!ctx || program_name == 0) {
        return;
    }

    program = gl_backend_find_program(ctx, program_name);
    if (!program) {
        return;
    }

    shader = gl_backend_find_shader(ctx, program->vertex_shader_name);
    if (shader) {
        if (shader->attach_count > 0) {
            shader->attach_count--;
        }
        if (shader->delete_pending && shader->attach_count == 0) {
            gl_backend_remove_shader(ctx, shader);
        }
    }

    shader = gl_backend_find_shader(ctx, program->fragment_shader_name);
    if (shader) {
        if (shader->attach_count > 0) {
            shader->attach_count--;
        }
        if (shader->delete_pending && shader->attach_count == 0) {
            gl_backend_remove_shader(ctx, shader);
        }
    }

    if (ctx->current_program_name == program_name) {
        ctx->current_program_name = 0;
    }

    gl_backend_remove_program(ctx, program);
}

static void gl_backend_gen_textures(GLsizei n, GLuint *textures)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !textures) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLuint name = gl_backend_next_name(&ctx->next_texture_name);
        GLBackendTexture *texture = gl_backend_create_texture_record(ctx, name);

        if (!texture) {
            textures[index] = 0;
            continue;
        }

        textures[index] = name;
    }
}

static GLboolean gl_backend_is_texture(GLuint texture_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture = ctx ? gl_backend_find_texture(ctx, texture_name) : NULL;

    return texture && texture->target != 0 ? GL_TRUE : GL_FALSE;
}

static void gl_backend_delete_textures(GLsizei n, const GLuint *textures)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !textures) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLBackendTexture *texture = gl_backend_find_texture(ctx, textures[index]);

        if (!texture) {
            continue;
        }

        for (GLuint unit = 0; unit < GL_DRIVER_MAX_TEXTURE_UNITS; ++unit) {
            if (ctx->texture_units[unit].texture_2d_name == texture->name) {
                ctx->texture_units[unit].texture_2d_name = 0;
            }
        }

        gl_backend_remove_texture(ctx, texture);
    }
}

static void gl_backend_active_texture(GLenum texture)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLuint unit_index;

    if (!ctx) {
        return;
    }

    if (texture < GL_TEXTURE0) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    unit_index = texture - GL_TEXTURE0;
    if (unit_index >= GL_DRIVER_MAX_TEXTURE_UNITS) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    ctx->active_texture_unit_index = unit_index;
}

static void gl_backend_bind_texture(GLenum target, GLuint texture_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLuint *binding;
    GLBackendTexture *texture = NULL;

    if (!ctx) {
        return;
    }

    binding = gl_backend_texture_binding_slot(ctx, target);
    if (!binding) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (texture_name != 0) {
        texture = gl_backend_find_texture(ctx, texture_name);
        if (!texture) {
            texture = gl_backend_create_texture_record(ctx, texture_name);
            if (!texture) {
                return;
            }
        }

        if (texture->target != 0 && texture->target != target) {
            gl_backend_set_error(ctx, GL_INVALID_OPERATION);
            return;
        }

        if (texture->target == 0) {
            texture->target = target;
        }
    }

    *binding = texture_name;
}

static bool gl_backend_texture_filter_valid(GLenum pname, GLint param)
{
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
            return param == GL_NEAREST ||
                   param == GL_LINEAR ||
                   param == GL_NEAREST_MIPMAP_NEAREST ||
                   param == GL_LINEAR_MIPMAP_NEAREST ||
                   param == GL_NEAREST_MIPMAP_LINEAR ||
                   param == GL_LINEAR_MIPMAP_LINEAR;
        case GL_TEXTURE_MAG_FILTER:
            return param == GL_NEAREST || param == GL_LINEAR;
        default:
            return false;
    }
}

static bool gl_backend_texture_wrap_valid(GLint param)
{
    return param == GL_REPEAT || param == GL_CLAMP_TO_EDGE || param == GL_MIRRORED_REPEAT;
}

static void gl_backend_tex_parameter_i(GLenum target, GLenum pname, GLint param)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;

    if (!ctx) {
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
        case GL_TEXTURE_MAG_FILTER:
            if (!gl_backend_texture_filter_valid(pname, param)) {
                gl_backend_set_error(ctx, GL_INVALID_ENUM);
                return;
            }
            if (pname == GL_TEXTURE_MIN_FILTER) {
                texture->min_filter = param;
            } else {
                texture->mag_filter = param;
            }
            return;
        case GL_TEXTURE_WRAP_S:
        case GL_TEXTURE_WRAP_T:
            if (!gl_backend_texture_wrap_valid(param)) {
                gl_backend_set_error(ctx, GL_INVALID_ENUM);
                return;
            }
            if (pname == GL_TEXTURE_WRAP_S) {
                texture->wrap_s = param;
            } else {
                texture->wrap_t = param;
            }
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return;
    }
}

static void gl_backend_get_tex_parameter_iv(GLenum target, GLenum pname, GLint *params)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;

    if (!ctx || !params) {
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        params[0] = 0;
        return;
    }

    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
            params[0] = texture->min_filter;
            return;
        case GL_TEXTURE_MAG_FILTER:
            params[0] = texture->mag_filter;
            return;
        case GL_TEXTURE_WRAP_S:
            params[0] = texture->wrap_s;
            return;
        case GL_TEXTURE_WRAP_T:
            params[0] = texture->wrap_t;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            params[0] = 0;
            return;
    }
}

static void gl_backend_store_texel_bgra8(uint8_t *dst, GLenum format, const uint8_t *src)
{
    if (format == GL_BGRA) {
        memcpy(dst, src, 4u);
        return;
    }

    dst[0] = src[2];
    dst[1] = src[1];
    dst[2] = src[0];
    dst[3] = src[3];
}

static void gl_backend_copy_texture_image_bgra8(uint8_t *dst,
                                                GLsizei width,
                                                GLsizei height,
                                                GLenum format,
                                                GLint unpack_alignment,
                                                const void *pixels)
{
    const uint8_t *src = pixels;
    size_t src_row_stride;

    if (!dst || !pixels || width <= 0 || height <= 0) {
        return;
    }

    src_row_stride = gl_backend_aligned_row_stride(width, 4u, unpack_alignment);
    for (GLsizei y = 0; y < height; ++y) {
        for (GLsizei x = 0; x < width; ++x) {
            gl_backend_store_texel_bgra8(dst + ((size_t)y * (size_t)width + (size_t)x) * 4u,
                                         format,
                                         src + (size_t)y * src_row_stride + (size_t)x * 4u);
        }
    }
}

static void gl_backend_copy_texture_sub_image_bgra8(GLBackendTexture *texture,
                                                    GLint xoffset,
                                                    GLint yoffset,
                                                    GLsizei width,
                                                    GLsizei height,
                                                    GLenum format,
                                                    GLint unpack_alignment,
                                                    const void *pixels)
{
    const uint8_t *src = pixels;
    size_t src_row_stride;

    if (!texture || !texture->data || !pixels || width <= 0 || height <= 0) {
        return;
    }

    src_row_stride = gl_backend_aligned_row_stride(width, 4u, unpack_alignment);
    for (GLsizei y = 0; y < height; ++y) {
        for (GLsizei x = 0; x < width; ++x) {
            uint8_t *dst_texel = texture->data +
                                 (((size_t)(yoffset + y) * (size_t)texture->width) + (size_t)(xoffset + x)) * 4u;

            gl_backend_store_texel_bgra8(dst_texel,
                                         format,
                                         src + (size_t)y * src_row_stride + (size_t)x * 4u);
        }
    }
}

static void gl_backend_tex_image_2d(GLenum target,
                                    GLint level,
                                    GLint internalformat,
                                    GLsizei width,
                                    GLsizei height,
                                    GLint border,
                                    GLenum format,
                                    GLenum type,
                                    const void *pixels)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;
    uint8_t *storage = NULL;

    if (!ctx) {
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (level != 0 ||
        border != 0 ||
        width < 0 ||
        height < 0 ||
        width > ctx->core.state.max_texture_size ||
        height > ctx->core.state.max_texture_size) {
        gl_backend_set_error(ctx, level != 0 || border != 0 ? GL_INVALID_VALUE : GL_INVALID_VALUE);
        return;
    }

    if (internalformat != GL_RGBA8 && internalformat != GL_RGBA) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (format != GL_RGBA && format != GL_BGRA) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (type != GL_UNSIGNED_BYTE) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (width > 0 && height > 0) {
        storage = calloc((size_t)width * (size_t)height, 4u);
        if (!storage) {
            gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
            return;
        }
        if (pixels) {
            gl_backend_copy_texture_image_bgra8(storage,
                                               width,
                                               height,
                                               format,
                                               ctx->core.state.unpack_alignment,
                                               pixels);
        }
    }

    free(texture->data);
    texture->data = storage;
    texture->defined = (width > 0 && height > 0) ? GL_TRUE : GL_FALSE;
    texture->width = width;
    texture->height = height;
    texture->internal_format = internalformat == GL_RGBA ? GL_RGBA8 : internalformat;
}

static void gl_backend_tex_sub_image_2d(GLenum target,
                                        GLint level,
                                        GLint xoffset,
                                        GLint yoffset,
                                        GLsizei width,
                                        GLsizei height,
                                        GLenum format,
                                        GLenum type,
                                        const void *pixels)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;

    if (!ctx) {
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (level != 0 || xoffset < 0 || yoffset < 0 || width < 0 || height < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (format != GL_RGBA && format != GL_BGRA) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (type != GL_UNSIGNED_BYTE) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (!texture->defined || !texture->data) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (xoffset + width > texture->width || yoffset + height > texture->height) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if ((width > 0 || height > 0) && !pixels) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_copy_texture_sub_image_bgra8(texture,
                                            xoffset,
                                            yoffset,
                                            width,
                                            height,
                                            format,
                                            ctx->core.state.unpack_alignment,
                                            pixels);
}

static void gl_backend_get_tex_level_parameter_iv(GLenum target, GLint level, GLenum pname, GLint *params)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;

    if (!ctx || !params) {
        return;
    }

    if (level != 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        params[0] = 0;
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        params[0] = 0;
        return;
    }

    switch (pname) {
        case GL_TEXTURE_WIDTH:
            params[0] = texture->width;
            return;
        case GL_TEXTURE_HEIGHT:
            params[0] = texture->height;
            return;
        case GL_TEXTURE_INTERNAL_FORMAT:
            params[0] = texture->defined ? texture->internal_format : 0;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            params[0] = 0;
            return;
    }
}

static void gl_backend_get_tex_image(GLenum target, GLint level, GLenum format, GLenum type, void *pixels)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendTexture *texture;
    size_t dst_row_stride;

    if (!ctx) {
        return;
    }

    if (!pixels) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (level != 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (format != GL_RGBA && format != GL_BGRA) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (type != GL_UNSIGNED_BYTE) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture || !texture->defined || !texture->data) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    dst_row_stride = gl_backend_aligned_row_stride(texture->width, 4u, ctx->core.state.pack_alignment);
    for (GLsizei y = 0; y < texture->height; ++y) {
        for (GLsizei x = 0; x < texture->width; ++x) {
            gl_backend_read_bgra8_pixel(texture->data + ((size_t)y * (size_t)texture->width + (size_t)x) * 4u,
                                        format,
                                        (uint8_t *)pixels + (size_t)y * dst_row_stride + (size_t)x * 4u);
        }
    }
}

static void gl_backend_gen_buffers(GLsizei n, GLuint *buffers)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !buffers) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLBackendBuffer *buffer = calloc(1, sizeof(*buffer));

        if (!buffer) {
            gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
            buffers[index] = 0;
            continue;
        }

        buffer->name = gl_backend_next_name(&ctx->next_buffer_name);
        buffer->next = ctx->buffers;
        ctx->buffers = buffer;
        buffers[index] = buffer->name;
    }
}

static GLboolean gl_backend_is_buffer(GLuint buffer_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    return ctx && gl_backend_find_buffer(ctx, buffer_name) != NULL ? GL_TRUE : GL_FALSE;
}

static void gl_backend_delete_buffers(GLsizei n, const GLuint *buffers)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !buffers) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLBackendBuffer *buffer = gl_backend_find_buffer(ctx, buffers[index]);
        GLBackendVertexArray *vertex_array;

        if (!buffer) {
            continue;
        }

        if (ctx->array_buffer_binding == buffer->name) {
            ctx->array_buffer_binding = 0;
        }

        vertex_array = ctx->vertex_arrays;
        while (vertex_array) {
            if (vertex_array->element_array_buffer_name == buffer->name) {
                vertex_array->element_array_buffer_name = 0;
            }
            for (int attrib = 0; attrib < GL_DRIVER_MAX_VERTEX_ATTRIBS; ++attrib) {
                if (vertex_array->attribs[attrib].buffer_name == buffer->name) {
                    vertex_array->attribs[attrib].buffer_name = 0;
                }
            }
            vertex_array = vertex_array->next;
        }

        gl_backend_remove_buffer(ctx, buffer);
    }
}

static void gl_backend_bind_buffer(GLenum target, GLuint buffer_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLuint *binding;

    if (!ctx) {
        return;
    }

    binding = gl_backend_buffer_binding_slot(ctx, target);
    if (!binding) {
        gl_backend_set_error(ctx, target == GL_ELEMENT_ARRAY_BUFFER ? GL_INVALID_OPERATION : GL_INVALID_ENUM);
        return;
    }

    if (buffer_name != 0 && !gl_backend_find_buffer(ctx, buffer_name)) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    *binding = buffer_name;
}

static void gl_backend_buffer_data(GLenum target,
                                   GLsizeiptr size,
                                   const void *data,
                                   GLenum usage)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendBuffer *buffer;
    uint8_t *storage;

    if (!ctx) {
        return;
    }

    if (size < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    buffer = gl_backend_bound_buffer(ctx, target);
    if (!buffer) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    storage = size > 0 ? calloc((size_t)size, 1) : NULL;
    if (size > 0 && !storage) {
        gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
        return;
    }

    if (size > 0 && data) {
        memcpy(storage, data, (size_t)size);
    }

    free(buffer->data);
    buffer->data = storage;
    buffer->size = (size_t)size;
    buffer->usage = usage;
}

static void gl_backend_buffer_sub_data(GLenum target,
                                       GLintptr offset,
                                       GLsizeiptr size,
                                       const void *data)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendBuffer *buffer;

    if (!ctx) {
        return;
    }

    if (offset < 0 || size < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    buffer = gl_backend_bound_buffer(ctx, target);
    if (!buffer || !buffer->data) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if ((size_t)offset > buffer->size || (size_t)size > buffer->size - (size_t)offset) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (size == 0) {
        return;
    }

    if (!data) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    memcpy(buffer->data + (size_t)offset, data, (size_t)size);
}

static void gl_backend_get_buffer_parameter_iv(GLenum target, GLenum pname, GLint *params)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendBuffer *buffer;

    if (!ctx || !params) {
        return;
    }

    buffer = gl_backend_bound_buffer(ctx, target);
    if (!buffer) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        params[0] = 0;
        return;
    }

    switch (pname) {
        case GL_BUFFER_SIZE:
            params[0] = (GLint)buffer->size;
            return;
        case GL_BUFFER_USAGE:
            params[0] = (GLint)buffer->usage;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            params[0] = 0;
            return;
    }
}

static void gl_backend_gen_vertex_arrays(GLsizei n, GLuint *arrays)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !arrays) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLBackendVertexArray *vertex_array = calloc(1, sizeof(*vertex_array));

        if (!vertex_array) {
            gl_backend_set_error(ctx, GL_OUT_OF_MEMORY);
            arrays[index] = 0;
            continue;
        }

        vertex_array->name = gl_backend_next_name(&ctx->next_vertex_array_name);
        vertex_array->next = ctx->vertex_arrays;
        ctx->vertex_arrays = vertex_array;
        arrays[index] = vertex_array->name;
    }
}

static GLboolean gl_backend_is_vertex_array(GLuint array_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    return ctx && gl_backend_find_vertex_array(ctx, array_name) != NULL ? GL_TRUE : GL_FALSE;
}

static void gl_backend_delete_vertex_arrays(GLsizei n, const GLuint *arrays)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !arrays) {
        return;
    }

    if (n < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    for (GLsizei index = 0; index < n; ++index) {
        GLBackendVertexArray *vertex_array = gl_backend_find_vertex_array(ctx, arrays[index]);

        if (!vertex_array) {
            continue;
        }

        if (ctx->current_vertex_array_name == vertex_array->name) {
            ctx->current_vertex_array_name = 0;
        }

        gl_backend_remove_vertex_array(ctx, vertex_array);
    }
}

static void gl_backend_bind_vertex_array(GLuint array_name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if (array_name != 0 && !gl_backend_find_vertex_array(ctx, array_name)) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    ctx->current_vertex_array_name = array_name;
}

static void gl_backend_enable_vertex_attrib_array(GLuint index)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendVertexArray *vertex_array;

    if (!ctx) {
        return;
    }

    if (index >= GL_DRIVER_MAX_VERTEX_ATTRIBS) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
    if (!vertex_array) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    vertex_array->attribs[index].enabled = GL_TRUE;
}

static void gl_backend_disable_vertex_attrib_array(GLuint index)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendVertexArray *vertex_array;

    if (!ctx) {
        return;
    }

    if (index >= GL_DRIVER_MAX_VERTEX_ATTRIBS) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
    if (!vertex_array) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    vertex_array->attribs[index].enabled = GL_FALSE;
}

static void gl_backend_vertex_attrib_pointer(GLuint index,
                                             GLint size,
                                             GLenum type,
                                             GLboolean normalized,
                                             GLsizei stride,
                                             const void *pointer)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendVertexArray *vertex_array;
    GLBackendVertexAttrib *attrib;

    if (!ctx) {
        return;
    }

    if (index >= GL_DRIVER_MAX_VERTEX_ATTRIBS || size < 1 || size > 4 || stride < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (type != GL_FLOAT) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
    if (!vertex_array || ctx->array_buffer_binding == 0) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    attrib = &vertex_array->attribs[index];
    attrib->size = size;
    attrib->type = type;
    attrib->normalized = normalized;
    attrib->stride = stride;
    attrib->offset = (uintptr_t)pointer;
    attrib->buffer_name = ctx->array_buffer_binding;
}

static bool gl_backend_fetch_attrib(GLBackendBuffer *buffer,
                                    const GLBackendVertexAttrib *attrib,
                                    GLint vertex_index,
                                    GLfloat default_w,
                                    GLfloat out_values[4])
{
    size_t stride;
    size_t offset;
    const GLfloat *src;

    out_values[0] = 0.0f;
    out_values[1] = 0.0f;
    out_values[2] = 0.0f;
    out_values[3] = default_w;

    if (!buffer || !attrib || !buffer->data || attrib->type != GL_FLOAT || attrib->size < 1 || attrib->size > 4) {
        return false;
    }

    stride = attrib->stride > 0 ? (size_t)attrib->stride : (size_t)attrib->size * sizeof(GLfloat);
    offset = attrib->offset + (size_t)vertex_index * stride;
    if (offset + (size_t)attrib->size * sizeof(GLfloat) > buffer->size) {
        return false;
    }

    src = (const GLfloat *)(buffer->data + offset);
    for (GLint component = 0; component < attrib->size; ++component) {
        out_values[component] = src[component];
    }
    if (attrib->size == 1) {
        out_values[1] = 0.0f;
        out_values[2] = 0.0f;
        out_values[3] = default_w;
    } else if (attrib->size == 2) {
        out_values[2] = 0.0f;
        out_values[3] = default_w;
    } else if (attrib->size == 3) {
        out_values[3] = default_w;
    }
    return true;
}

static bool gl_backend_fetch_vertex(AO46BackendContextRef ctx,
                                    GLBackendProgram *program,
                                    GLBackendVertexArray *vertex_array,
                                    GLint vertex_index,
                                    GLBackendVertex *vertex)
{
    GLBackendBuffer *position_buffer;
    GLBackendBuffer *color_buffer;
    GLBackendBuffer *texcoord_buffer;
    const GLBackendVertexAttrib *position_attrib = &vertex_array->attribs[0];
    const GLBackendVertexAttrib *color_attrib = &vertex_array->attribs[1];
    const GLBackendVertexAttrib *texcoord_attrib = &vertex_array->attribs[2];

    vertex->color[0] = 1.0f;
    vertex->color[1] = 1.0f;
    vertex->color[2] = 1.0f;
    vertex->color[3] = 1.0f;
    vertex->texcoord[0] = 0.0f;
    vertex->texcoord[1] = 0.0f;

    if (!position_attrib->enabled || position_attrib->buffer_name == 0) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return false;
    }

    position_buffer = gl_backend_find_buffer(ctx, position_attrib->buffer_name);
    if (!gl_backend_fetch_attrib(position_buffer, position_attrib, vertex_index, 1.0f, vertex->position)) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return false;
    }

    if (color_attrib->enabled && color_attrib->buffer_name != 0) {
        color_buffer = gl_backend_find_buffer(ctx, color_attrib->buffer_name);
        if (!gl_backend_fetch_attrib(color_buffer, color_attrib, vertex_index, 1.0f, vertex->color)) {
            gl_backend_set_error(ctx, GL_INVALID_OPERATION);
            return false;
        }
    }

    if (program &&
        program->uses_texture_2d &&
        texcoord_attrib->enabled &&
        texcoord_attrib->buffer_name != 0) {
        GLfloat texcoord_values[4];

        texcoord_buffer = gl_backend_find_buffer(ctx, texcoord_attrib->buffer_name);
        if (!gl_backend_fetch_attrib(texcoord_buffer, texcoord_attrib, vertex_index, 0.0f, texcoord_values)) {
            gl_backend_set_error(ctx, GL_INVALID_OPERATION);
            return false;
        }

        vertex->texcoord[0] = texcoord_values[0];
        vertex->texcoord[1] = texcoord_values[1];
    }

    return true;
}

static float gl_backend_edge_function(float ax, float ay, float bx, float by, float px, float py)
{
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

static bool gl_backend_texture_filter_uses_mipmaps(GLint filter)
{
    return filter == GL_NEAREST_MIPMAP_NEAREST ||
           filter == GL_LINEAR_MIPMAP_NEAREST ||
           filter == GL_NEAREST_MIPMAP_LINEAR ||
           filter == GL_LINEAR_MIPMAP_LINEAR;
}

static float gl_backend_wrap_texture_coordinate(float value, GLint wrap_mode)
{
    switch (wrap_mode) {
        case GL_REPEAT:
            return value - floorf(value);
        case GL_MIRRORED_REPEAT: {
            float wrapped = fmodf(value, 2.0f);
            if (wrapped < 0.0f) {
                wrapped += 2.0f;
            }
            return wrapped <= 1.0f ? wrapped : 2.0f - wrapped;
        }
        case GL_CLAMP_TO_EDGE:
        default:
            return gl_backend_clampf(value);
    }
}

static void gl_backend_sample_texture_2d(const GLBackendTexture *texture,
                                         GLfloat s,
                                         GLfloat t,
                                         GLfloat out_color[4])
{
    GLfloat wrapped_s;
    GLfloat wrapped_t;
    GLsizei x;
    GLsizei y;
    const uint8_t *texel;

    out_color[0] = 0.0f;
    out_color[1] = 0.0f;
    out_color[2] = 0.0f;
    out_color[3] = 1.0f;

    if (!texture || !texture->defined || !texture->data || texture->width <= 0 || texture->height <= 0) {
        return;
    }

    if (gl_backend_texture_filter_uses_mipmaps(texture->min_filter)) {
        return;
    }

    wrapped_s = gl_backend_wrap_texture_coordinate(s, texture->wrap_s);
    wrapped_t = gl_backend_wrap_texture_coordinate(t, texture->wrap_t);
    x = (GLsizei)floorf(wrapped_s * (GLfloat)(texture->width - 1) + 0.5f);
    y = (GLsizei)floorf(wrapped_t * (GLfloat)(texture->height - 1) + 0.5f);

    if (x < 0) {
        x = 0;
    } else if (x >= texture->width) {
        x = texture->width - 1;
    }

    if (y < 0) {
        y = 0;
    } else if (y >= texture->height) {
        y = texture->height - 1;
    }

    texel = texture->data + ((size_t)y * (size_t)texture->width + (size_t)x) * 4u;
    out_color[0] = (GLfloat)texel[2] / 255.0f;
    out_color[1] = (GLfloat)texel[1] / 255.0f;
    out_color[2] = (GLfloat)texel[0] / 255.0f;
    out_color[3] = (GLfloat)texel[3] / 255.0f;
}

static void gl_backend_rasterize_triangle(AO46BackendContextRef ctx,
                                          GLBackendProgram *program,
                                          const GLBackendVertex *v0,
                                          const GLBackendVertex *v1,
                                          const GLBackendVertex *v2)
{
    float sx0;
    float sy0;
    float sx1;
    float sy1;
    float sx2;
    float sy2;
    float area;
    GLint min_x;
    GLint max_x;
    GLint min_y;
    GLint max_y;

    if (!gl_backend_has_drawable_storage(ctx)) {
        return;
    }

    if (v0->position[3] == 0.0f || v1->position[3] == 0.0f || v2->position[3] == 0.0f) {
        return;
    }

    sx0 = (v0->position[0] / v0->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[2] + (float)ctx->core.state.viewport[0];
    sy0 = (v0->position[1] / v0->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[3] + (float)ctx->core.state.viewport[1];
    sx1 = (v1->position[0] / v1->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[2] + (float)ctx->core.state.viewport[0];
    sy1 = (v1->position[1] / v1->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[3] + (float)ctx->core.state.viewport[1];
    sx2 = (v2->position[0] / v2->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[2] + (float)ctx->core.state.viewport[0];
    sy2 = (v2->position[1] / v2->position[3] * 0.5f + 0.5f) * (float)ctx->core.state.viewport[3] + (float)ctx->core.state.viewport[1];

    area = gl_backend_edge_function(sx0, sy0, sx1, sy1, sx2, sy2);
    if (area == 0.0f) {
        return;
    }

    min_x = (GLint)floorf(fminf(sx0, fminf(sx1, sx2)));
    max_x = (GLint)ceilf(fmaxf(sx0, fmaxf(sx1, sx2)));
    min_y = (GLint)floorf(fminf(sy0, fminf(sy1, sy2)));
    max_y = (GLint)ceilf(fmaxf(sy0, fmaxf(sy1, sy2)));

    if (min_x < 0) {
        min_x = 0;
    }
    if (min_y < 0) {
        min_y = 0;
    }
    if (max_x > ctx->drawable_width) {
        max_x = ctx->drawable_width;
    }
    if (max_y > ctx->drawable_height) {
        max_y = ctx->drawable_height;
    }

    for (GLint y = min_y; y < max_y; ++y) {
        for (GLint x = min_x; x < max_x; ++x) {
            float px = (float)x + 0.5f;
            float py = (float)y + 0.5f;
            float w0 = gl_backend_edge_function(sx1, sy1, sx2, sy2, px, py);
            float w1 = gl_backend_edge_function(sx2, sy2, sx0, sy0, px, py);
            float w2 = gl_backend_edge_function(sx0, sy0, sx1, sy1, px, py);

            if ((area > 0.0f && (w0 < 0.0f || w1 < 0.0f || w2 < 0.0f)) ||
                (area < 0.0f && (w0 > 0.0f || w1 > 0.0f || w2 > 0.0f))) {
                continue;
            }

            if (ctx->core.state.scissor_test &&
                (x < ctx->core.state.scissor_box[0] ||
                 y < ctx->core.state.scissor_box[1] ||
                 x >= ctx->core.state.scissor_box[0] + ctx->core.state.scissor_box[2] ||
                 y >= ctx->core.state.scissor_box[1] + ctx->core.state.scissor_box[3])) {
                continue;
            }

            {
                GLfloat red;
                GLfloat green;
                GLfloat blue;
                GLfloat alpha;

            w0 /= area;
            w1 /= area;
            w2 /= area;

                red = v0->color[0] * w0 + v1->color[0] * w1 + v2->color[0] * w2;
                green = v0->color[1] * w0 + v1->color[1] * w1 + v2->color[1] * w2;
                blue = v0->color[2] * w0 + v1->color[2] * w1 + v2->color[2] * w2;
                alpha = v0->color[3] * w0 + v1->color[3] * w1 + v2->color[3] * w2;

                if (program && program->uses_texture_2d) {
                    GLfloat sample_color[4];
                    GLfloat s = v0->texcoord[0] * w0 + v1->texcoord[0] * w1 + v2->texcoord[0] * w2;
                    GLfloat t = v0->texcoord[1] * w0 + v1->texcoord[1] * w1 + v2->texcoord[1] * w2;
                    const GLBackendTexture *texture = NULL;

                    if (program->sampler_binding_unit >= 0 &&
                        program->sampler_binding_unit < GL_DRIVER_MAX_TEXTURE_UNITS) {
                        texture = gl_backend_find_texture(ctx,
                                                          ctx->texture_units[program->sampler_binding_unit].texture_2d_name);
                    }
                    gl_backend_sample_texture_2d(texture, s, t, sample_color);
                    red *= sample_color[0];
                    green *= sample_color[1];
                    blue *= sample_color[2];
                    alpha *= sample_color[3];
                }

                gl_backend_write_pixel(ctx, x, y, red, green, blue, alpha);
            }
        }
    }
}

static bool gl_backend_validate_draw_state(AO46BackendContextRef ctx,
                                           bool uses_elements,
                                           GLBackendProgram **out_program,
                                           GLBackendVertexArray **out_vertex_array)
{
    GLBackendProgram *program;
    GLBackendVertexArray *vertex_array;

    if (!ctx) {
        return false;
    }

    program = gl_backend_find_program(ctx, ctx->current_program_name);
    vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
    if (!program || !program->linked || !vertex_array) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return false;
    }

    if (uses_elements && vertex_array->element_array_buffer_name == 0) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return false;
    }

    if (out_program) {
        *out_program = program;
    }
    if (out_vertex_array) {
        *out_vertex_array = vertex_array;
    }
    return true;
}

static bool gl_backend_read_element_index(const GLBackendBuffer *buffer,
                                          GLenum type,
                                          uintptr_t base_offset,
                                          GLsizei element_index,
                                          GLuint *out_index)
{
    size_t element_size;
    size_t byte_offset;
    const uint8_t *src;

    if (!buffer || !buffer->data || !out_index || element_index < 0) {
        return false;
    }

    switch (type) {
        case GL_UNSIGNED_BYTE:
            element_size = sizeof(GLubyte);
            break;
        case GL_UNSIGNED_SHORT:
            element_size = sizeof(GLushort);
            break;
        case GL_UNSIGNED_INT:
            element_size = sizeof(GLuint);
            break;
        default:
            return false;
    }

    byte_offset = (size_t)base_offset + (size_t)element_index * element_size;
    if (byte_offset + element_size > buffer->size) {
        return false;
    }

    src = buffer->data + byte_offset;
    switch (type) {
        case GL_UNSIGNED_BYTE:
            *out_index = (GLuint)src[0];
            return true;
        case GL_UNSIGNED_SHORT: {
            GLushort value;
            memcpy(&value, src, sizeof(value));
            *out_index = (GLuint)value;
            return true;
        }
        case GL_UNSIGNED_INT: {
            GLuint value;
            memcpy(&value, src, sizeof(value));
            *out_index = value;
            return true;
        }
        default:
            return false;
    }
}

static void gl_backend_draw_arrays(GLenum mode, GLint first, GLsizei count)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendVertexArray *vertex_array;

    if (!ctx) {
        return;
    }

    if (first < 0 || count < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (mode != GL_TRIANGLES) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (!gl_backend_validate_draw_state(ctx, false, &program, &vertex_array)) {
        return;
    }

    for (GLint index = first; index + 2 < first + count; index += 3) {
        GLBackendVertex triangle[3];

        if (!gl_backend_fetch_vertex(ctx, program, vertex_array, index + 0, &triangle[0]) ||
            !gl_backend_fetch_vertex(ctx, program, vertex_array, index + 1, &triangle[1]) ||
            !gl_backend_fetch_vertex(ctx, program, vertex_array, index + 2, &triangle[2])) {
            return;
        }

        gl_backend_rasterize_triangle(ctx, program, &triangle[0], &triangle[1], &triangle[2]);
    }
}

static void gl_backend_draw_elements(GLenum mode, GLsizei count, GLenum type, const void *indices)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLBackendProgram *program;
    GLBackendVertexArray *vertex_array;
    GLBackendBuffer *element_buffer;
    uintptr_t index_offset = (uintptr_t)indices;

    if (!ctx) {
        return;
    }

    if (count < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (count == 0) {
        return;
    }

    if (mode != GL_TRIANGLES) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (type != GL_UNSIGNED_BYTE &&
        type != GL_UNSIGNED_SHORT &&
        type != GL_UNSIGNED_INT) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (!gl_backend_validate_draw_state(ctx, true, &program, &vertex_array)) {
        return;
    }

    element_buffer = gl_backend_find_buffer(ctx, vertex_array->element_array_buffer_name);
    if (!element_buffer) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    for (GLsizei element = 0; element + 2 < count; element += 3) {
        GLuint index0;
        GLuint index1;
        GLuint index2;
        GLBackendVertex triangle[3];

        if (!gl_backend_read_element_index(element_buffer, type, index_offset, element + 0, &index0) ||
            !gl_backend_read_element_index(element_buffer, type, index_offset, element + 1, &index1) ||
            !gl_backend_read_element_index(element_buffer, type, index_offset, element + 2, &index2)) {
            gl_backend_set_error(ctx, GL_INVALID_OPERATION);
            return;
        }

        if (!gl_backend_fetch_vertex(ctx, program, vertex_array, (GLint)index0, &triangle[0]) ||
            !gl_backend_fetch_vertex(ctx, program, vertex_array, (GLint)index1, &triangle[1]) ||
            !gl_backend_fetch_vertex(ctx, program, vertex_array, (GLint)index2, &triangle[2])) {
            return;
        }

        gl_backend_rasterize_triangle(ctx, program, &triangle[0], &triangle[1], &triangle[2]);
    }
}

static void gl_backend_draw_range_elements(GLenum mode,
                                           GLuint start,
                                           GLuint end,
                                           GLsizei count,
                                           GLenum type,
                                           const void *indices)
{
    if (end < start) {
        AO46BackendContextRef ctx = gl_backend_current_context();
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_draw_elements(mode, count, type, indices);
}

static const GLubyte *gl_backend_get_string(GLenum name)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return NULL;
    }

    switch (name) {
        case GL_VENDOR:
            return kGLVendorString;
        case GL_RENDERER:
            return kGLRendererString;
        case GL_VERSION:
            return kGLVersionString;
        case GL_SHADING_LANGUAGE_VERSION:
            return kGLSLVersionString;
        case GL_EXTENSIONS:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return NULL;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return NULL;
    }
}

static const GLubyte *gl_backend_get_string_i(GLenum name, GLuint index)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return NULL;
    }

    if (name != GL_EXTENSIONS) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return NULL;
    }

    if (index != 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return NULL;
    }

    gl_backend_set_error(ctx, GL_INVALID_VALUE);
    return NULL;
}

static void gl_backend_pixel_store_i(GLenum pname, GLint param)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if (!gl_backend_valid_pixel_alignment(param)) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    switch (pname) {
        case GL_PACK_ALIGNMENT:
            ctx->core.state.pack_alignment = param;
            return;
        case GL_UNPACK_ALIGNMENT:
            ctx->core.state.unpack_alignment = param;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return;
    }
}

static void gl_backend_pixel_store_f(GLenum pname, GLfloat param)
{
    GLint integral = (GLint)param;

    if ((GLfloat)integral != param) {
        AO46BackendContextRef ctx = gl_backend_current_context();
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    gl_backend_pixel_store_i(pname, integral);
}

static GLenum gl_backend_get_error(void)
{
    AO46BackendContextRef ctx = gl_backend_current_context();
    GLenum error_code;

    if (!ctx) {
        return GL_INVALID_OPERATION;
    }

    error_code = ctx->core.state.error_code;
    ctx->core.state.error_code = GL_NO_ERROR;
    return error_code;
}

static void gl_backend_get_integer_v(GLenum pname, GLint *data)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !data) {
        return;
    }

    switch (pname) {
        case GL_MAJOR_VERSION:
            data[0] = 4;
            return;
        case GL_MINOR_VERSION:
            data[0] = 6;
            return;
        case GL_ACTIVE_TEXTURE:
            data[0] = (GLint)(GL_TEXTURE0 + ctx->active_texture_unit_index);
            return;
        case GL_CONTEXT_PROFILE_MASK:
            data[0] = GL_CONTEXT_CORE_PROFILE_BIT;
            return;
        case GL_NUM_EXTENSIONS:
            data[0] = 0;
            return;
        case GL_VIEWPORT:
            memcpy(data, ctx->core.state.viewport, sizeof(ctx->core.state.viewport));
            return;
        case GL_SCISSOR_BOX:
            memcpy(data, ctx->core.state.scissor_box, sizeof(ctx->core.state.scissor_box));
            return;
        case GL_READ_BUFFER:
            data[0] = (GLint)ctx->core.state.read_buffer;
            return;
        case GL_DRAW_BUFFER:
            data[0] = (GLint)ctx->core.state.draw_buffer;
            return;
        case GL_CURRENT_PROGRAM:
            data[0] = (GLint)ctx->current_program_name;
            return;
        case GL_ARRAY_BUFFER_BINDING:
            data[0] = (GLint)ctx->array_buffer_binding;
            return;
        case GL_PACK_ALIGNMENT:
            data[0] = ctx->core.state.pack_alignment;
            return;
        case GL_UNPACK_ALIGNMENT:
            data[0] = ctx->core.state.unpack_alignment;
            return;
        case GL_TEXTURE_BINDING_2D:
            data[0] = (GLint)ctx->texture_units[ctx->active_texture_unit_index].texture_2d_name;
            return;
        case GL_ELEMENT_ARRAY_BUFFER_BINDING: {
            GLBackendVertexArray *vertex_array = gl_backend_find_vertex_array(ctx, ctx->current_vertex_array_name);
            data[0] = vertex_array ? (GLint)vertex_array->element_array_buffer_name : 0;
            return;
        }
        case GL_VERTEX_ARRAY_BINDING:
            data[0] = (GLint)ctx->current_vertex_array_name;
            return;
        case GL_MAX_SAMPLES:
            data[0] = ctx->core.state.max_samples;
            return;
        case GL_MAX_TEXTURE_SIZE:
            data[0] = ctx->core.state.max_texture_size;
            return;
        case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:
        case GL_MAX_TEXTURE_IMAGE_UNITS:
            data[0] = GL_DRIVER_MAX_TEXTURE_UNITS;
            return;
        case GL_MAX_VERTEX_ATTRIBS:
            data[0] = ctx->core.state.max_vertex_attribs;
            return;
        case GL_IMPLEMENTATION_COLOR_READ_FORMAT:
            data[0] = GL_RGBA;
            return;
        case GL_IMPLEMENTATION_COLOR_READ_TYPE:
            data[0] = GL_UNSIGNED_BYTE;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            data[0] = 0;
            return;
    }
}

static void gl_backend_get_boolean_v(GLenum pname, GLboolean *data)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx || !data) {
        return;
    }

    switch (pname) {
        case GL_COLOR_WRITEMASK:
            memcpy(data, ctx->core.state.color_mask, sizeof(ctx->core.state.color_mask));
            return;
        case GL_DEPTH_WRITEMASK:
            data[0] = ctx->core.state.depth_mask;
            return;
        case GL_SCISSOR_TEST:
            data[0] = ctx->core.state.scissor_test;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            data[0] = GL_FALSE;
            return;
    }
}

static void gl_backend_viewport(GLint x, GLint y, GLsizei width, GLsizei height)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if (width < 0 || height < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    ctx->core.state.viewport[0] = x;
    ctx->core.state.viewport[1] = y;
    ctx->core.state.viewport[2] = width;
    ctx->core.state.viewport[3] = height;
}

static void gl_backend_scissor(GLint x, GLint y, GLsizei width, GLsizei height)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if (width < 0 || height < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    ctx->core.state.scissor_box[0] = x;
    ctx->core.state.scissor_box[1] = y;
    ctx->core.state.scissor_box[2] = width;
    ctx->core.state.scissor_box[3] = height;
}

static void gl_backend_enable(GLenum cap)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    switch (cap) {
        case GL_SCISSOR_TEST:
            ctx->core.state.scissor_test = GL_TRUE;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return;
    }
}

static void gl_backend_disable(GLenum cap)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    switch (cap) {
        case GL_SCISSOR_TEST:
            ctx->core.state.scissor_test = GL_FALSE;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return;
    }
}

static GLboolean gl_backend_is_enabled(GLenum cap)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return GL_FALSE;
    }

    switch (cap) {
        case GL_SCISSOR_TEST:
            return ctx->core.state.scissor_test;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return GL_FALSE;
    }
}

static void gl_backend_clear_color(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    ctx->core.state.clear_color[0] = gl_backend_clampf(red);
    ctx->core.state.clear_color[1] = gl_backend_clampf(green);
    ctx->core.state.clear_color[2] = gl_backend_clampf(blue);
    ctx->core.state.clear_color[3] = gl_backend_clampf(alpha);
}

static void gl_backend_clear_depth(GLdouble depth)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    ctx->core.state.clear_depth = gl_backend_clampd(depth);
}

static void gl_backend_clear_stencil(GLint stencil)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    ctx->core.state.clear_stencil = stencil;
}

static void gl_backend_color_mask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    ctx->core.state.color_mask[0] = red ? GL_TRUE : GL_FALSE;
    ctx->core.state.color_mask[1] = green ? GL_TRUE : GL_FALSE;
    ctx->core.state.color_mask[2] = blue ? GL_TRUE : GL_FALSE;
    ctx->core.state.color_mask[3] = alpha ? GL_TRUE : GL_FALSE;
}

static void gl_backend_depth_mask(GLboolean flag)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    ctx->core.state.depth_mask = flag ? GL_TRUE : GL_FALSE;
}

static void gl_backend_clear(GLbitfield mask)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if ((mask & ~(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) != 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if ((mask & GL_COLOR_BUFFER_BIT) != 0) {
        gl_backend_clear_color_buffer(ctx);
    }
}

static void gl_backend_read_buffer(GLenum mode)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    switch (mode) {
        case GL_FRONT:
        case GL_BACK:
        case GL_FRONT_LEFT:
        case GL_BACK_LEFT:
            ctx->core.state.read_buffer = mode;
            return;
        default:
            gl_backend_set_error(ctx, GL_INVALID_ENUM);
            return;
    }
}

static void gl_backend_read_pixels(GLint x,
                                   GLint y,
                                   GLsizei width,
                                   GLsizei height,
                                   GLenum format,
                                   GLenum type,
                                   void *pixels)
{
    AO46BackendContextRef ctx = gl_backend_current_context();

    if (!ctx) {
        return;
    }

    if (width < 0 || height < 0) {
        gl_backend_set_error(ctx, GL_INVALID_VALUE);
        return;
    }

    if (!pixels) {
        gl_backend_set_error(ctx, GL_INVALID_OPERATION);
        return;
    }

    if (format != GL_RGBA && format != GL_BGRA) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (type != GL_UNSIGNED_BYTE) {
        gl_backend_set_error(ctx, GL_INVALID_ENUM);
        return;
    }

    if (!gl_backend_has_drawable_storage(ctx)) {
        memset(pixels,
               0,
               gl_backend_aligned_row_stride(width, 4u, ctx->core.state.pack_alignment) * (size_t)height);
        return;
    }

    for (GLint row = 0; row < height; ++row) {
        uint8_t *dst_row = (uint8_t *)pixels +
                           (size_t)row * gl_backend_aligned_row_stride(width, 4u, ctx->core.state.pack_alignment);
        GLint src_y = y + row;

        for (GLint col = 0; col < width; ++col) {
            GLint src_x = x + col;
            uint8_t *dst_pixel = dst_row + (size_t)col * 4u;

            if (src_x < 0 ||
                src_y < 0 ||
                src_x >= ctx->drawable_width ||
                src_y >= ctx->drawable_height) {
                memset(dst_pixel, 0, 4u);
                continue;
            }

            gl_backend_read_bgra8_pixel(
                ctx->drawable_storage + (size_t)src_y * (size_t)ctx->drawable_rowbytes + (size_t)src_x * 4u,
                format,
                dst_pixel
            );
        }
    }
}

static void gl_backend_flush(void)
{
}

static void gl_backend_finish(void)
{
}

CGLError AO46BackendEnsureReady(void)
{
    return kCGLNoError;
}

AO46BackendContextRef AO46BackendCreateContext(GLenum color_format,
                                               GLenum color_type,
                                               GLenum depth_format,
                                               GLenum depth_type,
                                               GLenum stencil_format,
                                               GLenum stencil_type)
{
    AO46BackendContextRef ctx = calloc(1, sizeof(*ctx));

    if (!ctx) {
        return NULL;
    }

    GLDriverInitializeContext(&ctx->core,
                              color_format,
                              color_type,
                              depth_format,
                              depth_type,
                              stencil_format,
                              stencil_type);
    return ctx;
}

void AO46BackendDestroyContext(AO46BackendContextRef ctx)
{
    if (!ctx) {
        return;
    }

    if (g_backend_current_context == ctx) {
        g_backend_current_context = NULL;
    }

    while (ctx->programs) {
        gl_backend_remove_program(ctx, ctx->programs);
    }
    while (ctx->shaders) {
        gl_backend_remove_shader(ctx, ctx->shaders);
    }
    while (ctx->buffers) {
        gl_backend_remove_buffer(ctx, ctx->buffers);
    }
    while (ctx->vertex_arrays) {
        gl_backend_remove_vertex_array(ctx, ctx->vertex_arrays);
    }
    while (ctx->textures) {
        gl_backend_remove_texture(ctx, ctx->textures);
    }

    AO46BackendReleaseDrawable(ctx);
    free(ctx);
}

void AO46BackendSetCurrentContext(AO46BackendContextRef ctx)
{
    g_backend_current_context = ctx;
}

AO46BackendContextRef AO46BackendGetCurrentContext(void)
{
    return g_backend_current_context;
}

CGLError AO46BackendCreateHeadlessDrawable(AO46BackendContextRef ctx, void **out_renderer)
{
    if (!ctx || !out_renderer) {
        return !out_renderer ? kCGLBadAddress : kCGLBadContext;
    }

    ctx->core.metal.object = &ctx->core;
    ctx->core.metal.view = NULL;
    ctx->renderer_handle = ctx->core.metal.object;
    ctx->window_handle = NULL;
    ctx->headless = true;
    *out_renderer = ctx->renderer_handle;
    return kCGLNoError;
}

CGLError AO46BackendCreateWindowDrawable(AO46BackendContextRef ctx, void *window, void **out_renderer)
{
    if (!ctx) {
        return kCGLBadContext;
    }

    if (!window) {
        return kCGLBadDrawable;
    }

    if (!out_renderer) {
        return kCGLBadAddress;
    }

    ctx->core.metal.object = window;
    ctx->core.metal.view = window;
    ctx->renderer_handle = window;
    ctx->window_handle = window;
    ctx->headless = false;
    *out_renderer = ctx->renderer_handle;
    return kCGLNoError;
}

CGLError AO46BackendBindOffscreenStorage(AO46BackendContextRef ctx,
                                         void *baseaddr,
                                         GLsizei width,
                                         GLsizei height,
                                         GLint rowbytes)
{
    if (!ctx) {
        return kCGLBadContext;
    }

    if (!baseaddr || width <= 0 || height <= 0 || rowbytes < (GLint)(width * 4)) {
        return kCGLBadOffScreen;
    }

    ctx->drawable_storage = baseaddr;
    ctx->drawable_width = width;
    ctx->drawable_height = height;
    ctx->drawable_rowbytes = rowbytes;
    if (ctx->core.state.viewport[2] == 0 && ctx->core.state.viewport[3] == 0) {
        ctx->core.state.viewport[2] = width;
        ctx->core.state.viewport[3] = height;
    }
    if (ctx->core.state.scissor_box[2] == 0 && ctx->core.state.scissor_box[3] == 0) {
        ctx->core.state.scissor_box[2] = width;
        ctx->core.state.scissor_box[3] = height;
    }
    return kCGLNoError;
}

void AO46BackendReleaseDrawable(AO46BackendContextRef ctx)
{
    if (!ctx) {
        return;
    }

    ctx->core.metal.object = NULL;
    ctx->core.metal.view = NULL;
    ctx->renderer_handle = NULL;
    ctx->window_handle = NULL;
    ctx->drawable_storage = NULL;
    ctx->drawable_width = 0;
    ctx->drawable_height = 0;
    ctx->drawable_rowbytes = 0;
    ctx->headless = false;
}

void AO46BackendSwapBuffers(AO46BackendContextRef ctx)
{
    (void)ctx;
}

CGLError AO46BackendTexImagePBuffer(AO46BackendContextRef ctx,
                                    const void *storage,
                                    GLsizei width,
                                    GLsizei height,
                                    GLint rowbytes,
                                    GLenum target,
                                    GLenum internal_format,
                                    GLenum source)
{
    GLBackendTexture *texture;

    if (!ctx) {
        return kCGLBadContext;
    }

    if (!storage || width <= 0 || height <= 0 || rowbytes < (GLint)(width * 4)) {
        return kCGLBadValue;
    }

    if (target != GL_TEXTURE_2D) {
        return kCGLBadValue;
    }

    switch (source) {
        case GL_FRONT:
        case GL_BACK:
        case GL_FRONT_LEFT:
        case GL_BACK_LEFT:
            break;
        default:
            return kCGLBadValue;
    }

    texture = gl_backend_bound_texture(ctx, target);
    if (!texture) {
        return kCGLNoError;
    }

    if (!texture->data || texture->width != width || texture->height != height) {
        uint8_t *new_storage = calloc((size_t)width * (size_t)height, 4u);

        if (!new_storage) {
            return kCGLBadAlloc;
        }

        free(texture->data);
        texture->data = new_storage;
    }

    for (GLsizei y = 0; y < height; ++y) {
        memcpy(texture->data + (size_t)y * (size_t)width * 4u,
               (const uint8_t *)storage + (size_t)y * (size_t)rowbytes,
               (size_t)width * 4u);
    }

    texture->defined = GL_TRUE;
    texture->width = width;
    texture->height = height;
    texture->internal_format = internal_format == 0 ? GL_RGBA8 : (GLint)internal_format;
    return kCGLNoError;
}

void *AO46BackendCustomProcAddress(const char *procname)
{
    if (!procname) {
        return NULL;
    }

    if (strcmp(procname, "glCreateShader") == 0) {
        return (void *)gl_backend_create_shader;
    }
    if (strcmp(procname, "glShaderSource") == 0) {
        return (void *)gl_backend_shader_source;
    }
    if (strcmp(procname, "glCompileShader") == 0) {
        return (void *)gl_backend_compile_shader;
    }
    if (strcmp(procname, "glGetShaderiv") == 0) {
        return (void *)gl_backend_get_shader_iv;
    }
    if (strcmp(procname, "glGetShaderInfoLog") == 0) {
        return (void *)gl_backend_get_shader_info_log;
    }
    if (strcmp(procname, "glDeleteShader") == 0) {
        return (void *)gl_backend_delete_shader;
    }
    if (strcmp(procname, "glIsShader") == 0) {
        return (void *)gl_backend_is_shader;
    }
    if (strcmp(procname, "glCreateProgram") == 0) {
        return (void *)gl_backend_create_program;
    }
    if (strcmp(procname, "glGenTextures") == 0) {
        return (void *)gl_backend_gen_textures;
    }
    if (strcmp(procname, "glDeleteTextures") == 0) {
        return (void *)gl_backend_delete_textures;
    }
    if (strcmp(procname, "glIsTexture") == 0) {
        return (void *)gl_backend_is_texture;
    }
    if (strcmp(procname, "glActiveTexture") == 0) {
        return (void *)gl_backend_active_texture;
    }
    if (strcmp(procname, "glBindTexture") == 0) {
        return (void *)gl_backend_bind_texture;
    }
    if (strcmp(procname, "glPixelStoref") == 0) {
        return (void *)gl_backend_pixel_store_f;
    }
    if (strcmp(procname, "glPixelStorei") == 0) {
        return (void *)gl_backend_pixel_store_i;
    }
    if (strcmp(procname, "glTexParameteri") == 0) {
        return (void *)gl_backend_tex_parameter_i;
    }
    if (strcmp(procname, "glGetTexParameteriv") == 0) {
        return (void *)gl_backend_get_tex_parameter_iv;
    }
    if (strcmp(procname, "glTexImage2D") == 0) {
        return (void *)gl_backend_tex_image_2d;
    }
    if (strcmp(procname, "glTexSubImage2D") == 0) {
        return (void *)gl_backend_tex_sub_image_2d;
    }
    if (strcmp(procname, "glGetTexLevelParameteriv") == 0) {
        return (void *)gl_backend_get_tex_level_parameter_iv;
    }
    if (strcmp(procname, "glGetTexImage") == 0) {
        return (void *)gl_backend_get_tex_image;
    }
    if (strcmp(procname, "glAttachShader") == 0) {
        return (void *)gl_backend_attach_shader;
    }
    if (strcmp(procname, "glDetachShader") == 0) {
        return (void *)gl_backend_detach_shader;
    }
    if (strcmp(procname, "glBindAttribLocation") == 0) {
        return (void *)gl_backend_bind_attrib_location;
    }
    if (strcmp(procname, "glLinkProgram") == 0) {
        return (void *)gl_backend_link_program;
    }
    if (strcmp(procname, "glUseProgram") == 0) {
        return (void *)gl_backend_use_program;
    }
    if (strcmp(procname, "glValidateProgram") == 0) {
        return (void *)gl_backend_validate_program;
    }
    if (strcmp(procname, "glGetProgramiv") == 0) {
        return (void *)gl_backend_get_program_iv;
    }
    if (strcmp(procname, "glGetProgramInfoLog") == 0) {
        return (void *)gl_backend_get_program_info_log;
    }
    if (strcmp(procname, "glGetAttribLocation") == 0) {
        return (void *)gl_backend_get_attrib_location;
    }
    if (strcmp(procname, "glGetUniformLocation") == 0) {
        return (void *)gl_backend_get_uniform_location;
    }
    if (strcmp(procname, "glUniform1i") == 0) {
        return (void *)gl_backend_uniform_1i;
    }
    if (strcmp(procname, "glDeleteProgram") == 0) {
        return (void *)gl_backend_delete_program;
    }
    if (strcmp(procname, "glIsProgram") == 0) {
        return (void *)gl_backend_is_program;
    }
    if (strcmp(procname, "glGenBuffers") == 0) {
        return (void *)gl_backend_gen_buffers;
    }
    if (strcmp(procname, "glDeleteBuffers") == 0) {
        return (void *)gl_backend_delete_buffers;
    }
    if (strcmp(procname, "glIsBuffer") == 0) {
        return (void *)gl_backend_is_buffer;
    }
    if (strcmp(procname, "glBindBuffer") == 0) {
        return (void *)gl_backend_bind_buffer;
    }
    if (strcmp(procname, "glBufferData") == 0) {
        return (void *)gl_backend_buffer_data;
    }
    if (strcmp(procname, "glBufferSubData") == 0) {
        return (void *)gl_backend_buffer_sub_data;
    }
    if (strcmp(procname, "glGetBufferParameteriv") == 0) {
        return (void *)gl_backend_get_buffer_parameter_iv;
    }
    if (strcmp(procname, "glGenVertexArrays") == 0) {
        return (void *)gl_backend_gen_vertex_arrays;
    }
    if (strcmp(procname, "glDeleteVertexArrays") == 0) {
        return (void *)gl_backend_delete_vertex_arrays;
    }
    if (strcmp(procname, "glIsVertexArray") == 0) {
        return (void *)gl_backend_is_vertex_array;
    }
    if (strcmp(procname, "glBindVertexArray") == 0) {
        return (void *)gl_backend_bind_vertex_array;
    }
    if (strcmp(procname, "glEnableVertexAttribArray") == 0) {
        return (void *)gl_backend_enable_vertex_attrib_array;
    }
    if (strcmp(procname, "glDisableVertexAttribArray") == 0) {
        return (void *)gl_backend_disable_vertex_attrib_array;
    }
    if (strcmp(procname, "glVertexAttribPointer") == 0) {
        return (void *)gl_backend_vertex_attrib_pointer;
    }
    if (strcmp(procname, "glDrawArrays") == 0) {
        return (void *)gl_backend_draw_arrays;
    }
    if (strcmp(procname, "glDrawElements") == 0) {
        return (void *)gl_backend_draw_elements;
    }
    if (strcmp(procname, "glDrawRangeElements") == 0) {
        return (void *)gl_backend_draw_range_elements;
    }
    if (strcmp(procname, "glGetString") == 0) {
        return (void *)gl_backend_get_string;
    }
    if (strcmp(procname, "glGetStringi") == 0) {
        return (void *)gl_backend_get_string_i;
    }
    if (strcmp(procname, "glGetError") == 0) {
        return (void *)gl_backend_get_error;
    }
    if (strcmp(procname, "glGetIntegerv") == 0) {
        return (void *)gl_backend_get_integer_v;
    }
    if (strcmp(procname, "glGetBooleanv") == 0) {
        return (void *)gl_backend_get_boolean_v;
    }
    if (strcmp(procname, "glViewport") == 0) {
        return (void *)gl_backend_viewport;
    }
    if (strcmp(procname, "glScissor") == 0) {
        return (void *)gl_backend_scissor;
    }
    if (strcmp(procname, "glEnable") == 0) {
        return (void *)gl_backend_enable;
    }
    if (strcmp(procname, "glDisable") == 0) {
        return (void *)gl_backend_disable;
    }
    if (strcmp(procname, "glIsEnabled") == 0) {
        return (void *)gl_backend_is_enabled;
    }
    if (strcmp(procname, "glClearColor") == 0) {
        return (void *)gl_backend_clear_color;
    }
    if (strcmp(procname, "glClearDepth") == 0) {
        return (void *)gl_backend_clear_depth;
    }
    if (strcmp(procname, "glClearStencil") == 0) {
        return (void *)gl_backend_clear_stencil;
    }
    if (strcmp(procname, "glColorMask") == 0) {
        return (void *)gl_backend_color_mask;
    }
    if (strcmp(procname, "glDepthMask") == 0) {
        return (void *)gl_backend_depth_mask;
    }
    if (strcmp(procname, "glClear") == 0) {
        return (void *)gl_backend_clear;
    }
    if (strcmp(procname, "glReadBuffer") == 0) {
        return (void *)gl_backend_read_buffer;
    }
    if (strcmp(procname, "glReadPixels") == 0) {
        return (void *)gl_backend_read_pixels;
    }
    if (strcmp(procname, "glFlush") == 0) {
        return (void *)gl_backend_flush;
    }
    if (strcmp(procname, "glFinish") == 0) {
        return (void *)gl_backend_finish;
    }

    return NULL;
}

void *AO46BackendGetProcAddress(const char *procname)
{
    return AO46GL2MTLLookupProcAddress(procname);
}

const char *AO46BackendIdentity(void)
{
    return "libgl2mtl.dylib";
}
