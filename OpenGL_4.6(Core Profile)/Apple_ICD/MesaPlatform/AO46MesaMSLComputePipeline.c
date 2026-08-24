/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMSLComputePipeline.h"

#include "AO46MetalGalliumScreen.h"

#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir.h"
#include "nir_builder.h"
#include "nir_intrinsics.h"
#include "pipe/p_state.h"
#include "util/hash_table.h"
#include "util/ralloc.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static bool
ao46_mesa_compute_pipeline_is_empty(const struct AO46MesaComputePipeline *pipeline)
{
   return pipeline && !pipeline->metal_pipeline.adapter &&
          !pipeline->metal_pipeline.native_pipeline &&
          !pipeline->metal_pipeline.native_classic_pipeline &&
          !pipeline->msl_source &&
          !pipeline->entrypoint &&
          pipeline->reflection.local_size[0] == 0 &&
          pipeline->reflection.local_size[1] == 0 &&
          pipeline->reflection.local_size[2] == 0 &&
          pipeline->reflection.required_buffer_mask == 0 &&
          pipeline->reflection.thread_execution_width == 0 &&
          pipeline->reflection.max_threads_per_threadgroup == 0;
}

/* Reflect every direct KK buffer root before NIR-to-MSL fixes its ABI. */
static bool
ao46_mesa_compute_collect_static_buffer_bindings(const struct nir_shader *nir,
                                                 uint16_t *out_mask)
{
   uint16_t mask = 0;

   if (!nir || !out_mask)
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
            if (binding == 0)
               continue;
            if (binding < 2 ||
                binding >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS)
               return false;

            mask |= UINT16_C(1) << binding;
         }
      }
   }

   *out_mask = mask;
   return true;
}

struct AO46MesaBoundedSSBOLowering {
   struct hash_table *range_ht;
   bool valid;
   bool lowered;
};

static bool
ao46_mesa_ssbo_index_upper_bound(nir_shader *nir,
                                 struct hash_table *range_ht,
                                 nir_src index_src, uint32_t *out_upper_bound)
{
   uint32_t upper_bound;

   if (!nir || !range_ht || !index_src.ssa || !out_upper_bound ||
       index_src.ssa->num_components != 1 || index_src.ssa->bit_size > 32)
      return false;

   upper_bound = nir_src_is_const(index_src)
                    ? nir_src_as_uint(index_src)
                    : nir_unsigned_upper_bound(
                         nir, range_ht, nir_get_scalar(index_src.ssa, 0));
   if (upper_bound >= AO46_MESA_MAX_SHADER_BUFFERS)
      return false;

   *out_upper_bound = upper_bound;
   return true;
}

static bool
ao46_mesa_lower_bounded_ssbo_address(nir_builder *builder,
                                     nir_intrinsic_instr *intrinsic,
                                     void *data)
{
   struct AO46MesaBoundedSSBOLowering *lowering = data;
   uint32_t upper_bound;
   nir_def *index;
   nir_def *root;

   if (intrinsic->intrinsic != nir_intrinsic_load_ssbo_address)
      return false;

   if (!nir_src_is_const(intrinsic->src[1]) ||
       nir_src_as_uint(intrinsic->src[1]) != 0) {
      lowering->valid = false;
      return false;
   }

   if (!ao46_mesa_ssbo_index_upper_bound(builder->shader, lowering->range_ht,
                                          intrinsic->src[0], &upper_bound)) {
      lowering->valid = false;
      return false;
   }

   builder->cursor = nir_before_instr(&intrinsic->instr);
   index = nir_u2u32(builder, intrinsic->src[0].ssa);
   root = nir_load_buffer_ptr_kk(builder, 1, 64, .binding = 2);
   for (uint32_t ssbo_index = 1; ssbo_index <= upper_bound; ++ssbo_index) {
      nir_def *candidate =
         nir_load_buffer_ptr_kk(builder, 1, 64, .binding = ssbo_index + 2);

      root = nir_bcsel(builder, nir_ieq_imm(builder, index, ssbo_index),
                       candidate, root);
   }
   nir_def_rewrite_uses(&intrinsic->def, root);
   nir_instr_remove(&intrinsic->instr);
   lowering->lowered = true;
   return true;
}

/*
 * Mesa lowers SSBO operations to global memory. AO46 maps each statically
 * bounded index range onto direct Metal buffer roots and selects the root in
 * NIR. Unbounded indexing and robust-size queries stay fail-closed until a
 * descriptor-table size contract exists in the Gallium state path.
 */
