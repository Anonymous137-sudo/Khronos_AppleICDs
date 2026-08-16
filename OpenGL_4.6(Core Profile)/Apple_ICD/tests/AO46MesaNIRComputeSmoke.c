/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLComputePipeline.h"
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
ao46_build_mesa_compute_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_mesa_compute_smoke");
   nir_def *root;
   nir_def *global_id;
   nir_def *byte_offset;
   nir_def *address;

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;

   /* Bind Mesa's root-buffer ABI directly to the output PIPE_BUFFER. */
   root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 0);
   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   byte_offset = nir_imul_imm(&builder, global_id, sizeof(uint32_t));
   address = nir_iadd(&builder, root, nir_u2u64(&builder, byte_offset));
   nir_store_global(&builder, nir_iadd_imm(&builder, global_id, 0x4600), address,
                    .align_mul = sizeof(uint32_t),
                    .access = ACCESS_NON_READABLE);
   return builder.shader;
}

static struct nir_shader *
ao46_build_rgb32_buffer_texture_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_rgb32_buffer_texture_smoke");
   nir_def *root;
   nir_def *global_id;
   nir_def *byte_offset;
   nir_def *address;
   nir_def *texel;

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;

   root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 0);
   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   texel = nir_txf(&builder, global_id, .dim = GLSL_SAMPLER_DIM_BUF,
                   .texture_index = 2, .dest_type = nir_type_uint32);
   byte_offset = nir_imul_imm(&builder, global_id, 4 * sizeof(uint32_t));
   address = nir_iadd(&builder, root, nir_u2u64(&builder, byte_offset));
   nir_store_global(&builder, texel, address,
                    .align_mul = sizeof(uint32_t),
                    .access = ACCESS_NON_READABLE);
   return builder.shader;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaComputePipeline pipeline = {0};
   struct AO46MesaComputePipeline rgb32_pipeline = {0};
   struct nir_shader *nir = NULL;
   struct nir_shader *rgb32_nir = NULL;
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *output = NULL;
   struct pipe_resource *sampler_table = NULL;
   struct pipe_resource *rgb32_input = NULL;
   struct pipe_resource *rgb32_output = NULL;
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct pipe_transfer *write_transfer = NULL;
   struct pipe_resource *resources[3];
   uint32_t offsets[3] = {0, 0, 0};
   uint32_t indices[3] = {0, 1, 2};
   struct pipe_resource buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 4096,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_VERTEX_BUFFER,
   };
   const struct pipe_box readback_box = {
      .width = 16 * (int)sizeof(uint32_t),
      .height = 1,
      .depth = 1,
   };
   const struct pipe_box rgb32_readback_box = {
      .width = 16 * 4 * (int)sizeof(uint32_t),
      .height = 1,
      .depth = 1,
   };
   const struct pipe_box rgb32_write_box = {
      .width = 16 * 3 * (int)sizeof(uint32_t),
      .height = 1,
      .depth = 1,
   };
   const struct AO46MesaRGB32BufferTextureBinding rgb32_binding = {
      .texture_index = 2,
      .buffer_binding = 2,
      .element_count = 16,
      .kind = AO46_MESA_RGB32_BUFFER_TEXTURE_UINT,
   };
   uint16_t rgb32_mask = 0;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Mesa NIR compute smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   nir = ao46_build_mesa_compute_shader();
   if (!nir || !AO46MesaComputePipelineCreate(&adapter, nir, &pipeline) ||
       !pipeline.msl_source || !pipeline.entrypoint ||
       !strstr(pipeline.msl_source, "kernel") ||
       !strstr(pipeline.msl_source, "gl_GlobalInvocationID") ||
       pipeline.reflection.required_buffer_mask != 0x3 ||
       pipeline.reflection.local_size[0] != 16 ||
       pipeline.reflection.thread_execution_width == 0 ||
       pipeline.reflection.max_threads_per_threadgroup < 16) {
      fputs("Mesa NIR-to-MSL pipeline creation contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   rgb32_nir = ao46_build_rgb32_buffer_texture_shader();
   if (!rgb32_nir ||
       !AO46MesaRGB32BufferTextureBindingsMask(&rgb32_binding, 1,
                                                &rgb32_mask) ||
       rgb32_mask != (UINT16_C(1) << 2) ||
       !AO46MesaNIRLowerRGB32BufferTextures(rgb32_nir, &rgb32_binding, 1) ||
       !AO46MesaComputePipelineCreateWithStaticBuffers(
          &adapter, rgb32_nir, rgb32_mask, &rgb32_pipeline) ||
       !rgb32_pipeline.msl_source ||
       !strstr(rgb32_pipeline.msl_source,
               "constant Buffer &buf2 [[buffer(2)]]") ||
       strstr(rgb32_pipeline.msl_source, "texture_buffer") ||
       rgb32_pipeline.reflection.required_buffer_mask != 0x7) {
      fputs("RGB32 buffer-texture NIR lowering contract was unexpected\n", stderr);
      failed = 1;
      goto out;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY)
                    : NULL;
   output = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   sampler_table = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   rgb32_input = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   rgb32_output = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   if (!screen || !context || !output || !sampler_table || !rgb32_input ||
       !rgb32_output) {
      fputs("Mesa NIR compute smoke could not create Gallium resources\n", stderr);
      failed = 1;
      goto out;
   }

   uint32_t *rgb32_values = context->buffer_map(
      context, rgb32_input, 0, PIPE_MAP_WRITE, &rgb32_write_box,
      &write_transfer);
   if (!rgb32_values || !write_transfer) {
      fputs("RGB32 source buffer could not be mapped\n", stderr);
      failed = 1;
      goto out;
   }
   for (uint32_t i = 0; i < 16; ++i) {
      rgb32_values[3 * i + 0] = 0x1000u + i;
      rgb32_values[3 * i + 1] = 0x2000u + i;
      rgb32_values[3 * i + 2] = 0x3000u + i;
   }
   context->buffer_unmap(context, write_transfer);
   write_transfer = NULL;

   resources[0] = output;
   resources[1] = sampler_table;
   if (!AO46MesaComputePipelineDispatch(&pipeline, context, resources, offsets,
                                        indices, 2, 16, 1, 1, &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Mesa-generated compute dispatch did not complete\n", stderr);
      failed = 1;
      goto out;
   }

   screen->fence_reference(screen, &fence, NULL);
   uint32_t *values = context->buffer_map(context, output, 0, PIPE_MAP_READ,
                                          &readback_box, &transfer);
   if (!values || !transfer) {
      fputs("Mesa-generated compute readback could not map output\n", stderr);
      failed = 1;
      goto out;
   }

   for (uint32_t i = 0; i < 16; ++i) {
      if (values[i] != 0x4600u + i) {
         fputs("Mesa-generated compute output mismatched\n", stderr);
         failed = 1;
         break;
      }
   }
   if (transfer) {
      context->buffer_unmap(context, transfer);
      transfer = NULL;
   }
   if (failed)
      goto out;

   resources[0] = rgb32_output;
   resources[1] = sampler_table;
   resources[2] = rgb32_input;
   if (!AO46MesaComputePipelineDispatch(&rgb32_pipeline, context, resources,
                                        offsets, indices, 3, 16, 1, 1,
                                        &fence) ||
       !fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("RGB32 buffer-texture compute dispatch did not complete\n", stderr);
      failed = 1;
      goto out;
   }

   screen->fence_reference(screen, &fence, NULL);
   uint32_t *rgb32_output_values = context->buffer_map(
      context, rgb32_output, 0, PIPE_MAP_READ, &rgb32_readback_box, &transfer);
   if (!rgb32_output_values || !transfer) {
      fputs("RGB32 buffer-texture output could not be mapped\n", stderr);
      failed = 1;
      goto out;
   }
   for (uint32_t i = 0; i < 16; ++i) {
      if (rgb32_output_values[4 * i + 0] != 0x1000u + i ||
          rgb32_output_values[4 * i + 1] != 0x2000u + i ||
          rgb32_output_values[4 * i + 2] != 0x3000u + i ||
          rgb32_output_values[4 * i + 3] != 1u) {
         fputs("RGB32 buffer-texture output mismatched\n", stderr);
         failed = 1;
         break;
      }
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (write_transfer)
      context->buffer_unmap(context, write_transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   pipe_resource_reference(&rgb32_output, NULL);
   pipe_resource_reference(&rgb32_input, NULL);
   pipe_resource_reference(&sampler_table, NULL);
   pipe_resource_reference(&output, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MesaComputePipelineDestroy(&pipeline);
   AO46MesaComputePipelineDestroy(&rgb32_pipeline);
   ralloc_free(nir);
   ralloc_free(rgb32_nir);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
