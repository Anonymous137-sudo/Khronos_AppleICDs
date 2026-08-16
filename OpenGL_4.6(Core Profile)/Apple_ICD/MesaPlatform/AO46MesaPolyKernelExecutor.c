/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyKernelExecutor.h"

#include "AO46MetalGalliumScreen.h"

static bool
ao46_mesa_poly_kernel_executor_is_empty(
   const struct AO46MesaPolyKernelExecutor *executor)
{
   if (!executor || executor->adapter)
      return false;

   for (unsigned i = 0; i < AO46_MESA_POLY_KERNEL_COUNT; ++i) {
      if (executor->pipelines[i].adapter || executor->pipelines[i].native_pipeline ||
          executor->sources[i].msl_source || executor->sources[i].entrypoint ||
          executor->sources[i].workgroup_size[0] ||
          executor->sources[i].workgroup_size[1] ||
          executor->sources[i].workgroup_size[2] ||
          executor->sources[i].requires_gpu_address_root)
         return false;
   }

   return true;
}

static bool
ao46_mesa_poly_kernel_executor_is_current(
   const struct AO46MesaPolyKernelExecutor *executor)
{
   if (!executor || !AO46MetalAdapterSupportsGPUAddress(executor->adapter))
      return false;

   for (unsigned i = 0; i < AO46_MESA_POLY_KERNEL_COUNT; ++i) {
      if (!executor->sources[i].msl_source || !executor->sources[i].entrypoint ||
          !executor->sources[i].requires_gpu_address_root ||
          executor->sources[i].workgroup_size[0] == 0 ||
          executor->sources[i].workgroup_size[1] == 0 ||
          executor->sources[i].workgroup_size[2] == 0 ||
          executor->pipelines[i].adapter != executor->adapter ||
          !executor->pipelines[i].native_pipeline)
         return false;
   }

   return true;
}

bool
AO46MesaPolyKernelExecutorCreate(
   const struct AO46MetalAdapter *adapter,
   struct AO46MesaPolyKernelExecutor *out_executor)
{
   if (!AO46MetalAdapterSupportsGPUAddress(adapter) || !out_executor ||
       !ao46_mesa_poly_kernel_executor_is_empty(out_executor))
      return false;

   out_executor->adapter = adapter;
   for (unsigned i = 0; i < AO46_MESA_POLY_KERNEL_COUNT; ++i) {
      if (!AO46MesaPolyKernelSourceGet((enum AO46MesaPolyKernel)i,
                                       &out_executor->sources[i]) ||
          !AO46MetalComputePipelineCreate(
             adapter, out_executor->sources[i].msl_source,
             out_executor->sources[i].entrypoint, &out_executor->pipelines[i])) {
         AO46MesaPolyKernelExecutorDestroy(out_executor);
         return false;
      }
   }

   return true;
}

void
AO46MesaPolyKernelExecutorDestroy(struct AO46MesaPolyKernelExecutor *executor)
{
   if (!executor)
      return;

   for (unsigned i = 0; i < AO46_MESA_POLY_KERNEL_COUNT; ++i)
      AO46MetalComputePipelineDestroy(&executor->pipelines[i]);
   *executor = (struct AO46MesaPolyKernelExecutor){0};
}

bool
AO46MesaPolyKernelExecutorSubmit(
   const struct AO46MesaPolyKernelExecutor *executor,
   enum AO46MesaPolyKernel kernel, const struct AO46MetalBuffer *root,
   const struct AO46MetalBuffer *sampler_table, uint32_t grid_width,
   uint32_t grid_height, uint32_t grid_depth,
   struct AO46MetalSubmission *out_submission)
{
   struct AO46MetalBufferBinding bindings[2];
   const struct AO46MesaPolyKernelSource *source;

   if (!ao46_mesa_poly_kernel_executor_is_current(executor) ||
       kernel >= AO46_MESA_POLY_KERNEL_COUNT || !AO46MetalBufferIsCurrent(root) ||
       !AO46MetalBufferIsCurrent(sampler_table) ||
       root->adapter != executor->adapter ||
       sampler_table->adapter != executor->adapter || grid_width == 0 ||
       grid_height == 0 || grid_depth == 0)
      return false;

   source = &executor->sources[kernel];
   bindings[0] = (struct AO46MetalBufferBinding){
      .buffer = root,
      .size = root->length,
      .index = 0,
      .writable = true,
   };
   bindings[1] = (struct AO46MetalBufferBinding){
      .buffer = sampler_table,
      .size = sampler_table->length,
      .index = 1,
      .writable = true,
   };

   return AO46MetalComputeSubmit(
      executor->adapter, &executor->pipelines[kernel], bindings, 2, grid_width,
      grid_height, grid_depth, source->workgroup_size[0],
      source->workgroup_size[1], source->workgroup_size[2], out_submission);
}

bool
AO46MesaPolyKernelExecutorSubmitGallium(
   const struct AO46MesaPolyKernelExecutor *executor,
   enum AO46MesaPolyKernel kernel, struct pipe_context *context,
   struct pipe_resource *root, size_t root_offset,
   struct pipe_resource *sampler_table, size_t sampler_table_offset,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence)
{
   const struct AO46MesaPolyKernelSource *source;
   const struct AO46MetalGalliumComputeBinding bindings[] = {
      {
         .resource = root,
         .offset = root_offset,
         .index = 0,
      },
      {
         .resource = sampler_table,
         .offset = sampler_table_offset,
         .index = 1,
      },
   };

   if (!ao46_mesa_poly_kernel_executor_is_current(executor) ||
       kernel >= AO46_MESA_POLY_KERNEL_COUNT || !context || !root ||
       !sampler_table || !out_fence || grid_width == 0 || grid_height == 0 ||
       grid_depth == 0)
      return false;

   source = &executor->sources[kernel];
   return AO46MetalGalliumComputeDispatch(
      context, &executor->pipelines[kernel], bindings,
      sizeof(bindings) / sizeof(bindings[0]), grid_width, grid_height,
      grid_depth, source->workgroup_size[0], source->workgroup_size[1],
      source->workgroup_size[2], out_fence);
}
