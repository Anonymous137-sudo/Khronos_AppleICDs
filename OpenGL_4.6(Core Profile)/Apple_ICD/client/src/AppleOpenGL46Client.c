#include "AppleOpenGL46Client.h"

#include <stdbool.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    void *framework_handle;
    const char *loaded_path;
    CGLError (*ensure_runtime)(void);
    CGLError (*choose_pixel_format)(const CGLPixelFormatAttribute *, AO46PixelFormatRef *, GLint *);
    void (*destroy_pixel_format)(AO46PixelFormatRef);
    AO46PixelFormatRef (*retain_pixel_format)(AO46PixelFormatRef);
    GLuint (*get_pixel_format_retain_count)(AO46PixelFormatRef);
    CGLError (*describe_pixel_format)(AO46PixelFormatRef, GLint, CGLPixelFormatAttribute, GLint *);
    CGLError (*query_renderer_info)(GLuint, AO46RendererInfoRef *, GLint *);
    void (*destroy_renderer_info)(AO46RendererInfoRef);
    CGLError (*describe_renderer)(AO46RendererInfoRef, GLint, CGLRendererProperty, GLint *);
    CGLError (*create_context)(AO46PixelFormatRef, AO46ContextRef, AO46ContextRef *);
    CGLError (*copy_context)(AO46ContextRef, AO46ContextRef, GLbitfield);
    void (*destroy_context)(AO46ContextRef);
    AO46ContextRef (*retain_context)(AO46ContextRef);
    GLuint (*get_context_retain_count)(AO46ContextRef);
    AO46PixelFormatRef (*get_pixel_format_for_context)(AO46ContextRef);
    AO46ShareGroupRef (*get_share_group_for_context)(AO46ContextRef);
    CGLError (*create_pbuffer)(GLsizei, GLsizei, GLenum, GLenum, GLint, AO46PBufferRef *);
    void (*destroy_pbuffer)(AO46PBufferRef);
    AO46PBufferRef (*retain_pbuffer)(AO46PBufferRef);
    GLuint (*get_pbuffer_retain_count)(AO46PBufferRef);
    CGLError (*describe_pbuffer)(AO46PBufferRef, GLsizei *, GLsizei *, GLenum *, GLenum *, GLint *);
    CGLError (*tex_image_pbuffer)(AO46ContextRef, AO46PBufferRef, GLenum);
    CGLError (*set_offscreen)(AO46ContextRef, GLsizei, GLsizei, GLint, void *);
    CGLError (*get_offscreen)(AO46ContextRef, GLsizei *, GLsizei *, GLint *, void **);
    CGLError (*set_fullscreen)(AO46ContextRef);
    CGLError (*set_fullscreen_on_display)(AO46ContextRef, GLuint);
    CGLError (*set_pbuffer)(AO46ContextRef, AO46PBufferRef, GLenum, GLint, GLint);
    CGLError (*get_pbuffer)(AO46ContextRef, AO46PBufferRef *, GLenum *, GLint *, GLint *);
    CGLError (*set_current_context)(AO46ContextRef);
    AO46ContextRef (*get_current_context)(void);
    CGLError (*create_headless_drawable)(AO46ContextRef);
    CGLError (*attach_window_to_context)(AO46ContextRef, void *);
    CGLError (*clear_drawable)(AO46ContextRef);
    CGLError (*enable_context)(AO46ContextRef, CGLContextEnable);
    CGLError (*disable_context)(AO46ContextRef, CGLContextEnable);
    CGLError (*is_context_enabled)(AO46ContextRef, CGLContextEnable, GLint *);
    CGLError (*set_context_parameter)(AO46ContextRef, CGLContextParameter, const GLint *);
    CGLError (*get_context_parameter)(AO46ContextRef, CGLContextParameter, GLint *);
    CGLError (*set_virtual_screen)(AO46ContextRef, GLint);
    CGLError (*get_virtual_screen)(AO46ContextRef, GLint *);
    AO46DrawableKind (*get_drawable_kind)(AO46ContextRef);
    void *(*get_window_handle_for_context)(AO46ContextRef);
    CGLError (*update_context)(AO46ContextRef);
    CGLError (*flush_drawable)(AO46ContextRef);
    CGLError (*set_global_option)(CGLGlobalOption, const GLint *);
    CGLError (*get_global_option)(CGLGlobalOption, GLint *);
    CGLError (*lock_context)(AO46ContextRef);
    CGLError (*unlock_context)(AO46ContextRef);
    void *(*get_proc_address)(const char *);
    void *(*get_proc_address_bytes)(const GLubyte *);
} AO46FrameworkDispatch;

