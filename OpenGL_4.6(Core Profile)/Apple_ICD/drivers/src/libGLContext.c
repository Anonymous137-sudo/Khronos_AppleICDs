#include "AppleOpenGL46LibGLContext.h"

#include <stdbool.h>
#include <stddef.h>

static CGLError ao46_create_context_without_drawable(CGLContextObj *ctx)
{
    static const CGLPixelFormatAttribute default_attribs[] = { 0 };
    CGLPixelFormatObj pix;
    GLint npix;
    CGLError err;

    err = AO46ICDChoosePixelFormat(default_attribs, (AO46PixelFormatRef *)&pix, &npix);
    if (err != kCGLNoError) {
        return err;
    }

    err = AO46ICDCreateContext((AO46PixelFormatRef)pix, NULL, (AO46ContextRef *)ctx);
    AO46ICDDestroyPixelFormat((AO46PixelFormatRef)pix);
    return err;
}

bool AO46LibGLContextBootstrap(void)
{
    return AO46ICDEnsureDriver() == kCGLNoError;
}

CGLError AO46LibGLContextCreate(CGLContextObj *ctx)
{
    return AO46LibGLContextCreateHeadless(ctx);
}

CGLError AO46LibGLContextCreateHeadless(CGLContextObj *ctx)
{
    CGLError err = ao46_create_context_without_drawable(ctx);
    if (err != kCGLNoError) {
        return err;
    }

    return AO46LibGLContextAttachHeadless(*ctx);
}

CGLError AO46LibGLContextCreateForWindow(void *window, CGLContextObj *ctx)
{
    CGLError err = ao46_create_context_without_drawable(ctx);
    if (err != kCGLNoError) {
        return err;
    }

    return AO46LibGLContextAttachWindow(*ctx, window);
}

CGLError AO46LibGLContextAttachHeadless(CGLContextObj ctx)
{
    return AO46ICDCreateHeadlessDrawable((AO46ContextRef)ctx);
}

CGLError AO46LibGLContextAttachWindow(CGLContextObj ctx, void *window)
{
    return AO46ICDAttachWindowToContext((AO46ContextRef)ctx, window);
}

CGLError AO46LibGLContextClearDrawable(CGLContextObj ctx)
{
    return AO46ICDClearDrawable((AO46ContextRef)ctx);
}

AO46DrawableKind AO46LibGLContextGetDrawableKind(CGLContextObj ctx)
{
    return AO46ICDGetDrawableKind((AO46ContextRef)ctx);
}

void *AO46LibGLContextGetWindowHandle(CGLContextObj ctx)
{
    return AO46ICDGetWindowHandleForContext((AO46ContextRef)ctx);
}

void *AO46LibGLContextResolve(const char *symbol)
{
    return AO46ICDGetProcAddress(symbol);
}
