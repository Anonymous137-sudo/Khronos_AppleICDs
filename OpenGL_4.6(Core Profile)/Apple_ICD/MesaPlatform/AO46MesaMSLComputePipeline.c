/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLComputePipeline.h"

#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir.h"
#include "nir_intrinsics.h"
#include "util/ralloc.h"

#include <stdlib.h>
#include <string.h>

static bool
ao46_mesa_compute_pipeline_is_empty(const struct AO46MesaComputePipeline *pipeline)
{
   return pipeline && !pipeline->metal_pipeline.adapter &&
          !pipeline->metal_pipeline.native_pipeline &&
          !pipeline->metal_pipeline.native_classic_pipeline &&
          !pipeline->msl_source &&
          !pipeline->entrypoint &&
          pipeline->reflection.local_size[0] == 0 &&
          pipeline->reflection.local_size[1] == 0 &&
          pipeline->reflection.local_size[2] == 0 &&
          pipeline->reflection.required_buffer_mask == 0 &&
          pipeline->reflection.thread_execution_width == 0 &&
          pipeline->reflection.max_threads_per_threadgroup == 0;
}

/* Reflect every direct KK buffer root before NIR-to-MSL fixes its ABI. */
static bool
ao46_mesa_compute_collect_static_buffer_bindings(const struct nir_shader *nir,
                                                 uint16_t *out_mask)
{
   uint16_t mask = 0;

   if (!nir || !out_mask)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_intrinsic_instr *intrinsic;
            unsigned binding;

            if (instr->type != nir_instr_type_intrinsic)
               continue;

            intrinsic = nir_instr_as_intrinsic(instr);
            if (intrinsic->intrinsic != nir_intrinsic_load_buffer_ptr_kk)
               continue;

            binding = nir_intrinsic_binding(intrinsic);
            if (binding == 0)
               continue;
            if (binding < 2 ||
                binding >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS)
               return false;

            mask |= UINT16_C(1) << binding;
         }
      }
   }

   *out_mask = mask;
   return true;
}

bool
AO46MesaComputePipelineCreate(const struct AO46MetalAdapter *adapter,
                              struct nir_shader *nir,
                              struct AO46MesaComputePipeline *out_pipeline)
{
   uint16_t static_buffer_mask;

   if (!ao46_mesa_compute_collect_static_buffer_bindings(nir,
                                                          &static_buffer_mask))
      return false;

   return AO46MesaComputePipelineCreateWithStaticBuffers(
      adapter, nir, static_buffer_mask, out_pipeline);
}

bool
AO46MesaComputePipelineCreateWithStaticBuffers(
   const struct AO46MetalAdapter *adapter, struct nir_shader *nir,
   uint16_t static_buffer_mask,
   struct AO46MesaComputePipeline *out_pipeline)
{
   struct nir_to_msl_options options = {0};
   nir_function_impl *entrypoint;
   void *msl_context = NULL;
   char *msl = NULL;
   char *source = NULL;
   char *entrypoint_name = NULL;
   bool created = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !nir ||
       nir->info.stage != MESA_SHADER_COMPUTE || !out_pipeline ||
       !ao46_mesa_compute_pipeline_is_empty(out_pipeline) ||
       nir->info.workgroup_size[0] == 0 || nir->info.workgroup_size[1] == 0 ||
       nir->info.workgroup_size[2] == 0 || (static_buffer_mask & UINT16_C(0x0003)))
      return false;

   /* These are Mesa's standard KosmicKrisp preprocessing and SSA-lowering passes. */
   msl_preprocess_nir(nir);
   /* Mesa reports whether this optimization changed NIR, not success/failure. */
   (void)msl_optimize_nir(nir);

   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
   msl_context = ralloc_context(NULL);
   if (!msl_context)
      return false;

   options.mem_ctx = msl_context;
   options.static_buffer_mask = static_buffer_mask;
   msl = nir_to_msl(nir, &options);
   entrypoint = nir_shader_get_entrypoint(nir);
   if (!msl || !entrypoint || !entrypoint->function ||
       !entrypoint->function->name)
      goto out;

   source = strdup(msl);
   entrypoint_name = strdup(entrypoint->function->name);
   if (!source || !entrypoint_name ||
       !AO46MetalComputePipelineCreate(adapter, source, entrypoint_name,
                                       &out_pipeline->metal_pipeline))
      goto out;

   out_pipeline->msl_source = source;
   out_pipeline->entrypoint = entrypoint_name;
   out_pipeline->reflection = (struct AO46MesaComputeReflection){
      .local_size = {
         nir->info.workgroup_size[0],
         nir->info.workgroup_size[1],
         nir->info.workgroup_size[2],
      },
      /* KosmicKrisp emits the root and sampler-table ABI plus direct buffers. */
      .required_buffer_mask = (1u << 0) | (1u << 1) | static_buffer_mask,
      .thread_execution_width = out_pipeline->metal_pipeline.thread_execution_width,
      .max_threads_per_threadgroup =
         out_pipeline->metal_pipeline.max_threads_per_threadgroup,
   };
   source = NULL;
   entrypoint_name = NULL;
   created = true;

