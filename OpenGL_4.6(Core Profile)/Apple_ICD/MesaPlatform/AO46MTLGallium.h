/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "AO46MetalAdapter.h"
#include "AO46MesaPolyGallium.h"

struct AO46MetalRenderPipeline;
struct pipe_context;
struct pipe_resource;
struct pipe_screen;

/*
 * Creates the Mesa-facing Gallium screen over an adapter-owned Metal device
 * and queue. The adapter must outlive every screen and context it creates.
 */
struct pipe_screen *AO46MTLGalliumScreenCreate(
   const struct AO46MetalAdapter *adapter);

/* Binds the Mesa-generated TES render pipeline used by the poly patch path. */
bool AO46MTLGalliumContextBindRenderPipeline(
   struct pipe_context *context,
   const struct AO46MetalRenderPipeline *pipeline);

bool AO46MTLGalliumContextBindPolyTessellationDraw(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw);
bool AO46MTLGalliumContextBindPolyTessellationSequence(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence);

/* Test and package construction helpers for active PIPE_BUFFER resources. */
bool AO46MTLGalliumResourceGetCPUMapping(struct pipe_resource *resource,
                                         void **out_mapping,
                                         size_t *out_length);
bool AO46MTLGalliumResourceGetGPUAddress(struct pipe_resource *resource,
                                        uint64_t *out_address);
bool AO46MTLGalliumResourceWriteGPUAddressRoot(
   struct pipe_resource *root, size_t root_offset,
   struct pipe_resource *target, size_t target_offset);
