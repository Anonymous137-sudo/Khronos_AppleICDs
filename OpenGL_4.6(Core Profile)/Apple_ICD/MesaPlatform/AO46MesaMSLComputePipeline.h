/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "AO46MetalAdapter.h"

struct nir_shader;
struct pipe_context;
struct pipe_fence_handle;
struct pipe_resource;

/* The interface reconstructed from Mesa NIR and the compiled Metal pipeline. */
struct AO46MesaComputeReflection {
   uint32_t local_size[3];
   uint32_t required_buffer_mask;
   uint32_t thread_execution_width;
   uint32_t max_threads_per_threadgroup;
};

struct AO46MesaComputePipeline {
   struct AO46MetalComputePipeline metal_pipeline;
   char *msl_source;
   char *entrypoint;
   struct AO46MesaComputeReflection reflection;
};

/*
 * Lowers the caller-owned compute NIR through Mesa KosmicKrisp and compiles
 * the resulting MSL. The NIR is consumed by the standard MSL lowering pass.
 */
bool AO46MesaComputePipelineCreate(const struct AO46MetalAdapter *adapter,
                                   struct nir_shader *nir,
                                   struct AO46MesaComputePipeline *out_pipeline);

/*
 * As above, with immutable direct MTLBuffer bindings at NIR buffer-pointer
 * indices 2..15. Indices 0 and 1 remain the root-buffer and sampler-table ABI.
 */
bool AO46MesaComputePipelineCreateWithStaticBuffers(
   const struct AO46MetalAdapter *adapter, struct nir_shader *nir,
   uint16_t static_buffer_mask,
   struct AO46MesaComputePipeline *out_pipeline);
void AO46MesaComputePipelineDestroy(struct AO46MesaComputePipeline *pipeline);

bool AO46MesaComputePipelineDispatch(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, uint32_t resource_count, uint32_t grid_width,
   uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence);

/*
 * As above, while preserving Gallium's pipe_shader_buffer writable contract.
 * A NULL writable array remains conservatively read/write for legacy callers.
 */
bool AO46MesaComputePipelineDispatchWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence);

/*
 * Uses a PIPE_BUFFER containing uint32_t workgroup_count_x/y/z. It preserves
 * Mesa's generated MSL and resource bindings while keeping dispatch arguments
 * GPU-resident for the Gallium indirect-compute path.
 */
bool AO46MesaComputePipelineDispatchIndirectWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   struct pipe_resource *indirect_resource, size_t indirect_offset,
   struct pipe_fence_handle **out_fence);
