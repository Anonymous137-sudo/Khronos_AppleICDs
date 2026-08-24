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
#include "AO46MTLGallium.h"

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
#include <stdlib.h>
#include <string.h>

static struct pipe_screen *
ao46_poly_screen_create(const struct AO46MetalAdapter *adapter, bool promoted)
{
   return promoted ? AO46MTLGalliumScreenCreate(adapter)
                   : AO46MetalGalliumScreenCreate(adapter);
}

static struct pipe_surface *
ao46_poly_surface_create(struct pipe_resource *texture, bool promoted)
{
   struct pipe_surface *surface;

   if (!promoted)
      return AO46MetalGalliumSurfaceCreate(texture);
   if (!texture || !(texture->bind & PIPE_BIND_RENDER_TARGET))
      return NULL;
   surface = calloc(1, sizeof(*surface));
   if (!surface)
      return NULL;
   pipe_reference_init(&surface->reference, 1);
   pipe_resource_reference(&surface->texture, texture);
   surface->format = texture->format;
   surface->nr_samples = texture->nr_samples;
   return surface;
}

static void
ao46_poly_surface_destroy(struct pipe_surface *surface, bool promoted)
{
   if (!promoted) {
      AO46MetalGalliumSurfaceDestroy(surface);
      return;
   }
   if (surface) {
      pipe_resource_reference(&surface->texture, NULL);
      free(surface);
   }
}

static bool
ao46_poly_resource_mapping(struct pipe_resource *resource, bool promoted,
                           void **out_mapping, size_t *out_length)
{
   return promoted
             ? AO46MTLGalliumResourceGetCPUMapping(resource, out_mapping,
                                                   out_length)
             : AO46MetalGalliumResourceGetCPUMapping(resource, out_mapping,
                                                     out_length);
}

static bool
ao46_poly_resource_gpu_address(struct pipe_resource *resource, bool promoted,
                               uint64_t *out_address)
{
   const struct AO46MetalBuffer *buffer = NULL;

   if (promoted)
      return AO46MTLGalliumResourceGetGPUAddress(resource, out_address);
   return AO46MetalGalliumResourceGetMetalBuffer(resource, &buffer) &&
          AO46MetalBufferGetGPUAddress(buffer, out_address);
}

static bool
ao46_poly_write_gpu_address_root(struct pipe_resource *root,
                                 size_t root_offset,
                                 struct pipe_resource *target,
                                 size_t target_offset, bool promoted)
{
   return promoted
             ? AO46MTLGalliumResourceWriteGPUAddressRoot(
                  root, root_offset, target, target_offset)
             : AO46MetalGalliumResourceWriteGPUAddressRoot(
                  root, root_offset, target, target_offset);
}

static bool
ao46_poly_bind_render_pipeline(
   struct pipe_context *context,
   const struct AO46MetalRenderPipeline *pipeline, bool promoted)
{
   return promoted
             ? AO46MTLGalliumContextBindRenderPipeline(context, pipeline)
             : AO46MetalGalliumContextBindRenderPipeline(context, pipeline);
}

static bool
ao46_poly_bind_draw(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw, bool promoted)
{
   return promoted
             ? AO46MTLGalliumContextBindPolyTessellationDraw(context, draw)
             : AO46MetalGalliumContextBindPolyTessellationDraw(context, draw);
}

static bool
ao46_poly_bind_sequence(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence,
   bool promoted)
{
   return promoted
             ? AO46MTLGalliumContextBindPolyTessellationSequence(context,
                                                                 sequence)
             : AO46MetalGalliumContextBindPolyTessellationSequence(context,
                                                                    sequence);
}

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
ao46_build_vertex_for_tcs(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_poly_vertex_payload");
   const struct nir_io_semantics payload = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   const struct nir_io_semantics vertex_input = {
      .location = VERT_ATTRIB_GENERIC0,
      .num_slots = 1,
   };
   nir_def *input = nir_load_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), .base = 0, .range = 1,
      .dest_type = nir_type_float32, .io_semantics = vertex_input);
   nir_def *level = nir_channel(&builder, input, 0);

   nir_store_output(&builder,
                    nir_vec4(&builder, level, level, level,
                             nir_imm_float(&builder, 1.0f)),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = payload);
   nir_store_output(&builder,
                    nir_imm_vec4(&builder, 0.0f, 0.0f, 0.0f, 1.0f),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = position);
   nir_shader_gather_info(builder.shader,
                          nir_shader_get_entrypoint(builder.shader));
   return builder.shader;
}

