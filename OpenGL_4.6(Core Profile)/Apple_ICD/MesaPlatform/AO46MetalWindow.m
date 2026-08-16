/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/CAMetalLayer.h>

#include "AO46MetalWindow.h"

static bool
ao46_metal_window_layer_is_empty(const struct AO46MetalWindowLayer *layer)
{
   return layer && !layer->adapter && !layer->native_layer &&
          layer->width == 0 && layer->height == 0 &&
          layer->format == AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM &&
          layer->color_space == AO46_METAL_WINDOW_COLOR_SPACE_SRGB;
}

static bool
ao46_metal_window_layer_color_space(
   CAMetalLayer *layer, bool assign_default,
   enum AO46MetalWindowColorSpace *out_color_space)
{
   CGColorSpaceRef color_space;
   CFStringRef name;
   bool is_srgb;

   if (!layer || !out_color_space)
      return false;

   color_space = layer.colorspace;
   if (!color_space && assign_default) {
      color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      if (!color_space)
         return false;
      layer.colorspace = color_space;
      CGColorSpaceRelease(color_space);
      color_space = layer.colorspace;
   }
   if (!color_space)
      return false;

   name = CGColorSpaceCopyName(color_space);
   is_srgb = name && CFEqual(name, kCGColorSpaceSRGB);
   if (name)
      CFRelease(name);
   if (!is_srgb)
      return false;

   *out_color_space = AO46_METAL_WINDOW_COLOR_SPACE_SRGB;
   return true;
}

static bool
ao46_metal_window_layer_format(MTLPixelFormat native_format,
                               enum AO46MetalTextureFormat *out_format)
{
   if (!out_format)
      return false;

   switch (native_format) {
   case MTLPixelFormatRGBA8Unorm:
      *out_format = AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
      return true;
   case MTLPixelFormatBGRA8Unorm:
      *out_format = AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM;
      return true;
   default:
      return false;
   }
}

bool
AO46MetalWindowLayerAcquire(const struct AO46MetalAdapter *adapter,
                            void *native_window_or_view,
                            struct AO46MetalWindowLayer *out_layer)
{
   __block bool acquired = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !native_window_or_view ||
       !out_layer || !ao46_metal_window_layer_is_empty(out_layer))
      return false;

   @autoreleasepool {
      id candidate = (__bridge id)native_window_or_view;
      NSView *view = nil;
      CAMetalLayer *layer = nil;
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      CGSize drawable_size;
      enum AO46MetalTextureFormat format;
      enum AO46MetalWindowColorSpace color_space;

      if ([candidate isKindOfClass:[CAMetalLayer class]]) {
         layer = (CAMetalLayer *)candidate;
      } else if ([candidate isKindOfClass:[NSWindow class]]) {
         view = ((NSWindow *)candidate).contentView;
      } else if ([candidate isKindOfClass:[NSView class]]) {
         view = (NSView *)candidate;
      } else {
         goto out;
      }

      if (!layer) {
         CALayer *existing_layer;

         if (!view)
            goto out;
         existing_layer = view.layer;
         if (existing_layer && ![existing_layer isKindOfClass:[CAMetalLayer class]])
            goto out;
         if (!existing_layer) {
            view.wantsLayer = YES;
            layer = [CAMetalLayer layer];
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            view.layer = layer;
         } else {
            layer = (CAMetalLayer *)existing_layer;
         }

         NSRect backing_bounds = [view convertRectToBacking:view.bounds];
         if (backing_bounds.size.width > 0 && backing_bounds.size.height > 0)
            layer.drawableSize = backing_bounds.size;
      }

      if ((layer.device && layer.device != device) ||
          !ao46_metal_window_layer_format(layer.pixelFormat, &format) ||
          !ao46_metal_window_layer_color_space(layer, true, &color_space))
         goto out;
      layer.device = device;
      /* AO46 presents by copying Mesa's color target into this texture. */
      layer.framebufferOnly = NO;
      drawable_size = layer.drawableSize;
      if (drawable_size.width < 1 || drawable_size.height < 1 ||
          drawable_size.width > adapter->max_texture_dimension_2d ||
          drawable_size.height > adapter->max_texture_dimension_2d ||
          drawable_size.width > UINT32_MAX || drawable_size.height > UINT32_MAX)
         goto out;

      *out_layer = (struct AO46MetalWindowLayer){
         .adapter = adapter,
         .native_layer = (__bridge_retained void *)layer,
         .width = (uint32_t)drawable_size.width,
         .height = (uint32_t)drawable_size.height,
         .format = format,
         .color_space = color_space,
      };
      acquired = true;
out:
      ;
   }

   return acquired;
}

bool
AO46MetalWindowLayerIsCurrent(const struct AO46MetalWindowLayer *layer)
{
   CAMetalLayer *native_layer;
   enum AO46MetalTextureFormat format;
   enum AO46MetalWindowColorSpace color_space;

   if (!layer || !AO46MetalAdapterIsCurrent(layer->adapter) ||
       !layer->native_layer || layer->width == 0 || layer->height == 0)
      return false;

   native_layer = (__bridge CAMetalLayer *)layer->native_layer;
   return native_layer.device == (__bridge id<MTLDevice>)layer->adapter->device &&
          native_layer.drawableSize.width == layer->width &&
          native_layer.drawableSize.height == layer->height &&
          ao46_metal_window_layer_format(native_layer.pixelFormat, &format) &&
          format == layer->format &&
          ao46_metal_window_layer_color_space(native_layer, false, &color_space) &&
          color_space == layer->color_space;
}

void
AO46MetalWindowLayerSetDisplaySync(const struct AO46MetalWindowLayer *layer,
                                   bool enabled)
{
   if (!AO46MetalWindowLayerIsCurrent(layer))
      return;

   ((__bridge CAMetalLayer *)layer->native_layer).displaySyncEnabled = enabled;
}

void
AO46MetalWindowLayerRelease(struct AO46MetalWindowLayer *layer)
{
   if (!layer)
      return;
   if (layer->native_layer)
      CFBridgingRelease(layer->native_layer);
   *layer = (struct AO46MetalWindowLayer){0};
}
