#include "AppleOpenGLICD.h"

#include <OpenGL/OpenGL.h>

CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *attribs,
                              CGLPixelFormatObj *pix,
                              GLint *npix)
{
    return AO46ICDChoosePixelFormat(attribs, (AO46PixelFormatRef *)pix, npix);
}

CGLError CGLDestroyPixelFormat(CGLPixelFormatObj pix)
{
    if (pix && AO46ICDEnsureDriver() != kCGLNoError) {
        return kCGLBadConnection;
    }

    AO46ICDDestroyPixelFormat((AO46PixelFormatRef)pix);
    return kCGLNoError;
}

CGLError CGLDescribePixelFormat(CGLPixelFormatObj pix,
                                GLint pix_num,
                                CGLPixelFormatAttribute attrib,
                                GLint *value)
{
    return AO46ICDDescribePixelFormat((AO46PixelFormatRef)pix, pix_num, attrib, value);
}

void CGLReleasePixelFormat(CGLPixelFormatObj pix)
{
    AO46ICDDestroyPixelFormat((AO46PixelFormatRef)pix);
}

CGLPixelFormatObj CGLRetainPixelFormat(CGLPixelFormatObj pix)
{
    return (CGLPixelFormatObj)AO46ICDRetainPixelFormat((AO46PixelFormatRef)pix);
}

GLuint CGLGetPixelFormatRetainCount(CGLPixelFormatObj pix)
{
    return AO46ICDGetPixelFormatRetainCount((AO46PixelFormatRef)pix);
}

CGLError CGLQueryRendererInfo(GLuint display_mask, CGLRendererInfoObj *rend, GLint *nrend)
{
    return AO46ICDQueryRendererInfo(display_mask, (AO46RendererInfoRef *)rend, nrend);
}

CGLError CGLDestroyRendererInfo(CGLRendererInfoObj rend)
{
    if (rend && AO46ICDEnsureDriver() != kCGLNoError) {
        return kCGLBadConnection;
    }

    AO46ICDDestroyRendererInfo((AO46RendererInfoRef)rend);
    return kCGLNoError;
}

CGLError CGLDescribeRenderer(CGLRendererInfoObj rend, GLint rend_num, CGLRendererProperty prop, GLint *value)
{
    return AO46ICDDescribeRenderer((AO46RendererInfoRef)rend, rend_num, prop, value);
}

CGLError CGLCreateContext(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *ctx)
{
    return AO46ICDCreateContext((AO46PixelFormatRef)pix, (AO46ContextRef)share, (AO46ContextRef *)ctx);
}

CGLError CGLCopyContext(CGLContextObj src, CGLContextObj dst, GLbitfield mask)
{
    return AO46ICDCopyContext((AO46ContextRef)src, (AO46ContextRef)dst, mask);
}

CGLError CGLDestroyContext(CGLContextObj ctx)
{
    if (ctx && AO46ICDEnsureDriver() != kCGLNoError) {
        return kCGLBadConnection;
    }

    AO46ICDDestroyContext((AO46ContextRef)ctx);
    return kCGLNoError;
}

CGLContextObj CGLRetainContext(CGLContextObj ctx)
{
    return (CGLContextObj)AO46ICDRetainContext((AO46ContextRef)ctx);
}

void CGLReleaseContext(CGLContextObj ctx)
{
    AO46ICDDestroyContext((AO46ContextRef)ctx);
}

GLuint CGLGetContextRetainCount(CGLContextObj ctx)
{
    return AO46ICDGetContextRetainCount((AO46ContextRef)ctx);
}

CGLPixelFormatObj CGLGetPixelFormat(CGLContextObj ctx)
{
    return (CGLPixelFormatObj)AO46ICDGetPixelFormatForContext((AO46ContextRef)ctx);
}

CGLShareGroupObj CGLGetShareGroup(CGLContextObj ctx)
{
    return (CGLShareGroupObj)AO46ICDGetShareGroupForContext((AO46ContextRef)ctx);
}

