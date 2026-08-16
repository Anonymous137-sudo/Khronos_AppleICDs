/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyTessellation.h"
#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MetalAdapter.h"
#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir_builder.h"
#include "nir_intrinsics.h"
#include "pipe/p_context.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "poly/tessellator.h"
#include "util/u_inlines.h"
#include "util/ralloc.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static struct nir_shader *
ao46_build_tcs(enum tess_primitive_mode domain)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_CTRL, &kk_nir_options, "ao46_poly_tcs_smoke");

   builder.shader->info.tess._primitive_mode = domain;
   builder.shader->info.tess.tcs_vertices_out = 1;
   return builder.shader;
}

static struct nir_shader *
ao46_build_tes(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_EVAL, &kk_nir_options, "ao46_poly_tes_smoke");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   nir_def *coord;
   nir_def *x;
   nir_def *y;
   nir_def *position_value;

   builder.shader->info.tess._primitive_mode = TESS_PRIMITIVE_TRIANGLES;
   coord = nir_load_tess_coord_xy(&builder);
   x = nir_fsub(&builder,
                nir_fmul(&builder, nir_channel(&builder, coord, 0),
                         nir_imm_float(&builder, 4.0f)),
                nir_imm_float(&builder, 1.0f));
   y = nir_fsub(&builder,
                nir_fmul(&builder, nir_channel(&builder, coord, 1),
                         nir_imm_float(&builder, 4.0f)),
                nir_imm_float(&builder, 1.0f));
   position_value = nir_vec4(&builder, x, y,
                             nir_imm_float(&builder, 0.0f),
                             nir_imm_float(&builder, 1.0f));
   nir_store_output(&builder, position_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return builder.shader;
}

