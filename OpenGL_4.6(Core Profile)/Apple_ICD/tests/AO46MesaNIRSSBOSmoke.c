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
ao46_build_static_ssbo_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_static_ssbo_smoke");
   nir_def *global_id;
   nir_def *offset;
   nir_def *value;

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;

   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   offset = nir_imul_imm(&builder, global_id, sizeof(uint32_t));
   value = nir_load_ssbo(&builder, 1, 32, nir_imm_int(&builder, 0), offset,
                         .align_mul = sizeof(uint32_t),
                         .access = ACCESS_NON_WRITEABLE);
   nir_store_ssbo(&builder, nir_iadd_imm(&builder, value, 0x4a00),
                  nir_imm_int(&builder, 1), offset,
                  .write_mask = 0x1, .align_mul = sizeof(uint32_t),
                  .access = ACCESS_NON_READABLE);
   return builder.shader;
}

static struct nir_shader *
ao46_build_dynamic_ssbo_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_dynamic_ssbo_reject");
   nir_def *global_id;

   builder.shader->info.workgroup_size[0] = 1;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;
   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   (void)nir_load_ssbo(&builder, 1, 32, global_id, nir_imm_int(&builder, 0),
                       .align_mul = sizeof(uint32_t));
   return builder.shader;
}

static struct nir_shader *
ao46_build_static_ssbo_atomic_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_static_ssbo_atomic_smoke");

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;
   (void)nir_ssbo_atomic(&builder, 32, nir_imm_int(&builder, 0),
                         nir_imm_int(&builder, 0), nir_imm_int(&builder, 1),
                         .atomic_op = nir_atomic_op_iadd,
                         .access = ACCESS_ATOMIC | ACCESS_COHERENT);
   return builder.shader;
}

