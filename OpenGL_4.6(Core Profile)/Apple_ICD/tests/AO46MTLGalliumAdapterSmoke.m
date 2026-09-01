/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import "mtl_pub.h"

#include "AO46MTLGallium.h"
#include "kosmickrisp/compiler/nir_to_msl.h"
#include "nir_builder.h"
#include "pipe/p_context.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/ralloc.h"
#include "util/u_inlines.h"

#include <stdint.h>
#include <stdio.h>

struct AO46DrawIndirectArguments {
   uint32_t vertex_count;
   uint32_t instance_count;
   uint32_t vertex_start;
   uint32_t base_instance;
};

static nir_def *
ao46_build_vote(nir_builder *builder, nir_intrinsic_op operation,
                nir_def *condition)
{
   nir_intrinsic_instr *vote =
      nir_intrinsic_instr_create(builder->shader, operation);

   vote->src[0] = nir_src_for_ssa(condition);
   nir_def_init(&vote->instr, &vote->def, 1, 1);
   nir_builder_instr_insert(builder, &vote->instr);
   return &vote->def;
}

static struct nir_shader *
ao46_build_vertex_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_active_indirect_vertex");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   nir_def *vertex_id = nir_load_vertex_id(&b);
   nir_def *position_value = nir_bcsel(
      &b, nir_ieq_imm(&b, vertex_id, 0),
      nir_imm_vec4(&b, -1.0f, -1.0f, 0.0f, 1.0f),
      nir_bcsel(&b, nir_ieq_imm(&b, vertex_id, 1),
                nir_imm_vec4(&b, 3.0f, -1.0f, 0.0f, 1.0f),
                nir_imm_vec4(&b, -1.0f, 3.0f, 0.0f, 1.0f)));

   nir_store_output(&b, position_value, nir_imm_int(&b, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   b.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return b.shader;
}

static struct nir_shader *
ao46_build_negative_z_vertex_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_clip_control_vertex");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   nir_def *vertex_id = nir_load_vertex_id(&b);
   nir_def *position_value = nir_bcsel(
      &b, nir_ieq_imm(&b, vertex_id, 0),
      nir_imm_vec4(&b, -1.0f, -1.0f, -0.5f, 1.0f),
      nir_bcsel(&b, nir_ieq_imm(&b, vertex_id, 1),
                nir_imm_vec4(&b, 3.0f, -1.0f, -0.5f, 1.0f),
                nir_imm_vec4(&b, -1.0f, 3.0f, -0.5f, 1.0f)));

   nir_store_output(&b, position_value, nir_imm_int(&b, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   b.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return b.shader;
}

static struct nir_shader *
ao46_build_fragment_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_active_indirect_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };

   nir_def *front_facing = nir_load_front_face(&b, 1);
   nir_def *back_facing = nir_inot(&b, front_facing);
   nir_def *all_one_facing = nir_ior(
      &b, ao46_build_vote(&b, nir_intrinsic_vote_all, front_facing),
      ao46_build_vote(&b, nir_intrinsic_vote_all, back_facing));
   nir_def *any_facing = nir_ior(
      &b, ao46_build_vote(&b, nir_intrinsic_vote_any, front_facing),
      ao46_build_vote(&b, nir_intrinsic_vote_any, back_facing));
   nir_def *color_value = nir_bcsel(
      &b, nir_iand(&b, all_one_facing, any_facing),
      nir_imm_vec4(&b, 1.0f, 0.25f, 0.0f, 1.0f),
      nir_imm_vec4(&b, 0.0f, 0.0f, 0.0f, 1.0f));

   nir_store_output(&b, color_value,
                    nir_imm_int(&b, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = color);
   b.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return b.shader;
}

static struct nir_shader *
ao46_build_fine_derivative_fragment_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_fine_derivative_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *frag_coord = nir_load_frag_coord(&b);
   nir_def *x = nir_channel(&b, frag_coord, 0);
   nir_def *y = nir_channel(&b, frag_coord, 1);
   nir_def *derivatives = nir_vec4(
      &b, nir_ddx_fine(&b, x), nir_ddy_fine(&b, y),
      nir_imm_float(&b, 0.0f), nir_imm_float(&b, 1.0f));

   nir_store_output(&b, derivatives, nir_imm_int(&b, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   b.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return b.shader;
}

static struct nir_shader *
ao46_build_ssbo_fragment_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_graphics_ssbo_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *value = nir_load_ssbo(
      &b, 4, 32, nir_imm_int(&b, 0), nir_imm_int(&b, 0),
      .align_mul = sizeof(float), .access = ACCESS_NON_WRITEABLE);

   nir_store_output(&b, value, nir_imm_int(&b, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = color);
   b.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return b.shader;
}

static struct nir_shader *
ao46_build_ubo_fragment_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_active_ubo_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *color_zero = nir_load_ubo(
      &b, 4, 32, nir_imm_int(&b, 0), nir_imm_int(&b, 0),
      .align_mul = 16, .align_offset = 0, .range = 16);
   nir_def *color_one = nir_load_ubo(
      &b, 4, 32, nir_imm_int(&b, 1), nir_imm_int(&b, 0),
      .align_mul = 16, .align_offset = 0, .range = 16);

   nir_store_output(&b, nir_fadd(&b, color_zero, color_one),
                    nir_imm_int(&b, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = color);
   b.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return b.shader;
}

static struct nir_shader *
ao46_build_count_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_active_indirect_count");
   nir_def *global_id;
   nir_def *buffer_index;

   b.shader->info.workgroup_size[0] = 1;
   b.shader->info.workgroup_size[1] = 1;
   b.shader->info.workgroup_size[2] = 1;
   global_id = nir_channel(&b, nir_load_global_invocation_id(&b, 32), 0);
   buffer_index = nir_iand_imm(&b, global_id, 1);
   nir_store_ssbo(&b, nir_imm_int(&b, 1), buffer_index,
                  nir_imm_int(&b, 0), .write_mask = 1,
                  .align_mul = sizeof(uint32_t));
   return b.shader;
}

static struct nir_shader *
ao46_build_draw_parameter_count_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options,
      "ao46_draw_parameter_indirect_count");

   b.shader->info.workgroup_size[0] = 1;
   b.shader->info.workgroup_size[1] = 1;
   b.shader->info.workgroup_size[2] = 1;
   nir_store_ssbo(&b, nir_imm_int(&b, 2), nir_imm_int(&b, 0),
                  nir_imm_int(&b, 0), .write_mask = 1,
                  .align_mul = sizeof(uint32_t));
   return b.shader;
}

static struct nir_shader *
ao46_build_ssbo_atomic_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_ssbo_atomic_compute");

   b.shader->info.workgroup_size[0] = 1;
   b.shader->info.workgroup_size[1] = 1;
   b.shader->info.workgroup_size[2] = 1;
   (void)nir_ssbo_atomic(&b, 32, nir_imm_int(&b, 0), nir_imm_int(&b, 0),
                         nir_imm_int(&b, 3),
                         .atomic_op = nir_atomic_op_iadd);
   nir_store_ssbo(&b, nir_imm_int(&b, 0x12345678), nir_imm_int(&b, 0),
                  nir_imm_int(&b, sizeof(uint32_t)), .write_mask = 1,
                  .align_mul = sizeof(uint32_t));
   (void)nir_ssbo_atomic(&b, 32, nir_imm_int(&b, 0),
                         nir_imm_int(&b, sizeof(uint32_t)),
                         nir_imm_int(&b, 1),
                         .atomic_op = nir_atomic_op_iadd);
   return b.shader;
}

static struct nir_shader *
ao46_build_tcs_state_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_CTRL, &kk_nir_options, "ao46_active_tcs_state");

   b.shader->info.tess._primitive_mode = TESS_PRIMITIVE_TRIANGLES;
   b.shader->info.tess.tcs_vertices_out = 1;
   return b.shader;
}

static struct nir_shader *
ao46_build_tes_state_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_TESS_EVAL, &kk_nir_options, "ao46_active_tes_state");

   b.shader->info.tess._primitive_mode = TESS_PRIMITIVE_TRIANGLES;
   return b.shader;
}

