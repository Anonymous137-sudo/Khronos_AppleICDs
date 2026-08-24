/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaNIRBufferTexture.h"

#include "AO46MesaMSLRenderPipeline.h"

#include "nir.h"
#include "nir_builder.h"
#include "nir_intrinsics.h"

bool
AO46MesaRGB32BufferTextureRequirements(
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, struct AO46MesaStaticBufferRequirement *out_requirements,
   uint32_t requirement_capacity, uint32_t *out_requirement_count)
{
   uint16_t mask;

   if (!AO46MesaRGB32BufferTextureBindingsMask(bindings, binding_count, &mask) ||
       !out_requirements || requirement_capacity < binding_count ||
       !out_requirement_count)
      return false;

   for (uint32_t i = 0; i < binding_count; ++i) {
      const struct AO46MesaRGB32BufferTextureBinding *binding = &bindings[i];
      const size_t minimum_size =
         (size_t)binding->element_count * 3 * sizeof(uint32_t);

      if (minimum_size == 0 ||
          (mask & (UINT16_C(1) << binding->buffer_binding)) == 0)
         return false;

      out_requirements[i] = (struct AO46MesaStaticBufferRequirement){
         .binding = binding->buffer_binding,
         .minimum_size = minimum_size,
      };
   }

   *out_requirement_count = binding_count;
   return true;
}

bool
AO46MesaNIRCollectRGB32BufferTextureSlots(const struct nir_shader *nir,
                                          uint16_t *out_slot_mask)
{
   uint16_t slot_mask = 0;

   if (!nir || !out_slot_mask)
      return false;

   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            nir_tex_instr *tex;

            if (instr->type != nir_instr_type_tex)
               continue;

            tex = nir_instr_as_tex(instr);
            if (tex->sampler_dim != GLSL_SAMPLER_DIM_BUF)
               continue;

            if (tex->texture_index >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
                tex->op != nir_texop_txf || tex->is_sparse ||
                nir_tex_instr_src_index(tex, nir_tex_src_texture_handle) >= 0 ||
                nir_tex_instr_src_index(tex, nir_tex_src_texture_deref) >= 0)
               return false;

            slot_mask |= UINT16_C(1) << tex->texture_index;
         }
      }
   }

   if (slot_mask == 0)
      return false;

   *out_slot_mask = slot_mask;
   return true;
}

struct AO46MesaRGB32BufferTextureLowering {
   const struct AO46MesaRGB32BufferTextureBinding *bindings;
   uint32_t binding_count;
   uint32_t lowered_texture_mask;
   unsigned address_table_binding;
   bool use_address_table;
};

static const struct AO46MesaRGB32BufferTextureBinding *
ao46_mesa_rgb32_find_binding(
   const struct AO46MesaRGB32BufferTextureLowering *lowering,
   unsigned texture_index)
{
   for (uint32_t i = 0; i < lowering->binding_count; ++i) {
      if (lowering->bindings[i].texture_index == texture_index)
         return &lowering->bindings[i];
   }

   return NULL;
}

static bool
ao46_mesa_rgb32_type_matches(const struct nir_tex_instr *tex,
                             enum AO46MesaRGB32BufferTextureKind kind)
{
   const nir_alu_type type = nir_alu_type_get_base_type(tex->dest_type);

   switch (kind) {
   case AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT:
      return type == nir_type_float;
   case AO46_MESA_RGB32_BUFFER_TEXTURE_UINT:
      return type == nir_type_uint;
   case AO46_MESA_RGB32_BUFFER_TEXTURE_SINT:
      return type == nir_type_int;
   }

   return false;
}

static nir_def *
ao46_mesa_rgb32_default_texel(nir_builder *builder,
                              enum AO46MesaRGB32BufferTextureKind kind,
                              bool alpha)
{
   if (kind == AO46_MESA_RGB32_BUFFER_TEXTURE_FLOAT)
      return nir_imm_float(builder, alpha ? 1.0f : 0.0f);

   return nir_imm_int(builder, alpha ? 1 : 0);
}

static nir_def *
ao46_mesa_rgb32_vec4(nir_builder *builder, nir_def *rgb,
                     enum AO46MesaRGB32BufferTextureKind kind)
{
   return nir_vec4(builder, nir_channel(builder, rgb, 0),
                   nir_channel(builder, rgb, 1), nir_channel(builder, rgb, 2),
                   ao46_mesa_rgb32_default_texel(builder, kind, true));
}

