/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#import "NSVulkan_KHR.h"

#include <math.h>
#include <stdio.h>

static bool
avk143_equal(CGFloat lhs, CGFloat rhs)
{
   return fabs(lhs - rhs) < 0.001;
}

int
main(void)
{
   @autoreleasepool {
      NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 64, 32)];
      NSVulkanKHRSurface *surface =
         [[NSVulkanKHRSurface alloc] initWithView:view];
      CAMetalLayer *metal_layer = [CAMetalLayer layer];
      const NSUInteger attached_generation = surface.generation;
      CVKSurfaceSnapshot snapshot = {0};

      if (!surface || surface.view != view ||
          surface.state != NSVulkanKHRSurfaceStateAttached ||
          !avk143_equal(surface.drawableSize.width, 64.0) ||
          !avk143_equal(surface.drawableSize.height, 32.0) ||
          !avk143_equal(surface.backingScaleFactor, 1.0) ||
          attached_generation == 0) {
         fputs("AVK143 NSVulkan_KHR attach contract mismatched\n", stderr);
         return 1;
      }

      if (![surface attachMetalLayer:metal_layer] ||
          surface.metalLayer != metal_layer || view.layer == metal_layer ||
          !avk143_equal(metal_layer.contentsScale, 1.0) ||
          !avk143_equal(metal_layer.drawableSize.width, 64.0) ||
          !avk143_equal(metal_layer.drawableSize.height, 32.0)) {
         fputs("AVK143 NSVulkan_KHR Metal-layer handoff mismatched\n", stderr);
         return 1;
      }

      if (![surface getCVKSurfaceSnapshot:&snapshot] ||
          snapshot.structure_size != sizeof(snapshot) ||
          snapshot.abi_version != CVK_ABI_VERSION ||
          snapshot.state != kCVKDrawableAttached ||
          snapshot.drawable_width != 64 || snapshot.drawable_height != 32 ||
          !avk143_equal(snapshot.backing_scale_factor, 1.0) ||
          snapshot.generation != attached_generation) {
         fputs("CVK AppKit snapshot contract mismatched\n", stderr);
         return 1;
      }
      [surface update];
      if (surface.generation != attached_generation) {
         fputs("AVK143 NSVulkan_KHR changed without a drawable transition\n",
               stderr);
         return 1;
      }

      view.frame = NSMakeRect(0, 0, 128, 48);
      [surface update];
      if (surface.generation <= attached_generation ||
          !avk143_equal(surface.drawableSize.width, 128.0) ||
          !avk143_equal(surface.drawableSize.height, 48.0)) {
         fputs("AVK143 NSVulkan_KHR resize contract mismatched\n", stderr);
         return 1;
      }
      if (!avk143_equal(metal_layer.contentsScale, 1.0) ||
          !avk143_equal(metal_layer.drawableSize.width, 128.0) ||
          !avk143_equal(metal_layer.drawableSize.height, 48.0)) {
         fputs("AVK143 NSVulkan_KHR did not update the Metal layer\n", stderr);
         return 1;
      }
      if (![surface getCVKSurfaceSnapshot:&snapshot] ||
          snapshot.state != kCVKDrawableAttached ||
          snapshot.drawable_width != 128 || snapshot.drawable_height != 48 ||
          snapshot.generation != surface.generation) {
         fputs("CVK resize snapshot mismatched\n", stderr);
         return 1;
      }
      if (surface.metalLayer != metal_layer) {
         fputs("AVK143 NSVulkan_KHR lost the attached Metal layer\n", stderr);
         return 1;
      }

      const NSUInteger resized_generation = surface.generation;
      [surface clearDrawable];
      if (surface.view || surface.state != NSVulkanKHRSurfaceStateDetached ||
          !CGSizeEqualToSize(surface.drawableSize, CGSizeZero) ||
          surface.generation <= resized_generation || surface.metalLayer) {
         fputs("AVK143 NSVulkan_KHR detach contract mismatched\n", stderr);
         return 1;
      }
      if (![surface getCVKSurfaceSnapshot:&snapshot] ||
          snapshot.state != kCVKDrawableDetached ||
          snapshot.drawable_width != 0 || snapshot.drawable_height != 0 ||
          snapshot.generation != surface.generation) {
         fputs("CVK detach snapshot mismatched\n", stderr);
         return 1;
      }

      __weak NSView *weak_view = nil;
      @autoreleasepool {
         NSView *temporary_view =
            [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
         weak_view = temporary_view;
         surface.view = temporary_view;
      }
      [surface update];
      if (weak_view || surface.view ||
          surface.state != NSVulkanKHRSurfaceStateDetached) {
         fputs("AVK143 NSVulkan_KHR retained an AppKit view\n", stderr);
         return 1;
      }
   }

   return 0;
}
