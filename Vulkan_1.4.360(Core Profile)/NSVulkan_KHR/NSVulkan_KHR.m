/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import "NSVulkan_KHR.h"

#import <QuartzCore/CAMetalLayer.h>

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
   CAMetalLayer *_metalLayer;
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
      _metalLayer = nil;
      _state = NSVulkanKHRSurfaceStateDetached;
      _drawableSize = CGSizeZero;
      _backingScaleFactor = 1.0;
      ++_generation;
   }
}

- (CAMetalLayer *)metalLayer
{
   return _metalLayer;
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
      _metalLayer = nil;
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

   if (_metalLayer) {
      _metalLayer.contentsScale = scale;
      _metalLayer.drawableSize = size;
   }
}

- (BOOL)getCVKSurfaceSnapshot:(CVKSurfaceSnapshot *)outSnapshot
{
   if (!outSnapshot)
      return NO;

   [self update];
   *outSnapshot = (CVKSurfaceSnapshot){
      .structure_size = sizeof(*outSnapshot),
      .abi_version = CVK_ABI_VERSION,
      .state = _state == NSVulkanKHRSurfaceStateAttached
         ? kCVKDrawableAttached
         : kCVKDrawableDetached,
      .drawable_width = avk143_cvk_drawable_extent(_drawableSize.width),
      .drawable_height = avk143_cvk_drawable_extent(_drawableSize.height),
      .backing_scale_factor = (float)_backingScaleFactor,
      .generation = _generation,
   };
   return YES;
}

- (BOOL)attachMetalLayer:(CAMetalLayer *)layer
{
   if (!layer || !_view)
      return NO;

   [self update];
   if (_state != NSVulkanKHRSurfaceStateAttached)
      return NO;

   _metalLayer = layer;
   _metalLayer.contentsScale = _backingScaleFactor;
   _metalLayer.drawableSize = _drawableSize;
   return YES;
}

- (void)clearDrawable
{
   self.view = nil;
}

@end
