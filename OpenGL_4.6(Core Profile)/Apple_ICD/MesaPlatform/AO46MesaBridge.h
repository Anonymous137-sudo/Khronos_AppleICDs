#ifndef AO46_MESA_BRIDGE_H
#define AO46_MESA_BRIDGE_H

#include <stdbool.h>

#include <OpenGL/CGLTypes.h>
#include "AppleOpenGL46Runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialise the Mesa Gallium screen.
 * Must be called before any other bridge function.
 */
CGLError AO46MesaInit(void);

/*
 * Snapshot the state-tracker inputs that decide the advertised core profile.
 * The audit is diagnostic only: it never raises capabilities or overrides a
 * Mesa version decision.
 */
struct AO46MesaCoreCapabilityAudit {
    int core_version;
    int glsl_version;
    int max_texture_size;
    int max_renderbuffer_size;
    int max_cube_texture_levels;
    int max_3d_texture_levels;
    int max_array_texture_layers;
    int max_color_attachments;
    int max_samples;
    int max_vertex_texture_units;
    int max_vertex_uniform_blocks;
    int max_vertex_attrib_stride;
    bool gl14_shadow;
    bool gl20_vertex_shader;
    bool gl20_fragment_shader;
    bool gl20_texture_npot;
    bool gl20_blend_equation_separate;
    bool gl20_stencil_two_side;
    bool gl21_texture_srgb;
    bool gl30_depth_buffer_float;
    bool gl30_half_float_vertex;
    bool gl30_map_buffer_range;
    bool gl30_shader_texture_lod;
    bool gl30_texture_float;
    bool gl30_texture_rg;
    bool gl30_texture_compression_rgtc;
    bool gl30_draw_buffers2;
    bool gl30_framebuffer_object;
    bool gl30_framebuffer_srgb;
    bool gl30_packed_float;
    bool gl30_texture_array;
    bool gl30_texture_integer;
    bool gl30_texture_shared_exponent;
    bool gl30_transform_feedback;
    bool gl30_conditional_render;
    bool gl31_draw_instanced;
    bool gl31_uniform_buffer_object;
    bool gl31_texture_snorm;
    bool gl31_primitive_restart;
    bool gl31_texture_rectangle;
    bool gl32_depth_clamp;
    bool gl32_draw_elements_base_vertex;
    bool gl32_fragment_coord_conventions;
    bool gl32_provoking_vertex;
    bool gl32_seamless_cube_map;
    bool gl32_sync;
    bool gl32_texture_multisample;
    bool gl32_vertex_array_bgra;
    bool gl33_blend_func_extended;
    bool gl33_explicit_attrib_location;
    bool gl33_instanced_arrays;
    bool gl33_shader_bit_encoding;
    bool gl33_texture_rgb10_a2ui;
    bool gl33_timer_query;
    bool gl33_vertex_type_2_10_10_10_rev;
    bool gl33_texture_swizzle;
    bool gl40_draw_buffers_blend;
    bool gl40_draw_indirect;
    bool gl40_gpu_shader5;
    bool gl40_gpu_shader_fp64;
    bool gl40_sample_shading;
    bool gl40_tessellation_shader;
    bool gl40_texture_buffer_object_rgb32;
    bool gl40_texture_cube_map_array;
    bool gl40_texture_query_lod;
    bool gl40_transform_feedback2;
    bool gl40_transform_feedback3;
    bool gl41_es2_compatibility;
    bool gl41_shader_precision;
    bool gl41_vertex_attrib_64bit;
    bool gl41_viewport_array;
    bool gl42_base_instance;
    bool gl42_conservative_depth;
    bool gl42_internalformat_query;
    bool gl42_shader_atomic_counters;
    bool gl42_shader_image_load_store;
    bool gl42_shading_language_420pack;
    bool gl42_shading_language_packing;
    bool gl42_texture_compression_bptc;
    bool gl42_transform_feedback_instanced;
    bool gl43_compute_shader;
    bool gl43_copy_image;
    bool gl43_es3_compatibility;
    bool gl43_arrays_of_arrays;
    bool gl43_explicit_uniform_location;
    bool gl43_fragment_layer_viewport;
    bool gl43_framebuffer_no_attachments;
    bool gl43_internalformat_query2;
    bool gl43_robust_buffer_access_behavior;
    bool gl43_shader_image_size;
    bool gl43_shader_storage_buffer_object;
    bool gl43_stencil_texturing;
    bool gl43_texture_buffer_range;
    bool gl43_texture_query_levels;
    bool gl43_texture_view;
    bool gl44_buffer_storage;
    bool gl44_enhanced_layouts;
    bool gl44_query_buffer_object;
    bool gl44_texture_mirror_clamp_to_edge;
    bool gl44_texture_stencil8;
    bool gl44_vertex_type_10f_11f_11f_rev;
    bool gl45_es3_1_compatibility;
    bool gl45_clip_control;
    bool gl45_conditional_render_inverted;
    bool gl45_cull_distance;
    bool gl45_derivative_control;
    bool gl45_shader_texture_image_samples;
    bool gl45_texture_barrier;
    bool gl46_gl_spirv;
    bool gl46_spirv_extensions;
    bool gl46_indirect_parameters;
    bool gl46_polygon_offset_clamp;
    bool gl46_shader_atomic_counter_ops;
    bool gl46_shader_draw_parameters;
    bool gl46_shader_group_vote;
    bool gl46_texture_filter_anisotropic;
    bool gl46_transform_feedback_overflow_query;
};