/* Render one Mesa poly TES-generated triangle using its direct parameter slot. */
static bool
ao46_mesa_poly_tes_render_smoke(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MesaRenderPipeline *pipeline)
{
   const uint32_t indices[] = {0, 1, 2};
   const uint32_t coordinate_allocations[] = {0};
   const struct poly_tess_point points[] = {
      {.u = 0, .v = 0},
      {.u = UINT32_C(0x00010000), .v = 0},
      {.u = 0, .v = UINT32_C(0x00010000)},
   };
   struct AO46MetalTexture color = {0};
   struct AO46MetalBuffer params = {0};
   struct AO46MetalBuffer coordinates = {0};
   struct AO46MetalBuffer coordinate_allocs = {0};
   struct AO46MetalBuffer index_buffer = {0};
   struct AO46MetalBuffer readback = {0};
   struct AO46MetalSubmission render_submission = {0};
   struct AO46MetalSubmission readback_submission = {0};
   size_t bytes_per_row = 0;
   size_t readback_size = 0;
   uint64_t coordinate_address = 0;
   uint64_t coordinate_allocations_address = 0;
   bool submitted = false;
   bool render_completed = false;
   bool readback_submitted = false;
   bool readback_completed = false;
   bool rendered = false;

   if (!adapter || !pipeline || !pipeline->metal_pipeline.native_pipeline)
      return false;

   if (!AO46MetalAdapterSupportsGPUAddress(adapter)) {
      fputs("Mesa poly TES render smoke skipped: public MTLBuffer GPU addresses unavailable\n",
            stdout);
      return true;
   }

   if (!AO46MetalTextureCreate(adapter, 8, 8,
                               AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, &color) ||
       !AO46MetalTextureTransferLayout(&color, color.width, color.height,
                                       &bytes_per_row, &readback_size) ||
       !AO46MetalBufferCreate(adapter, sizeof(struct poly_tess_params), &params) ||
       !AO46MetalBufferCreate(adapter, sizeof(points), &coordinates) ||
       !AO46MetalBufferCreate(adapter, sizeof(coordinate_allocations),
                              &coordinate_allocs) ||
       !AO46MetalBufferCreate(adapter, sizeof(indices), &index_buffer) ||
       !AO46MetalBufferCreate(adapter, readback_size, &readback) ||
       !AO46MetalBufferGetGPUAddress(&coordinates, &coordinate_address) ||
       !AO46MetalBufferGetGPUAddress(&coordinate_allocs,
                                     &coordinate_allocations_address))
      goto out;

   memset(params.cpu_mapping, 0, params.length);
   memcpy(coordinates.cpu_mapping, points, sizeof(points));
   memcpy(coordinate_allocs.cpu_mapping, coordinate_allocations,
          sizeof(coordinate_allocations));
   memcpy(index_buffer.cpu_mapping, indices, sizeof(indices));
   *(struct poly_tess_params *)params.cpu_mapping = (struct poly_tess_params){
      .patch_coord_buffer = coordinate_address,
      .coord_allocs = coordinate_allocations_address,
   };

   const struct AO46MetalBufferBinding parameter_binding = {
      .buffer = &params,
      .size = params.length,
      .index = 3,
   };
   const struct AO46MetalIndexBufferBinding index_binding = {
      .buffer = &index_buffer,
      .size = sizeof(indices),
      .count = sizeof(indices) / sizeof(indices[0]),
      .format = AO46_METAL_INDEX_FORMAT_UINT32,
   };

   submitted = AO46MetalRenderSubmitWithStaticVertexBuffers(
      adapter, &pipeline->metal_pipeline, &color, NULL, 0, &index_binding,
      NULL, NULL, 0, NULL, 0, NULL, 0, &parameter_binding, 1, NULL, 0, 0, 0,
      AO46_METAL_PRIMITIVE_TRIANGLES, 1, 0, &render_submission);
   if (submitted && AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       !render_submission.uses_mtl4) {
      fprintf(stderr, "Mesa poly TES draw bypassed the KK MTL4 render path\n");
      goto out;
   }
   render_completed = submitted && AO46MetalSubmissionWait(&render_submission);
   readback_submitted = render_completed && AO46MetalTextureReadbackSubmit(
      adapter, &color, 0, 0, color.width, color.height, &readback, 0,
      bytes_per_row, &readback_submission);
   readback_completed = readback_submitted &&
                        AO46MetalSubmissionWait(&readback_submission);
   if (!readback_completed) {
      fprintf(stderr,
              "Mesa poly TES draw lifecycle failed "
              "(submit=%d complete=%d readback=%d readback_complete=%d)\n",
              submitted, render_completed, readback_submitted, readback_completed);
      goto out;
   }

   const uint8_t *pixel = (const uint8_t *)readback.cpu_mapping +
                          4 * bytes_per_row + 4 * 4;
   rendered = pixel[0] == 0xff && pixel[1] == 0x00 && pixel[2] == 0x00 &&
              pixel[3] == 0xff;
   if (!rendered)
      fprintf(stderr, "Mesa poly TES draw pixel mismatched (%u,%u,%u,%u)\n",
              pixel[0], pixel[1], pixel[2], pixel[3]);

out:
   AO46MetalSubmissionDestroy(&readback_submission);
   AO46MetalSubmissionDestroy(&render_submission);
   AO46MetalBufferDestroy(&readback);
   AO46MetalBufferDestroy(&index_buffer);
   AO46MetalBufferDestroy(&coordinate_allocs);
   AO46MetalBufferDestroy(&coordinates);
   AO46MetalBufferDestroy(&params);
   AO46MetalTextureDestroy(&color);
   return rendered;
}

