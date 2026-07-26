#include <stddef.h>

#include "AppleOpenGL46Backend.h"
#include "AO46MesaBridge.h"

CGLError AO46BackendEnsureReady(void)
{
    return AO46MesaInit();
}

AO46BackendContextRef AO46BackendCreateContext(const AO46BackendContextCreateInfo *info)
{
    /* We don't create a backend context separately; it's integrated into AO46ContextRef.
     * This function is not used in the new design. Return NULL. */
    (void)info;
    return NULL;
}

void AO46BackendDestroyContext(AO46BackendContextRef ctx) { (void)ctx; }

void AO46BackendSetCurrentContext(AO46BackendContextRef ctx) { (void)ctx; }

AO46BackendContextRef AO46BackendGetCurrentContext(void) { return NULL; }

CGLError AO46BackendCreateHeadlessDrawable(AO46BackendContextRef ctx, void **out_renderer)
{
    /* This is handled by AO46CreateHeadlessDrawable in runtime */
    (void)ctx; (void)out_renderer;
    return kCGLNoError;
}

CGLError AO46BackendCreateWindowDrawable(AO46BackendContextRef ctx, void *window, void **out_renderer)
{
    return AO46MesaAttachWindow((AO46ContextRef)ctx, window);
}

CGLError AO46BackendBindOffscreenStorage(AO46BackendContextRef ctx,
                                         void *baseaddr,
                                         GLsizei width,
                                         GLsizei height,
                                         GLint rowbytes)
{
    return AO46MesaAttachOffscreen((AO46ContextRef)ctx, baseaddr, width, height, rowbytes);
}

void AO46BackendReleaseDrawable(AO46BackendContextRef ctx)
{
    AO46MesaDetachDrawable((AO46ContextRef)ctx);
}

void AO46BackendSwapBuffers(AO46BackendContextRef ctx)
{
    AO46MesaSwapBuffers((AO46ContextRef)ctx);
}

CGLError AO46BackendTexImagePBuffer(AO46BackendContextRef ctx,
                                    const void *storage,
                                    GLsizei width,
                                    GLsizei height,
                                    GLint rowbytes,
                                    GLenum target,
                                    GLenum internal_format,
                                    GLenum source)
{
    /* not used – pbuffer handling is in runtime */
    return kCGLNoError;
}

void *AO46BackendGetProcAddress(const char *procname)
{
    return AO46MesaGetProcAddress(procname);
}

void *AO46BackendCustomProcAddress(const char *procname) { return NULL; }

const char *AO46BackendIdentity(void)
{
    return "Mesa Gallium Metal backend";
}