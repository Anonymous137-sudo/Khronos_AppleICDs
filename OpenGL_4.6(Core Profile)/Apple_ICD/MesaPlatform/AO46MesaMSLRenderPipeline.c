/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLRenderPipeline.h"

#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir.h"
#include "util/bitscan.h"
#include "util/ralloc.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static bool
ao46_mesa_render_pipeline_is_empty(const struct AO46MesaRenderPipeline *pipeline)
{
   if (!pipeline || pipeline->metal_pipeline.adapter ||
       pipeline->metal_pipeline.native_pipeline ||
       pipeline->metal_pipeline.native_classic_pipeline ||
       pipeline->metal_pipeline.color_format !=
          AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM ||
       pipeline->vertex_msl_source || pipeline->vertex_entrypoint ||
       pipeline->fragment_msl_source || pipeline->fragment_entrypoint ||
       pipeline->vertex_reflection.inputs_read != 0 ||
       pipeline->vertex_reflection.outputs_written != 0 ||
       pipeline->vertex_reflection.static_texture_mask != 0 ||
       pipeline->vertex_reflection.static_sampler_mask != 0 ||
       pipeline->vertex_reflection.static_buffer_mask != 0 ||
       pipeline->vertex_reflection.uniform_mask != 0 ||
       pipeline->fragment_reflection.inputs_read != 0 ||
       pipeline->fragment_reflection.outputs_written != 0 ||
       pipeline->fragment_reflection.static_texture_mask != 0 ||
       pipeline->fragment_reflection.static_sampler_mask != 0 ||
       pipeline->fragment_reflection.static_buffer_mask != 0 ||
       pipeline->fragment_reflection.uniform_mask != 0 ||
       pipeline->vertex_attribute_count != 0)
      return false;

   for (size_t i = 0; i < AO46_METAL_MAX_UNIFORM_BINDINGS; ++i) {
      if (pipeline->vertex_reflection.uniform_bytes[i] != 0 ||
          pipeline->fragment_reflection.uniform_bytes[i] != 0)
         return false;
   }

   for (size_t i = 0; i < AO46_METAL_MAX_STATIC_BINDINGS; ++i) {
      if (pipeline->vertex_reflection.static_buffer_bytes[i] != 0 ||
          pipeline->fragment_reflection.static_buffer_bytes[i] != 0)
         return false;
   }

   return true;
}

static bool
ao46_mesa_vertex_attribute_index(uint32_t location, uint32_t *out_index)
{
   if (!out_index)
      return false;

   if (location == VERT_ATTRIB_POS) {
      *out_index = 0;
      return true;
   }

   if (location >= VERT_ATTRIB_GENERIC0 && location < VERT_ATTRIB_MAX) {
      *out_index = location - VERT_ATTRIB_GENERIC0;
      return true;
   }

   return false;
}

static bool
ao46_mesa_vertex_attributes_are_valid(
   const struct AO46MesaGraphicsStageReflection *reflection,
   const struct AO46MesaVertexAttribute *attributes, size_t attribute_count,
   struct AO46MetalVertexAttribute *out_metal_attributes)
{
   if (!reflection || !out_metal_attributes ||
       (attribute_count == 0 && attributes) ||
       (attribute_count != 0 && !attributes) ||
       attribute_count > AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
       util_bitcount64(reflection->inputs_read) != attribute_count)
      return false;

   for (size_t i = 0; i < attribute_count; ++i) {
      uint32_t attribute_index;

      if (!ao46_mesa_vertex_attribute_index(attributes[i].location,
                                             &attribute_index) ||
          !(reflection->inputs_read & BITFIELD64_BIT(attributes[i].location)))
         return false;

      out_metal_attributes[i] = (struct AO46MetalVertexAttribute){
         .attribute_index = attribute_index,
         .buffer_index = attributes[i].buffer_index,
         .offset = attributes[i].offset,
         .stride = attributes[i].stride,
         .instance_divisor = attributes[i].instance_divisor,
         .format = attributes[i].format,
      };

      for (size_t j = 0; j < i; ++j) {
         if (attributes[j].location == attributes[i].location)
            return false;
      }
   }

   return true;
}

