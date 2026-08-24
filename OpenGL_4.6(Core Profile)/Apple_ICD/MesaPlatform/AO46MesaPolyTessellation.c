/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyTessellation.h"

#include "nir.h"
#include "nir_builder.h"
#include "nir_intrinsics.h"
#include "poly/nir/poly_nir.h"
#include "poly/tessellator.h"

#include <limits.h>
#include <string.h>

enum {
   AO46_MESA_POLY_DRAW_WORDS = 5,
};

static bool
ao46_mesa_poly_tessellation_domain_from_nir(
   enum tess_primitive_mode primitive,
   enum AO46MesaPolyTessellationDomain *out_domain)
{
   if (!out_domain)
      return false;

   switch (primitive) {
   case TESS_PRIMITIVE_TRIANGLES:
      *out_domain = AO46_MESA_POLY_TESSELLATION_TRIANGLES;
      return true;
   case TESS_PRIMITIVE_QUADS:
      *out_domain = AO46_MESA_POLY_TESSELLATION_QUADS;
      return true;
   case TESS_PRIMITIVE_ISOLINES:
      *out_domain = AO46_MESA_POLY_TESSELLATION_ISOLINES;
      return true;
   default:
      return false;
   }
}

static bool
ao46_mesa_poly_size_add(size_t *value, size_t amount)
{
   if (!value || amount > SIZE_MAX - *value)
      return false;

   *value += amount;
   return true;
}

static bool
ao46_mesa_poly_size_mul(uint32_t count, uint32_t stride, size_t *out_size)
{
   if (!out_size || (size_t)count > SIZE_MAX / stride)
      return false;

   *out_size = (size_t)count * stride;
   return true;
}

bool
AO46MesaPolyTessellationPlanCreate(
   const struct nir_shader *tcs, uint32_t input_patch_size,
   uint32_t input_vertex_count, uint32_t instance_count,
   unsigned parameter_buffer_binding,
   struct AO46MesaPolyTessellationPlan *out_plan)
{
   const uint32_t output_patch_size = tcs ? tcs->info.tess.tcs_vertices_out : 0;
   uint32_t patches_per_instance;
   uint32_t nr_patches;
   uint32_t tcs_stride_bytes;
   size_t allocation = 0;
   size_t tcs_buffer_bytes;
   size_t per_patch_u32_bytes;
   enum AO46MesaPolyTessellationDomain domain;

   if (!tcs || !out_plan || tcs->info.stage != MESA_SHADER_TESS_CTRL ||
       input_patch_size == 0 || input_patch_size > 32 ||
       output_patch_size == 0 || output_patch_size > 32 || instance_count == 0 ||
       input_vertex_count == 0 || input_vertex_count % input_patch_size != 0 ||
       parameter_buffer_binding < 2 || parameter_buffer_binding >= 16)
      return false;

   if (!ao46_mesa_poly_tessellation_domain_from_nir(
          tcs->info.tess._primitive_mode, &domain))
      return false;

   patches_per_instance = input_vertex_count / input_patch_size;
   if (patches_per_instance > UINT32_MAX / instance_count ||
       patches_per_instance > UINT32_MAX / output_patch_size)
      return false;
   nr_patches = patches_per_instance * instance_count;
   tcs_stride_bytes = poly_tcs_output_stride(tcs);
   if (tcs_stride_bytes % sizeof(uint32_t) != 0 ||
       !ao46_mesa_poly_size_mul(nr_patches, tcs_stride_bytes,
                                &tcs_buffer_bytes) ||
       !ao46_mesa_poly_size_mul(nr_patches, sizeof(uint32_t),
                                &per_patch_u32_bytes))
      return false;

   *out_plan = (struct AO46MesaPolyTessellationPlan){
      .parameter_buffer_binding = parameter_buffer_binding,
      .parameter_bytes = sizeof(struct poly_tess_params),
      .input_patch_size = input_patch_size,
      .output_patch_size = output_patch_size,
      .domain = domain,
      .patches_per_instance = patches_per_instance,
      .nr_patches = nr_patches,
      .tcs_stride_bytes = tcs_stride_bytes,
      .vertex_grid_width = input_vertex_count,
      .vertex_grid_height = instance_count,
      .tcs_grid_width = patches_per_instance * output_patch_size,
      .tess_grid_width = nr_patches,
      .tcs_buffer_offset = allocation,
      .tcs_buffer_bytes = tcs_buffer_bytes,
      .requires_prefix_sum = true,
      .requires_dynamic_index_heap = true,
   };

   if (!ao46_mesa_poly_size_add(&allocation, tcs_buffer_bytes))
      return false;
   out_plan->coord_allocs_offset = allocation;
   if (!ao46_mesa_poly_size_add(&allocation, per_patch_u32_bytes))
      return false;
   out_plan->counts_offset = allocation;
   if (!ao46_mesa_poly_size_add(&allocation, per_patch_u32_bytes))
      return false;
   out_plan->out_draw_offset = allocation;
   if (!ao46_mesa_poly_size_add(&allocation,
                                AO46_MESA_POLY_DRAW_WORDS * sizeof(uint32_t)))
      return false;

