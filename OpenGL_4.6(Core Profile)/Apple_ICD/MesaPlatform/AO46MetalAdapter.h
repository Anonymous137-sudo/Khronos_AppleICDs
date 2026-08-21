/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * AO46's Metal execution adapter is deliberately below Mesa's GL and NIR
 * layers. Callers provide MSL emitted by Mesa; this interface never accepts
 * GL state or implements GL validation.
 */
struct AO46MetalAdapter {
   void *device;
   /* Classic queue remains active until graphics and blit migrate to MTL4. */
   void *queue;
   /* Mesa KosmicKrisp's public Metal 4 submission objects for compute work. */
   void *mtl4_queue;
   void *mtl4_residency_set;
   /* Retains the queue/set pair across CGL and Gallium adapter copies. */
   void *mtl4_shared_state;
   /* Mesa's generated graphics entry points always reserve buffer slots 0/1. */
   void *graphics_root_buffer;
   void *graphics_sampler_table_buffer;
   /* Adapter-owned utility pipeline for GPU-resident indirect draw counts. */
   void *indirect_count_range_pipeline;
   uint64_t registry_id;
   bool unified_memory;
   /* Public MTLBuffer.gpuAddress roots are available on macOS 13 and later. */
   bool gpu_addressable_buffers;
   /* MTL4 queue plus residency-set ownership is ready for direct submissions. */
   bool mtl4_submission_enabled;
   size_t max_buffer_length;
   uint32_t max_texture_dimension_2d;
};

struct AO46MetalBuffer {
   const struct AO46MetalAdapter *adapter;
   void *native_buffer;
   void *cpu_mapping;
   uint64_t gpu_address;
   size_t length;
};

enum AO46MetalTextureFormat {
   AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM,
   AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM,
};

enum AO46MetalVertexFormat {
   AO46_METAL_VERTEX_FORMAT_FLOAT2,
   AO46_METAL_VERTEX_FORMAT_FLOAT4,
};

enum AO46MetalIndexFormat {
   AO46_METAL_INDEX_FORMAT_UINT16,
   AO46_METAL_INDEX_FORMAT_UINT32,
};

/* The primitive topology selected by validated Gallium/Mesa draw state. */
enum AO46MetalPrimitive {
   AO46_METAL_PRIMITIVE_TRIANGLES,
   AO46_METAL_PRIMITIVE_LINES,
   AO46_METAL_PRIMITIVE_POINTS,
};

enum {
   AO46_METAL_MAX_VERTEX_ATTRIBUTES = 16,
   AO46_METAL_MAX_STATIC_BINDINGS = 64,
   /* Direct MSL buffer slots use a uint16_t reflection mask. */
   AO46_METAL_MAX_STATIC_BUFFER_BINDINGS = 16,
   /* Buffer 0 is UBO 0; UBOs 1..15 live at Metal slots 16..30. */
   AO46_METAL_MAX_UNIFORM_BINDINGS = 16,
   AO46_METAL_MAX_INDIRECT_DRAWS = 64,
   AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX = 16,
   AO46_METAL_MAX_VERTEX_BUFFER_INDEX =
      AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX - 1,
};

/* Vertex buffer slots 0 and 1 are reserved by Mesa's root/sampler ABI. */
struct AO46MetalVertexAttribute {
   uint32_t attribute_index;
   uint32_t buffer_index;
   uint32_t offset;
   uint32_t stride;
   /* Zero advances per vertex; nonzero is the Metal per-instance step rate. */
   uint32_t instance_divisor;
   enum AO46MetalVertexFormat format;
};

struct AO46MetalTexture {
   const struct AO46MetalAdapter *adapter;
   void *native_texture;
   /* Retained only for a texture imported from a caller-owned IOSurface. */
   void *native_iosurface;
   uint32_t width;
   uint32_t height;
   enum AO46MetalTextureFormat format;
};

/*
 * The Gallium bridge intentionally exposes only the non-mipmapped sampler
 * subset it can bind directly through public Metal today. More sampler state
 * belongs above this adapter, where Mesa owns the API semantics.
 */
