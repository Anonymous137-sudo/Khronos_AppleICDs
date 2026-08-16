/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct nir_shader;
struct pipe_sampler_view;

/* Metal has no packed RGB32 texture format, so these views use an MTLBuffer. */
enum AO46MesaRGB32BufferTextureKind {
   AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT,
   AO46_MESA_RGB32_BUFFER_TEXTURE_UINT,
   AO46_MESA_RGB32_BUFFER_TEXTURE_SINT,
};

struct AO46MesaRGB32BufferTextureBinding {
   unsigned texture_index;
   unsigned buffer_binding;
   uint32_t element_count;
   enum AO46MesaRGB32BufferTextureKind kind;
};

struct AO46MesaStaticBufferRequirement;

bool AO46MesaRGB32BufferTextureBindingIsValid(
   const struct AO46MesaRGB32BufferTextureBinding *binding);

/*
 * Derives the direct-MSL binding from the same PIPE_BUFFER sampler view that
 * Gallium will submit. A view range becomes the buffer root, so texel zero in
 * the lowered shader is always the first texel in that view.
 */
bool AO46MesaRGB32BufferTextureBindingFromSamplerView(
   const struct pipe_sampler_view *view, unsigned texture_index,
   unsigned buffer_binding, struct AO46MesaRGB32BufferTextureBinding *out_binding);

/* Builds a shader-variant binding set from selected Gallium sampler slots. */
bool AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
   struct pipe_sampler_view *const *views, uint16_t selected_slot_mask,
   struct AO46MesaRGB32BufferTextureBinding *out_bindings,
   uint32_t binding_capacity, uint32_t *out_binding_count);

/* Validates and returns the immutable direct-buffer bindings required by MSL. */
bool AO46MesaRGB32BufferTextureBindingsMask(
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, uint16_t *out_static_buffer_mask);

/*
 * Converts Mesa RGB32 view metadata to the exact ranges required by the MSL
 * direct-buffer bindings. This keeps the lowering and submission contracts in
 * lockstep instead of asking callers to restate the packed RGB32 byte count.
 */
bool AO46MesaRGB32BufferTextureRequirements(
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, struct AO46MesaStaticBufferRequirement *out_requirements,
   uint32_t requirement_capacity, uint32_t *out_requirement_count);

/*
 * Finds the static buffer-texture slots used by a Mesa NIR shader. The caller
 * supplies the matching Gallium sampler views when it creates the pipeline.
 */
bool AO46MesaNIRCollectRGB32BufferTextureSlots(const struct nir_shader *nir,
                                               uint16_t *out_slot_mask);

/*
 * Lowers static RGB32 texelFetch NIR to bounded direct global loads. This keeps
 * packed three-component data in its source MTLBuffer, avoiding a fake RGB32
 * Metal texture format or an expansion copy.
 */
bool AO46MesaNIRLowerRGB32BufferTextures(
   struct nir_shader *nir,
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count);