static AO46FrameworkDispatch g_framework;

static bool ao46_framework_has_required_exports(void)
{
    return g_framework.ensure_runtime &&
           g_framework.choose_pixel_format &&
           g_framework.destroy_pixel_format &&
           g_framework.retain_pixel_format &&
           g_framework.get_pixel_format_retain_count &&
           g_framework.describe_pixel_format &&
           g_framework.query_renderer_info &&
           g_framework.destroy_renderer_info &&
           g_framework.describe_renderer &&
           g_framework.create_context &&
           g_framework.copy_context &&
           g_framework.destroy_context &&
           g_framework.retain_context &&
           g_framework.get_context_retain_count &&
           g_framework.get_pixel_format_for_context &&
           g_framework.get_share_group_for_context &&
           g_framework.create_pbuffer &&
           g_framework.destroy_pbuffer &&
           g_framework.retain_pbuffer &&
           g_framework.get_pbuffer_retain_count &&
           g_framework.describe_pbuffer &&
           g_framework.tex_image_pbuffer &&
           g_framework.set_offscreen &&
           g_framework.get_offscreen &&
           g_framework.set_fullscreen &&
           g_framework.set_fullscreen_on_display &&
           g_framework.set_pbuffer &&
           g_framework.get_pbuffer &&
           g_framework.set_current_context &&
           g_framework.get_current_context &&
           g_framework.create_headless_drawable &&
           g_framework.attach_window_to_context &&
           g_framework.clear_drawable &&
           g_framework.enable_context &&
           g_framework.disable_context &&
           g_framework.is_context_enabled &&
           g_framework.set_context_parameter &&
           g_framework.get_context_parameter &&
           g_framework.set_virtual_screen &&
           g_framework.get_virtual_screen &&
           g_framework.get_drawable_kind &&
           g_framework.get_window_handle_for_context &&
           g_framework.update_context &&
           g_framework.flush_drawable &&
           g_framework.set_global_option &&
           g_framework.get_global_option &&
           g_framework.lock_context &&
           g_framework.unlock_context &&
           g_framework.get_proc_address;
}