enum AO46MetalSamplerFilter {
   AO46_METAL_SAMPLER_FILTER_NEAREST,
   AO46_METAL_SAMPLER_FILTER_LINEAR,
};

enum AO46MetalSamplerAddressMode {
   AO46_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE,
   AO46_METAL_SAMPLER_ADDRESS_REPEAT,
};

struct AO46MetalSamplerDescriptor {
   enum AO46MetalSamplerFilter min_filter;
   enum AO46MetalSamplerFilter mag_filter;
   enum AO46MetalSamplerAddressMode address_s;
   enum AO46MetalSamplerAddressMode address_t;
   enum AO46MetalSamplerAddressMode address_r;
};

struct AO46MetalSampler {
   const struct AO46MetalAdapter *adapter;
   void *native_sampler;
};

struct AO46MetalComputePipeline {
   const struct AO46MetalAdapter *adapter;
   /* Preferred MTL4 PSO when it was built by KosmicKrisp's compiler bridge. */
   void *native_pipeline;
   /* Classic encoder fallback for ICB and pre-MTL4 command paths. */
   void *native_classic_pipeline;
   /* The PSO was compiled through KosmicKrisp's public MTL4 compiler bridge. */
   bool uses_mtl4_compiler;
   uint32_t thread_execution_width;
   uint32_t max_threads_per_threadgroup;
};

/*
 * A graphics PSO joins vertex and fragment MSL emitted by Mesa. It does not
 * own shader translation or OpenGL state; the color format is fixed at build
 * time so an incompatible surface is rejected before command encoding.
 */
struct AO46MetalRenderPipeline {
   const struct AO46MetalAdapter *adapter;
   /* Preferred MTL4 PSO when it was built by KosmicKrisp's compiler bridge. */
   void *native_pipeline;
   /* Classic encoder fallback for ICB and pre-MTL4 command paths. */
   void *native_classic_pipeline;
   /* The PSO was compiled through KosmicKrisp's public MTL4 compiler bridge. */
   bool uses_mtl4_compiler;
   enum AO46MetalTextureFormat color_format;
   bool supports_indirect_command_buffers;
   uint64_t static_texture_mask;
   uint64_t static_sampler_mask;
   /* Stage masks preserve Mesa bindings when a slot is used by one stage only. */
   uint64_t static_vertex_texture_mask;
   uint64_t static_fragment_texture_mask;
   uint64_t static_vertex_sampler_mask;
   uint64_t static_fragment_sampler_mask;
   uint16_t static_vertex_buffer_mask;
   size_t static_vertex_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   /* Direct fragment MTLBuffer slots emitted by KosmicKrisp. */
   uint16_t static_fragment_buffer_mask;
   size_t static_fragment_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint16_t uniform_mask;
   size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS];
   uint32_t vertex_attribute_count;
   struct AO46MetalVertexAttribute
      vertex_attributes[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
};

struct AO46MetalVertexBufferBinding {
   const struct AO46MetalBuffer *buffer;
   size_t offset;
   uint32_t index;
};

/* Bounded triangle-list element binding for Mesa-generated graphics draws. */
struct AO46MetalIndexBufferBinding {
   const struct AO46MetalBuffer *buffer;
   size_t offset;
   size_t size;
   uint32_t count;
   enum AO46MetalIndexFormat format;
   int32_t base_vertex;
   bool primitive_restart;
   uint32_t restart_index;
};

/* A bounded Gallium indirect argument sequence retained by the fence. */
struct AO46MetalIndirectDrawBinding {
   const struct AO46MetalBuffer *buffer;
   size_t offset;
   uint32_t draw_count;
   size_t stride;
   /* Optional GPU-written uint32_t count, clamped to draw_count on the GPU. */
   const struct AO46MetalBuffer *count_buffer;
   size_t count_buffer_offset;
   /*
    * Mesa poly may write one indexed record on the GPU. Its heap capacity is
    * validated up front, while the regular indirect path remains host-checked.
    */
   bool gpu_generated;
   uint32_t maximum_index_count;
};

struct AO46MetalTextureBinding {
   const struct AO46MetalTexture *texture;
   uint32_t index;
};

struct AO46MetalSamplerBinding {
   const struct AO46MetalSampler *sampler;
   uint32_t index;
};

