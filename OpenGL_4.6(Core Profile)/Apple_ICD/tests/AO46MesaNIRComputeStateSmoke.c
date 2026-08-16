/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

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

static struct nir_shader *
ao46_build_compute_state_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_compute_state_smoke");
   nir_def *input_root;
   nir_def *output_root;
   nir_def *global_id;
   nir_def *input_address;
   nir_def *address;
   nir_def *input;

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;

   input_root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 2);
   output_root = nir_load_buffer_ptr_kk(&builder, 1, 64, .binding = 3);
   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   input_address = nir_iadd(&builder, input_root,
                            nir_u2u64(&builder,
                                      nir_imul_imm(&builder, global_id,
                                                   sizeof(uint32_t))));
   address = nir_iadd(&builder, output_root,
                      nir_u2u64(&builder,
                                nir_imul_imm(&builder, global_id,
                                             sizeof(uint32_t))));
   input = nir_load_global(&builder, 1, 32, input_address,
                           .align_mul = sizeof(uint32_t),
                           .access = ACCESS_NON_WRITEABLE);
   nir_store_global(&builder, nir_iadd_imm(&builder, input, 0x4300), address,
                    .align_mul = sizeof(uint32_t),
                    .access = ACCESS_NON_READABLE);
   return builder.shader;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *output = NULL;
   struct pipe_resource *input = NULL;
   struct pipe_resource *sampler_table = NULL;
   struct pipe_resource *indirect = NULL;
   struct pipe_shader_buffer shader_buffers[4] = {{0}};
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct nir_shader *nir = NULL;
   void *compute_state = NULL;
   struct pipe_compute_state_object_info compute_info = {0};
   struct pipe_box readback_box = {
      .width = 32 * (int)sizeof(uint32_t),
      .height = 1,
      .depth = 1,
   };
   const struct pipe_resource buffer_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 4096,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SHADER_BUFFER,
   };
   const struct pipe_compute_state compute_template = {
      .ir_type = PIPE_SHADER_IR_NIR,
      .prog = NULL,
      .static_shared_mem = 0,
   };
   const struct pipe_resource indirect_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 3 * sizeof(uint32_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER,
   };
   const uint32_t indirect_counts[] = {2, 1, 1};
   const uint32_t zeros[32] = {0};
   uint32_t input_values[32];
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("Compute-state smoke could not create a Metal adapter\n", stderr);
      return 1;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY)
                    : NULL;
   output = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   input = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   sampler_table = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   indirect = screen ? screen->resource_create(screen, &indirect_template) : NULL;
   nir = ao46_build_compute_state_shader();
   if (!screen || !context || !output || !input || !sampler_table || !indirect ||
       !nir ||
       !context->create_compute_state || !context->bind_compute_state ||
       !context->delete_compute_state || !context->set_shader_buffers ||
       !context->launch_grid || !context->memory_barrier) {
      fputs("Compute-state Gallium callbacks were unavailable\n", stderr);
      failed = 1;
      goto out;
   }

   struct pipe_compute_state state = compute_template;
   state.prog = nir;
   compute_state = context->create_compute_state(context, &state);
   if (!compute_state || nir->info.stage != MESA_SHADER_COMPUTE) {
      fputs("Compute-state creation did not retain a separate Mesa NIR variant\n",
            stderr);
      failed = 1;
      goto out;
   }

   context->get_compute_state_info(context, compute_state, &compute_info);
   if (compute_info.max_threads < 16 || compute_info.preferred_simd_size == 0 ||
       context->get_compute_state_subgroup_size(context, compute_state,
                                                (uint32_t[]){16, 1, 1}) == 0) {
      fputs("Compute-state hardware limits were not reported\n", stderr);
      failed = 1;
      goto out;
   }

   context->bind_compute_state(context, compute_state);
   shader_buffers[0] = (struct pipe_shader_buffer){
      .buffer = output,
      .buffer_size = 32 * sizeof(uint32_t),
   };
   shader_buffers[1] = (struct pipe_shader_buffer){
      .buffer = sampler_table,
      .buffer_size = sampler_table->width0,
   };
   shader_buffers[2] = (struct pipe_shader_buffer){
      .buffer = input,
      .buffer_size = 32 * sizeof(uint32_t),
   };
   shader_buffers[3] = (struct pipe_shader_buffer){
      .buffer = output,
      .buffer_size = 32 * sizeof(uint32_t),
   };
   for (uint32_t i = 0; i < ARRAY_SIZE(input_values); ++i)
      input_values[i] = i;
   context->buffer_subdata(context, input, 0, 0, sizeof(input_values),
                           input_values);
   context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 4,
                               shader_buffers, UINT32_C(1) << 3);
   context->buffer_subdata(context, indirect, 0, 0, sizeof(indirect_counts),
                           indirect_counts);

   {
      const struct pipe_grid_info partial_grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .last_block = {15, 1, 1},
         .grid = {1, 1, 1},
      };

      context->launch_grid(context, &partial_grid);
      context->flush(context, &fence, 0);
      if (fence) {
         fputs("Compute-state path accepted a partial workgroup\n", stderr);
         failed = 1;
         goto out;
      }
   }

   {
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .grid = {1, 1, 1},
      };

      context->launch_grid(context, &grid);
   }
   context->memory_barrier(context,
                           PIPE_BARRIER_SHADER_BUFFER | PIPE_BARRIER_MAPPED_BUFFER);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Compute-state launch_grid did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   /* A malformed command-record range must not reach the Metal encoder. */
   context->buffer_subdata(context, output, 0, 0, sizeof(zeros), zeros);
   {
      const struct pipe_grid_info malformed_indirect_grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .indirect = indirect,
         .indirect_offset = 2,
      };

      context->launch_grid(context, &malformed_indirect_grid);
      const uint32_t *invalid_values = context->buffer_map(
         context, output, 0, PIPE_MAP_READ, &readback_box, &transfer);

      if (!invalid_values || !transfer) {
         fputs("Compute-state invalid-indirect output could not be read\n", stderr);
         failed = 1;
         goto out;
      }
      for (uint32_t i = 0; i < 32; ++i) {
         if (invalid_values[i] != 0) {
            fputs("Compute-state path accepted misaligned indirect arguments\n",
                  stderr);
            failed = 1;
            break;
         }
      }
      context->buffer_unmap(context, transfer);
      transfer = NULL;
      if (failed)
         goto out;
   }

   /* Keep the indirect count GPU-resident and prove it overwrites fresh data. */
   {
      const struct pipe_grid_info indirect_grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .indirect = indirect,
      };

      context->launch_grid(context, &indirect_grid);
   }
   context->memory_barrier(context,
                           PIPE_BARRIER_SHADER_BUFFER | PIPE_BARRIER_MAPPED_BUFFER);
   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("Compute-state indirect launch_grid did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   const uint32_t *values = context->buffer_map(
      context, output, 0, PIPE_MAP_READ, &readback_box, &transfer);
   if (!values || !transfer) {
      fputs("Compute-state output could not be read\n", stderr);
      failed = 1;
      goto out;
   }
   for (uint32_t i = 0; i < 32; ++i) {
      if (values[i] != 0x4300u + i) {
         fputs("Compute-state output mismatched\n", stderr);
         failed = 1;
         break;
      }
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (context && compute_state) {
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 4, NULL, 0);
      context->bind_compute_state(context, NULL);
      context->delete_compute_state(context, compute_state);
   }
   ralloc_free(nir);
   pipe_resource_reference(&sampler_table, NULL);
   pipe_resource_reference(&indirect, NULL);
   pipe_resource_reference(&input, NULL);
   pipe_resource_reference(&output, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
