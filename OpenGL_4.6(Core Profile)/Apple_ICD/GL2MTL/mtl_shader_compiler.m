#import <Metal/Metal.h>
#import "mtl_pub.h"
#import "nir/nir.h"
#import "nir/nir_builder.h"
#include "nir_to_msl.h"
#import "compiler/shader_info.h"
#include "compiler/glsl_types.h"
#include "AO46MetalAdapter.h"
#include "AO46MesaMSLComputePipeline.h"
#include "util/ralloc.h"
#include <stdint.h>
#include <pthread.h>

static pthread_once_t ao46_metal_glsl_types_once = PTHREAD_ONCE_INIT;

static void
ao46_metal_retain_glsl_types(void)
{
    /* KK clip/cull lowering creates replacement array types after Mesa has
     * handed the shader to the driver. Keep the shared compiler type cache
     * alive for the lifetime of the AO46 process. */
    glsl_type_singleton_init_or_ref();
}

static bool
ao46_metal_lower_fine_derivative(nir_builder *builder,
                                 nir_intrinsic_instr *intrinsic,
                                 void *data)
{
    nir_def *value;
    nir_def *neighbor;
    nir_def *lane;
    nir_def *is_low_lane;
    nir_def *derivative;

    (void)data;
    if (intrinsic->intrinsic != nir_intrinsic_ddx_fine &&
        intrinsic->intrinsic != nir_intrinsic_ddy_fine) {
        return false;
    }

    builder->cursor = nir_before_instr(&intrinsic->instr);
    value = intrinsic->src[0].ssa;
    lane = nir_load_subgroup_invocation(builder);
    if (intrinsic->intrinsic == nir_intrinsic_ddx_fine) {
        neighbor = nir_quad_swap_horizontal(builder, value);
        is_low_lane = nir_ieq_imm(builder, nir_iand_imm(builder, lane, 1), 0);
    } else {
        neighbor = nir_quad_swap_vertical(builder, value);
        is_low_lane = nir_ieq_imm(builder, nir_iand_imm(builder, lane, 2), 0);
    }
    derivative = nir_bcsel(builder, is_low_lane,
                           nir_fsub(builder, neighbor, value),
                           nir_fsub(builder, value, neighbor));
    nir_def_rewrite_uses(&intrinsic->def, derivative);
    nir_instr_remove(&intrinsic->instr);
    return true;
}

static bool
ao46_metal_collect_static_ubo_roots(struct nir_shader *nir,
                                    uint16_t *out_mask)
{
    uint16_t mask = 0;

    if (!nir || !out_mask) {
        return false;
    }

    nir_foreach_function_impl(impl, nir) {
        nir_foreach_block(block, impl) {
            nir_foreach_instr(instr, block) {
                nir_intrinsic_instr *intrinsic;
                unsigned binding;

                if (instr->type != nir_instr_type_intrinsic) {
                    continue;
                }
                intrinsic = nir_instr_as_intrinsic(instr);
                if (intrinsic->intrinsic != nir_intrinsic_load_ubo) {
                    continue;
                }
                if (!nir_src_is_const(intrinsic->src[0])) {
                    return false;
                }
                binding = nir_src_as_uint(intrinsic->src[0]);
                if (binding >= AO46_METAL_MAX_UNIFORM_BINDINGS) {
                    return false;
                }
                mask |= UINT16_C(1) << binding;
            }
        }
    }

    *out_mask = mask;
    return true;
}

static bool
ao46_metal_collect_static_buffer_roots(struct nir_shader *nir,
                                       uint16_t *inout_mask)
{
    uint16_t mask;

    if (!nir || !inout_mask) {
        return false;
    }
    mask = *inout_mask;
    nir_foreach_function_impl(impl, nir) {
        nir_foreach_block(block, impl) {
            nir_foreach_instr(instr, block) {
                nir_intrinsic_instr *intrinsic;
                unsigned binding;

                if (instr->type != nir_instr_type_intrinsic) {
                    continue;
                }
                intrinsic = nir_instr_as_intrinsic(instr);
                if (intrinsic->intrinsic != nir_intrinsic_load_buffer_ptr_kk) {
                    continue;
                }
                binding = nir_intrinsic_binding(intrinsic);
                if (binding == 0) {
                    continue;
                }
                if (binding < 2 || binding >= 16) {
                    return false;
                }
                mask |= UINT16_C(1) << binding;
            }
        }
    }

    *inout_mask = mask;
    return true;
}

/**
 * Compile a NIR shader to a Metal function.
 * Returns nil on error; sets error if provided.
 */
struct ao46_clip_distance_mask_state {
    uint32_t enabled;
    uint32_t seen;
};

