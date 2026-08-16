/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import "NSVulkan_KHR.h"

#include <math.h>
#include <stdint.h>

static uint32_t
avk143_cvk_drawable_extent(CGFloat value)
{
   if (!(value > 0.0))
      return 0;
   if (value >= (CGFloat)UINT32_MAX)
      return UINT32_MAX;

   return (uint32_t)ceil(value);
}

@implementation NSVulkanKHRSurface {
   __weak NSView *_view;
   NSVulkanKHRSurfaceState _state;
   CGSize _drawableSize;
   CGFloat _backingScaleFactor;
   NSUInteger _generation;
}

- (instancetype)initWithView:(NSView *)view
{
   self = [super init];
   if (!self)
      return nil;

   _backingScaleFactor = 1.0;
   self.view = view;
   return self;
}

- (NSView *)view
{
   return _view;
}

- (void)setView:(NSView *)view
{
   if (_view == view) {
      [self update];
      return;
   }

   _view = view;
   if (view) {
      _state = NSVulkanKHRSurfaceStateDetached;
      [self update];
   } else {
      _state = NSVulkanKHRSurfaceStateDetached;
      _drawableSize = CGSizeZero;
      _backingScaleFactor = 1.0;
      ++_generation;
   }
}

- (NSVulkanKHRSurfaceState)state
{
   return _state;
}

- (CGSize)drawableSize
{
   return _drawableSize;
}

- (CGFloat)backingScaleFactor
{
   return _backingScaleFactor;
}

- (NSUInteger)generation
{
   return _generation;
}

- (void)update
{
   NSView *view = _view;
   CGFloat scale;
   CGSize size;

   if (!view) {
      if (_state != NSVulkanKHRSurfaceStateDetached ||
          !CGSizeEqualToSize(_drawableSize, CGSizeZero) ||
          _backingScaleFactor != 1.0) {
         _state = NSVulkanKHRSurfaceStateDetached;
         _drawableSize = CGSizeZero;
         _backingScaleFactor = 1.0;
         ++_generation;
      }
      return;
   }

   scale = view.window ? view.window.backingScaleFactor : 1.0;
   if (scale <= 0.0)
      scale = 1.0;
   size = CGSizeMake(MAX(0.0, view.bounds.size.width * scale),
                     MAX(0.0, view.bounds.size.height * scale));

   if (_state != NSVulkanKHRSurfaceStateAttached ||
       !CGSizeEqualToSize(_drawableSize, size) ||
       _backingScaleFactor != scale) {
      _state = NSVulkanKHRSurfaceStateAttached;
      _drawableSize = size;
      _backingScaleFactor = scale;
      ++_generation;
   }
}

- (BOOL)getCVKSurfaceSnapshot:(struct AVK143CVKSurfaceSnapshot *)outSnapshot
{
   if (!outSnapshot)
      return NO;

   [self update];
   *outSnapshot = (struct AVK143CVKSurfaceSnapshot){
      .structure_size = sizeof(*outSnapshot),
      .abi_version = AVK143_CVK_ABI_VERSION,
      .state = _state == NSVulkanKHRSurfaceStateAttached
         ? AVK143_CVK_DRAWABLE_ATTACHED
         : AVK143_CVK_DRAWABLE_DETACHED,
      .drawable_width = avk143_cvk_drawable_extent(_drawableSize.width),
      .drawable_height = avk143_cvk_drawable_extent(_drawableSize.height),
      .backing_scale_factor = (float)_backingScaleFactor,
      .generation = _generation,
   };
   return YES;
}

- (void)clearDrawable
{
   self.view = nil;
}

@end
