/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MesaNIRBufferTexture.h"
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

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static struct nir_shader *
ao46_build_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_rgb32_graphics_vertex");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   const struct nir_io_semantics attribute = {
      .location = VERT_ATTRIB_POS,
      .num_slots = 1,
   };
   nir_def *input = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 0, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = attribute);
   nir_def *rgb32 = nir_txf(&builder, nir_imm_int(&builder, 0),
                             .dim = GLSL_SAMPLER_DIM_BUF, .texture_index = 3,
                             .dest_type = nir_type_uint32);
   nir_def *offset = nir_vec4(
      &builder, nir_u2f32(&builder, nir_channel(&builder, rgb32, 0)),
      nir_u2f32(&builder, nir_channel(&builder, rgb32, 1)),
      nir_u2f32(&builder, nir_channel(&builder, rgb32, 2)),
      nir_imm_float(&builder, 0.0f));
   nir_def *value = nir_fadd(&builder, input, offset);

   nir_store_output(&builder, value, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VERT_ATTRIB_POS);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return builder.shader;
}

static struct nir_shader *
ao46_build_rgb32_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_rgb32_graphics_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *first_texel = nir_txf(&builder, nir_imm_int(&builder, 0),
                                  .dim = GLSL_SAMPLER_DIM_BUF,
                                  .texture_index = 2,
                                  .dest_type = nir_type_uint32);
   nir_def *second_texel = nir_txf(&builder, nir_imm_int(&builder, 0),
                                   .dim = GLSL_SAMPLER_DIM_BUF,
                                   .texture_index = 4,
                                   .dest_type = nir_type_uint32);
   nir_def *normalized_first = nir_fmul_imm(
      &builder, nir_u2f32(&builder, first_texel), 1.0f / 255.0f);
   nir_def *normalized_second = nir_fmul_imm(
      &builder, nir_u2f32(&builder, second_texel), 1.0f / 255.0f);
   nir_def *normalized = nir_vec4(
      &builder, nir_channel(&builder, normalized_first, 0),
      nir_channel(&builder, normalized_second, 1),
      nir_channel(&builder, normalized_second, 2), nir_imm_float(&builder, 1.0f));

   nir_store_output(&builder, normalized, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

static struct nir_shader *
ao46_build_rgb32_variant_fragment_shader(
   enum AO46MesaRGB32BufferTextureKind kind)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_rgb32_variant_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_alu_type type = kind == AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT
                          ? nir_type_float32
                          : kind == AO46_MESA_RGB32_BUFFER_TEXTURE_UINT
                               ? nir_type_uint32
                               : nir_type_int32;
   nir_def *texel = nir_txf(&builder, nir_imm_int(&builder, 0),
                            .dim = GLSL_SAMPLER_DIM_BUF, .texture_index = 2,
                            .dest_type = type);
   nir_def *color_value = texel;

   if (kind == AO46_MESA_RGB32_BUFFER_TEXTURE_UINT)
      color_value = nir_fmul_imm(&builder, nir_u2f32(&builder, texel),
                                 1.0f / 255.0f);
   else if (kind == AO46_MESA_RGB32_BUFFER_TEXTURE_SINT)
      color_value = nir_fmul_imm(&builder, nir_i2f32(&builder, texel),
                                 1.0f / 255.0f);

   nir_store_output(&builder, color_value, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

int
main(void)
{
   static const float vertices[][4] = {
      {-1.0f, -1.0f, 0.0f, 1.0f},
      {3.0f, -1.0f, 0.0f, 1.0f},
      {-1.0f, 3.0f, 0.0f, 1.0f},
   };
   static const uint32_t rgb32_data[] = {
      0, 0, 0,
      255, 64, 32,
      0, 0, 0,
      16, 192, 48,
      0, 0, 0,
   };
   static const float rgb32_float_data[] = {0.25f, 0.5f, 0.75f};
   static const int32_t rgb32_sint_data[] = {64, 128, 192};
   const struct pipe_resource color_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UNORM,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET,
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
   struct pipe_resource rgb32_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(rgb32_data),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   const struct pipe_resource rgb32_float_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(rgb32_float_data),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   const struct pipe_resource rgb32_sint_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(rgb32_sint_data),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_sampler_view view_template = {
      .format = PIPE_FORMAT_R32G32B32_UINT,
      .target = PIPE_BUFFER,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_Y,
      .swizzle_b = PIPE_SWIZZLE_Z,
      .swizzle_a = PIPE_SWIZZLE_W,
      .texture = &rgb32_template,
      .u.buf = {
         .offset = 3 * sizeof(uint32_t),
         .size = 6 * sizeof(uint32_t),
      },
   };
   struct pipe_sampler_view vertex_view_template = {
      .format = PIPE_FORMAT_R32G32B32_UINT,
      .target = PIPE_BUFFER,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_Y,
      .swizzle_b = PIPE_SWIZZLE_Z,
      .swizzle_a = PIPE_SWIZZLE_W,
      .texture = &rgb32_template,
      .u.buf = {
         .offset = 0,
         .size = 3 * sizeof(uint32_t),
      },
   };
   struct pipe_sampler_view second_view_template = {
      .format = PIPE_FORMAT_R32G32B32_UINT,
      .target = PIPE_BUFFER,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_Y,
      .swizzle_b = PIPE_SWIZZLE_Z,
      .swizzle_a = PIPE_SWIZZLE_W,
      .texture = &rgb32_template,
      .u.buf = {
         .offset = 9 * sizeof(uint32_t),
         .size = 6 * sizeof(uint32_t),
      },
   };
   struct pipe_resource readback_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   const struct AO46MesaVertexAttribute attribute = {
      .location = VERT_ATTRIB_POS,
      .buffer_index = 2,
      .stride = sizeof(vertices[0]),
      .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
   };
   const struct pipe_vertex_element vertex_element = {
      .vertex_buffer_index = 2,
      .src_format = PIPE_FORMAT_R32G32B32A32_FLOAT,
      .src_stride = sizeof(vertices[0]),
   };
   struct pipe_vertex_buffer vertex_buffers[3] = {0};
   struct pipe_framebuffer_state framebuffer = {0};
   const struct pipe_draw_info draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .instance_count = 1,
   };
   const struct pipe_draw_start_count_bias draw_range = {.count = 3};
   struct pipe_sampler_view *rgb32_views[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS] = {
      [2] = &view_template,
      [4] = &second_view_template,
   };
   struct AO46MesaRGB32BufferTextureBinding rgb32_bindings[2] = {{0}};
   uint32_t rgb32_binding_count = 0;
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   struct AO46MesaRenderPipeline float_pipeline = {0};
   struct AO46MesaRenderPipeline sint_pipeline = {0};
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct nir_shader *float_vertex_nir = NULL;
   struct nir_shader *float_fragment_nir = NULL;
   struct nir_shader *sint_vertex_nir = NULL;
   struct nir_shader *sint_fragment_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *rgb32_buffer = NULL;
   struct pipe_resource *rgb32_float_buffer = NULL;
   struct pipe_resource *rgb32_sint_buffer = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *surface = NULL;
   void *vertex_elements = NULL;
   struct pipe_sampler_view *view = NULL;
   struct pipe_sampler_view *vertex_view = NULL;
   struct pipe_sampler_view *second_view = NULL;
   struct pipe_sampler_view *float_view = NULL;
   struct pipe_sampler_view *sint_view = NULL;
   struct pipe_sampler_view *undersized_view = NULL;
   struct pipe_sampler_view *rebound_view = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_box color_box = {.width = 8, .height = 8, .depth = 1};
   struct pipe_box readback_box = {.height = 1, .depth = 1};
   size_t row_pitch = 0;
   size_t readback_size = 0;
   uint16_t static_buffer_mask = 0;
   uint16_t vertex_static_buffer_mask = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("RGB32 graphics smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   vertex_nir = ao46_build_vertex_shader();
   fragment_nir = ao46_build_rgb32_fragment_shader();
   if (!vertex_nir || !fragment_nir) {
      fputs("RGB32 graphics shaders could not be created\n", stderr);
      failed = 1;
      goto out;
   }
   if (!AO46MesaNIRCollectRGB32BufferTextureSlots(vertex_nir,
                                                   &vertex_static_buffer_mask) ||
       vertex_static_buffer_mask != (UINT16_C(1) << 3) ||
       !AO46MesaNIRCollectRGB32BufferTextureSlots(fragment_nir,
                                                   &static_buffer_mask) ||
       static_buffer_mask != ((UINT16_C(1) << 2) | (UINT16_C(1) << 4))) {
      fputs("RGB32 graphics NIR slot discovery was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   {
      struct pipe_sampler_view out_of_range_view = view_template;

      out_of_range_view.u.buf.offset = rgb32_template.width0;
      out_of_range_view.u.buf.size = 0;
      rgb32_views[2] = &out_of_range_view;
      if (AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
             rgb32_views, (UINT16_C(1) << 2) | (UINT16_C(1) << 4),
             rgb32_bindings, ARRAY_SIZE(rgb32_bindings),
             &rgb32_binding_count)) {
         fputs("RGB32 graphics accepted an out-of-range implicit view\n", stderr);
         failed = 1;
         goto out;
      }
      rgb32_views[2] = &view_template;
   }
   if (!AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
          rgb32_views, (UINT16_C(1) << 2) | (UINT16_C(1) << 4),
          rgb32_bindings, ARRAY_SIZE(rgb32_bindings), &rgb32_binding_count) ||
       rgb32_binding_count != 2 ||
       !AO46MesaRGB32BufferTextureBindingsMask(rgb32_bindings,
                                                rgb32_binding_count,
                                                &static_buffer_mask) ||
       static_buffer_mask != ((UINT16_C(1) << 2) | (UINT16_C(1) << 4))) {
      fputs("RGB32 graphics binding mask was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   vertex_buffer = screen ? screen->resource_create(screen, &vertex_template) : NULL;
   rgb32_buffer = screen ? screen->resource_create(screen, &rgb32_template) : NULL;
   rgb32_float_buffer =
      screen ? screen->resource_create(screen, &rgb32_float_template) : NULL;
   rgb32_sint_buffer =
      screen ? screen->resource_create(screen, &rgb32_sint_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   if (!screen || !context || !color || !vertex_buffer || !rgb32_buffer ||
       !rgb32_float_buffer || !rgb32_sint_buffer || !surface ||
       !AO46MetalGalliumTextureGetTransferLayout(
          color, color_box.width, color_box.height, &row_pitch, &readback_size) ||
       readback_size > UINT32_MAX) {
      fputs("RGB32 graphics smoke could not create Gallium resources\n", stderr);
      failed = 1;
      goto out;
   }

   readback_template.width0 = (uint32_t)readback_size;
   readback = screen->resource_create(screen, &readback_template);
   if (!readback) {
      fputs("RGB32 graphics smoke could not create readback buffer\n", stderr);
      failed = 1;
      goto out;
   }

   context->buffer_subdata(context, vertex_buffer, 0, 0, sizeof(vertices), vertices);
   context->buffer_subdata(context, rgb32_buffer, 0, 0, sizeof(rgb32_data),
                           rgb32_data);
   context->buffer_subdata(context, rgb32_float_buffer, 0, 0,
                           sizeof(rgb32_float_data), rgb32_float_data);
   context->buffer_subdata(context, rgb32_sint_buffer, 0, 0,
                           sizeof(rgb32_sint_data), rgb32_sint_data);

   view_template.texture = rgb32_buffer;
   view_template.u.buf.size = 6 * sizeof(uint32_t);
   second_view_template.texture = rgb32_buffer;
   vertex_view_template.texture = rgb32_buffer;
   view = context->create_sampler_view(context, rgb32_buffer, &view_template);
   second_view = context->create_sampler_view(context, rgb32_buffer,
                                              &second_view_template);
   vertex_view = context->create_sampler_view(context, rgb32_buffer,
                                              &vertex_view_template);
   {
      struct pipe_sampler_view float_view_template = view_template;
      struct pipe_sampler_view sint_view_template = view_template;

      float_view_template.format = PIPE_FORMAT_R32G32B32_FLOAT;
      float_view_template.texture = rgb32_float_buffer;
      float_view_template.u.buf.offset = 0;
      float_view_template.u.buf.size = sizeof(rgb32_float_data);
      sint_view_template.format = PIPE_FORMAT_R32G32B32_SINT;
      sint_view_template.texture = rgb32_sint_buffer;
      sint_view_template.u.buf.offset = 0;
      sint_view_template.u.buf.size = sizeof(rgb32_sint_data);
      float_view = context->create_sampler_view(context, rgb32_float_buffer,
                                                &float_view_template);
      sint_view = context->create_sampler_view(context, rgb32_sint_buffer,
                                               &sint_view_template);
   }
   if (!view || !second_view || !vertex_view || !float_view || !sint_view) {
      fputs("RGB32 graphics smoke could not create stage sampler views\n",
            stderr);
      failed = 1;
      goto out;
   }
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0, &view);
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 4, 1, 0,
                              &second_view);
   context->set_sampler_views(context, MESA_SHADER_VERTEX, 3, 1, 0,
                              &vertex_view);

   /* All three packed RGB32 view types must reach the Mesa MSL compiler. */
   float_vertex_nir = ao46_build_vertex_shader();
   float_fragment_nir = ao46_build_rgb32_variant_fragment_shader(
      AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT);
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0,
                              &float_view);
   if (!float_vertex_nir || !float_fragment_nir ||
       !AO46MetalGalliumContextCreateRenderPipelineWithCurrentRGB32SamplerViews(
          context, float_vertex_nir, float_fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, &attribute, 1,
          &float_pipeline) ||
       float_pipeline.fragment_reflection.static_buffer_mask !=
          (UINT16_C(1) << 2) ||
       float_pipeline.fragment_reflection.static_buffer_bytes[2] !=
          sizeof(rgb32_float_data)) {
      fputs("RGB32 float buffer-view pipeline contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   sint_vertex_nir = ao46_build_vertex_shader();
   sint_fragment_nir = ao46_build_rgb32_variant_fragment_shader(
      AO46_MESA_RGB32_BUFFER_TEXTURE_SINT);
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0,
                              &sint_view);
   if (!sint_vertex_nir || !sint_fragment_nir ||
       !AO46MetalGalliumContextCreateRenderPipelineWithCurrentRGB32SamplerViews(
          context, sint_vertex_nir, sint_fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, &attribute, 1,
          &sint_pipeline) ||
       sint_pipeline.fragment_reflection.static_buffer_mask !=
          (UINT16_C(1) << 2) ||
       sint_pipeline.fragment_reflection.static_buffer_bytes[2] !=
          sizeof(rgb32_sint_data)) {
      fputs("RGB32 signed buffer-view pipeline contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0, &view);

   if (!AO46MetalGalliumContextCreateRenderPipelineWithCurrentRGB32SamplerViews(
          context, vertex_nir, fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, &attribute, 1, &pipeline) ||
       !strstr(pipeline.fragment_msl_source,
               "constant Buffer &buf2 [[buffer(2)]]") ||
       !strstr(pipeline.fragment_msl_source,
               "constant Buffer &buf4 [[buffer(4)]]") ||
       !strstr(pipeline.vertex_msl_source,
               "constant Buffer &buf3 [[buffer(3)]]") ||
       pipeline.vertex_reflection.static_buffer_mask !=
          vertex_static_buffer_mask ||
       pipeline.vertex_reflection.static_buffer_bytes[3] !=
          3 * sizeof(uint32_t) ||
       pipeline.fragment_reflection.static_buffer_mask != static_buffer_mask ||
       pipeline.fragment_reflection.static_buffer_bytes[2] != 6 * sizeof(uint32_t) ||
       pipeline.fragment_reflection.static_buffer_bytes[4] != 6 * sizeof(uint32_t) ||
       pipeline.metal_pipeline.static_vertex_buffer_mask !=
          vertex_static_buffer_mask ||
       pipeline.metal_pipeline.static_fragment_buffer_mask != static_buffer_mask) {
      fputs("RGB32 graphics context-bound pipeline ABI was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   if (!AO46MetalGalliumContextBindRenderPipeline(context,
                                                    &pipeline.metal_pipeline)) {
      fputs("RGB32 graphics state-tracker pipeline bind failed\n", stderr);
      failed = 1;
      goto out;
   }
   vertex_elements = context->create_vertex_elements_state(
      context, 1, &vertex_element);
   if (!vertex_elements) {
      fputs("RGB32 graphics could not create vertex-element state\n", stderr);
      failed = 1;
      goto out;
   }
   vertex_buffers[2].buffer.resource = vertex_buffer;
   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   context->set_framebuffer_state(context, &framebuffer);
   context->bind_vertex_elements_state(context, vertex_elements);
   context->set_vertex_buffers(context, ARRAY_SIZE(vertex_buffers), vertex_buffers);

   /* A pipeline may not fall back to an old RGB32 binding after an unbind. */
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 4, 0, 1, NULL);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (fence) {
      fputs("RGB32 graphics accepted a missing required buffer view\n", stderr);
      failed = 1;
      goto out;
   }
   {
      struct pipe_sampler_view *fragment_views[] = {view, NULL, second_view};

      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2,
                                 ARRAY_SIZE(fragment_views), 0, fragment_views);
   }
   {
      struct pipe_sampler_view short_template = view_template;

      short_template.u.buf.size = 3 * sizeof(uint32_t);
      undersized_view = context->create_sampler_view(context, rgb32_buffer,
                                                     &short_template);
      if (!undersized_view) {
         fputs("RGB32 graphics smoke could not create undersized sampler view\n",
               stderr);
         failed = 1;
         goto out;
      }
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0,
                                 &undersized_view);
      pipe_sampler_view_reference(&undersized_view, NULL);
   }
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (fence) {
      fputs("RGB32 graphics accepted an undersized buffer view\n", stderr);
      failed = 1;
      goto out;
   }
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0, &view);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("RGB32 graphics state-tracker draw did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("RGB32 graphics readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)readback_size;
   const uint8_t *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("RGB32 graphics output could not map\n", stderr);
      failed = 1;
      goto out;
   }
   for (unsigned y = 0; y < color_template.height0 && !failed; ++y) {
      for (unsigned x = 0; x < color_template.width0; ++x) {
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;

         if (pixel[0] != 255 || pixel[1] != 192 || pixel[2] != 48 ||
             pixel[3] != 255) {
            fprintf(stderr,
                    "RGB32 graphics output mismatched at %u,%u: %u,%u,%u,%u\n",
                    x, y, pixel[0], pixel[1], pixel[2], pixel[3]);
            failed = 1;
            break;
         }
      }
   }

   if (failed)
      goto out;
   context->buffer_unmap(context, transfer);
   transfer = NULL;

   /* Rebind a same-shaped live buffer view without recompiling the pipeline. */
   {
      struct pipe_sampler_view alternate_template = view_template;

      alternate_template.u.buf.offset = 9 * sizeof(uint32_t);
      alternate_template.u.buf.size = 6 * sizeof(uint32_t);
      rebound_view = context->create_sampler_view(context, rgb32_buffer,
                                                  &alternate_template);
      if (!rebound_view) {
         fputs("RGB32 graphics could not create a replacement sampler view\n",
               stderr);
         failed = 1;
         goto out;
      }
   }
   context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 1, 0,
                              &rebound_view);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("RGB32 graphics rebind draw did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("RGB32 graphics rebind readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   pixels = context->buffer_map(context, readback, 0, PIPE_MAP_READ,
                                &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("RGB32 graphics rebound output could not map\n", stderr);
      failed = 1;
      goto out;
   }
   for (unsigned y = 0; y < color_template.height0 && !failed; ++y) {
      for (unsigned x = 0; x < color_template.width0; ++x) {
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;

         if (pixel[0] != 16 || pixel[1] != 192 || pixel[2] != 48 ||
             pixel[3] != 255) {
            fprintf(stderr,
                    "RGB32 graphics rebound output mismatched at %u,%u: %u,%u,%u,%u\n",
                    x, y, pixel[0], pixel[1], pixel[2], pixel[3]);
            failed = 1;
            break;
         }
      }
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (view) {
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 2, 0, 1, NULL);
      pipe_sampler_view_reference(&view, NULL);
   }
   if (rebound_view)
      pipe_sampler_view_reference(&rebound_view, NULL);
   if (float_view)
      pipe_sampler_view_reference(&float_view, NULL);
   if (sint_view)
      pipe_sampler_view_reference(&sint_view, NULL);
   if (second_view) {
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 4, 0, 1, NULL);
      pipe_sampler_view_reference(&second_view, NULL);
   }
   if (vertex_view) {
      context->set_sampler_views(context, MESA_SHADER_VERTEX, 3, 0, 1, NULL);
      pipe_sampler_view_reference(&vertex_view, NULL);
   }
   if (context && vertex_elements) {
      context->bind_vertex_elements_state(context, NULL);
      context->delete_vertex_elements_state(context, vertex_elements);
   }
   AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&readback, NULL);
   pipe_resource_reference(&rgb32_sint_buffer, NULL);
   pipe_resource_reference(&rgb32_float_buffer, NULL);
   pipe_resource_reference(&rgb32_buffer, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   pipe_resource_reference(&color, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaRenderPipelineDestroy(&sint_pipeline);
   AO46MesaRenderPipelineDestroy(&float_pipeline);
   AO46MesaRenderPipelineDestroy(&pipeline);
   ralloc_free(sint_fragment_nir);
   ralloc_free(sint_vertex_nir);
   ralloc_free(float_fragment_nir);
   ralloc_free(float_vertex_nir);
   ralloc_free(fragment_nir);
   ralloc_free(vertex_nir);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
