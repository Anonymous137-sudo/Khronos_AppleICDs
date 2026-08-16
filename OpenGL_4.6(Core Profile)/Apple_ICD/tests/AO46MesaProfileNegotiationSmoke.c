#include "AppleOpenGL46Runtime.h"
#include "AO46MetalBackend.h"

#include "pipe/p_screen.h"

#include <stdio.h>
#include <string.h>

static int
fail(const char *label, CGLError error)
{
    fprintf(stderr, "%s failed with CGLError %d\n", label, error);
    return 1;
}

int
main(void)
{
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_6_Core,
        0,
    };
    AO46PixelFormatRef pixel_format = NULL;
    AO46ContextRef context = NULL;
    GLubyte storage[4] = {0};
    GLint pixel_format_count = 0;
    GLint major = 0;
    GLint minor = 0;
    GLubyte pixel[4] = {0};
    CGLError error;
    struct pipe_screen *screen;

    screen = AO46MetalBackendCreateScreen();
    if (!screen || !screen->get_name ||
        strcmp(screen->get_name(screen), "AO46 Metal Gallium") != 0) {
        return fail("AO46 promoted Metal Gallium screen", kCGLBadContext);
    }

    error = AO46ChoosePixelFormat(attributes, &pixel_format, &pixel_format_count);
    if (error != kCGLNoError || !pixel_format || pixel_format_count != 1) {
        return fail("AO46ChoosePixelFormat(GL 4.6 core)", error);
    }

    error = AO46CreateContext(pixel_format, NULL, &context);
    if ((error == kCGLBadPixelFormat || error == kCGLBadContext) && !context) {
        if ((AO46MetalBackendContextBlockers() &
             AO46_METAL_CONTEXT_BLOCKER_GL46_CAPABILITY) == 0) {
            AO46DestroyPixelFormat(pixel_format);
            return fail("AO46CreateContext(GL 4.6 core) without capability blocker",
                        error);
        }
        AO46DestroyPixelFormat(pixel_format);
        return 0;
    }
    if (error != kCGLNoError || !context) {
        AO46DestroyPixelFormat(pixel_format);
        return fail("AO46CreateContext(GL 4.6 core)", error);
    }

    error = AO46SetOffScreen(context, 1, 1, 4, storage);
    if (error == kCGLNoError)
        error = AO46SetCurrentContext(context);
    if (error != kCGLNoError) {
        AO46DestroyContext(context);
        AO46DestroyPixelFormat(pixel_format);
        return fail("AO46SetCurrentContext(GL 4.6 core)", error);
    }

    glGetIntegerv(GL_MAJOR_VERSION, &major);
    glGetIntegerv(GL_MINOR_VERSION, &minor);
    glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    if (glGetError() != GL_NO_ERROR || pixel[0] < 63 || pixel[0] > 65 ||
        pixel[1] < 127 || pixel[1] > 129 || pixel[2] < 190 ||
        pixel[2] > 192 || pixel[3] != 255) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(context);
        AO46DestroyPixelFormat(pixel_format);
        return fail("AO46 native Mesa offscreen clear/readback", kCGLBadContext);
    }
    AO46SetCurrentContext(NULL);
    AO46DestroyContext(context);
    AO46DestroyPixelFormat(pixel_format);

    if (major < 4 || (major == 4 && minor < 6)) {
        fprintf(stderr, "GL 4.6 request realized as %d.%d\n", major, minor);
        return 1;
    }

    return 0;
}