static bool
ao46_mesa_lower_rgb32_buffer_texture(nir_builder *builder, nir_instr *instr,
                                     void *data)
{
   struct AO46MesaRGB32BufferTextureLowering *lowering = data;
   nir_tex_instr *tex;
   const struct AO46MesaRGB32BufferTextureBinding *binding;
   nir_def *coord_src;
   nir_def *coord;
   nir_def *root;
   nir_def *address;
   nir_def *in_bounds;
   nir_def *out_of_bounds;
   nir_def *value;
   nir_if *nif;

   if (instr->type != nir_instr_type_tex)
      return false;

   tex = nir_instr_as_tex(instr);
   binding = ao46_mesa_rgb32_find_binding(lowering, tex->texture_index);
   if (!binding || tex->op != nir_texop_txf ||
       tex->sampler_dim != GLSL_SAMPLER_DIM_BUF || tex->is_sparse ||
       tex->def.num_components != 4 || tex->def.bit_size != 32 ||
       !ao46_mesa_rgb32_type_matches(tex, binding->kind) ||
       nir_tex_instr_src_index(tex, nir_tex_src_texture_handle) >= 0 ||
       nir_tex_instr_src_index(tex, nir_tex_src_texture_deref) >= 0)
      return false;

   coord_src = nir_get_tex_src(tex, nir_tex_src_coord);
   if (!coord_src || coord_src->num_components != 1 ||
       coord_src->bit_size != 32)
      return false;

   builder->cursor = nir_before_instr(instr);
   coord = nir_u2u32(builder, coord_src);
   if (lowering->use_address_table) {
      nir_def *table = nir_load_buffer_ptr_kk(
         builder, 1, 64, .binding = lowering->address_table_binding);
      nir_def *entry = nir_iadd_imm(
         builder, table, binding->texture_index * sizeof(uint64_t));
      root = nir_load_global(builder, 1, 64, entry,
                             .align_mul = sizeof(uint64_t),
                             .access = ACCESS_NON_WRITEABLE);
   } else {
      root = nir_load_buffer_ptr_kk(builder, 1, 64,
                                    .binding = binding->buffer_binding);
   }
   address = nir_iadd(
      builder, root,
      nir_u2u64(builder, nir_imul_imm(builder, coord, 3 * sizeof(uint32_t))));

   /* Keep direct loads in-bounds while preserving the robust zero texel. */
   nif = nir_push_if(builder,
                     nir_ult(builder, coord,
                             nir_imm_int(builder, binding->element_count)));
   value = ao46_mesa_rgb32_vec4(
      builder,
      nir_load_global(builder, 3, 32, address, .align_mul = sizeof(uint32_t),
                      .access = ACCESS_NON_WRITEABLE),
      binding->kind);
   nir_push_else(builder, nif);
   out_of_bounds = nir_vec4(
      builder, ao46_mesa_rgb32_default_texel(builder, binding->kind, false),
      ao46_mesa_rgb32_default_texel(builder, binding->kind, false),
      ao46_mesa_rgb32_default_texel(builder, binding->kind, false),
      ao46_mesa_rgb32_default_texel(builder, binding->kind, true));
   nir_pop_if(builder, nif);
   in_bounds = nir_if_phi(builder, value, out_of_bounds);

   nir_def_rewrite_uses(&tex->def, in_bounds);
   nir_instr_remove(&tex->instr);
   lowering->lowered_texture_mask |= UINT32_C(1) << binding->texture_index;
   return true;
}

static bool
ao46_mesa_rgb32_texture_mask(
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, uint32_t *out_mask)
{
   uint32_t mask = 0;

   if (!bindings || binding_count == 0 || !out_mask)
      return false;

   for (uint32_t i = 0; i < binding_count; ++i) {
      const struct AO46MesaRGB32BufferTextureBinding *binding = &bindings[i];
      uint32_t bit;

      if (!AO46MesaRGB32BufferTextureBindingIsValid(binding) ||
          binding->texture_index >= 32)
         return false;
      bit = UINT32_C(1) << binding->texture_index;
      if (mask & bit)
         return false;
      mask |= bit;
   }

   *out_mask = mask;
   return true;
}

bool
AO46MesaNIRLowerRGB32BufferTextures(
   struct nir_shader *nir,
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count)
{
   struct AO46MesaRGB32BufferTextureLowering lowering = {
      .bindings = bindings,
      .binding_count = binding_count,
   };
   uint16_t required_mask;
   uint32_t required_texture_mask;
   bool progress;

   if (!nir || !AO46MesaRGB32BufferTextureBindingsMask(bindings, binding_count,
                                                         &required_mask) ||
       !ao46_mesa_rgb32_texture_mask(bindings, binding_count,
                                     &required_texture_mask))
      return false;

   progress = nir_shader_instructions_pass(
      nir, ao46_mesa_lower_rgb32_buffer_texture, nir_metadata_none, &lowering);
   return progress && required_mask != 0 &&
          lowering.lowered_texture_mask == required_texture_mask;
}

bool
AO46MesaNIRLowerRGB32BufferTexturesWithAddressTable(
   struct nir_shader *nir,
   const struct AO46MesaRGB32BufferTextureBinding *bindings,
   uint32_t binding_count, unsigned address_table_binding)
{
   struct AO46MesaRGB32BufferTextureLowering lowering = {
      .bindings = bindings,
      .binding_count = binding_count,
      .address_table_binding = address_table_binding,
      .use_address_table = true,
   };
   uint32_t required_texture_mask;
   bool progress;

   if (!nir || address_table_binding < 2 || address_table_binding >= 16 ||
       !ao46_mesa_rgb32_texture_mask(bindings, binding_count,
                                     &required_texture_mask))
      return false;

   progress = nir_shader_instructions_pass(
      nir, ao46_mesa_lower_rgb32_buffer_texture, nir_metadata_none, &lowering);
   return progress && lowering.lowered_texture_mask == required_texture_mask;
}