static bool ao46_try_load_framework_candidate(const char *path)
{
    AO46FrameworkDispatch dispatch;

    if (!path || path[0] == '\0') {
        return false;
    }

    dispatch = (AO46FrameworkDispatch){ 0 };
    dispatch.framework_handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!dispatch.framework_handle) {
        return false;
    }

    dispatch.loaded_path = path;
    dispatch.ensure_runtime = dlsym(dispatch.framework_handle, "AO46EnsureRuntime");
    dispatch.choose_pixel_format = dlsym(dispatch.framework_handle, "AO46ChoosePixelFormat");
    dispatch.destroy_pixel_format = dlsym(dispatch.framework_handle, "AO46DestroyPixelFormat");
    dispatch.retain_pixel_format = dlsym(dispatch.framework_handle, "AO46RetainPixelFormat");
    dispatch.get_pixel_format_retain_count = dlsym(dispatch.framework_handle, "AO46GetPixelFormatRetainCount");
    dispatch.describe_pixel_format = dlsym(dispatch.framework_handle, "AO46DescribePixelFormat");
    dispatch.query_renderer_info = dlsym(dispatch.framework_handle, "AO46QueryRendererInfo");
    dispatch.destroy_renderer_info = dlsym(dispatch.framework_handle, "AO46DestroyRendererInfo");
    dispatch.describe_renderer = dlsym(dispatch.framework_handle, "AO46DescribeRenderer");
    dispatch.create_context = dlsym(dispatch.framework_handle, "AO46CreateContext");
    dispatch.copy_context = dlsym(dispatch.framework_handle, "AO46CopyContext");
    dispatch.destroy_context = dlsym(dispatch.framework_handle, "AO46DestroyContext");
    dispatch.retain_context = dlsym(dispatch.framework_handle, "AO46RetainContext");
    dispatch.get_context_retain_count = dlsym(dispatch.framework_handle, "AO46GetContextRetainCount");
    dispatch.get_pixel_format_for_context = dlsym(dispatch.framework_handle, "AO46GetPixelFormatForContext");
    dispatch.get_share_group_for_context = dlsym(dispatch.framework_handle, "AO46GetShareGroupForContext");
    dispatch.create_pbuffer = dlsym(dispatch.framework_handle, "AO46CreatePBuffer");
    dispatch.destroy_pbuffer = dlsym(dispatch.framework_handle, "AO46DestroyPBuffer");
    dispatch.retain_pbuffer = dlsym(dispatch.framework_handle, "AO46RetainPBuffer");
    dispatch.get_pbuffer_retain_count = dlsym(dispatch.framework_handle, "AO46GetPBufferRetainCount");
    dispatch.describe_pbuffer = dlsym(dispatch.framework_handle, "AO46DescribePBuffer");
    dispatch.tex_image_pbuffer = dlsym(dispatch.framework_handle, "AO46TexImagePBuffer");
    dispatch.set_offscreen = dlsym(dispatch.framework_handle, "AO46SetOffScreen");
    dispatch.get_offscreen = dlsym(dispatch.framework_handle, "AO46GetOffScreen");
    dispatch.set_fullscreen = dlsym(dispatch.framework_handle, "AO46SetFullScreen");
    dispatch.set_fullscreen_on_display = dlsym(dispatch.framework_handle, "AO46SetFullScreenOnDisplay");
    dispatch.set_pbuffer = dlsym(dispatch.framework_handle, "AO46SetPBuffer");
    dispatch.get_pbuffer = dlsym(dispatch.framework_handle, "AO46GetPBuffer");
    dispatch.set_current_context = dlsym(dispatch.framework_handle, "AO46SetCurrentContext");
    dispatch.get_current_context = dlsym(dispatch.framework_handle, "AO46GetCurrentContext");
    dispatch.create_headless_drawable = dlsym(dispatch.framework_handle, "AO46CreateHeadlessDrawable");
    dispatch.attach_window_to_context = dlsym(dispatch.framework_handle, "AO46AttachWindowToContext");
    dispatch.clear_drawable = dlsym(dispatch.framework_handle, "AO46ClearDrawable");
    dispatch.enable_context = dlsym(dispatch.framework_handle, "AO46EnableContext");
    dispatch.disable_context = dlsym(dispatch.framework_handle, "AO46DisableContext");
    dispatch.is_context_enabled = dlsym(dispatch.framework_handle, "AO46IsContextEnabled");
    dispatch.set_context_parameter = dlsym(dispatch.framework_handle, "AO46SetContextParameter");
    dispatch.get_context_parameter = dlsym(dispatch.framework_handle, "AO46GetContextParameter");
    dispatch.set_virtual_screen = dlsym(dispatch.framework_handle, "AO46SetVirtualScreen");
    dispatch.get_virtual_screen = dlsym(dispatch.framework_handle, "AO46GetVirtualScreen");
    dispatch.get_drawable_kind = dlsym(dispatch.framework_handle, "AO46GetDrawableKind");
    dispatch.get_window_handle_for_context = dlsym(dispatch.framework_handle, "AO46GetWindowHandleForContext");
    dispatch.update_context = dlsym(dispatch.framework_handle, "AO46UpdateContext");
    dispatch.flush_drawable = dlsym(dispatch.framework_handle, "AO46FlushDrawable");
    dispatch.set_global_option = dlsym(dispatch.framework_handle, "AO46SetGlobalOption");
    dispatch.get_global_option = dlsym(dispatch.framework_handle, "AO46GetGlobalOption");
    dispatch.lock_context = dlsym(dispatch.framework_handle, "AO46LockContext");
    dispatch.unlock_context = dlsym(dispatch.framework_handle, "AO46UnlockContext");
    dispatch.get_proc_address = dlsym(dispatch.framework_handle, "AO46GetProcAddress");
    dispatch.get_proc_address_bytes = dlsym(dispatch.framework_handle, "AO46GetProcAddressBytes");

    g_framework = dispatch;
    if (ao46_framework_has_required_exports()) {
        return true;
    }

    dlclose(g_framework.framework_handle);
    g_framework = (AO46FrameworkDispatch){ 0 };
    return false;
}

CGLError AO46ClientEnsureFramework(void)
{
    const char *env_path = getenv("AO46_FRAMEWORK_PATH");
    const char *candidates[] = {
        env_path,
        "/System/Library/Frameworks/OpenGL_4.6.framework/OpenGL_4.6",
        "./OpenGL_4.6.framework/OpenGL_4.6"
    };
    size_t i;

    if (g_framework.framework_handle) {
        if (!g_framework.ensure_runtime) {
            return kCGLBadConnection;
        }
        return g_framework.ensure_runtime();
    }

    for (i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        if (ao46_try_load_framework_candidate(candidates[i])) {
            fprintf(stderr, "AO46 client: loaded framework driver from %s\n", g_framework.loaded_path);
            return g_framework.ensure_runtime();
        }
    }

    fprintf(stderr, "AO46 client: failed to load OpenGL_4.6.framework\n");
    return kCGLBadConnection;
}

