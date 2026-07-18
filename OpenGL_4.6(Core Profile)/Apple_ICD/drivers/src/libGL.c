#include "AppleOpenGLICD.h"

#include <stdbool.h>

bool AO46LibGLBootstrap(void)
{
    return AO46ICDEnsureDriver() == kCGLNoError;
}

void *glXGetProcAddress(const GLubyte *procname)
{
    return AO46ICDGetProcAddressBytes(procname);
}

void *glXGetProcAddressARB(const GLubyte *procname)
{
    return AO46ICDGetProcAddressBytes(procname);
}
