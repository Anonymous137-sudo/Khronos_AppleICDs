/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MesaMSLComputePipeline.h"
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
ao46_build_mesa_indexed_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_mesa_indexed_vertex_smoke");
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
ao46_build_mesa_indexed_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options,
      "ao46_mesa_indexed_fragment_smoke");
   struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *constant_color = nir_imm_vec4(&builder, 0.25f, 0.5f, 0.75f, 1.0f);

   nir_store_output(&builder, constant_color, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

/* Mesa-generated work produces the indirect count without a CPU readback. */
static struct nir_shader *
ao46_build_indirect_count_compute_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_indirect_count_producer");
   nir_def *root;

   builder.shader->info.workgroup_size[0] = 1;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;
   root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 0);
   nir_store_global(&builder, nir_imm_int(&builder, 1), root,
                    .align_mul = sizeof(uint32_t),
                    .access = ACCESS_NON_READABLE);
   return builder.shader;
}

/* Mesa NIR writes two indexed-indirect records that the CPU never maps. */
static struct nir_shader *
ao46_build_gpu_indirect_compute_shader(void)
{
   static const uint32_t arguments[] = {3, 1, 0, 0, 0, 3, 1, 0, 3, 1};
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_gpu_indirect_producer");
   nir_def *root;

   builder.shader->info.workgroup_size[0] = 1;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;
   root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 0);
   for (uint32_t i = 0; i < ARRAY_SIZE(arguments); ++i) {
      nir_store_global(&builder, nir_imm_int(&builder, arguments[i]),
                       nir_iadd_imm(&builder, root, i * sizeof(uint32_t)),
                       .align_mul = sizeof(uint32_t),
                       .access = ACCESS_NON_READABLE);
   }
   return builder.shader;
}

static struct nir_shader *
ao46_build_mesa_procedural_vertex_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_gpu_indirect_vertex_smoke");
   struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   struct nir_io_semantics draw_color = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *vertex_id = nir_load_vertex_id(&builder);
   nir_def *base_instance = nir_load_base_instance(&builder);
   nir_def *first = nir_imm_vec4(&builder, -1.0f, -1.0f, 0.0f, 1.0f);
   nir_def *second = nir_imm_vec4(&builder, 1.0f, -1.0f, 0.0f, 1.0f);
   nir_def *third = nir_imm_vec4(&builder, -1.0f, 1.0f, 0.0f, 1.0f);
   nir_def *fourth = nir_imm_vec4(&builder, 1.0f, -1.0f, 0.0f, 1.0f);
   nir_def *fifth = nir_imm_vec4(&builder, 1.0f, 1.0f, 0.0f, 1.0f);
   nir_def *sixth = nir_imm_vec4(&builder, -1.0f, 1.0f, 0.0f, 1.0f);
   nir_def *position_value = nir_bcsel(
      &builder, nir_ieq_imm(&builder, vertex_id, 0), first,
      nir_bcsel(
         &builder, nir_ieq_imm(&builder, vertex_id, 1), second,
         nir_bcsel(
            &builder, nir_ieq_imm(&builder, vertex_id, 2), third,
            nir_bcsel(
               &builder, nir_ieq_imm(&builder, vertex_id, 3), fourth,
               nir_bcsel(&builder, nir_ieq_imm(&builder, vertex_id, 4), fifth,
                         sixth)))));
   nir_def *color_value = nir_bcsel(
      &builder, nir_ieq_imm(&builder, base_instance, 0),
      nir_imm_vec4(&builder, 0.0f, 0.5f, 0.0f, 1.0f),
      nir_imm_vec4(&builder, 0.0f, 0.0f, 0.5f, 1.0f));

   nir_store_output(&builder, position_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   nir_store_output(&builder, color_value, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = draw_color);
   builder.shader->info.outputs_written |=
      BITFIELD64_BIT(VARYING_SLOT_POS) | BITFIELD64_BIT(VARYING_SLOT_VAR0);
   return builder.shader;
}