static struct nir_shader *
ao46_build_tcs_with_vertex_input(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_CTRL, &kk_nir_options, "ao46_poly_vertex_input_tcs");
   const struct nir_io_semantics payload = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   const struct nir_io_semantics outer = {
      .location = VARYING_SLOT_TESS_LEVEL_OUTER,
      .num_slots = 1,
   };
   const struct nir_io_semantics inner = {
      .location = VARYING_SLOT_TESS_LEVEL_INNER,
      .num_slots = 1,
   };
   nir_def *input = nir_load_per_vertex_input(
      &builder, 4, 32, nir_imm_int(&builder, 0), nir_imm_int(&builder, 0),
      .io_semantics = payload, .dest_type = nir_type_float32);
   nir_def *level = nir_channel(&builder, input, 0);

   builder.shader->info.tess._primitive_mode = TESS_PRIMITIVE_TRIANGLES;
   builder.shader->info.tess.tcs_vertices_out = 1;
   nir_store_output(&builder,
                    nir_vec4(&builder, level, level, level,
                             nir_imm_float(&builder, 0.0f)),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = outer);
   nir_store_output(&builder,
                    nir_vec2(&builder, level, nir_imm_float(&builder, 0.0f)),
                    nir_imm_int(&builder, 0), .base = 0, .range = 1,
                    .write_mask = 0x3, .src_type = nir_type_float32,
                    .io_semantics = inner);
   nir_shader_gather_info(builder.shader,
                          nir_shader_get_entrypoint(builder.shader));
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
   const struct AO46MesaRenderPipeline *pipeline, bool promoted)
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
   const char *stage = "input validation";

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

   stage = "screen and resource creation";
   screen = ao46_poly_screen_create(adapter, promoted);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   package_template.width0 = package_bytes;
   package = screen ? screen->resource_create(screen, &package_template) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   surface = ao46_poly_surface_create(color, promoted);
   if (!screen || !context || !package || !color || !surface)
      goto out;
   stage = "poly kernel executor creation";
   if (!AO46MesaPolyKernelExecutorCreate(adapter, &executor))
      goto out;
   stage = "package CPU mapping";
   if (!ao46_poly_resource_mapping(package, promoted, &package_mapping,
                                   &package_length) ||
       package_length != package_bytes)
      goto out;
   stage = "package GPU address";
   if (!ao46_poly_resource_gpu_address(package, promoted, &package_address))
      goto out;
   stage = "package range validation";
   if (root_offset + sizeof(struct libkk_tess_tri_args) > sampler_table_offset ||
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

   bytes_per_row = (size_t)color_template.width0 * 4;
   readback_size = bytes_per_row * color_template.height0;

   stage = "readback allocation";
   readback_template.width0 = readback_size;
   readback = screen->resource_create(screen, &readback_template);
   if (!readback)
      goto out;

   stage = "package construction";
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
   if (!ao46_poly_write_gpu_address_root(
          package, root_offset, package, parameters_offset, promoted))
      goto out;
   if (!ao46_poly_write_gpu_address_root(
          package, count_root_offset, package, parameters_offset, promoted))
      goto out;

   stage = "pipeline and framebuffer binding";
   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   if (!ao46_poly_bind_render_pipeline(context, &pipeline->metal_pipeline,
                                        promoted))
      goto out;
   context->set_framebuffer_state(context, &framebuffer);

   /* Patch draws stay fail-closed until both the range and patch state exist. */
   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if (fence)
      goto out;

   stage = "TCS and TES state admission";
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

   stage = "poly draw binding";
   poly_tess_draw.parameter_resource = package;
   poly_tess_draw.index_resource = package;
   poly_tess_draw.indirect_resource = package;
   if (!ao46_poly_bind_draw(context, &poly_tess_draw, promoted))
      goto out;
   context->set_patch_vertices(context, poly_tess_draw.input_patch_size);

   root->tess_mode = POLY_TESS_MODE_WITH_COUNTS;
   count_root->tess_mode = POLY_TESS_MODE_COUNT;
   /* The pre-TES execution plan is required before patches can be admitted. */
   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if (fence)
      goto out;

   stage = "poly sequence binding";
   if (!ao46_poly_bind_sequence(context, &poly_tess_sequence, promoted))
      goto out;

   stage = "poly execution and terminal render";
   context->draw_vbo(context, &patch_info, 0, NULL, &patch_draw, 1);
   context->flush(context, &fence, 0);
   if ((!promoted && !fence) ||
       !ao46_poly_bind_draw(context, NULL, promoted) ||
       !ao46_poly_bind_render_pipeline(context, NULL, promoted))
      goto out;

   /* The terminal render fence retains the complete generated package. */
   completed = promoted || screen->fence_finish(screen, context, fence,
                                                 UINT64_MAX);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (!completed)
      goto out;

   stage = "generated draw validation";
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

   stage = "color readback";
   const struct pipe_box color_box = {
      .width = color_template.width0,
      .height = color_template.height0,
      .depth = 1,
   };
   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence,
                  promoted ? PIPE_FLUSH_HINT_FINISH : 0);
   if ((!promoted &&
        (!fence || !screen->fence_finish(screen, context, fence,
                                         UINT64_MAX))) ||
       !ao46_poly_resource_mapping(readback, promoted, &readback_mapping,
                                   &readback_length) ||
       readback_length < readback_size)
      goto out;
   if (fence)
      screen->fence_reference(screen, &fence, NULL);

   stage = "pixel validation";
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
   if (!rendered)
      fprintf(stderr, "Mesa poly %s screen stopped at: %s\n",
              promoted ? "promoted" : "reference", stage);
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
      ao46_poly_surface_destroy(surface, promoted);
   pipe_resource_reference(&color, NULL);
   pipe_resource_reference(&package, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaPolyKernelExecutorDestroy(&executor);
   return rendered;
}

