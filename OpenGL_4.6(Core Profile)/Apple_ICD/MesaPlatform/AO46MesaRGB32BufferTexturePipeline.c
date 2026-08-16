/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaNIRBufferTexture.h"

#include "AO46MesaMSLRenderPipeline.h"

static bool
ao46_mesa_prepare_rgb32_stage(
   struct nir_shader *nir, struct pipe_sampler_view *const *views,
   uint16_t view_mask,
   struct AO46MesaStaticBufferRequirement
      requirements[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint32_t *out_requirement_count)
{
   struct AO46MesaRGB32BufferTextureBinding
      bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint32_t binding_count = 0;

   if (!nir || !requirements || !out_requirement_count)
      return false;

   *out_requirement_count = 0;
   if (view_mask == 0)
      return true;

   if (!views || !AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
          views, view_mask, bindings,
          AO46_METAL_MAX_STATIC_BUFFER_BINDINGS, &binding_count) ||
       !AO46MesaRGB32BufferTextureRequirements(
          bindings, binding_count, requirements,
          AO46_METAL_MAX_STATIC_BUFFER_BINDINGS, out_requirement_count) ||
       !AO46MesaNIRLowerRGB32BufferTextures(nir, bindings, binding_count))
      return false;

   return true;
}

bool
AO46MesaRenderPipelineCreateWithStageRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *vertex_views,
   uint16_t vertex_rgb32_view_mask,
   struct pipe_sampler_view *const *fragment_views,
   uint16_t fragment_rgb32_view_mask,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   struct AO46MesaStaticBufferRequirement
      vertex_requirements[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   struct AO46MesaStaticBufferRequirement
      fragment_requirements[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint32_t vertex_requirement_count = 0;
   uint32_t fragment_requirement_count = 0;

   if (!ao46_mesa_prepare_rgb32_stage(
          vertex_nir, vertex_views, vertex_rgb32_view_mask,
          vertex_requirements, &vertex_requirement_count) ||
       !ao46_mesa_prepare_rgb32_stage(
          fragment_nir, fragment_views, fragment_rgb32_view_mask,
          fragment_requirements, &fragment_requirement_count))
      return false;

   return AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, vertex_rgb32_view_mask, vertex_requirements,
      vertex_requirement_count, fragment_rgb32_view_mask,
      fragment_requirements, fragment_requirement_count, out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *fragment_views,
   uint16_t rgb32_view_mask, struct AO46MesaRenderPipeline *out_pipeline)
{
   return AO46MesaRenderPipelineCreateWithStageRGB32SamplerViews(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, NULL, 0, fragment_views, rgb32_view_mask,
      out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithDetectedRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *fragment_views,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   uint16_t rgb32_view_mask;

   if (!AO46MesaNIRCollectRGB32BufferTextureSlots(fragment_nir,
                                                   &rgb32_view_mask))
      return false;

   return AO46MesaRenderPipelineCreateWithRGB32SamplerViews(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, fragment_views, rgb32_view_mask, out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithDetectedStageRGB32SamplerViews(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct pipe_sampler_view *const *vertex_views,
   struct pipe_sampler_view *const *fragment_views,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   uint16_t vertex_rgb32_view_mask;
   uint16_t fragment_rgb32_view_mask;

   if (!AO46MesaNIRCollectRGB32BufferTextureSlots(vertex_nir,
                                                   &vertex_rgb32_view_mask) ||
       !AO46MesaNIRCollectRGB32BufferTextureSlots(fragment_nir,
                                                   &fragment_rgb32_view_mask))
      return false;

   return AO46MesaRenderPipelineCreateWithStageRGB32SamplerViews(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, vertex_views, vertex_rgb32_view_mask,
      fragment_views, fragment_rgb32_view_mask, out_pipeline);
}