static bool
ao46_mesa_compute_lower_bounded_ssbo(nir_shader *nir)
{
   struct AO46MesaBoundedSSBOLowering lowering = {
      .range_ht = _mesa_pointer_hash_table_create(NULL),
      .valid = true,
   };
   bool has_ssbo = false;
   bool lowered = false;

   if (!nir || !lowering.range_ht)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_intrinsic_instr *intrinsic;
            unsigned index_src;

            if (instr->type != nir_instr_type_intrinsic)
               continue;

            intrinsic = nir_instr_as_intrinsic(instr);
            switch (intrinsic->intrinsic) {
            case nir_intrinsic_load_ssbo:
            case nir_intrinsic_ssbo_atomic:
            case nir_intrinsic_ssbo_atomic_swap:
               index_src = 0;
               break;
            case nir_intrinsic_store_ssbo:
               index_src = 1;
               break;
            case nir_intrinsic_get_ssbo_size:
            case nir_intrinsic_load_ssbo_address:
               goto out;
            default:
               continue;
            }

            uint32_t upper_bound;

            if (!ao46_mesa_ssbo_index_upper_bound(
                   nir, lowering.range_ht, intrinsic->src[index_src],
                   &upper_bound))
               goto out;
            has_ssbo = true;
         }
      }
   }

   if (!has_ssbo) {
      lowered = true;
      goto out;
   }

   (void)nir_lower_ssbo(nir, NULL);
   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_bounded_ssbo_address, nir_metadata_control_flow,
      &lowering);
   lowered = lowering.valid && lowering.lowered;

out:
   _mesa_hash_table_destroy(lowering.range_ht, NULL);
   return lowered;
}

bool
AO46MesaNIRLowerBoundedSSBOs(struct nir_shader *nir,
                            uint16_t *out_static_buffer_mask)
{
   uint16_t static_buffer_mask;

   if (!nir || !out_static_buffer_mask ||
       !ao46_mesa_compute_lower_bounded_ssbo(nir) ||
       !ao46_mesa_compute_collect_static_buffer_bindings(
          nir, &static_buffer_mask))
      return false;

   *out_static_buffer_mask = static_buffer_mask;
   return true;
}

struct AO46MesaImageLowering {
   uint16_t image_mask;
   bool valid;
};

static bool
ao46_mesa_lower_static_image(nir_builder *builder,
                             nir_intrinsic_instr *intrinsic, void *data)
{
   struct AO46MesaImageLowering *lowering = data;
   nir_deref_instr *deref;
   nir_variable *variable;
   nir_def *texture_index;
   unsigned binding;

   switch (intrinsic->intrinsic) {
   case nir_intrinsic_image_deref_load:
   case nir_intrinsic_image_deref_store:
   case nir_intrinsic_image_deref_atomic:
   case nir_intrinsic_image_deref_atomic_swap:
      break;
   default:
      return false;
   }

   deref = nir_src_as_deref(intrinsic->src[0]);
   variable = deref ? nir_deref_instr_get_variable(deref) : NULL;
   if (!deref || deref->deref_type != nir_deref_type_var || !variable ||
       variable->data.mode != nir_var_image ||
       variable->data.binding >= AO46_MESA_MAX_IMAGE_UNITS) {
      lowering->valid = false;
      return false;
   }

   binding = variable->data.binding;
   builder->cursor = nir_before_instr(&intrinsic->instr);
   texture_index = nir_imm_int(builder, AO46_MESA_IMAGE_TEXTURE_BASE + binding);
   nir_rewrite_image_intrinsic(intrinsic, texture_index,
                               nir_image_intrinsic_type_default);
   lowering->image_mask |= UINT16_C(1) << binding;
   return true;
}

bool
AO46MesaNIRLowerStaticImages(struct nir_shader *nir,
                            uint16_t *inout_static_buffer_mask,
                            uint16_t *out_image_mask)
{
   struct AO46MesaImageLowering lowering = {.valid = true};

   if (!nir || !inout_static_buffer_mask || !out_image_mask)
      return false;

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_static_image, nir_metadata_control_flow, &lowering);
   if (!lowering.valid)
      return false;

   (void)inout_static_buffer_mask;
   *out_image_mask = lowering.image_mask;
   return true;
}

struct AO46MesaDrawParameterLowering {
   bool uses_draw_id;
   bool uses_parameters;
};