static bool
ao46_mesa_stage_link_is_valid(
   const struct AO46MesaGraphicsStageReflection *vertex_reflection,
   const struct AO46MesaGraphicsStageReflection *fragment_reflection)
{
   if (!vertex_reflection || !fragment_reflection)
      return false;

   /* The bounded path supports only fragment stage inputs written by the VS. */
   return (fragment_reflection->inputs_read &
           ~vertex_reflection->outputs_written) == 0;
}

static void
ao46_mesa_clear_barycentric_sysvals(struct nir_shader *nir)
{
   if (nir->info.stage != MESA_SHADER_FRAGMENT)
      return;

   /*
    * KosmicKrisp emits interpolation from FragmentIn directly. These gather
    * bits otherwise reach emit_sysvals, where barycentrics have no standalone
    * Metal entry-point parameter and would become a null declaration.
    */
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_LINEAR_PIXEL);
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_LINEAR_CENTROID);
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_LINEAR_SAMPLE);
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_PERSP_PIXEL);
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_PERSP_CENTROID);
   BITSET_CLEAR(nir->info.system_values_read,
                SYSTEM_VALUE_BARYCENTRIC_PERSP_SAMPLE);
}

static bool
ao46_mesa_collect_static_texture_bindings(
   struct nir_shader *nir, struct AO46MesaGraphicsStageReflection *reflection)
{
   if (!nir || !reflection)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_tex_instr *tex;
            uint64_t texture_bit;

            if (instr->type != nir_instr_type_tex)
               continue;

            tex = nir_instr_as_tex(instr);
            if (tex->texture_index >= AO46_METAL_MAX_STATIC_BINDINGS ||
                nir_tex_instr_src_index(tex, nir_tex_src_texture_handle) >= 0 ||
                nir_tex_instr_src_index(tex, nir_tex_src_texture_deref) >= 0)
               return false;

            texture_bit = UINT64_C(1) << tex->texture_index;
            reflection->static_texture_mask |= texture_bit;
            if (!nir_tex_instr_need_sampler(tex))
               continue;

            if (tex->sampler_index >= AO46_METAL_MAX_STATIC_BINDINGS ||
                tex->embedded_sampler ||
                nir_tex_instr_src_index(tex, nir_tex_src_sampler_handle) >= 0 ||
                nir_tex_instr_src_index(tex, nir_tex_src_sampler_deref) >= 0)
               return false;

            reflection->static_sampler_mask |= UINT64_C(1) << tex->sampler_index;
         }
      }
   }

   return true;
}

static bool
ao46_mesa_collect_uniform_loads(
   struct nir_shader *nir, struct AO46MesaGraphicsStageReflection *reflection)
{
   if (!nir || !reflection)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_intrinsic_instr *intrinsic;
            size_t bytes_per_component;
            size_t byte_count;
            size_t offset;
            uint32_t binding;

            if (instr->type != nir_instr_type_intrinsic)
               continue;

            intrinsic = nir_instr_as_intrinsic(instr);
            if (intrinsic->intrinsic != nir_intrinsic_load_ubo)
               continue;

            if (!nir_src_is_const(intrinsic->src[0]) ||
                !nir_src_is_const(intrinsic->src[1]) ||
                intrinsic->src[0].ssa->bit_size != 32 ||
                intrinsic->src[1].ssa->bit_size != 32 ||
                intrinsic->def.bit_size == 0 ||
                intrinsic->def.bit_size % CHAR_BIT != 0)
               return false;

            binding = nir_src_as_uint(intrinsic->src[0]);
            if (binding >= AO46_METAL_MAX_UNIFORM_BINDINGS)
               return false;

            bytes_per_component = intrinsic->def.bit_size / CHAR_BIT;
            if (intrinsic->def.num_components > SIZE_MAX / bytes_per_component)
               return false;
            byte_count = (size_t)intrinsic->def.num_components *
                         bytes_per_component;

            offset = nir_src_as_uint(intrinsic->src[1]);
            if (offset > SIZE_MAX - byte_count)
               return false;

            reflection->uniform_mask |= UINT16_C(1) << binding;
            if (reflection->uniform_bytes[binding] < offset + byte_count)
               reflection->uniform_bytes[binding] = offset + byte_count;
         }
      }
   }

   return true;
}

