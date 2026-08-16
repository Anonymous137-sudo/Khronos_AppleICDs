/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/CAMetalLayer.h>

#include "AO46MetalAdapter.h"
#include "AO46MetalWindow.h"

#include <stdio.h>

static bool
ao46_layer_is_srgb(CAMetalLayer *layer)
{
   CGColorSpaceRef color_space = layer.colorspace;
   CFStringRef name = color_space ? CGColorSpaceCopyName(color_space) : NULL;
   const bool is_srgb = name && CFEqual(name, kCGColorSpaceSRGB);

   if (name)
      CFRelease(name);
   return is_srgb;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct AO46MetalWindowLayer window_layer = {0};
   struct AO46MetalWindowLayer rejected_layer = {0};
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("Window policy smoke could not create the Metal adapter\n", stderr);
      return 1;
   }

   @autoreleasepool {
      CAMetalLayer *layer = [CAMetalLayer layer];
      CAMetalLayer *display_p3_layer = [CAMetalLayer layer];
      CGColorSpaceRef display_p3;

      layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      layer.drawableSize = CGSizeMake(16, 16);
      if (!AO46MetalWindowLayerAcquire(&adapter, (__bridge void *)layer,
                                       &window_layer) ||
          !AO46MetalWindowLayerIsCurrent(&window_layer) ||
          window_layer.color_space != AO46_METAL_WINDOW_COLOR_SPACE_SRGB ||
          !ao46_layer_is_srgb(layer)) {
         fputs("Window policy smoke did not establish an sRGB layer\n", stderr);
         failed = 1;
         goto out;
      }
      AO46MetalWindowLayerRelease(&window_layer);

      display_p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
      if (!display_p3) {
         fputs("Window policy smoke could not create Display P3\n", stderr);
         failed = 1;
         goto out;
      }
      display_p3_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      display_p3_layer.drawableSize = CGSizeMake(16, 16);
      display_p3_layer.colorspace = display_p3;
      CGColorSpaceRelease(display_p3);
      if (AO46MetalWindowLayerAcquire(&adapter, (__bridge void *)display_p3_layer,
                                      &rejected_layer) ||
          rejected_layer.adapter || rejected_layer.native_layer ||
          rejected_layer.width || rejected_layer.height) {
         fputs("Window policy smoke accepted an unsupported wide-gamut layer\n",
               stderr);
         failed = 1;
      }
   }

out:
   AO46MetalWindowLayerRelease(&rejected_layer);
   AO46MetalWindowLayerRelease(&window_layer);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
