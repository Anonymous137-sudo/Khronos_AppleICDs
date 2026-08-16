/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MetalAdapter.h"
#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir_builder.h"
#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/ralloc.h"
#include "util/u_inlines.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static struct nir_shader *
ao46_build_mesa_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_mesa_texture_vertex_smoke");
   struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics attribute = {
      .location = VERT_ATTRIB_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics uv_attribute = {
      .location = VERT_ATTRIB_GENERIC1,
      .num_slots = 1,
   };
   struct nir_io_semantics uv_varying = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *position_value = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 0, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = attribute);
   nir_def *uv_value = nir_load_input(
      &builder, 2, 32, nir_imm_int(&builder, 0), .base = 1, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = uv_attribute);

   nir_store_output(&builder, position_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   nir_store_output(&builder, uv_value, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0x3,
                    .src_type = nir_type_float32, .io_semantics = uv_varying);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VERT_ATTRIB_POS);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VERT_ATTRIB_GENERIC1);
   builder.shader->info.outputs_written |=
      BITFIELD64_BIT(VARYING_SLOT_POS) | BITFIELD64_BIT(VARYING_SLOT_VAR0);
   return builder.shader;
}

static struct nir_shader *
ao46_build_mesa_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_mesa_texture_fragment_smoke");
   struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   struct nir_io_semantics uv_varying = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *barycentric = nir_load_barycentric_pixel(
      &builder, 32, .interp_mode = INTERP_MODE_SMOOTH);
   nir_def *coordinate = nir_load_interpolated_input(
      &builder, 2, 32, barycentric, nir_imm_int(&builder, 0), .base = 0,
      .dest_type = nir_type_float32, .io_semantics = uv_varying);
   nir_def *sampled_color_one = nir_tex(
      &builder, coordinate, .texture_index = 1, .sampler_index = 1,
      .dim = GLSL_SAMPLER_DIM_2D, .dest_type = nir_type_float32);
   nir_def *sampled_color_three = nir_tex(
      &builder, coordinate, .texture_index = 3, .sampler_index = 3,
      .dim = GLSL_SAMPLER_DIM_2D, .dest_type = nir_type_float32);
   nir_def *sampled_color = nir_fadd(&builder, sampled_color_one,
                                     sampled_color_three);

   nir_store_output(&builder, sampled_color, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VARYING_SLOT_VAR0);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

struct AO46TextureVertex {
   float position[4];
   float uv[2];
};

static const uint8_t ao46_texture_slot_one_quadrants[][4] = {
   {0x40, 0x00, 0x00, 0xff},
   {0x00, 0x40, 0x00, 0xff},
   {0x00, 0x00, 0x40, 0xff},
   {0x40, 0x40, 0x00, 0xff},
};

static const uint8_t ao46_texture_slot_three_quadrants[][4] = {
   {0x00, 0x80, 0x00, 0xff},
   {0x00, 0x00, 0x80, 0xff},
   {0x80, 0x00, 0x00, 0xff},
   {0x00, 0x00, 0x80, 0xff},
};

static const uint8_t ao46_texture_combined_quadrants[][4] = {
   {0x40, 0x80, 0x00, 0xff},
   {0x00, 0x40, 0x80, 0xff},
   {0x80, 0x00, 0x40, 0xff},
   {0x40, 0x40, 0x80, 0xff},
};

static void
ao46_fill_texture_quadrants(uint8_t *pixels, size_t row_pitch, uint32_t width,
                            uint32_t height,
                            const uint8_t quadrants[][4])
{
   for (uint32_t y = 0; y < height; ++y) {
      for (uint32_t x = 0; x < width; ++x) {
         uint32_t quadrant = (y >= height / 2 ? 2 : 0) +
                             (x >= width / 2 ? 1 : 0);

         memcpy(pixels + (size_t)y * row_pitch + x * 4, quadrants[quadrant], 4);
      }
   }
}

static bool
ao46_texture_output_matches(const uint8_t *pixels, size_t row_pitch,
                            uint32_t width, uint32_t height, bool flip_y)
{
   for (uint32_t y = 0; y < height; ++y) {
      uint32_t source_y = flip_y ? height - 1 - y : y;

      for (uint32_t x = 0; x < width; ++x) {
         uint32_t quadrant = (source_y >= height / 2 ? 2 : 0) +
                             (x >= width / 2 ? 1 : 0);
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;

         if (memcmp(pixel, ao46_texture_combined_quadrants[quadrant],
                    sizeof(ao46_texture_combined_quadrants[quadrant])) != 0)
            return false;
      }
   }

   return true;
}

