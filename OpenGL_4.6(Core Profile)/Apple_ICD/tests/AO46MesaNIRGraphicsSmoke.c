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

static bool
ao46_check_builtin_io_abi(void)
{
   nir_builder vs = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_builtin_io_vs");
   nir_def *zero = nir_imm_int(&vs, 0);
   nir_store_output(&vs, nir_imm_ivec2(&vs, 0, 0x3f800000), zero,
                    .component = 1, .write_mask = 3,
                    .src_type = nir_type_uint32,
                    .io_semantics = {.location = VARYING_SLOT_POS, .num_slots = 1});
   nir_def *position = nir_load_output(
      &vs, 1, 32, zero, .component = 2, .dest_type = nir_type_uint32,
      .io_semantics = {.location = VARYING_SLOT_POS, .num_slots = 1});
   nir_store_output(&vs, position, zero, .write_mask = 1,
                    .src_type = nir_type_uint32,
                    .io_semantics = {.location = VARYING_SLOT_PSIZ, .num_slots = 1});
   const unsigned uint_slots[] = {
      VARYING_SLOT_LAYER, VARYING_SLOT_VIEWPORT, VARYING_SLOT_PRIMITIVE_ID,
   };
   for (unsigned i = 0; i < ARRAY_SIZE(uint_slots); ++i)
      nir_store_output(&vs, nir_imm_int(&vs, -1), zero, .write_mask = 1,
                       .src_type = nir_type_int32,
                       .io_semantics = {.location = uint_slots[i], .num_slots = 1});
   nir_shader_gather_info(vs.shader, nir_shader_get_entrypoint(vs.shader));
   struct nir_to_msl_options options = {.mem_ctx = vs.shader};
   char *source = nir_to_msl(vs.shader, &options);
   bool valid = source &&
      strstr(source, "float4 position [[position]]") &&
      strstr(source, "float point_size [[point_size]]") &&
      strstr(source, "uint render_target_array_index") &&
      strstr(source, "uint viewport_array_index") &&
      strstr(source, "uint primitive_id") &&
      strstr(source, "out.position.yz = as_type<float2>(") &&
      strstr(source, "as_type<uint>(out.position.z)") &&
      strstr(source, "out.point_size = as_type<float>(") &&
      strstr(source, "out.render_target_array_index = as_type<uint>(");
   if (!valid && source)
      fprintf(stderr, "Built-in vertex ABI mismatch:\n%s\n", source);
   ralloc_free(vs.shader);

   nir_builder fs = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_builtin_io_fs");
   zero = nir_imm_int(&fs, 0);
   nir_def *layer = nir_load_input(
      &fs, 1, 32, zero, .dest_type = nir_type_int32,
      .io_semantics = {.location = VARYING_SLOT_LAYER, .num_slots = 1});
   nir_store_output(&fs, layer, zero, .write_mask = 1,
                    .src_type = nir_type_int32,
                    .io_semantics = {.location = FRAG_RESULT_STENCIL, .num_slots = 1});
   nir_store_output(&fs, nir_imm_int(&fs, -1), zero, .write_mask = 1,
                    .src_type = nir_type_int32,
                    .io_semantics = {.location = FRAG_RESULT_SAMPLE_MASK, .num_slots = 1});
   nir_store_output(&fs, nir_imm_int(&fs, 0x3f800000), zero, .write_mask = 1,
                    .src_type = nir_type_uint32,
                    .io_semantics = {.location = FRAG_RESULT_DEPTH, .num_slots = 1});
   nir_shader_gather_info(fs.shader, nir_shader_get_entrypoint(fs.shader));
   options.mem_ctx = fs.shader;
   source = nir_to_msl(fs.shader, &options);
   bool fs_valid = source &&
      strstr(source, "float depth_out [[depth(any)]]") &&
      strstr(source, "uint stencil_out [[stencil]]") &&
      strstr(source, "uint sample_mask_out [[sample_mask]]") &&
      strstr(source, "as_type<int>(in.render_target_array_index)") &&
      strstr(source, "out.depth_out = as_type<float>(") &&
      strstr(source, "out.sample_mask_out = as_type<uint>(");
   if (!fs_valid && source)
      fprintf(stderr, "Built-in fragment ABI mismatch:\n%s\n", source);
   ralloc_free(fs.shader);
   return valid && fs_valid;
}