static bool
ao46_metal_lower_clip_distance_mask(nir_builder *builder,
                                    nir_intrinsic_instr *intrinsic,
                                    void *data)
{
    struct ao46_clip_distance_mask_state *mask = data;
    unsigned component;

    if (intrinsic->intrinsic != nir_intrinsic_store_clip_distance_kk) {
        return false;
    }
    component = nir_intrinsic_base(intrinsic);
    if (component >= 32) {
        return false;
    }
    /* Mesa has already resolved conditional output writes into one SSA value
     * before this pass. A later store for the same lane is the disabled-plane
     * initializer and must not overwrite the resolved value. */
    if (mask->seen & BITFIELD_BIT(component)) {
        nir_instr_remove(&intrinsic->instr);
        return true;
    }
    mask->seen |= BITFIELD_BIT(component);
    if (!(mask->enabled & BITFIELD_BIT(component))) {
        builder->cursor = nir_before_instr(&intrinsic->instr);
        nir_src_rewrite(&intrinsic->src[0],
                        nir_imm_floatN_t(builder, 0,
                            intrinsic->src[0].ssa->bit_size));
    }
    return true;
}

static bool
ao46_metal_remove_vertex_output(nir_builder *builder,
                                nir_intrinsic_instr *intrinsic,
                                void *data)
{
    (void)builder;
    (void)data;

    switch (intrinsic->intrinsic) {
    case nir_intrinsic_store_output:
    case nir_intrinsic_store_per_vertex_output:
    case nir_intrinsic_store_per_primitive_output:
    case nir_intrinsic_store_per_view_output:
        nir_instr_remove(&intrinsic->instr);
        return true;
    case nir_intrinsic_store_deref: {
        nir_deref_instr *deref = nir_src_as_deref(intrinsic->src[0]);
        if (deref && nir_deref_mode_is(deref, nir_var_shader_out)) {
            nir_instr_remove(&intrinsic->instr);
            return true;
        }
        return false;
    }
    default:
        return false;
    }
}