   out_plan->transient_bytes = allocation;
   return true;
}

bool
AO46MesaPolyTessellationPlanFinalize(
   struct AO46MesaPolyTessellationPlan *plan, const struct nir_shader *tes)
{
   enum AO46MesaPolyTessellationDomain domain;

   if (!plan || !tes || tes->info.stage != MESA_SHADER_TESS_EVAL ||
       !ao46_mesa_poly_tessellation_domain_from_nir(
          tes->info.tess._primitive_mode, &domain) || domain != plan->domain)
      return false;

   plan->point_mode = tes->info.tess.point_mode;
   switch (domain) {
   case AO46_MESA_POLY_TESSELLATION_TRIANGLES:
   case AO46_MESA_POLY_TESSELLATION_QUADS:
      plan->output_primitive = plan->point_mode
                                  ? AO46_MESA_POLY_TESSELLATION_OUTPUT_POINTS
                                  : AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES;
      return true;
   case AO46_MESA_POLY_TESSELLATION_ISOLINES:
      /* Isoline evaluation always emits line segments in the Mesa poly path. */
      if (plan->point_mode)
         return false;
      plan->output_primitive = AO46_MESA_POLY_TESSELLATION_OUTPUT_LINES;
      return true;
   default:
      return false;
   }
}

bool
AO46MesaPolyTessellationPlanMatchesTCS(
   const struct AO46MesaPolyTessellationPlan *plan,
   const struct nir_shader *tcs)
{
   enum AO46MesaPolyTessellationDomain domain;

   return plan && tcs && tcs->info.stage == MESA_SHADER_TESS_CTRL &&
          ao46_mesa_poly_tessellation_domain_from_nir(
             tcs->info.tess._primitive_mode, &domain) &&
          domain == plan->domain &&
          tcs->info.tess.tcs_vertices_out == plan->output_patch_size;
}

bool
AO46MesaPolyTessellationPlanMatchesTES(
   const struct AO46MesaPolyTessellationPlan *plan,
   const struct nir_shader *tes)
{
   enum AO46MesaPolyTessellationDomain domain;

   return plan && tes && tes->info.stage == MESA_SHADER_TESS_EVAL &&
          ao46_mesa_poly_tessellation_domain_from_nir(
             tes->info.tess._primitive_mode, &domain) &&
          domain == plan->domain && tes->info.tess.point_mode == plan->point_mode;
}

struct AO46MesaPolyParameterBufferLowering {
   unsigned binding;
};

struct AO46MesaPolyVertexBufferLowering {
   unsigned binding;
   uint64_t outputs;
   int32_t first_vertex;
   uint32_t base_instance;
   uint32_t index_size;
};

static bool
ao46_mesa_lower_poly_parameter_buffer(nir_builder *builder,
                                      nir_intrinsic_instr *intrinsic,
                                      void *data)
{
   const struct AO46MesaPolyParameterBufferLowering *lowering = data;
   nir_def *pointer;

   if (intrinsic->intrinsic != nir_intrinsic_load_tess_param_buffer_poly)
      return false;

   builder->cursor = nir_before_instr(&intrinsic->instr);
   pointer = nir_load_buffer_ptr_kk(builder, 1, 64, .binding = lowering->binding);
   nir_def_rewrite_uses(&intrinsic->def, pointer);
   nir_instr_remove(&intrinsic->instr);
   return true;
}

static void
ao46_mesa_lower_poly_parameter_buffer_for_shader(
   nir_shader *nir, unsigned parameter_buffer_binding)
{
   const struct AO46MesaPolyParameterBufferLowering lowering = {
      .binding = parameter_buffer_binding,
   };

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_poly_parameter_buffer, nir_metadata_none,
      (void *)&lowering);
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
}

static bool
ao46_mesa_lower_poly_vertex_buffer(nir_builder *builder,
                                   nir_intrinsic_instr *intrinsic,
                                   void *data)
{
   const struct AO46MesaPolyVertexBufferLowering *lowering = data;
   nir_def *replacement = NULL;

   builder->cursor = nir_before_instr(&intrinsic->instr);
   switch (intrinsic->intrinsic) {
   case nir_intrinsic_load_vertex_param_buffer_poly:
      replacement = nir_load_buffer_ptr_kk(builder, 1, 64,
                                            .binding = lowering->binding);
      break;
   case nir_intrinsic_load_vs_outputs_poly:
      replacement = nir_imm_int64(builder, lowering->outputs);
      break;
   case nir_intrinsic_load_index_size_poly:
      replacement = nir_imm_intN_t(builder, lowering->index_size,
                                   intrinsic->def.bit_size);
      break;
   case nir_intrinsic_load_first_vertex:
      replacement = nir_imm_intN_t(builder, lowering->first_vertex,
                                   intrinsic->def.bit_size);
      break;
   case nir_intrinsic_load_base_instance:
      replacement = nir_imm_intN_t(builder, lowering->base_instance,
                                   intrinsic->def.bit_size);
      break;
   case nir_intrinsic_load_vertex_id_zero_base:
      replacement = nir_channel(
         builder, nir_load_global_invocation_id(builder, 32), 0);
      break;
   default:
      return false;
   }

   nir_def_rewrite_uses(&intrinsic->def, replacement);
   nir_instr_remove(&intrinsic->instr);
   return true;
}

