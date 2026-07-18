#import "AppleNSOpenGLCompat.h"
#import <AppKit/NSView.h>

#include <stdio.h>

static int expect_true(const char *label, int condition)
{
    if (condition) {
        return 0;
    }

    fprintf(stderr, "%s failed\n", label);
    return 1;
}

int main(void)
{
    @autoreleasepool {
        const AO46NSOpenGLPixelFormatAttribute attribs[] = {
            AO46NSOpenGLPFADoubleBuffer,
            AO46NSOpenGLPFASampleBuffers,
            1,
            AO46NSOpenGLPFASamples,
            4,
            AO46NSOpenGLPFAWindow,
            AO46NSOpenGLPFAPixelBuffer,
            AO46NSOpenGLPFAOpenGLProfile,
            AO46NSOpenGLProfileVersion4_6Core,
            0
        };
        GLint major = 0;
        GLint minor = 0;
        GLint value = 0;
        GLint has_drawable = 0;
        GLint swap_interval = 2;
        NSData *attribute_data = nil;
        NSData *archive_data = nil;
        NSError *archive_error = nil;
        NSError *unarchive_error = nil;
        NSView *view = nil;
        AO46NSOpenGLPixelBuffer *bound_pixel_buffer = nil;
        AO46NSOpenGLPixelFormat *format = nil;
        AO46NSOpenGLPixelFormat *format_from_data = nil;
        AO46NSOpenGLPixelFormat *format_from_archive = nil;
        AO46NSOpenGLPixelFormat *mutable_format = nil;
        AO46NSOpenGLContext *context = nil;
        AO46NSOpenGLPixelBuffer *pixel_buffer = nil;

        NSOpenGLGetVersion(&major, &minor);
        if (expect_true("NSOpenGLGetVersion major", major == 4) ||
            expect_true("NSOpenGLGetVersion minor", minor == 6)) {
            return 1;
        }

        AO46NSOpenGLSetOption(AO46NSOpenGLGOUseBuildCache, 1);
        AO46NSOpenGLGetOption(AO46NSOpenGLGOUseBuildCache, &value);
        if (expect_true("NSOpenGL use-build-cache round-trip", value == 1)) {
            return 1;
        }

        format = [[AO46NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
        if (expect_true("AO46NSOpenGLPixelFormat exists", format != nil) ||
            expect_true("AO46NSOpenGLPixelFormat virtual screens", format.numberOfVirtualScreens == 1)) {
            return 1;
        }

        [format getValues:&value forAttribute:AO46NSOpenGLPFAOpenGLProfile forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat preserves 4.6 profile request",
                        value == AO46NSOpenGLProfileVersion4_6Core)) {
            return 1;
        }

        [format getValues:&value forAttribute:AO46NSOpenGLPFASampleBuffers forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat sample buffers", value == 1)) {
            return 1;
        }

        [format getValues:&value forAttribute:AO46NSOpenGLPFASamples forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat samples", value == 4)) {
            return 1;
        }

        attribute_data = [format attributes];
        if (expect_true("AO46NSOpenGLPixelFormat attributes exist",
                        attribute_data != nil &&
                        [attribute_data length] >= sizeof(AO46NSOpenGLPixelFormatAttribute))) {
            return 1;
        }

        format_from_data = [[AO46NSOpenGLPixelFormat alloc] initWithData:attribute_data];
        if (expect_true("AO46NSOpenGLPixelFormat initWithData", format_from_data != nil)) {
            return 1;
        }

        [format_from_data getValues:&value forAttribute:AO46NSOpenGLPFAOpenGLProfile forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat initWithData preserves profile",
                        value == AO46NSOpenGLProfileVersion4_6Core)) {
            return 1;
        }

        mutable_format = [[AO46NSOpenGLPixelFormat alloc] init];
        [mutable_format setAttributes:attribute_data];
        [mutable_format getValues:&value forAttribute:AO46NSOpenGLPFASamples forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat setAttributes preserves samples", value == 4)) {
            return 1;
        }

        archive_data = [NSKeyedArchiver archivedDataWithRootObject:format
                                             requiringSecureCoding:YES
                                                             error:&archive_error];
        if (expect_true("AO46NSOpenGLPixelFormat archive succeeds",
                        archive_data != nil && archive_error == nil)) {
            return 1;
        }

        format_from_archive = [NSKeyedUnarchiver unarchivedObjectOfClass:[AO46NSOpenGLPixelFormat class]
                                                                fromData:archive_data
                                                                   error:&unarchive_error];
        if (expect_true("AO46NSOpenGLPixelFormat unarchive succeeds",
                        format_from_archive != nil && unarchive_error == nil)) {
            return 1;
        }

        [format_from_archive getValues:&value forAttribute:AO46NSOpenGLPFAOpenGLProfile forVirtualScreen:0];
        if (expect_true("AO46NSOpenGLPixelFormat archive preserves profile",
                        value == AO46NSOpenGLProfileVersion4_6Core)) {
            return 1;
        }

        context = [[AO46NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
        if (expect_true("AO46NSOpenGLContext exists", context != nil)) {
            return 1;
        }

        [context setValues:&swap_interval forParameter:AO46NSOpenGLContextParameterSwapInterval];
        [context getValues:&value forParameter:AO46NSOpenGLContextParameterSwapInterval];
        if (expect_true("AO46NSOpenGLContext swap interval round-trip", value == 2)) {
            return 1;
        }

        view = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 64.0, 64.0)];
        [context setView:view];
        [context getValues:&has_drawable forParameter:AO46NSOpenGLContextParameterHasDrawable];
        if (expect_true("AO46NSOpenGLContext view drawable attached", has_drawable == 1) ||
            expect_true("AO46NSOpenGLContext view round-trip", [context view] == view)) {
            return 1;
        }

        [context clearDrawable];
        [context getValues:&has_drawable forParameter:AO46NSOpenGLContextParameterHasDrawable];
        if (expect_true("AO46NSOpenGLContext view drawable cleared", has_drawable == 0) ||
            expect_true("AO46NSOpenGLContext view cleared", [context view] == nil)) {
            return 1;
        }

        [context createTexture:GL_TEXTURE_2D fromView:view internalFormat:GL_RGBA8];
        [context getValues:&has_drawable forParameter:AO46NSOpenGLContextParameterHasDrawable];
        if (expect_true("AO46NSOpenGLContext createTexture binds view", has_drawable == 1) ||
            expect_true("AO46NSOpenGLContext createTexture keeps view", [context view] == view)) {
            return 1;
        }

        pixel_buffer = [[AO46NSOpenGLPixelBuffer alloc] initWithTextureTarget:GL_TEXTURE_2D
                                                         textureInternalFormat:GL_RGBA8
                                                          textureMaxMipMapLevel:2
                                                                     pixelsWide:64
                                                                     pixelsHigh:64];
        if (expect_true("AO46NSOpenGLPixelBuffer exists", pixel_buffer != nil)) {
            return 1;
        }

        [context setPixelBuffer:pixel_buffer cubeMapFace:0 mipMapLevel:1 currentVirtualScreen:0];
        [context getValues:&has_drawable forParameter:AO46NSOpenGLContextParameterHasDrawable];
        bound_pixel_buffer = [context pixelBuffer];
        if (expect_true("AO46NSOpenGLContext drawable attached", has_drawable == 1) ||
            expect_true("AO46NSOpenGLContext view released on pbuffer switch", [context view] == nil) ||
            expect_true("AO46NSOpenGLContext pixel buffer bound", bound_pixel_buffer != nil) ||
            expect_true("AO46NSOpenGLContext pixel buffer width", [bound_pixel_buffer pixelsWide] == 64) ||
            expect_true("AO46NSOpenGLContext pixel buffer mip level", [context pixelBufferMipMapLevel] == 1)) {
            return 1;
        }

        [context makeCurrentContext];
        if (expect_true("AO46NSOpenGLContext currentContext identity",
                        [AO46NSOpenGLContext currentContext] == context)) {
            return 1;
        }

        [context update];
        [context flushBuffer];
        [context setTextureImageToPixelBuffer:pixel_buffer colorBuffer:GL_FRONT];
        [context clearDrawable];
        [context getValues:&has_drawable forParameter:AO46NSOpenGLContextParameterHasDrawable];
        if (expect_true("AO46NSOpenGLContext drawable cleared", has_drawable == 0)) {
            return 1;
        }

        [AO46NSOpenGLContext clearCurrentContext];
        if (expect_true("AO46NSOpenGLContext currentContext cleared",
                        [AO46NSOpenGLContext currentContext] == nil)) {
            return 1;
        }
    }

    return 0;
}
