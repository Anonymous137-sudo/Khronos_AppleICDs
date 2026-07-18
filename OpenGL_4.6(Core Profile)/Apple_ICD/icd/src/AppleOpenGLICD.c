#include "AppleOpenGLICD.h"

#include "AppleOpenGL46Client.h"

CGLError AO46ICDEnsureDriver(void)
{
    return AO46ClientEnsureFramework();
}

CGLError AO46ICDChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                                  AO46PixelFormatRef *out_pix,
                                  GLint *out_npix)
{
    return AO46ClientChoosePixelFormat(attribs, out_pix, out_npix);
}

void AO46ICDDestroyPixelFormat(AO46PixelFormatRef pix)
{
    AO46ClientDestroyPixelFormat(pix);
}

AO46PixelFormatRef AO46ICDRetainPixelFormat(AO46PixelFormatRef pix)
{
    return AO46ClientRetainPixelFormat(pix);
}

GLuint AO46ICDGetPixelFormatRetainCount(AO46PixelFormatRef pix)
{
    return AO46ClientGetPixelFormatRetainCount(pix);
}

CGLError AO46ICDDescribePixelFormat(AO46PixelFormatRef pix,
                                    GLint pix_num,
                                    CGLPixelFormatAttribute attrib,
                                    GLint *value)
{
    return AO46ClientDescribePixelFormat(pix, pix_num, attrib, value);
}

CGLError AO46ICDQueryRendererInfo(GLuint display_mask,
                                  AO46RendererInfoRef *out_rend,
                                  GLint *out_nrend)
{
    return AO46ClientQueryRendererInfo(display_mask, out_rend, out_nrend);
}

void AO46ICDDestroyRendererInfo(AO46RendererInfoRef rend)
{
    AO46ClientDestroyRendererInfo(rend);
}

CGLError AO46ICDDescribeRenderer(AO46RendererInfoRef rend,
                                 GLint rend_num,
                                 CGLRendererProperty prop,
                                 GLint *value)
{
    return AO46ClientDescribeRenderer(rend, rend_num, prop, value);
}

CGLError AO46ICDCreateContext(AO46PixelFormatRef pix,
                              AO46ContextRef share,
                              AO46ContextRef *out_ctx)
{
    return AO46ClientCreateContext(pix, share, out_ctx);
}

CGLError AO46ICDCopyContext(AO46ContextRef src, AO46ContextRef dst, GLbitfield mask)
{
    return AO46ClientCopyContext(src, dst, mask);
}

void AO46ICDDestroyContext(AO46ContextRef ctx)
{
    AO46ClientDestroyContext(ctx);
}

AO46ContextRef AO46ICDRetainContext(AO46ContextRef ctx)
{
    return AO46ClientRetainContext(ctx);
}

GLuint AO46ICDGetContextRetainCount(AO46ContextRef ctx)
{
    return AO46ClientGetContextRetainCount(ctx);
}

AO46PixelFormatRef AO46ICDGetPixelFormatForContext(AO46ContextRef ctx)
{
    return AO46ClientGetPixelFormatForContext(ctx);
}

AO46ShareGroupRef AO46ICDGetShareGroupForContext(AO46ContextRef ctx)
{
    return AO46ClientGetShareGroupForContext(ctx);
}

CGLError AO46ICDCreatePBuffer(GLsizei width,
                              GLsizei height,
                              GLenum target,
                              GLenum internal_format,
                              GLint max_level,
                              AO46PBufferRef *out_pbuffer)
{
    return AO46ClientCreatePBuffer(width, height, target, internal_format, max_level, out_pbuffer);
}

void AO46ICDDestroyPBuffer(AO46PBufferRef pbuffer)
{
    AO46ClientDestroyPBuffer(pbuffer);
}

AO46PBufferRef AO46ICDRetainPBuffer(AO46PBufferRef pbuffer)
{
    return AO46ClientRetainPBuffer(pbuffer);
}

GLuint AO46ICDGetPBufferRetainCount(AO46PBufferRef pbuffer)
{
    return AO46ClientGetPBufferRetainCount(pbuffer);
}

CGLError AO46ICDDescribePBuffer(AO46PBufferRef pbuffer,
                                GLsizei *width,
                                GLsizei *height,
                                GLenum *target,
                                GLenum *internal_format,
                                GLint *mipmap)
{
    return AO46ClientDescribePBuffer(pbuffer, width, height, target, internal_format, mipmap);
}

CGLError AO46ICDTexImagePBuffer(AO46ContextRef ctx, AO46PBufferRef pbuffer, GLenum source)
{
    return AO46ClientTexImagePBuffer(ctx, pbuffer, source);
}