struct AO46MetalBufferBinding {
   const struct AO46MetalBuffer *buffer;
   size_t offset;
   size_t size;
   uint32_t index;
   /* Mesa's pipe_shader_buffer writable bit for compute resource hazards. */
   bool writable;
};

/* A validated constant-offset Mesa UBO binding for the graphics ABI. */
struct AO46MetalUniformBufferBinding {
   const struct AO46MetalBuffer *buffer;
   size_t offset;
   size_t size;
   uint32_t binding;
};

struct AO46MetalSubmission {
   const struct AO46MetalAdapter *adapter;
   void *native_command_buffer;
   /* These retain the complete MTL4 command lifetime through fence retirement. */
   void *native_command_allocator;
   void *native_argument_table;
   void *native_commit_options;
   void *native_completion_state;
   /* MTL4 presentation retains an external drawable until queue feedback. */
   void *native_presentation_drawable;
   void *native_presentation_allocation;
   bool uses_mtl4;
};

bool AO46MetalAdapterCreate(struct AO46MetalAdapter *out_adapter);
/* Create an independently retained copy for a consumer that shares this queue. */
bool AO46MetalAdapterCopyRetained(const struct AO46MetalAdapter *adapter,
                                  struct AO46MetalAdapter *out_adapter);
void AO46MetalAdapterDestroy(struct AO46MetalAdapter *adapter);
bool AO46MetalAdapterIsCurrent(const struct AO46MetalAdapter *adapter);
/* Whether public Metal GPU virtual-address roots are usable by this adapter. */
bool AO46MetalAdapterSupportsGPUAddress(const struct AO46MetalAdapter *adapter);
/* Whether the adapter can submit GPU-addressed compute work through MTL4. */
bool AO46MetalAdapterSupportsMTL4Submission(
   const struct AO46MetalAdapter *adapter);
/* Registers a retained externally owned Metal allocation, such as a drawable. */
bool AO46MetalAdapterTrackExternalAllocation(
   const struct AO46MetalAdapter *adapter, void *native_allocation);
void AO46MetalAdapterUntrackExternalAllocation(
   const struct AO46MetalAdapter *adapter, void *native_allocation);

/*
 * Adapter-owned command lifecycle. Gallium command paths may acquire this
 * carrier, encode through their Metal encoder, then commit it exactly once.
 * Keeping ownership here avoids independent queue-lifecycle conventions.
 */
bool AO46MetalSubmissionBegin(const struct AO46MetalAdapter *adapter,
                              struct AO46MetalSubmission *out_submission);
bool AO46MetalSubmissionCommit(struct AO46MetalSubmission *submission,
                               bool wait);

bool AO46MetalBufferCreate(const struct AO46MetalAdapter *adapter,
                           size_t length,
                           struct AO46MetalBuffer *out_buffer);
void AO46MetalBufferDestroy(struct AO46MetalBuffer *buffer);
bool AO46MetalBufferIsCurrent(const struct AO46MetalBuffer *buffer);
/* Returns a public Metal GPU virtual address for Mesa/libkk pointer ABIs. */
bool AO46MetalBufferGetGPUAddress(const struct AO46MetalBuffer *buffer,
                                  uint64_t *out_gpu_address);
/* Writes a validated target GPU address into a mapped Mesa/libkk root block. */
bool AO46MetalBufferWriteGPUAddressRoot(struct AO46MetalBuffer *root,
                                        size_t root_offset,
                                        const struct AO46MetalBuffer *target,
                                        size_t target_offset);

bool AO46MetalTextureCreate(const struct AO46MetalAdapter *adapter,
                            uint32_t width, uint32_t height,
                            enum AO46MetalTextureFormat format,
                            struct AO46MetalTexture *out_texture);
/*
 * Imports one non-planar, four-bytes-per-pixel IOSurface as a Metal texture.
 * AO46 retains the IOSurface until AO46MetalTextureDestroy, so the caller may
 * release its own reference after a successful import.
 */
bool AO46MetalTextureImportIOSurface(
   const struct AO46MetalAdapter *adapter, void *native_iosurface,
   enum AO46MetalTextureFormat format, struct AO46MetalTexture *out_texture);