/* Keeps the full TES pointer graph inside retained Gallium resources. */
static bool
ao46_mesa_poly_tes_gallium_render_smoke(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MesaRenderPipeline *pipeline)
{
   enum {
      parameters_offset = 0,
      coordinates_offset = 256,
      coordinate_allocations_offset = 384,
      tessellation_data_bytes = 512,
   };
   const uint32_t indices[] = {0, 1, 2};
   const uint32_t coordinate_allocations[] = {0};
   const struct poly_tess_point points[] = {
      {.u = 0, .v = 0},
      {.u = UINT32_C(0x00010000), .v = 0},
      {.u = 0, .v = UINT32_C(0x00010000)},
   };
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *tessellation_data = NULL;
   struct pipe_resource *index_buffer = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_resource buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   struct pipe_resource color_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UNORM,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET,
   };
   struct pipe_resource readback_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   struct AO46MetalGalliumStaticBufferBinding parameter_binding = {
      .offset = parameters_offset,
      .size = sizeof(struct poly_tess_params),
      .index = 3,
   };
   struct AO46MetalGalliumIndexBufferBinding index_binding = {
      .size = sizeof(indices),
      .count = sizeof(indices) / sizeof(indices[0]),
      .format = AO46_METAL_INDEX_FORMAT_UINT32,
   };
   const struct AO46MetalBuffer *native_tessellation_data = NULL;
   void *data_mapping = NULL;
   void *readback_mapping = NULL;
   size_t data_length = 0;
   size_t readback_length = 0;
   size_t bytes_per_row = 0;
   size_t readback_size = 0;
   uint64_t base_address = 0;
   bool submitted = false;
   bool render_completed = false;
   bool readback_completed = false;
   bool rendered = false;

   if (!adapter || !pipeline || !pipeline->metal_pipeline.native_pipeline)
      return false;

   if (!AO46MetalAdapterSupportsGPUAddress(adapter)) {
      fputs("Mesa poly Gallium TES smoke skipped: public MTLBuffer GPU addresses unavailable\n",
            stdout);
      return true;
   }

   screen = AO46MetalGalliumScreenCreate(adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   buffer_template.width0 = tessellation_data_bytes;
   tessellation_data = screen ? screen->resource_create(screen, &buffer_template)
                              : NULL;
   buffer_template.width0 = sizeof(indices);
   index_buffer = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   if (!screen || !context || !tessellation_data || !index_buffer || !color ||
       !surface ||
       !AO46MetalGalliumResourceGetCPUMapping(tessellation_data, &data_mapping,
                                               &data_length) ||
       !AO46MetalGalliumResourceGetMetalBuffer(tessellation_data,
                                                &native_tessellation_data) ||
       !AO46MetalBufferGetGPUAddress(native_tessellation_data, &base_address) ||
       !AO46MetalGalliumTextureGetTransferLayout(
          color, color_template.width0, color_template.height0, &bytes_per_row,
          &readback_size) ||
       data_length != tessellation_data_bytes ||
       coordinates_offset > data_length - sizeof(points) ||
       coordinate_allocations_offset >
          data_length - sizeof(coordinate_allocations))
      goto out;

   readback_template.width0 = readback_size;
   readback = screen->resource_create(screen, &readback_template);
   if (!readback)
      goto out;

   memset(data_mapping, 0, data_length);
   memcpy((uint8_t *)data_mapping + coordinates_offset, points, sizeof(points));
   memcpy((uint8_t *)data_mapping + coordinate_allocations_offset,
          coordinate_allocations, sizeof(coordinate_allocations));
   *(struct poly_tess_params *)((uint8_t *)data_mapping + parameters_offset) =
      (struct poly_tess_params){
         .patch_coord_buffer = base_address + coordinates_offset,
         .coord_allocs = base_address + coordinate_allocations_offset,
      };

   context->buffer_subdata(context, index_buffer, 0, 0, sizeof(indices), indices);
   parameter_binding.resource = tessellation_data;
   index_binding.resource = index_buffer;
   submitted = AO46MetalGalliumRenderIndexedTrianglesWithStaticVertexBuffers(
      context, &pipeline->metal_pipeline, surface, &parameter_binding, 1,
      &index_binding, NULL, 0, &fence);
   if (!submitted) {
      fputs("Mesa poly Gallium TES submission was rejected\n", stderr);
      goto out;
   }

   /* The render fence owns its root and EBO resources, not this test. */
   pipe_resource_reference(&tessellation_data, NULL);
   pipe_resource_reference(&index_buffer, NULL);
   render_completed = screen->fence_finish(screen, context, fence, UINT64_MAX);
   if (!render_completed)
      goto out;
   screen->fence_reference(screen, &fence, NULL);

   struct pipe_box color_box = {
      .width = color_template.width0,
      .height = color_template.height0,
      .depth = 1,
   };
   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, 0);
   readback_completed = fence &&
                        screen->fence_finish(screen, context, fence, UINT64_MAX);
   if (!readback_completed ||
       !AO46MetalGalliumResourceGetCPUMapping(readback, &readback_mapping,
                                               &readback_length) ||
       readback_length < readback_size) {
      fprintf(stderr,
              "Mesa poly Gallium TES readback failed "
              "(submit=%d render_complete=%d readback_complete=%d)\n",
              submitted, render_completed, readback_completed);
      goto out;
   }

   const uint8_t *pixel = (const uint8_t *)readback_mapping +
                          4 * bytes_per_row + 4 * 4;
   rendered = pixel[0] == 0xff && pixel[1] == 0x00 && pixel[2] == 0x00 &&
              pixel[3] == 0xff;
   if (!rendered)
      fprintf(stderr, "Mesa poly Gallium TES pixel mismatched (%u,%u,%u,%u)\n",
              pixel[0], pixel[1], pixel[2], pixel[3]);

out:
   if (screen && fence)
      screen->fence_reference(screen, &fence, NULL);
   pipe_resource_reference(&readback, NULL);
   if (surface)
      AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&color, NULL);
   pipe_resource_reference(&index_buffer, NULL);
   pipe_resource_reference(&tessellation_data, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   return rendered;
}