static struct nir_shader *
ao46_build_rgb32_fragment_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_FRAGMENT, &kk_nir_options, "ao46_active_rgb32_fragment");
   const struct nir_io_semantics color = {
      .location = FRAG_RESULT_DATA0,
      .num_slots = 1,
   };
   nir_def *texel = nir_txf(&b, nir_imm_int(&b, 0),
                            .dim = GLSL_SAMPLER_DIM_BUF,
                            .texture_index = 0,
                            .dest_type = nir_type_uint32);
   nir_def *last_slot_texel = nir_txf(&b, nir_imm_int(&b, 0),
                                      .dim = GLSL_SAMPLER_DIM_BUF,
                                      .texture_index = 15,
                                      .dest_type = nir_type_uint32);
   nir_def *normalized = nir_vec4(
      &b, nir_fmul_imm(&b, nir_u2f32(&b, nir_channel(&b, texel, 0)),
                       1.0f / 255.0f),
      nir_fmul_imm(&b, nir_u2f32(&b, nir_channel(&b, texel, 1)),
                   1.0f / 255.0f),
      nir_fmul_imm(&b,
                   nir_u2f32(&b, nir_channel(&b, last_slot_texel, 2)),
                   1.0f / 255.0f),
      nir_imm_float(&b, 1.0f));

   nir_store_output(&b, normalized, nir_imm_int(&b, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = color);
   b.shader->info.outputs_written |= BITFIELD64_BIT(FRAG_RESULT_DATA0);
   return b.shader;
}

static struct nir_shader *
ao46_build_storage_image_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_storage_image_compute");
   nir_variable *image = nir_variable_create(
      b.shader, nir_var_image,
      glsl_image_type(GLSL_SAMPLER_DIM_2D, false, GLSL_TYPE_UINT), "image0");
   nir_deref_instr *image_deref;
   nir_def *global_x;
   nir_def *coord;
   nir_def *loaded;
   nir_def *value;

   b.shader->info.workgroup_size[0] = 1;
   b.shader->info.workgroup_size[1] = 1;
   b.shader->info.workgroup_size[2] = 1;
   image->data.binding = 0;
   image->data.explicit_binding = true;
   image->data.access = ACCESS_COHERENT;
   image->data.image.format = PIPE_FORMAT_R8G8B8A8_UINT;
   image_deref = nir_build_deref_var(&b, image);
   global_x = nir_channel(&b, nir_load_global_invocation_id(&b, 32), 0);
   coord = nir_vec4(&b, global_x, nir_imm_int(&b, 0), nir_imm_int(&b, 0),
                    nir_imm_int(&b, 0));
   loaded = nir_image_deref_load(
      &b, 4, 32, &image_deref->def, coord, nir_imm_int(&b, 0),
      nir_imm_int(&b, 0), .dest_type = nir_type_uint32,
      .image_dim = GLSL_SAMPLER_DIM_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UINT, .access = ACCESS_COHERENT);
   value = nir_iadd(
      &b, loaded,
      nir_imm_ivec4(&b, 16, 32, 48, 251));
   nir_image_deref_store(&b, &image_deref->def, coord, nir_imm_int(&b, 0),
                         value, nir_imm_int(&b, 0),
                         .src_type = nir_type_uint32,
                         .image_dim = GLSL_SAMPLER_DIM_2D);
   return b.shader;
}

static struct nir_shader *
ao46_build_storage_image_atomic_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_COMPUTE, &kk_nir_options, "ao46_storage_image_atomic");
   nir_variable *image = nir_variable_create(
      b.shader, nir_var_image,
      glsl_image_type(GLSL_SAMPLER_DIM_2D, false, GLSL_TYPE_UINT), "atomic0");
   nir_deref_instr *image_deref;
   nir_def *coord;

   b.shader->info.workgroup_size[0] = 1;
   b.shader->info.workgroup_size[1] = 1;
   b.shader->info.workgroup_size[2] = 1;
   image->data.binding = 0;
   image->data.explicit_binding = true;
   image->data.access = ACCESS_COHERENT;
   image->data.image.format = PIPE_FORMAT_R32_UINT;
   image_deref = nir_build_deref_var(&b, image);
   coord = nir_imm_ivec4(&b, 0, 0, 0, 0);
   (void)nir_image_deref_atomic(
      &b, 32, &image_deref->def, coord, nir_imm_int(&b, 0),
      nir_imm_int(&b, 7), .image_dim = GLSL_SAMPLER_DIM_2D,
      .format = PIPE_FORMAT_R32_UINT, .access = ACCESS_COHERENT,
      .atomic_op = nir_atomic_op_iadd);
   return b.shader;
}

static struct nir_shader *
ao46_build_draw_id_vertex_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_draw_id_vertex");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   nir_def *vertex_id = nir_load_vertex_id(&b);
   nir_def *draw_id = nir_load_draw_id(&b);
   nir_def *base_vertex = nir_load_base_vertex(&b);
   nir_def *base_instance = nir_load_base_instance(&b);
   nir_def *zero_based_vertex = nir_umod_imm(&b, vertex_id, 3);
   nir_def *regular_draw = nir_iand(
      &b, nir_ior(&b, nir_ieq_imm(&b, draw_id, 4),
                  nir_ieq_imm(&b, draw_id, 5)),
      nir_iand(&b, nir_ieq_imm(&b, base_vertex, 0),
               nir_ieq_imm(&b, base_instance, 0)));
   nir_def *indexed_draw = nir_iand(
      &b, nir_ieq_imm(&b, draw_id, 9),
      nir_iand(&b, nir_ieq_imm(&b, base_vertex, 2),
               nir_ieq_imm(&b, base_instance, 5)));
   nir_def *stream_output_draw = nir_iand(
      &b, nir_ieq_imm(&b, draw_id, 12),
      nir_iand(&b, nir_ieq_imm(&b, base_vertex, 0),
               nir_ieq_imm(&b, base_instance, 0)));
   nir_def *indirect_left = nir_iand(
      &b, nir_ieq_imm(&b, draw_id, 20),
      nir_iand(&b, nir_ieq_imm(&b, base_vertex, 0),
               nir_ieq_imm(&b, base_instance, 7)));
   nir_def *indirect_right = nir_iand(
      &b, nir_ieq_imm(&b, draw_id, 21),
      nir_iand(&b, nir_ieq_imm(&b, base_vertex, 0),
               nir_ieq_imm(&b, base_instance, 8)));
   nir_def *valid_draw = nir_ior(
      &b, nir_ior(&b, regular_draw, indexed_draw),
      nir_ior(&b, stream_output_draw,
              nir_ior(&b, indirect_left, indirect_right)));
   nir_def *is_left = nir_bcsel(
      &b, stream_output_draw, nir_ult_imm(&b, vertex_id, 3),
      nir_ior(&b, nir_ior(&b, nir_ieq_imm(&b, draw_id, 4), indexed_draw),
              indirect_left));
   nir_def *left = nir_bcsel(
      &b, nir_ieq_imm(&b, zero_based_vertex, 0),
      nir_imm_vec4(&b, -0.95f, -0.8f, 0.0f, 1.0f),
      nir_bcsel(&b, nir_ieq_imm(&b, zero_based_vertex, 1),
                nir_imm_vec4(&b, -0.05f, -0.8f, 0.0f, 1.0f),
                nir_imm_vec4(&b, -0.5f, 0.8f, 0.0f, 1.0f)));
   nir_def *right = nir_bcsel(
      &b, nir_ieq_imm(&b, zero_based_vertex, 0),
      nir_imm_vec4(&b, 0.05f, -0.8f, 0.0f, 1.0f),
      nir_bcsel(&b, nir_ieq_imm(&b, zero_based_vertex, 1),
                nir_imm_vec4(&b, 0.95f, -0.8f, 0.0f, 1.0f),
                nir_imm_vec4(&b, 0.5f, 0.8f, 0.0f, 1.0f)));
   nir_def *outside = nir_imm_vec4(&b, 2.0f, 2.0f, 0.0f, 1.0f);

   nir_store_output(&b,
                    nir_bcsel(&b, valid_draw,
                              nir_bcsel(&b, is_left, left, right), outside),
                    nir_imm_int(&b, 0), .base = 0, .range = 1,
                    .write_mask = 0xf, .src_type = nir_type_float32,
                    .io_semantics = position);
   b.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS);
   return b.shader;
}