/* Each GPU-authored indirect record supplies its own base-instance value. */
static struct nir_shader *
ao46_build_mesa_gpu_indirect_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_gpu_indirect_fragment_smoke");
   struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   struct nir_io_semantics draw_color = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   nir_def *barycentric = nir_load_barycentric_pixel(
      &builder, 32, .interp_mode = INTERP_MODE_SMOOTH);
   nir_def *color_value = nir_load_interpolated_input(
      &builder, 4, 32, barycentric, nir_imm_int(&builder, 0), .base = 0,
      .dest_type = nir_type_float32, .io_semantics = draw_color);

   nir_store_output(&builder, color_value, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.inputs_read |= BITFIELD64_BIT(VARYING_SLOT_VAR0);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

struct AO46IndexedSmokeVertex {
   float position[4];
};

struct AO46IndexedIndirectArguments {
   uint32_t index_count;
   uint32_t instance_count;
   uint32_t index_start;
   int32_t base_vertex;
   uint32_t base_instance;
};

int
main(void)
{
   static const struct AO46IndexedSmokeVertex vertices[] = {
      {{7.0f, 7.0f, 0.0f, 1.0f}},
      {{-1.0f, -1.0f, 0.0f, 1.0f}},
      {{3.0f, -1.0f, 0.0f, 1.0f}},
      {{-1.0f, 3.0f, 0.0f, 1.0f}},
      {{7.0f, 7.0f, 0.0f, 1.0f}},
   };
   static const uint16_t u16_indices[] = {0, 1, 2};
   static const uint16_t u16_restart_indices[] = {
      0, 1, 2, UINT16_MAX, 0, 1, 2,
   };
   static const uint32_t invalid_range_words[] = {99, 0, 1, 4, 0, 2, 3};
   static const uint32_t index_words[] = {99, 0, 1, 2, 0, 1, 2};
   static const uint32_t restart_index_words[] = {
      0, 1, 2, UINT32_MAX, 0, 1, 2,
   };
   static const uint32_t indirect_index_words[] = {0, 1, 2};
   static const uint32_t indirect_draw_count_zero = 0;
   static const uint32_t indirect_draw_count_overflow = UINT32_MAX;
   static const struct AO46IndexedIndirectArguments indirect_arguments[] = {
      {
         .index_count = ARRAY_SIZE(indirect_index_words),
         .instance_count = 2,
         .index_start = 0,
         .base_vertex = 1,
         .base_instance = 0,
      },
      {
         .index_count = ARRAY_SIZE(indirect_index_words),
         .instance_count = 1,
         .index_start = 0,
         .base_vertex = 1,
         .base_instance = 0,
      },
   };
   static const struct AO46IndexedIndirectArguments invalid_indirect_arguments[] = {
      {
         .index_count = ARRAY_SIZE(indirect_index_words),
         .instance_count = 1,
         .index_start = 0,
         .base_vertex = 1,
         .base_instance = 0,
      },
      {
         .index_count = 2,
         .instance_count = 1,
         .index_start = 0,
         .base_vertex = 1,
         .base_instance = 0,
      },
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
   const struct pipe_resource index_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(index_words),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_INDEX_BUFFER,
   };
   const struct pipe_resource indirect_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(indirect_arguments),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER,
   };
   const struct pipe_resource indirect_count_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      /* The Mesa pointer-root ABI is 64-bit although the count itself is u32. */
      .width0 = sizeof(uint64_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER,
   };
   const struct pipe_resource gpu_indirect_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 2 * 5 * sizeof(uint32_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER | PIPE_BIND_SHADER_BUFFER,
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
         .offset = offsetof(struct AO46IndexedSmokeVertex, position),
         .stride = sizeof(struct AO46IndexedSmokeVertex),
         .format = AO46_METAL_VERTEX_FORMAT_FLOAT4,
      },
   };
   const struct AO46MesaVertexBinding vertex_binding = {
      .index = 2,
   };
   const struct AO46MesaIndexBinding index_binding = {
      .offset = sizeof(uint32_t),
      .size = 6 * sizeof(uint32_t),
      .count = 6,
      .format = AO46_METAL_INDEX_FORMAT_UINT32,
      .base_vertex = 1,
   };
   const struct AO46MesaIndexBinding u16_index_binding = {
      .offset = 0,
      .size = sizeof(u16_indices),
      .count = ARRAY_SIZE(u16_indices),
      .format = AO46_METAL_INDEX_FORMAT_UINT16,
      .base_vertex = 1,
   };
   const struct AO46MesaIndexBinding restart_index_binding = {
      .offset = 0,
      .size = sizeof(restart_index_words),
      .count = ARRAY_SIZE(restart_index_words),
      .format = AO46_METAL_INDEX_FORMAT_UINT32,
      .base_vertex = 1,
      .primitive_restart = true,
      .restart_index = UINT32_MAX,
   };
   const struct AO46MesaIndexBinding u16_restart_index_binding = {
      .offset = 0,
      .size = sizeof(u16_restart_indices),
      .count = ARRAY_SIZE(u16_restart_indices),
      .format = AO46_METAL_INDEX_FORMAT_UINT16,
      .base_vertex = 1,
      .primitive_restart = true,
      .restart_index = UINT16_MAX,
   };
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   struct AO46MesaRenderPipeline gpu_indirect_pipeline = {0};
   struct AO46MesaComputePipeline count_pipeline = {0};
   struct AO46MesaComputePipeline gpu_indirect_compute_pipeline = {0};
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct nir_shader *count_nir = NULL;
   struct nir_shader *gpu_indirect_vertex_nir = NULL;
   struct nir_shader *gpu_indirect_fragment_nir = NULL;
   struct nir_shader *gpu_indirect_compute_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *index_buffer = NULL;
   struct pipe_resource *indirect_buffer = NULL;
   struct pipe_resource *indirect_count_buffer = NULL;
   struct pipe_resource *gpu_indirect_buffer = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_fence_handle *previous_fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_vertex_buffer vertex_buffers[3] = {0};
   struct pipe_framebuffer_state framebuffer = {0};
   struct pipe_draw_info indexed_draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .index_size = sizeof(uint32_t),
      .primitive_restart = true,
      .restart_index = UINT32_MAX,
      .instance_count = 1,
   };
   struct pipe_draw_info array_draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .instance_count = 1,
   };
   struct pipe_draw_info indirect_draw = {
      .mode = MESA_PRIM_TRIANGLES,
      .index_size = sizeof(uint32_t),
   };
   struct pipe_draw_indirect_info indirect_info = {
      .offset = 0,
      .stride = sizeof(indirect_arguments[0]),
      .draw_count = ARRAY_SIZE(indirect_arguments),
   };
   struct pipe_draw_start_count_bias indexed_range = {
      .count = ARRAY_SIZE(restart_index_words),
      .index_bias = 1,
   };
   struct pipe_draw_start_count_bias array_range = {
      .start = 1,
      .count = 3,
   };
   struct pipe_box color_box = {.width = 8, .height = 8, .depth = 1};
   struct pipe_box readback_box = {.height = 1, .depth = 1};
   union pipe_color_union gpu_indirect_clear = {
      .f = {0.0f, 0.0f, 0.0f, 1.0f},
   };
   size_t row_pitch = 0;
   size_t readback_size = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Mesa indexed smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   vertex_nir = ao46_build_mesa_indexed_vertex_shader();
   fragment_nir = ao46_build_mesa_indexed_fragment_shader();
   if (!vertex_nir || !fragment_nir ||
       !AO46MesaRenderPipelineCreate(
          &adapter, vertex_nir, fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, vertex_attributes,
          ARRAY_SIZE(vertex_attributes), &pipeline)) {
      fputs("Mesa NIR indexed pipeline could not be created\n", stderr);
      failed = 1;
      goto out;
   }

   count_nir = ao46_build_indirect_count_compute_shader();
   if (!count_nir ||
       !AO46MesaComputePipelineCreate(&adapter, count_nir, &count_pipeline)) {
      fputs("Mesa indirect-count producer could not be created\n", stderr);
      failed = 1;
      goto out;
   }

   if (!strstr(pipeline.vertex_msl_source, "position_in [[attribute(0)]]") ||
       !strstr(pipeline.fragment_msl_source, "color(0)")) {
      fputs("Mesa NIR indexed pipeline reflection contract was unexpected\n",
            stderr);
      failed = 1;
      goto out;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   vertex_buffer = screen ? screen->resource_create(screen, &vertex_template) : NULL;
   index_buffer = screen ? screen->resource_create(screen, &index_template) : NULL;
   indirect_buffer =
      screen ? screen->resource_create(screen, &indirect_template) : NULL;
   indirect_count_buffer =
      screen ? screen->resource_create(screen, &indirect_count_template) : NULL;
   gpu_indirect_buffer =
      screen ? screen->resource_create(screen, &gpu_indirect_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   if (!screen || !context || !color || !vertex_buffer || !index_buffer ||
       !indirect_buffer || !indirect_count_buffer || !gpu_indirect_buffer ||
       !surface || !AO46MetalGalliumTextureGetTransferLayout(
          color, color_box.width, color_box.height, &row_pitch, &readback_size) ||
       readback_size > UINT32_MAX) {
      fputs("Mesa NIR indexed smoke could not create bounded resources\n", stderr);
      failed = 1;
      goto out;
   }

   readback_template.width0 = (uint32_t)readback_size;
   readback = screen->resource_create(screen, &readback_template);
   context->buffer_subdata(context, vertex_buffer, 0, 0, sizeof(vertices),
                           vertices);
   context->buffer_subdata(context, index_buffer, 0, 0,
                           sizeof(invalid_range_words), invalid_range_words);
   struct AO46MesaVertexBinding bound_vertex = vertex_binding;
   struct AO46MesaIndexBinding bound_index = index_binding;
   struct AO46MesaIndexBinding bound_u16_index = u16_index_binding;
   struct AO46MesaIndexBinding bound_restart_index = restart_index_binding;
   struct AO46MesaIndexBinding bound_u16_restart_index = u16_restart_index_binding;
   struct AO46MesaIndexBinding invalid_count = index_binding;
   bound_vertex.resource = vertex_buffer;
   bound_index.resource = index_buffer;
   bound_u16_index.resource = index_buffer;
   bound_restart_index.resource = index_buffer;
   bound_u16_restart_index.resource = index_buffer;
   invalid_count.resource = index_buffer;
   invalid_count.count = 5;
   invalid_count.size = 5 * sizeof(uint32_t);
   if (!readback ||
       AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &bound_index, &bound_vertex, 1, &fence)) {
      fputs("Mesa indexed range validation did not reject an invalid index\n",
            stderr);
      failed = 1;
      goto out;
   }

   context->buffer_subdata(context, index_buffer, 0, 0, sizeof(u16_indices),
                           u16_indices);
   if (!AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &bound_u16_index, &bound_vertex, 1,
          &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa uint16 indexed triangle did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, index_buffer, 0, 0,
                           sizeof(u16_restart_indices), u16_restart_indices);
   if (!AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &bound_u16_restart_index, &bound_vertex, 1,
          &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa uint16 primitive-restart draw did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, index_buffer, 0, 0, sizeof(index_words),
                           index_words);
   if (AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &invalid_count, &bound_vertex, 1, &fence)) {
      fputs("Mesa indexed count validation did not reject a partial triangle\n",
            stderr);
      failed = 1;
      goto out;
   }

   if (!AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &bound_index, &bound_vertex, 1, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa-generated indexed triangle did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, index_buffer, 0, 0, sizeof(restart_index_words),
                           restart_index_words);
   if (!AO46MesaRenderPipelineDrawIndexedTriangles(
          &pipeline, context, surface, &bound_restart_index, &bound_vertex, 1,
          &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa base-vertex primitive-restart draw did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   if (!AO46MetalGalliumContextBindRenderPipeline(context,
                                                    &pipeline.metal_pipeline)) {
      fputs("Mesa draw_vbo pipeline bind failed\n", stderr);
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

   indexed_draw.index.resource = index_buffer;
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indexed_draw, 0, NULL, &indexed_range, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa indexed draw_vbo did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &array_draw, 0, NULL, &array_range, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa array draw_vbo did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, indirect_buffer, 0, 0,
                           sizeof(invalid_indirect_arguments),
                           &invalid_indirect_arguments);
   indirect_draw.index.resource = index_buffer;
   indirect_info.buffer = indirect_buffer;
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence != previous_fence) {
      fputs("Mesa malformed indirect record unexpectedly submitted\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, index_buffer, 0, 0,
                           sizeof(indirect_index_words), indirect_index_words);
   context->buffer_subdata(context, indirect_buffer, 0, 0,
                           sizeof(indirect_arguments), &indirect_arguments);
   indirect_draw.index.resource = index_buffer;
   indirect_info.buffer = indirect_buffer;
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa indexed indirect draw_vbo did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   /* Mesa compute writes this count; the adapter consumes it on the GPU via ICB. */
   {
      struct pipe_resource *count_resources[] = {indirect_count_buffer};
      const uint32_t count_offsets[] = {0};
      const uint32_t count_indices[] = {0};

      if (!AO46MesaComputePipelineDispatch(
             &count_pipeline, context, count_resources, count_offsets,
             count_indices, 1, 1, 1, 1, &fence) || !fence) {
         fputs("Mesa GPU indirect-count producer did not submit\n", stderr);
         failed = 1;
         goto out;
      }
      screen->fence_reference(screen, &fence, NULL);
   }
   indirect_info.indirect_draw_count = indirect_count_buffer;
   indirect_info.indirect_draw_count_offset = 0;
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa count-buffer indirect draw_vbo did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, indirect_count_buffer, 0, 0,
                           sizeof(indirect_draw_count_zero),
                           &indirect_draw_count_zero);
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa zero GPU count did not complete its empty ICB range\n",
            stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);

   context->buffer_subdata(context, indirect_count_buffer, 0, 0,
                           sizeof(indirect_draw_count_overflow),
                           &indirect_draw_count_overflow);
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa count-buffer limit clamp did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &previous_fence, NULL);
   screen->fence_reference(screen, &fence, NULL);
   indirect_info.indirect_draw_count = NULL;
   indirect_info.indirect_draw_count_offset = 0;

   gpu_indirect_vertex_nir = ao46_build_mesa_procedural_vertex_shader();
   gpu_indirect_fragment_nir = ao46_build_mesa_gpu_indirect_fragment_shader();
   gpu_indirect_compute_nir = ao46_build_gpu_indirect_compute_shader();
   if (!gpu_indirect_vertex_nir || !gpu_indirect_fragment_nir ||
       !gpu_indirect_compute_nir ||
       !AO46MesaRenderPipelineCreate(
          &adapter, gpu_indirect_vertex_nir, gpu_indirect_fragment_nir,
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, NULL, 0,
          &gpu_indirect_pipeline) ||
       !AO46MesaComputePipelineCreate(
          &adapter, gpu_indirect_compute_nir,
          &gpu_indirect_compute_pipeline)) {
      fputs("Mesa GPU indirect pipelines could not be created\n", stderr);
      failed = 1;
      goto out;
   }
   if (!strstr(gpu_indirect_pipeline.vertex_msl_source,
               "gl_BaseInstance [[base_instance]]") ||
       !strstr(gpu_indirect_pipeline.vertex_msl_source, "vary_00 [[user(vary_00)]]") ||
       !strstr(gpu_indirect_pipeline.fragment_msl_source,
               "vary_00 [[user(vary_00)]]")) {
      fputs("Mesa GPU indirect base-instance ABI was unexpected\n", stderr);
      failed = 1;
      goto out;
   }
   {
      struct pipe_resource *resources[] = {gpu_indirect_buffer};
      const uint32_t offsets[] = {0};
      const uint32_t indices[] = {0};

      if (!AO46MesaComputePipelineDispatch(
             &gpu_indirect_compute_pipeline, context, resources, offsets,
             indices, 1, 1, 1, 1, &fence) || !fence) {
         fputs("Mesa GPU indirect record producer did not submit\n", stderr);
         failed = 1;
         goto out;
      }
      screen->fence_reference(screen, &fence, NULL);
   }
   if (!AO46MetalGalliumContextBindRenderPipeline(
          context, &gpu_indirect_pipeline.metal_pipeline)) {
      fputs("Mesa GPU indirect render pipeline bind failed\n", stderr);
      failed = 1;
      goto out;
   }
   context->bind_vertex_elements_state(context, NULL);
   context->set_vertex_buffers(context, 0, NULL);
   indirect_info.buffer = gpu_indirect_buffer;
   indirect_info.draw_count = 2;
   indirect_info.stride = 5 * sizeof(uint32_t);
   /* Each record covers one half; both must execute to overwrite this clear. */
   context->clear_render_target(context, surface, &gpu_indirect_clear, 0, 0,
                                color_template.width0, color_template.height0,
                                false);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa GPU indirect clear did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);
   context->flush(context, &previous_fence, 0);
   context->draw_vbo(context, &indirect_draw, 0, &indirect_info, NULL, 1);
   context->flush(context, &fence, 0);
   if (!fence || fence == previous_fence ||
       !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa GPU-authored indirect record sequence did not complete\n", stderr);
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
      fputs("Mesa-generated indexed readback did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   readback_box.width = (int)readback_size;
   const uint8_t *pixels = context->buffer_map(
      context, readback, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!pixels || !transfer) {
      fputs("Mesa-generated indexed output could not map\n", stderr);
      failed = 1;
      goto out;
   }

   {
      uint32_t green_pixels = 0;
      uint32_t blue_pixels = 0;

      for (unsigned y = 0; y < color_template.height0 && !failed; ++y) {
      for (unsigned x = 0; x < color_template.width0; ++x) {
         const uint8_t *pixel = pixels + (size_t)y * row_pitch + x * 4;

         if (pixel[0] == 0x00 && pixel[1] == 0x80 && pixel[2] == 0x00 &&
             pixel[3] == 0xff) {
            ++green_pixels;
         } else if (pixel[0] == 0x00 && pixel[1] == 0x00 &&
                    pixel[2] == 0x80 && pixel[3] == 0xff) {
            ++blue_pixels;
         } else {
            fputs("Mesa GPU indirect base-instance output mismatched\n", stderr);
            failed = 1;
            break;
         }
      }
   }
      if (!failed && (green_pixels == 0 || blue_pixels == 0 ||
                      green_pixels + blue_pixels !=
                         color_template.width0 * color_template.height0)) {
         fputs("Mesa GPU indirect records did not preserve base instances\n",
               stderr);
         failed = 1;
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
   pipe_resource_reference(&indirect_buffer, NULL);
   pipe_resource_reference(&indirect_count_buffer, NULL);
   pipe_resource_reference(&gpu_indirect_buffer, NULL);
   pipe_resource_reference(&index_buffer, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&color, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaRenderPipelineDestroy(&pipeline);
   AO46MesaRenderPipelineDestroy(&gpu_indirect_pipeline);
   AO46MesaComputePipelineDestroy(&count_pipeline);
   AO46MesaComputePipelineDestroy(&gpu_indirect_compute_pipeline);
   ralloc_free(count_nir);
   ralloc_free(gpu_indirect_compute_nir);
   ralloc_free(gpu_indirect_fragment_nir);
   ralloc_free(gpu_indirect_vertex_nir);
   ralloc_free(fragment_nir);
   ralloc_free(vertex_nir);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
