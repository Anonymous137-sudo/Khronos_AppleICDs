/*
 * Copyright 2022 Alyssa Rosenzweig
 * Copyright 2025 LunarG, Inc.
 * Copyright 2025 Google LLC
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaNIRVertexInput.h"

#include "compiler/nir/nir_builder.h"
#include "compiler/nir/nir_format_convert.h"
#include "nir.h"
#include "shader_enums.h"
#include "util/bitscan.h"
#include "util/format/u_format.h"
#include "util/u_math.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>

/* Compact AO46 form of the KosmicKrisp draw root consumed by vertex fetch. */
struct AO46MesaVertexInputRoot {
   uint32_t buffer_strides[AO46_MESA_VERTEX_INPUT_MAX_BUFFERS];
   uint64_t attrib_base[AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS];
   uint32_t attrib_clamps[AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS];
};

struct AO46MesaVertexAttribute {
   uint32_t divisor;
   uint32_t binding;
   enum pipe_format format;
   bool instanced;
};

struct AO46MesaVertexLowering {
   struct AO46MesaVertexAttribute attributes[AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS];
   unsigned root_binding;
};

static bool
ao46_mesa_is_rgb10_a2(const struct util_format_description *desc)
{
   return desc->channel[0].shift == 0 && desc->channel[0].size == 10 &&
          desc->channel[1].shift == 10 && desc->channel[1].size == 10 &&
          desc->channel[2].shift == 20 && desc->channel[2].size == 10 &&
          desc->channel[3].shift == 30 && desc->channel[3].size == 2;
}

static bool
ao46_mesa_is_rg11_b10(const struct util_format_description *desc)
{
   return desc->channel[0].shift == 0 && desc->channel[0].size == 11 &&
          desc->channel[1].shift == 11 && desc->channel[1].size == 11 &&
          desc->channel[2].shift == 22 && desc->channel[2].size == 10;
}

static enum pipe_format
ao46_mesa_vertex_internal_format(enum pipe_format format)
{
   const struct util_format_description *desc = util_format_description(format);
   int channel;

   if (!desc)
      return PIPE_FORMAT_NONE;
   if (ao46_mesa_is_rgb10_a2(desc) || ao46_mesa_is_rg11_b10(desc))
      return PIPE_FORMAT_R32_UINT;
   if (format == PIPE_FORMAT_R11G11B10_FLOAT)
      return format;
   if (!desc->is_array)
      return PIPE_FORMAT_NONE;

   channel = util_format_get_first_non_void_channel(format);
   if (channel < 0 || desc->colorspace != UTIL_FORMAT_COLORSPACE_RGB ||
       desc->layout != UTIL_FORMAT_LAYOUT_PLAIN)
      return PIPE_FORMAT_NONE;

   switch (desc->channel[channel].size) {
   case 32:
      return PIPE_FORMAT_R32_UINT;
   case 16:
      return PIPE_FORMAT_R16_UINT;
   case 8:
      return PIPE_FORMAT_R8_UINT;
   default:
      return PIPE_FORMAT_NONE;
   }
}

static nir_def *
ao46_mesa_swizzle_channel(nir_builder *builder, nir_def *vector,
                          unsigned swizzle, bool is_integer)
{
   switch (swizzle) {
   case PIPE_SWIZZLE_X:
   case PIPE_SWIZZLE_Y:
   case PIPE_SWIZZLE_Z:
   case PIPE_SWIZZLE_W:
      return nir_channel(builder, vector, swizzle - PIPE_SWIZZLE_X);
   case PIPE_SWIZZLE_0:
      return nir_imm_intN_t(builder, 0, vector->bit_size);
   case PIPE_SWIZZLE_1:
      return is_integer
                ? nir_imm_intN_t(builder, 1, vector->bit_size)
                : nir_imm_floatN_t(builder, 1.0, vector->bit_size);
   default:
      return NULL;
   }
}

