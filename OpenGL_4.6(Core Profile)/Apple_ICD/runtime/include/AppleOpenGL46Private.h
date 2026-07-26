#ifndef APPLE_OPENGL46_PRIVATE_H
#define APPLE_OPENGL46_PRIVATE_H

#include <stdbool.h>

#include "AppleOpenGL46Runtime.h"

struct st_context;
struct pipe_context;
struct pipe_surface;
struct pipe_resource;
struct AO46MesaDrawable;

struct AO46ContextRec {
    GLuint retain_count;
    AO46PixelFormatRef pixel_format;
    AO46ShareGroupRef share_group;
    AO46PBufferRef pbuffer;
    void *renderer_handle;
    void *window_handle;
    void *offscreen_baseaddr;
    AO46DrawableKind drawable_kind;
    GLint virtual_screen;
    GLuint fullscreen_display_mask;
    GLsizei offscreen_width;
    GLsizei offscreen_height;
    GLint offscreen_rowbytes;
    GLenum pbuffer_face;
    GLint pbuffer_level;
    GLint pbuffer_screen;
    struct st_context *st;
    struct pipe_context *pipe;
    struct pipe_surface *present_surface;
    struct pipe_resource *tex;
    struct AO46MesaDrawable *drawable;
    bool offscreen;
    void *metal_drawable;
};

struct AO46PBufferRec {
    GLuint retain_count;
    struct pipe_resource *tex;
    GLsizei width;
    GLsizei height;
    GLenum target;
    GLenum internal_format;
    GLint max_level;
};

#endif /* APPLE_OPENGL46_PRIVATE_H */