static struct nir_shader *
ao46_build_flat_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_poly_fragment_smoke");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *red = nir_vec4(&builder, nir_imm_float(&builder, 1.0f),
                            nir_imm_float(&builder, 0.0f),
                            nir_imm_float(&builder, 0.0f),
                            nir_imm_float(&builder, 1.0f));

   nir_store_output(&builder, red, nir_imm_int(&builder, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return builder.shader;
}

static bool
ao46_shader_has_expected_parameter_binding(struct nir_shader *nir,
                                           unsigned binding)
{
   bool has_direct_pointer = false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            if (instr->type != nir_instr_type_intrinsic)
               continue;

            nir_intrinsic_instr *intrinsic = nir_instr_as_intrinsic(instr);
            if (intrinsic->intrinsic == nir_intrinsic_load_tess_param_buffer_poly)
               return false;
            if (intrinsic->intrinsic == nir_intrinsic_load_buffer_ptr_kk &&
                nir_intrinsic_binding(intrinsic) == binding)
               has_direct_pointer = true;
         }
      }
   }

   return has_direct_pointer;
}

int
main(void)
{
   struct nir_shader *tcs = ao46_build_tcs(TESS_PRIMITIVE_TRIANGLES);
   struct nir_shader *quad_tcs = ao46_build_tcs(TESS_PRIMITIVE_QUADS);
   struct nir_shader *isoline_tcs = ao46_build_tcs(TESS_PRIMITIVE_ISOLINES);
   struct nir_shader *tes = ao46_build_tes();
   struct nir_shader *tes_graphics = ao46_build_tes();
   struct nir_shader *quad_tes = ao46_build_tes();
   struct nir_shader *isoline_tes = ao46_build_tes();
   struct nir_shader *fragment = ao46_build_flat_fragment_shader();
   struct AO46MesaPolyTessellationPlan plan = {0};
   struct AO46MesaPolyTessellationPlan quad_plan = {0};
   struct AO46MesaPolyTessellationPlan isoline_plan = {0};
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   const struct AO46MesaStaticBufferRequirement parameter_requirement = {
      .binding = 3,
      .minimum_size = sizeof(struct poly_tess_params),
   };
   bool graphics_lowered = false;
   bool adapter_created = false;
   bool graphics_pipeline_created = false;
   struct nir_to_msl_options options = {0};
   void *context = ralloc_context(NULL);
   char *msl = NULL;
   int failed = 0;

   if (quad_tes)
      quad_tes->info.tess._primitive_mode = TESS_PRIMITIVE_QUADS;
   if (isoline_tes)
      isoline_tes->info.tess._primitive_mode = TESS_PRIMITIVE_ISOLINES;

   const bool plan_created = tcs && tes &&
      AO46MesaPolyTessellationPlanCreate(tcs, 1, 6, 2, 3, &plan) &&
      AO46MesaPolyTessellationPlanFinalize(&plan, tes);
   const bool domain_plans_created =
      quad_tcs && quad_tes && isoline_tcs && isoline_tes &&
      AO46MesaPolyTessellationPlanCreate(quad_tcs, 4, 8, 1, 3, &quad_plan) &&
      AO46MesaPolyTessellationPlanFinalize(&quad_plan, quad_tes) &&
      AO46MesaPolyTessellationPlanCreate(isoline_tcs, 2, 4, 1, 3,
                                         &isoline_plan) &&
      AO46MesaPolyTessellationPlanFinalize(&isoline_plan, isoline_tes);
   if (!tcs || !quad_tcs || !isoline_tcs || !tes || !tes_graphics || !quad_tes ||
       !isoline_tes || !fragment ||
       !context || !plan_created || !domain_plans_created ||
       plan.parameter_buffer_binding != 3 || plan.parameter_bytes != 136 ||
       plan.input_patch_size != 1 || plan.output_patch_size != 1 ||
       plan.domain != AO46_MESA_POLY_TESSELLATION_TRIANGLES ||
       quad_plan.domain != AO46_MESA_POLY_TESSELLATION_QUADS ||
       isoline_plan.domain != AO46_MESA_POLY_TESSELLATION_ISOLINES ||
       plan.output_primitive != AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES ||
       quad_plan.output_primitive != AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES ||
       isoline_plan.output_primitive != AO46_MESA_POLY_TESSELLATION_OUTPUT_LINES ||
       plan.patches_per_instance != 6 || plan.nr_patches != 12 ||
       plan.vertex_grid_width != 6 || plan.vertex_grid_height != 2 ||
       plan.tcs_grid_width != 6 || plan.tess_grid_width != 12 ||
       plan.tcs_buffer_bytes != (size_t)plan.nr_patches * plan.tcs_stride_bytes ||
       plan.coord_allocs_offset != plan.tcs_buffer_bytes ||
       plan.counts_offset != plan.coord_allocs_offset +
                                (size_t)plan.nr_patches * sizeof(uint32_t) ||
       plan.out_draw_offset != plan.counts_offset +
                              (size_t)plan.nr_patches * sizeof(uint32_t) ||
       plan.transient_bytes != plan.out_draw_offset + 5 * sizeof(uint32_t) ||
       !plan.requires_prefix_sum || !plan.requires_dynamic_index_heap ||
       AO46MesaPolyTessellationPlanCreate(tcs, 2, 5, 1, 3, &plan) ||
       !AO46MesaPolyTessellationLower(tcs, tes, 3) ||
       tcs->info.stage != MESA_SHADER_COMPUTE ||
       tcs->info.workgroup_size[0] != 1 ||
       tes->info.stage != MESA_SHADER_VERTEX || !tes->info.vs.tes_poly ||
       !ao46_shader_has_expected_parameter_binding(tes, 3)) {
      fprintf(stderr,
              "Mesa poly tessellation lowering contract was unexpected "
              "(plan=%d stride=%u tcs=%zu coord=%zu count=%zu draw=%zu total=%zu)\n",
              plan_created, plan.tcs_stride_bytes, plan.tcs_buffer_bytes,
              plan.coord_allocs_offset, plan.counts_offset, plan.out_draw_offset,
              plan.transient_bytes);
      failed = 1;
      goto out;
   }

   msl_preprocess_nir(tes);
   (void)msl_optimize_nir(tes);
   nir_shader_gather_info(tes, nir_shader_get_entrypoint(tes));
   options.mem_ctx = context;
   options.static_buffer_mask = UINT16_C(1) << 3;
   msl = nir_to_msl(tes, &options);
   if (!msl || !strstr(msl, "vertex VertexOut") ||
       !strstr(msl, "constant Buffer &buf3 [[buffer(3)]]")) {
      fputs("Mesa poly tessellation MSL contract was unexpected\n", stderr);
      failed = 1;
   }

   if (!failed) {
      graphics_lowered = AO46MesaPolyTessellationLower(NULL, tes_graphics, 3);
      adapter_created = graphics_lowered && AO46MetalAdapterCreate(&adapter);
      graphics_pipeline_created = adapter_created &&
         AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
            &adapter, tes_graphics, fragment,
            AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, NULL, 0,
            UINT16_C(1) << parameter_requirement.binding,
            &parameter_requirement, 1, 0, NULL, 0, &pipeline);
   }

   if (!failed &&
       (!graphics_pipeline_created ||
        pipeline.vertex_reflection.static_buffer_mask !=
           (UINT16_C(1) << parameter_requirement.binding) ||
        pipeline.vertex_reflection.static_buffer_bytes[
           parameter_requirement.binding] != parameter_requirement.minimum_size ||
        pipeline.metal_pipeline.static_vertex_buffer_mask !=
           (UINT16_C(1) << parameter_requirement.binding) ||
        pipeline.metal_pipeline.static_vertex_buffer_bytes[
           parameter_requirement.binding] != parameter_requirement.minimum_size ||
        !ao46_mesa_poly_tes_render_smoke(&adapter, &pipeline) ||
        !ao46_mesa_poly_tes_gallium_render_smoke(&adapter, &pipeline))) {
      fprintf(stderr,
              "Mesa poly TES static-vertex-buffer pipeline contract was unexpected "
              "(lowered=%d adapter=%d pipeline=%d reflected=%#x metal=%#x)\n",
              graphics_lowered, adapter_created, graphics_pipeline_created,
              pipeline.vertex_reflection.static_buffer_mask,
              pipeline.metal_pipeline.static_vertex_buffer_mask);
      failed = 1;
   }

out:
   AO46MesaRenderPipelineDestroy(&pipeline);
   AO46MetalAdapterDestroy(&adapter);
   ralloc_free(context);
   ralloc_free(fragment);
   ralloc_free(isoline_tes);
   ralloc_free(quad_tes);
   ralloc_free(tes_graphics);
   ralloc_free(tes);
   ralloc_free(isoline_tcs);
   ralloc_free(quad_tcs);
   ralloc_free(tcs);
   return failed;
}
