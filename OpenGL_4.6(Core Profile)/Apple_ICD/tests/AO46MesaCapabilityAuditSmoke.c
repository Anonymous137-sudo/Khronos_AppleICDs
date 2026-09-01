#include "AO46MesaBridge.h"

#include <stdio.h>

int
main(void)
{
    struct AO46MesaCoreCapabilityAudit audit = {0};

    if (AO46MesaAuditCoreCapabilities(&audit) != kCGLNoError) {
        fputs("AO46 Mesa capability audit could not initialize the active screen\n",
              stderr);
        return 1;
    }

    printf("AO46 Mesa core=%d.%d GLSL=%d GL1.4/2.x gates: shadow=%d vs=%d "
           "fs=%d npot=%d blend-separate=%d stencil-two-side=%d srgb=%d\n"
           "AO46 Mesa GL3.0 gates: depth-float=%d half-vertex=%d map-range=%d "
           "shader-lod=%d float=%d rg=%d rgtc=%d draw-buffers2=%d fbo=%d "
           "fb-srgb=%d packed=%d array=%d integer=%d shared-exp=%d tf=%d "
           "conditional=%d\n"
           "AO46 Mesa GL3.1 gates: draw-instanced=%d ubo=%d snorm=%d "
           "restart=%d rectangle=%d\n"
           "AO46 Mesa GL3.3 gates: "
           "blend=%d attrib=%d instancing=%d bit-encoding=%d rgb10=%d "
           "timer=%d packed-vertex=%d swizzle=%d\n"
           "AO46 Mesa GL3.2 gates: depth-clamp=%d base-vertex=%d frag-coord=%d "
           "provoking=%d seamless=%d sync=%d multisample=%d bgra=%d\n"
           "AO46 Mesa GL4.0 gates: blend=%d indirect=%d shader5=%d fp64=%d "
           "sample=%d tess=%d rgb32=%d cube-array=%d lod=%d tf2=%d tf3=%d\n"
           "AO46 Mesa GL4.1 gates: es2=%d precision=%d attrib64=%d viewport-array=%d\n"
           "AO46 Mesa GL4.2 gates: base-instance=%d conservative-depth=%d "
           "internalformat=%d atomic=%d images=%d pack420=%d packing=%d "
           "bptc=%d tf-instanced=%d\n"
           "AO46 Mesa GL4.3 gates: compute=%d copy-image=%d es3=%d arrays=%d "
           "uniform-location=%d fragment-layer=%d no-attachments=%d "
           "internalformat2=%d robust=%d image-size=%d SSBO=%d stencil=%d "
           "tbo-range=%d query-levels=%d texture-view=%d\n"
           "AO46 Mesa GL4.4 gates: storage=%d layouts=%d query-buffer=%d "
           "mirror-clamp=%d stencil8=%d packed-vertex=%d\n"
           "AO46 Mesa GL4.5 gates: es31=%d clip-control=%d conditional=%d "
           "cull-distance=%d derivatives=%d image-samples=%d barrier=%d\n"
           "AO46 Mesa GL4.6 gates: gl-spirv=%d spirv-extensions=%d "
           "indirect-parameters=%d "
           "offset-clamp=%d atomic-ops=%d draw-parameters=%d group-vote=%d "
           "anisotropic=%d tf-overflow=%d\n",
           audit.core_version / 10, audit.core_version % 10,
           audit.glsl_version, audit.gl14_shadow,
           audit.gl20_vertex_shader, audit.gl20_fragment_shader,
           audit.gl20_texture_npot, audit.gl20_blend_equation_separate,
           audit.gl20_stencil_two_side, audit.gl21_texture_srgb,
           audit.gl30_depth_buffer_float, audit.gl30_half_float_vertex,
           audit.gl30_map_buffer_range, audit.gl30_shader_texture_lod,
           audit.gl30_texture_float, audit.gl30_texture_rg,
           audit.gl30_texture_compression_rgtc, audit.gl30_draw_buffers2,
           audit.gl30_framebuffer_object, audit.gl30_framebuffer_srgb,
           audit.gl30_packed_float, audit.gl30_texture_array,
           audit.gl30_texture_integer, audit.gl30_texture_shared_exponent,
           audit.gl30_transform_feedback, audit.gl30_conditional_render,
           audit.gl31_draw_instanced, audit.gl31_uniform_buffer_object,
           audit.gl31_texture_snorm, audit.gl31_primitive_restart,
           audit.gl31_texture_rectangle,
           audit.gl33_blend_func_extended,
           audit.gl33_explicit_attrib_location, audit.gl33_instanced_arrays,
           audit.gl33_shader_bit_encoding, audit.gl33_texture_rgb10_a2ui,
           audit.gl33_timer_query, audit.gl33_vertex_type_2_10_10_10_rev,
           audit.gl33_texture_swizzle,
           audit.gl32_depth_clamp, audit.gl32_draw_elements_base_vertex,
           audit.gl32_fragment_coord_conventions,
           audit.gl32_provoking_vertex, audit.gl32_seamless_cube_map,
           audit.gl32_sync, audit.gl32_texture_multisample,
           audit.gl32_vertex_array_bgra,
           audit.gl40_draw_buffers_blend,
           audit.gl40_draw_indirect, audit.gl40_gpu_shader5,
           audit.gl40_gpu_shader_fp64, audit.gl40_sample_shading,
           audit.gl40_tessellation_shader,
           audit.gl40_texture_buffer_object_rgb32,
           audit.gl40_texture_cube_map_array, audit.gl40_texture_query_lod,
           audit.gl40_transform_feedback2, audit.gl40_transform_feedback3,
           audit.gl41_es2_compatibility, audit.gl41_shader_precision,
           audit.gl41_vertex_attrib_64bit, audit.gl41_viewport_array,
           audit.gl42_base_instance, audit.gl42_conservative_depth,
           audit.gl42_internalformat_query, audit.gl42_shader_atomic_counters,
           audit.gl42_shader_image_load_store,
           audit.gl42_shading_language_420pack,
           audit.gl42_shading_language_packing,
           audit.gl42_texture_compression_bptc,
           audit.gl42_transform_feedback_instanced,
           audit.gl43_compute_shader, audit.gl43_copy_image,
           audit.gl43_es3_compatibility, audit.gl43_arrays_of_arrays,
           audit.gl43_explicit_uniform_location,
           audit.gl43_fragment_layer_viewport,
           audit.gl43_framebuffer_no_attachments,
           audit.gl43_internalformat_query2,
           audit.gl43_robust_buffer_access_behavior,
           audit.gl43_shader_image_size,
           audit.gl43_shader_storage_buffer_object,
           audit.gl43_stencil_texturing,
           audit.gl43_texture_buffer_range,
           audit.gl43_texture_query_levels, audit.gl43_texture_view,
           audit.gl44_buffer_storage, audit.gl44_enhanced_layouts,
           audit.gl44_query_buffer_object,
           audit.gl44_texture_mirror_clamp_to_edge,
           audit.gl44_texture_stencil8,
           audit.gl44_vertex_type_10f_11f_11f_rev,
           audit.gl45_es3_1_compatibility,
           audit.gl45_clip_control,
           audit.gl45_conditional_render_inverted,
           audit.gl45_cull_distance, audit.gl45_derivative_control,
           audit.gl45_shader_texture_image_samples,
           audit.gl45_texture_barrier,
           audit.gl46_gl_spirv, audit.gl46_spirv_extensions,
           audit.gl46_indirect_parameters,
           audit.gl46_polygon_offset_clamp,
           audit.gl46_shader_atomic_counter_ops,
           audit.gl46_shader_draw_parameters,
           audit.gl46_shader_group_vote,
           audit.gl46_texture_filter_anisotropic,
           audit.gl46_transform_feedback_overflow_query);

    printf("AO46 Mesa core limits: texture=%d renderbuffer=%d cube-levels=%d "
           "3d-levels=%d array-layers=%d color-attachments=%d samples=%d "
           "vertex-textures=%d vertex-ubos=%d vertex-stride=%d\n",
           audit.max_texture_size, audit.max_renderbuffer_size,
           audit.max_cube_texture_levels, audit.max_3d_texture_levels,
           audit.max_array_texture_layers, audit.max_color_attachments,
           audit.max_samples, audit.max_vertex_texture_units,
           audit.max_vertex_uniform_blocks, audit.max_vertex_attrib_stride);

    /* Keep this synchronized with Mesa's complete OpenGL 4.6 predicate. */
    return audit.core_version >= 46 && audit.glsl_version >= 460 &&
           audit.max_vertex_uniform_blocks >= 14 &&
           audit.max_vertex_attrib_stride >= 2048 &&
           audit.gl43_compute_shader && audit.gl43_copy_image &&
           audit.gl43_es3_compatibility && audit.gl43_arrays_of_arrays &&
           audit.gl43_explicit_uniform_location &&
           audit.gl43_fragment_layer_viewport &&
           audit.gl43_framebuffer_no_attachments &&
           audit.gl43_internalformat_query2 &&
           audit.gl43_robust_buffer_access_behavior &&
           audit.gl43_shader_image_size &&
           audit.gl43_shader_storage_buffer_object &&
           audit.gl43_stencil_texturing &&
           audit.gl43_texture_buffer_range &&
           audit.gl43_texture_query_levels &&
           audit.gl43_texture_view &&
           audit.gl44_buffer_storage && audit.gl44_enhanced_layouts &&
           audit.gl44_query_buffer_object &&
           audit.gl44_texture_mirror_clamp_to_edge &&
           audit.gl44_texture_stencil8 &&
           audit.gl44_vertex_type_10f_11f_11f_rev &&
           audit.gl45_es3_1_compatibility && audit.gl45_clip_control &&
           audit.gl45_conditional_render_inverted &&
           audit.gl45_cull_distance && audit.gl45_derivative_control &&
           audit.gl45_shader_texture_image_samples &&
           audit.gl45_texture_barrier &&
           audit.gl46_gl_spirv && audit.gl46_spirv_extensions &&
           audit.gl46_indirect_parameters &&
           audit.gl46_polygon_offset_clamp &&
           audit.gl46_shader_atomic_counter_ops &&
           audit.gl46_shader_draw_parameters &&
           audit.gl46_shader_group_vote &&
           audit.gl46_texture_filter_anisotropic &&
           audit.gl46_transform_feedback_overflow_query ? 0 : 1;
}
