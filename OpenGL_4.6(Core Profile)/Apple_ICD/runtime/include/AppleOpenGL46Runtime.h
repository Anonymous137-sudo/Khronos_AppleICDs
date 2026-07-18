#ifndef APPLE_OPENGL46_RUNTIME_H
#define APPLE_OPENGL46_RUNTIME_H

#include <OpenGL/CGLTypes.h>
#include "glcorearb.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AO46ContextRec *AO46ContextRef;
typedef struct AO46PixelFormatRec *AO46PixelFormatRef;
typedef struct AO46RendererInfoRec *AO46RendererInfoRef;
typedef struct AO46PBufferRec *AO46PBufferRef;
typedef struct AO46ShareGroupRec *AO46ShareGroupRef;

#define kCGLOGLPVersion_GL4_6_Core ((CGLOpenGLProfile)0x4600)
#define kAO46CGLOGLPVersion_GL4_6_Core kCGLOGLPVersion_GL4_6_Core

typedef enum {
    AO46DrawableKindNone = 0,
    AO46DrawableKindHeadless = 1,
    AO46DrawableKindWindow = 2
} AO46DrawableKind;

CGLError AO46EnsureRuntime(void);

CGLError AO46ChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                               AO46PixelFormatRef *out_pix,
                               GLint *out_npix);
void AO46DestroyPixelFormat(AO46PixelFormatRef pix);
AO46PixelFormatRef AO46RetainPixelFormat(AO46PixelFormatRef pix);
GLuint AO46GetPixelFormatRetainCount(AO46PixelFormatRef pix);
CGLError AO46DescribePixelFormat(AO46PixelFormatRef pix,
                                 GLint pix_num,
                                 CGLPixelFormatAttribute attrib,
                                 GLint *value);
CGLError AO46QueryRendererInfo(GLuint display_mask,
                               AO46RendererInfoRef *out_rend,
                               GLint *out_nrend);
void AO46DestroyRendererInfo(AO46RendererInfoRef rend);
CGLError AO46DescribeRenderer(AO46RendererInfoRef rend,
                              GLint rend_num,
                              CGLRendererProperty prop,
                              GLint *value);

CGLError AO46CreateContext(AO46PixelFormatRef pix,
                           AO46ContextRef share,
                           AO46ContextRef *out_ctx);
CGLError AO46CopyContext(AO46ContextRef src, AO46ContextRef dst, GLbitfield mask);
void AO46DestroyContext(AO46ContextRef ctx);
AO46ContextRef AO46RetainContext(AO46ContextRef ctx);
GLuint AO46GetContextRetainCount(AO46ContextRef ctx);
AO46PixelFormatRef AO46GetPixelFormatForContext(AO46ContextRef ctx);
AO46ShareGroupRef AO46GetShareGroupForContext(AO46ContextRef ctx);

CGLError AO46CreatePBuffer(GLsizei width,
                           GLsizei height,
                           GLenum target,
                           GLenum internal_format,
                           GLint max_level,
                           AO46PBufferRef *out_pbuffer);
void AO46DestroyPBuffer(AO46PBufferRef pbuffer);
AO46PBufferRef AO46RetainPBuffer(AO46PBufferRef pbuffer);
GLuint AO46GetPBufferRetainCount(AO46PBufferRef pbuffer);
CGLError AO46DescribePBuffer(AO46PBufferRef pbuffer,
                             GLsizei *width,
                             GLsizei *height,
                             GLenum *target,
                             GLenum *internal_format,
                             GLint *mipmap);
CGLError AO46TexImagePBuffer(AO46ContextRef ctx, AO46PBufferRef pbuffer, GLenum source);
CGLError AO46SetOffScreen(AO46ContextRef ctx,
                          GLsizei width,
                          GLsizei height,
                          GLint rowbytes,
                          void *baseaddr);
CGLError AO46GetOffScreen(AO46ContextRef ctx,
                          GLsizei *width,
                          GLsizei *height,
                          GLint *rowbytes,
                          void **baseaddr);
CGLError AO46SetFullScreen(AO46ContextRef ctx);
CGLError AO46SetFullScreenOnDisplay(AO46ContextRef ctx, GLuint display_mask);
CGLError AO46SetPBuffer(AO46ContextRef ctx,
                        AO46PBufferRef pbuffer,
                        GLenum face,
                        GLint level,
                        GLint screen);
CGLError AO46GetPBuffer(AO46ContextRef ctx,
                        AO46PBufferRef *pbuffer,
                        GLenum *face,
                        GLint *level,
                        GLint *screen);

CGLError AO46SetCurrentContext(AO46ContextRef ctx);
AO46ContextRef AO46GetCurrentContext(void);
CGLError AO46CreateHeadlessDrawable(AO46ContextRef ctx);
CGLError AO46AttachWindowToContext(AO46ContextRef ctx, void *window);
CGLError AO46ClearDrawable(AO46ContextRef ctx);
CGLError AO46EnableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46DisableContext(AO46ContextRef ctx, CGLContextEnable pname);
CGLError AO46IsContextEnabled(AO46ContextRef ctx, CGLContextEnable pname, GLint *enable);
CGLError AO46SetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, const GLint *params);
CGLError AO46GetContextParameter(AO46ContextRef ctx, CGLContextParameter pname, GLint *params);
CGLError AO46SetVirtualScreen(AO46ContextRef ctx, GLint screen);
CGLError AO46GetVirtualScreen(AO46ContextRef ctx, GLint *screen);
AO46DrawableKind AO46GetDrawableKind(AO46ContextRef ctx);
void *AO46GetWindowHandleForContext(AO46ContextRef ctx);
CGLError AO46UpdateContext(AO46ContextRef ctx);
CGLError AO46FlushDrawable(AO46ContextRef ctx);
CGLError AO46SetGlobalOption(CGLGlobalOption pname, const GLint *params);
CGLError AO46GetGlobalOption(CGLGlobalOption pname, GLint *params);
CGLError AO46LockContext(AO46ContextRef ctx);
CGLError AO46UnlockContext(AO46ContextRef ctx);

void *AO46GetProcAddress(const char *procname);
void *AO46GetProcAddressBytes(const GLubyte *procname);

const char *AO46FrameworkIdentity(void);

#ifdef __cplusplus
}
#endif

#endif