static nir_def *
ao46_mesa_load_draw_parameter(nir_builder *builder, unsigned byte_offset)
{
   nir_def *root = nir_load_buffer_ptr_kk(
      builder, 1, 64, .binding = AO46_MESA_DRAW_PARAMETER_BINDING);

   return nir_load_global(builder, 1, 32,
                          nir_iadd_imm(builder, root, byte_offset),
                          .align_mul = sizeof(uint32_t));
}

static bool
ao46_mesa_lower_draw_parameter(nir_builder *builder,
                               nir_intrinsic_instr *intrinsic, void *data)
{
   struct AO46MesaDrawParameterLowering *lowering = data;
   nir_def *replacement;

   switch (intrinsic->intrinsic) {
   case nir_intrinsic_load_draw_id: {
      builder->cursor = nir_before_instr(&intrinsic->instr);
      replacement = ao46_mesa_load_draw_parameter(
         builder, offsetof(struct AO46MesaDrawParameters, draw_id));
      lowering->uses_draw_id = true;
      lowering->uses_parameters = true;
      break;
   }
   case nir_intrinsic_load_base_vertex:
      builder->cursor = nir_before_instr(&intrinsic->instr);
      replacement = ao46_mesa_load_draw_parameter(
         builder, offsetof(struct AO46MesaDrawParameters, base_vertex));
      lowering->uses_parameters = true;
      break;
   case nir_intrinsic_load_base_instance:
      builder->cursor = nir_before_instr(&intrinsic->instr);
      replacement = ao46_mesa_load_draw_parameter(
         builder, offsetof(struct AO46MesaDrawParameters, base_instance));
      lowering->uses_parameters = true;
      break;
   default:
      return false;
   }

   nir_def_rewrite_uses(&intrinsic->def, replacement);
   nir_instr_remove(&intrinsic->instr);
   return true;
}

bool
AO46MesaNIRLowerDrawParameters(struct nir_shader *nir,
                              uint16_t *inout_static_buffer_mask,
                              bool *out_uses_draw_id)
{
   struct AO46MesaDrawParameterLowering lowering = {0};

   if (!nir || !inout_static_buffer_mask || !out_uses_draw_id)
      return false;

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_draw_parameter, nir_metadata_control_flow,
      &lowering);
   if (lowering.uses_parameters)
      *inout_static_buffer_mask |=
         UINT16_C(1) << AO46_MESA_DRAW_PARAMETER_BINDING;
   *out_uses_draw_id = lowering.uses_draw_id;
   return true;
}

struct AO46MesaStreamOutputLowering {
   const struct pipe_stream_output_info *info;
   bool valid;
   bool lowered;
};

static bool
ao46_mesa_lower_stream_output_store(nir_builder *builder,
                                    nir_intrinsic_instr *intrinsic, void *data)
{
   struct AO46MesaStreamOutputLowering *lowering = data;
   unsigned register_index;

   if (intrinsic->intrinsic != nir_intrinsic_store_output)
      return false;

   if (!nir_src_is_const(intrinsic->src[1]))
      return false;

   register_index = nir_intrinsic_base(intrinsic) +
                    nir_src_as_uint(intrinsic->src[1]);

   for (unsigned i = 0; i < lowering->info->num_outputs; ++i) {
      const struct pipe_stream_output *output = &lowering->info->output[i];
      nir_def *descriptor_root;
      nir_def *target_address;
      nir_def *draw_root;
      nir_def *vertex_count;
      nir_def *first_vertex;
      nir_def *base_instance;
      nir_def *vertex_index;
      nir_def *instance_index;
      nir_def *linear_index;
      nir_def *byte_offset;
      nir_def *value;

      if (output->register_index != register_index)
         continue;
      if (nir_intrinsic_component(intrinsic) != 0 ||
          intrinsic->src[0].ssa->num_components > 4 || output->stream != 0 ||
          output->output_buffer >= PIPE_MAX_SO_BUFFERS ||
          output->num_components == 0 ||
          output->start_component + output->num_components >
             intrinsic->src[0].ssa->num_components ||
          lowering->info->stride[output->output_buffer] == 0) {
         lowering->valid = false;
         return false;
      }

      builder->cursor = nir_before_instr(&intrinsic->instr);
      descriptor_root = nir_load_buffer_ptr_kk(
         builder, 1, 64,
         .binding = AO46_MESA_STREAM_OUTPUT_DESCRIPTOR_BINDING);
      target_address = nir_load_global(
         builder, 1, 64,
         nir_iadd_imm(builder, descriptor_root,
                      output->output_buffer * sizeof(uint64_t)),
         .align_mul = sizeof(uint64_t));
      draw_root = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = AO46_MESA_DRAW_PARAMETER_BINDING);
      vertex_count = nir_load_global(
         builder, 1, 32,
         nir_iadd_imm(builder, draw_root, sizeof(uint32_t)),
         .align_mul = sizeof(uint32_t));
      first_vertex = nir_load_global(
         builder, 1, 32,
         nir_iadd_imm(builder, draw_root, 2 * sizeof(uint32_t)),
         .align_mul = sizeof(uint32_t));
      base_instance = nir_load_global(
         builder, 1, 32,
         nir_iadd_imm(builder, draw_root, 3 * sizeof(uint32_t)),
         .align_mul = sizeof(uint32_t));
      vertex_index = nir_isub(builder, nir_load_vertex_id(builder), first_vertex);
      instance_index =
         nir_isub(builder, nir_load_instance_id(builder), base_instance);
      linear_index = nir_iadd(
         builder, nir_imul(builder, instance_index, vertex_count), vertex_index);
      byte_offset = nir_iadd_imm(
         builder,
         nir_imul_imm(builder, nir_u2u64(builder, linear_index),
                      lowering->info->stride[output->output_buffer] *
                         sizeof(uint32_t)),
         output->dst_offset * sizeof(uint32_t));
      value = nir_channels(
         builder, intrinsic->src[0].ssa,
         BITFIELD_RANGE(output->start_component, output->num_components));
      nir_store_global(builder, value,
                       nir_iadd(builder, target_address, byte_offset),
                       .align_mul = sizeof(uint32_t),
                       .access = ACCESS_NON_READABLE);
      lowering->lowered = true;
   }

   return false;
}

