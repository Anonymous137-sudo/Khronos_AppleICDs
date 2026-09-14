/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyGeometry.h"

#include "compiler/glsl_types.h"
#include "nir.h"
#include "nir_builder.h"
#include "nir_intrinsics.h"
#include "poly/nir/poly_nir.h"
#include "util/ralloc.h"

#include <stddef.h>
#include <string.h>

struct AO46MesaPolyGeometryLowering {
   bool provoking_vertex_last;
   unsigned rasterization_stream;
};

struct AO46MesaGeometryOutputNormalization {
   uint64_t written;
};

static void
ao46_mesa_prepare_geometry_io(nir_shader *nir)
{
   /* Poly consumes load/store I/O intrinsics, while Gallium hands AO46
    * dereference-based GLSL I/O.  Perform the representation change while
    * this is still a geometry shader; doing it after poly changes the main
    * program to compute leaves invalid geometry dereferences behind. */
   NIR_PASS(_, nir, nir_lower_variable_initializers, nir_var_function_temp);
   NIR_PASS(_, nir, nir_lower_returns);
   NIR_PASS(_, nir, nir_inline_functions);
   NIR_PASS(_, nir, nir_opt_deref);
   nir_remove_non_entrypoints(nir);
   NIR_PASS(_, nir, nir_lower_io_vars_to_temporaries,
            nir_shader_get_entrypoint(nir), nir_var_shader_out);
   NIR_PASS(_, nir, nir_lower_global_vars_to_local);
   NIR_PASS(_, nir, nir_split_var_copies);
   NIR_PASS(_, nir, nir_split_struct_vars, nir_var_function_temp);
   NIR_PASS(_, nir, nir_split_array_vars, nir_var_function_temp);
   NIR_PASS(_, nir, nir_split_per_member_structs);
   NIR_PASS(_, nir, nir_lower_continue_constructs);
   NIR_PASS(_, nir, nir_lower_frexp);
   NIR_PASS(_, nir, nir_lower_vars_to_ssa);
   NIR_PASS(_, nir, nir_lower_io, nir_var_shader_in | nir_var_shader_out,
            glsl_count_attribute_slots,
            nir_lower_io_lower_64bit_to_32 |
               nir_lower_io_use_interpolated_input_intrinsics);
   NIR_PASS(_, nir, nir_remove_dead_variables, nir_var_function_temp, NULL);
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
}

static bool
ao46_mesa_size_untyped_geometry_output(nir_builder *builder,
                                       nir_intrinsic_instr *intrinsic,
                                       void *data)
{
   struct AO46MesaGeometryOutputNormalization *normalization = data;
   (void)builder;
   if (intrinsic->intrinsic != nir_intrinsic_store_output)
      return false;

   nir_io_semantics semantics = nir_intrinsic_io_semantics(intrinsic);
   if (nir_src_is_const(intrinsic->src[1])) {
      unsigned location = semantics.location + nir_src_as_uint(intrinsic->src[1]);
      if (location < 64)
         normalization->written |= UINT64_C(1) << location;
   }

   if (nir_intrinsic_src_type(intrinsic) != nir_type_invalid)
      return false;

   /* GLSL geometry varyings reaching Gallium are floating-point unless Mesa
    * preserved a more specific integer type on the intrinsic.  Poly needs a
    * sized type to materialize its raster-copy temporaries; the store remains
    * bit preserving. */
   nir_intrinsic_set_src_type(
      intrinsic, nir_type_float | intrinsic->src[0].ssa->bit_size);
   return true;
}