out:
   free(source);
   free(entrypoint_name);
   ralloc_free(msl_context);
   return created;
}

void
AO46MesaComputePipelineDestroy(struct AO46MesaComputePipeline *pipeline)
{
   if (!pipeline)
      return;

   AO46MetalComputePipelineDestroy(&pipeline->metal_pipeline);
   free(pipeline->msl_source);
   free(pipeline->entrypoint);
   *pipeline = (struct AO46MesaComputePipeline){0};
}

bool
AO46MesaComputePipelineDispatch(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, uint32_t resource_count, uint32_t grid_width,
   uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence)
{
   return AO46MesaComputePipelineDispatchWithAccess(
      pipeline, context, resources, offsets, indices, NULL, resource_count,
      grid_width, grid_height, grid_depth, out_fence);
}

bool
AO46MesaComputePipelineDispatchWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumComputeBinding *bindings;
   bool submitted;

   if (!pipeline || !pipeline->metal_pipeline.native_pipeline || !context ||
       !resources || !offsets || !indices || resource_count == 0 ||
       resource_count > 32 || grid_width == 0 || grid_height == 0 ||
       grid_depth == 0 || !out_fence)
      return false;

   bindings = calloc(resource_count, sizeof(*bindings));
   if (!bindings)
      return false;

   for (uint32_t i = 0; i < resource_count; ++i) {
      bindings[i] = (struct AO46MetalGalliumComputeBinding){
         .resource = resources[i],
         .offset = offsets[i],
         .index = indices[i],
         /* Keep older direct callers conservative until they opt in. */
         .writable = writable ? writable[i] : true,
      };
   }

   submitted = AO46MetalGalliumComputeDispatch(
      context, &pipeline->metal_pipeline, bindings, resource_count, grid_width,
      grid_height, grid_depth, pipeline->reflection.local_size[0],
      pipeline->reflection.local_size[1], pipeline->reflection.local_size[2],
      out_fence);
   free(bindings);
   return submitted;
}

bool
AO46MesaComputePipelineDispatchIndirectWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   struct pipe_resource *indirect_resource, size_t indirect_offset,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumComputeBinding *bindings;
   bool submitted;

   if (!pipeline || !pipeline->metal_pipeline.native_classic_pipeline ||
       !context || !resources || !offsets || !indices || resource_count == 0 ||
       resource_count > 32 || !indirect_resource || !out_fence)
      return false;

   bindings = calloc(resource_count, sizeof(*bindings));
   if (!bindings)
      return false;

   for (uint32_t i = 0; i < resource_count; ++i) {
      bindings[i] = (struct AO46MetalGalliumComputeBinding){
         .resource = resources[i],
         .offset = offsets[i],
         .index = indices[i],
         .writable = writable ? writable[i] : true,
      };
   }

   submitted = AO46MetalGalliumComputeDispatchIndirect(
      context, &pipeline->metal_pipeline, bindings, resource_count,
      indirect_resource, indirect_offset, pipeline->reflection.local_size[0],
      pipeline->reflection.local_size[1], pipeline->reflection.local_size[2],
      out_fence);
   free(bindings);
   return submitted;
}
