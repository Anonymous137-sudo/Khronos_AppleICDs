/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyKernelCatalog.h"
#include "AO46MesaPolyKernelExecutor.h"
#include "AO46MetalAdapter.h"

#include "libkk_shaders.h"
#include "poly/geometry.h"
#include "poly/tessellator.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Executes Mesa's generated prefix-sum and minimum-triangle tessellation chain. */
static bool
ao46_mesa_poly_tessellation_chain_smoke(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MesaPolyKernelExecutor *executor)
{
   const uint32_t input_counts[] = {3};
   const float tess_factors[] = {1.0f, 1.0f, 1.0f, 0.0f, 1.0f};
   struct AO46MetalBuffer root = {0};
   struct AO46MetalBuffer sampler_table = {0};
   struct AO46MetalBuffer params = {0};
   struct AO46MetalBuffer heap = {0};
   struct AO46MetalBuffer heap_data = {0};
   struct AO46MetalBuffer counts = {0};
   struct AO46MetalBuffer out_draws = {0};
   struct AO46MetalBuffer factors = {0};
   struct AO46MetalBuffer coord_allocs = {0};
   struct AO46MetalSubmission submission = {0};
   uint64_t params_address;
   uint64_t heap_address;
   uint64_t heap_data_address;
   uint64_t counts_address;
   uint64_t out_draws_address;
   uint64_t factors_address;
   uint64_t coord_allocs_address;
   bool passed = false;

   if (!AO46MetalAdapterSupportsGPUAddress(adapter)) {
      fputs("Mesa poly tessellation smoke skipped: public MTLBuffer GPU addresses unavailable\n",
            stdout);
      return true;
   }

   if (!executor || executor->adapter != adapter ||
       !AO46MetalBufferCreate(adapter, sizeof(struct libkk_tess_tri_args), &root) ||
       !AO46MetalBufferCreate(adapter, 16, &sampler_table) ||
       !AO46MetalBufferCreate(adapter, sizeof(struct poly_tess_params), &params) ||
       !AO46MetalBufferCreate(adapter, sizeof(struct poly_heap), &heap) ||
       !AO46MetalBufferCreate(adapter, 64, &heap_data) ||
       !AO46MetalBufferCreate(adapter, sizeof(input_counts), &counts) ||
       !AO46MetalBufferCreate(adapter, 5 * sizeof(uint32_t), &out_draws) ||
       !AO46MetalBufferCreate(adapter, sizeof(tess_factors), &factors) ||
       !AO46MetalBufferCreate(adapter, sizeof(uint32_t), &coord_allocs) ||
       !AO46MetalBufferGetGPUAddress(&params, &params_address) ||
       !AO46MetalBufferGetGPUAddress(&heap, &heap_address) ||
       !AO46MetalBufferGetGPUAddress(&heap_data, &heap_data_address) ||
       !AO46MetalBufferGetGPUAddress(&counts, &counts_address) ||
       !AO46MetalBufferGetGPUAddress(&out_draws, &out_draws_address) ||
       !AO46MetalBufferGetGPUAddress(&factors, &factors_address) ||
       !AO46MetalBufferGetGPUAddress(&coord_allocs, &coord_allocs_address))
      goto cleanup;

   memset(params.cpu_mapping, 0, params.length);
   memset(heap.cpu_mapping, 0, heap.length);
   memset(heap_data.cpu_mapping, 0, heap_data.length);
   memcpy(counts.cpu_mapping, input_counts, sizeof(input_counts));
   memset(out_draws.cpu_mapping, 0, out_draws.length);
   memcpy(factors.cpu_mapping, tess_factors, sizeof(tess_factors));
   memset(coord_allocs.cpu_mapping, 0, coord_allocs.length);

   if (!AO46MetalBufferWriteGPUAddressRoot(&root, 0, &params, 0))
      goto cleanup;
   *(struct poly_heap *)heap.cpu_mapping = (struct poly_heap){
      .base = heap_data_address,
      .bottom = 0,
      .size = heap_data.length,
   };
   *(struct poly_tess_params *)params.cpu_mapping = (struct poly_tess_params){
      .heap = heap_address,
      .counts = counts_address,
      .out_draws = out_draws_address,
      .tcs_buffer = factors_address,
      .coord_allocs = coord_allocs_address,
      .tcs_stride_el = sizeof(tess_factors) / sizeof(tess_factors[0]),
      .nr_patches = sizeof(input_counts) / sizeof(input_counts[0]),
      .partitioning = POLY_TESS_PARTITIONING_INTEGER,
   };

   if (((const struct poly_tess_params *)params.cpu_mapping)->counts == 0 ||
       ((const struct poly_tess_params *)params.cpu_mapping)->out_draws == 0)
      goto cleanup;

   if (!AO46MesaPolyKernelExecutorSubmit(
          executor, AO46_MESA_POLY_KERNEL_PREFIX_SUM, &root, &sampler_table,
          executor->sources[AO46_MESA_POLY_KERNEL_PREFIX_SUM].workgroup_size[0],
          1, 1, &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto cleanup;

   AO46MetalSubmissionDestroy(&submission);
   *(uint32_t *)((uint8_t *)root.cpu_mapping +
                 offsetof(struct libkk_tess_tri_args, tess_mode)) =
      POLY_TESS_MODE_WITH_COUNTS;

   if (!AO46MesaPolyKernelExecutorSubmit(
          executor, AO46_MESA_POLY_KERNEL_TRIANGLE, &root, &sampler_table, 1,
          1, 1, &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto cleanup;

   const struct poly_tess_params *result_params = params.cpu_mapping;
   const struct poly_heap *result_heap = heap.cpu_mapping;
   const uint32_t *result_counts = counts.cpu_mapping;
   const uint32_t *result_draws = out_draws.cpu_mapping;
   const uint32_t *result_coord_allocs = coord_allocs.cpu_mapping;
   const struct poly_tess_point *result_points =
      (const struct poly_tess_point *)((const uint8_t *)heap_data.cpu_mapping + 16);
   const uint32_t *result_indices = heap_data.cpu_mapping;
   passed = result_counts[0] == 3 && result_heap->bottom == 48 &&
            result_params->index_buffer == heap_data_address &&
            result_draws[0] == 3 && result_draws[1] == 1 &&
            result_draws[2] == 0 && result_draws[3] == 0 &&
            result_draws[4] == 0 && result_coord_allocs[0] == 2 &&
            result_indices[0] == 0 && result_indices[1] == 1 &&
            result_indices[2] == 2 && result_points[0].u == 0 &&
            result_points[0].v == UINT32_C(0x00010000) &&
            result_points[1].u == 0 && result_points[1].v == 0 &&
            result_points[2].u == UINT32_C(0x00010000) &&
            result_points[2].v == 0;

cleanup:
   AO46MetalSubmissionDestroy(&submission);
   AO46MetalBufferDestroy(&coord_allocs);
   AO46MetalBufferDestroy(&factors);
   AO46MetalBufferDestroy(&out_draws);
   AO46MetalBufferDestroy(&counts);
   AO46MetalBufferDestroy(&heap_data);
   AO46MetalBufferDestroy(&heap);
   AO46MetalBufferDestroy(&params);
   AO46MetalBufferDestroy(&sampler_table);
   AO46MetalBufferDestroy(&root);
   return passed;
}

int
main(void)
{
   const enum AO46MesaPolyKernel kernels[] = {
      AO46_MESA_POLY_KERNEL_PREFIX_SUM,
      AO46_MESA_POLY_KERNEL_TRIANGLE,
      AO46_MESA_POLY_KERNEL_QUAD,
      AO46_MESA_POLY_KERNEL_ISOLINE,
   };
   struct AO46MetalAdapter adapter = {0};
   struct AO46MesaPolyKernelExecutor executor = {0};
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("Mesa poly catalog smoke could not create Metal adapter\n", stderr);
      return 1;
   }

   if (!AO46MesaPolyKernelExecutorCreate(&adapter, &executor)) {
      fputs("Mesa poly kernel executor could not compile generated MSL\n", stderr);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   for (size_t i = 0; i < sizeof(kernels) / sizeof(kernels[0]); ++i) {
      const struct AO46MesaPolyKernelSource *source = &executor.sources[kernels[i]];
      const struct AO46MetalComputePipeline *pipeline =
         &executor.pipelines[kernels[i]];

      if (!source->msl_source || !source->entrypoint ||
          !source->requires_gpu_address_root || source->workgroup_size[0] == 0 ||
          !strstr(source->msl_source, "main_entrypoint") ||
          !pipeline->native_pipeline || pipeline->thread_execution_width == 0 ||
          pipeline->max_threads_per_threadgroup < source->workgroup_size[0]) {
         fprintf(stderr, "Mesa poly kernel %zu did not compile as MSL\n", i);
         failed = 1;
      }

      if (failed)
         break;
   }

   if (!failed && !ao46_mesa_poly_tessellation_chain_smoke(&adapter, &executor)) {
      fputs("Mesa poly tessellation-chain GPU-address execution failed\n", stderr);
      failed = 1;
   }

   AO46MesaPolyKernelExecutorDestroy(&executor);
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