static bool
ao46_mesa_lower_vertex_load(nir_builder *builder,
                            nir_intrinsic_instr *intrinsic, void *data)
{
   const struct AO46MesaVertexLowering *lowering = data;
   struct AO46MesaVertexAttribute attribute;
   const struct util_format_description *desc;
   enum pipe_format interchange_format;
   nir_src *offset_source;
   nir_def *element;
   nir_def *root;
   nir_def *base;
   nir_def *stride;
   nir_def *clamp;
   nir_def *out_of_bounds;
   nir_def *safe_element;
   nir_def *memory;
   nir_def *channels[4] = {NULL};
   unsigned index;
   int channel;
   unsigned interchange_alignment;
   unsigned interchange_components;
   unsigned interchange_register_size;
   unsigned destination_size;
   unsigned bits[4];
   bool is_float;
   bool is_unsigned;
   bool is_signed;
   bool is_fixed;
   bool is_integer;

   if (intrinsic->intrinsic != nir_intrinsic_load_input)
      return false;

   offset_source = nir_get_io_offset_src(intrinsic);
   if (!nir_src_is_const(*offset_source))
      return false;
   index = nir_intrinsic_base(intrinsic) + nir_src_as_uint(*offset_source);
   if (index >= AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS)
      return false;

   attribute = lowering->attributes[index];
   desc = util_format_description(attribute.format);
   channel = util_format_get_first_non_void_channel(attribute.format);
   interchange_format = ao46_mesa_vertex_internal_format(attribute.format);
   if (!desc || channel < 0 || interchange_format == PIPE_FORMAT_NONE)
      return false;

   is_float = desc->channel[channel].type == UTIL_FORMAT_TYPE_FLOAT;
   is_unsigned = desc->channel[channel].type == UTIL_FORMAT_TYPE_UNSIGNED;
   is_signed = desc->channel[channel].type == UTIL_FORMAT_TYPE_SIGNED;
   is_fixed = desc->channel[channel].type == UTIL_FORMAT_TYPE_FIXED;
   is_integer = util_format_is_pure_integer(attribute.format);
   if (!(is_float ^ is_unsigned ^ is_signed ^ is_fixed))
      return false;

   builder->cursor = nir_instr_remove(&intrinsic->instr);
   interchange_alignment = util_format_get_blocksize(interchange_format);
   interchange_components = util_format_get_nr_components(attribute.format);
   interchange_register_size = util_format_is_pure_uint(interchange_format)
                                  ? interchange_alignment * 8
                                  : intrinsic->def.bit_size;
   if (interchange_format == PIPE_FORMAT_R32_UINT && !desc->is_array)
      interchange_components = 1;

   if (attribute.instanced) {
      element = attribute.divisor
                   ? nir_udiv_imm(builder, nir_load_instance_id(builder),
                                  attribute.divisor)
                   : nir_imm_int(builder, 0);
      element = nir_iadd(builder, element, nir_load_base_instance(builder));
      BITSET_SET(builder->shader->info.system_values_read,
                 SYSTEM_VALUE_INSTANCE_ID);
      BITSET_SET(builder->shader->info.system_values_read,
                 SYSTEM_VALUE_BASE_INSTANCE);
   } else {
      element = nir_load_vertex_id(builder);
      BITSET_SET(builder->shader->info.system_values_read,
                 SYSTEM_VALUE_VERTEX_ID);
   }

   root = nir_load_buffer_ptr_kk(builder, 1, 64,
                                 .binding = lowering->root_binding);
   base = nir_load_global_constant(
      builder, 1, 64,
      nir_iadd_imm(builder, root,
                   offsetof(struct AO46MesaVertexInputRoot,
                            attrib_base[index])));
   stride = nir_load_global_constant(
      builder, 1, 32,
      nir_iadd_imm(builder, root,
                   offsetof(struct AO46MesaVertexInputRoot,
                            buffer_strides[attribute.binding])));
   clamp = nir_load_global_constant(
      builder, 1, 32,
      nir_iadd_imm(builder, root,
                   offsetof(struct AO46MesaVertexInputRoot,
                            attrib_clamps[index])));
   out_of_bounds = nir_ult(builder, clamp, element);
   safe_element = nir_bcsel(builder, out_of_bounds,
                            nir_imm_int(builder, 0), element);
   nir_def *stride_elements = nir_imul(
      builder, safe_element,
      nir_udiv_imm(builder, stride, interchange_alignment));
   memory = nir_load_constant_agx(builder, interchange_components,
                                  interchange_register_size, base,
                                  stride_elements,
                                  .format = interchange_format, .base = 0u);
   memory = nir_bcsel(builder, out_of_bounds,
                      nir_imm_zero(builder, memory->num_components,
                                   memory->bit_size),
                      memory);

   destination_size = intrinsic->def.bit_size;
   for (unsigned i = 0; i < ARRAY_SIZE(bits); ++i)
      bits[i] = desc->channel[channel].size;

   if (ao46_mesa_is_rg11_b10(desc)) {
      memory = nir_format_unpack_11f11f10f(builder, memory);
   } else if (ao46_mesa_is_rgb10_a2(desc)) {
      bits[0] = bits[1] = bits[2] = 10;
      bits[3] = 2;
      memory = is_signed
                  ? nir_format_unpack_sint(builder, memory, bits, 4)
                  : nir_format_unpack_uint(builder, memory, bits, 4);
   }

   if (desc->channel[channel].normalized) {
      memory = is_signed
                  ? nir_format_snorm_to_float(builder, memory, bits)
                  : nir_format_unorm_to_float(builder, memory, bits);
   } else if (desc->channel[channel].pure_integer) {
      memory = is_signed ? nir_i2iN(builder, memory, destination_size)
                         : nir_u2uN(builder, memory, destination_size);
   } else {
      if (is_unsigned)
         memory = nir_u2fN(builder, memory, destination_size);
      else if (is_signed || is_fixed)
         memory = nir_i2fN(builder, memory, destination_size);
      else
         memory = nir_f2fN(builder, memory, destination_size);

      if (is_fixed)
         memory = nir_fmul_imm(builder, memory, 1.0 / 65536.0);
   }

   for (unsigned i = 0; i < intrinsic->num_components; ++i) {
      unsigned component = nir_intrinsic_component(intrinsic) + i;
      channels[i] = ao46_mesa_swizzle_channel(
         builder, memory, desc->swizzle[component], is_integer);
      if (!channels[i])
         return false;
   }

   nir_def_rewrite_uses(
      &intrinsic->def, nir_vec(builder, channels, intrinsic->num_components));
   return true;
}