/* Exercises the production path without any AO46-only package/pipeline bind. */
static bool
ao46_mesa_poly_gallium_state_tracker_smoke(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *tcs_nir, struct nir_shader *tes_nir,
   struct nir_shader *fragment_nir)
{
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *readback = NULL;
   struct pipe_resource *vertex_buffer = NULL;
   struct pipe_resource *indirect_buffer = NULL;
   struct pipe_surface *surface = NULL;
   struct pipe_fence_handle *fence = NULL;
   void *tcs_state = NULL;
   void *vertex_state = NULL;
   void *tes_state = NULL;
   void *fragment_state = NULL;
   void *vertex_elements_state = NULL;
   const float default_outer_level[] = {1.0f, 1.0f, 1.0f, 1.0f};
   const float default_inner_level[] = {1.0f, 1.0f};
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
      .width0 = 8 * 8 * 4,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_STAGING,
   };
   struct pipe_resource vertex_buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 7 * 4 * sizeof(float),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   struct pipe_resource indirect_buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 4 * sizeof(uint32_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER,
   };
   struct pipe_framebuffer_state framebuffer = {0};
   struct pipe_draw_info patch_info = {
      .mode = MESA_PRIM_PATCHES,
      .instance_count = 1,
   };
   /* Two retained draws prove asynchronous Gallium multi-draw scheduling and
    * nonzero first-vertex handling in the compute VS prepass. */
   const struct pipe_draw_start_count_bias patch_draws[] = {
      {.start = 1, .count = 3},
      {.start = 4, .count = 3},
   };
   const struct pipe_vertex_element vertex_element = {
      .src_offset = 0,
      .instance_divisor = 0,
      .vertex_buffer_index = 0,
      .src_format = PIPE_FORMAT_R32G32B32A32_FLOAT,
      .src_stride = 4 * sizeof(float),
   };
   struct pipe_vertex_buffer vertex_binding = {0};
   struct pipe_draw_indirect_info indirect = {
      .offset = 0,
      .stride = 4 * sizeof(uint32_t),
      .draw_count = 1,
   };
   const union pipe_color_union black = {.f = {0.0f, 0.0f, 0.0f, 0.0f}};
   const struct pipe_box color_box = {
      .width = 8,
      .height = 8,
      .depth = 1,
   };
   struct pipe_shader_state tcs_template = {
      .type = PIPE_SHADER_IR_NIR,
      .ir.nir = tcs_nir,
   };
   struct pipe_shader_state vertex_template = {
      .type = PIPE_SHADER_IR_NIR,
      .ir.nir = vertex_nir,
   };
   struct pipe_shader_state tes_template = {
      .type = PIPE_SHADER_IR_NIR,
      .ir.nir = tes_nir,
   };
   struct pipe_shader_state fragment_template = {
      .type = PIPE_SHADER_IR_NIR,
      .ir.nir = fragment_nir,
   };
   void *readback_mapping = NULL;
   size_t readback_length = 0;
   void *vertex_mapping = NULL;
   size_t vertex_mapping_length = 0;
   void *indirect_mapping = NULL;
   size_t indirect_mapping_length = 0;
   bool rendered = false;
   bool indirect_rendered = false;

   if (!adapter || !vertex_nir || !tcs_nir || !tes_nir || !fragment_nir)
      return false;

   screen = ao46_poly_screen_create(adapter, true);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   color = screen ? screen->resource_create(screen, &color_template) : NULL;
   readback = screen ? screen->resource_create(screen, &readback_template) : NULL;
   vertex_buffer =
      screen ? screen->resource_create(screen, &vertex_buffer_template) : NULL;
   indirect_buffer = screen
      ? screen->resource_create(screen, &indirect_buffer_template)
      : NULL;
   surface = ao46_poly_surface_create(color, true);
   if (!screen || !context || !color || !readback || !vertex_buffer ||
       !indirect_buffer ||
       !surface ||
       !ao46_poly_resource_mapping(vertex_buffer, true, &vertex_mapping,
                                   &vertex_mapping_length) ||
       vertex_mapping_length < vertex_buffer_template.width0 ||
       !ao46_poly_resource_mapping(indirect_buffer, true, &indirect_mapping,
                                   &indirect_mapping_length) ||
       indirect_mapping_length < indirect_buffer_template.width0)
      goto out;

   for (unsigned i = 0; i < 7; ++i) {
      float *vertex = (float *)vertex_mapping + i * 4;
      vertex[0] = i == 1 ? 2.0f : 1.0f;
      vertex[1] = vertex[0];
      vertex[2] = vertex[0];
      vertex[3] = 1.0f;
   }
   {
      const uint32_t command[] = {3, 1, 1, 0};
      memcpy(indirect_mapping, command, sizeof(command));
   }

   vertex_state = context->create_vs_state(context, &vertex_template);
   tcs_state = context->create_tcs_state(context, &tcs_template);
   tes_state = context->create_tes_state(context, &tes_template);
   fragment_state = context->create_fs_state(context, &fragment_template);
   vertex_elements_state = context->create_vertex_elements_state(
      context, 1, &vertex_element);
   if (!vertex_state || !tcs_state || !tes_state || !fragment_state ||
       !vertex_elements_state)
      goto out;

   framebuffer.width = color_template.width0;
   framebuffer.height = color_template.height0;
   framebuffer.nr_cbufs = 1;
   framebuffer.cbufs[0] = *surface;
   context->set_framebuffer_state(context, &framebuffer);
   context->bind_vs_state(context, vertex_state);
   context->bind_tcs_state(context, tcs_state);
   context->bind_tes_state(context, tes_state);
   context->bind_fs_state(context, fragment_state);
   context->bind_vertex_elements_state(context, vertex_elements_state);
   pipe_resource_reference(&vertex_binding.buffer.resource, vertex_buffer);
   context->set_vertex_buffers(context, 1, &vertex_binding);
   context->set_tess_state(context, default_outer_level, default_inner_level);
   context->set_patch_vertices(context, 3);

   context->draw_vbo(context, &patch_info, 0, NULL, patch_draws,
                     ARRAY_SIZE(patch_draws));
   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, PIPE_FLUSH_HINT_FINISH);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (!ao46_poly_resource_mapping(readback, true, &readback_mapping,
                                   &readback_length) ||
       readback_length < readback_template.width0)
      goto out;

   const uint8_t *pixel = (const uint8_t *)readback_mapping + (4 * 8 + 4) * 4;
   rendered = pixel[0] == 0xff && pixel[1] == 0x00 && pixel[2] == 0x00 &&
              pixel[3] == 0xff;
   if (!rendered) {
      fprintf(stderr,
              "Mesa poly state-tracker pixel mismatched (%u,%u,%u,%u)\n",
              pixel[0], pixel[1], pixel[2], pixel[3]);
      goto out;
   }

   context->clear_render_target(context, surface, &black, 0, 0,
                                color_template.width0, color_template.height0,
                                false);
   indirect.buffer = indirect_buffer;
   context->draw_vbo(context, &patch_info, 0, &indirect, NULL, 0);
   context->resource_copy_region(context, readback, 0, 0, 0, 0, color, 0,
                                 &color_box);
   context->flush(context, &fence, PIPE_FLUSH_HINT_FINISH);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   pixel = (const uint8_t *)readback_mapping + (4 * 8 + 4) * 4;
   indirect_rendered = pixel[0] == 0xff && pixel[1] == 0x00 &&
                       pixel[2] == 0x00 && pixel[3] == 0xff;
   if (!indirect_rendered) {
      fprintf(stderr,
              "Mesa poly indirect pixel mismatched (%u,%u,%u,%u)\n",
              pixel[0], pixel[1], pixel[2], pixel[3]);
   }