static bool
ao46_mesa_collect_static_buffer_bindings(
   struct nir_shader *nir, struct AO46MesaGraphicsStageReflection *reflection)
{
   if (!nir || !reflection)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_intrinsic_instr *intrinsic;
            unsigned binding;

            if (instr->type != nir_instr_type_intrinsic)
               continue;

            intrinsic = nir_instr_as_intrinsic(instr);
            if (intrinsic->intrinsic != nir_intrinsic_load_buffer_ptr_kk)
               continue;

            binding = nir_intrinsic_binding(intrinsic);
            if (binding < 2 ||
                binding >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS)
               return false;
            reflection->static_buffer_mask |= UINT16_C(1) << binding;
         }
      }
   }

   return true;
}

static bool
ao46_mesa_apply_static_buffer_requirements(
   struct AO46MesaGraphicsStageReflection *reflection,
   uint16_t required_mask,
   const struct AO46MesaStaticBufferRequirement *requirements,
   size_t requirement_count)
{
   uint16_t observed_mask = 0;

   if (!reflection || reflection->static_buffer_mask != required_mask ||
       (requirement_count == 0 && requirements) ||
       (requirement_count != 0 && !requirements) ||
       requirement_count > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS)
      return false;

   for (size_t i = 0; i < requirement_count; ++i) {
      const struct AO46MesaStaticBufferRequirement *requirement =
         &requirements[i];
      uint16_t bit;

      if (requirement->binding < 2 ||
          requirement->binding >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
          requirement->minimum_size == 0)
         return false;

      bit = UINT16_C(1) << requirement->binding;
      if (!(required_mask & bit) || (observed_mask & bit))
         return false;
      observed_mask |= bit;
      reflection->static_buffer_bytes[requirement->binding] =
         requirement->minimum_size;
   }

   return observed_mask == required_mask;
}

static bool
ao46_mesa_lower_graphics_stage(
   struct nir_shader *nir, mesa_shader_stage stage,
   uint16_t expected_static_buffer_mask,
   struct AO46MesaGraphicsStageReflection *out_reflection, char **out_source,
   char **out_entrypoint)
{
   struct nir_to_msl_options options = {0};
   nir_function_impl *entrypoint;
   void *msl_context = NULL;
   char *msl = NULL;
   char *source = NULL;
   char *entrypoint_name = NULL;
   bool lowered = false;

   if (!nir || nir->info.stage != stage || !out_reflection || !out_source ||
       !out_entrypoint || *out_source || *out_entrypoint)
      return false;

   msl_preprocess_nir(nir);
   /* Mesa reports optimization progress, not a pass-level success value. */
   (void)msl_optimize_nir(nir);
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
   ao46_mesa_clear_barycentric_sysvals(nir);
   if (!ao46_mesa_collect_static_texture_bindings(nir, out_reflection) ||
       !ao46_mesa_collect_uniform_loads(nir, out_reflection) ||
       !ao46_mesa_collect_static_buffer_bindings(nir, out_reflection) ||
       out_reflection->static_buffer_mask != expected_static_buffer_mask)
      return false;

   msl_context = ralloc_context(NULL);
   if (!msl_context)
      return false;

   options.mem_ctx = msl_context;
   options.use_static_sampler_bindings = true;
   options.static_buffer_mask = out_reflection->static_buffer_mask;
   options.static_ubo_mask = out_reflection->uniform_mask;
   options.static_ubo_first_buffer = AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX;
   if (stage == MESA_SHADER_FRAGMENT)
      options.rts_component_count[0] = 4;

   msl = nir_to_msl(nir, &options);
   entrypoint = nir_shader_get_entrypoint(nir);
   if (!msl || !entrypoint || !entrypoint->function ||
       !entrypoint->function->name)
      goto out;

   source = strdup(msl);
   entrypoint_name = strdup(entrypoint->function->name);
   if (!source || !entrypoint_name)
      goto out;

   out_reflection->inputs_read = nir->info.inputs_read;
   out_reflection->outputs_written = nir->info.outputs_written;
   *out_source = source;
   *out_entrypoint = entrypoint_name;
   source = NULL;
   entrypoint_name = NULL;
   lowered = true;

out:
   free(source);
   free(entrypoint_name);
   ralloc_free(msl_context);
   return lowered;
}