static bool
ao46_mesa_vertex_attributes(
   const struct nir_shader *nir, const struct pipe_vertex_element *elements,
   unsigned element_count, struct AO46MesaVertexLowering *lowering)
{
   uint64_t inputs;
   unsigned slot = 0;

   if (!nir || !elements || !lowering || element_count == 0 ||
       element_count > AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS ||
       (nir->info.inputs_read & BITFIELD64_MASK(VERT_ATTRIB_GENERIC0)) != 0)
      return false;

   inputs = nir->info.inputs_read >> VERT_ATTRIB_GENERIC0;
   u_foreach_bit(location, inputs) {
      const struct pipe_vertex_element *element;

      if (location >= element_count ||
          slot >= AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS)
         return false;
      element = &elements[location];
      if (element->vertex_buffer_index >= AO46_MESA_VERTEX_INPUT_MAX_BUFFERS ||
          ao46_mesa_vertex_internal_format(element->src_format) ==
             PIPE_FORMAT_NONE)
         return false;

      lowering->attributes[slot++] = (struct AO46MesaVertexAttribute){
         .divisor = element->instance_divisor,
         .binding = element->vertex_buffer_index,
         .format = element->src_format,
         .instanced = element->instance_divisor != 0,
      };
   }

   return slot != 0;
}