static bool
ao46_check_mediump_conversions(void)
{
   const nir_op ops[] = {nir_op_i2imp, nir_op_f2fmp, nir_op_f2imp,
                         nir_op_f2ump, nir_op_i2fmp, nir_op_u2fmp};
   const char *casts[] = {"short4(", "half4(", "short4(",
                          "ushort4(", "half4(", "half4("};
   bool valid = true;
   for (unsigned i = 0; i < ARRAY_SIZE(ops); ++i) {
      nir_builder b = nir_builder_init_simple_shader(
         MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_mediump_conversions");
      nir_def *input = nir_load_input(
         &b, 4, 32, nir_imm_int(&b, 0),
         .dest_type = nir_op_infos[ops[i]].input_types[0],
         .io_semantics = {.location = VARYING_SLOT_VAR0, .num_slots = 1});
      nir_def *value = nir_build_alu(&b, ops[i], input, NULL, NULL, NULL);
      nir_alu_type type = nir_alu_type_get_base_type(nir_op_infos[ops[i]].output_type);
      value = type == nir_type_float ? nir_f2f32(&b, value) :
              type == nir_type_uint ? nir_u2u32(&b, value) : nir_i2i32(&b, value);
      nir_store_output(&b, value, nir_imm_int(&b, 0), .write_mask = 0xf,
                       .src_type = type | 32,
                       .io_semantics = {.location = FRAG_RESULT_DATA0, .num_slots = 1});
      nir_shader_gather_info(b.shader, nir_shader_get_entrypoint(b.shader));
      struct nir_to_msl_options options = {.mem_ctx = b.shader};
      char *source = nir_to_msl(b.shader, &options);
      if (!source || strstr(source, "ALU ") || !strstr(source, casts[i])) {
         fprintf(stderr, "Mediump conversion %s failed:\n%s\n",
                 nir_op_infos[ops[i]].name, source ? source : "no source");
         valid = false;
      }
      ralloc_free(b.shader);
   }
   return valid;
}

static struct nir_shader *
ao46_build_mesa_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_mesa_vertex_smoke");
   struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics attribute = {
      .location = VERT_ATTRIB_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics color_attribute = {
      .location = VERT_ATTRIB_GENERIC1,
      .num_slots = 1,
   };
   struct nir_io_semantics varying = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *position_value = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 0, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = attribute);
   nir_def *color_value = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 1, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = color_attribute);

   /* NIR's bitwise storage must preserve float positions across split stores. */
   nir_store_output(&builder, nir_channels(&builder, position_value, 3),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 3, .src_type = nir_type_uint32,
                    .io_semantics = position);
   nir_store_output(&builder, nir_channels(&builder, position_value, 12),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .component = 2, .write_mask = 3,
                    .src_type = nir_type_uint32, .io_semantics = position);
   nir_store_output(&builder, color_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = varying);
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
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_mesa_fragment_smoke");
   struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   struct nir_io_semantics varying = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *barycentric = nir_load_barycentric_pixel(
      &builder, 32, .interp_mode = INTERP_MODE_SMOOTH);
   nir_def *vertex_color = nir_load_interpolated_input(
      &builder, 4, 32, barycentric, nir_imm_int(&builder, 0), .base = 0,
      .dest_type = nir_type_float32, .io_semantics = varying);

   nir_store_output(&builder, vertex_color, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   nir_store_output(&builder, nir_imm_int(&builder, -1),
                    nir_imm_int(&builder, 0), .write_mask = 1,
                    .src_type = nir_type_int32,
                    .io_semantics = {.location = FRAG_RESULT_SAMPLE_MASK, .num_slots = 1});
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VARYING_SLOT_VAR0);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_SAMPLE_MASK);
   return builder.shader;
}

struct AO46SmokePosition {
   float position[4];
};

struct AO46SmokeInstance {
   float color[4];
};

