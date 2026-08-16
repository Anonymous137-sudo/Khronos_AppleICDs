/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MesaMSLComputePipeline.h"
#include "AO46MesaPolyKernelExecutor.h"
#include "AO46MesaPolyTessellation.h"
#include "AO46MetalAdapter.h"
#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "libkk_shaders.h"
#include "nir_builder.h"
#include "pipe/p_context.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "poly/geometry.h"
#include "poly/tessellator.h"
#include "util/ralloc.h"
#include "util/u_inlines.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static struct nir_shader *
ao46_build_tcs(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_CTRL, &kk_nir_options, "ao46_poly_gallium_chain_tcs");
   const struct nir_io_semantics outer = {
      .location = VARYING_SLOT_TESS_LEVEL_OUTER,
      .num_slots = 1,
   };
   const struct nir_io_semantics inner = {
      .location = VARYING_SLOT_TESS_LEVEL_INNER,
      .num_slots = 1,
   };

   builder.shader->info.tess._primitive_mode = TESS_PRIMITIVE_TRIANGLES;
   builder.shader->info.tess.tcs_vertices_out = 1;

   nir_store_output(
      &builder,
      nir_vec4(&builder, nir_imm_float(&builder, 1.0f),
               nir_imm_float(&builder, 1.0f), nir_imm_float(&builder, 1.0f),
               nir_imm_float(&builder, 0.0f)),
      nir_imm_int(&builder, 0), .base = 0, .range = 1, .write_mask = 0xf,
      .src_type = nir_type_float32, .io_semantics = outer);
   nir_store_output(&builder,
                    nir_vec2(&builder, nir_imm_float(&builder, 1.0f),
                             nir_imm_float(&builder, 0.0f)),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 0x3, .src_type = nir_type_float32,
                    .io_semantics = inner);
   nir_shader_gather_info(builder.shader, nir_shader_get_entrypoint(builder.shader));
   return builder.shader;
}

static struct nir_shader *
ao46_build_tes(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_EVAL, &kk_nir_options, "ao46_poly_gallium_chain_tes");
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
   position_value = nir_vec4(&builder, x, y, nir_imm_float(&builder, 0.0f),
                             nir_imm_float(&builder, 1.0f));
   nir_store_output(&builder, position_value, nir_imm_int(&builder, 0),
                    .base = 0, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   builder.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return builder.shader;
}

static struct nir_shader *
ao46_build_flat_fragment_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options,
      "ao46_poly_gallium_chain_fragment");
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

/*
 * The package contains every Mesa libkk pointer target. One PIPE_BUFFER root
 * lets the Gallium fences retain the complete generated-index/TES dependency
 * graph without introducing an AO46-specific shader ABI.
 */