size_t
AO46MesaVertexInputRootSize(void)
{
   return sizeof(struct AO46MesaVertexInputRoot);
}

bool
AO46MesaNIRLowerVertexInputs(
   struct nir_shader *nir, const struct pipe_vertex_element *elements,
   unsigned element_count, unsigned root_buffer_binding)
{
   struct AO46MesaVertexLowering lowering = {
      .root_binding = root_buffer_binding,
   };

   if (!nir || nir->info.stage != MESA_SHADER_VERTEX ||
       root_buffer_binding < 2 || root_buffer_binding >= 16 ||
       !ao46_mesa_vertex_attributes(nir, elements, element_count, &lowering))
      return false;

   NIR_PASS(_, nir, nir_recompute_io_bases, nir_var_shader_in);
   NIR_PASS(_, nir, nir_opt_constant_folding);
   if (!nir_shader_intrinsics_pass(nir, ao46_mesa_lower_vertex_load,
                                   nir_metadata_control_flow, &lowering))
      return false;

   nir->info.inputs_read = 0;
   nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
   return true;
}

bool
AO46MesaVertexInputRootBuild(
   void *root, size_t root_size, uint64_t sink_gpu_address,
   uint64_t inputs_read, const struct pipe_vertex_element *elements,
   unsigned element_count, const struct AO46MesaVertexBufferRange *buffers,
   unsigned buffer_count)
{
   struct AO46MesaVertexInputRoot *table = root;
   uint64_t inputs;
   unsigned slot = 0;

   if (!root || root_size < sizeof(*table) || !sink_gpu_address || !elements ||
       !buffers || element_count == 0 ||
       element_count > AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS ||
       buffer_count == 0 || buffer_count > AO46_MESA_VERTEX_INPUT_MAX_BUFFERS ||
       (inputs_read & BITFIELD64_MASK(VERT_ATTRIB_GENERIC0)) != 0)
      return false;

   memset(table, 0, sizeof(*table));
   inputs = inputs_read >> VERT_ATTRIB_GENERIC0;
   u_foreach_bit(location, inputs) {
      const struct pipe_vertex_element *element;
      const struct AO46MesaVertexBufferRange *buffer;
      size_t format_size;
      size_t start;
      size_t available;

      if (location >= element_count ||
          slot >= AO46_MESA_VERTEX_INPUT_MAX_ATTRIBS)
         return false;
      element = &elements[location];
      if (element->vertex_buffer_index >= buffer_count ||
          element->vertex_buffer_index >= AO46_MESA_VERTEX_INPUT_MAX_BUFFERS ||
          ao46_mesa_vertex_internal_format(element->src_format) ==
             PIPE_FORMAT_NONE)
         return false;
      buffer = &buffers[element->vertex_buffer_index];
      format_size = util_format_get_blocksize(element->src_format);
      if (!buffer->valid || !buffer->gpu_address || !format_size ||
          buffer->offset > buffer->size ||
          element->src_offset > buffer->size - buffer->offset)
         return false;

      start = buffer->offset + element->src_offset;
      available = buffer->size - start;
      if (start > UINT64_MAX - buffer->gpu_address)
         return false;

      table->buffer_strides[element->vertex_buffer_index] = element->src_stride;
      if (available >= format_size) {
         table->attrib_base[slot] = buffer->gpu_address + start;
         table->attrib_clamps[slot] = element->src_stride
            ? (uint32_t)MIN2((available - format_size) / element->src_stride,
                             UINT32_MAX)
            : UINT32_MAX;
      } else {
         table->attrib_base[slot] = sink_gpu_address;
         table->attrib_clamps[slot] = 0;
      }
      ++slot;
   }

   return slot != 0;
}
