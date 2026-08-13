#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

static bool
require_iogpu_symbol(void *image, const char *name)
{
   void *symbol = dlsym(image, name);
   Dl_info info = {};

   if (!symbol || !dladdr(symbol, &info) || !info.dli_fname ||
       !strstr(info.dli_fname, "IOGPU.framework") || !info.dli_sname ||
       strcmp(info.dli_sname, name) != 0) {
      fprintf(stderr, "IOGPU bridge symbol is unavailable: %s\n", name);
      return false;
   }

   printf("Apple AGX bridge symbol probe: image=%s symbol=%s\n", info.dli_fname,
          info.dli_sname);
   return true;
}

/* This development probe establishes only that the runtime loader exposes the
 * submit anchor observed by wrap.dylib. It deliberately does not call the
 * symbol: its signature, object ownership, and admissible inputs are separate
 * evidence gates for the Apple-native adapter. */
int
main(void)
{
   const char *path =
      "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU";
   void *image = dlopen(path, RTLD_LAZY | RTLD_LOCAL);

   if (!image) {
      fprintf(stderr, "IOGPU is unavailable on this profile: %s\n", dlerror());
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   static const char *const required_symbols[] = {
      "IOGPUDeviceCreate",
      "IOGPUCommandQueueCreate",
      "IOGPUCommandQueueGetConnect",
      "IOGPUCommandQueueGetID",
      "IOGPUCommandQueueRelease",
      "IOGPUCommandQueueSubmitCommandBuffers",
      "IOGPUMetalCommandBufferStorageCreateExt",
      "IOGPUResourceCreate",
      "IOGPUResourceGetGPUVirtualAddress",
      "IOGPUResourceGetGPUVirtualAddressLength",
      "IOGPUResourceRelease",
   };

   for (unsigned i = 0; i < sizeof(required_symbols) / sizeof(required_symbols[0]);
        ++i) {
      if (!require_iogpu_symbol(image, required_symbols[i])) {
         dlclose(image);
         return AO46_SKIP_UNSUPPORTED_PROFILE;
      }
   }

   dlclose(image);
   return 0;
}