bool
AO46MesaNIRLowerStreamOutput(
   struct nir_shader *nir, const struct pipe_stream_output_info *stream_output,
   uint16_t *inout_static_buffer_mask)
{
   struct AO46MesaStreamOutputLowering lowering = {
      .info = stream_output,
      .valid = true,
   };

   if (!nir || !stream_output || !inout_static_buffer_mask ||
       nir->info.stage != MESA_SHADER_VERTEX ||
       stream_output->num_outputs > PIPE_MAX_SO_OUTPUTS)
      return false;
   if (stream_output->num_outputs == 0)
      return true;

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_stream_output_store, nir_metadata_control_flow,
      &lowering);
   if (!lowering.valid || !lowering.lowered)
      return false;

   *inout_static_buffer_mask |=
      (UINT16_C(1) << AO46_MESA_DRAW_PARAMETER_BINDING) |
      (UINT16_C(1) << AO46_MESA_STREAM_OUTPUT_DESCRIPTOR_BINDING);
   return true;
}

bool
AO46MesaComputePipelineCreate(const struct AO46MetalAdapter *adapter,
                              struct nir_shader *nir,
                              struct AO46MesaComputePipeline *out_pipeline)
{
   uint16_t static_buffer_mask;

   if (!AO46MesaNIRLowerBoundedSSBOs(nir, &static_buffer_mask))
      return false;

   return AO46MesaComputePipelineCreateWithStaticBuffers(
      adapter, nir, static_buffer_mask, out_pipeline);
}

bool
AO46MesaComputePipelineCreateWithStaticBuffers(
   const struct AO46MetalAdapter *adapter, struct nir_shader *nir,
   uint16_t static_buffer_mask,
   struct AO46MesaComputePipeline *out_pipeline)
{
   struct nir_to_msl_options options = {0};
   nir_function_impl *entrypoint;
   void *msl_context = NULL;
   char *msl = NULL;
   char *source = NULL;
   char *entrypoint_name = NULL;
   bool created = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !nir ||
       nir->info.stage != MESA_SHADER_COMPUTE || !out_pipeline ||
       !ao46_mesa_compute_pipeline_is_empty(out_pipeline) ||
       nir->info.workgroup_size[0] == 0 || nir->info.workgroup_size[1] == 0 ||
       nir->info.workgroup_size[2] == 0 || (static_buffer_mask & UINT16_C(0x0003)))
      return false;

   /* These are Mesa's standard KosmicKrisp preprocessing and SSA-lowering passes. */
   msl_preprocess_nir(nir);
   /* Mesa reports whether this optimization changed NIR, not success/failure. */
   (void)msl_optimize_nir(nir);

   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
   msl_context = ralloc_context(NULL);
   if (!msl_context)
      return false;

   options.mem_ctx = msl_context;
   options.static_buffer_mask = static_buffer_mask;
   msl = nir_to_msl(nir, &options);
   entrypoint = nir_shader_get_entrypoint(nir);
   if (!msl || !entrypoint || !entrypoint->function ||
       !entrypoint->function->name)
      goto out;

   source = strdup(msl);
   entrypoint_name = strdup(entrypoint->function->name);
   if (!source || !entrypoint_name ||
       !AO46MetalComputePipelineCreate(adapter, source, entrypoint_name,
                                       &out_pipeline->metal_pipeline))
      goto out;

   out_pipeline->msl_source = source;
   out_pipeline->entrypoint = entrypoint_name;
   out_pipeline->reflection = (struct AO46MesaComputeReflection){
      .local_size = {
         nir->info.workgroup_size[0],
         nir->info.workgroup_size[1],
         nir->info.workgroup_size[2],
      },
      /* KosmicKrisp emits the root and sampler-table ABI plus direct buffers. */
      .required_buffer_mask = (1u << 0) | (1u << 1) | static_buffer_mask,
      .thread_execution_width = out_pipeline->metal_pipeline.thread_execution_width,
      .max_threads_per_threadgroup =
         out_pipeline->metal_pipeline.max_threads_per_threadgroup,
   };
   source = NULL;
   entrypoint_name = NULL;
   created = true;

