#import <Metal/Metal.h>
#import "mtl_pub.h"
#import "nir/nir.h"
#include "nir_to_msl.h"
#import "compiler/shader_info.h"
#include "util/ralloc.h"
#include <stdint.h>

/**
 * Compile a NIR shader to a Metal function.
 * Returns nil on error; sets error if provided.
 */
static id<MTLFunction>
ao46_metal_compile_nir_to_msl_internal(struct nir_shader *nir,
                                       const char *entry_name,
                                       MTLFunctionConstantValues *constants,
                                       uint32_t static_sample_mask,
                                       NSError **error)
{
    (void)constants;

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

    nir_shader_gather_info(work_nir, nir_shader_get_entrypoint(work_nir));
    if (work_nir->info.stage == MESA_SHADER_FRAGMENT) {
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
    msl_preprocess_nir(work_nir);
    msl_preprocess_nir_workarounds(work_nir, 0);
    msl_optimize_nir(work_nir);

    struct nir_to_msl_options translate_options = {
        .mem_ctx = work_nir,
        .disabled_workarounds = 0,
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

    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    /* Keep Mesa shader results conservative until a CTS-backed relaxed mode exists. */
    options.languageVersion = MTLLanguageVersion2_4;

    NSError *compileError = nil;
    id<MTLLibrary> lib = [g_mtl_device newLibraryWithSource:sourceStr
                                                    options:options
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
                                                   UINT32_MAX, error);
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
                                                   sample_mask, error);
}