void AO46MetalTextureDestroy(struct AO46MetalTexture *texture);
bool AO46MetalTextureIsCurrent(const struct AO46MetalTexture *texture);

bool AO46MetalSamplerCreate(const struct AO46MetalAdapter *adapter,
                            const struct AO46MetalSamplerDescriptor *descriptor,
                            struct AO46MetalSampler *out_sampler);
/* Kept as the stable helper for existing callers that use the original slice. */
bool AO46MetalSamplerCreateNearestClamp(const struct AO46MetalAdapter *adapter,
                                        struct AO46MetalSampler *out_sampler);
void AO46MetalSamplerDestroy(struct AO46MetalSampler *sampler);
bool AO46MetalSamplerIsCurrent(const struct AO46MetalSampler *sampler);

/* Returns the Metal-required staging layout for an RGBA8/BGRA8 texture transfer. */
bool AO46MetalTextureTransferLayout(const struct AO46MetalTexture *texture,
                                    uint32_t width, uint32_t height,
                                    size_t *out_bytes_per_row,
                                    size_t *out_size);

/* Encodes a full-surface color clear using a native Metal render pass. */
bool AO46MetalTextureClearSubmit(const struct AO46MetalAdapter *adapter,
                                 const struct AO46MetalTexture *texture,
                                 const float color[4],
                                 struct AO46MetalSubmission *out_submission);

/* Copies an RGBA8/BGRA8 texture region into a staging MTLBuffer. */
bool AO46MetalTextureReadbackSubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTexture *source, uint32_t source_x, uint32_t source_y,
   uint32_t width, uint32_t height, const struct AO46MetalBuffer *destination,
   size_t destination_offset, size_t destination_bytes_per_row,
   struct AO46MetalSubmission *out_submission);

/* Copies one RGBA8/BGRA8 staging-buffer region into a private MTLTexture. */
bool AO46MetalTextureUploadSubmit(
   const struct AO46MetalAdapter *adapter, const struct AO46MetalBuffer *source,
   size_t source_offset, size_t source_bytes_per_row,
   const struct AO46MetalTexture *destination, uint32_t destination_x,
   uint32_t destination_y, uint32_t width, uint32_t height,
   struct AO46MetalSubmission *out_submission);

/* Copies one full-format RGBA8/BGRA8 region between native Metal textures. */
bool AO46MetalTextureCopySubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTexture *source, uint32_t source_x, uint32_t source_y,
   const struct AO46MetalTexture *destination, uint32_t destination_x,
   uint32_t destination_y, uint32_t width, uint32_t height,
   struct AO46MetalSubmission *out_submission);

/*
 * Encodes a native MTLBlitCommandEncoder copy and returns immediately after
 * queue commit. The caller owns the returned completion handle.
 */
bool AO46MetalBufferBlitSubmit(const struct AO46MetalAdapter *adapter,
                               const struct AO46MetalBuffer *source,
                               size_t source_offset,
                               const struct AO46MetalBuffer *destination,
                               size_t destination_offset,
                               size_t size,
                               struct AO46MetalSubmission *out_submission);

/* Compiles MSL generated by Mesa's NIR-to-MSL path into a Metal compute PSO. */
bool AO46MetalComputePipelineCreate(
   const struct AO46MetalAdapter *adapter, const char *msl_source,
   const char *entrypoint, struct AO46MetalComputePipeline *out_pipeline);
void AO46MetalComputePipelineDestroy(
   struct AO46MetalComputePipeline *pipeline);

bool AO46MetalRenderPipelineCreate(
   const struct AO46MetalAdapter *adapter, const char *vertex_msl_source,
   const char *vertex_entrypoint, const char *fragment_msl_source,
   const char *fragment_entrypoint, enum AO46MetalTextureFormat color_format,
   const struct AO46MetalVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint64_t static_texture_mask,
   uint64_t static_sampler_mask, uint16_t static_fragment_buffer_mask,
   const size_t
      static_fragment_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t uniform_mask,
   const size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS],
   struct AO46MetalRenderPipeline *out_pipeline);
