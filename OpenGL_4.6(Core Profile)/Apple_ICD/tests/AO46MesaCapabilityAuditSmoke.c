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

    printf("AO46 Mesa core=%d.%d GLSL=%d GL3.3 gates: "
           "blend=%d attrib=%d instancing=%d bit-encoding=%d rgb10=%d "
           "timer=%d packed-vertex=%d swizzle=%d\n"
           "AO46 Mesa GL4.0 gates: blend=%d indirect=%d shader5=%d fp64=%d "
           "sample=%d tess=%d rgb32=%d cube-array=%d lod=%d tf2=%d tf3=%d\n"
           "AO46 Mesa modern gates: GL4.3-SSBO=%d GL4.5-clip-control=%d "
           "GL4.6-indirect-parameters=%d\n",
           audit.core_version / 10, audit.core_version % 10,
           audit.glsl_version, audit.gl33_blend_func_extended,
           audit.gl33_explicit_attrib_location, audit.gl33_instanced_arrays,
           audit.gl33_shader_bit_encoding, audit.gl33_texture_rgb10_a2ui,
           audit.gl33_timer_query, audit.gl33_vertex_type_2_10_10_10_rev,
           audit.gl33_texture_swizzle, audit.gl40_draw_buffers_blend,
           audit.gl40_draw_indirect, audit.gl40_gpu_shader5,
           audit.gl40_gpu_shader_fp64, audit.gl40_sample_shading,
           audit.gl40_tessellation_shader,
           audit.gl40_texture_buffer_object_rgb32,
           audit.gl40_texture_cube_map_array, audit.gl40_texture_query_lod,
           audit.gl40_transform_feedback2, audit.gl40_transform_feedback3,
           audit.gl43_shader_storage_buffer_object,
           audit.gl45_clip_control,
           audit.gl46_indirect_parameters);

    /* Mesa selects GL 4.0 only when every required extension gate is live. */
    return audit.core_version >= 40 &&
           audit.gl40_tessellation_shader &&
           audit.gl40_texture_buffer_object_rgb32 &&
           audit.gl43_shader_storage_buffer_object &&
           audit.gl45_clip_control &&
           audit.gl46_indirect_parameters ? 0 : 1;
}