static bool
ao46_mesa_lower_poly_geometry_intrinsic(nir_builder *builder,
                                        nir_intrinsic_instr *intrinsic,
                                        void *data)
{
   const struct AO46MesaPolyGeometryLowering *lowering = data;
   nir_def *replacement = NULL;

   builder->cursor = nir_before_instr(&intrinsic->instr);
   switch (intrinsic->intrinsic) {
   case nir_intrinsic_load_geometry_param_buffer_poly:
      replacement = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = AO46_MESA_POLY_GEOMETRY_PARAMS_BINDING);
      break;
   case nir_intrinsic_load_vertex_param_buffer_poly:
      replacement = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = AO46_MESA_POLY_VERTEX_PARAMS_BINDING);
      break;
   case nir_intrinsic_load_stat_query_address_poly: {
      nir_def *root = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = AO46_MESA_POLY_QUERY_SCRATCH_BINDING);
      replacement = nir_iadd_imm(
         builder, root, nir_intrinsic_base(intrinsic) * sizeof(uint64_t));
      break;
   }
   case nir_intrinsic_load_ro_sink_address_poly:
      replacement = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = AO46_MESA_POLY_RO_SINK_BINDING);
      break;
   case nir_intrinsic_ro_to_rw_poly:
      /* AO46 binds the poly sink as writable Metal storage.  Unlike AGX's
       * protected zero page, no address-space translation is needed. */
      replacement = intrinsic->src[0].ssa;
      break;
   case nir_intrinsic_load_rasterization_stream:
      replacement = nir_imm_intN_t(builder, lowering->rasterization_stream,
                                   intrinsic->def.bit_size);
      break;
   case nir_intrinsic_load_provoking_last:
      replacement = nir_imm_intN_t(builder, lowering->provoking_vertex_last,
                                   intrinsic->def.bit_size);
      break;
   default:
      return false;
   }

   nir_def_rewrite_uses(&intrinsic->def, replacement);
   nir_instr_remove(&intrinsic->instr);
   return true;
}

static void
ao46_mesa_lower_poly_geometry_program(
   nir_shader *nir, const struct AO46MesaPolyGeometryLowering *lowering,
   bool compute)
{
   if (!nir)
      return;

   (void)nir_shader_intrinsics_pass(
      nir, ao46_mesa_lower_poly_geometry_intrinsic, nir_metadata_none,
      (void *)lowering);
   if (compute) {
      const uint16_t workgroup_size[3] = {64, 1, 1};

      nir->info.stage = MESA_SHADER_COMPUTE;
      memset(&nir->info.cs, 0, sizeof(nir->info.cs));
      memcpy(nir->info.workgroup_size, workgroup_size,
             sizeof(nir->info.workgroup_size));
      nir->info.outputs_written = 0;
      nir->info.has_transform_feedback_varyings = false;
      nir->xfb_info = NULL;
      nir->info.inputs_read = 0;
   }
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
}

bool
AO46MesaPolyGeometryProgramsCreate(
   const struct nir_shader *source, bool provoking_vertex_last,
   unsigned rasterization_stream,
   struct AO46MesaPolyGeometryPrograms *out_programs)
{
   struct AO46MesaPolyGeometryLowering lowering = {
      .provoking_vertex_last = provoking_vertex_last,
      .rasterization_stream = rasterization_stream,
   };
   struct AO46MesaPolyGeometryPrograms programs = {0};
   struct AO46MesaGeometryOutputNormalization normalization = {0};

   if (!source || source->info.stage != MESA_SHADER_GEOMETRY ||
       !out_programs || rasterization_stream >= POLY_MAX_VERTEX_STREAMS)
      return false;

   programs.main = nir_shader_clone(NULL, source);
   if (!programs.main)
      goto fail;
   ao46_mesa_prepare_geometry_io(programs.main);
   (void)nir_shader_intrinsics_pass(
      programs.main, ao46_mesa_size_untyped_geometry_output,
      nir_metadata_all, &normalization);
   programs.main->info.outputs_written = normalization.written;
   if (
       !poly_nir_lower_gs(programs.main, &programs.count, &programs.copy,
                          &programs.pre, &programs.info))
      goto fail;

   ao46_mesa_lower_poly_geometry_program(programs.main, &lowering, true);
   ao46_mesa_lower_poly_geometry_program(programs.count, &lowering, true);
   ao46_mesa_lower_poly_geometry_program(programs.pre, &lowering, true);
   ao46_mesa_lower_poly_geometry_program(programs.copy, &lowering, false);
   *out_programs = programs;
   return true;

fail:
   AO46MesaPolyGeometryProgramsDestroy(&programs);
   return false;
}

void
AO46MesaPolyGeometryProgramsDestroy(
   struct AO46MesaPolyGeometryPrograms *programs)
{
   if (!programs)
      return;

   ralloc_free(programs->pre);
   ralloc_free(programs->copy);
   ralloc_free(programs->count);
   ralloc_free(programs->main);
   *programs = (struct AO46MesaPolyGeometryPrograms){0};
}
