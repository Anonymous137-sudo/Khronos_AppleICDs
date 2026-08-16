/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "AO46MesaPolyKernelCatalog.h"
#include "AO46MetalAdapter.h"

/* Compiled Mesa libkk programs used by the poly tessellation sequence. */
struct AO46MesaPolyKernelExecutor {
   const struct AO46MetalAdapter *adapter;
   struct AO46MetalComputePipeline pipelines[AO46_MESA_POLY_KERNEL_COUNT];
   struct AO46MesaPolyKernelSource sources[AO46_MESA_POLY_KERNEL_COUNT];
};

struct pipe_context;
struct pipe_fence_handle;
struct pipe_resource;

/* Compiles Mesa's immutable libkk MSL once for a GPU-address-capable adapter. */
bool AO46MesaPolyKernelExecutorCreate(
   const struct AO46MetalAdapter *adapter,
   struct AO46MesaPolyKernelExecutor *out_executor);
void AO46MesaPolyKernelExecutorDestroy(
   struct AO46MesaPolyKernelExecutor *executor);

/*
 * Submits a Mesa-generated poly kernel. The caller owns its packed libkk
 * argument block at root buffer index 0 and supplies the Mesa sampler table
 * required by the fixed generated-MSL ABI at index 1.
 */
bool AO46MesaPolyKernelExecutorSubmit(
   const struct AO46MesaPolyKernelExecutor *executor,
   enum AO46MesaPolyKernel kernel, const struct AO46MetalBuffer *root,
   const struct AO46MetalBuffer *sampler_table, uint32_t grid_width,
   uint32_t grid_height, uint32_t grid_depth,
   struct AO46MetalSubmission *out_submission);

/*
 * Schedules one immutable Mesa libkk stage through the Gallium resource and
 * fence model. The caller provides the standard root/sampler-table ABI at
 * Metal buffer slots zero and one; both resources remain retained by the
 * returned fence until the Metal submission completes.
 */
bool AO46MesaPolyKernelExecutorSubmitGallium(
   const struct AO46MesaPolyKernelExecutor *executor,
   enum AO46MesaPolyKernel kernel, struct pipe_context *context,
   struct pipe_resource *root, size_t root_offset,
   struct pipe_resource *sampler_table, size_t sampler_table_offset,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence);
