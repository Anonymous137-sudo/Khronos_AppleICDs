/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaNIRBufferTexture.h"

#include "AO46MesaMSLRenderPipeline.h"

#include "pipe/p_state.h"

bool
AO46MesaRGB32BufferTextureBindingIsValid(
   const struct AO46MesaRGB32BufferTextureBinding *binding)
{
   return binding && binding->buffer_binding >= 2 &&
          binding->buffer_binding < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS &&
          binding->element_count != 0 &&
          binding->element_count <= UINT32_MAX / (3 * sizeof(uint32_t)) &&
          binding->kind <= AO46_MESA_RGB32_BUFFER_TEXTURE_SINT;
}

bool
AO46MesaRGB32BufferTextureBindingFromSamplerView(
   const struct pipe_sampler_view *view, unsigned texture_index,
   unsigned buffer_binding, struct AO46MesaRGB32BufferTextureBinding *out_binding)
{
   enum AO46MesaRGB32BufferTextureKind kind;
   uint64_t offset;
   uint64_t size;
   uint64_t texture_size;
   struct AO46MesaRGB32BufferTextureBinding binding;

   if (!view || !view->texture || !out_binding ||
       view->target != PIPE_BUFFER || view->texture->target != PIPE_BUFFER ||
       view->format != view->texture->format ||
       view->swizzle_r != PIPE_SWIZZLE_X ||
       view->swizzle_g != PIPE_SWIZZLE_Y ||
       view->swizzle_b != PIPE_SWIZZLE_Z ||
       view->swizzle_a != PIPE_SWIZZLE_W)
      return false;

   switch (view->format) {
   case PIPE_FORMAT_R32G32B32_FLOAT:
      kind = AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT;
      break;
   case PIPE_FORMAT_R32G32B32_UINT:
      kind = AO46_MESA_RGB32_BUFFER_TEXTURE_UINT;
      break;
   case PIPE_FORMAT_R32G32B32_SINT:
      kind = AO46_MESA_RGB32_BUFFER_TEXTURE_SINT;
      break;
   default:
      return false;
   }

   texture_size = view->texture->width0;
   offset = view->u.buf.offset;
   if (offset >= texture_size)
      return false;

   size = view->u.buf.size ? view->u.buf.size : texture_size - offset;
   if (size == 0 || size > texture_size - offset ||
       offset % (3 * sizeof(uint32_t)) != 0 ||
       size % (3 * sizeof(uint32_t)) != 0 ||
       size / (3 * sizeof(uint32_t)) > UINT32_MAX)
      return false;

   binding = (struct AO46MesaRGB32BufferTextureBinding){
      .texture_index = texture_index,
      .buffer_binding = buffer_binding,
      .element_count = (uint32_t)(size / (3 * sizeof(uint32_t))),
      .kind = kind,
   };
   if (!AO46MesaRGB32BufferTextureBindingIsValid(&binding))
      return false;

   *out_binding = binding;
   return true;
}

bool
AO46MesaRGB32BufferTextureBindingsMask(
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, uint16_t *out_static_buffer_mask)
{
   uint16_t mask = 0;

   if (!bindings || binding_count == 0 || !out_static_buffer_mask)
      return false;

   for (uint32_t i = 0; i < binding_count; ++i) {
      const struct AO46MesaRGB32BufferTextureBinding *binding = &bindings[i];
      uint16_t bit;

      if (!AO46MesaRGB32BufferTextureBindingIsValid(binding))
         return false;

      bit = UINT16_C(1) << binding->buffer_binding;
      if (mask & bit)
         return false;

      for (uint32_t j = 0; j < i; ++j) {
         if (bindings[j].texture_index == binding->texture_index)
            return false;
      }

      mask |= bit;
   }

   *out_static_buffer_mask = mask;
   return true;
}

bool
AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
   struct pipe_sampler_view *const *views, uint16_t selected_slot_mask,
   struct AO46MesaRGB32BufferTextureBinding *out_bindings,
   uint32_t binding_capacity, uint32_t *out_binding_count)
{
   uint16_t observed_mask;
   uint32_t binding_count = 0;

   if (!views || selected_slot_mask == 0 || !out_bindings ||
       binding_capacity == 0 || !out_binding_count)
      return false;

   for (unsigned slot = 0; slot < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS; ++slot) {
      if (!(selected_slot_mask & (UINT16_C(1) << slot)))
         continue;
      if (binding_count == binding_capacity ||
          !AO46MesaRGB32BufferTextureBindingFromSamplerView(
             views[slot], slot, slot, &out_bindings[binding_count]))
         return false;
      ++binding_count;
   }

   if (binding_count == 0 ||
       !AO46MesaRGB32BufferTextureBindingsMask(
          out_bindings, binding_count, &observed_mask) ||
       observed_mask != selected_slot_mask)
      return false;

   *out_binding_count = binding_count;
   return true;
}
