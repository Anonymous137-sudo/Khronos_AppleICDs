/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <QuartzCore/CAMetalLayer.h>
#import <Metal/MTLTexture.h>

#include "AO46MetalDrawable.h"
#include "kosmickrisp/bridge/mtl_bridge.h"

#include <stdatomic.h>

static atomic_uint_fast64_t ao46_metal_drawable_generation = 1;

static bool
ao46_metal_drawable_is_empty(const struct AO46MetalDrawable *drawable)
{
   return drawable && !drawable->adapter && !drawable->native_drawable &&
          !drawable->texture.adapter && !drawable->texture.native_texture &&
          !drawable->texture.native_iosurface &&
          drawable->texture.width == 0 && drawable->texture.height == 0 &&
          drawable->generation == 0 && !drawable->retained_by_submission;
}

static bool
ao46_metal_drawable_texture_format(MTLPixelFormat native_format,
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
AO46MetalDrawableAcquireFromLayer(
   const struct AO46MetalAdapter *adapter, void *native_metal_layer,
   struct AO46MetalDrawable *out_drawable)
{
   __block bool acquired = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !native_metal_layer ||
       !out_drawable || !ao46_metal_drawable_is_empty(out_drawable))
      return false;

   @autoreleasepool {
      CAMetalLayer *layer = (__bridge CAMetalLayer *)native_metal_layer;
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      id<CAMetalDrawable> native_drawable;
      id<MTLTexture> texture;
      enum AO46MetalTextureFormat format;

      if (![layer isKindOfClass:[CAMetalLayer class]])
         goto out;
      if (layer.device && layer.device != device)
         goto out;
      if (!layer.device)
         layer.device = device;

      native_drawable = [layer nextDrawable];
      texture = native_drawable.texture;
      if (!native_drawable || !texture || texture.device != device ||
          texture.width == 0 || texture.height == 0 ||
          texture.width > adapter->max_texture_dimension_2d ||
          texture.height > adapter->max_texture_dimension_2d ||
          !ao46_metal_drawable_texture_format(texture.pixelFormat, &format))
         goto out;

      *out_drawable = (struct AO46MetalDrawable){
         .adapter = adapter,
         .native_drawable = (__bridge_retained void *)native_drawable,
         .texture = {
            .adapter = adapter,
            .native_texture = (__bridge_retained void *)texture,
            .width = (uint32_t)texture.width,
            .height = (uint32_t)texture.height,
            .format = format,
         },
         .generation = atomic_fetch_add_explicit(
            &ao46_metal_drawable_generation, 1, memory_order_relaxed),
      };
      acquired = AO46MetalTextureIsCurrent(&out_drawable->texture) &&
         AO46MetalAdapterTrackExternalAllocation(adapter,
                                                 out_drawable->texture.native_texture);
      if (!acquired)
         AO46MetalDrawableRelease(out_drawable);

out:
      ;
   }

   return acquired;
}

bool
AO46MetalDrawableIsCurrent(const struct AO46MetalDrawable *drawable)
{
   return drawable && AO46MetalAdapterIsCurrent(drawable->adapter) &&
          drawable->native_drawable && drawable->generation != 0 &&
          AO46MetalTextureIsCurrent(&drawable->texture) &&
          drawable->texture.adapter == drawable->adapter;
}

void
AO46MetalDrawableRelease(struct AO46MetalDrawable *drawable)
{
   if (!drawable)
      return;

   if (drawable->retained_by_submission) {
      /* The submission retires MTL4 residency after feedback completes. */
      if (drawable->texture.native_texture)
         CFBridgingRelease(drawable->texture.native_texture);
      drawable->texture = (struct AO46MetalTexture){0};
   } else {
      AO46MetalTextureDestroy(&drawable->texture);
   }
   if (drawable->native_drawable)
      CFBridgingRelease(drawable->native_drawable);
   *drawable = (struct AO46MetalDrawable){0};
}

bool
AO46MetalDrawablePresent(struct AO46MetalDrawable *drawable,
                         struct AO46MetalSubmission *submission)
{
   if (!AO46MetalDrawableIsCurrent(drawable) || !submission ||
       submission->adapter != drawable->adapter ||
       !submission->native_command_buffer ||
       drawable->retained_by_submission)
      return false;

   if (submission->uses_mtl4) {
      if (!AO46MetalAdapterSupportsMTL4Submission(drawable->adapter))
         return false;
      if (submission->native_presentation_drawable ||
          submission->native_presentation_allocation)
         return false;
      submission->native_presentation_drawable = (void *)CFBridgingRetain(
         (__bridge id)drawable->native_drawable);
      submission->native_presentation_allocation = (void *)CFBridgingRetain(
         (__bridge id)drawable->texture.native_texture);
      drawable->retained_by_submission = true;
      mtl_command_queue_signal_drawable(
         (mtl_command_queue *)drawable->adapter->mtl4_queue,
         drawable->native_drawable);
      mtl_drawable_present(drawable->native_drawable);
      return true;
   }

   if (!AO46MetalSubmissionWait((struct AO46MetalSubmission *)submission))
      return false;
   mtl_drawable_present(drawable->native_drawable);
   return true;
}