static bool
ao46_mesa_poly_gallium_chain_smoke(
   const struct AO46MetalAdapter *adapter,
   struct nir_shader *tcs_state_nir, struct nir_shader *tes_state_nir,
   const struct AO46MesaComputePipeline *tcs_pipeline,
   const struct AO46MesaPolyTessellationPlan *plan,
   const struct AO46MesaRenderPipeline *pipeline)
{
   enum {
      root_offset = 0,
      count_root_offset = 128,
      sampler_table_offset = 256,
      parameters_offset = 512,
      heap_offset = 768,
      heap_data_offset = 1024,
      counts_offset = 1280,
      draws_offset = 1536,
      factors_offset = 1792,
      coord_allocs_offset = 2048,
      package_bytes = 2304,
      heap_data_bytes = 64,
   };
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *package = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_fence_handle *fence = NULL;
   void *tcs_state = NULL;
   void *tes_state = NULL;
   const float default_outer_level[] = {1.0f, 1.0f, 1.0f, 1.0f};
   const float default_inner_level[] = {1.0f, 1.0f};
   struct AO46MesaPolyKernelExecutor executor = {0};
   struct pipe_resource package_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER | PIPE_BIND_INDEX_BUFFER,
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
   struct AO46MetalGalliumPolyTessellationDraw poly_tess_draw = {
      .parameter_offset = parameters_offset,
      .parameter_size = sizeof(struct poly_tess_params),
      .index_offset = heap_data_offset,
      .index_size = heap_data_bytes,
      .indirect_offset = draws_offset,
      .indirect_size = 5 * sizeof(uint32_t),
      .maximum_index_count = heap_data_bytes / sizeof(uint32_t),
      .input_patch_size = 3,
      .input_vertex_count = 3,
   };
   struct AO46MetalGalliumPolyTessellationSequence poly_tess_sequence = {
      .tcs_pipeline = tcs_pipeline,
      .kernel_executor = &executor,
      .plan = plan,
      .count_root_offset = count_root_offset,
      .root_offset = root_offset,
      .root_size = sizeof(struct libkk_tess_tri_args),
      .sampler_table_offset = sampler_table_offset,
      .sampler_table_size = 16,
   };
   struct pipe_framebuffer_state framebuffer = {0};
   struct pipe_draw_info patch_info = {
      .mode = MESA_PRIM_PATCHES,
      .instance_count = 1,
   };
   const struct pipe_draw_start_count_bias patch_draw = {
      .count = 3,
   };
   const struct AO46MetalBuffer *native_package = NULL;
   struct libkk_tess_tri_args *root;
   struct libkk_tess_tri_args *count_root;
   struct poly_tess_params *parameters;
   struct poly_heap *heap;
   void *package_mapping = NULL;
   void *readback_mapping = NULL;
   size_t package_length = 0;
   size_t readback_length = 0;
   size_t bytes_per_row = 0;
   size_t readback_size = 0;
   uint64_t package_address = 0;
   bool completed = false;
   bool rendered = false;

   if (!adapter || !tcs_state_nir || !tes_state_nir || !tcs_pipeline ||
       !tcs_pipeline->metal_pipeline.native_pipeline ||
       !plan || !pipeline || !pipeline->metal_pipeline.native_pipeline ||
       plan->input_patch_size != 3 || plan->output_patch_size != 1 ||
       plan->patches_per_instance != 1 || plan->nr_patches != 1 ||
       plan->tcs_stride_bytes != 6 * sizeof(float) ||
       plan->tcs_buffer_bytes != 6 * sizeof(float) ||
       plan->tcs_grid_width != 1 || plan->parameter_buffer_binding != 3) {
      ralloc_free(tcs_state_nir);
      ralloc_free(tes_state_nir);
      return false;
   }

   if (!AO46MetalAdapterSupportsGPUAddress(adapter)) {
      fputs("Mesa poly Gallium chain smoke skipped: public MTLBuffer GPU addresses unavailable\n",
            stdout);
      return true;
   }

   screen = AO46MetalGalliumScreenCreate(adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   package_template.width0 = package_bytes;
   package = screen ? screen->resource_create(screen, &package_template) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   surface = AO46MetalGalliumSurfaceCreate(color);
   if (!screen || !context || !package || !color || !surface ||
       !AO46MesaPolyKernelExecutorCreate(adapter, &executor) ||
       !AO46MetalGalliumResourceGetCPUMapping(package, &package_mapping,
                                               &package_length) ||
       !AO46MetalGalliumResourceGetMetalBuffer(package, &native_package) ||
       !AO46MetalBufferGetGPUAddress(native_package, &package_address) ||
       !AO46MetalGalliumTextureGetTransferLayout(
          color, color_template.width0, color_template.height0, &bytes_per_row,
          &readback_size) ||
       package_length != package_bytes ||
       root_offset + sizeof(struct libkk_tess_tri_args) > sampler_table_offset ||
       count_root_offset + sizeof(struct libkk_tess_tri_args) > sampler_table_offset ||
       sampler_table_offset + 16 > parameters_offset ||
       parameters_offset + sizeof(struct poly_tess_params) > heap_offset ||
       heap_offset + sizeof(struct poly_heap) > heap_data_offset ||
       heap_data_offset + heap_data_bytes > counts_offset ||
       counts_offset + plan->nr_patches * sizeof(uint32_t) > draws_offset ||
       draws_offset + 5 * sizeof(uint32_t) > factors_offset ||
       factors_offset + plan->tcs_buffer_bytes > coord_allocs_offset ||
       coord_allocs_offset + sizeof(uint32_t) > package_bytes)
      goto out;

   readback_template.width0 = readback_size;
   readback = screen->resource_create(screen, &readback_template);
   if (!readback)
      goto out;

   memset(package_mapping, 0, package_length);
   root = (struct libkk_tess_tri_args *)((uint8_t *)package_mapping + root_offset);
   count_root = (struct libkk_tess_tri_args *)((uint8_t *)package_mapping +
                                                count_root_offset);
   parameters = (struct poly_tess_params *)((uint8_t *)package_mapping +
                                             parameters_offset);
   heap = (struct poly_heap *)((uint8_t *)package_mapping + heap_offset);
   *heap = (struct poly_heap){
      .base = package_address + heap_data_offset,
      .bottom = 0,
      .size = heap_data_bytes,
   };
   *parameters = (struct poly_tess_params){
      .heap = package_address + heap_offset,
      .patch_coord_buffer = package_address + heap_data_offset,
      .coord_allocs = package_address + coord_allocs_offset,
      .out_draws = package_address + draws_offset,
      .tcs_buffer = package_address + factors_offset,
      .counts = package_address + counts_offset,
      /* Mesa poly emits its generated uint32 indices into this heap range. */
      .index_buffer = package_address + heap_data_offset,
      .input_patch_size = plan->input_patch_size,
      .output_patch_size = plan->output_patch_size,
      .patches_per_instance = plan->patches_per_instance,
      .tcs_stride_el = plan->tcs_stride_bytes / sizeof(float),
      .nr_patches = plan->nr_patches,
      .partitioning = POLY_TESS_PARTITIONING_INTEGER,
   };
   if (!AO46MetalGalliumResourceWriteGPUAddressRoot(
          package, root_offset, package, parameters_offset))
      goto out;
   if (!AO46MetalGalliumResourceWriteGPUAddressRoot(
          package, count_root_offset, package, parameters_offset))
      goto out;

   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   if (!AO46MetalGalliumContextBindRenderPipeline(context,
                                                    &pipeline->metal_pipeline))
      goto out;
   context->set_framebuffer_state(context, &framebuffer);

   /* Patch draws stay fail-closed until both the range and patch state exist. */
   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if (fence)
      goto out;

   {
      struct pipe_shader_state tcs_template = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = tcs_state_nir,
      };
      struct pipe_shader_state tes_template = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = tes_state_nir,
      };

      tcs_state = context->create_tcs_state(context, &tcs_template);
      if (tcs_state)
         tcs_state_nir = NULL;
      tes_state = context->create_tes_state(context, &tes_template);
      if (tes_state)
         tes_state_nir = NULL;
      if (!tcs_state || !tes_state)
         goto out;
      context->bind_tcs_state(context, tcs_state);
      context->bind_tes_state(context, tes_state);
      context->set_tess_state(context, default_outer_level, default_inner_level);
   }

   poly_tess_draw.parameter_resource = package;
   poly_tess_draw.index_resource = package;
   poly_tess_draw.indirect_resource = package;
   if (!AO46MetalGalliumContextBindPolyTessellationDraw(context,
                                                         &poly_tess_draw))
      goto out;
   context->set_patch_vertices(context, poly_tess_draw.input_patch_size);

   root->tess_mode = POLY_TESS_MODE_WITH_COUNTS;
   count_root->tess_mode = POLY_TESS_MODE_COUNT;
   /* The pre-TES execution plan is required before patches can be admitted. */
   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if (fence)
      goto out;

   if (!AO46MetalGalliumContextBindPolyTessellationSequence(
          context, &poly_tess_sequence))
      goto out;

   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if (!fence)
      goto out;
   if (!AO46MetalGalliumContextBindPolyTessellationDraw(context, NULL) ||
       !AO46MetalGalliumContextBindRenderPipeline(context, NULL))
      goto out;

   /* The terminal render fence retains the complete generated package. */
   completed = screen->fence_finish(screen, context, fence, UINT64_MAX);
   screen->fence_reference(screen, &fence, NULL);
   if (!completed)
      goto out;

   const uint32_t *generated_draw =
      (const uint32_t *)((const uint8_t *)package_mapping + draws_offset);
   if (generated_draw[0] < 3 || generated_draw[0] % 3 != 0 ||
       generated_draw[1] != 1 ||
       generated_draw[2] > poly_tess_draw.maximum_index_count ||
       generated_draw[0] >
          poly_tess_draw.maximum_index_count - generated_draw[2] ||
       generated_draw[3] != 0 || generated_draw[4] != 0) {
      fprintf(stderr, "Mesa poly generated draw mismatched (%u,%u,%u,%u,%u)\n",
              generated_draw[0], generated_draw[1], generated_draw[2],
              generated_draw[3], generated_draw[4]);
      goto out;
   }

   const struct pipe_box color_box = {
      .width = color_template.width0,
      .height = color_template.height0,
      .depth = 1,
   };
   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX) ||
       !AO46MetalGalliumResourceGetCPUMapping(readback, &readback_mapping,
                                               &readback_length) ||
       readback_length < readback_size)
      goto out;
   screen->fence_reference(screen, &fence, NULL);

   const uint8_t *pixel = (const uint8_t *)readback_mapping +
                          4 * bytes_per_row + 4 * 4;
   rendered = pixel[0] == 0xff && pixel[1] == 0x00 && pixel[2] == 0x00 &&
              pixel[3] == 0xff;
   if (!rendered) {
      const uint32_t *generated_indices =
         (const uint32_t *)((const uint8_t *)package_mapping + heap_data_offset +
                            generated_draw[2] * sizeof(uint32_t));
      const uint32_t generated_count =
         *(const uint32_t *)((const uint8_t *)package_mapping + counts_offset);
      fprintf(stderr,
              "Mesa poly Gallium chain pixel mismatched (%u,%u,%u,%u); "
              "count %u, heap bottom %u, generated indices (%u,%u,%u)\n",
              pixel[0], pixel[1], pixel[2], pixel[3], generated_count,
              heap->bottom, generated_indices[0],
              generated_indices[1], generated_indices[2]);
   }

