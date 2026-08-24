/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct nir_shader;

/* Mesa's TES domains map to a libkk kernel and a native output topology. */
enum AO46MesaPolyTessellationDomain {
   AO46_MESA_POLY_TESSELLATION_TRIANGLES,
   AO46_MESA_POLY_TESSELLATION_QUADS,
   AO46_MESA_POLY_TESSELLATION_ISOLINES,
};

/* Mesa TES metadata chooses this; the Gallium draw package cannot override it. */
enum AO46MesaPolyTessellationOutputPrimitive {
   AO46_MESA_POLY_TESSELLATION_OUTPUT_INVALID,
   AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES,
   AO46_MESA_POLY_TESSELLATION_OUTPUT_LINES,
   AO46_MESA_POLY_TESSELLATION_OUTPUT_POINTS,
};

/*
 * Mesa poly uses this fixed transient order for direct tessellation draws.
 * The generated index buffer is deliberately excluded: it is sized only after
 * the GPU count and prefix-sum passes have completed.
 */
struct AO46MesaPolyTessellationPlan {
   unsigned parameter_buffer_binding;
   uint32_t parameter_bytes;
   uint32_t input_patch_size;
   uint32_t output_patch_size;
   enum AO46MesaPolyTessellationDomain domain;
   enum AO46MesaPolyTessellationOutputPrimitive output_primitive;
   bool point_mode;
   uint32_t patches_per_instance;
   uint32_t nr_patches;
   uint32_t tcs_stride_bytes;
   uint32_t vertex_grid_width;
   uint32_t vertex_grid_height;
   uint32_t tcs_grid_width;
   uint32_t tess_grid_width;
   size_t tcs_buffer_offset;
   size_t tcs_buffer_bytes;
   size_t coord_allocs_offset;
   size_t counts_offset;
   size_t out_draw_offset;
   size_t transient_bytes;
   bool requires_prefix_sum;
   bool requires_dynamic_index_heap;
};

/* Builds the direct-draw resource and dispatch contract used by Mesa poly. */
bool AO46MesaPolyTessellationPlanCreate(
   const struct nir_shader *tcs, uint32_t input_patch_size,
   uint32_t input_vertex_count, uint32_t instance_count,
   unsigned parameter_buffer_binding,
   struct AO46MesaPolyTessellationPlan *out_plan);

/* Matches the plan to its pre-lowering TES and derives the native topology. */
bool AO46MesaPolyTessellationPlanFinalize(
   struct AO46MesaPolyTessellationPlan *plan, const struct nir_shader *tes);

/* Verifies raw Gallium state objects against the pre-lowering Mesa Poly plan. */
bool AO46MesaPolyTessellationPlanMatchesTCS(
   const struct AO46MesaPolyTessellationPlan *plan,
   const struct nir_shader *tcs);
bool AO46MesaPolyTessellationPlanMatchesTES(
   const struct AO46MesaPolyTessellationPlan *plan,
   const struct nir_shader *tes);

/* Converts Mesa poly's tessellation parameter intrinsic to a direct MTLBuffer. */
bool AO46MesaPolyTessellationLower(struct nir_shader *tcs,
                                   struct nir_shader *tes,
                                   unsigned parameter_buffer_binding);

/* Lowers Mesa's software VS prepass and the TCS gl_in package together. */
bool AO46MesaPolyVertexTessellationLower(
   struct nir_shader *vs, struct nir_shader *tcs, struct nir_shader *tes,
   unsigned vertex_parameter_buffer_binding,
   unsigned tessellation_parameter_buffer_binding,
   uint64_t vertex_outputs, int32_t first_vertex, uint32_t base_instance,
   uint32_t index_size);