CGLError CGLCreatePBuffer(GLsizei width,
                          GLsizei height,
                          GLenum target,
                          GLenum internalFormat,
                          GLint max_level,
                          CGLPBufferObj *pbuffer)
{
    return AO46ICDCreatePBuffer(width, height, target, internalFormat, max_level, (AO46PBufferRef *)pbuffer);
}

CGLError CGLDestroyPBuffer(CGLPBufferObj pbuffer)
{
    if (pbuffer && AO46ICDEnsureDriver() != kCGLNoError) {
        return kCGLBadConnection;
    }

    AO46ICDDestroyPBuffer((AO46PBufferRef)pbuffer);
    return kCGLNoError;
}

CGLError CGLDescribePBuffer(CGLPBufferObj obj,
                            GLsizei *width,
                            GLsizei *height,
                            GLenum *target,
                            GLenum *internalFormat,
                            GLint *mipmap)
{
    return AO46ICDDescribePBuffer((AO46PBufferRef)obj, width, height, target, internalFormat, mipmap);
}

CGLError CGLTexImagePBuffer(CGLContextObj ctx, CGLPBufferObj pbuffer, GLenum source)
{
    return AO46ICDTexImagePBuffer((AO46ContextRef)ctx, (AO46PBufferRef)pbuffer, source);
}

CGLPBufferObj CGLRetainPBuffer(CGLPBufferObj pbuffer)
{
    return (CGLPBufferObj)AO46ICDRetainPBuffer((AO46PBufferRef)pbuffer);
}

void CGLReleasePBuffer(CGLPBufferObj pbuffer)
{
    AO46ICDDestroyPBuffer((AO46PBufferRef)pbuffer);
}

GLuint CGLGetPBufferRetainCount(CGLPBufferObj pbuffer)
{
    return AO46ICDGetPBufferRetainCount((AO46PBufferRef)pbuffer);
}

CGLError CGLSetOffScreen(CGLContextObj ctx, GLsizei width, GLsizei height, GLint rowbytes, void *baseaddr)
{
    return AO46ICDSetOffScreen((AO46ContextRef)ctx, width, height, rowbytes, baseaddr);
}

CGLError CGLGetOffScreen(CGLContextObj ctx, GLsizei *width, GLsizei *height, GLint *rowbytes, void **baseaddr)
{
    return AO46ICDGetOffScreen((AO46ContextRef)ctx, width, height, rowbytes, baseaddr);
}

CGLError CGLSetFullScreen(CGLContextObj ctx)
{
    return AO46ICDSetFullScreen((AO46ContextRef)ctx);
}

CGLError CGLSetFullScreenOnDisplay(CGLContextObj ctx, GLuint display_mask)
{
    return AO46ICDSetFullScreenOnDisplay((AO46ContextRef)ctx, display_mask);
}

CGLError CGLSetPBuffer(CGLContextObj ctx, CGLPBufferObj pbuffer, GLenum face, GLint level, GLint screen)
{
    return AO46ICDSetPBuffer((AO46ContextRef)ctx, (AO46PBufferRef)pbuffer, face, level, screen);
}

CGLError CGLGetPBuffer(CGLContextObj ctx, CGLPBufferObj *pbuffer, GLenum *face, GLint *level, GLint *screen)
{
    return AO46ICDGetPBuffer((AO46ContextRef)ctx, (AO46PBufferRef *)pbuffer, face, level, screen);
}

CGLError CGLSetCurrentContext(CGLContextObj ctx)
{
    return AO46ICDSetCurrentContext((AO46ContextRef)ctx);
}

CGLContextObj CGLGetCurrentContext(void)
{
    return (CGLContextObj)AO46ICDGetCurrentContext();
}

CGLError CGLSetParameter(CGLContextObj ctx, CGLContextParameter pname, const GLint *params)
{
    return AO46ICDSetContextParameter((AO46ContextRef)ctx, pname, params);
}

