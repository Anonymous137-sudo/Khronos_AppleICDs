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
struct pipe_sampler_view;
struct pipe_surface;

/* A restricted Mesa vertex-input declaration for the bootstrap renderer. */
struct AO46MesaVertexAttribute {
   uint32_t location;
   uint32_t buffer_index;
   uint32_t offset;
   uint32_t stride;
   uint32_t instance_divisor;
   enum AO46MetalVertexFormat format;
};

struct AO46MesaVertexBinding {
   struct pipe_resource *resource;
   size_t offset;
   uint32_t index;
};

/* Bounded triangle-list element binding for a Mesa-generated draw. */
struct AO46MesaIndexBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t count;
   enum AO46MetalIndexFormat format;
   int32_t base_vertex;
   bool primitive_restart;
   uint32_t restart_index;
};

/* One constant-offset UBO binding for a Mesa-generated graphics draw. */
struct AO46MesaUniformBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t binding;
};

/* One direct MTLBuffer range required by a Mesa-lowered graphics stage. */
struct AO46MesaStaticBufferRequirement {
   uint32_t binding;
   size_t minimum_size;
};

/* One caller-owned vertex-stage direct-MTLBuffer range for a graphics draw. */
struct AO46MesaStaticBufferBinding {
   struct pipe_resource *resource;
   size_t offset;
   size_t size;
   uint32_t binding;
};

/* Mesa-derived metadata retained beside each emitted graphics entry point. */
struct AO46MesaGraphicsStageReflection {
   uint64_t inputs_read;
   uint64_t outputs_written;
   uint64_t static_texture_mask;
   uint64_t static_sampler_mask;
   uint16_t static_buffer_mask;
   size_t static_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint16_t uniform_mask;
   size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS];
};

struct AO46MesaRenderPipeline {
   struct AO46MetalRenderPipeline metal_pipeline;
   char *vertex_msl_source;
   char *vertex_entrypoint;
   char *fragment_msl_source;
   char *fragment_entrypoint;
   struct AO46MesaGraphicsStageReflection vertex_reflection;
   struct AO46MesaGraphicsStageReflection fragment_reflection;
   uint32_t vertex_attribute_count;
   struct AO46MesaVertexAttribute
      vertex_attributes[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
};

/*
 * Lowers caller-owned vertex and fragment NIR with Mesa KosmicKrisp, retains
 * their MSL/reflection, and creates a format-specific Metal render pipeline.
 */
bool AO46MesaRenderPipelineCreate(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count,
   struct AO46MesaRenderPipeline *out_pipeline);

/* Adds bounded direct-MTLBuffer bindings for Mesa NIR pointer intrinsics. */
bool AO46MesaRenderPipelineCreateWithStaticBuffers(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t vertex_static_buffer_mask,
   uint16_t fragment_static_buffer_mask,
   struct AO46MesaRenderPipeline *out_pipeline);

/*
 * Creates a pipeline with direct fragment-buffer requirements. Every set bit
 * needs exactly one requirement, allowing Gallium sampler views to enforce
 * the original Mesa texel range at Metal submission time.
 */
bool AO46MesaRenderPipelineCreateWithStaticBufferRequirements(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t fragment_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *fragment_requirements,
   size_t fragment_requirement_count,
   struct AO46MesaRenderPipeline *out_pipeline);

/* The live sampler-view range is part of each RGB32 NIR pipeline variant. */
bool AO46MesaRenderPipelineCreateWithRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *fragment_views,
   uint16_t rgb32_view_mask, struct AO46MesaRenderPipeline *out_pipeline);

/* Derives the RGB32 view mask from the fragment NIR before lowering it. */
bool AO46MesaRenderPipelineCreateWithDetectedRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *fragment_views,
   struct AO46MesaRenderPipeline *out_pipeline);

/*
 * Stage-aware RGB32 path. Both Mesa graphics stages reuse their live Gallium
 * PIPE_BUFFER sampler views as direct MTLBuffer roots after NIR lowering.
 */
bool AO46MesaRenderPipelineCreateWithStageRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *vertex_views,
   uint16_t vertex_rgb32_view_mask,
   struct pipe_sampler_view *const *fragment_views,
   uint16_t fragment_rgb32_view_mask,
   struct AO46MesaRenderPipeline *out_pipeline);

bool AO46MesaRenderPipelineCreateWithDetectedStageRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *vertex_views,
   struct pipe_sampler_view *const *fragment_views,
   struct AO46MesaRenderPipeline *out_pipeline);

/*
 * Stage-aware variant for Mesa-generated pointer roots in the vertex and
 * fragment stages. Slots zero and one remain reserved by the graphics ABI.
 */
bool AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t vertex_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *vertex_requirements,
   size_t vertex_requirement_count, uint16_t fragment_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *fragment_requirements,
   size_t fragment_requirement_count,
   struct AO46MesaRenderPipeline *out_pipeline);
void AO46MesaRenderPipelineDestroy(struct AO46MesaRenderPipeline *pipeline);

/* Executes one three-vertex draw on the bounded AO46 color-surface path. */
bool AO46MesaRenderPipelineDrawTriangle(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/* Draws with the exact reflected vertex-stage static MTLBuffer roots. */
bool AO46MesaRenderPipelineDrawTriangleWithStaticVertexBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/* Draws with the exact reflected set of constant-offset Mesa UBO bindings. */
bool AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaUniformBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

/* Executes a bounded uint16/uint32 indexed triangle list. */
bool AO46MesaRenderPipelineDrawIndexedTriangles(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaIndexBinding *index_binding,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);

bool AO46MesaRenderPipelineDrawIndexedTrianglesWithUniformBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaUniformBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MesaIndexBinding *index_binding,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence);