static id<MTLFunction>
ao46_metal_compile_nir_to_msl_internal(struct nir_shader *nir,
                                       const char *entry_name,
                                       MTLFunctionConstantValues *constants,
                                       uint32_t static_sample_mask,
                                       uint32_t clip_distance_enable_mask,
                                       bool vertex_void_output,
                                       NSError **error)
{
    (void)constants;

    pthread_once(&ao46_metal_glsl_types_once, ao46_metal_retain_glsl_types);

    if (!nir) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid NIR shader"}];
        return nil;
    }

    nir_shader *work_nir = nir_shader_clone(NULL, nir);
    if (!work_nir) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to clone NIR shader"}];
        return nil;
    }

    if (vertex_void_output && work_nir->info.stage == MESA_SHADER_VERTEX) {
        (void)nir_shader_intrinsics_pass(
            work_nir, ao46_metal_remove_vertex_output,
            nir_metadata_control_flow, NULL);
        work_nir->info.outputs_written = 0;
        work_nir->info.clip_distance_array_size = 0;
        work_nir->info.cull_distance_array_size = 0;
        (void)nir_remove_dead_variables(work_nir, nir_var_shader_out, NULL);
    }

    nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));
    uint16_t static_buffer_mask = 0;
    uint16_t static_ubo_mask = 0;
    uint16_t static_image_mask = 0;
    bool uses_draw_id = false;
    if (!AO46MesaNIRLowerRobustBufferAccess(work_nir)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:10
                                             userInfo:@{NSLocalizedDescriptionKey: @"Unsupported robust buffer binding in Metal size-table ABI"}];
        ralloc_free(work_nir);
        return nil;
    }
    if (!AO46MesaNIRLowerBoundedSSBOs(work_nir, &static_buffer_mask)) {
        if (getenv("AO46_DEBUG_NIR_ON_ERROR"))
            nir_print_shader(work_nir, stderr);
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:5
                                             userInfo:@{NSLocalizedDescriptionKey: @"Unbounded SSBO indexing is not supported by the Metal buffer ABI"}];
        ralloc_free(work_nir);
        return nil;
    }
    if (!AO46MesaNIRLowerStaticImages(work_nir, &static_buffer_mask,
                                      &static_image_mask)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:7
                                             userInfo:@{NSLocalizedDescriptionKey: @"Unbounded or unsupported image binding in Metal image ABI"}];
        ralloc_free(work_nir);
        return nil;
    }
    if (!AO46MesaNIRLowerDrawParameters(work_nir, &static_buffer_mask,
                                        &uses_draw_id)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:8
                                             userInfo:@{NSLocalizedDescriptionKey: @"Unsupported shader draw-parameter lowering"}];
        ralloc_free(work_nir);
        return nil;
    }
    if (!ao46_metal_collect_static_buffer_roots(work_nir,
                                                &static_buffer_mask)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:6
                                             userInfo:@{NSLocalizedDescriptionKey: @"NIR uses a Metal buffer root outside the active ABI"}];
        ralloc_free(work_nir);
        return nil;
    }
    if (!ao46_metal_collect_static_ubo_roots(work_nir, &static_ubo_mask)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:9
                                             userInfo:@{NSLocalizedDescriptionKey: @"Dynamic or out-of-range UBO binding in Metal buffer ABI"}];
        ralloc_free(work_nir);
        return nil;
    }
    nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));
    (void)static_image_mask;
    (void)uses_draw_id;
    if (work_nir->info.stage == MESA_SHADER_FRAGMENT) {
        nir_shader_intrinsics_pass(work_nir,
                                   ao46_metal_lower_fine_derivative,
                                   nir_metadata_control_flow, NULL);
        /* Mesa provides the selected fragment variant; lower its MSAA ABI to MSL. */
        if (static_sample_mask != UINT32_MAX) {
            msl_lower_static_sample_mask(work_nir, static_sample_mask);
        }
        if (work_nir->info.fs.uses_sample_shading) {
            msl_nir_lower_sample_shading(work_nir);
        }

        /* The lowering may add FRAG_RESULT_SAMPLE_MASK and system-value inputs. */
        nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));
    }
    if (work_nir->info.stage == MESA_SHADER_VERTEX && !vertex_void_output) {
        (void)msl_ensure_vertex_position_output(work_nir);
        nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));
    }
    if (work_nir->info.cull_distance_array_size > 0 ||
        work_nir->info.clip_distance_array_size > 0) {
        /* Lower the OpenGL-owned array variables while their originating Mesa
         * type cache is still authoritative. KK then receives plain I/O
         * intrinsics and does not attempt to reconstruct foreign array types. */
        (void)nir_lower_io(work_nir,
                           nir_var_shader_in | nir_var_shader_out,
                           glsl_count_attribute_slots,
                           nir_lower_io_lower_64bit_to_32 |
                               nir_lower_io_use_interpolated_input_intrinsics);
    }
    /* Reuse Mesa's Metal texture lowering without KK Vulkan's descriptor-
     * sourced sampler LOD bias. Gallium already carries explicit shader bias,
     * while nir_texop_lod_bias requires KK's Vulkan descriptor layout. */
    const nir_lower_tex_options texture_options = {
        .lower_txp = ~0u,
        .lower_1d = true,
        .lower_tg4_offsets = true,
        .lower_txf_offset = true,
        .lower_txd_cube_map = true,
    };
    (void)nir_lower_tex(work_nir, &texture_options);
    msl_preprocess_nir(work_nir);
    if (work_nir->info.cull_distance_array_size > 0 ||
        work_nir->info.clip_distance_array_size > 0) {
        const nir_shader_compiler_options *source_options = work_nir->options;
        nir_shader_compiler_options clip_options = *source_options;

        /* Gallium supplies deref-based OpenGL arrays while KK's native path
         * supplies compact scalar I/O. First let KK lower all shader I/O to
         * intrinsics, then apply its compact clip/cull separation contract. */
        clip_options.compact_arrays = true;
        work_nir->options = &clip_options;
        msl_nir_lower_clip_cull_distance(
            work_nir, work_nir->info.cull_distance_array_size);
        work_nir->options = source_options;
        if (work_nir->info.stage == MESA_SHADER_VERTEX) {
            struct ao46_clip_distance_mask_state state = {
                clip_distance_enable_mask, 0
            };
            (void)nir_shader_intrinsics_pass(
                work_nir, ao46_metal_lower_clip_distance_mask,
                nir_metadata_control_flow, &state);
        }
        nir_shader_gather_info(work_nir,
                               nir_shader_get_entrypoint(work_nir));
    }
    msl_preprocess_nir_workarounds(work_nir, 0);
    msl_optimize_nir(work_nir);
    /* Subgroup lowering can introduce Metal system-value inputs. */
    nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));

    /* The static root masks are an emitter contract, not merely an early
     * lowering hint. Rebuild them from the final NIR so a late Mesa/KK pass
     * cannot leave a load_ubo without the matching MSL entry-point argument. */
    static_buffer_mask = 0;
    static_ubo_mask = 0;
    if (!ao46_metal_collect_static_buffer_roots(work_nir,
                                                &static_buffer_mask) ||
        !ao46_metal_collect_static_ubo_roots(work_nir, &static_ubo_mask)) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:9
                                             userInfo:@{NSLocalizedDescriptionKey: @"Final NIR has a dynamic or out-of-range Metal buffer binding"}];
        ralloc_free(work_nir);
        return nil;
    }

    struct nir_to_msl_options translate_options = {
        .mem_ctx = work_nir,
        .disabled_workarounds = 0,
        .use_static_sampler_bindings = true,
        .vertex_void_output = vertex_void_output,
        .static_buffer_mask = static_buffer_mask,
        .static_ubo_mask = static_ubo_mask,
        .static_ubo_first_buffer = AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX,
    };

    if (work_nir->info.stage == MESA_SHADER_FRAGMENT) {
        for (uint32_t i = 0; i < MAX_DRAW_BUFFERS; ++i) {
            translate_options.rts_component_count[i] = 4;
        }
    }

    char *msl_source = nir_to_msl(work_nir, &translate_options);
    if (!msl_source) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:3
                                             userInfo:@{NSLocalizedDescriptionKey: @"NIR->MSL translation failed"}];
        ralloc_free(work_nir);
        return nil;
    }

    /* KK reflects a partial Mesa position store as a partial Metal member.
     * Metal rejects float2/float3 values carrying the [[position]] attribute,
     * even though the corresponding .xy/.xyz store is otherwise legal. The
     * position ABI is always float4; widening only the declaration preserves
     * the generated store semantics and keeps this fix local to AO46. */
    if (work_nir->info.stage == MESA_SHADER_VERTEX) {
        char *position_decl = strstr(msl_source,
                                     "float2 position [[position]];");
        if (position_decl) {
            position_decl[5] = '4';
        }
    }

    const char *translated_entry_name = nir_shader_get_entrypoint(work_nir)->function->name;
    if (!translated_entry_name) {
        translated_entry_name = entry_name ? entry_name : "main_entrypoint";
    }

    NSString *sourceStr = [NSString stringWithUTF8String:msl_source];
    NSString *entryName = [NSString stringWithUTF8String:translated_entry_name];

    if (getenv("AO46_TRACE_RUNTIME")) {
        fprintf(stderr,
                "[AO46Metal] translated %s shader entry=%s\n%s\n",
                _mesa_shader_stage_to_string(work_nir->info.stage),
                translated_entry_name,
                msl_source);
    }

    NSError *compileError = nil;
    id<MTLLibrary> lib = [g_mtl_device newLibraryWithSource:sourceStr
                                                    options:nil
                                                      error:&compileError];
    if (!lib) {
        if (error) *error = compileError;
        NSLog(@"MSL compilation error: %@", compileError);
        fprintf(stderr, "AO46 Metal generated MSL follows:\n%s\n", msl_source);
        fflush(stderr);
        ralloc_free(work_nir);
        return nil;
    }

    id<MTLFunction> func = [lib newFunctionWithName:entryName];
    if (!func) {
        if (error) *error = [NSError errorWithDomain:@"AO46Metal" code:4
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Translated entry function '%@' not found", entryName]}];
    }

    ralloc_free(work_nir);
    return func;
}