/* Preserve the returned value as well as the atomic update itself. */
static struct nir_shader *
ao46_build_static_ssbo_atomic_swap_shader(void)
{
   nir_builder builder = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_static_ssbo_atomic_swap_smoke");
   nir_def *global_id;
   nir_def *offset;
   nir_def *previous;

   builder.shader->info.workgroup_size[0] = 16;
   builder.shader->info.workgroup_size[1] = 1;
   builder.shader->info.workgroup_size[2] = 1;
   global_id = nir_channel(&builder,
                           nir_load_global_invocation_id(&builder, 32), 0);
   offset = nir_imul_imm(&builder, global_id, sizeof(uint32_t));
   previous = nir_ssbo_atomic_swap(
      &builder, 32, nir_imm_int(&builder, 0), nir_imm_int(&builder, 0),
      nir_imm_int(&builder, 0x5a5a), nir_imm_int(&builder, 0),
      .atomic_op = nir_atomic_op_xchg,
      .access = ACCESS_ATOMIC | ACCESS_COHERENT);
   nir_store_ssbo(&builder, previous, nir_imm_int(&builder, 1), offset,
                  .write_mask = 0x1, .align_mul = sizeof(uint32_t),
                  .access = ACCESS_NON_READABLE);
   return builder.shader;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *root = NULL;
   struct pipe_resource *sampler_table = NULL;
   struct pipe_resource *input = NULL;
   struct pipe_resource *output = NULL;
   struct pipe_resource *rebound_output = NULL;
   struct pipe_resource *atomic_counter = NULL;
   struct pipe_resource *atomic_previous_values = NULL;
   struct pipe_shader_buffer shader_buffers[4] = {{0}};
   struct pipe_fence_handle *fence = NULL;
   struct pipe_transfer *transfer = NULL;
   struct nir_shader *nir = NULL;
   struct nir_shader *dynamic_nir = NULL;
   struct nir_shader *atomic_nir = NULL;
   struct nir_shader *atomic_swap_nir = NULL;
   void *compute_state = NULL;
   void *atomic_compute_state = NULL;
   void *atomic_swap_compute_state = NULL;
   struct pipe_box readback_box = {
      .x = 128,
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
   };
   uint32_t input_values[32];
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("SSBO smoke could not create a Metal adapter\n", stderr);
      return 1;
   }

   screen = AO46MetalGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, PIPE_CONTEXT_COMPUTE_ONLY)
                    : NULL;
   root = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   sampler_table = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   input = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   output = screen ? screen->resource_create(screen, &buffer_template) : NULL;
   rebound_output =
      screen ? screen->resource_create(screen, &buffer_template) : NULL;
   atomic_counter = screen ? screen->resource_create(screen, &buffer_template)
                           : NULL;
   atomic_previous_values =
      screen ? screen->resource_create(screen, &buffer_template) : NULL;
   nir = ao46_build_static_ssbo_shader();
   dynamic_nir = ao46_build_dynamic_ssbo_shader();
   atomic_nir = ao46_build_static_ssbo_atomic_shader();
   atomic_swap_nir = ao46_build_static_ssbo_atomic_swap_shader();
   if (!screen || !context || !root || !sampler_table || !input || !output ||
       !atomic_counter || !atomic_previous_values || !rebound_output || !nir ||
       !dynamic_nir || !atomic_nir || !atomic_swap_nir ||
       !context->create_compute_state ||
       !context->bind_compute_state || !context->delete_compute_state ||
       !context->set_shader_buffers || !context->launch_grid) {
      fputs("SSBO smoke Gallium callbacks were unavailable\n", stderr);
      failed = 1;
      goto out;
   }

   {
      struct pipe_compute_state dynamic_state = compute_template;

      dynamic_state.prog = dynamic_nir;
      if (context->create_compute_state(context, &dynamic_state)) {
         fputs("SSBO smoke accepted dynamic storage-buffer indexing\n", stderr);
         failed = 1;
         goto out;
      }
   }

   {
      struct pipe_compute_state state = compute_template;

      state.prog = nir;
      compute_state = context->create_compute_state(context, &state);
   }
   if (!compute_state) {
      fputs("SSBO smoke could not lower static Mesa SSBO operations\n", stderr);
      failed = 1;
      goto out;
   }
   {
      struct pipe_compute_state state = compute_template;

      state.prog = atomic_nir;
      atomic_compute_state = context->create_compute_state(context, &state);
   }
   if (!atomic_compute_state) {
      fputs("SSBO smoke could not lower static Mesa SSBO atomics\n", stderr);
      failed = 1;
      goto out;
   }
   {
      struct pipe_compute_state state = compute_template;

      state.prog = atomic_swap_nir;
      atomic_swap_compute_state = context->create_compute_state(context, &state);
   }
   if (!atomic_swap_compute_state) {
      fputs("SSBO smoke could not lower static Mesa atomic exchange\n", stderr);
      failed = 1;
      goto out;
   }

   for (uint32_t i = 0; i < ARRAY_SIZE(input_values); ++i)
      input_values[i] = i;
   context->buffer_subdata(context, input, 0, 0, sizeof(input_values),
                           input_values);
   shader_buffers[0] = (struct pipe_shader_buffer){
      .buffer = root,
      .buffer_size = root->width0,
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
      .buffer_offset = 128,
      .buffer_size = 32 * sizeof(uint32_t),
   };
   context->bind_compute_state(context, compute_state);
   context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0,
                               ARRAY_SIZE(shader_buffers), shader_buffers,
                               UINT32_C(1) << 3);

   {
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .grid = {2, 1, 1},
      };

      context->launch_grid(context, &grid);
   }

   context->flush(context, &fence, 0);
   if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
      fputs("SSBO smoke dispatch did not complete\n", stderr);
      failed = 1;
      goto out;
   }
   screen->fence_reference(screen, &fence, NULL);

   {
      const uint32_t *values = context->buffer_map(
         context, output, 0, PIPE_MAP_READ, &readback_box, &transfer);

      if (!values || !transfer) {
         fputs("SSBO smoke output could not map\n", stderr);
         failed = 1;
         goto out;
      }
      for (uint32_t i = 0; i < 32; ++i) {
         if (values[i] != 0x4a00u + i) {
            fputs("SSBO smoke output mismatched\n", stderr);
            failed = 1;
            break;
         }
      }
      context->buffer_unmap(context, transfer);
      transfer = NULL;
   }
   if (failed)
      goto out;

   /* Rebind one slot and a nonzero range without disturbing the other SSBOs. */
   {
      const struct pipe_shader_buffer rebound_buffer = {
         .buffer = rebound_output,
         .buffer_offset = 256,
         .buffer_size = 32 * sizeof(uint32_t),
      };
      struct pipe_box rebound_readback_box = readback_box;

      rebound_readback_box.x = 256;
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 3, 1,
                                  &rebound_buffer, UINT32_C(1));
      {
         const struct pipe_grid_info grid = {
            .work_dim = 1,
            .block = {16, 1, 1},
            .grid = {2, 1, 1},
         };

         context->launch_grid(context, &grid);
      }
      context->flush(context, &fence, 0);
      if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
         fputs("SSBO sparse rebind dispatch did not complete\n", stderr);
         failed = 1;
         goto out;
      }
      screen->fence_reference(screen, &fence, NULL);

      {
         const uint32_t *values = context->buffer_map(
            context, rebound_output, 0, PIPE_MAP_READ, &rebound_readback_box,
            &transfer);

         if (!values || !transfer) {
            fputs("SSBO sparse rebind output could not map\n", stderr);
            failed = 1;
            goto out;
         }
         for (uint32_t i = 0; i < 32; ++i) {
            if (values[i] != 0x4a00u + i) {
               fputs("SSBO sparse rebind range mismatched\n", stderr);
               failed = 1;
               break;
            }
         }
         context->buffer_unmap(context, transfer);
         transfer = NULL;
      }
      if (failed)
         goto out;
   }

   {
      const uint32_t zero = 0;
      struct pipe_shader_buffer atomic_buffers[3] = {
         {
            .buffer = root,
            .buffer_size = root->width0,
         },
         {
            .buffer = sampler_table,
            .buffer_size = sampler_table->width0,
         },
         {
            .buffer = atomic_counter,
            .buffer_size = sizeof(zero),
         },
      };
      const struct pipe_grid_info atomic_grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .grid = {2, 1, 1},
      };

      context->buffer_subdata(context, atomic_counter, 0, 0, sizeof(zero),
                              &zero);
      context->bind_compute_state(context, atomic_compute_state);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0,
                                  ARRAY_SIZE(atomic_buffers), atomic_buffers,
                                  UINT32_C(1) << 2);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 3, 1, NULL, 0);
      context->launch_grid(context, &atomic_grid);
      context->flush(context, &fence, 0);
      if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
         fputs("SSBO atomic dispatch did not complete\n", stderr);
         failed = 1;
         goto out;
      }
      screen->fence_reference(screen, &fence, NULL);
   }
   {
      const uint32_t *counter = context->buffer_map(
         context, atomic_counter, 0, PIPE_MAP_READ,
         &(struct pipe_box){.width = sizeof(uint32_t), .height = 1, .depth = 1},
         &transfer);

      if (!counter || !transfer || *counter != 32) {
         fputs("SSBO atomic counter mismatched\n", stderr);
         failed = 1;
         goto out;
      }
      context->buffer_unmap(context, transfer);
      transfer = NULL;
   }

   {
      const uint32_t zero = 0;
      struct pipe_shader_buffer atomic_swap_buffers[4] = {
         {
            .buffer = root,
            .buffer_size = root->width0,
         },
         {
            .buffer = sampler_table,
            .buffer_size = sampler_table->width0,
         },
         {
            .buffer = atomic_counter,
            .buffer_size = sizeof(zero),
         },
         {
            .buffer = atomic_previous_values,
            .buffer_size = 32 * sizeof(uint32_t),
         },
      };
      const struct pipe_grid_info atomic_swap_grid = {
         .work_dim = 1,
         .block = {16, 1, 1},
         .grid = {2, 1, 1},
      };

      context->buffer_subdata(context, atomic_counter, 0, 0, sizeof(zero),
                              &zero);
      context->bind_compute_state(context, atomic_swap_compute_state);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0,
                                  ARRAY_SIZE(atomic_swap_buffers),
                                  atomic_swap_buffers,
                                  (UINT32_C(1) << 2) | (UINT32_C(1) << 3));
      context->launch_grid(context, &atomic_swap_grid);
      context->memory_barrier(context,
                              PIPE_BARRIER_SHADER_BUFFER | PIPE_BARRIER_MAPPED_BUFFER);
      context->flush(context, &fence, 0);
      if (!fence || !screen->fence_finish(screen, context, fence, UINT64_MAX)) {
         fputs("SSBO atomic exchange dispatch did not complete\n", stderr);
         failed = 1;
         goto out;
      }
      screen->fence_reference(screen, &fence, NULL);
   }
   {
      const uint32_t *counter = context->buffer_map(
         context, atomic_counter, 0, PIPE_MAP_READ,
         &(struct pipe_box){.width = sizeof(uint32_t), .height = 1, .depth = 1},
         &transfer);

      if (!counter || !transfer || *counter != 0x5a5a) {
         fputs("SSBO atomic exchange result mismatched\n", stderr);
         failed = 1;
         goto out;
      }
      context->buffer_unmap(context, transfer);
      transfer = NULL;
   }
   {
      const uint32_t *previous = context->buffer_map(
         context, atomic_previous_values, 0, PIPE_MAP_READ,
         &(struct pipe_box){.width = 32 * sizeof(uint32_t), .height = 1,
                            .depth = 1},
         &transfer);
      uint32_t zero_count = 0;

      if (!previous || !transfer) {
         fputs("SSBO atomic exchange values could not map\n", stderr);
         failed = 1;
         goto out;
      }
      for (uint32_t i = 0; i < 32; ++i) {
         if (previous[i] == 0)
            ++zero_count;
         else if (previous[i] != 0x5a5a) {
            fputs("SSBO atomic exchange returned an unexpected value\n", stderr);
            failed = 1;
            break;
         }
      }
      if (!failed && zero_count != 1) {
         fputs("SSBO atomic exchange did not serialize the initial value\n", stderr);
         failed = 1;
      }
      context->buffer_unmap(context, transfer);
      transfer = NULL;
   }

out:
   if (transfer)
      context->buffer_unmap(context, transfer);
   if (fence)
      screen->fence_reference(screen, &fence, NULL);
   if (context && (compute_state || atomic_compute_state || atomic_swap_compute_state)) {
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0,
                                  ARRAY_SIZE(shader_buffers), NULL, 0);
      context->bind_compute_state(context, NULL);
   }
   if (context && atomic_compute_state)
      context->delete_compute_state(context, atomic_compute_state);
   if (context && atomic_swap_compute_state)
      context->delete_compute_state(context, atomic_swap_compute_state);
   ralloc_free(atomic_swap_nir);
   if (context && compute_state) {
      context->delete_compute_state(context, compute_state);
   }
   ralloc_free(atomic_nir);
   ralloc_free(dynamic_nir);
   ralloc_free(nir);
   pipe_resource_reference(&atomic_counter, NULL);
   pipe_resource_reference(&atomic_previous_values, NULL);
   pipe_resource_reference(&rebound_output, NULL);
   pipe_resource_reference(&output, NULL);
   pipe_resource_reference(&input, NULL);
   pipe_resource_reference(&sampler_table, NULL);
   pipe_resource_reference(&root, NULL);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