int
main(void)
{
   if (!ao46_check_builtin_io_abi() || !ao46_check_mediump_conversions()) {
      fputs("Mesa built-in I/O ABI regression failed\n", stderr);
      return 1;
   }
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *instance_buffer = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_fence_handle *previous_fence = NULL;
   void *vertex_elements = NULL;
   void *incompatible_vertex_elements = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_resource color_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UNORM,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource readback_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   struct pipe_resource vertex_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 3 * sizeof(struct AO46SmokePosition),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   struct pipe_resource instance_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 2 * sizeof(struct AO46SmokeInstance),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   const struct AO46SmokePosition vertices[3] = {
      {{-1.0f, -1.0f, 0.0f, 1.0f}},
      {{3.0f, -1.0f, 0.0f, 1.0f}},
      {{-1.0f, 3.0f, 0.0f, 1.0f}},
   };
   const struct AO46SmokeInstance instances[2] = {
      {{0.0f, 1.0f, 0.0f, 1.0f}},
      {{0.0f, 0.0f, 1.0f, 1.0f}},
   };
   const struct AO46MesaVertexAttribute vertex_attributes[] = {
      {
         .location = VERT_ATTRIB_POS,
         .buffer_index = 2,
         .offset = offsetof(struct AO46SmokePosition, position),
         .stride = sizeof(struct AO46SmokePosition),
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
      },
      {
         .location = VERT_ATTRIB_GENERIC1,
         .buffer_index = 3,
         .offset = offsetof(struct AO46SmokeInstance, color),
         .stride = sizeof(struct AO46SmokeInstance),
         .instance_divisor = 1,
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
      },
   };
   const struct pipe_vertex_element vertex_element_layout[] = {
      {
         .src_offset = offsetof(struct AO46SmokePosition, position),
         .vertex_buffer_index = 2,
         .src_format = PIPE_FORMAT_R32G32B32A32_FLOAT,
         .src_stride = sizeof(struct AO46SmokePosition),
      },
      {
         .src_offset = offsetof(struct AO46SmokeInstance, color),
         .vertex_buffer_index = 3,
         .src_format = PIPE_FORMAT_R32G32B32A32_FLOAT,
         .src_stride = sizeof(struct AO46SmokeInstance),
         .instance_divisor = 1,
      },
   };
   struct pipe_vertex_element incompatible_vertex_element_layout[
      ARRAY_SIZE(vertex_element_layout)];
   struct pipe_vertex_buffer vertex_buffers[4] = {0};
   struct pipe_framebuffer_state framebuffer = {0};
   struct pipe_draw_info draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .instance_count = 2,
   };
   struct pipe_draw_start_count_bias draw_range = {.count = 3};
   struct pipe_box color_box = {
      .width = 8,
      .height = 8,
      .depth = 1,
   };
   struct pipe_box readback_box = {
      .height = 1,
      .depth = 1,
   };
   size_t row_pitch = 0;
   size_t readback_size = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Mesa NIR graphics smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   vertex_nir = ao46_build_mesa_vertex_shader();
   fragment_nir = ao46_build_mesa_fragment_shader();
   if (!vertex_nir || !fragment_nir ||
       !AO46MesaRenderPipelineCreate(
          &adapter, vertex_nir, fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, vertex_attributes,
          ARRAY_SIZE(vertex_attributes), &pipeline)) {
      fputs("Mesa NIR graphics pipeline could not be created\n", stderr);
      failed = 1;
      goto out;
   }
   if (AO46MetalAdapterSupportsMTL4Submission(&adapter) &&
       !pipeline.metal_pipeline.uses_mtl4_compiler) {
      fputs("Mesa graphics pipeline did not use KK's MTL4 compiler\n", stderr);
      failed = 1;
      goto out;
   }

   if (!pipeline.vertex_msl_source || !pipeline.fragment_msl_source ||
       !pipeline.vertex_entrypoint || !pipeline.fragment_entrypoint ||
       !strstr(pipeline.vertex_msl_source, "vertex VertexOut") ||
       !strstr(pipeline.vertex_msl_source, "float4 position [[position]]") ||
       !strstr(pipeline.fragment_msl_source, "uint sample_mask_out [[sample_mask]]") ||
       !strstr(pipeline.vertex_msl_source, "position_in [[attribute(0)]]") ||
       !strstr(pipeline.vertex_msl_source, "attrib_01 [[attribute(1)]]") ||
       strstr(pipeline.vertex_msl_source, "gl_VertexID") ||
       !strstr(pipeline.fragment_msl_source, "fragment FragmentOut") ||
       !strstr(pipeline.vertex_msl_source, "vary_00 [[user(vary_00)]]") ||
       !strstr(pipeline.fragment_msl_source, "vary_00 [[user(vary_00)]]") ||
       strstr(pipeline.fragment_msl_source, "(null)") ||
       !strstr(pipeline.fragment_msl_source, "color(0)") ||
       pipeline.vertex_reflection.inputs_read == 0 ||
       pipeline.vertex_reflection.outputs_written == 0 ||
       pipeline.fragment_reflection.inputs_read == 0 ||
       pipeline.fragment_reflection.outputs_written == 0) {
      fputs("Mesa NIR graphics pipeline reflection contract was unexpected\n",
            stderr);
      failed = 1;
      goto out;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   vertex_buffer = screen ? screen->resource_create(screen, &vertex_template) : NULL;
   instance_buffer =
      screen ? screen->resource_create(screen, &instance_template) : NULL;
   if (!screen || !context || !color || !surface ||
       !vertex_buffer || !instance_buffer ||
       !AO46MetalGalliumTextureGetTransferLayout(
          color, color_box.width, color_box.height, &row_pitch, &readback_size) ||
       readback_size > UINT32_MAX) {
      fputs("Mesa NIR graphics smoke could not create bounded render resources\n",
            stderr);
      failed = 1;
      goto out;
   }

   readback_template.width0 = (uint32_t)readback_size;
   readback = screen->resource_create(screen, &readback_template);
   context->buffer_subdata(context, vertex_buffer, 0, 0, sizeof(vertices),
                           vertices);
   context->buffer_subdata(context, instance_buffer, 0, 0, sizeof(instances),
                           instances);
   if (!readback ||
       !AO46MetalGalliumContextBindRenderPipeline(context,
                                                    &pipeline.metal_pipeline)) {
      fputs("Mesa instanced graphics pipeline bind failed\n", stderr);
      failed = 1;
      goto out;
   }
   vertex_buffers[2].buffer.resource = vertex_buffer;
   vertex_buffers[3].buffer.resource = instance_buffer;
   vertex_elements = context->create_vertex_elements_state(
      context, ARRAY_SIZE(vertex_element_layout), vertex_element_layout);
   memcpy(incompatible_vertex_element_layout, vertex_element_layout,
          sizeof(vertex_element_layout));
   incompatible_vertex_element_layout[1].instance_divisor = 0;
   incompatible_vertex_elements = context->create_vertex_elements_state(
      context, ARRAY_SIZE(incompatible_vertex_element_layout),
      incompatible_vertex_element_layout);
   if (!vertex_elements || !incompatible_vertex_elements) {
      fputs("Mesa vertex-element state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   context->set_framebuffer_state(context, &framebuffer);
   context->bind_vertex_elements_state(context, incompatible_vertex_elements);
   context->set_vertex_buffers(context, ARRAY_SIZE(vertex_buffers), vertex_buffers);
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (fence) {
      fputs("Incompatible Mesa vertex-element state submitted a draw\n", stderr);
      failed = 1;
      goto out;
   }
   context->bind_vertex_elements_state(context, vertex_elements);
   context->set_vertex_buffers(context, ARRAY_SIZE(vertex_buffers), vertex_buffers);
   context->draw_vbo(context, &draw, 0, NULL, &draw_range, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa instanced vertex-buffer draw did not complete\n", stderr);
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
      fputs("Mesa-generated graphics readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)readback_size;
   const uint8_t *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("Mesa-generated graphics output could not map\n", stderr);
      failed = 1;
      goto out;
   }

   for (unsigned y = 0; y < color_template.height0 && !failed; ++y) {
      for (unsigned x = 0; x < color_template.width0; ++x) {
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;
         if (pixel[0] != 0x00 || pixel[1] != 0x00 || pixel[2] != 0xff ||
             pixel[3] != 0xff) {
            fputs("Mesa-generated instanced fragment output mismatched\n", stderr);
            failed = 1;
            break;
         }
      }
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (context && incompatible_vertex_elements)
      context->delete_vertex_elements_state(context, incompatible_vertex_elements);
   if (context && vertex_elements)
      context->delete_vertex_elements_state(context, vertex_elements);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (previous_fence)
      screen->fence_reference(screen, &previous_fence, NULL);
   pipe_resource_reference(&readback, NULL);
   pipe_resource_reference(&instance_buffer, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   if (surface)
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