bool
AO46MesaRenderPipelineCreate(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   return AO46MesaRenderPipelineCreateWithStaticBuffers(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, 0, 0, out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithStaticBuffers(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t vertex_static_buffer_mask,
   uint16_t fragment_static_buffer_mask,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   return AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, vertex_static_buffer_mask, NULL, 0,
      fragment_static_buffer_mask, NULL, 0, out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithStaticBufferRequirements(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t fragment_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *fragment_requirements,
   size_t fragment_requirement_count,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   return AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
      adapter, vertex_nir, fragment_nir, color_format, vertex_attributes,
      vertex_attribute_count, 0, NULL, 0, fragment_static_buffer_mask,
      fragment_requirements, fragment_requirement_count, out_pipeline);
}

bool
AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
   const struct AO46MetalAdapter *adapter, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint16_t vertex_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *vertex_requirements,
   size_t vertex_requirement_count, uint16_t fragment_static_buffer_mask,
   const struct AO46MesaStaticBufferRequirement *fragment_requirements,
   size_t fragment_requirement_count,
   struct AO46MesaRenderPipeline *out_pipeline)
{
   struct AO46MetalRenderPipeline metal_pipeline = {0};
   struct AO46MetalVertexAttribute
      metal_attributes[AO46_METAL_MAX_VERTEX_ATTRIBUTES] = {{0}};
   struct AO46MesaGraphicsStageReflection vertex_reflection = {0};
   struct AO46MesaGraphicsStageReflection fragment_reflection = {0};
   char *vertex_source = NULL;
   char *vertex_entrypoint = NULL;
   char *fragment_source = NULL;
   char *fragment_entrypoint = NULL;
   size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS] = {0};
   uint16_t uniform_mask = 0;
   bool created = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !vertex_nir || !fragment_nir ||
       vertex_nir->info.stage != MESA_SHADER_VERTEX ||
       fragment_nir->info.stage != MESA_SHADER_FRAGMENT || !out_pipeline ||
       (vertex_static_buffer_mask & UINT16_C(0x0003)) != 0 ||
       (fragment_static_buffer_mask & UINT16_C(0x0003)) != 0 ||
       !ao46_mesa_render_pipeline_is_empty(out_pipeline))
      return false;

   if (!ao46_mesa_lower_graphics_stage(vertex_nir, MESA_SHADER_VERTEX,
                                       vertex_static_buffer_mask,
                                       &vertex_reflection, &vertex_source,
                                       &vertex_entrypoint) ||
       !ao46_mesa_lower_graphics_stage(fragment_nir, MESA_SHADER_FRAGMENT,
                                       fragment_static_buffer_mask,
                                       &fragment_reflection, &fragment_source,
                                       &fragment_entrypoint) ||
       vertex_reflection.static_texture_mask != 0 ||
       vertex_reflection.static_sampler_mask != 0 ||
       !ao46_mesa_apply_static_buffer_requirements(
          &vertex_reflection, vertex_static_buffer_mask,
          vertex_requirements, vertex_requirement_count) ||
       !ao46_mesa_apply_static_buffer_requirements(
          &fragment_reflection, fragment_static_buffer_mask,
          fragment_requirements, fragment_requirement_count) ||
       !ao46_mesa_stage_link_is_valid(&vertex_reflection, &fragment_reflection) ||
       !ao46_mesa_vertex_attributes_are_valid(
          &vertex_reflection, vertex_attributes, vertex_attribute_count,
          metal_attributes))
      goto out;

   uniform_mask = vertex_reflection.uniform_mask | fragment_reflection.uniform_mask;
   for (size_t i = 0; i < AO46_METAL_MAX_UNIFORM_BINDINGS; ++i) {
      uniform_bytes[i] = vertex_reflection.uniform_bytes[i] >
                            fragment_reflection.uniform_bytes[i]
                             ? vertex_reflection.uniform_bytes[i]
                             : fragment_reflection.uniform_bytes[i];
   }

   if (!AO46MetalRenderPipelineCreateWithStaticVertexBuffers(
          adapter, vertex_source, vertex_entrypoint, fragment_source,
          fragment_entrypoint, color_format,
          vertex_attribute_count ? metal_attributes : NULL,
          vertex_attribute_count,
          vertex_reflection.static_texture_mask |
             fragment_reflection.static_texture_mask,
          vertex_reflection.static_sampler_mask |
             fragment_reflection.static_sampler_mask,
          vertex_reflection.static_buffer_mask,
          vertex_reflection.static_buffer_bytes,
          fragment_reflection.static_buffer_mask,
          fragment_reflection.static_buffer_bytes,
          uniform_mask, uniform_bytes, &metal_pipeline))
      goto out;

   *out_pipeline = (struct AO46MesaRenderPipeline){
      .metal_pipeline = metal_pipeline,
      .vertex_msl_source = vertex_source,
      .vertex_entrypoint = vertex_entrypoint,
      .fragment_msl_source = fragment_source,
      .fragment_entrypoint = fragment_entrypoint,
      .vertex_reflection = vertex_reflection,
      .fragment_reflection = fragment_reflection,
      .vertex_attribute_count = (uint32_t)vertex_attribute_count,
   };
   if (vertex_attribute_count != 0)
      memcpy(out_pipeline->vertex_attributes, vertex_attributes,
             vertex_attribute_count * sizeof(*vertex_attributes));
   metal_pipeline = (struct AO46MetalRenderPipeline){0};
   vertex_source = NULL;
   vertex_entrypoint = NULL;
   fragment_source = NULL;
   fragment_entrypoint = NULL;
   created = true;

