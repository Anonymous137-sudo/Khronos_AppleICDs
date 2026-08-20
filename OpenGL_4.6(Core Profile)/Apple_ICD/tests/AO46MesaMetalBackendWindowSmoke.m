/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "AO46MesaMetalBackend.h"

#include <stdio.h>

static int
fail(const char *message)
{
   fprintf(stderr, "AO46 Mesa backend window smoke: %s\n", message);
   return 1;
}

int
main(void)
{
   struct AO46MesaMetalBackendWindow window = {0};
   enum AO46MesaMetalBackendWindowFormat format;
   uint32_t width = 0;
   uint32_t height = 0;
   int result = 1;

   @autoreleasepool {
      CAMetalLayer *layer = [CAMetalLayer layer];

      layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      layer.drawableSize = CGSizeMake(16, 16);
      if (!AO46MesaMetalBackendWindowAcquire((__bridge void *)layer, &window) ||
          !AO46MesaMetalBackendWindowIsCurrent(&window) ||
          !AO46MesaMetalBackendWindowGetInfo(&window, &width, &height,
                                              &format) ||
          width != 16 || height != 16 ||
          format != AO46_MESA_METAL_BACKEND_WINDOW_BGRA8_UNORM)
         goto cleanup;

      AO46MesaMetalBackendWindowSetSwapInterval(&window, 0);
      layer.drawableSize = CGSizeMake(32, 24);
      if (AO46MesaMetalBackendWindowIsCurrent(&window) ||
          !AO46MesaMetalBackendWindowRefresh((__bridge void *)layer, &window) ||
          !AO46MesaMetalBackendWindowGetInfo(&window, &width, &height,
                                              &format) ||
          width != 32 || height != 24 ||
          format != AO46_MESA_METAL_BACKEND_WINDOW_BGRA8_UNORM)
         goto cleanup;

      result = 0;

cleanup:
      AO46MesaMetalBackendWindowRelease(&window);
   }

   return result ? fail("layer lifecycle validation failed") : 0;
}