out:
   if (screen && fence)
      screen->fence_reference(screen, &fence, NULL);
   if (context) {
      context->bind_tcs_state(context, NULL);
      context->bind_tes_state(context, NULL);
      if (tcs_state)
         context->delete_tcs_state(context, tcs_state);
      if (tes_state)
         context->delete_tes_state(context, tes_state);
   }
   ralloc_free(tcs_state_nir);
   ralloc_free(tes_state_nir);
   pipe_resource_reference(&readback, NULL);
   if (surface)
      AO46MetalGalliumSurfaceDestroy(surface);
   pipe_resource_reference(&color, NULL);
   pipe_resource_reference(&package, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaPolyKernelExecutorDestroy(&executor);
   return rendered;
}

int
main(void)
{
   struct nir_shader *tcs = ao46_build_tcs();
   struct nir_shader *tes = ao46_build_tes();
   struct nir_shader *fragment = ao46_build_flat_fragment_shader();
   struct nir_shader *tcs_state_nir = tcs ? nir_shader_clone(NULL, tcs) : NULL;
   struct nir_shader *tes_state_nir = tes ? nir_shader_clone(NULL, tes) : NULL;
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaComputePipeline tcs_pipeline = {0};
   struct AO46MesaPolyTessellationPlan plan = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   const struct AO46MesaStaticBufferRequirement parameter_requirement = {
      .binding = 3,
      .minimum_size = sizeof(struct poly_tess_params),
   };
   bool passed = false;
   bool tess_state_nirs_handed_off = false;

   if (tcs && tes && fragment && tcs_state_nir && tes_state_nir &&
       AO46MesaPolyTessellationPlanCreate(tcs, 3, 3, 1, 3, &plan) &&
       AO46MesaPolyTessellationPlanFinalize(&plan, tes) &&
       AO46MesaPolyTessellationLower(tcs, tes, 3) &&
       AO46MetalAdapterCreate(&adapter) &&
       AO46MesaComputePipelineCreateWithStaticBuffers(
          &adapter, tcs, UINT16_C(1) << 3, &tcs_pipeline) &&
       AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
          &adapter, tes, fragment, AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, NULL,
          0, UINT16_C(1) << parameter_requirement.binding,
          &parameter_requirement, 1, 0, NULL, 0, &pipeline))
      tess_state_nirs_handed_off = true;
      passed = ao46_mesa_poly_gallium_chain_smoke(
         &adapter, tcs_state_nir, tes_state_nir, &tcs_pipeline, &plan,
         &pipeline);

   if (!tess_state_nirs_handed_off) {
      ralloc_free(tcs_state_nir);
      ralloc_free(tes_state_nir);
   }

   if (!passed)
      fputs("Mesa poly Gallium prefix/triangle/TES chain failed\n", stderr);

   AO46MesaRenderPipelineDestroy(&pipeline);
   AO46MesaComputePipelineDestroy(&tcs_pipeline);
   AO46MetalAdapterDestroy(&adapter);
   ralloc_free(fragment);
   ralloc_free(tes);
   ralloc_free(tcs);
   return passed ? 0 : 1;
}