out:
   AO46MetalRenderPipelineDestroy(&metal_pipeline);
   free(vertex_source);
   free(vertex_entrypoint);
   free(fragment_source);
   free(fragment_entrypoint);
   return created;
}

void
AO46MesaRenderPipelineDestroy(struct AO46MesaRenderPipeline *pipeline)
{
   if (!pipeline)
      return;

   AO46MetalRenderPipelineDestroy(&pipeline->metal_pipeline);
   free(pipeline->vertex_msl_source);
   free(pipeline->vertex_entrypoint);
   free(pipeline->fragment_msl_source);
   free(pipeline->fragment_entrypoint);
   *pipeline = (struct AO46MesaRenderPipeline){0};
}

bool
AO46MesaRenderPipelineDrawTriangle(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
      pipeline, context, destination, NULL, 0, vertex_bindings, vertex_binding_count,
      out_fence);
}

bool
AO46MesaRenderPipelineDrawTriangleWithStaticVertexBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumStaticBufferBinding
      gallium_static_bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   struct AO46MetalGalliumVertexBinding
      gallium_vertex_bindings[AO46_METAL_MAX_VERTEX_ATTRIBUTES];

   if (!pipeline || !pipeline->metal_pipeline.native_pipeline || !context ||
       !destination || !out_fence ||
       (vertex_static_binding_count == 0 && vertex_static_bindings) ||
       (vertex_static_binding_count != 0 && !vertex_static_bindings) ||
       vertex_static_binding_count > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
       (vertex_binding_count == 0 && vertex_bindings) ||
       (vertex_binding_count != 0 && !vertex_bindings) ||
       vertex_binding_count > pipeline->vertex_attribute_count)
      return false;

   for (size_t i = 0; i < vertex_static_binding_count; ++i) {
      gallium_static_bindings[i] = (struct AO46MetalGalliumStaticBufferBinding){
         .resource = vertex_static_bindings[i].resource,
         .offset = vertex_static_bindings[i].offset,
         .size = vertex_static_bindings[i].size,
         .index = vertex_static_bindings[i].binding,
      };
   }
   for (size_t i = 0; i < vertex_binding_count; ++i) {
      gallium_vertex_bindings[i] = (struct AO46MetalGalliumVertexBinding){
         .resource = vertex_bindings[i].resource,
         .offset = vertex_bindings[i].offset,
         .index = vertex_bindings[i].index,
      };
   }

   return AO46MetalGalliumRenderTriangleWithStaticVertexBuffers(
      context, &pipeline->metal_pipeline, destination,
      vertex_static_binding_count ? gallium_static_bindings : NULL,
      vertex_static_binding_count,
      vertex_binding_count ? gallium_vertex_bindings : NULL, vertex_binding_count,
      out_fence);
}

