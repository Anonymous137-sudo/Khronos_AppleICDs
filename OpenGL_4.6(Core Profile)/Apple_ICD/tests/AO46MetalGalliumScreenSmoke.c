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
#include <string.h>

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen;
   struct pipe_context *context = NULL;
   struct pipe_context *graphics_context = NULL;
   struct pipe_resource *buffer = NULL;
   struct pipe_resource *copy = NULL;
   struct pipe_stream_output_target *stream_output = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_resource buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 4096,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER | PIPE_BIND_STREAM_OUTPUT,
   };
   const struct pipe_box copy_box = {
      .x = 64,
      .width = 256,
      .height = 1,
      .depth = 1,
   };
   const struct pipe_box readback_box = {
      .x = 128,
      .width = 256,
      .height = 1,
      .depth = 1,
   };
   unsigned char upload[256];
   unsigned stream_output_offset = 384;
   const unsigned invalid_stream_output_offset = 641;
   const unsigned stream_output_append = (unsigned)-1;
   void *mapping = NULL;
   size_t length = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Metal Gallium screen smoke could not create adapter\n", stderr);
      return 1;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   graphics_context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   if (!screen || !screen->get_name || !screen->get_vendor ||
       !screen->get_device_vendor || strcmp(screen->get_vendor(screen),
                                             "Khronos_AppleICDs") != 0 ||
       screen->get_screen_fd(screen) != -1 ||
       !graphics_context || !graphics_context->draw_vbo ||
       !graphics_context->set_framebuffer_state ||
       !graphics_context->set_vertex_buffers ||
       !graphics_context->set_constant_buffer ||
       !graphics_context->create_stream_output_target ||
       !graphics_context->stream_output_target_destroy ||
       !graphics_context->set_stream_output_targets ||
       !graphics_context->stream_output_target_offset) {
      fputs("AO46 Metal Gallium screen contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   context = screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY);
   if (!context || !context->destroy || !context->resource_copy_region ||
       !context->buffer_map || !context->buffer_unmap ||
       !context->buffer_subdata || !context->flush) {
      fputs("AO46 Metal Gallium compute context contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   buffer = screen->resource_create(screen, &buffer_template);
   if (!buffer || !AO46MetalGalliumResourceGetCPUMapping(buffer, &mapping,
                                                         &length) ||
       !mapping || length != 4096 ||
       screen->is_format_supported(screen, PIPE_FORMAT_R8_UNORM,
                                   PIPE_TEXTURE_2D, 1, 1,
                                   PIPE_BIND_RENDER_TARGET)) {
      fputs("AO46 Metal Gallium buffer resource contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   copy = screen->resource_create(screen, &buffer_template);
   if (!copy) {
      fputs("AO46 Metal Gallium copy destination did not allocate\n", stderr);
      failed = 1;
      goto out;
   }

   stream_output = graphics_context->create_stream_output_target(
      graphics_context, buffer, 128, 512);
   if (!stream_output) {
      fputs("AO46 Metal Gallium stream-output target did not allocate\n", stderr);
      failed = 1;
      goto out;
   }

   graphics_context->set_stream_output_targets(
      graphics_context, 1, &stream_output, &stream_output_offset, MESA_PRIM_POINTS);
   if (graphics_context->stream_output_target_offset(stream_output) !=
       stream_output_offset) {
      fputs("AO46 Metal Gallium stream-output offset was not retained\n", stderr);
      failed = 1;
      goto out;
   }

   graphics_context->set_stream_output_targets(
      graphics_context, 1, &stream_output, &stream_output_append, MESA_PRIM_POINTS);
   if (graphics_context->stream_output_target_offset(stream_output) !=
       stream_output_offset) {
      fputs("AO46 Metal Gallium stream-output append offset was not preserved\n", stderr);
      failed = 1;
      goto out;
   }

   graphics_context->set_stream_output_targets(
      graphics_context, 1, &stream_output, &invalid_stream_output_offset,
      MESA_PRIM_POINTS);
   if (graphics_context->stream_output_target_offset(stream_output) !=
       stream_output_offset) {
      fputs("AO46 Metal Gallium stream-output range validation failed\n", stderr);
      failed = 1;
      goto out;
   }
   graphics_context->set_stream_output_targets(graphics_context, 0, NULL, NULL,
                                                MESA_PRIM_POINTS);

   memset(mapping, 0x46, length);
   if (((const unsigned char *)mapping)[0] != 0x46 ||
       ((const unsigned char *)mapping)[length - 1] != 0x46) {
      fputs("AO46 Metal Gallium buffer mapping was not writable\n", stderr);
      failed = 1;
      goto out;
   }

   for (unsigned i = 0; i < sizeof(upload); ++i)
      upload[i] = (unsigned char)(i ^ 0xa5u);

   context->buffer_subdata(context, buffer, 0, copy_box.x, sizeof(upload), upload);
   context->resource_copy_region(context, copy, 0, readback_box.x, 0, 0,
                                 buffer, 0, &copy_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX) ||
       !screen->fence_finish(screen, context, fence, 0)) {
      fputs("AO46 Metal Gallium buffer copy did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   mapping = context->buffer_map(context, copy, 0, PIPE_MAP_READ, &readback_box,
                                 &transfer);
   if (!mapping || !transfer || memcmp(mapping, upload, sizeof(upload)) != 0) {
      fputs("AO46 Metal Gallium copied buffer readback mismatched\n", stderr);
      failed = 1;
      goto out;
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (context)
      context->destroy(context);
   pipe_so_target_reference(&stream_output, NULL);
   if (graphics_context)
      graphics_context->destroy(graphics_context);
   pipe_resource_reference(&copy, NULL);
   pipe_resource_reference(&buffer, NULL);
   if (screen)
      screen->destroy(screen);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
