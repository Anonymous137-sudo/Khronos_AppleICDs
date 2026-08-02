#ifndef APPLE_OPENGL46_PRIVATE_H
#define APPLE_OPENGL46_PRIVATE_H

#include <stdbool.h>
#include <pthread.h>

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
    GLint swap_rectangle[4];
    GLint swap_interval;
    GLint surface_order;
    GLint surface_opacity;
    GLint surface_backing_size[2];
    GLint surface_volatile;
    GLint swaps_in_flight;
    GLint abort_on_gpu_restart_denied;
    GLint context_priority_request;
    GLint swap_rectangle_enabled;
    GLint swap_limit_enabled;
    GLint rasterization_enabled;
    GLint state_validation_enabled;
    GLint surface_backing_size_enabled;
    GLint display_list_optimization_enabled;
    GLint mp_engine_enabled;
    GLint crash_on_removed_functions_enabled;
    struct st_context *st;
    struct pipe_context *pipe;
    struct pipe_surface *present_surface;
    struct pipe_resource *tex;
    struct AO46MesaDrawable *drawable;
    bool offscreen;
    void *metal_drawable;
    pthread_mutex_t lock;
    bool lock_initialized;
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