static void
ao46_mesa_lower_poly_vertex_buffer_for_shader(
   nir_shader *nir, unsigned vertex_parameter_buffer_binding,
   uint64_t vertex_outputs, int32_t first_vertex, uint32_t base_instance,
   uint32_t index_size)
{
   const struct AO46MesaPolyVertexBufferLowering lowering = {
      .binding = vertex_parameter_buffer_binding,
      .outputs = vertex_outputs,
      .first_vertex = first_vertex,
      .base_instance = base_instance,
      .index_size = index_size,
   };

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_poly_vertex_buffer, nir_metadata_none,
      (void *)&lowering);
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
}

bool
AO46MesaPolyTessellationLower(struct nir_shader *tcs, struct nir_shader *tes,
                              unsigned parameter_buffer_binding)
{
   if ((!tcs && !tes) || parameter_buffer_binding < 2 ||
       parameter_buffer_binding >= 16)
      return false;

   if ((tcs && (tcs->info.stage != MESA_SHADER_TESS_CTRL ||
                tcs->info.tess.tcs_vertices_out == 0 ||
                tcs->info.tess.tcs_vertices_out > 32 ||
                !ao46_mesa_poly_tessellation_domain_from_nir(
                   tcs->info.tess._primitive_mode,
                   &(enum AO46MesaPolyTessellationDomain){0}))) ||
       (tes && (tes->info.stage != MESA_SHADER_TESS_EVAL ||
                !ao46_mesa_poly_tessellation_domain_from_nir(
                   tes->info.tess._primitive_mode,
                   &(enum AO46MesaPolyTessellationDomain){0}))) ||
       (tcs && tes &&
        tcs->info.tess._primitive_mode != tes->info.tess._primitive_mode))
      return false;

   if (tcs) {
      const unsigned invocations = tcs->info.tess.tcs_vertices_out;

      (void)poly_nir_lower_tcs(tcs, false);
      tcs->info.stage = MESA_SHADER_COMPUTE;
      tcs->info.workgroup_size[0] = invocations;
      tcs->info.workgroup_size[1] = 1;
      tcs->info.workgroup_size[2] = 1;
      ao46_mesa_lower_poly_parameter_buffer_for_shader(
         tcs, parameter_buffer_binding);
   }

   if (tes) {
      (void)poly_nir_lower_tes(tes, true);
      if (tes->info.stage != MESA_SHADER_VERTEX || !tes->info.vs.tes_poly)
         return false;
      ao46_mesa_lower_poly_parameter_buffer_for_shader(
         tes, parameter_buffer_binding);
   }

   return true;
}

bool
AO46MesaPolyVertexTessellationLower(
   struct nir_shader *vs, struct nir_shader *tcs, struct nir_shader *tes,
   unsigned vertex_parameter_buffer_binding,
   unsigned tessellation_parameter_buffer_binding, uint64_t vertex_outputs,
   int32_t first_vertex, uint32_t base_instance, uint32_t index_size)
{
   const uint16_t workgroup_size[3] = {64, 1, 1};

   if (!vs || !tcs || !tes || vs->info.stage != MESA_SHADER_VERTEX ||
       tcs->info.stage != MESA_SHADER_TESS_CTRL ||
       tes->info.stage != MESA_SHADER_TESS_EVAL || vertex_outputs == 0 ||
       vertex_outputs != vs->info.outputs_written ||
       (tcs->info.inputs_read & ~vertex_outputs) != 0 ||
       vertex_parameter_buffer_binding < 2 ||
       vertex_parameter_buffer_binding >= 16 ||
       vertex_parameter_buffer_binding ==
          tessellation_parameter_buffer_binding)
      return false;

   (void)poly_nir_lower_vs_before_gs(vs);
   vs->info.stage = MESA_SHADER_COMPUTE;
   memset(&vs->info.cs, 0, sizeof(vs->info.cs));
   vs->xfb_info = NULL;
   memcpy(vs->info.workgroup_size, workgroup_size,
          sizeof(vs->info.workgroup_size));
   (void)poly_nir_lower_sw_vs(vs);
   ao46_mesa_lower_poly_vertex_buffer_for_shader(
      vs, vertex_parameter_buffer_binding, vertex_outputs, first_vertex,
      base_instance, index_size);

   if (!AO46MesaPolyTessellationLower(
          tcs, tes, tessellation_parameter_buffer_binding))
      return false;

   ao46_mesa_lower_poly_vertex_buffer_for_shader(
      tcs, vertex_parameter_buffer_binding, vertex_outputs, first_vertex,
      base_instance, index_size);
   memcpy(vs->info.workgroup_size, workgroup_size,
          sizeof(vs->info.workgroup_size));
   return true;
}
