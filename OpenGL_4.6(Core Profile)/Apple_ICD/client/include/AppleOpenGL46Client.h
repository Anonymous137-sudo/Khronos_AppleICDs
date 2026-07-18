#ifndef APPLE_OPENGL46_CLIENT_H
#define APPLE_OPENGL46_CLIENT_H

#include "AppleOpenGL46Runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

CGLError AO46ClientEnsureFramework(void);

CGLError AO46ClientChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                                     AO46PixelFormatRef *out_pix,
                                     GLint *out_npix);
void AO46ClientDestroyPixelFormat(AO46PixelFormatRef pix);
AO46PixelFormatRef AO46ClientRetainPixelFormat(AO46PixelFormatRef pix);
GLuint AO46ClientGetPixelFormatRetainCount(AO46PixelFormatRef pix);
CGLError AO46ClientDescribePixelFormat(AO46PixelFormatRef pix,
                                       GLint pix_num,
                                       CGLPixelFormatAttribute attrib,
                                       GLint *value);
CGLError AO46ClientQueryRendererInfo(GLuint display_mask,
                                     AO46RendererInfoRef *out_rend,
                                     GLint *out_nrend);
void AO46ClientDestroyRendererInfo(AO46RendererInfoRef rend);
CGLError AO46ClientDescribeRenderer(AO46RendererInfoRef rend,
                                    GLint rend_num,
                                    CGLRendererProperty prop,
                                    GLint *value);

CGLError AO46ClientCreateContext(AO46PixelFormatRef pix,
                                 AO46ContextRef share,
                                 AO46ContextRef *out_ctx);
CGLError AO46ClientCopyContext(AO46ContextRef src, AO46ContextRef dst, GLbitfield mask);
void AO46ClientDestroyContext(AO46ContextRef ctx);
AO46ContextRef AO46ClientRetainContext(AO46ContextRef ctx);
GLuint AO46ClientGetContextRetainCount(AO46ContextRef ctx);
AO46PixelFormatRef AO46ClientGetPixelFormatForContext(AO46ContextRef ctx);
AO46ShareGroupRef AO46ClientGetShareGroupForContext(AO46ContextRef ctx);

CGLError AO46ClientCreatePBuffer(GLsizei width,
                                 GLsizei height,
                                 GLenum target,
                                 GLenum internal_format,
                                 GLint max_level,
                                 AO46PBufferRef *out_pbuffer);
void AO46ClientDestroyPBuffer(AO46PBufferRef pbuffer);
AO46PBufferRef AO46ClientRetainPBuffer(AO46PBufferRef pbuffer);
GLuint AO46ClientGetPBufferRetainCount(AO46PBufferRef pbuffer);
CGLError AO46ClientDescribePBuffer(AO46PBufferRef pbuffer,
                                   GLsizei *width,
                                   GLsizei *height,
                                   GLenum *target,
                                   GLenum *internal_format,
                                   GLint *mipmap);
CGLError AO46ClientTexImagePBuffer(AO46ContextRef ctx, AO46PBufferRef pbuffer, GLenum source);
CGLError AO46ClientSetOffScreen(AO46ContextRef ctx,
                                GLsizei width,
                                GLsizei height,
                                GLint rowbytes,
                                void *baseaddr);
CGLError AO46ClientGetOffScreen(AO46ContextRef ctx,
                                GLsizei *width,
                                GLsizei *height,
                                GLint *rowbytes,
                                void **baseaddr);
CGLError AO46ClientSetFullScreen(AO46ContextRef ctx);
CGLError AO46ClientSetFullScreenOnDisplay(AO46ContextRef ctx, GLuint display_mask);
CGLError AO46ClientSetPBuffer(AO46ContextRef ctx,
                              AO46PBufferRef pbuffer,
                              GLenum face,
                              GLint level,
                              GLint screen);
CGLError AO46ClientGetPBuffer(AO46ContextRef ctx,
                              AO46PBufferRef *pbuffer,
                              GLenum *face,
                              GLint *level,
                              GLint *screen);

CGLError AO46ClientSetCurrentContext(AO46ContextRef ctx);
AO46ContextRef AO46ClientGetCurrentContext(void);
CGLError AO46ClientCreateHeadlessDrawable(AO46ContextRef ctx);
CGLError AO46ClientAttachWindowToContext(AO46ContextRef ctx, void *window);
CGLError AO46ClientClearDrawable(AO46ContextRef ctx);
CGLError AO46ClientEnableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46ClientDisableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46ClientIsContextEnabled(AO46ContextRef ctx, CGLContextEnable pname, GLint *enable);
CGLError AO46ClientSetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, const GLint *params);
CGLError AO46ClientGetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, GLint *params);
CGLError AO46ClientSetVirtualScreen(AO46ContextRef ctx, GLint screen);
CGLError AO46ClientGetVirtualScreen(AO46ContextRef ctx, GLint *screen);
AO46DrawableKind AO46ClientGetDrawableKind(AO46ContextRef ctx);
void *AO46ClientGetWindowHandleForContext(AO46ContextRef ctx);
CGLError AO46ClientUpdateContext(AO46ContextRef ctx);
CGLError AO46ClientFlushDrawable(AO46ContextRef ctx);
CGLError AO46ClientSetGlobalOption(CGLGlobalOption pname, const GLint *params);
CGLError AO46ClientGetGlobalOption(CGLGlobalOption pname, GLint *params);
CGLError AO46ClientLockContext(AO46ContextRef ctx);
CGLError AO46ClientUnlockContext(AO46ContextRef ctx);

void *AO46ClientGetProcAddress(const char *procname);
void *AO46ClientGetProcAddressBytes(const GLubyte *procname);

#ifdef __cplusplus
}
#endif

#endif
