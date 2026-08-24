/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "AO46MetalAdapter.h"
#include "AO46MesaPolyGallium.h"

struct AO46MetalComputePipeline;
struct AO46MetalRenderPipeline;
struct AO46MesaComputePipeline;
struct AO46MesaRenderPipeline;
struct AO46MesaPolyKernelExecutor;
struct AO46MesaPolyTessellationPlan;
struct AO46MesaVertexAttribute;
struct nir_shader;
struct pipe_context;
struct pipe_fence_handle;
struct pipe_resource;
struct pipe_screen;
struct pipe_surface;

struct AO46MetalGalliumComputeBinding {
   struct pipe_resource *resource;
   size_t offset;
   uint32_t index;
   bool writable;
};

struct AO46MetalGalliumVertexBinding {
   struct pipe_resource *resource;
   size_t offset;
   uint32_t index;
};

/* A reflected Mesa NIR pointer buffer retained for one vertex-stage draw. */
struct AO46MetalGalliumStaticBufferBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t index;
};

/* Bounded triangle-list element binding retained by the submitted fence. */
struct AO46MetalGalliumIndexBufferBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t count;
   enum AO46MetalIndexFormat format;
   int32_t base_vertex;
   bool primitive_restart;
   uint32_t restart_index;
};

/* A bounded Gallium indirect-draw sequence retained by the submitted fence. */
struct AO46MetalGalliumIndirectDrawBinding {
   struct pipe_resource *resource;
   size_t offset;
   uint32_t draw_count;
   size_t stride;
   struct pipe_resource *count_resource;
   size_t count_offset;
   bool gpu_generated;
   uint32_t maximum_index_count;
};

/* One constant-offset Gallium UBO retained by the graphics submission fence. */
struct AO46MetalGalliumUniformBufferBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t binding;
};

/*
 * Creates the Mesa-facing device object over an already-owned Metal adapter.
 * The adapter must outlive the returned screen. This first slice supports
 * native PIPE_BUFFER resources plus bounded color textures; unsupported
 * Gallium state still fails closed at the relevant entry point.
 */
struct pipe_screen *AO46MetalGalliumScreenCreate(
   const struct AO46MetalAdapter *adapter);

/* Synchronizes only when the preceding Gallium work was not MTL4-ordered. */
bool AO46MetalGalliumContextPrepareForExternalMTL4Submission(
   struct pipe_context *context);

/*
 * Binds a Mesa-generated graphics pipeline for the bounded draw_vbo path.
 * The caller owns the pipeline and must clear this binding before destroying it.
 */
bool AO46MetalGalliumContextBindRenderPipeline(
   struct pipe_context *context,
   const struct AO46MetalRenderPipeline *pipeline);

/* Compiles an RGB32 view-dependent pipeline from live vertex/fragment state. */
bool AO46MetalGalliumContextCreateRenderPipelineWithCurrentRGB32SamplerViews(
   struct pipe_context *context, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct AO46MesaRenderPipeline *out_pipeline);

/* Binds or clears the bounded post-tessellation data for patch draw_vbo. */
bool AO46MetalGalliumContextBindPolyTessellationDraw(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw);

/* Binds or clears the Mesa TCS/prefix/tessellation sequence for patch draws. */
bool AO46MetalGalliumContextBindPolyTessellationSequence(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence);

/* Returns the shared CPU mapping for a live PIPE_BUFFER resource. */
bool AO46MetalGalliumResourceGetCPUMapping(struct pipe_resource *resource,
                                           void **out_mapping,
                                           size_t *out_length);
/* Returns the live buffer backing a Mesa-owned PIPE_BUFFER resource. */
bool AO46MetalGalliumResourceGetMetalBuffer(
   struct pipe_resource *resource, const struct AO46MetalBuffer **out_buffer);
/* Returns the live 2D Metal texture backing a Mesa-owned color resource. */
bool AO46MetalGalliumResourceGetMetalTexture(
   struct pipe_resource *resource, const struct AO46MetalTexture **out_texture);

/* Writes one GPU address into a live Mesa-owned pointer root. */
bool AO46MetalGalliumResourceWriteGPUAddressRoot(
   struct pipe_resource *root, size_t root_offset,
   struct pipe_resource *target, size_t target_offset);

/* Creates a level-zero, single-layer color surface for the bounded renderer. */
struct pipe_surface *AO46MetalGalliumSurfaceCreate(
   struct pipe_resource *texture);
void AO46MetalGalliumSurfaceDestroy(struct pipe_surface *surface);

/* Returns the staging layout required to transfer a texture region and buffer. */
bool AO46MetalGalliumTextureGetTransferLayout(
   struct pipe_resource *texture, uint32_t width, uint32_t height,
   size_t *out_bytes_per_row, size_t *out_size);

/* Uploads one aligned staging-buffer region into a bounded AO46 2D texture. */
bool AO46MetalGalliumTextureUpload(
   struct pipe_context *context, struct pipe_resource *destination,
   uint32_t destination_x, uint32_t destination_y, uint32_t width,
   uint32_t height, struct pipe_resource *source, size_t source_offset,
   size_t source_bytes_per_row, struct pipe_fence_handle **out_fence);

/*
 * Dispatches a Mesa-produced MSL pipeline through the compute-only context.
 * Bound pipe resources stay retained by the returned fence until Metal has
 * finished consuming the command buffer.
 */
bool AO46MetalGalliumComputeDispatch(
   struct pipe_context *context,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalGalliumComputeBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct pipe_fence_handle **out_fence);

/* Dispatches GPU-resident three-word Gallium indirect workgroup counts. */
bool AO46MetalGalliumComputeDispatchIndirect(
   struct pipe_context *context,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalGalliumComputeBinding *bindings, size_t binding_count,
   struct pipe_resource *indirect_resource, size_t indirect_offset,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct pipe_fence_handle **out_fence);

/*
 * Submits the first bounded graphics slice: a Mesa-generated three-vertex
 * draw into one AO46 color surface. General Gallium graphics state is not
 * exposed through this bootstrap helper.
 */
bool AO46MetalGalliumRenderTriangle(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

bool AO46MetalGalliumRenderTriangleWithUniformBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/* Draws a direct triangle with reflected vertex-stage MTLBuffer roots. */
bool AO46MetalGalliumRenderTriangleWithStaticVertexBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/* Draws a validated uint16/uint32 triangle list through a retained EBO. */
bool AO46MetalGalliumRenderIndexedTriangles(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

bool AO46MetalGalliumRenderIndexedTrianglesWithUniformBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/*
 * Binds the exact reflected vertex-stage pointer ranges for a Mesa-generated
 * indexed draw. This is separate from generic Gallium shader-buffer state.
 */
bool AO46MetalGalliumRenderIndexedTrianglesWithStaticVertexBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);
