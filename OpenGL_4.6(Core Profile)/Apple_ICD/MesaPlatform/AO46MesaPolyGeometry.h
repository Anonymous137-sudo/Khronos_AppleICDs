/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "poly/geometry.h"
#include "poly/nir/poly_nir.h"

struct nir_shader;

enum {
   AO46_MESA_POLY_GEOMETRY_PARAMS_BINDING = 2,
   AO46_MESA_POLY_VERTEX_PARAMS_BINDING = 3,
   AO46_MESA_POLY_QUERY_SCRATCH_BINDING = 4,
   AO46_MESA_POLY_RO_SINK_BINDING = 5,
};

struct AO46MesaPolyGeometryPrograms {
   struct nir_shader *main;
   struct nir_shader *count;
   struct nir_shader *copy;
   struct nir_shader *pre;
   struct poly_gs_info info;
};

/* Clone and lower one Mesa geometry shader into the poly compute pipeline. */
bool AO46MesaPolyGeometryProgramsCreate(
   const struct nir_shader *source, bool provoking_vertex_last,
   unsigned rasterization_stream,
   struct AO46MesaPolyGeometryPrograms *out_programs);

void AO46MesaPolyGeometryProgramsDestroy(
   struct AO46MesaPolyGeometryPrograms *programs);
