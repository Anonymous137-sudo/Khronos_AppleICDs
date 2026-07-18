#ifndef APPLE_OPENGL46_BACKEND_H
#define APPLE_OPENGL46_BACKEND_H

#include <OpenGL/CGLTypes.h>
#include "glcorearb.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AO46BackendContextRec *AO46BackendContextRef;

CGLError AO46BackendEnsureReady(void);
AO46BackendContextRef AO46BackendCreateContext(GLenum color_format,
                                               GLenum color_type,
                                               GLenum depth_format,
                                               GLenum depth_type,
                                               GLenum stencil_format,
                                               GLenum stencil_type);
void AO46BackendDestroyContext(AO46BackendContextRef ctx);
void AO46BackendSetCurrentContext(AO46BackendContextRef ctx);
AO46BackendContextRef AO46BackendGetCurrentContext(void);
CGLError AO46BackendCreateHeadlessDrawable(AO46BackendContextRef ctx, void **out_renderer);
CGLError AO46BackendCreateWindowDrawable(AO46BackendContextRef ctx, void *window, void **out_renderer);
CGLError AO46BackendBindOffscreenStorage(AO46BackendContextRef ctx,
                                         void *baseaddr,
                                         GLsizei width,
                                         GLsizei height,
                                         GLint rowbytes);
void AO46BackendReleaseDrawable(AO46BackendContextRef ctx);
void AO46BackendSwapBuffers(AO46BackendContextRef ctx);
CGLError AO46BackendTexImagePBuffer(AO46BackendContextRef ctx,
                                    const void *storage,
                                    GLsizei width,
                                    GLsizei height,
                                    GLint rowbytes,
                                    GLenum target,
                                    GLenum internal_format,
                                    GLenum source);
void *AO46BackendGetProcAddress(const char *procname);
void *AO46BackendCustomProcAddress(const char *procname);
void *AO46GL2MTLLookupProcAddress(const char *procname);
const char *AO46BackendIdentity(void);

#ifdef __cplusplus
}
#endif

#endif