static struct nir_shader *
ao46_build_stream_output_vertex_shader(void)
{
   nir_builder b = nir_builder_init_simple_shader(
      MESA_SHADER_VERTEX, &kk_nir_options, "ao46_stream_output_vertex");
   const struct nir_io_semantics position = {
      .location = VARYING_SLOT_POS,
      .num_slots = 1,
   };
   const struct nir_io_semantics captured = {
      .location = VARYING_SLOT_VAR0,
      .num_slots = 1,
   };
   const struct nir_io_semantics captured_secondary = {
      .location = VARYING_SLOT_VAR1,
      .num_slots = 1,
   };
   nir_def *vertex_id = nir_load_vertex_id(&b);
   nir_def *position_value = nir_bcsel(
      &b, nir_ieq_imm(&b, vertex_id, 0),
      nir_imm_vec4(&b, -1.0f, -1.0f, 0.0f, 1.0f),
      nir_bcsel(&b, nir_ieq_imm(&b, vertex_id, 1),
                nir_imm_vec4(&b, 3.0f, -1.0f, 0.0f, 1.0f),
                nir_imm_vec4(&b, -1.0f, 3.0f, 0.0f, 1.0f)));
   nir_def *captured_value = nir_vec4(
      &b, nir_u2f32(&b, vertex_id), nir_imm_float(&b, 10.0f),
      nir_imm_float(&b, 20.0f), nir_imm_float(&b, 30.0f));
   nir_def *captured_secondary_value = nir_vec4(
      &b, nir_fadd_imm(&b, nir_u2f32(&b, vertex_id), 100.0f),
      nir_imm_float(&b, 40.0f), nir_imm_float(&b, 50.0f),
      nir_imm_float(&b, 60.0f));

   nir_store_output(&b, position_value, nir_imm_int(&b, 0), .base = 0,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = position);
   nir_store_output(&b, captured_value, nir_imm_int(&b, 0), .base = 1,
                    .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32, .io_semantics = captured);
   nir_store_output(&b, captured_secondary_value, nir_imm_int(&b, 0),
                    .base = 2, .range = 1, .write_mask = 0xf,
                    .src_type = nir_type_float32,
                    .io_semantics = captured_secondary);
   b.shader->info.outputs_written |= BITFIELD64_BIT(VARYING_SLOT_POS) |
                                     BITFIELD64_BIT(VARYING_SLOT_VAR0) |
                                     BITFIELD64_BIT(VARYING_SLOT_VAR1);
   return b.shader;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   struct pipe_resource *color = NULL;
   struct pipe_resource *indirect = NULL;
   struct pipe_resource *count = NULL;
   struct pipe_resource *count_scratch = NULL;
   struct pipe_resource *ssbo_atomic = NULL;
   struct pipe_resource *copy_compressed = NULL;
   struct pipe_resource *copy_plain = NULL;
   struct pipe_resource *depth_stencil = NULL;
   struct pipe_resource *rgb32 = NULL;
   struct pipe_resource *graphics_ssbo = NULL;
   struct pipe_resource *ubo_zero = NULL;
   struct pipe_resource *ubo_one = NULL;
   struct pipe_resource *storage_image = NULL;
   struct pipe_resource *storage_image_atomic = NULL;
   struct pipe_resource *stream_output_buffer = NULL;
   struct pipe_resource *stream_output_buffer_secondary = NULL;
   struct pipe_resource *draw_parameter_indices = NULL;
   struct pipe_stream_output_target *stream_output_target = NULL;
   struct pipe_stream_output_target *stream_output_target_secondary = NULL;
   struct pipe_query *stream_output_query = NULL;
   struct pipe_query *generated_query = NULL;
   struct pipe_sampler_view *rgb32_view = NULL;
   struct pipe_sampler_view *stencil_view = NULL;
   struct pipe_surface surface = {0};
   struct pipe_surface *surface_ptr = NULL;
   struct pipe_transfer *transfer = NULL;
   struct nir_shader *vertex_nir = NULL;
   struct nir_shader *fragment_nir = NULL;
   struct nir_shader *fine_derivative_nir = NULL;
   struct nir_shader *count_nir = NULL;
   struct nir_shader *draw_parameter_count_nir = NULL;
   struct nir_shader *ssbo_atomic_nir = NULL;
   struct nir_shader *tcs_state_nir = NULL;
   struct nir_shader *tes_state_nir = NULL;
   struct nir_shader *rgb32_nir = NULL;
   struct nir_shader *ssbo_fragment_nir = NULL;
   struct nir_shader *ubo_fragment_nir = NULL;
   struct nir_shader *negative_vertex_nir = NULL;
   struct nir_shader *storage_image_nir = NULL;
   struct nir_shader *storage_image_atomic_nir = NULL;
   struct nir_shader *draw_id_vertex_nir = NULL;
   struct nir_shader *stream_output_vertex_nir = NULL;
   void *vertex_state = NULL;
   void *fragment_state = NULL;
   void *fine_derivative_state = NULL;
   void *count_state = NULL;
   void *draw_parameter_count_state = NULL;
   void *ssbo_atomic_state = NULL;
   void *tcs_state = NULL;
   void *tes_state = NULL;
   void *rgb32_state = NULL;
   void *ssbo_fragment_state = NULL;
   void *ubo_fragment_state = NULL;
   void *negative_vertex_state = NULL;
   void *storage_image_state = NULL;
   void *storage_image_atomic_state = NULL;
   void *draw_id_vertex_state = NULL;
   void *stream_output_vertex_state = NULL;
   void *default_clip_raster = NULL;
   void *halfz_clip_raster = NULL;
   int failed = 0;
   const struct AO46DrawIndirectArguments arguments[2] = {
      {.vertex_count = 3, .instance_count = 1},
      {.vertex_count = 0, .instance_count = 1},
   };
   const struct AO46DrawIndirectArguments draw_parameter_arguments[2] = {
      {.vertex_count = 3, .instance_count = 1, .vertex_start = 0,
       .base_instance = 7},
      {.vertex_count = 3, .instance_count = 1, .vertex_start = 3,
       .base_instance = 8},
   };
   const uint32_t initial_count = 0;
   const uint32_t ssbo_atomic_initial[2] = {5, 0xdeadbeef};
   const uint8_t copy_image_block[16] = {
      0x13, 0x57, 0x9b, 0xdf, 0x24, 0x68, 0xac, 0xe0,
      0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78,
   };
   const uint32_t rgb32_texel[3] = {255, 64, 32};
   const float ssbo_color[4] = {0.125f, 0.75f, 0.375f, 1.0f};
   const float ubo_color_zero[4] = {0.125f, 0.25f, 0.0f, 0.5f};
   const float ubo_color_one[4] = {0.125f, 0.25f, 0.5f, 0.5f};
   const uint16_t draw_parameter_index_data[3] = {0, 1, 2};
   const uint8_t storage_image_initial[8] = {
      1, 2, 3, 4, 2, 2, 3, 4,
   };
   const uint32_t storage_image_atomic_initial = 5;
   struct pipe_resource color_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UNORM,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource indirect_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(arguments),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER,
   };
   struct pipe_resource count_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(uint64_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_COMMAND_ARGS_BUFFER | PIPE_BIND_SHADER_BUFFER,
   };
   struct pipe_resource ssbo_atomic_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(uint64_t),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SHADER_BUFFER,
   };
   struct pipe_resource copy_compressed_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_BPTC_RGBA_UNORM,
      .width0 = 4,
      .height0 = 4,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource copy_plain_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R32G32B32A32_UINT,
      .width0 = 1,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource depth_stencil_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_Z32_FLOAT_S8X24_UINT,
      .width0 = 8,
      .height0 = 8,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_DEPTH_STENCIL | PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource rgb32_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(rgb32_texel),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SAMPLER_VIEW,
   };
   struct pipe_resource graphics_ssbo_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(ssbo_color),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SHADER_BUFFER,
   };
   struct pipe_resource ubo_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(ubo_color_zero),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_CONSTANT_BUFFER,
   };
   struct pipe_resource storage_image_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R8G8B8A8_UINT,
      .width0 = 2,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SHADER_IMAGE,
   };
   struct pipe_resource storage_image_atomic_template = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_R32_UINT,
      .width0 = 1,
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_SHADER_IMAGE,
   };
   struct pipe_resource stream_output_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 16 + 6 * 4 * sizeof(float),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_STREAM_OUTPUT,
   };
   struct pipe_resource stream_output_secondary_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = 32 + 6 * 4 * sizeof(float),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_STREAM_OUTPUT,
   };
   struct pipe_resource draw_parameter_index_template = {
      .target = PIPE_BUFFER,
      .format = PIPE_FORMAT_R8_UNORM,
      .width0 = sizeof(draw_parameter_index_data),
      .height0 = 1,
      .depth0 = 1,
      .array_size = 1,
      .usage = PIPE_USAGE_DEFAULT,
      .bind = PIPE_BIND_INDEX_BUFFER,
   };
   const struct pipe_sampler_view rgb32_view_template = {
      .format = PIPE_FORMAT_R32G32B32_UINT,
      .target = PIPE_BUFFER,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_Y,
      .swizzle_b = PIPE_SWIZZLE_Z,
      .swizzle_a = PIPE_SWIZZLE_W,
      .u.buf = {.size = sizeof(rgb32_texel)},
   };
   const struct pipe_sampler_view stencil_view_template = {
      .format = PIPE_FORMAT_X24S8_UINT,
      .target = PIPE_TEXTURE_2D,
      .swizzle_r = PIPE_SWIZZLE_X,
      .swizzle_g = PIPE_SWIZZLE_0,
      .swizzle_b = PIPE_SWIZZLE_0,
      .swizzle_a = PIPE_SWIZZLE_1,
      .u.tex = {.first_level = 0, .last_level = 0,
                .first_layer = 0, .last_layer = 0},
   };

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Gallium adapter smoke could not create the Metal adapter\n",
            stderr);
      return 1;
   }

   screen = AO46MTLGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   if (!screen || !context || !screen->get_name || !screen->get_vendor ||
       !screen->get_name(screen)[0] || !screen->get_vendor(screen)[0] ||
       !screen->caps.multi_draw_indirect_params ||
       (__bridge void *)g_mtl_device != adapter.device ||
       (__bridge void *)g_mtl_queue != adapter.queue) {
      fputs("AO46 Gallium adapter smoke did not retain the active Metal path\n",
            stderr);
      failed = 1;
      goto out;
   }

   vertex_nir = ao46_build_vertex_shader();
   fragment_nir = ao46_build_fragment_shader();
   fine_derivative_nir = ao46_build_fine_derivative_fragment_shader();
   count_nir = ao46_build_count_shader();
   draw_parameter_count_nir = ao46_build_draw_parameter_count_shader();
   if (!vertex_nir || !fragment_nir || !fine_derivative_nir || !count_nir ||
       !draw_parameter_count_nir) {
      failed = 1;
      goto out;
   }
   {
      const struct pipe_shader_state vertex_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = vertex_nir,
      };
      const struct pipe_shader_state fragment_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = fragment_nir,
      };
      const struct pipe_shader_state fine_derivative_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = fine_derivative_nir,
      };
      const struct pipe_compute_state compute_shader = {
         .ir_type = PIPE_SHADER_IR_NIR,
         .prog = count_nir,
      };
      const struct pipe_compute_state draw_parameter_count_shader = {
         .ir_type = PIPE_SHADER_IR_NIR,
         .prog = draw_parameter_count_nir,
      };

      vertex_state = context->create_vs_state(context, &vertex_shader);
      fragment_state = context->create_fs_state(context, &fragment_shader);
      fine_derivative_state =
         context->create_fs_state(context, &fine_derivative_shader);
      count_state = context->create_compute_state(context, &compute_shader);
      draw_parameter_count_state = context->create_compute_state(
         context, &draw_parameter_count_shader);
   }
   color = screen->resource_create(screen, &color_template);
   indirect = screen->resource_create(screen, &indirect_template);
   count = screen->resource_create(screen, &count_template);
   count_scratch = screen->resource_create(screen, &count_template);
   ssbo_atomic = screen->resource_create(screen, &ssbo_atomic_template);
   copy_compressed = screen->resource_create(screen, &copy_compressed_template);
   copy_plain = screen->resource_create(screen, &copy_plain_template);
   depth_stencil = screen->resource_create(screen, &depth_stencil_template);
   stencil_view = depth_stencil
                     ? context->create_sampler_view(context, depth_stencil,
                                                    &stencil_view_template)
                     : NULL;
   if (color) {
      surface.texture = color;
      surface.format = color->format;
      surface.nr_samples = color->nr_samples;
      surface_ptr = &surface;
   }
   if (!vertex_state || !fragment_state || !fine_derivative_state ||
       !count_state ||
       !draw_parameter_count_state || !color ||
       !indirect || !count || !count_scratch || !ssbo_atomic ||
       !copy_compressed || !copy_plain || !depth_stencil || !stencil_view ||
       !surface_ptr) {
      fputs("AO46 active indirect smoke could not create Gallium state\n",
            stderr);
      failed = 1;
      goto out;
   }
   if (!context->memory_barrier || !context->texture_barrier ||
       !screen->caps.texture_barrier) {
      fputs("AO46 active Gallium barrier callbacks are incomplete\n", stderr);
      failed = 1;
      goto out;
   }

   /* GL 4.3: copy-image preserves a compressed block in plain storage. */
   {
      const struct pipe_box compressed_box = {
         .x = 0, .y = 0, .z = 0, .width = 4, .height = 4, .depth = 1,
      };
      const struct pipe_box plain_box = {
         .x = 0, .y = 0, .z = 0, .width = 1, .height = 1, .depth = 1,
      };

      context->texture_subdata(context, copy_compressed, 0, PIPE_MAP_WRITE,
                               &compressed_box, copy_image_block,
                               sizeof(copy_image_block),
                               sizeof(copy_image_block));
      context->resource_copy_region(context, copy_plain, 0, 0, 0, 0,
                                    copy_compressed, 0, &compressed_box);
      const uint8_t *copied = context->texture_map(
         context, copy_plain, 0, PIPE_MAP_READ, &plain_box, &transfer);
      if (!screen->caps.copy_between_compressed_and_plain_formats || !copied ||
          !transfer || memcmp(copied, copy_image_block,
                              sizeof(copy_image_block)) != 0) {
         fputs("AO46 compressed/plain copy-image readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* Legacy lane: the active screen now admits Mesa's standard patch state. */
   tcs_state_nir = ao46_build_tcs_state_shader();
   tes_state_nir = ao46_build_tes_state_shader();
   if (tcs_state_nir && tes_state_nir && context->set_tess_state &&
       context->set_patch_vertices) {
      const struct pipe_shader_state tcs_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = tcs_state_nir,
      };
      const struct pipe_shader_state tes_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = tes_state_nir,
      };
      const float outer[] = {1.0f, 1.0f, 1.0f, 1.0f};
      const float inner[] = {1.0f, 1.0f};

      tcs_state = context->create_tcs_state(context, &tcs_shader);
      tes_state = context->create_tes_state(context, &tes_shader);
      context->set_tess_state(context, outer, inner);
      context->set_patch_vertices(context, 3);
      context->bind_tcs_state(context, tcs_state);
      context->bind_tes_state(context, tes_state);
   }
   if (!tcs_state || !tes_state) {
      fputs("AO46 active tessellation state admission failed\n", stderr);
      failed = 1;
      goto out;
   }

   context->buffer_subdata(context, indirect, 0, 0, sizeof(arguments),
                           arguments);
   context->buffer_subdata(context, count, 0, 0, sizeof(initial_count),
                           &initial_count);
   {
      struct pipe_framebuffer_state framebuffer = {
         .width = color_template.width0,
         .height = color_template.height0,
         .nr_cbufs = 1,
      };
      const struct pipe_viewport_state viewport = {
         .scale = {4.0f, 4.0f, 0.5f},
         .translate = {4.0f, 4.0f, 0.5f},
      };
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      struct pipe_shader_buffer count_bindings[2] = {
         {
            .buffer = count,
            .buffer_size = sizeof(uint32_t),
         },
         {
            .buffer = count_scratch,
            .buffer_size = sizeof(uint32_t),
         },
      };
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {1, 1, 1},
         .grid = {2, 1, 1},
      };
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_indirect_info indirect_info = {
         .stride = sizeof(struct AO46DrawIndirectArguments),
         .draw_count = 2,
         .buffer = indirect,
         .indirect_draw_count = count,
      };

      framebuffer.cbufs[0] = surface;
      context->set_framebuffer_state(context, &framebuffer);
      context->set_viewport_states(context, 0, 1, &viewport);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->bind_compute_state(context, count_state);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 2,
                                  count_bindings, 3);
      context->launch_grid(context, &grid);
      context->memory_barrier(
         context, PIPE_BARRIER_SHADER_BUFFER | PIPE_BARRIER_INDIRECT_BUFFER);
      context->bind_vs_state(context, vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->draw_vbo(context, &draw, 0, &indirect_info, NULL, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }

   {
      const struct pipe_box box = {
         .x = 4,
         .y = 4,
         .width = 1,
         .height = 1,
         .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 GPU count-to-ICB draw readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.2 lane: active Gallium UBO 0/1 bindings reach distinct Metal slots. */
   ubo_fragment_nir = ao46_build_ubo_fragment_shader();
   if (ubo_fragment_nir) {
      const struct pipe_shader_state shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = ubo_fragment_nir,
      };

      ubo_fragment_state = context->create_fs_state(context, &shader);
   }
   ubo_zero = screen->resource_create(screen, &ubo_template);
   ubo_one = screen->resource_create(screen, &ubo_template);
   if (!ubo_fragment_state || !ubo_zero || !ubo_one ||
       !context->set_constant_buffer) {
      fputs("AO46 active multi-UBO state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   context->buffer_subdata(context, ubo_zero, 0, 0, sizeof(ubo_color_zero),
                           ubo_color_zero);
   context->buffer_subdata(context, ubo_one, 0, 0, sizeof(ubo_color_one),
                           ubo_color_one);
   {
      const struct pipe_constant_buffer bindings[2] = {
         {.buffer = ubo_zero, .buffer_size = sizeof(ubo_color_zero)},
         {.buffer = ubo_one, .buffer_size = sizeof(ubo_color_one)},
      };
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};

      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 0,
                                   &bindings[0]);
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 1,
                                   &bindings[1]);
      context->bind_vs_state(context, vertex_state);
      context->bind_fs_state(context, ubo_fragment_state);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 4, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 60 || pixel[0] > 68 ||
          pixel[1] < 124 || pixel[1] > 132 || pixel[2] < 124 ||
          pixel[2] > 132 || pixel[3] < 250) {
         fputs("AO46 active multi-UBO draw readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 0,
                                   NULL);
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 1,
                                   NULL);
   }

   /* GL 4.3 lane: Mesa SSBO atomics execute through direct Metal buffers. */
   ssbo_atomic_nir = ao46_build_ssbo_atomic_shader();
   if (ssbo_atomic_nir) {
      const struct pipe_compute_state compute_shader = {
         .ir_type = PIPE_SHADER_IR_NIR,
         .prog = ssbo_atomic_nir,
      };
      ssbo_atomic_state =
         context->create_compute_state(context, &compute_shader);
   }
   if (!ssbo_atomic_state) {
      fputs("AO46 SSBO atomic state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const struct pipe_shader_buffer binding = {
         .buffer = ssbo_atomic,
         .buffer_size = sizeof(uint32_t),
      };
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {1, 1, 1},
         .grid = {2, 1, 1},
      };
      const struct pipe_box box = {
         .x = 0, .width = sizeof(ssbo_atomic_initial),
         .height = 1, .depth = 1,
      };

      context->buffer_subdata(context, ssbo_atomic, 0, 0,
                              sizeof(ssbo_atomic_initial),
                              &ssbo_atomic_initial);
      context->bind_compute_state(context, ssbo_atomic_state);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 1,
                                  &binding, 1);
      context->launch_grid(context, &grid);
      context->memory_barrier(context, PIPE_BARRIER_SHADER_BUFFER);
      context->launch_grid(context, &grid);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
      const uint32_t *value = context->buffer_map(
         context, ssbo_atomic, 0, PIPE_MAP_READ, &box, &transfer);
      if (!screen->caps.robust_buffer_access_behavior || !value || !transfer ||
          value[0] != 17 || value[1] != ssbo_atomic_initial[1]) {
         fprintf(stderr,
                 "AO46 robust SSBO readback mismatched: %u guard=%08x\n",
                 value ? value[0] : 0, value ? value[1] : 0);
         failed = 1;
      }
      if (transfer) {
         context->buffer_unmap(context, transfer);
         transfer = NULL;
      }
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 1,
                                  NULL, 0);
   }

   rgb32_nir = ao46_build_rgb32_fragment_shader();
   if (!rgb32_nir ||
       !screen->is_format_supported(screen, PIPE_FORMAT_R32G32B32_UINT,
                                    PIPE_BUFFER, 1, 1,
                                    PIPE_BIND_SAMPLER_VIEW)) {
      fputs("AO46 active RGB32 format gate was not available\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const struct pipe_shader_state rgb32_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = rgb32_nir,
      };
      rgb32_state = context->create_fs_state(context, &rgb32_shader);
   }
   rgb32 = screen->resource_create(screen, &rgb32_template);
   rgb32_view = rgb32
                   ? context->create_sampler_view(context, rgb32,
                                                  &rgb32_view_template)
                   : NULL;
   if (!rgb32_state || !rgb32 || !rgb32_view) {
      fputs("AO46 active RGB32 state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   context->buffer_subdata(context, rgb32, 0, 0, sizeof(rgb32_texel),
                           rgb32_texel);
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};

      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->bind_fs_state(context, rgb32_state);
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 0, 1, 0,
                                 &rgb32_view);
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 15, 1, 0,
                                 &rgb32_view);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->texture_barrier(
         context,
         PIPE_TEXTURE_BARRIER_SAMPLER | PIPE_TEXTURE_BARRIER_FRAMEBUFFER);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 4,
         .y = 4,
         .width = 1,
         .height = 1,
         .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] < 28 || pixel[2] > 36 ||
          pixel[3] < 250) {
         fputs("AO46 active RGB32 draw readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   ssbo_fragment_nir = ao46_build_ssbo_fragment_shader();
   negative_vertex_nir = ao46_build_negative_z_vertex_shader();
   if (!ssbo_fragment_nir || !negative_vertex_nir) {
      failed = 1;
      goto out;
   }
   {
      const struct pipe_shader_state ssbo_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = ssbo_fragment_nir,
      };
      const struct pipe_shader_state negative_vertex_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = negative_vertex_nir,
      };
      const struct pipe_rasterizer_state default_clip = {.clip_halfz = false};
      const struct pipe_rasterizer_state halfz_clip = {.clip_halfz = true};

      ssbo_fragment_state = context->create_fs_state(context, &ssbo_shader);
      negative_vertex_state =
         context->create_vs_state(context, &negative_vertex_shader);
      default_clip_raster =
         context->create_rasterizer_state(context, &default_clip);
      halfz_clip_raster =
         context->create_rasterizer_state(context, &halfz_clip);
   }
   graphics_ssbo = screen->resource_create(screen, &graphics_ssbo_template);
   if (!ssbo_fragment_state || !negative_vertex_state ||
       !default_clip_raster || !halfz_clip_raster || !graphics_ssbo) {
      fputs("AO46 graphics SSBO/clip-control state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   context->buffer_subdata(context, graphics_ssbo, 0, 0, sizeof(ssbo_color),
                           ssbo_color);

   /* GL 4.3 lane: a fragment-stage Mesa SSBO reaches a direct Metal root. */
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};
      const struct pipe_shader_buffer binding = {
         .buffer = graphics_ssbo,
         .buffer_size = sizeof(ssbo_color),
      };

      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->bind_vs_state(context, vertex_state);
      context->bind_fs_state(context, ssbo_fragment_state);
      context->bind_rasterizer_state(context, default_clip_raster);
      context->set_shader_buffers(context, MESA_SHADER_FRAGMENT, 0, 1,
                                  &binding, 0);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 4, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 28 || pixel[0] > 36 ||
          pixel[1] < 187 || pixel[1] > 195 || pixel[2] < 92 ||
          pixel[2] > 100 || pixel[3] < 250) {
         fputs("AO46 graphics SSBO draw readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.5 lane: negative Z is clipped only in zero-to-one mode. */
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};

      context->set_shader_buffers(context, MESA_SHADER_FRAGMENT, 0, 1,
                                  NULL, 0);
      context->bind_vs_state(context, negative_vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->bind_rasterizer_state(context, halfz_clip_raster);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 4, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] != 0 || pixel[1] != 0 ||
          pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 zero-to-one clip-control draw was not clipped\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};

      context->bind_rasterizer_state(context, default_clip_raster);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 4, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 negative-one-to-one clip-control draw mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.3 lane: Mesa imageStore reaches a retained Metal storage texture. */
   storage_image_nir = ao46_build_storage_image_shader();
   if (storage_image_nir) {
      const struct pipe_compute_state compute_shader = {
         .ir_type = PIPE_SHADER_IR_NIR,
         .prog = storage_image_nir,
      };
      storage_image_state =
         context->create_compute_state(context, &compute_shader);
   }
   storage_image = screen->resource_create(screen, &storage_image_template);
   if (!storage_image_state || !storage_image ||
       !screen->is_format_supported(screen, storage_image_template.format,
                                    storage_image_template.target, 1, 1,
                                    PIPE_BIND_SHADER_IMAGE)) {
      fputs("AO46 storage-image state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const struct pipe_box upload_box = {
         .x = 0, .y = 0, .width = 2, .height = 1, .depth = 1,
      };
      const struct pipe_image_view image = {
         .resource = storage_image,
         .format = PIPE_FORMAT_R8G8B8A8_UINT,
         .access = PIPE_IMAGE_ACCESS_READ_WRITE,
         .shader_access = PIPE_IMAGE_ACCESS_READ_WRITE,
         .u.tex = {.level = 0, .first_layer = 0, .last_layer = 0},
      };
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {1, 1, 1},
         .grid = {2, 1, 1},
      };

      context->texture_subdata(context, storage_image, 0, PIPE_MAP_WRITE,
                               &upload_box, storage_image_initial, 8, 8);
      context->bind_compute_state(context, storage_image_state);
      context->set_shader_images(context, MESA_SHADER_COMPUTE, 0, 1, 0,
                                 &image);
      context->launch_grid(context, &grid);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 0, .y = 0, .width = 2, .height = 1, .depth = 1,
      };
      const uint8_t *pixels = context->texture_map(
         context, storage_image, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixels || !transfer || pixels[0] != 17 || pixels[1] != 34 ||
          pixels[2] != 51 || pixels[3] != 255 || pixels[4] != 18 ||
          pixels[5] != 34 || pixels[6] != 51 || pixels[7] != 255) {
         fprintf(stderr,
                 "AO46 storage-image dispatch readback mismatched: "
                 "%u,%u,%u,%u %u,%u,%u,%u\n",
                 pixels ? pixels[0] : 0, pixels ? pixels[1] : 0,
                 pixels ? pixels[2] : 0, pixels ? pixels[3] : 0,
                 pixels ? pixels[4] : 0, pixels ? pixels[5] : 0,
                 pixels ? pixels[6] : 0, pixels ? pixels[7] : 0);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
      context->set_shader_images(context, MESA_SHADER_COMPUTE, 0, 0, 1,
                                 NULL);
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 0,
                                   NULL);
      context->set_constant_buffer(context, MESA_SHADER_FRAGMENT, 1,
                                   NULL);
   }

   /* GL 4.3 lane: typed image atomics execute against a real Metal texture. */
   storage_image_atomic_nir = ao46_build_storage_image_atomic_shader();
   if (storage_image_atomic_nir) {
      const struct pipe_compute_state atomic_shader = {
         .ir_type = PIPE_SHADER_IR_NIR,
         .prog = storage_image_atomic_nir,
      };
      storage_image_atomic_state =
         context->create_compute_state(context, &atomic_shader);
   }
   storage_image_atomic =
      screen->resource_create(screen, &storage_image_atomic_template);
   if (!storage_image_atomic_state || !storage_image_atomic ||
       !screen->is_format_supported(screen, storage_image_atomic_template.format,
                                    storage_image_atomic_template.target, 1, 1,
                                    storage_image_atomic_template.bind)) {
      fputs("AO46 atomic storage-image setup failed\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const struct pipe_box upload_box = {
         .x = 0, .y = 0, .width = 1, .height = 1, .depth = 1,
      };
      const struct pipe_image_view image = {
         .resource = storage_image_atomic,
         .format = PIPE_FORMAT_R32_UINT,
         .access = PIPE_IMAGE_ACCESS_READ_WRITE,
         .shader_access = PIPE_IMAGE_ACCESS_READ_WRITE,
         .u.tex = {.level = 0, .first_layer = 0, .last_layer = 0},
      };
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {1, 1, 1},
         .grid = {1, 1, 1},
      };

      context->texture_subdata(context, storage_image_atomic, 0,
                               PIPE_MAP_WRITE, &upload_box,
                               &storage_image_atomic_initial, sizeof(uint32_t),
                               sizeof(uint32_t));
      context->bind_compute_state(context, storage_image_atomic_state);
      context->set_shader_images(context, MESA_SHADER_COMPUTE, 0, 1, 0,
                                 &image);
      context->launch_grid(context, &grid);
      context->memory_barrier(context, PIPE_BARRIER_IMAGE);
      context->launch_grid(context, &grid);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 0, .y = 0, .width = 1, .height = 1, .depth = 1,
      };
      const uint32_t *value = context->texture_map(
         context, storage_image_atomic, 0, PIPE_MAP_READ, &box, &transfer);

      if (!value || !transfer || *value != 19) {
         fprintf(stderr, "AO46 storage-image atomic readback mismatched: %u\n",
                 value ? *value : 0);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
      context->set_shader_images(context, MESA_SHADER_COMPUTE, 0, 0, 1,
                                 NULL);
   }

   /* GL 4.6 lane: DrawID is supplied independently for each Gallium draw. */
   draw_id_vertex_nir = ao46_build_draw_id_vertex_shader();
   if (draw_id_vertex_nir) {
      const struct pipe_shader_state draw_id_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = draw_id_vertex_nir,
      };
      draw_id_vertex_state =
         context->create_vs_state(context, &draw_id_shader);
   }
   if (!draw_id_vertex_state) {
      fputs("AO46 draw-parameter vertex state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias ranges[2] = {
         {.count = 3},
         {.count = 3},
      };

      context->bind_compute_state(context, NULL);
      context->bind_tcs_state(context, NULL);
      context->bind_tes_state(context, NULL);
      context->bind_vs_state(context, draw_id_vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->bind_rasterizer_state(context, default_clip_raster);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 4, NULL, ranges, 2);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   for (unsigned x = 2; x <= 6; x += 4) {
      const struct pipe_box box = {
         .x = (int)x, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 DrawID multi-draw readback mismatched\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.6 lane: each indirect record carries its own base-instance state. */
   context->buffer_subdata(context, indirect, 0, 0,
                           sizeof(draw_parameter_arguments),
                           draw_parameter_arguments);
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_indirect_info indirect_info = {
         .buffer = indirect,
         .stride = sizeof(struct AO46DrawIndirectArguments),
         .draw_count = 2,
      };

      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 20, &indirect_info, NULL, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   for (unsigned x = 2; x <= 6; x += 4) {
      const struct pipe_box box = {
         .x = (int)x, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 indirect DrawID/BaseInstance readback mismatched\n",
               stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.6 lane: GPU-selected indirect batches retain per-record DrawID. */
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_indirect_info indirect_info = {
         .buffer = indirect,
         .stride = sizeof(struct AO46DrawIndirectArguments),
         .draw_count = 2,
         .indirect_draw_count = count,
      };
      const struct pipe_shader_buffer count_binding = {
         .buffer = count,
         .buffer_size = sizeof(uint32_t),
      };
      const struct pipe_grid_info grid = {
         .work_dim = 1,
         .block = {1, 1, 1},
         .grid = {1, 1, 1},
      };

      context->bind_compute_state(context, draw_parameter_count_state);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 1,
                                  &count_binding, 1);
      context->launch_grid(context, &grid);
      context->memory_barrier(
         context, PIPE_BARRIER_SHADER_BUFFER | PIPE_BARRIER_INDIRECT_BUFFER);
      context->bind_vs_state(context, draw_id_vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 20, &indirect_info, NULL, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   for (unsigned x = 2; x <= 6; x += 4) {
      const struct pipe_box box = {
         .x = (int)x, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 GPU-count DrawID/BaseInstance readback mismatched\n",
               stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* GL 4.6 lane: nonzero BaseVertex/BaseInstance share the DrawID ABI. */
   draw_parameter_indices =
      screen->resource_create(screen, &draw_parameter_index_template);
   if (!draw_parameter_indices) {
      fputs("AO46 draw-parameter index buffer creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   context->buffer_subdata(context, draw_parameter_indices, 0, 0,
                           sizeof(draw_parameter_index_data),
                           draw_parameter_index_data);
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .index_size = sizeof(uint16_t),
         .instance_count = 1,
         .start_instance = 5,
      };
      const struct pipe_draw_start_count_bias range = {
         .count = 3,
         .index_bias = 2,
      };

      draw.index.resource = draw_parameter_indices;
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->draw_vbo(context, &draw, 9, NULL, &range, 1);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 2, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 BaseVertex/BaseInstance draw readback mismatched\n",
               stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* Legacy lane: capture, pause, and append transform-feedback records. */
   stream_output_vertex_nir = ao46_build_stream_output_vertex_shader();
   if (stream_output_vertex_nir) {
      const struct pipe_shader_state stream_output_shader = {
         .type = PIPE_SHADER_IR_NIR,
         .ir.nir = stream_output_vertex_nir,
         .stream_output = {
            .num_outputs = 2,
            .stride = {4, 4},
            .output = {
               {
                  .register_index = 1,
                  .start_component = 0,
                  .num_components = 4,
                  .output_buffer = 0,
                  .dst_offset = 0,
                  .stream = 0,
               },
               {
                  .register_index = 2,
                  .start_component = 0,
                  .num_components = 4,
                  .output_buffer = 1,
                  .dst_offset = 0,
                  .stream = 0,
               },
            },
         },
      };
      stream_output_vertex_state =
         context->create_vs_state(context, &stream_output_shader);
   }
   stream_output_buffer =
      screen->resource_create(screen, &stream_output_template);
   stream_output_target =
      stream_output_buffer
         ? context->create_stream_output_target(
              context, stream_output_buffer, 16, 6 * 4 * sizeof(float))
         : NULL;
   stream_output_buffer_secondary =
      screen->resource_create(screen, &stream_output_secondary_template);
   stream_output_target_secondary =
      stream_output_buffer_secondary
         ? context->create_stream_output_target(
              context, stream_output_buffer_secondary, 32,
              6 * 4 * sizeof(float))
         : NULL;
   if (!stream_output_vertex_state || !stream_output_buffer ||
       !stream_output_target || !stream_output_buffer_secondary ||
       !stream_output_target_secondary ||
       !screen->caps.stream_output_interleave_buffers) {
      fputs("AO46 transform-feedback state creation failed\n", stderr);
      failed = 1;
      goto out;
   }
   stream_output_query =
      context->create_query(context, PIPE_QUERY_SO_STATISTICS, 0);
   generated_query =
      context->create_query(context, PIPE_QUERY_PRIMITIVES_GENERATED, 0);
   if (!screen->caps.stream_output_pause_resume || !stream_output_query ||
       !generated_query ||
       !context->begin_query(context, stream_output_query)) {
      fputs("AO46 transform-feedback query lifecycle unavailable\n", stderr);
      failed = 1;
      goto out;
   }
   {
      const uint8_t zeroes[16 + 6 * 4 * sizeof(float)] = {0};
      const uint8_t secondary_zeroes[32 + 6 * 4 * sizeof(float)] = {0};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};
      struct pipe_stream_output_target *targets[2] = {
         stream_output_target,
         stream_output_target_secondary,
      };
      const unsigned reset_offsets[2] = {0, 0};
      const unsigned append_offsets[2] = {(unsigned)-1, (unsigned)-1};

      context->buffer_subdata(context, stream_output_buffer, 0, 0,
                              sizeof(zeroes), zeroes);
      context->buffer_subdata(context, stream_output_buffer_secondary, 0, 0,
                              sizeof(secondary_zeroes), secondary_zeroes);
      context->bind_vs_state(context, stream_output_vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->set_stream_output_targets(context, 2, targets, reset_offsets,
                                         MESA_PRIM_TRIANGLES);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->set_stream_output_targets(context, 0, NULL, NULL,
                                         MESA_PRIM_UNKNOWN);
      context->set_stream_output_targets(context, 2, targets, append_offsets,
                                         MESA_PRIM_TRIANGLES);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->set_stream_output_targets(context, 0, NULL, NULL,
                                         MESA_PRIM_UNKNOWN);
      if (!context->end_query(context, stream_output_query)) {
         fputs("AO46 transform-feedback statistics query did not end\n",
               stderr);
         failed = 1;
      }
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      const struct pipe_box box = {
         .x = 32,
         .width = 6 * 4 * sizeof(float),
         .height = 1,
         .depth = 1,
      };
      const float *records = context->buffer_map(
         context, stream_output_buffer_secondary, 0, PIPE_MAP_READ, &box,
         &transfer);

      if (!records || !transfer ||
          context->stream_output_target_offset(
             stream_output_target_secondary) != 6 * 4 * sizeof(float)) {
         fputs("AO46 secondary transform-feedback target mismatched\n",
               stderr);
         failed = 1;
      } else {
         for (unsigned record = 0; record < 6; ++record) {
            const unsigned expected_vertex = record % 3;
            if (records[record * 4 + 0] != 100.0f + expected_vertex ||
                records[record * 4 + 1] != 40.0f ||
                records[record * 4 + 2] != 50.0f ||
                records[record * 4 + 3] != 60.0f) {
               fprintf(stderr,
                       "AO46 secondary transform-feedback record %u "
                       "mismatched: %f,%f,%f,%f\n",
                       record, records[record * 4 + 0],
                       records[record * 4 + 1], records[record * 4 + 2],
                       records[record * 4 + 3]);
               failed = 1;
            }
         }
      }
      if (transfer) {
         context->buffer_unmap(context, transfer);
         transfer = NULL;
      }
   }
   {
      union pipe_query_result result = {0};

      if (!context->get_query_result(context, stream_output_query, true,
                                     &result) ||
          result.so_statistics.num_primitives_written != 2 ||
          result.so_statistics.primitives_storage_needed != 2) {
         fprintf(stderr,
                 "AO46 transform-feedback statistics mismatched: %llu/%llu\n",
                 (unsigned long long)
                    result.so_statistics.num_primitives_written,
                 (unsigned long long)
                    result.so_statistics.primitives_storage_needed);
         failed = 1;
      }
   }
   /* GL 4.4/4.5: query-buffer writes and inverted conditions share a query. */
   {
      const struct pipe_box query_box = {
         .x = 0, .width = sizeof(uint64_t), .height = 1, .depth = 1,
      };
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_start_count_bias range = {.count = 3};
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const uint64_t zero = 0;

      context->buffer_subdata(context, count_scratch, 0, 0, sizeof(zero),
                              &zero);
      context->get_query_result_resource(
         context, stream_output_query, PIPE_QUERY_WAIT, PIPE_QUERY_TYPE_U64,
         0, count_scratch, 0);
      const uint64_t *query_value = context->buffer_map(
         context, count_scratch, 0, PIPE_MAP_READ, &query_box, &transfer);
      if (!screen->caps.query_buffer_object || !query_value || !transfer ||
          *query_value != 2) {
         fprintf(stderr, "AO46 query-buffer result mismatched: %llu\n",
                 (unsigned long long)(query_value ? *query_value : 0));
         failed = 1;
      }
      if (transfer) {
         context->buffer_unmap(context, transfer);
         transfer = NULL;
      }

      context->bind_vs_state(context, vertex_state);
      context->bind_fs_state(context, fragment_state);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      context->render_condition(context, stream_output_query, true,
                                PIPE_RENDER_COND_WAIT);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->render_condition(context, NULL, false, PIPE_RENDER_COND_WAIT);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);

      const struct pipe_box pixel_box = {
         .x = 4, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &pixel_box, &transfer);
      if (!screen->caps.conditional_render_inverted || !pixel || !transfer ||
          pixel[0] != 0 || pixel[1] != 0 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 inverted conditional draw was not suppressed\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }

      context->render_condition(context, stream_output_query, false,
                                PIPE_RENDER_COND_WAIT);
      context->draw_vbo(context, &draw, 0, NULL, &range, 1);
      context->render_condition(context, NULL, false, PIPE_RENDER_COND_WAIT);
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
      pixel = context->texture_map(context, color, 0, PIPE_MAP_READ,
                                   &pixel_box, &transfer);
      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 normal conditional draw was not admitted\n", stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }
   {
      const struct pipe_box box = {
         .x = 16,
         .width = 6 * 4 * sizeof(float),
         .height = 1,
         .depth = 1,
      };
      const float *records = context->buffer_map(
         context, stream_output_buffer, 0, PIPE_MAP_READ, &box, &transfer);

      if (!records || !transfer ||
          context->stream_output_target_offset(stream_output_target) !=
             6 * 4 * sizeof(float)) {
         fputs("AO46 transform-feedback counter/append state mismatched\n",
               stderr);
         failed = 1;
      } else {
         for (unsigned record = 0; record < 6; ++record) {
            const unsigned expected_vertex = record % 3;
            if (records[record * 4 + 0] != (float)expected_vertex ||
                records[record * 4 + 1] != 10.0f ||
                records[record * 4 + 2] != 20.0f ||
                records[record * 4 + 3] != 30.0f) {
               fprintf(stderr,
                       "AO46 transform-feedback GPU record %u mismatched: "
                       "%f,%f,%f,%f expected %u,10,20,30\n",
                       record, records[record * 4 + 0],
                       records[record * 4 + 1], records[record * 4 + 2],
                       records[record * 4 + 3], expected_vertex);
               failed = 1;
            }
         }
      }
      if (transfer) {
         context->buffer_unmap(context, transfer);
         transfer = NULL;
      }
   }

   /* Transform-feedback 2: glDrawTransformFeedback's Gallium count path. */
   {
      const union pipe_color_union clear = {.f = {0.0f, 0.0f, 0.0f, 1.0f}};
      const struct pipe_draw_info draw = {
         .mode = MESA_PRIM_TRIANGLES,
         .instance_count = 1,
      };
      const struct pipe_draw_indirect_info from_stream_output = {
         .count_from_stream_output = stream_output_target,
      };

      context->bind_vs_state(context, draw_id_vertex_state);
      context->clear_render_target(context, surface_ptr, &clear, 0, 0,
                                   color_template.width0,
                                   color_template.height0, false);
      if (!context->begin_query(context, generated_query)) {
         fputs("AO46 generated-primitives query did not begin\n", stderr);
         failed = 1;
      }
      context->draw_vbo(context, &draw, 12, &from_stream_output, NULL, 1);
      if (!context->end_query(context, generated_query)) {
         fputs("AO46 generated-primitives query did not end\n", stderr);
         failed = 1;
      }
      context->flush(context, NULL, PIPE_FLUSH_HINT_FINISH);
   }
   {
      union pipe_query_result result = {0};

      if (!context->get_query_result(context, generated_query, true,
                                     &result) ||
          result.u64 != 2) {
         fprintf(stderr,
                 "AO46 stream-output draw count mismatched: %llu primitives\n",
                 (unsigned long long)result.u64);
         failed = 1;
      }
   }
   for (unsigned x = 2; x <= 6; x += 4) {
      const struct pipe_box box = {
         .x = (int)x, .y = 4, .width = 1, .height = 1, .depth = 1,
      };
      const uint8_t *pixel = context->texture_map(
         context, color, 0, PIPE_MAP_READ, &box, &transfer);

      if (!pixel || !transfer || pixel[0] < 250 || pixel[1] < 60 ||
          pixel[1] > 70 || pixel[2] != 0 || pixel[3] < 250) {
         fputs("AO46 draw-from-transform-feedback readback mismatched\n",
               stderr);
         failed = 1;
      }
      if (transfer) {
         context->texture_unmap(context, transfer);
         transfer = NULL;
      }
   }

out:
   if (transfer && context)
      context->texture_unmap(context, transfer);
   if (context) {
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 0, 0, 1,
                                 NULL);
      context->set_sampler_views(context, MESA_SHADER_FRAGMENT, 15, 0, 1,
                                 NULL);
      context->set_shader_buffers(context, MESA_SHADER_COMPUTE, 0, 2, NULL, 0);
      context->set_shader_buffers(context, MESA_SHADER_FRAGMENT, 0, 1,
                                  NULL, 0);
      context->set_shader_images(context, MESA_SHADER_COMPUTE, 0, 0, 1,
                                 NULL);
      context->set_stream_output_targets(context, 0, NULL, NULL,
                                         MESA_PRIM_UNKNOWN);
      context->bind_compute_state(context, NULL);
      context->bind_tcs_state(context, NULL);
      context->bind_tes_state(context, NULL);
      context->bind_vs_state(context, NULL);
      context->bind_fs_state(context, NULL);
      context->bind_rasterizer_state(context, NULL);
      if (count_state)
         context->delete_compute_state(context, count_state);
      if (draw_parameter_count_state)
         context->delete_compute_state(context, draw_parameter_count_state);
      if (ssbo_atomic_state)
         context->delete_compute_state(context, ssbo_atomic_state);
      if (tcs_state)
         context->delete_tcs_state(context, tcs_state);
      if (tes_state)
         context->delete_tes_state(context, tes_state);
      if (vertex_state)
         context->delete_vs_state(context, vertex_state);
      if (fragment_state)
         context->delete_fs_state(context, fragment_state);
      if (fine_derivative_state)
         context->delete_fs_state(context, fine_derivative_state);
      if (rgb32_state)
         context->delete_fs_state(context, rgb32_state);
      if (ssbo_fragment_state)
         context->delete_fs_state(context, ssbo_fragment_state);
      if (ubo_fragment_state)
         context->delete_fs_state(context, ubo_fragment_state);
      if (negative_vertex_state)
         context->delete_vs_state(context, negative_vertex_state);
      if (storage_image_state)
         context->delete_compute_state(context, storage_image_state);
      if (storage_image_atomic_state)
         context->delete_compute_state(context, storage_image_atomic_state);
      if (draw_id_vertex_state)
         context->delete_vs_state(context, draw_id_vertex_state);
      if (stream_output_vertex_state)
         context->delete_vs_state(context, stream_output_vertex_state);
      if (default_clip_raster)
         context->delete_rasterizer_state(context, default_clip_raster);
      if (halfz_clip_raster)
         context->delete_rasterizer_state(context, halfz_clip_raster);
      if (generated_query)
         context->destroy_query(context, generated_query);
      if (stream_output_query)
         context->destroy_query(context, stream_output_query);
   }
   pipe_so_target_reference(&stream_output_target_secondary, NULL);
   pipe_so_target_reference(&stream_output_target, NULL);
   pipe_resource_reference(&stream_output_buffer_secondary, NULL);
   pipe_resource_reference(&stream_output_buffer, NULL);
   pipe_resource_reference(&draw_parameter_indices, NULL);
   pipe_resource_reference(&storage_image, NULL);
   pipe_resource_reference(&storage_image_atomic, NULL);
   pipe_resource_reference(&graphics_ssbo, NULL);
   pipe_resource_reference(&ubo_one, NULL);
   pipe_resource_reference(&ubo_zero, NULL);
   pipe_sampler_view_reference(&rgb32_view, NULL);
   pipe_sampler_view_reference(&stencil_view, NULL);
   pipe_resource_reference(&depth_stencil, NULL);
   pipe_resource_reference(&rgb32, NULL);
   pipe_resource_reference(&count_scratch, NULL);
   pipe_resource_reference(&ssbo_atomic, NULL);
   pipe_resource_reference(&copy_plain, NULL);
   pipe_resource_reference(&copy_compressed, NULL);
   pipe_resource_reference(&count, NULL);
   pipe_resource_reference(&indirect, NULL);
   pipe_resource_reference(&color, NULL);
   ralloc_free(count_nir);
   ralloc_free(draw_parameter_count_nir);
   ralloc_free(ssbo_atomic_nir);
   ralloc_free(tcs_state_nir);
   ralloc_free(tes_state_nir);
   ralloc_free(rgb32_nir);
   ralloc_free(ssbo_fragment_nir);
   ralloc_free(ubo_fragment_nir);
   ralloc_free(negative_vertex_nir);
   ralloc_free(storage_image_nir);
   ralloc_free(storage_image_atomic_nir);
   ralloc_free(draw_id_vertex_nir);
   ralloc_free(stream_output_vertex_nir);
   ralloc_free(fragment_nir);
   ralloc_free(fine_derivative_nir);
   ralloc_free(vertex_nir);
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   if (!failed && (g_mtl_device != nil || g_mtl_queue != nil)) {
      fputs("AO46 Gallium adapter smoke did not release the Metal path\n",
            stderr);
      failed = 1;
   }
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
