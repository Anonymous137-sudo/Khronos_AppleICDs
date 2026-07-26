#ifndef AO46_MESA_BRIDGE_H
#define AO46_MESA_BRIDGE_H

#include <OpenGL/CGLTypes.h>
#include "AppleOpenGL46Runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialise the Mesa Gallium screen.
 * Must be called before any other bridge function.
 */
CGLError AO46MesaInit(void);

/**
 * Create a Mesa state tracker context from a pixel format.
 * share can be NULL.
 */
CGLError AO46MesaCreateContext(AO46PixelFormatRef pix,
                               AO46ContextRef share,
                               AO46ContextRef *out_ctx);

/**
 * Destroy a Mesa context.
 */
void AO46MesaDestroyContext(AO46ContextRef ctx);

/**
 * Make a context current on the calling thread.
 */
CGLError AO46MesaMakeCurrent(AO46ContextRef ctx);

/**
 * Get the current context for the thread.
 */
AO46ContextRef AO46MesaGetCurrent(void);

/**
 * Attach a window (NSView* or NSWindow*) as the drawable.
 * The bridge will create a CAMetalLayer and bind it.
 */
CGLError AO46MesaAttachWindow(AO46ContextRef ctx, void *window);

/**
 * Attach an offscreen buffer (manual memory) as drawable.
 */
CGLError AO46MesaAttachOffscreen(AO46ContextRef ctx,
                                 void *baseaddr,
                                 GLsizei width,
                                 GLsizei height,
                                 GLint rowbytes);

/**
 * Attach a PBuffer (wrapped as an offscreen render target).
 */
CGLError AO46MesaAttachPBuffer(AO46ContextRef ctx,
                               AO46PBufferRef pbuffer,
                               GLenum face,
                               GLint level,
                               GLint screen);

/**
 * Import the currently selected pbuffer image into the currently bound texture
 * for the pbuffer's target in the target context.
 */
CGLError AO46MesaImportPBufferToBoundTexture(AO46ContextRef ctx,
                                             AO46PBufferRef pbuffer,
                                             GLenum source);

/**
 * Detach any drawable.
 */
CGLError AO46MesaDetachDrawable(AO46ContextRef ctx);

/**
 * Update the drawable (e.g., window resize).
 */
CGLError AO46MesaUpdateDrawable(AO46ContextRef ctx);

/**
 * Flush the current drawable (swap buffers).
 */
CGLError AO46MesaSwapBuffers(AO46ContextRef ctx);

/**
 * Retrieve the OpenGL function pointer from Mesa's glapi.
 */
void *AO46MesaGetProcAddress(const char *procname);

/**
 * Query pixel format attributes from Mesa's capabilities.
 */
CGLError AO46MesaDescribePixelFormat(AO46PixelFormatRef pix,
                                     GLint pix_num,
                                     CGLPixelFormatAttribute attrib,
                                     GLint *value);

/**
 * PBuffer creation/destruction – now handled by Mesa's resources.
 */
CGLError AO46MesaCreatePBuffer(GLsizei width,
                               GLsizei height,
                               GLenum target,
                               GLenum internal_format,
                               GLint max_level,
                               AO46PBufferRef *out_pbuffer);
void AO46MesaDestroyPBuffer(AO46PBufferRef pbuffer);
CGLError AO46MesaDescribePBuffer(AO46PBufferRef pbuffer,
                                 GLsizei *width,
                                 GLsizei *height,
                                 GLenum *target,
                                 GLenum *internal_format,
                                 GLint *mipmap);

#ifdef __cplusplus
}
#endif

#endif /* AO46_MESA_BRIDGE_H */