out:
   if (screen && fence)
      screen->fence_reference(screen, &fence, NULL);
   if (context) {
      context->bind_vs_state(context, NULL);
      context->bind_tcs_state(context, NULL);
      context->bind_tes_state(context, NULL);
      context->bind_fs_state(context, NULL);
      context->bind_vertex_elements_state(context, NULL);
      context->set_vertex_buffers(context, 0, NULL);
      if (tcs_state)
         context->delete_tcs_state(context, tcs_state);
      if (vertex_state)
         context->delete_vs_state(context, vertex_state);
      if (tes_state)
         context->delete_tes_state(context, tes_state);
      if (fragment_state)
         context->delete_fs_state(context, fragment_state);
      if (vertex_elements_state)
         context->delete_vertex_elements_state(context, vertex_elements_state);
   }
   pipe_resource_reference(&vertex_binding.buffer.resource, NULL);
   if (surface)
      ao46_poly_surface_destroy(surface, true);
   pipe_resource_reference(&readback, NULL);
   pipe_resource_reference(&color, NULL);
   pipe_resource_reference(&vertex_buffer, NULL);
   pipe_resource_reference(&indirect_buffer, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   return rendered && indirect_rendered;
}

int
main(void)
{
   struct nir_shader *tcs = ao46_build_tcs();
   struct nir_shader *tes = ao46_build_tes();
   struct nir_shader *fragment = ao46_build_flat_fragment_shader();
   struct nir_shader *reference_tcs_state =
      tcs ? nir_shader_clone(NULL, tcs) : NULL;
   struct nir_shader *reference_tes_state =
      tes ? nir_shader_clone(NULL, tes) : NULL;
   struct nir_shader *promoted_tcs_state =
      tcs ? nir_shader_clone(NULL, tcs) : NULL;
   struct nir_shader *promoted_tes_state =
      tes ? nir_shader_clone(NULL, tes) : NULL;
   struct nir_shader *state_tracker_vertex = ao46_build_vertex_for_tcs();
   struct nir_shader *state_tracker_tcs = ao46_build_tcs_with_vertex_input();
   struct nir_shader *state_tracker_tes =
      tes ? nir_shader_clone(NULL, tes) : NULL;
   struct nir_shader *state_tracker_fragment =
      fragment ? nir_shader_clone(NULL, fragment) : NULL;
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaComputePipeline tcs_pipeline = {0};
   struct AO46MesaPolyTessellationPlan plan = {0};
   struct AO46MesaRenderPipeline pipeline = {0};
   const struct AO46MesaStaticBufferRequirement parameter_requirement = {
      .binding = 3,
      .minimum_size = sizeof(struct poly_tess_params),
   };
   bool reference_passed = false;
   bool promoted_passed = false;
   bool state_tracker_passed = false;
   bool reference_states_handed_off = false;
   bool promoted_states_handed_off = false;

   if (tcs && tes && fragment && reference_tcs_state && reference_tes_state &&
       promoted_tcs_state && promoted_tes_state && state_tracker_vertex &&
       state_tracker_tcs && state_tracker_tes && state_tracker_fragment &&
       AO46MesaPolyTessellationPlanCreate(tcs, 3, 3, 1, 3, &plan) &&
       AO46MesaPolyTessellationPlanFinalize(&plan, tes) &&
       AO46MesaPolyTessellationLower(tcs, tes, 3) &&
       AO46MetalAdapterCreate(&adapter) &&
       AO46MesaComputePipelineCreateWithStaticBuffers(
          &adapter, tcs, UINT16_C(1) << 3, &tcs_pipeline) &&
       AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
          &adapter, tes, fragment, AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM, NULL,
          0, UINT16_C(1) << parameter_requirement.binding,
          &parameter_requirement, 1, 0, NULL, 0, &pipeline)) {
      reference_states_handed_off = true;
      reference_passed = ao46_mesa_poly_gallium_chain_smoke(
         &adapter, reference_tcs_state, reference_tes_state, &tcs_pipeline,
         &plan, &pipeline, false);
      promoted_states_handed_off = true;
      promoted_passed = ao46_mesa_poly_gallium_chain_smoke(
         &adapter, promoted_tcs_state, promoted_tes_state, &tcs_pipeline,
         &plan, &pipeline, true);
      state_tracker_passed = ao46_mesa_poly_gallium_state_tracker_smoke(
         &adapter, state_tracker_vertex, state_tracker_tcs, state_tracker_tes,
         state_tracker_fragment);
   }

   if (!reference_states_handed_off) {
      ralloc_free(reference_tcs_state);
      ralloc_free(reference_tes_state);
   }
   if (!promoted_states_handed_off) {
      ralloc_free(promoted_tcs_state);
      ralloc_free(promoted_tes_state);
   }

   if (!reference_passed)
      fputs("Mesa poly reference Gallium chain failed\n", stderr);
   if (!promoted_passed)
      fputs("Mesa poly promoted AO46MTLGallium chain failed\n", stderr);
   if (!state_tracker_passed)
      fputs("Mesa poly normal Gallium state path failed\n", stderr);

   AO46MesaRenderPipelineDestroy(&pipeline);
   AO46MesaComputePipelineDestroy(&tcs_pipeline);
   AO46MetalAdapterDestroy(&adapter);
   ralloc_free(fragment);
   ralloc_free(tes);
   ralloc_free(tcs);
   ralloc_free(state_tracker_fragment);
   ralloc_free(state_tracker_tes);
   ralloc_free(state_tracker_tcs);
   ralloc_free(state_tracker_vertex);
   return reference_passed && promoted_passed && state_tracker_passed ? 0 : 1;
}