id<MTLFunction>
ao46_metal_compile_nir_to_msl(struct nir_shader *nir,
                              const char *entry_name,
                              MTLFunctionConstantValues *constants,
                              NSError **error)
{
    return ao46_metal_compile_nir_to_msl_internal(nir, entry_name, constants,
                                                   UINT32_MAX, UINT32_MAX,
                                                   false,
                                                   error);
}

id<MTLFunction>
ao46_metal_compile_nir_to_msl_with_static_sample_mask(
    struct nir_shader *nir,
    const char *entry_name,
    MTLFunctionConstantValues *constants,
    uint32_t sample_mask,
    NSError **error)
{
    return ao46_metal_compile_nir_to_msl_internal(nir, entry_name, constants,
                                                   sample_mask, UINT32_MAX,
                                                   false,
                                                   error);
}

id<MTLFunction>
ao46_metal_compile_nir_to_msl_with_clip_mask(
    struct nir_shader *nir,
    const char *entry_name,
    MTLFunctionConstantValues *constants,
    uint32_t clip_distance_enable_mask,
    NSError **error)
{
    return ao46_metal_compile_nir_to_msl_internal(
        nir, entry_name, constants, UINT32_MAX,
        clip_distance_enable_mask, false, error);
}

id<MTLFunction>
ao46_metal_compile_nir_to_msl_raster_discard(
    struct nir_shader *nir,
    const char *entry_name,
    MTLFunctionConstantValues *constants,
    NSError **error)
{
    return ao46_metal_compile_nir_to_msl_internal(
        nir, entry_name, constants, UINT32_MAX, UINT32_MAX, true, error);
}