out:
   free(source);
   free(entrypoint_name);
   ralloc_free(msl_context);
   return created;
}

void
AO46MesaComputePipelineDestroy(struct AO46MesaComputePipeline *pipeline)
{
   if (!pipeline)
      return;

   AO46MetalComputePipelineDestroy(&pipeline->metal_pipeline);
   free(pipeline->msl_source);
   free(pipeline->entrypoint);
   *pipeline = (struct AO46MesaComputePipeline){0};
}

bool
AO46MesaComputePipelineDispatch(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, uint32_t resource_count, uint32_t grid_width,
   uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence)
{
   return AO46MesaComputePipelineDispatchWithAccess(
      pipeline, context, resources, offsets, indices, NULL, resource_count,
      grid_width, grid_height, grid_depth, out_fence);
}

bool
AO46MesaComputePipelineDispatchWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumComputeBinding *bindings;
   bool submitted;

   if (!pipeline || !pipeline->metal_pipeline.native_pipeline || !context ||
       !resources || !offsets || !indices || resource_count == 0 ||
       resource_count > 32 || grid_width == 0 || grid_height == 0 ||
       grid_depth == 0 || !out_fence)
      return false;

   bindings = calloc(resource_count, sizeof(*bindings));
   if (!bindings)
      return false;

   for (uint32_t i = 0; i < resource_count; ++i) {
      bindings[i] = (struct AO46MetalGalliumComputeBinding){
         .resource = resources[i],
         .offset = offsets[i],
         .index = indices[i],
         /* Keep older direct callers conservative until they opt in. */
         .writable = writable ? writable[i] : true,
      };
   }

   submitted = AO46MetalGalliumComputeDispatch(
      context, &pipeline->metal_pipeline, bindings, resource_count, grid_width,
      grid_height, grid_depth, pipeline->reflection.local_size[0],
      pipeline->reflection.local_size[1], pipeline->reflection.local_size[2],
      out_fence);
   free(bindings);
   return submitted;
}

bool
AO46MesaComputePipelineDispatchIndirectWithAccess(
   const struct AO46MesaComputePipeline *pipeline, struct pipe_context *context,
   struct pipe_resource *const *resources, const uint32_t *offsets,
   const uint32_t *indices, const bool *writable, uint32_t resource_count,
   struct pipe_resource *indirect_resource, size_t indirect_offset,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumComputeBinding *bindings;
   bool submitted;

   if (!pipeline || !pipeline->metal_pipeline.native_classic_pipeline ||
       !context || !resources || !offsets || !indices || resource_count == 0 ||
       resource_count > 32 || !indirect_resource || !out_fence)
      return false;

   bindings = calloc(resource_count, sizeof(*bindings));
   if (!bindings)
      return false;

   for (uint32_t i = 0; i < resource_count; ++i) {
      bindings[i] = (struct AO46MetalGalliumComputeBinding){
         .resource = resources[i],
         .offset = offsets[i],
         .index = indices[i],
         .writable = writable ? writable[i] : true,
      };
   }

   submitted = AO46MetalGalliumComputeDispatchIndirect(
      context, &pipeline->metal_pipeline, bindings, resource_count,
      indirect_resource, indirect_offset, pipeline->reflection.local_size[0],
      pipeline->reflection.local_size[1], pipeline->reflection.local_size[2],
      out_fence);
   free(bindings);
   return submitted;
}
