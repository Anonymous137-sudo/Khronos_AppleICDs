/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pipe/p_state.h"

struct nir_shader;

#define AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS 32
#define AO46_MESA_VERTEX_INPUT_MAX_BUFFERS 32

/* Native ranges retained by the Metal submission while the VS prepass runs. */
struct AO46MesaVertexBufferRange {
   uint64_t gpu_address;
   size_t offset;
   size_t size;
   bool valid;
};

/* Size of KosmicKrisp's immutable root-table ABI used by vertex fetch. */
size_t AO46MesaVertexInputRootSize(void);

/*
 * Lowers Gallium vertex load_input operations through KosmicKrisp's complete
 * format conversion and robust range logic. The selected direct Metal buffer
 * slot carries the root table built by AO46MesaVertexInputRootBuild.
 */
bool AO46MesaNIRLowerVertexInputs(
   struct nir_shader *nir, const struct pipe_vertex_element *elements,
   unsigned element_count, unsigned root_buffer_binding);

/* Builds the exact root table consumed by AO46MesaNIRLowerVertexInputs. */
bool AO46MesaVertexInputRootBuild(
   void *root, size_t root_size, uint64_t sink_gpu_address,
   uint64_t inputs_read,
   const struct pipe_vertex_element *elements, unsigned element_count,
   const struct AO46MesaVertexBufferRange *buffers, unsigned buffer_count);
