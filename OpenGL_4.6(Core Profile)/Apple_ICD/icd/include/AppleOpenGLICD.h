#ifndef APPLE_OPENGL_ICD_H
#define APPLE_OPENGL_ICD_H

#include "AppleOpenGL46Runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

CGLError AO46ICDEnsureDriver(void);

CGLError AO46ICDChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                                  AO46PixelFormatRef *out_pix,
                                  GLint *out_npix);
void AO46ICDDestroyPixelFormat(AO46PixelFormatRef pix);
AO46PixelFormatRef AO46ICDRetainPixelFormat(AO46PixelFormatRef pix);
GLuint AO46ICDGetPixelFormatRetainCount(AO46PixelFormatRef pix);
CGLError AO46ICDDescribePixelFormat(AO46PixelFormatRef pix,
                                    GLint pix_num,
                                    CGLPixelFormatAttribute attrib,
                                    GLint *value);
CGLError AO46ICDQueryRendererInfo(GLuint display_mask,
                                  AO46RendererInfoRef *out_rend,
                                  GLint *out_nrend);
void AO46ICDDestroyRendererInfo(AO46RendererInfoRef rend);
CGLError AO46ICDDescribeRenderer(AO46RendererInfoRef rend,
                                 GLint rend_num,
                                 CGLRendererProperty prop,
                                 GLint *value);

CGLError AO46ICDCreateContext(AO46PixelFormatRef pix,
                              AO46ContextRef share,
                              AO46ContextRef *out_ctx);
CGLError AO46ICDCopyContext(AO46ContextRef src, AO46ContextRef dst, GLbitfield mask);
void AO46ICDDestroyContext(AO46ContextRef ctx);
AO46ContextRef AO46ICDRetainContext(AO46ContextRef ctx);
GLuint AO46ICDGetContextRetainCount(AO46ContextRef ctx);
AO46PixelFormatRef AO46ICDGetPixelFormatForContext(AO46ContextRef ctx);
AO46ShareGroupRef AO46ICDGetShareGroupForContext(AO46ContextRef ctx);

CGLError AO46ICDCreatePBuffer(GLsizei width,
                              GLsizei height,
                              GLenum target,
                              GLenum internal_format,
                              GLint max_level,
                              AO46PBufferRef *out_pbuffer);
void AO46ICDDestroyPBuffer(AO46PBufferRef pbuffer);
AO46PBufferRef AO46ICDRetainPBuffer(AO46PBufferRef pbuffer);
GLuint AO46ICDGetPBufferRetainCount(AO46PBufferRef pbuffer);
CGLError AO46ICDDescribePBuffer(AO46PBufferRef pbuffer,
                                GLsizei *width,
                                GLsizei *height,
                                GLenum *target,
                                GLenum *internal_format,
                                GLint *mipmap);
CGLError AO46ICDTexImagePBuffer(AO46ContextRef ctx, AO46PBufferRef pbuffer, GLenum source);
CGLError AO46ICDSetOffScreen(AO46ContextRef ctx,
                             GLsizei width,
                             GLsizei height,
                             GLint rowbytes,
                             void *baseaddr);
CGLError AO46ICDGetOffScreen(AO46ContextRef ctx,
                             GLsizei *width,
                             GLsizei *height,
                             GLint *rowbytes,
                             void **baseaddr);
CGLError AO46ICDSetFullScreen(AO46ContextRef ctx);
CGLError AO46ICDSetFullScreenOnDisplay(AO46ContextRef ctx, GLuint display_mask);
CGLError AO46ICDSetPBuffer(AO46ContextRef ctx,
                           AO46PBufferRef pbuffer,
                           GLenum face,
                           GLint level,
                           GLint screen);
CGLError AO46ICDGetPBuffer(AO46ContextRef ctx,
                           AO46PBufferRef *pbuffer,
                           GLenum *face,
                           GLint *level,
                           GLint *screen);

CGLError AO46ICDSetCurrentContext(AO46ContextRef ctx);
AO46ContextRef AO46ICDGetCurrentContext(void);
CGLError AO46ICDCreateHeadlessDrawable(AO46ContextRef ctx);
CGLError AO46ICDAttachWindowToContext(AO46ContextRef ctx, void *window);
CGLError AO46ICDClearDrawable(AO46ContextRef ctx);
CGLError AO46ICDEnableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46ICDDisableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46ICDIsContextEnabled(AO46ContextRef ctx, CGLContextEnable pname, GLint *enable);
CGLError AO46ICDSetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, const GLint *params);
CGLError AO46ICDGetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, GLint *params);
CGLError AO46ICDSetVirtualScreen(AO46ContextRef ctx, GLint screen);
CGLError AO46ICDGetVirtualScreen(AO46ContextRef ctx, GLint *screen);
AO46DrawableKind AO46ICDGetDrawableKind(AO46ContextRef ctx);
void *AO46ICDGetWindowHandleForContext(AO46ContextRef ctx);
CGLError AO46ICDUpdateContext(AO46ContextRef ctx);
CGLError AO46ICDFlushDrawable(AO46ContextRef ctx);
CGLError AO46ICDSetGlobalOption(CGLGlobalOption pname, const GLint *params);
CGLError AO46ICDGetGlobalOption(CGLGlobalOption pname, GLint *params);
CGLError AO46ICDLockContext(AO46ContextRef ctx);
CGLError AO46ICDUnlockContext(AO46ContextRef ctx);

void *AO46ICDGetProcAddress(const char *procname);
void *AO46ICDGetProcAddressBytes(const GLubyte *procname);

const char *AO46ICDIdentity(void);

#ifdef __cplusplus
}
#endif

#endif