int
main(void)
{
   static const struct AO46TextureVertex vertices[] = {
      {{-1.0f, -1.0f, 0.0f, 1.0f}, {0.0f, 0.0f}},
      {{3.0f, -1.0f, 0.0f, 1.0f}, {2.0f, 0.0f}},
      {{-1.0f, 3.0f, 0.0f, 1.0f}, {0.0f, 2.0f}},
   };
   const struct pipe_resource texture_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UNORM,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW,
   };
   const struct pipe_resource vertex_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(vertices),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   struct pipe_resource readback_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   const struct AO46MesaVertexAttribute vertex_attributes[] = {
      {
         .location = VERT_ATTRIB_POS,
         .buffer_index = 2,
         .offset = offsetof(struct AO46TextureVertex, position),
         .stride = sizeof(struct AO46TextureVertex),
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
      },
      {
         .location = VERT_ATTRIB_GENERIC1,
         .buffer_index = 2,
         .offset = offsetof(struct AO46TextureVertex, uv),
         .stride = sizeof(struct AO46TextureVertex),
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT2,
      },
   };
   const struct AO46MesaVertexBinding vertex_binding = {
      .index = 2,
   };
   const struct pipe_sampler_state sampler_template = {
      .wrap_s = PIPE_TEX_WRAP_CLAMP_TO_EDGE,
      .wrap_t = PIPE_TEX_WRAP_CLAMP_TO_EDGE,
      .wrap_r = PIPE_TEX_WRAP_CLAMP_TO_EDGE,
      .min_img_filter = PIPE_TEX_FILTER_NEAREST,
      .min_mip_filter = PIPE_TEX_MIPFILTER_NONE,
      .mag_img_filter = PIPE_TEX_FILTER_NEAREST,
      .compare_mode = PIPE_TEX_COMPARE_NONE,
      .max_anisotropy = 1,
   };
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *source_one = NULL;
   struct pipe_resource *source_three = NULL;
   struct pipe_resource *target = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *upload_buffer = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *target_surface = NULL;
   struct pipe_sampler_view *sampler_views[2] = {0};
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_box texture_box = {.width = 8, .height = 8, .depth = 1};
   struct pipe_box readback_box = {.height = 1, .depth = 1};
   void *samplers[2] = {0};
   void *no_sampler = NULL;
   uint8_t *upload = NULL;
   size_t row_pitch = 0;
   size_t transfer_size = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Mesa texture smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   vertex_nir = ao46_build_mesa_vertex_shader();
   fragment_nir = ao46_build_mesa_fragment_shader();
   if (!vertex_nir || !fragment_nir ||
       !AO46MesaRenderPipelineCreate(
          &adapter, vertex_nir, fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, vertex_attributes,
          ARRAY_SIZE(vertex_attributes),
          &pipeline)) {
      fputs("Mesa NIR texture pipeline could not be created\n", stderr);
      failed = 1;
      goto out;
   }
   if (AO46MetalAdapterSupportsMTL4Submission(&adapter) &&
       !pipeline.metal_pipeline.uses_mtl4_compiler) {
      fputs("Mesa textured pipeline did not use KK's MTL4 compiler\n", stderr);
      failed = 1;
      goto out;
   }

   if (!strstr(pipeline.fragment_msl_source,
               "texture2d<float> tex_1 [[texture(1)]]") ||
       !strstr(pipeline.fragment_msl_source,
               "texture2d<float> tex_3 [[texture(3)]]") ||
       !strstr(pipeline.fragment_msl_source, "sampler sampler_1 [[sampler(1)]]") ||
       !strstr(pipeline.fragment_msl_source, "sampler sampler_3 [[sampler(3)]]") ||
       !strstr(pipeline.fragment_msl_source, "tex_1.sample(sampler_1") ||
       !strstr(pipeline.fragment_msl_source, "tex_3.sample(sampler_3") ||
       !strstr(pipeline.vertex_msl_source, "attrib_01 [[attribute(1)]]") ||
       !strstr(pipeline.vertex_msl_source, "vary_00 [[user(vary_00)]]") ||
       !strstr(pipeline.fragment_msl_source, "vary_00 [[user(vary_00)]]") ||
       strstr(pipeline.fragment_msl_source, "sampler_table.handles") ||
       pipeline.fragment_reflection.static_texture_mask != UINT64_C(0xa) ||
       pipeline.fragment_reflection.static_sampler_mask != UINT64_C(0xa)) {
      fputs("Mesa static texture/sampler ABI was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY)
                    : NULL;
   source_one = screen ? screen->resource_create(screen, &texture_template) : NULL;
   source_three = screen ? screen->resource_create(screen, &texture_template) : NULL;
   target = screen ? screen->resource_create(screen, &texture_template) : NULL;
   vertex_buffer = screen ? screen->resource_create(screen, &vertex_template) : NULL;
   target_surface = AO46MetalGalliumSurfaceCreate(target);
   if (!screen || !context || !source_one || !source_three || !target ||
       !vertex_buffer ||
       !target_surface || !AO46MetalGalliumTextureGetTransferLayout(
          target, texture_box.width, texture_box.height, &row_pitch,
          &transfer_size) ||
       transfer_size > UINT32_MAX) {
      fputs("Mesa texture smoke could not create bounded render resources\n", stderr);
      failed = 1;
      goto out;
   }

   readback_template.width0 = (uint32_t)transfer_size;
   upload_buffer = screen->resource_create(screen, &readback_template);
   readback = screen->resource_create(screen, &readback_template);
   upload = calloc(1, transfer_size);
   if (!upload_buffer || !readback || !upload) {
      fputs("Mesa texture smoke could not create transfer resources\n", stderr);
      failed = 1;
      goto out;
   }

   ao46_fill_texture_quadrants(upload, row_pitch, texture_template.width0,
                               texture_template.height0,
                               ao46_texture_slot_one_quadrants);
   context->buffer_subdata(context, upload_buffer, 0, 0, transfer_size, upload);
   if (!AO46MetalGalliumTextureUpload(
          context, source_one, 0, 0, texture_template.width0,
          texture_template.height0,
          upload_buffer, 0, row_pitch, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa texture source upload did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   ao46_fill_texture_quadrants(upload, row_pitch, texture_template.width0,
                               texture_template.height0,
                               ao46_texture_slot_three_quadrants);
   context->buffer_subdata(context, upload_buffer, 0, 0, transfer_size, upload);
   if (!AO46MetalGalliumTextureUpload(
          context, source_three, 0, 0, texture_template.width0,
          texture_template.height0, upload_buffer, 0, row_pitch, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa texture slot-three upload did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   samplers[0] = context->create_sampler_state(context, &sampler_template);
   samplers[1] = context->create_sampler_state(context, &sampler_template);
   if (!samplers[0] || !samplers[1]) {
      fputs("Mesa texture smoke could not create nearest-clamp samplers\n", stderr);
      failed = 1;
      goto out;
   }
   context->bind_sampler_states(context, MESA_SHADER_FRAGMENT, 1, 1,
                                &samplers[0]);
   context->bind_sampler_states(context, MESA_SHADER_FRAGMENT, 3, 1,
                                &samplers[1]);

   struct pipe_sampler_view sampler_view_template = {
      .format = source_one->format,
      .target = PIPE_TEXTURE_2D,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_Y,
      .swizzle_b = PIPE_SWIZZLE_Z,
      .swizzle_a = PIPE_SWIZZLE_W,
      .texture = source_one,
      .u.tex = {
         .first_level = 0,
         .last_level = 0,
         .first_layer = 0,
         .last_layer = 0,
      },
   };
   sampler_views[0] = context->create_sampler_view(context, source_one,
                                                    &sampler_view_template);
   sampler_view_template.texture = source_three;
   sampler_views[1] = context->create_sampler_view(context, source_three,
                                                    &sampler_view_template);
   if (!sampler_views[0] || !sampler_views[1]) {
      fputs("Mesa texture smoke could not create sampler views\n", stderr);
      failed = 1;
      goto out;
   }
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 1, 1, 0,
                              &sampler_views[0]);
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 3, 1, 0,
                              &sampler_views[1]);

   context->buffer_subdata(context, vertex_buffer, 0, 0, sizeof(vertices),
                           vertices);
   struct AO46MesaVertexBinding bound_vertex = vertex_binding;
   bound_vertex.resource = vertex_buffer;
   if (!AO46MesaRenderPipelineDrawTriangle(
          &pipeline, context, target_surface, &bound_vertex, 1, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa multi-slot texture draw did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->resource_copy_region(context, readback, 0, 0, 0, 0, target, 0,
                                 &texture_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa texture output readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)transfer_size;
   const uint8_t *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("Mesa texture output could not map\n", stderr);
      failed = 1;
      goto out;
   }

   if (!ao46_texture_output_matches(pixels, row_pitch, texture_template.width0,
                                    texture_template.height0, false) &&
       !ao46_texture_output_matches(pixels, row_pitch, texture_template.width0,
                                    texture_template.height0, true)) {
      fputs("Mesa multi-slot UV texture output mismatched\n", stderr);
      failed = 1;
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   for (unsigned i = 0; i < ARRAY_SIZE(sampler_views); ++i) {
      if (sampler_views[i]) {
         const unsigned slot = i == 0 ? 1 : 3;

         context->set_sampler_views(context, MESA_SHADER_FRAGMENT, slot, 0, 1,
                                    NULL);
         pipe_sampler_view_reference(&sampler_views[i], NULL);
      }
   }
   for (unsigned i = 0; i < ARRAY_SIZE(samplers); ++i) {
      if (samplers[i]) {
         const unsigned slot = i == 0 ? 1 : 3;

         context->bind_sampler_states(context, MESA_SHADER_FRAGMENT, slot, 1,
                                      &no_sampler);
         context->delete_sampler_state(context, samplers[i]);
      }
   }
   AO46MetalGalliumSurfaceDestroy(target_surface);
   pipe_resource_reference(&readback, NULL);
   pipe_resource_reference(&upload_buffer, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   pipe_resource_reference(&target, NULL);
   pipe_resource_reference(&source_three, NULL);
   pipe_resource_reference(&source_one, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaRenderPipelineDestroy(&pipeline);
   ralloc_free(vertex_nir);
   ralloc_free(fragment_nir);
   free(upload);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