CGLError AO46ClientChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                                     AO46PixelFormatRef *out_pix,
                                     GLint *out_npix)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.choose_pixel_format(attribs, out_pix, out_npix);
}

void AO46ClientDestroyPixelFormat(AO46PixelFormatRef pix)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.destroy_pixel_format) {
        return;
    }
    g_framework.destroy_pixel_format(pix);
}

AO46PixelFormatRef AO46ClientRetainPixelFormat(AO46PixelFormatRef pix)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.retain_pixel_format) {
        return NULL;
    }
    return g_framework.retain_pixel_format(pix);
}

GLuint AO46ClientGetPixelFormatRetainCount(AO46PixelFormatRef pix)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_pixel_format_retain_count) {
        return 0;
    }
    return g_framework.get_pixel_format_retain_count(pix);
}

CGLError AO46ClientDescribePixelFormat(AO46PixelFormatRef pix,
                                       GLint pix_num,
                                       CGLPixelFormatAttribute attrib,
                                       GLint *value)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.describe_pixel_format(pix, pix_num, attrib, value);
}

CGLError AO46ClientQueryRendererInfo(GLuint display_mask,
                                     AO46RendererInfoRef *out_rend,
                                     GLint *out_nrend)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.query_renderer_info(display_mask, out_rend, out_nrend);
}

void AO46ClientDestroyRendererInfo(AO46RendererInfoRef rend)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.destroy_renderer_info) {
        return;
    }
    g_framework.destroy_renderer_info(rend);
}

CGLError AO46ClientDescribeRenderer(AO46RendererInfoRef rend,
                                    GLint rend_num,
                                    CGLRendererProperty prop,
                                    GLint *value)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.describe_renderer(rend, rend_num, prop, value);
}

CGLError AO46ClientCreateContext(AO46PixelFormatRef pix,
                                 AO46ContextRef share,
                                 AO46ContextRef *out_ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.create_context(pix, share, out_ctx);
}

CGLError AO46ClientCopyContext(AO46ContextRef src, AO46ContextRef dst, GLbitfield mask)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.copy_context(src, dst, mask);
}

void AO46ClientDestroyContext(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.destroy_context) {
        return;
    }
    g_framework.destroy_context(ctx);
}

AO46ContextRef AO46ClientRetainContext(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.retain_context) {
        return NULL;
    }
    return g_framework.retain_context(ctx);
}

GLuint AO46ClientGetContextRetainCount(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_context_retain_count) {
        return 0;
    }
    return g_framework.get_context_retain_count(ctx);
}

AO46PixelFormatRef AO46ClientGetPixelFormatForContext(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_pixel_format_for_context) {
        return NULL;
    }
    return g_framework.get_pixel_format_for_context(ctx);
}

AO46ShareGroupRef AO46ClientGetShareGroupForContext(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_share_group_for_context) {
        return NULL;
    }
    return g_framework.get_share_group_for_context(ctx);
}

CGLError AO46ClientCreatePBuffer(GLsizei width,
                                 GLsizei height,
                                 GLenum target,
                                 GLenum internal_format,
                                 GLint max_level,
                                 AO46PBufferRef *out_pbuffer)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.create_pbuffer(width, height, target, internal_format, max_level, out_pbuffer);
}

void AO46ClientDestroyPBuffer(AO46PBufferRef pbuffer)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.destroy_pbuffer) {
        return;
    }
    g_framework.destroy_pbuffer(pbuffer);
}

AO46PBufferRef AO46ClientRetainPBuffer(AO46PBufferRef pbuffer)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.retain_pbuffer) {
        return NULL;
    }
    return g_framework.retain_pbuffer(pbuffer);
}

GLuint AO46ClientGetPBufferRetainCount(AO46PBufferRef pbuffer)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_pbuffer_retain_count) {
        return 0;
    }
    return g_framework.get_pbuffer_retain_count(pbuffer);
}

CGLError AO46ClientDescribePBuffer(AO46PBufferRef pbuffer,
                                   GLsizei *width,
                                   GLsizei *height,
                                   GLenum *target,
                                   GLenum *internal_format,
                                   GLint *mipmap)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.describe_pbuffer(pbuffer, width, height, target, internal_format, mipmap);
}

CGLError AO46ClientTexImagePBuffer(AO46ContextRef ctx, AO46PBufferRef pbuffer, GLenum source)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.tex_image_pbuffer(ctx, pbuffer, source);
}