CGLError AO46MesaAuditCoreCapabilities(
    struct AO46MesaCoreCapabilityAudit *out_audit);

/**
 * Create a Mesa state tracker context from a pixel format.
 * share can be NULL.
 */
CGLError AO46MesaCreateContext(AO46PixelFormatRef pix,
                               AO46ContextRef share,
                               AO46ContextRef *out_ctx);

/**
 * Destroy a Mesa context.
 */
void AO46MesaDestroyContext(AO46ContextRef ctx);

/**
 * Make a context current on the calling thread.
 */
CGLError AO46MesaMakeCurrent(AO46ContextRef ctx);

/**
 * Get the current context for the thread.
 */
AO46ContextRef AO46MesaGetCurrent(void);

/**
 * Attach a window (NSView* or NSWindow*) as the drawable.
 * The bridge will create a CAMetalLayer and bind it.
 */
CGLError AO46MesaAttachWindow(AO46ContextRef ctx, void *window);

/**
 * Attach an offscreen buffer (manual memory) as drawable.
 */
CGLError AO46MesaAttachOffscreen(AO46ContextRef ctx,
                                 void *baseaddr,
                                 GLsizei width,
                                 GLsizei height,
                                 GLint rowbytes);

/**
 * Attach a PBuffer (wrapped as an offscreen render target).
 */
CGLError AO46MesaAttachPBuffer(AO46ContextRef ctx,
                               AO46PBufferRef pbuffer,
                               GLenum face,
                               GLint level,
                               GLint screen);

/**
 * Import the currently selected pbuffer image into the currently bound texture
 * for the pbuffer's target in the target context.
 */
CGLError AO46MesaImportPBufferToBoundTexture(AO46ContextRef ctx,
                                             AO46PBufferRef pbuffer,
                                             GLenum source);

/**
 * Detach any drawable.
 */
CGLError AO46MesaDetachDrawable(AO46ContextRef ctx);

/**
 * Update the drawable (e.g., window resize).
 */
CGLError AO46MesaUpdateDrawable(AO46ContextRef ctx);

/**
 * Flush the current drawable (swap buffers).
 */
CGLError AO46MesaSwapBuffers(AO46ContextRef ctx);

/**
 * Retrieve the OpenGL function pointer from Mesa's glapi.
 */
void *AO46MesaGetProcAddress(const char *procname);

/**
 * Query pixel format attributes from Mesa's capabilities.
 */
CGLError AO46MesaDescribePixelFormat(AO46PixelFormatRef pix,
                                     GLint pix_num,
                                     CGLPixelFormatAttribute attrib,
                                     GLint *value);

/**
 * PBuffer creation/destruction – now handled by Mesa's resources.
 */
CGLError AO46MesaCreatePBuffer(GLsizei width,
                               GLsizei height,
                               GLenum target,
                               GLenum internal_format,
                               GLint max_level,
                               AO46PBufferRef *out_pbuffer);
void AO46MesaDestroyPBuffer(AO46PBufferRef pbuffer);
CGLError AO46MesaDescribePBuffer(AO46PBufferRef pbuffer,
                                 GLsizei *width,
                                 GLsizei *height,
                                 GLenum *target,
                                 GLenum *internal_format,
                                 GLint *mipmap);

#ifdef __cplusplus
}
#endif

#endif /* AO46_MESA_BRIDGE_H */
