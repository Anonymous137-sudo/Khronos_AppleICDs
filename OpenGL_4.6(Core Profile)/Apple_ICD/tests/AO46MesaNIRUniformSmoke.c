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
#include <stdio.h>
#include <string.h>

static struct nir_shader *
ao46_build_mesa_uniform_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_mesa_uniform_vertex_smoke");
   struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics attribute = {
      .location = VERT_ATTRIB_POS,
      .num_slots = 1,
   };
   nir_def *position_value = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 0, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = attribute);

   nir_store_output(&builder, position_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VERT_ATTRIB_POS);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return builder.shader;
}

static struct nir_shader *
ao46_build_mesa_uniform_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_mesa_uniform_fragment_smoke");
   struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *uniform_color_zero = nir_load_ubo(
      &builder, 4, 32, nir_imm_int(&builder, 0), nir_imm_int(&builder, 0),
      .align_mul = 16, .align_offset = 0, .range = 16);
   nir_def *uniform_color_one = nir_load_ubo(
      &builder, 4, 32, nir_imm_int(&builder, 1), nir_imm_int(&builder, 0),
      .align_mul = 16, .align_offset = 0, .range = 16);
   nir_def *uniform_color = nir_fadd(&builder, uniform_color_zero,
                                     uniform_color_one);

   nir_store_output(&builder, uniform_color, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

struct AO46UniformSmokeVertex {
   float position[4];
};

struct AO46UniformSmokeColor {
   float color[4];
};

int
main(void)
{
   static const struct AO46UniformSmokeVertex vertices[] = {
      {{-1.0f, -1.0f, 0.0f, 1.0f}},
      {{3.0f, -1.0f, 0.0f, 1.0f}},
      {{-1.0f, 3.0f, 0.0f, 1.0f}},
   };
   static const struct AO46UniformSmokeColor uniform_color_zero = {
      .color = {0.25f, 0.5f, 0.0f, 0.5f},
   };
   static const struct AO46UniformSmokeColor uniform_color_one = {
      .color = {0.0f, 0.0f, 0.75f, 0.5f},
   };
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
   const struct pipe_resource uniform_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(uniform_color_zero),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_CONSTANT_BUFFER,
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
         .offset = offsetof(struct AO46UniformSmokeVertex, position),
         .stride = sizeof(struct AO46UniformSmokeVertex),
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
      },
   };
   const struct AO46MesaVertexBinding vertex_binding = {
      .index = 2,
   };
   const struct AO46MesaUniformBinding uniform_bindings[] = {
      {
         .offset = 0,
         .size = sizeof(uniform_color_zero),
         .binding = 0,
      },
      {
         .offset = 0,
         .size = sizeof(uniform_color_one),
         .binding = 1,
      },
   };
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *uniform_zero_buffer = NULL;
   struct pipe_resource *uniform_one_buffer = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_fence_handle *previous_fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_vertex_buffer vertex_buffers[3] = {0};
   struct pipe_framebuffer_state framebuffer = {0};
   struct pipe_constant_buffer constant_buffers[2] = {0};
   struct pipe_draw_info draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .instance_count = 1,
   };
   const struct pipe_draw_start_count_bias draw_range = {
      .count = 3,
   };
   struct pipe_box color_box = {.width = 8, .height = 8, .depth = 1};
   struct pipe_box readback_box = {.height = 1, .depth = 1};
   size_t row_pitch = 0;
   size_t readback_size = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Mesa uniform smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   vertex_nir = ao46_build_mesa_uniform_vertex_shader();
   fragment_nir = ao46_build_mesa_uniform_fragment_shader();
   if (!vertex_nir || !fragment_nir ||
       !AO46MesaRenderPipelineCreate(
          &adapter, vertex_nir, fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, vertex_attributes,
          ARRAY_SIZE(vertex_attributes), &pipeline)) {
      fputs("Mesa NIR uniform pipeline could not be created\n", stderr);
      failed = 1;
      goto out;
   }

   if (!strstr(pipeline.fragment_msl_source,
               "constant Buffer &buf0 [[buffer(0)]]") ||
       !strstr(pipeline.fragment_msl_source, "&buf0.contents[0]") ||
       !strstr(pipeline.fragment_msl_source,
               "constant Buffer &buf1 [[buffer(16)]]") ||
       !strstr(pipeline.fragment_msl_source, "&buf1.contents[0]") ||
       pipeline.vertex_reflection.uniform_mask != 0 ||
       pipeline.fragment_reflection.uniform_mask != UINT16_C(0x3) ||
       pipeline.fragment_reflection.uniform_bytes[0] !=
          sizeof(uniform_color_zero) ||
       pipeline.fragment_reflection.uniform_bytes[1] !=
          sizeof(uniform_color_one) ||
       pipeline.metal_pipeline.uniform_mask != UINT16_C(0x3)) {
      fputs("Mesa NIR UBO reflection contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   vertex_buffer = screen ? screen->resource_create(screen, &vertex_template) : NULL;
   uniform_zero_buffer =
      screen ? screen->resource_create(screen, &uniform_template) : NULL;
   uniform_one_buffer =
      screen ? screen->resource_create(screen, &uniform_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   if (!screen || !context || !color || !vertex_buffer || !uniform_zero_buffer ||
       !uniform_one_buffer ||
       !surface || !AO46MetalGalliumTextureGetTransferLayout(
          color, color_box.width, color_box.height, &row_pitch, &readback_size) ||
       readback_size > UINT32_MAX) {
      fputs("Mesa NIR uniform smoke could not create bounded resources\n", stderr);
      failed = 1;
      goto out;
   }

   readback_template.width0 = (uint32_t)readback_size;
   readback = screen->resource_create(screen, &readback_template);
   context->buffer_subdata(context, vertex_buffer, 0, 0, sizeof(vertices),
                           vertices);
   context->buffer_subdata(context, uniform_zero_buffer, 0, 0,
                           sizeof(uniform_color_zero), &uniform_color_zero);
   context->buffer_subdata(context, uniform_one_buffer, 0, 0,
                           sizeof(uniform_color_one), &uniform_color_one);
   struct AO46MesaVertexBinding bound_vertex = vertex_binding;
   struct AO46MesaUniformBinding bound_uniforms[ARRAY_SIZE(uniform_bindings)] = {
      uniform_bindings[0], uniform_bindings[1],
   };
   struct AO46MesaUniformBinding short_uniforms[ARRAY_SIZE(uniform_bindings)] = {
      uniform_bindings[0], uniform_bindings[1],
   };
   bound_vertex.resource = vertex_buffer;
   bound_uniforms[0].resource = uniform_zero_buffer;
   bound_uniforms[1].resource = uniform_one_buffer;
   short_uniforms[0].resource = uniform_zero_buffer;
   short_uniforms[1].resource = uniform_one_buffer;
   short_uniforms[1].size -= sizeof(float);
   if (!readback ||
       AO46MesaRenderPipelineDrawTriangle(
          &pipeline, context, surface, &bound_vertex, 1, &fence) ||
       AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
          &pipeline, context, surface, bound_uniforms, 1, &bound_vertex, 1,
          &fence) ||
       AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
          &pipeline, context, surface, short_uniforms,
          ARRAY_SIZE(short_uniforms), &bound_vertex, 1, &fence) ||
       !AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
          &pipeline, context, surface, bound_uniforms,
          ARRAY_SIZE(bound_uniforms), &bound_vertex, 1, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa UBO render submission contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   if (!context->set_constant_buffer ||
       !AO46MetalGalliumContextBindRenderPipeline(context,
                                                    &pipeline.metal_pipeline)) {
      fputs("Mesa draw_vbo UBO pipeline bind failed\n", stderr);
      failed = 1;
      goto out;
   }
   vertex_buffers[2].buffer.resource = vertex_buffer;
   context->set_vertex_buffers(context, ARRAY_SIZE(vertex_buffers),
                               vertex_buffers);
   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   context->set_framebuffer_state(context, &framebuffer);

   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (!previous_fence || fence != previous_fence) {
      fputs("Mesa draw_vbo accepted a missing UBO binding\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);
   screen->fence_reference(screen, &previous_fence, NULL);

   constant_buffers[0] = (struct pipe_constant_buffer){
      .buffer = uniform_zero_buffer,
      .buffer_size = sizeof(uniform_color_zero),
   };
   constant_buffers[1] = (struct pipe_constant_buffer){
      .buffer = uniform_one_buffer,
      .buffer_size = sizeof(uniform_color_one),
   };
   context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 0,
                                &constant_buffers[0]);
   context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 1,
                                &constant_buffers[1]);

   context->set_constant_buffer(context, MESA_SHADER_VERTEX, 0,
                                &constant_buffers[1]);
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (!previous_fence || fence != previous_fence) {
      fputs("Mesa draw_vbo accepted mismatched stage UBO bindings\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);
   screen->fence_reference(screen, &previous_fence, NULL);
   context->set_constant_buffer(context, MESA_SHADER_VERTEX, 0, NULL);

   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 0, NULL);
   context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 1, NULL);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa draw_vbo UBO submission did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);
   (void)AO46MetalGalliumContextBindRenderPipeline(context, NULL);

   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa UBO output readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)readback_size;
   const uint8_t *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("Mesa UBO output could not map\n", stderr);
      failed = 1;
      goto out;
   }

   for (unsigned y = 0; y < color_template.height0 && !failed; ++y) {
      for (unsigned x = 0; x < color_template.width0; ++x) {
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;

         if (pixel[0] != 0x40 || pixel[1] != 0x80 || pixel[2] != 0xbf ||
             pixel[3] != 0xff) {
            fputs("Mesa UBO fragment output mismatched\n", stderr);
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
   if (previous_fence)
      screen->fence_reference(screen, &previous_fence, NULL);
   pipe_resource_reference(&readback, NULL);
   pipe_resource_reference(&uniform_one_buffer, NULL);
   pipe_resource_reference(&uniform_zero_buffer, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&color, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaRenderPipelineDestroy(&pipeline);
   ralloc_free(fragment_nir);
   ralloc_free(vertex_nir);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