CGLError AO46ICDSetOffScreen(AO46ContextRef ctx,
                             GLsizei width,
                             GLsizei height,
                             GLint rowbytes,
                             void *baseaddr)
{
    return AO46ClientSetOffScreen(ctx, width, height, rowbytes, baseaddr);
}

CGLError AO46ICDGetOffScreen(AO46ContextRef ctx,
                             GLsizei *width,
                             GLsizei *height,
                             GLint *rowbytes,
                             void **baseaddr)
{
    return AO46ClientGetOffScreen(ctx, width, height, rowbytes, baseaddr);
}

CGLError AO46ICDSetFullScreen(AO46ContextRef ctx)
{
    return AO46ClientSetFullScreen(ctx);
}

CGLError AO46ICDSetFullScreenOnDisplay(AO46ContextRef ctx, GLuint display_mask)
{
    return AO46ClientSetFullScreenOnDisplay(ctx, display_mask);
}

CGLError AO46ICDSetPBuffer(AO46ContextRef ctx,
                           AO46PBufferRef pbuffer,
                           GLenum face,
                           GLint level,
                           GLint screen)
{
    return AO46ClientSetPBuffer(ctx, pbuffer, face, level, screen);
}

CGLError AO46ICDGetPBuffer(AO46ContextRef ctx,
                           AO46PBufferRef *pbuffer,
                           GLenum *face,
                           GLint *level,
                           GLint *screen)
{
    return AO46ClientGetPBuffer(ctx, pbuffer, face, level, screen);
}

CGLError AO46ICDSetCurrentContext(AO46ContextRef ctx)
{
    return AO46ClientSetCurrentContext(ctx);
}

AO46ContextRef AO46ICDGetCurrentContext(void)
{
    return AO46ClientGetCurrentContext();
}

CGLError AO46ICDCreateHeadlessDrawable(AO46ContextRef ctx)
{
    return AO46ClientCreateHeadlessDrawable(ctx);
}

CGLError AO46ICDAttachWindowToContext(AO46ContextRef ctx, void *window)
{
    return AO46ClientAttachWindowToContext(ctx, window);
}

CGLError AO46ICDClearDrawable(AO46ContextRef ctx)
{
    return AO46ClientClearDrawable(ctx);
}

CGLError AO46ICDEnableContext(AO46ContextRef ctx, CGLContextEnable pname)
{
    return AO46ClientEnableContext(ctx, pname);
}

CGLError AO46ICDDisableContext(AO46ContextRef ctx, CGLContextEnable pname)
{
    return AO46ClientDisableContext(ctx, pname);
}

CGLError AO46ICDIsContextEnabled(AO46ContextRef ctx, CGLContextEnable pname, GLint *enable)
{
    return AO46ClientIsContextEnabled(ctx, pname, enable);
}

CGLError AO46ICDSetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, const GLint *params)
{
    return AO46ClientSetContextParameter(ctx, pname, params);
}

CGLError AO46ICDGetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, GLint *params)
{
    return AO46ClientGetContextParameter(ctx, pname, params);
}

CGLError AO46ICDSetVirtualScreen(AO46ContextRef ctx, GLint screen)
{
    return AO46ClientSetVirtualScreen(ctx, screen);
}

CGLError AO46ICDGetVirtualScreen(AO46ContextRef ctx, GLint *screen)
{
    return AO46ClientGetVirtualScreen(ctx, screen);
}

AO46DrawableKind AO46ICDGetDrawableKind(AO46ContextRef ctx)
{
    return AO46ClientGetDrawableKind(ctx);
}

void *AO46ICDGetWindowHandleForContext(AO46ContextRef ctx)
{
    return AO46ClientGetWindowHandleForContext(ctx);
}

CGLError AO46ICDUpdateContext(AO46ContextRef ctx)
{
    return AO46ClientUpdateContext(ctx);
}

CGLError AO46ICDFlushDrawable(AO46ContextRef ctx)
{
    return AO46ClientFlushDrawable(ctx);
}

CGLError AO46ICDSetGlobalOption(CGLGlobalOption pname, const GLint *params)
{
    return AO46ClientSetGlobalOption(pname, params);
}

CGLError AO46ICDGetGlobalOption(CGLGlobalOption pname, GLint *params)
{
    return AO46ClientGetGlobalOption(pname, params);
}

CGLError AO46ICDLockContext(AO46ContextRef ctx)
{
    return AO46ClientLockContext(ctx);
}

CGLError AO46ICDUnlockContext(AO46ContextRef ctx)
{
    return AO46ClientUnlockContext(ctx);
}

void *AO46ICDGetProcAddress(const char *procname)
{
    return AO46ClientGetProcAddress(procname);
}

void *AO46ICDGetProcAddressBytes(const GLubyte *procname)
{
    return AO46ClientGetProcAddressBytes(procname);
}

const char *AO46ICDIdentity(void)
{
    return "libGLICD.dylib";
}