/* As above, with immutable direct MTLBuffer bindings in the vertex stage. */
bool AO46MetalRenderPipelineCreateWithStaticVertexBuffers(
   const struct AO46MetalAdapter *adapter, const char *vertex_msl_source,
   const char *vertex_entrypoint, const char *fragment_msl_source,
   const char *fragment_entrypoint, enum AO46MetalTextureFormat color_format,
   const struct AO46MetalVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint64_t static_texture_mask,
   uint64_t static_sampler_mask, uint16_t static_vertex_buffer_mask,
   const size_t
      static_vertex_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t static_fragment_buffer_mask,
   const size_t
      static_fragment_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t uniform_mask,
   const size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS],
   struct AO46MetalRenderPipeline *out_pipeline);
void AO46MetalRenderPipelineDestroy(
   struct AO46MetalRenderPipeline *pipeline);

/* Submits one bounded primitive stream with reflected UBO and element bindings. */
bool AO46MetalRenderSubmit(const struct AO46MetalAdapter *adapter,
                           const struct AO46MetalRenderPipeline *pipeline,
                           const struct AO46MetalTexture *color_target,
                           const struct AO46MetalUniformBufferBinding
                              *uniform_bindings,
                           size_t uniform_binding_count,
                           const struct AO46MetalIndexBufferBinding *index_binding,
                           const struct AO46MetalIndirectDrawBinding
                              *indirect_binding,
                           const struct AO46MetalVertexBufferBinding
                              *vertex_bindings,
                           size_t vertex_binding_count,
                           const struct AO46MetalTextureBinding
                              *texture_bindings,
                           size_t texture_binding_count,
                           const struct AO46MetalSamplerBinding
                              *sampler_bindings,
                           size_t sampler_binding_count,
                           const struct AO46MetalBufferBinding
                              *fragment_buffer_bindings,
                           size_t fragment_buffer_binding_count,
                           enum AO46MetalPrimitive primitive,
                           uint32_t vertex_start,
                           uint32_t vertex_count,
                           uint32_t instance_count,
                           uint32_t base_instance,
                           struct AO46MetalSubmission *out_submission);
/* As above, with reflected direct MTLBuffer bindings for the vertex stage. */
bool AO46MetalRenderSubmitWithStaticVertexBuffers(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalTexture *color_target,
   const struct AO46MetalUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalIndexBufferBinding *index_binding,
   const struct AO46MetalIndirectDrawBinding *indirect_binding,
   const struct AO46MetalVertexBufferBinding *vertex_bindings,
   size_t vertex_binding_count,
   const struct AO46MetalTextureBinding *texture_bindings,
   size_t texture_binding_count,
   const struct AO46MetalSamplerBinding *sampler_bindings,
   size_t sampler_binding_count,
   const struct AO46MetalBufferBinding *vertex_static_buffer_bindings,
   size_t vertex_static_buffer_binding_count,
   const struct AO46MetalBufferBinding *fragment_buffer_bindings,
   size_t fragment_buffer_binding_count,
   enum AO46MetalPrimitive primitive, uint32_t vertex_start,
   uint32_t vertex_count, uint32_t instance_count, uint32_t base_instance,
   struct AO46MetalSubmission *out_submission);

/*
 * Encodes one compute dispatch with direct MTLBuffer bindings. The returned
 * submission owns its Metal command buffer until wait or destroy. This avoids
 * CPU copies between Mesa-owned MSL output and the native Metal queue.
 */
bool AO46MetalComputeSubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission);

/*
 * Encodes a Mesa/Gallium indirect compute launch. The three uint32 workgroup
 * counts remain in GPU memory, avoiding a CPU readback of DispatchComputeIndirect
 * arguments. This stays on the classic public Metal encoder until the MTL4
 * indirect-dispatch contract is available through the audited adapter path.
 */
bool AO46MetalComputeSubmitIndirect(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   const struct AO46MetalBuffer *indirect_buffer, size_t indirect_offset,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission);
bool AO46MetalSubmissionIsComplete(const struct AO46MetalSubmission *submission);
bool AO46MetalSubmissionWait(struct AO46MetalSubmission *submission);
void AO46MetalSubmissionDestroy(struct AO46MetalSubmission *submission);