static bool
ao46_mesa_render_pipeline_draw_triangle(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaUniformBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MesaIndexBinding *index_binding,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   if (!pipeline || !pipeline->metal_pipeline.native_pipeline || !context ||
       !destination ||
       (vertex_binding_count == 0 && vertex_bindings) ||
       (vertex_binding_count != 0 && !vertex_bindings) ||
       vertex_binding_count > pipeline->vertex_attribute_count || !out_fence)
      return false;

   struct AO46MetalGalliumVertexBinding
      gallium_bindings[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
   struct AO46MetalGalliumUniformBufferBinding
      gallium_uniform_bindings[AO46_METAL_MAX_UNIFORM_BINDINGS];
   struct AO46MetalGalliumIndexBufferBinding gallium_index_binding;
   const struct AO46MetalGalliumIndexBufferBinding *gallium_index = NULL;

   if ((uniform_binding_count == 0 && uniform_bindings) ||
       (uniform_binding_count != 0 && !uniform_bindings) ||
       uniform_binding_count > AO46_METAL_MAX_UNIFORM_BINDINGS)
      return false;

   for (size_t i = 0; i < uniform_binding_count; ++i) {
      gallium_uniform_bindings[i] = (struct AO46MetalGalliumUniformBufferBinding){
         .resource = uniform_bindings[i].resource,
         .offset = uniform_bindings[i].offset,
         .size = uniform_bindings[i].size,
         .binding = uniform_bindings[i].binding,
      };
   }

   if (index_binding) {
      gallium_index_binding = (struct AO46MetalGalliumIndexBufferBinding){
         .resource = index_binding->resource,
         .offset = index_binding->offset,
         .size = index_binding->size,
         .count = index_binding->count,
         .format = index_binding->format,
         .base_vertex = index_binding->base_vertex,
         .primitive_restart = index_binding->primitive_restart,
         .restart_index = index_binding->restart_index,
      };
      gallium_index = &gallium_index_binding;
   }

   for (size_t i = 0; i < vertex_binding_count; ++i) {
      gallium_bindings[i] = (struct AO46MetalGalliumVertexBinding){
         .resource = vertex_bindings[i].resource,
         .offset = vertex_bindings[i].offset,
         .index = vertex_bindings[i].index,
      };
   }

   if (gallium_index) {
      return AO46MetalGalliumRenderIndexedTrianglesWithUniformBuffers(
         context, &pipeline->metal_pipeline, destination,
         uniform_binding_count ? gallium_uniform_bindings : NULL,
         uniform_binding_count, gallium_index, gallium_bindings,
         vertex_binding_count, out_fence);
   }

   return AO46MetalGalliumRenderTriangleWithUniformBuffers(
      context, &pipeline->metal_pipeline, destination,
      uniform_binding_count ? gallium_uniform_bindings : NULL,
      uniform_binding_count, gallium_bindings, vertex_binding_count, out_fence);
}

bool
AO46MesaRenderPipelineDrawTriangleWithUniformBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaUniformBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return ao46_mesa_render_pipeline_draw_triangle(
      pipeline, context, destination, uniform_bindings, uniform_binding_count,
      NULL, vertex_bindings, vertex_binding_count, out_fence);
}

bool
AO46MesaRenderPipelineDrawIndexedTriangles(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaIndexBinding *index_binding,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return AO46MesaRenderPipelineDrawIndexedTrianglesWithUniformBuffers(
      pipeline, context, destination, NULL, 0, index_binding, vertex_bindings,
      vertex_binding_count, out_fence);
}

bool
AO46MesaRenderPipelineDrawIndexedTrianglesWithUniformBuffers(
   const struct AO46MesaRenderPipeline *pipeline, struct pipe_context *context,
   struct pipe_surface *destination,
   const struct AO46MesaUniformBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MesaIndexBinding *index_binding,
   const struct AO46MesaVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   if (!index_binding)
      return false;

   return ao46_mesa_render_pipeline_draw_triangle(
      pipeline, context, destination, uniform_bindings, uniform_binding_count,
      index_binding, vertex_bindings, vertex_binding_count, out_fence);
}
