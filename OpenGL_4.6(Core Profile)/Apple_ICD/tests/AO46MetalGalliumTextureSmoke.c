/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MetalAdapter.h"
#include "AO46MetalGalliumScreen.h"

#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/u_inlines.h"

#include <stdint.h>
#include <stdio.h>

static bool
ao46_verify_clear(struct pipe_screen *screen, struct pipe_context *context,
                  enum pipe_format format, const unsigned char expected[4])
{
   struct pipe_resource texture_template = {
      .target = PIPE_TEXTURE_2D,
      .format = format,
      .width0 = 8,
      .height0 = 4,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   struct pipe_surface *surface = NULL;
   struct pipe_resource *texture = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_box texture_box = {
      .width = 8,
      .height = 4,
      .depth = 1,
   };
   struct pipe_box readback_box = {
      .height = 1,
      .depth = 1,
   };
   union pipe_color_union clear_color = {.f = {1.0f, 0.0f, 0.0f, 1.0f}};
   size_t row_pitch = 0;
   size_t readback_size = 0;
   bool verified = false;

   texture = screen->resource_create(screen, &texture_template);
   surface = AO46MetalGalliumSurfaceCreate(texture);
   if (!texture || !surface ||
       !AO46MetalGalliumTextureGetTransferLayout(texture, texture_box.width,
                                                  texture_box.height, &row_pitch,
                                                  &readback_size) ||
       row_pitch < texture_box.width * 4 || readback_size > UINT32_MAX)
      goto out;

   buffer_template.width0 = (uint32_t)readback_size;
   readback = screen->resource_create(screen, &buffer_template);
   if (!readback)
      goto out;

   context->clear_render_target(context, surface, &clear_color, 0, 0,
                                texture_template.width0,
                                texture_template.height0, false);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX))
      goto out;
   screen->fence_reference(screen, &fence, NULL);

   context->resource_copy_region(context, readback, 0, 0, 0, 0, texture, 0,
                                 &texture_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX))
      goto out;
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)readback_size;
   const unsigned char *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer)
      goto out;

   verified = true;
   for (unsigned y = 0; y < texture_box.height && verified; ++y) {
      for (unsigned x = 0; x < texture_box.width; ++x) {
         const unsigned char *pixel = pixels + (size_t)y * row_pitch + x * 4;

         for (unsigned component = 0; component < 4; ++component) {
            if (pixel[component] != expected[component]) {
               verified = false;
               break;
            }
         }
      }
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   pipe_resource_reference(&readback, NULL);
   if (surface)
      AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&texture, NULL);
   return verified;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   int failed = 0;
   const unsigned char rgba_red[4] = {0xff, 0x00, 0x00, 0xff};
   const unsigned char bgra_red[4] = {0x00, 0x00, 0xff, 0xff};

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Metal texture smoke could not create adapter\n", stderr);
      return 1;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY)
                    : NULL;
   if (!screen || !context || !context->clear_render_target ||
       !screen->is_format_supported(screen, PIPE_FORMAT_R8G8B8A8_UNORM,
                                    PIPE_TEXTURE_2D, 1, 1,
                                    PIPE_BIND_RENDER_TARGET) ||
       !screen->is_format_supported(screen, PIPE_FORMAT_B8G8R8A8_UNORM,
                                    PIPE_TEXTURE_2D, 1, 1,
                                    PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW) ||
       !ao46_verify_clear(screen, context, PIPE_FORMAT_R8G8B8A8_UNORM,
                          rgba_red) ||
       !ao46_verify_clear(screen, context, PIPE_FORMAT_B8G8R8A8_UNORM,
                          bgra_red)) {
      fputs("AO46 Metal texture clear/readback contract was unexpected\n", stderr);
      failed = 1;
   }

   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