CGLError AO46ClientSetOffScreen(AO46ContextRef ctx,
                                GLsizei width,
                                GLsizei height,
                                GLint rowbytes,
                                void *baseaddr)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_offscreen(ctx, width, height, rowbytes, baseaddr);
}

CGLError AO46ClientGetOffScreen(AO46ContextRef ctx,
                                GLsizei *width,
                                GLsizei *height,
                                GLint *rowbytes,
                                void **baseaddr)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.get_offscreen(ctx, width, height, rowbytes, baseaddr);
}

CGLError AO46ClientSetFullScreen(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_fullscreen(ctx);
}

CGLError AO46ClientSetFullScreenOnDisplay(AO46ContextRef ctx, GLuint display_mask)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_fullscreen_on_display(ctx, display_mask);
}

CGLError AO46ClientSetPBuffer(AO46ContextRef ctx,
                              AO46PBufferRef pbuffer,
                              GLenum face,
                              GLint level,
                              GLint screen)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_pbuffer(ctx, pbuffer, face, level, screen);
}

CGLError AO46ClientGetPBuffer(AO46ContextRef ctx,
                              AO46PBufferRef *pbuffer,
                              GLenum *face,
                              GLint *level,
                              GLint *screen)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.get_pbuffer(ctx, pbuffer, face, level, screen);
}

CGLError AO46ClientSetCurrentContext(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_current_context(ctx);
}

AO46ContextRef AO46ClientGetCurrentContext(void)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_current_context) {
        return NULL;
    }
    return g_framework.get_current_context();
}

CGLError AO46ClientCreateHeadlessDrawable(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.create_headless_drawable(ctx);
}

CGLError AO46ClientAttachWindowToContext(AO46ContextRef ctx, void *window)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.attach_window_to_context(ctx, window);
}

CGLError AO46ClientClearDrawable(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.clear_drawable(ctx);
}

CGLError AO46ClientEnableContext(AO46ContextRef ctx, CGLContextEnable pname)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.enable_context(ctx, pname);
}

CGLError AO46ClientDisableContext(AO46ContextRef ctx, CGLContextEnable pname)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.disable_context(ctx, pname);
}

CGLError AO46ClientIsContextEnabled(AO46ContextRef ctx, CGLContextEnable pname, GLint *enable)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.is_context_enabled(ctx, pname, enable);
}

CGLError AO46ClientSetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, const GLint *params)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_context_parameter(ctx, pname, params);
}

CGLError AO46ClientGetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, GLint *params)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.get_context_parameter(ctx, pname, params);
}

CGLError AO46ClientSetVirtualScreen(AO46ContextRef ctx, GLint screen)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_virtual_screen(ctx, screen);
}

CGLError AO46ClientGetVirtualScreen(AO46ContextRef ctx, GLint *screen)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.get_virtual_screen(ctx, screen);
}

AO46DrawableKind AO46ClientGetDrawableKind(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_drawable_kind) {
        return AO46DrawableKindNone;
    }
    return g_framework.get_drawable_kind(ctx);
}

void *AO46ClientGetWindowHandleForContext(AO46ContextRef ctx)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_window_handle_for_context) {
        return NULL;
    }
    return g_framework.get_window_handle_for_context(ctx);
}

CGLError AO46ClientUpdateContext(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.update_context(ctx);
}

CGLError AO46ClientFlushDrawable(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.flush_drawable(ctx);
}

CGLError AO46ClientSetGlobalOption(CGLGlobalOption pname, const GLint *params)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.set_global_option(pname, params);
}

CGLError AO46ClientGetGlobalOption(CGLGlobalOption pname, GLint *params)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.get_global_option(pname, params);
}

CGLError AO46ClientLockContext(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.lock_context(ctx);
}

CGLError AO46ClientUnlockContext(AO46ContextRef ctx)
{
    CGLError err = AO46ClientEnsureFramework();
    if (err != kCGLNoError) {
        return err;
    }
    return g_framework.unlock_context(ctx);
}

void *AO46ClientGetProcAddress(const char *procname)
{
    if (AO46ClientEnsureFramework() != kCGLNoError || !g_framework.get_proc_address) {
        return NULL;
    }
    return g_framework.get_proc_address(procname);
}

void *AO46ClientGetProcAddressBytes(const GLubyte *procname)
{
    if (AO46ClientEnsureFramework() != kCGLNoError) {
        return NULL;
    }

    if (g_framework.get_proc_address_bytes) {
        return g_framework.get_proc_address_bytes(procname);
    }

    if (!procname) {
        return NULL;
    }

    return g_framework.get_proc_address((const char *)procname);
}