CGLError CGLGetParameter(CGLContextObj ctx, CGLContextParameter pname, GLint *params)
{
    return AO46ICDGetContextParameter((AO46ContextRef)ctx, pname, params);
}

CGLError CGLEnable(CGLContextObj ctx, CGLContextEnable pname)
{
    return AO46ICDEnableContext((AO46ContextRef)ctx, pname);
}

CGLError CGLDisable(CGLContextObj ctx, CGLContextEnable pname)
{
    return AO46ICDDisableContext((AO46ContextRef)ctx, pname);
}

CGLError CGLIsEnabled(CGLContextObj ctx, CGLContextEnable pname, GLint *enable)
{
    return AO46ICDIsContextEnabled((AO46ContextRef)ctx, pname, enable);
}

CGLError CGLSetVirtualScreen(CGLContextObj ctx, GLint screen)
{
    return AO46ICDSetVirtualScreen((AO46ContextRef)ctx, screen);
}

CGLError CGLGetVirtualScreen(CGLContextObj ctx, GLint *screen)
{
    return AO46ICDGetVirtualScreen((AO46ContextRef)ctx, screen);
}

void *CGLGetProcAddress(const GLubyte *procname)
{
    return AO46ICDGetProcAddressBytes(procname);
}

CGLError CGLClearDrawable(CGLContextObj ctx)
{
    return AO46ICDClearDrawable((AO46ContextRef)ctx);
}

CGLError CGLFlushDrawable(CGLContextObj ctx)
{
    return AO46ICDFlushDrawable((AO46ContextRef)ctx);
}

CGLError CGLUpdateContext(CGLContextObj ctx)
{
    return AO46ICDUpdateContext((AO46ContextRef)ctx);
}

CGLError CGLSetGlobalOption(CGLGlobalOption pname, const GLint *params)
{
    return AO46ICDSetGlobalOption(pname, params);
}

CGLError CGLGetGlobalOption(CGLGlobalOption pname, GLint *params)
{
    return AO46ICDGetGlobalOption(pname, params);
}

CGLError CGLSetOption(CGLGlobalOption pname, GLint param)
{
    return AO46ICDSetGlobalOption(pname, &param);
}

CGLError CGLGetOption(CGLGlobalOption pname, GLint *param)
{
    return AO46ICDGetGlobalOption(pname, param);
}

CGLError CGLLockContext(CGLContextObj ctx)
{
    return AO46ICDLockContext((AO46ContextRef)ctx);
}

CGLError CGLUnlockContext(CGLContextObj ctx)
{
    return AO46ICDUnlockContext((AO46ContextRef)ctx);
}

void CGLGetVersion(GLint *majorvers, GLint *minorvers)
{
    if (majorvers) {
        *majorvers = 1;
    }
    if (minorvers) {
        *minorvers = 3;
    }
}

const char *CGLErrorString(CGLError error)
{
    switch (error) {
        case kCGLNoError:
            return "kCGLNoError";
        case kCGLBadAttribute:
            return "kCGLBadAttribute";
        case kCGLBadPixelFormat:
            return "kCGLBadPixelFormat";
        case kCGLBadContext:
            return "kCGLBadContext";
        case kCGLBadState:
            return "kCGLBadState";
        case kCGLBadValue:
            return "kCGLBadValue";
        case kCGLBadMatch:
            return "kCGLBadMatch";
        case kCGLBadEnumeration:
            return "kCGLBadEnumeration";
        case kCGLBadAddress:
            return "kCGLBadAddress";
        case kCGLBadAlloc:
            return "kCGLBadAlloc";
        case kCGLBadConnection:
            return "kCGLBadConnection";
        case kCGLBadDrawable:
            return "kCGLBadDrawable";
        case kCGLBadWindow:
            return "kCGLBadWindow";
        default:
            return "kCGLUnknownError";
    }
}
