#ifndef APPLE_OPENGL46_LIBGLCONTEXT_H
#define APPLE_OPENGL46_LIBGLCONTEXT_H

#include <stdbool.h>

#include "AppleOpenGLICD.h"

#ifdef __cplusplus
extern "C" {
#endif

bool AO46LibGLContextBootstrap(void);

CGLError AO46LibGLContextCreate(CGLContextObj *ctx);
CGLError AO46LibGLContextCreateHeadless(CGLContextObj *ctx);
CGLError AO46LibGLContextCreateForWindow(void *window, CGLContextObj *ctx);
CGLError AO46LibGLContextAttachHeadless(CGLContextObj ctx);
CGLError AO46LibGLContextAttachWindow(CGLContextObj ctx, void *window);
CGLError AO46LibGLContextClearDrawable(CGLContextObj ctx);
AO46DrawableKind AO46LibGLContextGetDrawableKind(CGLContextObj ctx);
void *AO46LibGLContextGetWindowHandle(CGLContextObj ctx);
void *AO46LibGLContextResolve(const char *symbol);

#ifdef __cplusplus
}
#endif

#endif
