/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

struct AO46MesaComputePipeline;
struct AO46MesaPolyKernelExecutor;
struct AO46MesaPolyTessellationPlan;
struct pipe_resource;

/* Mesa poly's bounded post-tessellation draw data for PIPE_PRIM_PATCHES. */
struct AO46MetalGalliumPolyTessellationDraw {
   struct pipe_resource *parameter_resource;
   size_t parameter_offset;
   size_t parameter_size;
   struct pipe_resource *index_resource;
   size_t index_offset;
   size_t index_size;
   struct pipe_resource *indirect_resource;
   size_t indirect_offset;
   size_t indirect_size;
   uint32_t maximum_index_count;
   uint8_t input_patch_size;
   uint32_t input_vertex_count;
};

/*
 * Mesa's pre-TES dispatch sequence for one retained poly package. The caller
 * owns the pipeline, executor, and plan and must clear this binding before
 * destroying any of them. Root, sampler, and parameter ranges intentionally
 * share the draw's retained parameter resource in this first path.
 */
struct AO46MetalGalliumPolyTessellationSequence {
   const struct AO46MesaComputePipeline *vs_pipeline;
   const struct AO46MesaComputePipeline *tcs_pipeline;
   const struct AO46MesaPolyKernelExecutor *kernel_executor;
   const struct AO46MesaPolyTessellationPlan *plan;
   /* Separate roots make the count and emit modes immutable on the GPU queue. */
   size_t count_root_offset;
   size_t root_offset;
   size_t root_size;
   size_t sampler_table_offset;
   size_t sampler_table_size;
   size_t vertex_parameter_offset;
   size_t vertex_parameter_size;
   size_t vertex_input_root_offset;
   size_t vertex_input_root_size;
   uint32_t vertex_buffer_mask;
};
