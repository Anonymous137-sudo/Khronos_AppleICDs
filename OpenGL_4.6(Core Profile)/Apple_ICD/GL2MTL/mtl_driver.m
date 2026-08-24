#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>
#import <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#include "pipe/p_context.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "pipe/p_defines.h"
#include "util/u_inlines.h"
#include "util/u_memory.h"
#include "util/u_screen.h"
#include "util/format/u_format.h"
#include "util/u_math.h"
#include "util/u_debug.h"
#include "util/u_hash_table.h"
#include "util/ralloc.h"
#include "util/blend.h"
#include "util/u_framebuffer.h"
#include "util/u_upload_mgr.h"
#include "state_tracker/st_context.h"
#include "nir/nir.h"
#include "nir/nir_builder.h"
#include "compiler/shader_enums.h"
#include "compiler/glsl_types.h"

#include "mtl_pub.h"
#include "AO46MTLGallium.h"
#include "AO46MesaMSLComputePipeline.h"
#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MesaNIRBufferTexture.h"
#include "AO46MesaNIRVertexInput.h"
#include "AO46MesaPolyKernelCatalog.h"
#include "AO46MesaPolyKernelExecutor.h"
#include "AO46MesaPolyTessellation.h"
#include "poly/nir/poly_nir.h"
#include "poly/tessellator.h"

#define AO46_MAX_SAMPLERS 16  /* Conservative graphics-stage sampler budget */
#define AO46_MAX_SHADER_BUFFERS 8
#define AO46_MAX_IMAGE_UNITS 8
#define AO46_BUFFER_SLOT_CONST0 0
#define AO46_BUFFER_SLOT_SAMPLER_TABLE 1
#define AO46_BUFFER_SLOT_PER_DRAW 2
#define AO46_BUFFER_SLOT_SHADER_BUFFER_BASE 2
#define AO46_BUFFER_SLOT_RGB32_ADDRESS_TABLE 10
#define AO46_BUFFER_SLOT_DRAW_PARAMETERS AO46_MESA_DRAW_PARAMETER_BINDING
#define AO46_BUFFER_SLOT_STREAM_OUTPUT_DESCRIPTORS \
    AO46_MESA_STREAM_OUTPUT_DESCRIPTOR_BINDING
#define AO46_BUFFER_SLOT_VERTEX_BASE 16
#ifndef MAX_IMAGE_UNITS
#define MAX_IMAGE_UNITS 8  /* GL_MAX_IMAGE_UNITS */
#endif

/* ======================================================================
 * Metal global objects (defined here, declared extern in mtl_pub.h)
 * ====================================================================== */
id<MTLDevice> g_mtl_device = nil;
id<MTLCommandQueue> g_mtl_queue = nil;
static struct AO46MetalAdapter g_mtl_adapter = {0};
static pthread_mutex_t g_mtl_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_mtl_screen_count = 0;
static unsigned g_mtl_pending_screen_creations = 0;

static void
ao46_metal_release_shared_objects_locked(void)
{
    AO46MetalAdapterDestroy(&g_mtl_adapter);
    [g_mtl_queue release];
    [g_mtl_device release];
    g_mtl_queue = nil;
    g_mtl_device = nil;
}

static void
ao46_metal_context_flush(struct pipe_context *ctx,
                         struct pipe_fence_handle **fence,
                         unsigned flags);
static void
ao46_metal_flush_for_resource_op(struct pipe_context *ctx);

static bool ao46_metal_init(void)
{
    pthread_mutex_lock(&g_mtl_lock);
    if (!g_mtl_device) {
        g_mtl_device = MTLCreateSystemDefaultDevice();
        if (!g_mtl_device) {
            pthread_mutex_unlock(&g_mtl_lock);
            return false;
        }
        g_mtl_queue = [g_mtl_device newCommandQueue];
        if (!g_mtl_queue) {
            ao46_metal_release_shared_objects_locked();
            pthread_mutex_unlock(&g_mtl_lock);
            return false;
        }
    }
    pthread_mutex_unlock(&g_mtl_lock);
    return true;
}

static bool
ao46_metal_init_from_adapter(const struct AO46MetalAdapter *adapter)
{
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;

    if (!AO46MetalAdapterIsCurrent(adapter)) {
        return false;
    }

    device = (__bridge id<MTLDevice>)adapter->device;
    queue = (__bridge id<MTLCommandQueue>)adapter->queue;
    pthread_mutex_lock(&g_mtl_lock);
    if (g_mtl_device || g_mtl_queue) {
        const bool matches = g_mtl_device == device && g_mtl_queue == queue;
        pthread_mutex_unlock(&g_mtl_lock);
        return matches;
    }

    /* Keep one adapter-owned lifetime for every context submission carrier. */
    if (!AO46MetalAdapterCopyRetained(adapter, &g_mtl_adapter)) {
        pthread_mutex_unlock(&g_mtl_lock);
        return false;
    }
    g_mtl_device = [device retain];
    g_mtl_queue = [queue retain];
    pthread_mutex_unlock(&g_mtl_lock);
    return true;
}

static id<MTLCommandBuffer> ao46_metal_get_command_buffer(void)
{
    return [g_mtl_queue commandBuffer];
}

static bool ao46_metal_texture_uses_slices(const struct pipe_resource *res);
static bool ao46_metal_texture_is_3d(const struct pipe_resource *res);
static id<MTLTexture> ao46_metal_create_texture_view(id<MTLTexture> texture,
                                                     MTLPixelFormat pixel_format,
                                                     MTLTextureType texture_type,
                                                     unsigned first_level,
                                                     unsigned level_count,
                                                     unsigned first_slice,
                                                     unsigned slice_count);

static void
ao46_metal_commit_command_buffer(id<MTLCommandBuffer> cmd_buffer, bool wait)
{
    if (!cmd_buffer) {
        return;
    }

    [cmd_buffer commit];
    if (wait) {
        [cmd_buffer waitUntilCompleted];
    }
}

static bool
ao46_metal_prepare_texture_for_cpu_read(id<MTLTexture> texture)
{
    id<MTLCommandBuffer> cmd_buffer;
    id<MTLBlitCommandEncoder> blit;

    if (!texture) {
        return false;
    }

    if (texture.storageMode != MTLStorageModeManaged) {
        return true;
    }

    cmd_buffer = ao46_metal_get_command_buffer();
    if (!cmd_buffer) {
        return false;
    }

    blit = [cmd_buffer blitCommandEncoder];
    if (!blit) {
        return false;
    }

    [blit synchronizeResource:texture];
    [blit endEncoding];
    ao46_metal_commit_command_buffer(cmd_buffer, true);
    return true;
}

static bool
ao46_metal_texture_region_read_multisample(id<MTLTexture> texture,
                                           const struct pipe_resource *res,
                                           unsigned level,
                                           const struct pipe_box *box,
                                           void *dst,
                                           unsigned stride)
{
    id<MTLTexture> source_texture = nil;
    id<MTLTexture> resolve_texture = nil;
    id<MTLCommandBuffer> cmd_buffer = nil;
    id<MTLRenderCommandEncoder> encoder = nil;
    MTLRenderPassDescriptor *rpd = nil;
    MTLTextureDescriptor *desc = nil;
    unsigned mip_width;
    unsigned mip_height;
    bool ok = false;

    if (!texture || !res || !box || !dst || box->depth != 1 ||
        ao46_metal_texture_uses_slices(res) || ao46_metal_texture_is_3d(res)) {
        return false;
    }

    mip_width = MAX2(u_minify(res->width0, level), 1u);
    mip_height = MAX2(u_minify(res->height0, level), 1u);

    if (level == 0) {
        source_texture = [texture retain];
    } else {
        source_texture = ao46_metal_create_texture_view(texture,
                                                        texture.pixelFormat,
                                                        texture.textureType,
                                                        level,
                                                        1u,
                                                        0u,
                                                        1u);
    }
    if (!source_texture) {
        return false;
    }

    desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2D;
    desc.pixelFormat = texture.pixelFormat;
    desc.width = mip_width;
    desc.height = mip_height;
    desc.depth = 1;
    desc.arrayLength = 1;
    desc.mipmapLevelCount = 1;
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModeManaged;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

    resolve_texture = [g_mtl_device newTextureWithDescriptor:desc];
    [desc release];
    if (!resolve_texture) {
        [source_texture release];
        return false;
    }

    cmd_buffer = ao46_metal_get_command_buffer();
    if (!cmd_buffer) {
        [resolve_texture release];
        [source_texture release];
        return false;
    }

    rpd = [[MTLRenderPassDescriptor alloc] init];
    rpd.colorAttachments[0].texture = source_texture;
    rpd.colorAttachments[0].resolveTexture = resolve_texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    encoder = [cmd_buffer renderCommandEncoderWithDescriptor:rpd];
    [encoder endEncoding];
    [rpd release];
    ao46_metal_commit_command_buffer(cmd_buffer, true);

    if (!ao46_metal_prepare_texture_for_cpu_read(resolve_texture)) {
        [resolve_texture release];
        [source_texture release];
        return false;
    }

    [resolve_texture getBytes:dst
                  bytesPerRow:stride
                   fromRegion:MTLRegionMake2D(box->x, box->y, box->width, box->height)
                  mipmapLevel:0];
    ok = true;

    [resolve_texture release];
    [source_texture release];
    return ok;
}

static MTLPixelFormat
ao46_metal_pixel_format(enum pipe_format format)
{
    switch (format) {
        case PIPE_FORMAT_R8_UNORM:
            return MTLPixelFormatR8Unorm;
        case PIPE_FORMAT_R8_SNORM:
            return MTLPixelFormatR8Snorm;
        case PIPE_FORMAT_R8_UINT:
            return MTLPixelFormatR8Uint;
        case PIPE_FORMAT_R8_SINT:
            return MTLPixelFormatR8Sint;
        case PIPE_FORMAT_R8G8_UNORM:
            return MTLPixelFormatRG8Unorm;
        case PIPE_FORMAT_R8G8_SNORM:
            return MTLPixelFormatRG8Snorm;
        case PIPE_FORMAT_R8G8_UINT:
            return MTLPixelFormatRG8Uint;
        case PIPE_FORMAT_R8G8_SINT:
            return MTLPixelFormatRG8Sint;
        case PIPE_FORMAT_B8G8R8A8_UNORM:
            return MTLPixelFormatBGRA8Unorm;
        case PIPE_FORMAT_B8G8R8A8_SRGB:
            return MTLPixelFormatBGRA8Unorm_sRGB;
        case PIPE_FORMAT_R8G8B8A8_UNORM:
            return MTLPixelFormatRGBA8Unorm;
        case PIPE_FORMAT_R8G8B8A8_SRGB:
            return MTLPixelFormatRGBA8Unorm_sRGB;
        case PIPE_FORMAT_R8G8B8A8_SNORM:
            return MTLPixelFormatRGBA8Snorm;
        case PIPE_FORMAT_R8G8B8A8_UINT:
            return MTLPixelFormatRGBA8Uint;
        case PIPE_FORMAT_R8G8B8A8_SINT:
            return MTLPixelFormatRGBA8Sint;
        case PIPE_FORMAT_R10G10B10A2_UNORM:
            return MTLPixelFormatRGB10A2Unorm;
        case PIPE_FORMAT_B10G10R10A2_UNORM:
            return MTLPixelFormatBGR10A2Unorm;
        case PIPE_FORMAT_R10G10B10A2_UINT:
            return MTLPixelFormatRGB10A2Uint;
        case PIPE_FORMAT_R16_UNORM:
            return MTLPixelFormatR16Unorm;
        case PIPE_FORMAT_R16_SNORM:
            return MTLPixelFormatR16Snorm;
        case PIPE_FORMAT_R16_UINT:
            return MTLPixelFormatR16Uint;
        case PIPE_FORMAT_R16_SINT:
            return MTLPixelFormatR16Sint;
        case PIPE_FORMAT_R16_FLOAT:
            return MTLPixelFormatR16Float;
        case PIPE_FORMAT_R16G16_UNORM:
            return MTLPixelFormatRG16Unorm;
        case PIPE_FORMAT_R16G16_SNORM:
            return MTLPixelFormatRG16Snorm;
        case PIPE_FORMAT_R16G16_UINT:
            return MTLPixelFormatRG16Uint;
        case PIPE_FORMAT_R16G16_SINT:
            return MTLPixelFormatRG16Sint;
        case PIPE_FORMAT_R16G16_FLOAT:
            return MTLPixelFormatRG16Float;
        case PIPE_FORMAT_R16G16B16A16_UNORM:
            return MTLPixelFormatRGBA16Unorm;
        case PIPE_FORMAT_R16G16B16A16_SNORM:
            return MTLPixelFormatRGBA16Snorm;
        case PIPE_FORMAT_R16G16B16A16_UINT:
            return MTLPixelFormatRGBA16Uint;
        case PIPE_FORMAT_R16G16B16A16_SINT:
            return MTLPixelFormatRGBA16Sint;
        case PIPE_FORMAT_R16G16B16A16_FLOAT:
            return MTLPixelFormatRGBA16Float;
        case PIPE_FORMAT_R11G11B10_FLOAT:
            return MTLPixelFormatRG11B10Float;
        case PIPE_FORMAT_R9G9B9E5_FLOAT:
            return MTLPixelFormatRGB9E5Float;
        case PIPE_FORMAT_R32_UINT:
            return MTLPixelFormatR32Uint;
        case PIPE_FORMAT_R32_SINT:
            return MTLPixelFormatR32Sint;
        case PIPE_FORMAT_R32_FLOAT:
            return MTLPixelFormatR32Float;
        case PIPE_FORMAT_R32G32_UINT:
            return MTLPixelFormatRG32Uint;
        case PIPE_FORMAT_R32G32_SINT:
            return MTLPixelFormatRG32Sint;
        case PIPE_FORMAT_R32G32_FLOAT:
            return MTLPixelFormatRG32Float;
        case PIPE_FORMAT_R32G32B32A32_UINT:
            return MTLPixelFormatRGBA32Uint;
        case PIPE_FORMAT_R32G32B32A32_SINT:
            return MTLPixelFormatRGBA32Sint;
        case PIPE_FORMAT_R32G32B32A32_FLOAT:
            return MTLPixelFormatRGBA32Float;
        case PIPE_FORMAT_Z32_FLOAT:
            return MTLPixelFormatDepth32Float;
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
            return MTLPixelFormatDepth32Float_Stencil8;
        case PIPE_FORMAT_RGTC1_UNORM:
            return MTLPixelFormatBC4_RUnorm;
        case PIPE_FORMAT_RGTC1_SNORM:
            return MTLPixelFormatBC4_RSnorm;
        case PIPE_FORMAT_RGTC2_UNORM:
            return MTLPixelFormatBC5_RGUnorm;
        case PIPE_FORMAT_RGTC2_SNORM:
            return MTLPixelFormatBC5_RGSnorm;
        default:
            return MTLPixelFormatInvalid;
    }
}

static bool
ao46_metal_buffer_texture_format_supported(enum pipe_format format)
{
    if (util_format_is_compressed(format) ||
        util_format_is_depth_or_stencil(format) ||
        util_format_get_blockwidth(format) != 1 ||
        util_format_get_blockheight(format) != 1) {
        return false;
    }

    return ao46_metal_pixel_format(format) != MTLPixelFormatInvalid;
}

static bool
ao46_metal_rgb32_buffer_texture_format(enum pipe_format format)
{
    return format == PIPE_FORMAT_R32G32B32_FLOAT ||
           format == PIPE_FORMAT_R32G32B32_UINT ||
           format == PIPE_FORMAT_R32G32B32_SINT;
}

static id<MTLTexture>
ao46_metal_create_buffer_texture_view(id<MTLBuffer> buffer,
                                      enum pipe_format format,
                                      unsigned offset,
                                      unsigned size)
{
    unsigned blocksize;
    unsigned texel_count;
    MTLTextureDescriptor *desc;

    if (!buffer || !size) {
        return nil;
    }

    if (!ao46_metal_buffer_texture_format_supported(format)) {
        return nil;
    }

    blocksize = util_format_get_blocksize(format);
    if (!blocksize || (offset % blocksize) != 0 || size < blocksize) {
        return nil;
    }

    texel_count = size / blocksize;
    if (!texel_count) {
        return nil;
    }

    desc = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:ao46_metal_pixel_format(format)
                                                                 width:texel_count
                                                       resourceOptions:MTLResourceStorageModeShared
                                                                 usage:MTLTextureUsageShaderRead];
    if (!desc) {
        return nil;
    }

    return [buffer newTextureWithDescriptor:desc offset:offset bytesPerRow:0];
}

static MTLVertexFormat
ao46_metal_vertex_format(enum pipe_format format)
{
    switch (format) {
        case PIPE_FORMAT_R32_UINT:
            return MTLVertexFormatUInt;
        case PIPE_FORMAT_R32_SINT:
            return MTLVertexFormatInt;
        case PIPE_FORMAT_R32_FLOAT:
            return MTLVertexFormatFloat;
        case PIPE_FORMAT_R32G32_UINT:
            return MTLVertexFormatUInt2;
        case PIPE_FORMAT_R32G32_SINT:
            return MTLVertexFormatInt2;
        case PIPE_FORMAT_R32G32_FLOAT:
            return MTLVertexFormatFloat2;
        case PIPE_FORMAT_R32G32B32_UINT:
            return MTLVertexFormatUInt3;
        case PIPE_FORMAT_R32G32B32_SINT:
            return MTLVertexFormatInt3;
        case PIPE_FORMAT_R32G32B32_FLOAT:
            return MTLVertexFormatFloat3;
        case PIPE_FORMAT_R32G32B32A32_UINT:
            return MTLVertexFormatUInt4;
        case PIPE_FORMAT_R32G32B32A32_SINT:
            return MTLVertexFormatInt4;
        case PIPE_FORMAT_R32G32B32A32_FLOAT:
            return MTLVertexFormatFloat4;
        case PIPE_FORMAT_R16_FLOAT:
            return MTLVertexFormatHalf;
        case PIPE_FORMAT_R16_UINT:
            return MTLVertexFormatUShort;
        case PIPE_FORMAT_R16_SINT:
            return MTLVertexFormatShort;
        case PIPE_FORMAT_R16_UNORM:
            return MTLVertexFormatUShortNormalized;
        case PIPE_FORMAT_R16_SNORM:
            return MTLVertexFormatShortNormalized;
        case PIPE_FORMAT_R16G16_FLOAT:
            return MTLVertexFormatHalf2;
        case PIPE_FORMAT_R16G16_UINT:
            return MTLVertexFormatUShort2;
        case PIPE_FORMAT_R16G16_SINT:
            return MTLVertexFormatShort2;
        case PIPE_FORMAT_R16G16_UNORM:
            return MTLVertexFormatUShort2Normalized;
        case PIPE_FORMAT_R16G16_SNORM:
            return MTLVertexFormatShort2Normalized;
        case PIPE_FORMAT_R16G16B16_FLOAT:
            return MTLVertexFormatHalf3;
        case PIPE_FORMAT_R16G16B16_UINT:
            return MTLVertexFormatUShort3;
        case PIPE_FORMAT_R16G16B16_SINT:
            return MTLVertexFormatShort3;
        case PIPE_FORMAT_R16G16B16_UNORM:
            return MTLVertexFormatUShort3Normalized;
        case PIPE_FORMAT_R16G16B16_SNORM:
            return MTLVertexFormatShort3Normalized;
        case PIPE_FORMAT_R16G16B16A16_FLOAT:
            return MTLVertexFormatHalf4;
        case PIPE_FORMAT_R16G16B16A16_UINT:
            return MTLVertexFormatUShort4;
        case PIPE_FORMAT_R16G16B16A16_SINT:
            return MTLVertexFormatShort4;
        case PIPE_FORMAT_R16G16B16A16_SNORM:
            return MTLVertexFormatShort4Normalized;
        case PIPE_FORMAT_R8G8B8A8_UNORM:
            return MTLVertexFormatUChar4Normalized;
        case PIPE_FORMAT_B8G8R8A8_UNORM:
            return MTLVertexFormatUChar4Normalized_BGRA;
        case PIPE_FORMAT_R8G8B8A8_SNORM:
            return MTLVertexFormatChar4Normalized;
        case PIPE_FORMAT_R8G8B8A8_UINT:
            return MTLVertexFormatUChar4;
        case PIPE_FORMAT_R8G8B8A8_SINT:
            return MTLVertexFormatChar4;
        case PIPE_FORMAT_R8_UINT:
            return MTLVertexFormatUChar;
        case PIPE_FORMAT_R8_SINT:
            return MTLVertexFormatChar;
        case PIPE_FORMAT_R8_UNORM:
            return MTLVertexFormatUCharNormalized;
        case PIPE_FORMAT_R8_SNORM:
            return MTLVertexFormatCharNormalized;
        case PIPE_FORMAT_R8G8_UINT:
            return MTLVertexFormatUChar2;
        case PIPE_FORMAT_R8G8_SINT:
            return MTLVertexFormatChar2;
        case PIPE_FORMAT_R8G8_UNORM:
            return MTLVertexFormatUChar2Normalized;
        case PIPE_FORMAT_R8G8_SNORM:
            return MTLVertexFormatChar2Normalized;
        case PIPE_FORMAT_R8G8B8_UINT:
            return MTLVertexFormatUChar3;
        case PIPE_FORMAT_R8G8B8_SINT:
            return MTLVertexFormatChar3;
        case PIPE_FORMAT_R8G8B8_UNORM:
            return MTLVertexFormatUChar3Normalized;
        case PIPE_FORMAT_R8G8B8_SNORM:
            return MTLVertexFormatChar3Normalized;
        case PIPE_FORMAT_R16G16B16A16_UNORM:
            return MTLVertexFormatUShort4Normalized;
        default:
            return MTLVertexFormatInvalid;
    }
}

/* Mesa's u_vbuf translates these virtual formats to native float4 inputs. */
static bool
ao46_metal_vertex_format_uses_vbuf(enum pipe_format format)
{
    switch (format) {
        case PIPE_FORMAT_R10G10B10A2_UNORM:
        case PIPE_FORMAT_B10G10R10A2_UNORM:
        case PIPE_FORMAT_R10G10B10A2_SNORM:
        case PIPE_FORMAT_B10G10R10A2_SNORM:
        case PIPE_FORMAT_R10G10B10A2_USCALED:
        case PIPE_FORMAT_B10G10R10A2_USCALED:
        case PIPE_FORMAT_R10G10B10A2_SSCALED:
        case PIPE_FORMAT_B10G10R10A2_SSCALED:
            return true;
        default:
            return false;
    }
}

static MTLCompareFunction
ao46_metal_compare_function(unsigned compare_func)
{
    switch (compare_func) {
        case PIPE_FUNC_NEVER:
            return MTLCompareFunctionNever;
        case PIPE_FUNC_LESS:
            return MTLCompareFunctionLess;
        case PIPE_FUNC_EQUAL:
            return MTLCompareFunctionEqual;
        case PIPE_FUNC_LEQUAL:
            return MTLCompareFunctionLessEqual;
        case PIPE_FUNC_GREATER:
            return MTLCompareFunctionGreater;
        case PIPE_FUNC_NOTEQUAL:
            return MTLCompareFunctionNotEqual;
        case PIPE_FUNC_GEQUAL:
            return MTLCompareFunctionGreaterEqual;
        case PIPE_FUNC_ALWAYS:
        default:
            return MTLCompareFunctionAlways;
    }
}

static MTLBlendOperation
ao46_metal_blend_operation(enum pipe_blend_func func)
{
    switch (func) {
        case PIPE_BLEND_SUBTRACT:
            return MTLBlendOperationSubtract;
        case PIPE_BLEND_REVERSE_SUBTRACT:
            return MTLBlendOperationReverseSubtract;
        case PIPE_BLEND_MIN:
            return MTLBlendOperationMin;
        case PIPE_BLEND_MAX:
            return MTLBlendOperationMax;
        case PIPE_BLEND_ADD:
        default:
            return MTLBlendOperationAdd;
    }
}

static MTLBlendFactor
ao46_metal_blend_factor(enum pipe_blendfactor factor, bool alpha)
{
    enum pipe_blendfactor canonical =
        alpha ? util_blendfactor_to_alpha(factor) : factor;

    switch (canonical) {
        case PIPE_BLENDFACTOR_ZERO:
            return MTLBlendFactorZero;
        case PIPE_BLENDFACTOR_ONE:
            return MTLBlendFactorOne;
        case PIPE_BLENDFACTOR_SRC_COLOR:
            return MTLBlendFactorSourceColor;
        case PIPE_BLENDFACTOR_INV_SRC_COLOR:
            return MTLBlendFactorOneMinusSourceColor;
        case PIPE_BLENDFACTOR_SRC_ALPHA:
            return MTLBlendFactorSourceAlpha;
        case PIPE_BLENDFACTOR_INV_SRC_ALPHA:
            return MTLBlendFactorOneMinusSourceAlpha;
        case PIPE_BLENDFACTOR_DST_COLOR:
            return MTLBlendFactorDestinationColor;
        case PIPE_BLENDFACTOR_INV_DST_COLOR:
            return MTLBlendFactorOneMinusDestinationColor;
        case PIPE_BLENDFACTOR_DST_ALPHA:
            return MTLBlendFactorDestinationAlpha;
        case PIPE_BLENDFACTOR_INV_DST_ALPHA:
            return MTLBlendFactorOneMinusDestinationAlpha;
        case PIPE_BLENDFACTOR_SRC_ALPHA_SATURATE:
            return MTLBlendFactorSourceAlphaSaturated;
        case PIPE_BLENDFACTOR_CONST_COLOR:
            return MTLBlendFactorBlendColor;
        case PIPE_BLENDFACTOR_INV_CONST_COLOR:
            return MTLBlendFactorOneMinusBlendColor;
        case PIPE_BLENDFACTOR_CONST_ALPHA:
            return MTLBlendFactorBlendAlpha;
        case PIPE_BLENDFACTOR_INV_CONST_ALPHA:
            return MTLBlendFactorOneMinusBlendAlpha;
        case PIPE_BLENDFACTOR_SRC1_COLOR:
            return MTLBlendFactorSource1Color;
        case PIPE_BLENDFACTOR_INV_SRC1_COLOR:
            return MTLBlendFactorOneMinusSource1Color;
        case PIPE_BLENDFACTOR_SRC1_ALPHA:
            return MTLBlendFactorSource1Alpha;
        case PIPE_BLENDFACTOR_INV_SRC1_ALPHA:
            return MTLBlendFactorOneMinusSource1Alpha;
        default:
            return MTLBlendFactorOne;
    }
}

static MTLStencilOperation
ao46_metal_stencil_operation(unsigned op)
{
    switch (op) {
        case PIPE_STENCIL_OP_ZERO:
            return MTLStencilOperationZero;
        case PIPE_STENCIL_OP_REPLACE:
            return MTLStencilOperationReplace;
        case PIPE_STENCIL_OP_INCR:
            return MTLStencilOperationIncrementClamp;
        case PIPE_STENCIL_OP_DECR:
            return MTLStencilOperationDecrementClamp;
        case PIPE_STENCIL_OP_INCR_WRAP:
            return MTLStencilOperationIncrementWrap;
        case PIPE_STENCIL_OP_DECR_WRAP:
            return MTLStencilOperationDecrementWrap;
        case PIPE_STENCIL_OP_INVERT:
            return MTLStencilOperationInvert;
        case PIPE_STENCIL_OP_KEEP:
        default:
            return MTLStencilOperationKeep;
    }
}

static MTLCullMode
ao46_metal_cull_mode(unsigned cull_face)
{
    switch (cull_face) {
        case PIPE_FACE_FRONT:
            return MTLCullModeFront;
        case PIPE_FACE_BACK:
            return MTLCullModeBack;
        case PIPE_FACE_FRONT_AND_BACK:
        case PIPE_FACE_NONE:
        default:
            return MTLCullModeNone;
    }
}

static MTLWinding
ao46_metal_winding(const struct pipe_rasterizer_state *raster)
{
    return (raster && raster->front_ccw) ?
        MTLWindingCounterClockwise :
        MTLWindingClockwise;
}

static MTLTriangleFillMode
ao46_metal_triangle_fill_mode(const struct pipe_rasterizer_state *raster)
{
    if (!raster) {
        return MTLTriangleFillModeFill;
    }

    return (raster->fill_front != PIPE_POLYGON_MODE_FILL ||
            raster->fill_back != PIPE_POLYGON_MODE_FILL) ?
        MTLTriangleFillModeLines :
        MTLTriangleFillModeFill;
}

static MTLPrimitiveTopologyClass
ao46_metal_primitive_topology_class(enum mesa_prim mode)
{
    switch (mode) {
        case MESA_PRIM_POINTS:
            return MTLPrimitiveTopologyClassPoint;
        case MESA_PRIM_LINES:
        case MESA_PRIM_LINE_LOOP:
        case MESA_PRIM_LINE_STRIP:
        case MESA_PRIM_LINES_ADJACENCY:
        case MESA_PRIM_LINE_STRIP_ADJACENCY:
            return MTLPrimitiveTopologyClassLine;
        case MESA_PRIM_TRIANGLES:
        case MESA_PRIM_TRIANGLE_STRIP:
        case MESA_PRIM_TRIANGLE_FAN:
        case MESA_PRIM_QUADS:
        case MESA_PRIM_QUAD_STRIP:
        case MESA_PRIM_POLYGON:
        case MESA_PRIM_TRIANGLES_ADJACENCY:
        case MESA_PRIM_TRIANGLE_STRIP_ADJACENCY:
        case MESA_PRIM_PATCHES:
        default:
            return MTLPrimitiveTopologyClassTriangle;
    }
}

static MTLColorWriteMask
ao46_metal_color_write_mask(unsigned colormask)
{
    MTLColorWriteMask mask = MTLColorWriteMaskNone;

    if (colormask & PIPE_MASK_R) mask |= MTLColorWriteMaskRed;
    if (colormask & PIPE_MASK_G) mask |= MTLColorWriteMaskGreen;
    if (colormask & PIPE_MASK_B) mask |= MTLColorWriteMaskBlue;
    if (colormask & PIPE_MASK_A) mask |= MTLColorWriteMaskAlpha;

    return mask;
}

static bool
ao46_metal_surface_has_stencil(const struct pipe_surface *surf)
{
    if (!surf) {
        return false;
    }

    switch (surf->format) {
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
            return true;
        default:
            return false;
    }
}

static MTLPixelFormat
ao46_metal_attachment_pixel_format(const struct pipe_surface *surf)
{
    if (!surf) {
        return MTLPixelFormatInvalid;
    }

    return ao46_metal_pixel_format(surf->format);
}

static unsigned
ao46_metal_framebuffer_sample_count(const struct pipe_framebuffer_state *fb)
{
    if (!fb) {
        return 1;
    }

    if (fb->samples > 0) {
        return fb->samples;
    }

    for (unsigned i = 0; i < fb->nr_cbufs; i++) {
        const struct pipe_surface *surf = &fb->cbufs[i];
        if (surf->nr_samples > 0) {
            return surf->nr_samples;
        }
        if (surf->texture && surf->texture->nr_samples > 0) {
            return surf->texture->nr_samples;
        }
    }

    if (fb->zsbuf.nr_samples > 0) {
        return fb->zsbuf.nr_samples;
    }
    if (fb->zsbuf.texture && fb->zsbuf.texture->nr_samples > 0) {
        return fb->zsbuf.texture->nr_samples;
    }

    return 1;
}

static uint64_t
ao46_metal_hash_u64(uint64_t hash, uint64_t value)
{
    return hash ^ (value + 0x9e3779b97f4a7c15ULL + (hash << 6) + (hash >> 2));
}

static void
ao46_metal_fill_stencil_descriptor(MTLStencilDescriptor *desc,
                                   const struct pipe_stencil_state *stencil)
{
    if (!desc || !stencil) {
        return;
    }

    desc.stencilCompareFunction = ao46_metal_compare_function(stencil->func);
    desc.stencilFailureOperation =
        ao46_metal_stencil_operation(stencil->fail_op);
    desc.depthFailureOperation =
        ao46_metal_stencil_operation(stencil->zfail_op);
    desc.depthStencilPassOperation =
        ao46_metal_stencil_operation(stencil->zpass_op);
    desc.readMask = stencil->valuemask;
    desc.writeMask = stencil->writemask;
}

static bool
ao46_metal_surface_equal(const struct pipe_surface *a,
                         const struct pipe_surface *b)
{
    return a->texture == b->texture &&
           a->format == b->format &&
           a->nr_samples == b->nr_samples &&
           a->first_layer == b->first_layer &&
           a->last_layer == b->last_layer &&
           a->level == b->level;
}

static bool
ao46_metal_framebuffer_equal(const struct pipe_framebuffer_state *a,
                             const struct pipe_framebuffer_state *b)
{
    if (a->width != b->width ||
        a->height != b->height ||
        a->layers != b->layers ||
        a->samples != b->samples ||
        a->nr_cbufs != b->nr_cbufs ||
        a->pls_enabled != b->pls_enabled ||
        a->viewmask != b->viewmask ||
        a->resolve != b->resolve) {
        return false;
    }

    for (unsigned i = 0; i < a->nr_cbufs; i++) {
        if (!ao46_metal_surface_equal(&a->cbufs[i], &b->cbufs[i])) {
            return false;
        }
    }

    return ao46_metal_surface_equal(&a->zsbuf, &b->zsbuf);
}

static unsigned
ao46_metal_bytes_per_pixel(enum pipe_format format)
{
    if (format == PIPE_FORMAT_NONE || util_format_is_compressed(format)) {
        return 0;
    }

    return util_format_get_blocksize(format);
}

static bool
ao46_metal_texture_uses_slices(const struct pipe_resource *res)
{
    if (!res) {
        return false;
    }

    switch (res->target) {
        case PIPE_TEXTURE_2D_ARRAY:
        case PIPE_TEXTURE_CUBE:
        case PIPE_TEXTURE_CUBE_ARRAY:
            return true;
        default:
            return false;
    }
}

static bool
ao46_metal_texture_is_3d(const struct pipe_resource *res)
{
    return res && res->target == PIPE_TEXTURE_3D;
}

static bool
ao46_metal_texture_is_multisampled(const struct pipe_resource *res)
{
    return res && res->nr_samples > 1;
}

static bool
ao46_metal_multisample_target_supported(const struct pipe_resource *res)
{
    if (!ao46_metal_texture_is_multisampled(res)) {
        return true;
    }

    switch (res->target) {
        case PIPE_TEXTURE_2D:
        case PIPE_TEXTURE_RECT:
            return true;
        default:
            return false;
    }
}

static bool
ao46_metal_texture_type_uses_slices(MTLTextureType type)
{
    switch (type) {
        case MTLTextureType2DArray:
        case MTLTextureTypeCube:
        case MTLTextureTypeCubeArray:
            return true;
        default:
            return false;
    }
}

static bool
ao46_metal_texture_type_is_3d(MTLTextureType type)
{
    return type == MTLTextureType3D;
}

static NSUInteger
ao46_metal_texture_slice_count(const struct pipe_resource *res, unsigned level)
{
    if (!res) {
        return 1;
    }

    switch (res->target) {
        case PIPE_TEXTURE_2D_ARRAY:
        case PIPE_TEXTURE_CUBE_ARRAY:
            return MAX2((NSUInteger)res->array_size, 1u);
        case PIPE_TEXTURE_CUBE:
            return 6;
        case PIPE_TEXTURE_3D:
            return MAX2((NSUInteger)u_minify(res->depth0, level), 1u);
        default:
            return 1;
    }
}

static MTLTextureType
ao46_metal_texture_type_for_resource(const struct pipe_resource *res)
{
    if (!res) {
        return MTLTextureType2D;
    }

    if (ao46_metal_texture_is_multisampled(res)) {
        return MTLTextureType2DMultisample;
    }

    switch (res->target) {
        case PIPE_TEXTURE_2D:
        case PIPE_TEXTURE_RECT:
            return MTLTextureType2D;
        case PIPE_TEXTURE_2D_ARRAY:
            return MTLTextureType2DArray;
        case PIPE_TEXTURE_CUBE:
            return MTLTextureTypeCube;
        case PIPE_TEXTURE_CUBE_ARRAY:
            return MTLTextureTypeCubeArray;
        case PIPE_TEXTURE_3D:
            return MTLTextureType3D;
        default:
            return MTLTextureType2D;
    }
}

static MTLTextureType
ao46_metal_texture_type_for_sampler_view(const struct pipe_resource *texture,
                                         enum pipe_texture_target target,
                                         NSUInteger slice_count)
{
    if (ao46_metal_texture_is_multisampled(texture)) {
        return MTLTextureType2DMultisample;
    }

    switch (target) {
        case PIPE_TEXTURE_2D:
        case PIPE_TEXTURE_RECT:
            return MTLTextureType2D;
        case PIPE_TEXTURE_2D_ARRAY:
            return slice_count > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        case PIPE_TEXTURE_CUBE:
            if (slice_count == 6) {
                return MTLTextureTypeCube;
            }
            return slice_count > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        case PIPE_TEXTURE_CUBE_ARRAY:
            if (slice_count >= 6 && (slice_count % 6) == 0) {
                return slice_count == 6 ? MTLTextureTypeCube : MTLTextureTypeCubeArray;
            }
            return slice_count > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        case PIPE_TEXTURE_3D:
            return MTLTextureType3D;
        default:
            return MTLTextureType2D;
    }
}

static NSUInteger
ao46_metal_texture_array_length(const struct pipe_resource *res)
{
    if (!res) {
        return 1;
    }

    switch (res->target) {
        case PIPE_TEXTURE_2D_ARRAY:
            return MAX2((NSUInteger)res->array_size, 1u);
        case PIPE_TEXTURE_CUBE:
            return 1;
        case PIPE_TEXTURE_CUBE_ARRAY:
            return MAX2((NSUInteger)(MAX2(res->array_size, 6u) / 6u), 1u);
        default:
            return 1;
    }
}

static MTLTextureType
ao46_metal_texture_type_for_surface_view(const struct pipe_surface *surf)
{
    NSUInteger layer_count;

    if (!surf || !surf->texture) {
        return MTLTextureType2D;
    }

    if (ao46_metal_texture_is_multisampled(surf->texture)) {
        return MTLTextureType2DMultisample;
    }

    layer_count = surf->last_layer >= surf->first_layer ?
        (NSUInteger)(surf->last_layer - surf->first_layer + 1) : 1u;
    return layer_count > 1 ? MTLTextureType2DArray : MTLTextureType2D;
}

static void
ao46_metal_default_box_for_resource(const struct pipe_resource *res,
                                    unsigned level,
                                    struct pipe_box *box)
{
    if (!res || !box) {
        return;
    }

    box->x = 0;
    box->y = 0;
    box->z = 0;
    box->width = (int32_t)MAX2(u_minify(res->width0, level), 1u);
    box->height = res->target == PIPE_BUFFER ? 1 :
        (int32_t)MAX2(u_minify(res->height0, level), 1u);
    box->depth = res->target == PIPE_BUFFER ? 1 :
        (int32_t)ao46_metal_texture_slice_count(res, level);
}

static id<MTLTexture>
ao46_metal_create_texture_view(id<MTLTexture> texture,
                               MTLPixelFormat pixel_format,
                               MTLTextureType texture_type,
                               unsigned first_level,
                               unsigned level_count,
                               unsigned first_slice,
                               unsigned slice_count)
{
    if (!texture || !level_count || !slice_count) {
        return nil;
    }

    return [texture newTextureViewWithPixelFormat:pixel_format
                                      textureType:texture_type
                                           levels:NSMakeRange(first_level, level_count)
                                           slices:NSMakeRange(first_slice, slice_count)];
}

static bool
ao46_metal_texture_region_read(id<MTLTexture> texture,
                               const struct pipe_resource *res,
                               unsigned level,
                               const struct pipe_box *box,
                               void *dst,
                               unsigned stride,
                               uintptr_t layer_stride)
{
    if (!texture || !res || !box || !dst || box->depth <= 0) {
        return false;
    }

    if (texture.sampleCount > 1) {
        return ao46_metal_texture_region_read_multisample(texture,
                                                          res,
                                                          level,
                                                          box,
                                                          dst,
                                                          stride);
    }

    if (!ao46_metal_prepare_texture_for_cpu_read(texture)) {
        return false;
    }

    if (ao46_metal_texture_uses_slices(res)) {
        MTLRegion region = MTLRegionMake2D(box->x, box->y, box->width, box->height);
        uintptr_t effective_layer_stride =
            layer_stride ? layer_stride : (uintptr_t)stride * (uintptr_t)box->height;
        for (int slice = 0; slice < box->depth; slice++) {
            [texture getBytes:(uint8_t *)dst + ((uintptr_t)slice * effective_layer_stride)
                  bytesPerRow:stride
                bytesPerImage:effective_layer_stride
                   fromRegion:region
                  mipmapLevel:level
                        slice:(NSUInteger)(box->z + slice)];
        }
        return true;
    }

    if (ao46_metal_texture_is_3d(res)) {
        uintptr_t effective_layer_stride =
            layer_stride ? layer_stride : (uintptr_t)stride * (uintptr_t)box->height;
        [texture getBytes:dst
              bytesPerRow:stride
            bytesPerImage:effective_layer_stride
               fromRegion:MTLRegionMake3D(box->x, box->y, box->z,
                                          box->width, box->height, box->depth)
              mipmapLevel:level
                    slice:0];
        return true;
    }

    if (box->depth != 1) {
        return false;
    }

    [texture getBytes:dst
          bytesPerRow:stride
           fromRegion:MTLRegionMake2D(box->x, box->y, box->width, box->height)
          mipmapLevel:level];
    return true;
}

static bool
ao46_metal_texture_region_write(id<MTLTexture> texture,
                                const struct pipe_resource *res,
                                unsigned level,
                                const struct pipe_box *box,
                                const void *src,
                                unsigned stride,
                                uintptr_t layer_stride)
{
    if (!texture || !res || !box || !src || box->depth <= 0) {
        return false;
    }

    if (texture.sampleCount > 1) {
        return false;
    }

    if (ao46_metal_texture_uses_slices(res)) {
        MTLRegion region = MTLRegionMake2D(box->x, box->y, box->width, box->height);
        uintptr_t effective_layer_stride =
            layer_stride ? layer_stride : (uintptr_t)stride * (uintptr_t)box->height;
        for (int slice = 0; slice < box->depth; slice++) {
            [texture replaceRegion:region
                       mipmapLevel:level
                             slice:(NSUInteger)(box->z + slice)
                         withBytes:(const uint8_t *)src + ((uintptr_t)slice * effective_layer_stride)
                       bytesPerRow:stride
                     bytesPerImage:effective_layer_stride];
        }
        return true;
    }

    if (ao46_metal_texture_is_3d(res)) {
        uintptr_t effective_layer_stride =
            layer_stride ? layer_stride : (uintptr_t)stride * (uintptr_t)box->height;
        [texture replaceRegion:MTLRegionMake3D(box->x, box->y, box->z,
                                               box->width, box->height, box->depth)
                   mipmapLevel:level
                         slice:0
                     withBytes:src
                   bytesPerRow:stride
                 bytesPerImage:effective_layer_stride];
        return true;
    }

    if (box->depth != 1) {
        return false;
    }

    [texture replaceRegion:MTLRegionMake2D(box->x, box->y, box->width, box->height)
               mipmapLevel:level
                 withBytes:src
               bytesPerRow:stride];
    return true;
}

static void
ao46_metal_pack_color_texel(enum pipe_format format,
                            const union pipe_color_union *color,
                            uint8_t *out_texel)
{
    uint8_t rgba[4] = {
        (uint8_t)CLAMP(color->f[0] * 255.0f, 0.0f, 255.0f),
        (uint8_t)CLAMP(color->f[1] * 255.0f, 0.0f, 255.0f),
        (uint8_t)CLAMP(color->f[2] * 255.0f, 0.0f, 255.0f),
        (uint8_t)CLAMP(color->f[3] * 255.0f, 0.0f, 255.0f),
    };

    switch (format) {
        case PIPE_FORMAT_B8G8R8A8_UNORM:
        case PIPE_FORMAT_B8G8R8A8_SRGB:
            out_texel[0] = rgba[2];
            out_texel[1] = rgba[1];
            out_texel[2] = rgba[0];
            out_texel[3] = rgba[3];
            break;
        case PIPE_FORMAT_R8G8B8A8_UNORM:
        case PIPE_FORMAT_R8G8B8A8_SRGB:
        default:
            memcpy(out_texel, rgba, sizeof(rgba));
            break;
    }
}

static bool
ao46_metal_box_covers_surface(const struct pipe_surface *surf,
                              unsigned x,
                              unsigned y,
                              unsigned width,
                              unsigned height)
{
    if (!surf || !surf->texture) {
        return false;
    }

    return x == 0 &&
           y == 0 &&
           width == MAX2(u_minify(surf->texture->width0, surf->level), 1u) &&
           height == MAX2(u_minify(surf->texture->height0, surf->level), 1u);
}

static bool
ao46_metal_scissor_is_full(unsigned width,
                           unsigned height,
                           const struct pipe_scissor_state *scissor)
{
    return !scissor ||
           (scissor->minx == 0 &&
            scissor->miny == 0 &&
            scissor->maxx >= width &&
            scissor->maxy >= height);
}

/* ======================================================================
 * Shader compilation wrapper (declared in mtl_shader_compiler.m)
 * ====================================================================== */
id<MTLFunction> ao46_metal_compile_nir_to_msl(struct nir_shader *nir,
                                              const char *entry_name,
                                              MTLFunctionConstantValues *constants,
                                              NSError **error);
id<MTLFunction> ao46_metal_compile_nir_to_msl_with_static_sample_mask(
    struct nir_shader *nir,
    const char *entry_name,
    MTLFunctionConstantValues *constants,
    uint32_t sample_mask,
    NSError **error);

/* ======================================================================
 * Pipe resource (buffer / texture)
 * ====================================================================== */
struct ao46_metal_resource {
    struct pipe_resource base;
    id<MTLBuffer> mtl_buffer;
    id<MTLTexture> mtl_texture;
    CAMetalLayer *metal_layer;  // for window textures
    void *user_data;            // for mapping
    int map_count;
};

struct ao46_metal_transfer {
    struct pipe_transfer base;
    void *map_data;
};

struct ao46_metal_sampler_state {
    struct pipe_sampler_state base;
    id<MTLSamplerState> mtl_sampler;
};

struct ao46_metal_sampler_view {
    struct pipe_sampler_view base;
    id<MTLTexture> mtl_texture;
};

struct ao46_metal_vertex_elements_state {
    unsigned num_elements;
    struct pipe_vertex_element elements[PIPE_MAX_ATTRIBS];
};

struct ao46_metal_blend_state {
    struct pipe_blend_state base;
};

struct ao46_metal_rasterizer_state {
    struct pipe_rasterizer_state base;
};

struct ao46_metal_depth_stencil_alpha_state {
    struct pipe_depth_stencil_alpha_state base;
    id<MTLDepthStencilState> mtl_state;
};

static inline struct ao46_metal_resource *
ao46_metal_resource(struct pipe_resource *res)
{
    return (struct ao46_metal_resource *)res;
}

static inline struct ao46_metal_transfer *
ao46_metal_transfer(struct pipe_transfer *transfer)
{
    return (struct ao46_metal_transfer *)transfer;
}

static inline struct ao46_metal_sampler_view *
ao46_metal_sampler_view(struct pipe_sampler_view *view)
{
    return (struct ao46_metal_sampler_view *)view;
}

static id<MTLTexture>
ao46_metal_get_surface_texture(const struct pipe_surface *surf)
{
    struct ao46_metal_resource *mr;
    MTLPixelFormat pixel_format;
    NSUInteger slice_count;
    bool full_levels;
    bool full_slices;
    bool full_view;

    if (!surf || !surf->texture) {
        return nil;
    }

    mr = ao46_metal_resource(surf->texture);
    if (!mr->mtl_texture) {
        return nil;
    }

    pixel_format = ao46_metal_attachment_pixel_format(surf);
    slice_count = surf->last_layer >= surf->first_layer ?
        (NSUInteger)(surf->last_layer - surf->first_layer + 1) : 1u;
    full_levels = surf->level == 0 && surf->texture->last_level == 0;
    full_slices = surf->first_layer == 0 &&
        slice_count == ao46_metal_texture_slice_count(surf->texture, surf->level);
    full_view = pixel_format == mr->mtl_texture.pixelFormat &&
        ao46_metal_texture_type_for_surface_view(surf) == mr->mtl_texture.textureType &&
        full_levels && full_slices;

    if (full_view) {
        return [mr->mtl_texture retain];
    }

    if (mr->mtl_texture.sampleCount > 1) {
        return nil;
    }

    return ao46_metal_create_texture_view(mr->mtl_texture,
                                          pixel_format,
                                          ao46_metal_texture_type_for_surface_view(surf),
                                          surf->level,
                                          1,
                                          surf->first_layer,
                                          MAX2(slice_count, 1u));
}

static struct pipe_resource *
ao46_metal_resource_create(struct pipe_screen *screen,
                           const struct pipe_resource *templ)
{
    struct ao46_metal_resource *res = CALLOC_STRUCT(ao46_metal_resource);
    MTLPixelFormat mtl_format;

    if (!res) return NULL;

    res->base = *templ;
    res->base.screen = screen;
    pipe_reference_init(&res->base.reference, 1);
    mtl_format = ao46_metal_pixel_format(templ->format);
    if (mtl_format == MTLPixelFormatInvalid) {
        FREE(res);
        return NULL;
    }

    if (!ao46_metal_multisample_target_supported(&res->base)) {
        FREE(res);
        return NULL;
    }

    switch (templ->target) {
        case PIPE_BUFFER: {
            size_t size = templ->width0;
            res->mtl_buffer = [g_mtl_device newBufferWithLength:size
                                                        options:MTLResourceStorageModeShared];
            if (!res->mtl_buffer) {
                FREE(res);
                return NULL;
            }
            if (AO46MetalAdapterIsCurrent(&g_mtl_adapter) &&
                !AO46MetalAdapterTrackExternalAllocation(
                    &g_mtl_adapter, (__bridge void *)res->mtl_buffer)) {
                [res->mtl_buffer release];
                FREE(res);
                return NULL;
            }
            break;
        }
        case PIPE_TEXTURE_2D:
        case PIPE_TEXTURE_RECT:
        case PIPE_TEXTURE_2D_ARRAY:
        case PIPE_TEXTURE_CUBE:
        case PIPE_TEXTURE_CUBE_ARRAY:
        case PIPE_TEXTURE_3D: {
            MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
            desc.textureType = ao46_metal_texture_type_for_resource(&res->base);
            desc.pixelFormat = mtl_format;
            desc.width = templ->width0;
            desc.height = templ->height0;
            desc.depth = templ->target == PIPE_TEXTURE_3D ?
                MAX2((NSUInteger)templ->depth0, 1u) : 1;
            desc.mipmapLevelCount = res->base.nr_samples > 1 ? 1u : templ->last_level + 1;
            desc.arrayLength = res->base.nr_samples > 1 ? 1u : ao46_metal_texture_array_length(templ);
            desc.sampleCount = MAX2(res->base.nr_samples, 1u);
            desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            if (res->base.nr_samples == 1) {
                desc.usage |= MTLTextureUsagePixelFormatView;
            }
            if ((templ->bind & PIPE_BIND_SHADER_IMAGE) && res->base.nr_samples == 1) {
                desc.usage |= MTLTextureUsageShaderWrite;
            }
            if (templ->bind & PIPE_BIND_DEPTH_STENCIL) {
                desc.pixelFormat = mtl_format;
                desc.usage |= MTLTextureUsageRenderTarget;
            }
            res->mtl_texture = [g_mtl_device newTextureWithDescriptor:desc];
            [desc release];
            if (!res->mtl_texture) {
                FREE(res);
                return NULL;
            }
            if (AO46MetalAdapterIsCurrent(&g_mtl_adapter) &&
                !AO46MetalAdapterTrackExternalAllocation(
                    &g_mtl_adapter, (__bridge void *)res->mtl_texture)) {
                [res->mtl_texture release];
                FREE(res);
                return NULL;
            }
            break;
        }
        default:
            FREE(res);
            return NULL;
    }

    return &res->base;
}

static void
ao46_metal_resource_destroy(struct pipe_screen *screen,
                            struct pipe_resource *res)
{
    struct ao46_metal_resource *mr = ao46_metal_resource(res);
    if (AO46MetalAdapterIsCurrent(&g_mtl_adapter)) {
        if (mr->mtl_buffer) {
            AO46MetalAdapterUntrackExternalAllocation(
                &g_mtl_adapter, (__bridge void *)mr->mtl_buffer);
        }
        if (mr->mtl_texture) {
            AO46MetalAdapterUntrackExternalAllocation(
                &g_mtl_adapter, (__bridge void *)mr->mtl_texture);
        }
    }
    [mr->mtl_buffer release];
    [mr->mtl_texture release];
    mr->mtl_buffer = nil;
    mr->mtl_texture = nil;
    if (mr->metal_layer) {
        [mr->metal_layer release];
        mr->metal_layer = nil;
    }
    FREE(mr);
}

static void *
ao46_metal_resource_map(struct pipe_screen *screen,
                        struct pipe_resource *res,
                        unsigned level,
                        unsigned usage,
                        const struct pipe_box *box,
                        struct pipe_transfer **transfer)
{
    struct ao46_metal_resource *mr = ao46_metal_resource(res);
    struct pipe_box map_box;
    unsigned bpp = 0;
    if (!mr->mtl_buffer && !mr->mtl_texture) return NULL;

    struct ao46_metal_transfer *t = CALLOC_STRUCT(ao46_metal_transfer);
    if (!t) return NULL;

    if (box) {
        map_box = *box;
    } else {
        ao46_metal_default_box_for_resource(res, level, &map_box);
    }

    t->base.resource = res;
    t->base.level = level;
    t->base.usage = usage;
    t->base.box = map_box;
    t->base.stride = 0;
    t->base.layer_stride = 0;

    void *data = NULL;
    if (mr->mtl_buffer) {
        t->base.stride = map_box.width;
        data = (uint8_t *)[mr->mtl_buffer contents] + map_box.x;
        if (!data) {
            FREE(t);
            return NULL;
        }
    } else if (mr->mtl_texture) {
        bpp = ao46_metal_bytes_per_pixel(res->format);
        if (!bpp || map_box.width <= 0 || map_box.height <= 0 || map_box.depth <= 0) {
            FREE(t);
            return NULL;
        }

        t->base.stride = (unsigned)((uintptr_t)map_box.width * bpp);
        t->base.layer_stride = (uintptr_t)t->base.stride * (uintptr_t)map_box.height;
        size_t size = (size_t)t->base.layer_stride * (size_t)map_box.depth;
        data = malloc(size);
        if (!data) {
            FREE(t);
            return NULL;
        }
        if (usage & PIPE_MAP_READ) {
            if (!ao46_metal_texture_region_read(mr->mtl_texture,
                                                res,
                                                level,
                                                &map_box,
                                                data,
                                                t->base.stride,
                                                t->base.layer_stride)) {
                free(data);
                FREE(t);
                return NULL;
            }
        }
        t->map_data = data;
    }
    *transfer = &t->base;
    return data;
}

static void
ao46_metal_resource_unmap(struct pipe_screen *screen,
                          struct pipe_transfer *transfer)
{
    struct ao46_metal_transfer *mt = ao46_metal_transfer(transfer);
    struct pipe_resource *res = transfer->resource;
    struct ao46_metal_resource *mr = ao46_metal_resource(res);
    if (mt->map_data && mr->mtl_texture) {
        if ((transfer->usage & PIPE_MAP_WRITE) &&
            !(transfer->usage & PIPE_MAP_FLUSH_EXPLICIT)) {
            (void)ao46_metal_texture_region_write(mr->mtl_texture,
                                                  res,
                                                  transfer->level,
                                                  &transfer->box,
                                                  mt->map_data,
                                                  transfer->stride,
                                                  transfer->layer_stride);
        }
        free(mt->map_data);
    }
    FREE(mt);
}

static struct pipe_surface *
ao46_metal_create_surface(struct pipe_screen *screen,
                          struct pipe_resource *res,
                          const struct pipe_surface *templ)
{
    struct pipe_surface *surf = CALLOC_STRUCT(pipe_surface);
    if (!surf) return NULL;
    pipe_reference_init(&surf->reference, 1);
    pipe_resource_reference(&surf->texture, res);
    surf->format = templ ? templ->format : res->format;
    surf->nr_samples = res->nr_samples;
    surf->first_layer = templ ? templ->first_layer : 0;
    surf->last_layer = templ ? templ->last_layer : 0;
    surf->level = templ ? templ->level : 0;
    return surf;
}

static void
ao46_metal_destroy_surface(struct pipe_screen *screen,
                           struct pipe_surface *surf)
{
    if (surf) {
        pipe_resource_reference(&surf->texture, NULL);
    }
    FREE(surf);
}

/* ======================================================================
 * Pipe context
 * ====================================================================== */

struct ao46_metal_shader {
    id<MTLFunction> function;
    id<MTLFunction> static_sample_mask_function;
    id<MTLComputePipelineState> compute_pipeline;
    struct nir_shader *nir;
    uint32_t static_sample_mask;
    uint32_t workgroup_size[3];
    struct pipe_stream_output_info stream_output;
    bool uses_draw_id;
    bool uses_draw_parameters;
    uint16_t image_mask;
};

struct ao46_metal_shader_buffer_binding {
    struct pipe_resource *buffer;
    unsigned buffer_offset;
    unsigned buffer_size;
    bool writable;
};

/* Mesa owns the transform-feedback object; AO46 owns its retained buffer view. */
struct ao46_metal_stream_output_target {
    struct pipe_stream_output_target base;
    unsigned write_offset;
    unsigned vertex_stride;
};

struct ao46_metal_query {
    unsigned type;
    unsigned index;
    bool active;
    bool ended;
    struct pipe_query_data_so_statistics start;
    struct pipe_query_data_so_statistics result;
};

struct ao46_metal_poly_package_layout {
    size_t root_offset;
    size_t count_root_offset;
    size_t sampler_table_offset;
    size_t vertex_parameters_offset;
    size_t vertex_input_root_offset;
    size_t vertex_input_root_size;
    size_t vertex_outputs_offset;
    size_t vertex_outputs_bytes;
    size_t parameters_offset;
    size_t heap_offset;
    size_t heap_data_offset;
    size_t heap_data_bytes;
    size_t counts_offset;
    size_t draws_offset;
    size_t factors_offset;
    size_t coord_allocs_offset;
    size_t package_bytes;
};

struct ao46_metal_poly_runtime {
    struct AO46MesaComputePipeline vs_pipeline;
    struct AO46MesaComputePipeline tcs_pipeline;
    struct AO46MesaRenderPipeline render_pipeline;
    struct AO46MesaPolyKernelExecutor kernel_executor;
    struct AO46MesaPolyTessellationPlan plan;
    struct AO46MetalGalliumPolyTessellationDraw draw;
    struct AO46MetalGalliumPolyTessellationSequence sequence;
    struct pipe_resource *package;
};

struct ao46_metal_context {
    struct pipe_context base;

    /* Texture buffers (GL_TEXTURE_BUFFER) */
    struct pipe_resource *texture_buffer;   /* currently bound buffer texture */
    id<MTLTexture> texture_buffer_mtl;      /* Metal texture wrapping the buffer */

    id<MTLCommandBuffer> cmd_buffer;
    struct AO46MetalSubmission submission;
    MTLRenderPassDescriptor *render_pass;
    id<MTLRenderCommandEncoder> render_encoder;
    id<MTLComputeCommandEncoder> compute_encoder;
    id<MTLBuffer> rgb32_address_tables[MESA_SHADER_STAGES];
    id<MTLTexture> image_binding_textures[MESA_SHADER_STAGES][AO46_MAX_IMAGE_UNITS];
    id<MTLRenderPipelineState> pipeline_state;
    uint64_t pipeline_key;
    bool render_pass_started;

    struct pipe_framebuffer_state fb_state;
    struct pipe_vertex_buffer vertex_buffers[PIPE_MAX_ATTRIBS];
    unsigned num_vertex_buffers;
    struct ao46_metal_vertex_elements_state *vertex_elements_state;
    struct pipe_viewport_state viewport;
    struct pipe_scissor_state scissor;
    struct ao46_metal_blend_state *blend;
    struct ao46_metal_rasterizer_state *raster;
    struct ao46_metal_depth_stencil_alpha_state *dsa;
    struct pipe_blend_color blend_color;
    struct pipe_stencil_ref stencil_ref;
    unsigned sample_mask;
    unsigned min_samples;
    struct ao46_metal_shader *vs_shader;
    struct ao46_metal_shader *gs_shader;
    struct ao46_metal_shader *tcs_shader;
    struct ao46_metal_shader *tes_shader;
    struct ao46_metal_shader *fs_shader;
    struct ao46_metal_shader *cs_shader;
    float tess_outer_level[4];
    float tess_inner_level[2];
    bool tess_state_set;
    uint8_t patch_vertices;
    const struct AO46MetalRenderPipeline *poly_render_pipeline;
    struct AO46MetalGalliumPolyTessellationDraw poly_tess_draw;
    struct AO46MetalGalliumPolyTessellationSequence poly_tess_sequence;
    struct pipe_constant_buffer const_buffers[MESA_SHADER_STAGES];
    id<MTLBuffer> const_buffer_mtl[MESA_SHADER_STAGES];
    bool const_buffer_dirty[MESA_SHADER_STAGES];
    struct ao46_metal_shader_buffer_binding shader_buffers[MESA_SHADER_STAGES][AO46_MAX_SHADER_BUFFERS];
    uint num_shader_buffers[MESA_SHADER_STAGES];
    struct pipe_stream_output_target *stream_output_targets[PIPE_MAX_SO_BUFFERS];
    unsigned stream_output_offsets[PIPE_MAX_SO_BUFFERS];
    unsigned num_stream_output_targets;
    enum mesa_prim stream_output_prim;
    struct pipe_query_data_so_statistics so_stats[PIPE_MAX_VERTEX_STREAMS];
    bool active_query_state;
    struct pipe_image_view image_views[MESA_SHADER_STAGES][AO46_MAX_IMAGE_UNITS];
    uint num_image_views[MESA_SHADER_STAGES];
    struct pipe_sampler_view *sampler_views[MESA_SHADER_STAGES][AO46_MAX_SAMPLERS];
    struct ao46_metal_sampler_state *samplers[MESA_SHADER_STAGES][AO46_MAX_SAMPLERS];
    uint num_sampler_views[MESA_SHADER_STAGES];
    uint num_samplers[MESA_SHADER_STAGES];
};

static bool
ao46_metal_context_begin_submission(struct ao46_metal_context *mc)
{
    if (!mc) {
        return false;
    }
    if (mc->cmd_buffer) {
        return true;
    }

    if (AO46MetalAdapterIsCurrent(&g_mtl_adapter)) {
        if (!AO46MetalSubmissionBegin(&g_mtl_adapter, &mc->submission)) {
            return false;
        }
        mc->cmd_buffer = (__bridge id<MTLCommandBuffer>)
            mc->submission.native_command_buffer;
        return mc->cmd_buffer != nil;
    }

    mc->cmd_buffer = ao46_metal_get_command_buffer();
    return mc->cmd_buffer != nil;
}

static inline struct ao46_metal_context *
ao46_metal_context(struct pipe_context *ctx)
{
    return (struct ao46_metal_context *)ctx;
}

static id<MTLTexture>
ao46_metal_get_resource_texture(struct pipe_resource *res)
{
    struct ao46_metal_resource *mr;

    if (!res) {
        return nil;
    }

    mr = ao46_metal_resource(res);
    return mr->mtl_texture ? [mr->mtl_texture retain] : nil;
}

static id<MTLTexture>
ao46_metal_get_framebuffer_resolve_texture(const struct ao46_metal_context *mc,
                                           unsigned color_index,
                                           const struct pipe_surface *surf)
{
    if (!mc || !surf || color_index != 0 || !mc->fb_state.resolve ||
        !surf->texture || !ao46_metal_texture_is_multisampled(surf->texture)) {
        return nil;
    }

    return ao46_metal_get_resource_texture(mc->fb_state.resolve);
}

static void *
ao46_metal_buffer_map(struct pipe_context *ctx,
                      struct pipe_resource *resource,
                      unsigned level,
                      unsigned usage,
                      const struct pipe_box *box,
                      struct pipe_transfer **out_transfer)
{
    if (ctx && (usage & PIPE_MAP_READ)) {
        ao46_metal_context_flush(ctx, NULL, PIPE_FLUSH_HINT_FINISH);
    }

    return ao46_metal_resource_map(resource->screen, resource, level, usage, box, out_transfer);
}

static void
ao46_metal_buffer_unmap(struct pipe_context *ctx, struct pipe_transfer *transfer)
{
    (void)ctx;
    ao46_metal_resource_unmap(transfer->resource->screen, transfer);
}

static void *
ao46_metal_texture_map(struct pipe_context *ctx,
                       struct pipe_resource *resource,
                       unsigned level,
                       unsigned usage,
                       const struct pipe_box *box,
                       struct pipe_transfer **out_transfer)
{
    if (ctx && (usage & PIPE_MAP_READ)) {
        ao46_metal_context_flush(ctx, NULL, PIPE_FLUSH_HINT_FINISH);
    }

    return ao46_metal_resource_map(resource->screen, resource, level, usage, box, out_transfer);
}

static void
ao46_metal_texture_unmap(struct pipe_context *ctx, struct pipe_transfer *transfer)
{
    (void)ctx;
    ao46_metal_resource_unmap(transfer->resource->screen, transfer);
}

static void
ao46_metal_transfer_flush_region(struct pipe_context *ctx,
                                 struct pipe_transfer *transfer,
                                 const struct pipe_box *box)
{
    struct ao46_metal_transfer *mt;
    struct ao46_metal_resource *mr;
    struct pipe_box flush_box;
    unsigned bpp;
    const uint8_t *src;

    (void)ctx;
    if (!transfer || !box) {
        return;
    }

    if (!(transfer->usage & PIPE_MAP_WRITE) ||
        !(transfer->usage & PIPE_MAP_FLUSH_EXPLICIT)) {
        return;
    }

    mt = ao46_metal_transfer(transfer);
    mr = ao46_metal_resource(transfer->resource);
    if (!mt->map_data || !mr->mtl_texture) {
        return;
    }

    bpp = ao46_metal_bytes_per_pixel(transfer->resource->format);
    if (!bpp) {
        return;
    }

    flush_box = *box;
    flush_box.x += transfer->box.x;
    flush_box.y += transfer->box.y;
    flush_box.z += transfer->box.z;

    src = (const uint8_t *)mt->map_data +
          ((uintptr_t)box->z * transfer->layer_stride) +
          ((uintptr_t)box->y * transfer->stride) +
          ((uintptr_t)box->x * bpp);

    (void)ao46_metal_texture_region_write(mr->mtl_texture,
                                          transfer->resource,
                                          transfer->level,
                                          &flush_box,
                                          src,
                                          transfer->stride,
                                          transfer->layer_stride);
}

static void
ao46_metal_buffer_subdata(struct pipe_context *ctx,
                          struct pipe_resource *resource,
                          unsigned usage,
                          unsigned offset,
                          unsigned size,
                          const void *data)
{
    struct ao46_metal_resource *mr;
    uint8_t *contents;

    (void)usage;
    if (!ctx || !resource || !data || resource->target != PIPE_BUFFER || !size) {
        return;
    }

    mr = ao46_metal_resource(resource);
    if (!mr->mtl_buffer || offset >= resource->width0) {
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
    contents = [mr->mtl_buffer contents];
    if (!contents) {
        return;
    }

    size = MIN2(size, resource->width0 - offset);
    memcpy(contents + offset, data, size);
}

static void
ao46_metal_texture_subdata(struct pipe_context *ctx,
                           struct pipe_resource *resource,
                           unsigned level,
                           unsigned usage,
                           const struct pipe_box *box,
                           const void *data,
                           unsigned stride,
                           uintptr_t layer_stride)
{
    struct ao46_metal_resource *mr;
    struct pipe_box upload_box;
    unsigned bpp;

    (void)usage;
    if (!ctx || !resource || !data) {
        return;
    }

    mr = ao46_metal_resource(resource);
    if (!mr->mtl_texture) {
        return;
    }

    if (box) {
        upload_box = *box;
    } else {
        ao46_metal_default_box_for_resource(resource, level, &upload_box);
    }

    bpp = ao46_metal_bytes_per_pixel(resource->format);
    if (!bpp || upload_box.width <= 0 || upload_box.height <= 0 || upload_box.depth <= 0) {
        return;
    }

    if (stride == 0) {
        stride = (unsigned)((uintptr_t)upload_box.width * bpp);
    }
    if (layer_stride == 0) {
        layer_stride = (uintptr_t)stride * (uintptr_t)upload_box.height;
    }

    ao46_metal_flush_for_resource_op(ctx);
    (void)ao46_metal_texture_region_write(mr->mtl_texture,
                                          resource,
                                          level,
                                          &upload_box,
                                          data,
                                          stride,
                                          layer_stride);
}

static void
ao46_metal_flush_for_resource_op(struct pipe_context *ctx)
{
    struct ao46_metal_context *mc = ctx ? ao46_metal_context(ctx) : NULL;
    if (mc && (mc->render_encoder || mc->compute_encoder)) {
        ao46_metal_context_flush(ctx, NULL, 0);
    }
}

static bool
ao46_metal_fill_texture_box(id<MTLTexture> texture,
                            enum pipe_format format,
                            unsigned level,
                            const struct pipe_box *box,
                            const void *texel)
{
    unsigned bpp = ao46_metal_bytes_per_pixel(format);
    size_t row_bytes;
    size_t image_bytes;
    size_t total_size;
    uint8_t *data;
    MTLTextureType texture_type;

    if (!texture || !box || box->width <= 0 || box->height <= 0 ||
        box->depth <= 0 || !texel || !bpp) {
        return false;
    }

    texture_type = texture.textureType;
    row_bytes = (size_t)box->width * bpp;
    image_bytes = row_bytes * (size_t)box->height;
    total_size = image_bytes * (size_t)box->depth;
    data = malloc(total_size);
    if (!data) {
        return false;
    }

    for (size_t offset = 0; offset < total_size; offset += bpp) {
        memcpy(data + offset, texel, bpp);
    }

    if (ao46_metal_texture_type_uses_slices(texture_type)) {
        MTLRegion region = MTLRegionMake2D(box->x, box->y, box->width, box->height);
        for (int slice = 0; slice < box->depth; slice++) {
            [texture replaceRegion:region
                       mipmapLevel:level
                             slice:(NSUInteger)(box->z + slice)
                         withBytes:data + ((size_t)slice * image_bytes)
                       bytesPerRow:row_bytes
                     bytesPerImage:image_bytes];
        }
    } else if (ao46_metal_texture_type_is_3d(texture_type)) {
        [texture replaceRegion:MTLRegionMake3D(box->x, box->y, box->z,
                                               box->width, box->height, box->depth)
                   mipmapLevel:level
                         slice:0
                     withBytes:data
                   bytesPerRow:row_bytes
                 bytesPerImage:image_bytes];
    } else {
        [texture replaceRegion:MTLRegionMake2D(box->x, box->y, box->width, box->height)
                   mipmapLevel:level
                     withBytes:data
                   bytesPerRow:row_bytes];
    }
    free(data);
    return true;
}

static void
ao46_metal_resource_copy_region(struct pipe_context *ctx,
                                struct pipe_resource *dst,
                                unsigned dst_level,
                                unsigned dstx, unsigned dsty, unsigned dstz,
                                struct pipe_resource *src,
                                unsigned src_level,
                                const struct pipe_box *src_box)
{
    struct ao46_metal_resource *dst_mr;
    struct ao46_metal_resource *src_mr;
    id<MTLCommandBuffer> cmd_buffer;
    id<MTLBlitCommandEncoder> blit;

    if (!ctx || !dst || !src || !src_box || src_box->width <= 0 ||
        src_box->height <= 0 || src_box->depth <= 0) {
        return;
    }

    dst_mr = ao46_metal_resource(dst);
    src_mr = ao46_metal_resource(src);
    if ((!dst_mr->mtl_buffer && !dst_mr->mtl_texture) ||
        (!src_mr->mtl_buffer && !src_mr->mtl_texture)) {
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
    cmd_buffer = ao46_metal_get_command_buffer();
    if (!cmd_buffer) {
        return;
    }

    blit = [cmd_buffer blitCommandEncoder];
    if (dst_mr->mtl_buffer && src_mr->mtl_buffer) {
        [blit copyFromBuffer:src_mr->mtl_buffer
                sourceOffset:(NSUInteger)src_box->x
                    toBuffer:dst_mr->mtl_buffer
           destinationOffset:(NSUInteger)dstx
                        size:(NSUInteger)src_box->width];
    } else if (dst_mr->mtl_texture && src_mr->mtl_texture) {
        if (ao46_metal_texture_uses_slices(src) || ao46_metal_texture_uses_slices(dst)) {
            for (int slice = 0; slice < src_box->depth; slice++) {
                NSUInteger source_slice =
                    ao46_metal_texture_uses_slices(src) ? (NSUInteger)(src_box->z + slice) : 0;
                NSUInteger destination_slice =
                    ao46_metal_texture_uses_slices(dst) ? (NSUInteger)(dstz + slice) : 0;
                [blit copyFromTexture:src_mr->mtl_texture
                          sourceSlice:source_slice
                          sourceLevel:src_level
                         sourceOrigin:MTLOriginMake(src_box->x, src_box->y, 0)
                           sourceSize:MTLSizeMake(src_box->width, src_box->height, 1)
                            toTexture:dst_mr->mtl_texture
                     destinationSlice:destination_slice
                     destinationLevel:dst_level
                    destinationOrigin:MTLOriginMake(dstx, dsty, 0)];
            }
        } else {
            [blit copyFromTexture:src_mr->mtl_texture
                      sourceSlice:0
                      sourceLevel:src_level
                     sourceOrigin:MTLOriginMake(src_box->x, src_box->y, src_box->z)
                       sourceSize:MTLSizeMake(src_box->width, src_box->height, src_box->depth)
                        toTexture:dst_mr->mtl_texture
                 destinationSlice:0
                 destinationLevel:dst_level
                destinationOrigin:MTLOriginMake(dstx, dsty, dstz)];
        }
    } else if (dst_mr->mtl_texture && src_mr->mtl_buffer) {
        unsigned bpp = ao46_metal_bytes_per_pixel(dst->format);
        if (bpp) {
            NSUInteger row_bytes = (NSUInteger)src_box->width * bpp;
            NSUInteger image_bytes = row_bytes * (NSUInteger)src_box->height;
            if (ao46_metal_texture_uses_slices(dst)) {
                for (int slice = 0; slice < src_box->depth; slice++) {
                    [blit copyFromBuffer:src_mr->mtl_buffer
                            sourceOffset:(NSUInteger)src_box->x + ((NSUInteger)slice * image_bytes)
                       sourceBytesPerRow:row_bytes
                     sourceBytesPerImage:image_bytes
                              sourceSize:MTLSizeMake(src_box->width, src_box->height, 1)
                               toTexture:dst_mr->mtl_texture
                        destinationSlice:(NSUInteger)(dstz + slice)
                        destinationLevel:dst_level
                       destinationOrigin:MTLOriginMake(dstx, dsty, 0)];
                }
            } else {
                [blit copyFromBuffer:src_mr->mtl_buffer
                        sourceOffset:(NSUInteger)src_box->x
                   sourceBytesPerRow:row_bytes
                 sourceBytesPerImage:image_bytes
                          sourceSize:MTLSizeMake(src_box->width, src_box->height, src_box->depth)
                           toTexture:dst_mr->mtl_texture
                    destinationSlice:0
                    destinationLevel:dst_level
                   destinationOrigin:MTLOriginMake(dstx, dsty, dstz)];
            }
        }
    } else if (dst_mr->mtl_buffer && src_mr->mtl_texture) {
        unsigned bpp = ao46_metal_bytes_per_pixel(src->format);
        if (bpp) {
            NSUInteger row_bytes = (NSUInteger)src_box->width * bpp;
            NSUInteger image_bytes = row_bytes * (NSUInteger)src_box->height;
            if (ao46_metal_texture_uses_slices(src)) {
                for (int slice = 0; slice < src_box->depth; slice++) {
                    [blit copyFromTexture:src_mr->mtl_texture
                              sourceSlice:(NSUInteger)(src_box->z + slice)
                              sourceLevel:src_level
                             sourceOrigin:MTLOriginMake(src_box->x, src_box->y, 0)
                               sourceSize:MTLSizeMake(src_box->width, src_box->height, 1)
                                 toBuffer:dst_mr->mtl_buffer
                        destinationOffset:(NSUInteger)dstx + ((NSUInteger)slice * image_bytes)
                   destinationBytesPerRow:row_bytes
                 destinationBytesPerImage:image_bytes];
                }
            } else {
                [blit copyFromTexture:src_mr->mtl_texture
                          sourceSlice:0
                          sourceLevel:src_level
                         sourceOrigin:MTLOriginMake(src_box->x, src_box->y, src_box->z)
                           sourceSize:MTLSizeMake(src_box->width, src_box->height, src_box->depth)
                             toBuffer:dst_mr->mtl_buffer
                    destinationOffset:(NSUInteger)dstx
               destinationBytesPerRow:row_bytes
             destinationBytesPerImage:image_bytes];
            }
        }
    }

    [blit endEncoding];
    ao46_metal_commit_command_buffer(cmd_buffer, true);
}

static void
ao46_metal_blit_cpu_color_convert(struct pipe_context *ctx,
                                  const struct pipe_blit_info *info)
{
    struct pipe_transfer *src_transfer = NULL;
    struct pipe_transfer *dst_transfer = NULL;
    uint8_t *rgba = NULL;
    void *src;
    void *dst;
    size_t width;
    size_t height;
    size_t rgba_size;

    if (!ctx || !info || !info->src.resource || !info->dst.resource ||
        info->src.resource->target == PIPE_BUFFER ||
        info->dst.resource->target == PIPE_BUFFER ||
        info->src.resource->nr_samples > 1 || info->dst.resource->nr_samples > 1 ||
        info->src.resource->format != info->src.format ||
        info->dst.resource->format != info->dst.format ||
        info->src.box.x < 0 || info->src.box.y < 0 || info->src.box.z < 0 ||
        info->dst.box.x < 0 || info->dst.box.y < 0 || info->dst.box.z < 0 ||
        info->src.box.width <= 0 || info->src.box.height <= 0 ||
        info->src.box.depth != 1 || info->dst.box.depth != 1 ||
        info->src.box.width != info->dst.box.width ||
        info->src.box.height != info->dst.box.height ||
        info->mask != PIPE_MASK_RGBA ||
        util_format_is_compressed(info->src.format) ||
        util_format_is_compressed(info->dst.format) ||
        util_format_is_depth_or_stencil(info->src.format) ||
        util_format_is_depth_or_stencil(info->dst.format) ||
        util_format_is_pure_integer(info->src.format) ||
        util_format_is_pure_integer(info->dst.format)) {
        return;
    }

    width = (size_t)info->src.box.width;
    height = (size_t)info->src.box.height;
    if (width > SIZE_MAX / 4u || height > SIZE_MAX / (width * 4u)) {
        return;
    }
    rgba_size = width * height * 4u;
    rgba = malloc(rgba_size);
    if (!rgba) {
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
    src = ao46_metal_resource_map(info->src.resource->screen,
                                  info->src.resource,
                                  info->src.level,
                                  PIPE_MAP_READ,
                                  &info->src.box,
                                  &src_transfer);
    if (!src) {
        free(rgba);
        return;
    }

    dst = ao46_metal_resource_map(info->dst.resource->screen,
                                  info->dst.resource,
                                  info->dst.level,
                                  PIPE_MAP_WRITE,
                                  &info->dst.box,
                                  &dst_transfer);
    if (!dst) {
        ao46_metal_resource_unmap(info->src.resource->screen, src_transfer);
        free(rgba);
        return;
    }

    util_format_read_4ub(info->src.format,
                         rgba,
                         (unsigned)info->src.box.width * 4u,
                         src,
                         src_transfer->stride,
                         0,
                         0,
                         (unsigned)info->src.box.width,
                         (unsigned)info->src.box.height);
    util_format_write_4ub(info->dst.format,
                          rgba,
                          (unsigned)info->src.box.width * 4u,
                          dst,
                          dst_transfer->stride,
                          0,
                          0,
                          (unsigned)info->dst.box.width,
                          (unsigned)info->dst.box.height);

    ao46_metal_resource_unmap(info->dst.resource->screen, dst_transfer);
    ao46_metal_resource_unmap(info->src.resource->screen, src_transfer);
    free(rgba);
}

static void
ao46_metal_blit(struct pipe_context *ctx, const struct pipe_blit_info *info)
{
    struct pipe_box src_box;

    if (!ctx || !info || !info->src.resource || !info->dst.resource ||
        info->scissor_enable || info->swizzle_enable || info->alpha_blend) {
        return;
    }

    if (info->src.box.width <= 0 || info->src.box.height <= 0 ||
        info->src.box.depth <= 0 || info->src.box.width != info->dst.box.width ||
        info->src.box.height != info->dst.box.height ||
        info->src.box.depth != info->dst.box.depth) {
        return;
    }

    if ((info->mask & PIPE_MASK_RGBA) &&
        (info->mask & PIPE_MASK_RGBA) != PIPE_MASK_RGBA) {
        return;
    }
    if ((info->mask & PIPE_MASK_ZS) &&
        (info->mask & PIPE_MASK_ZS) != PIPE_MASK_ZS) {
        return;
    }

    if (info->src.format != info->dst.format) {
        ao46_metal_blit_cpu_color_convert(ctx, info);
        return;
    }

    src_box = info->src.box;
    ctx->resource_copy_region(ctx,
                              info->dst.resource,
                              info->dst.level,
                              info->dst.box.x,
                              info->dst.box.y,
                              info->dst.box.z,
                              info->src.resource,
                              info->src.level,
                              &src_box);
}

static bool
ao46_metal_generate_mipmap(struct pipe_context *ctx,
                           struct pipe_resource *resource,
                           enum pipe_format format,
                           unsigned base_level,
                           unsigned last_level,
                           unsigned first_layer,
                           unsigned last_layer)
{
    struct ao46_metal_resource *mr;
    id<MTLTexture> target_texture = nil;
    id<MTLCommandBuffer> cmd_buffer;
    id<MTLBlitCommandEncoder> blit;
    NSUInteger slice_count;
    NSUInteger full_slice_count;
    unsigned level_count;
    MTLTextureType view_type;
    bool trace_runtime = getenv("AO46_TRACE_RUNTIME") != NULL;

    (void)format;
    if (!ctx || !resource || base_level >= last_level) {
        return false;
    }

    mr = ao46_metal_resource(resource);
    if (!mr->mtl_texture || resource->target == PIPE_BUFFER ||
        ao46_metal_texture_is_multisampled(resource) ||
        ao46_metal_texture_is_3d(resource)) {
        return false;
    }

    full_slice_count = ao46_metal_texture_slice_count(resource, base_level);
    slice_count = ao46_metal_texture_uses_slices(resource) ?
        (NSUInteger)(last_layer - first_layer + 1) : 1u;
    level_count = last_level - base_level + 1;
    view_type = ao46_metal_texture_type_for_sampler_view(resource,
                                                         resource->target,
                                                         MAX2(slice_count, 1u));

    if (base_level == 0 &&
        last_level == resource->last_level &&
        first_layer == 0 &&
        slice_count == full_slice_count &&
        view_type == mr->mtl_texture.textureType) {
        target_texture = [mr->mtl_texture retain];
    } else {
        target_texture = ao46_metal_create_texture_view(mr->mtl_texture,
                                                        mr->mtl_texture.pixelFormat,
                                                        view_type,
                                                        base_level,
                                                        MAX2(level_count, 1u),
                                                        first_layer,
                                                        MAX2(slice_count, 1u));
    }

    if (!target_texture) {
        return false;
    }

    ao46_metal_flush_for_resource_op(ctx);
    cmd_buffer = ao46_metal_get_command_buffer();
    if (!cmd_buffer) {
        [target_texture release];
        return false;
    }

    blit = [cmd_buffer blitCommandEncoder];
    if (!blit) {
        [target_texture release];
        return false;
    }

    if (trace_runtime) {
        fprintf(stderr,
                "[AO46Metal] generate_mipmap level=%u..%u layers=%u..%u target=%lu size=%lux%lu viewType=%lu\n",
                base_level,
                last_level,
                first_layer,
                last_layer,
                (unsigned long)resource->target,
                (unsigned long)target_texture.width,
                (unsigned long)target_texture.height,
                (unsigned long)target_texture.textureType);
    }

    [blit generateMipmapsForTexture:target_texture];
    [blit endEncoding];
    ao46_metal_commit_command_buffer(cmd_buffer, true);
    [target_texture release];
    return true;
}

static void
ao46_metal_clear_render_target(struct pipe_context *ctx,
                               struct pipe_surface *dst,
                               const union pipe_color_union *color,
                               unsigned dstx, unsigned dsty,
                               unsigned width, unsigned height,
                               bool render_condition_enabled)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    struct pipe_box box;
    id<MTLTexture> surface_texture;
    id<MTLTexture> resolve_texture = nil;

    (void)render_condition_enabled;
    if (!ctx || !dst || !dst->texture || !color) {
        return;
    }

    surface_texture = ao46_metal_get_surface_texture(dst);
    if (!surface_texture) {
        return;
    }

    if (mc) {
        for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
            if (ao46_metal_surface_equal(&mc->fb_state.cbufs[i], dst)) {
                resolve_texture = ao46_metal_get_framebuffer_resolve_texture(mc, i, dst);
                break;
            }
        }
    }

    if (ao46_metal_box_covers_surface(dst, dstx, dsty, width, height)) {
        id<MTLCommandBuffer> cmd_buffer;
        id<MTLRenderCommandEncoder> encoder;
        MTLRenderPassDescriptor *rpd;

        ao46_metal_flush_for_resource_op(ctx);
        cmd_buffer = ao46_metal_get_command_buffer();
        if (!cmd_buffer) {
            [surface_texture release];
            return;
        }

        rpd = [[MTLRenderPassDescriptor alloc] init];
        rpd.colorAttachments[0].texture = surface_texture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        if (resolve_texture && surface_texture.sampleCount > 1) {
            rpd.colorAttachments[0].resolveTexture = resolve_texture;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        } else {
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        rpd.colorAttachments[0].clearColor =
            MTLClearColorMake(color->f[0], color->f[1], color->f[2], color->f[3]);
        encoder = [cmd_buffer renderCommandEncoderWithDescriptor:rpd];
        [encoder endEncoding];
        [rpd release];
        [surface_texture release];
        [resolve_texture release];
        ao46_metal_commit_command_buffer(cmd_buffer, true);
        return;
    }

    u_box_2d(dstx, dsty, width, height, &box);
    if (ao46_metal_bytes_per_pixel(dst->format) == 4 &&
        (!ao46_metal_texture_is_multisampled(dst->texture) || resolve_texture)) {
        uint8_t texel[4];
        id<MTLTexture> target_texture = ao46_metal_texture_is_multisampled(dst->texture) ?
            resolve_texture : surface_texture;
        ao46_metal_pack_color_texel(dst->format, color, texel);
        box.z = 0;
        box.depth = ao46_metal_texture_type_uses_slices(target_texture.textureType) ?
            (int)MAX2(target_texture.arrayLength, 1u) : 1;
        (void)ao46_metal_fill_texture_box(target_texture, dst->format, 0, &box, texel);
    }
    [surface_texture release];
    [resolve_texture release];
}

static void
ao46_metal_clear_depth_stencil(struct pipe_context *ctx,
                               struct pipe_surface *dst,
                               unsigned clear_flags,
                               double depth,
                               unsigned stencil,
                               unsigned dstx, unsigned dsty,
                               unsigned width, unsigned height,
                               bool render_condition_enabled)
{
    id<MTLCommandBuffer> cmd_buffer;
    id<MTLRenderCommandEncoder> encoder;
    MTLRenderPassDescriptor *rpd;
    id<MTLTexture> surface_texture;

    (void)render_condition_enabled;
    if (!ctx || !dst || !dst->texture || !clear_flags) {
        return;
    }

    if (!ao46_metal_box_covers_surface(dst, dstx, dsty, width, height)) {
        return;
    }

    surface_texture = ao46_metal_get_surface_texture(dst);
    if (!surface_texture) {
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
    cmd_buffer = ao46_metal_get_command_buffer();
    if (!cmd_buffer) {
        [surface_texture release];
        return;
    }

    rpd = [[MTLRenderPassDescriptor alloc] init];
    rpd.depthAttachment.texture = surface_texture;
    rpd.depthAttachment.loadAction =
        (clear_flags & PIPE_CLEAR_DEPTH) ? MTLLoadActionClear : MTLLoadActionLoad;
    rpd.depthAttachment.storeAction = MTLStoreActionStore;
    rpd.depthAttachment.clearDepth = depth;

    if (ao46_metal_surface_has_stencil(dst)) {
        rpd.stencilAttachment.texture = surface_texture;
        rpd.stencilAttachment.loadAction =
            (clear_flags & PIPE_CLEAR_STENCIL) ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.clearStencil = stencil;
    }

    encoder = [cmd_buffer renderCommandEncoderWithDescriptor:rpd];
    [encoder endEncoding];
    [rpd release];
    [surface_texture release];
    ao46_metal_commit_command_buffer(cmd_buffer, true);
}

static void
ao46_metal_clear_texture(struct pipe_context *ctx,
                         struct pipe_resource *res,
                         unsigned level,
                         const struct pipe_box *box,
                         const void *data)
{
    struct ao46_metal_resource *mr;
    struct pipe_box full_box;

    (void)ctx;
    if (!res || !data) {
        return;
    }

    mr = ao46_metal_resource(res);
    if (!mr->mtl_texture) {
        return;
    }

    if (!box) {
        ao46_metal_default_box_for_resource(res, level, &full_box);
        box = &full_box;
    }

    (void)ao46_metal_fill_texture_box(mr->mtl_texture, res->format, level, box, data);
}

static void
ao46_metal_clear_buffer(struct pipe_context *ctx,
                        struct pipe_resource *res,
                        unsigned offset,
                        unsigned size,
                        const void *clear_value,
                        int clear_value_size)
{
    struct ao46_metal_resource *mr;
    uint8_t *contents;

    (void)ctx;
    if (!res || !clear_value || clear_value_size <= 0 || res->target != PIPE_BUFFER) {
        return;
    }

    mr = ao46_metal_resource(res);
    if (!mr->mtl_buffer) {
        return;
    }

    contents = [mr->mtl_buffer contents];
    if (!contents || offset >= res->width0) {
        return;
    }

    size = MIN2(size, res->width0 - offset);
    if (clear_value_size == 1) {
        memset(contents + offset, *(const uint8_t *)clear_value, size);
        return;
    }

    for (unsigned i = 0; i < size; i += clear_value_size) {
        unsigned chunk = MIN2((unsigned)clear_value_size, size - i);
        memcpy(contents + offset + i, clear_value, chunk);
    }
}

static void
ao46_metal_clear(struct pipe_context *ctx,
                 unsigned buffers,
                 uint32_t color_clear_mask,
                 uint8_t stencil_clear_mask,
                 const struct pipe_scissor_state *scissor_state,
                 const union pipe_color_union *color,
                 double depth,
                 unsigned stencil)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    unsigned fb_width;
    unsigned fb_height;
    unsigned clear_x;
    unsigned clear_y;
    unsigned clear_w;
    unsigned clear_h;

    if (!mc) {
        return;
    }

    fb_width = mc->fb_state.width;
    fb_height = mc->fb_state.height;
    if ((!fb_width || !fb_height) && mc->fb_state.nr_cbufs > 0 &&
        mc->fb_state.cbufs[0].texture) {
        fb_width = mc->fb_state.cbufs[0].texture->width0;
        fb_height = mc->fb_state.cbufs[0].texture->height0;
    } else if ((!fb_width || !fb_height) && mc->fb_state.zsbuf.texture) {
        fb_width = mc->fb_state.zsbuf.texture->width0;
        fb_height = mc->fb_state.zsbuf.texture->height0;
    }

    clear_x = scissor_state ? scissor_state->minx : 0;
    clear_y = scissor_state ? scissor_state->miny : 0;
    clear_w = scissor_state ? MAX2((int)scissor_state->maxx - (int)scissor_state->minx, 0) : fb_width;
    clear_h = scissor_state ? MAX2((int)scissor_state->maxy - (int)scissor_state->miny, 0) : fb_height;

    for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
        unsigned clear_bit = PIPE_CLEAR_COLOR0 << i;
        uint32_t channel_mask = (color_clear_mask >> (i * 4)) & 0xf;
        if (!(buffers & clear_bit) || !mc->fb_state.cbufs[i].texture ||
            !color || channel_mask != PIPE_MASK_RGBA) {
            continue;
        }

        ctx->clear_render_target(ctx,
                                 &mc->fb_state.cbufs[i],
                                 color,
                                 clear_x,
                                 clear_y,
                                 clear_w,
                                 clear_h,
                                 false);
    }

    if (mc->fb_state.zsbuf.texture &&
        (buffers & PIPE_CLEAR_DEPTHSTENCIL) &&
        ao46_metal_scissor_is_full(fb_width, fb_height, scissor_state)) {
        unsigned clear_flags = buffers & PIPE_CLEAR_DEPTHSTENCIL;
        if ((clear_flags & PIPE_CLEAR_STENCIL) && stencil_clear_mask != 0xff) {
            clear_flags &= ~PIPE_CLEAR_STENCIL;
        }

        if (clear_flags) {
            ctx->clear_depth_stencil(ctx,
                                     &mc->fb_state.zsbuf,
                                     clear_flags,
                                     depth,
                                     stencil,
                                     0,
                                     0,
                                     fb_width,
                                     fb_height,
                                     false);
        }
    }
}

static void
ao46_metal_trim_stage_bind_counts(struct ao46_metal_context *mc,
                                  mesa_shader_stage shader)
{
    int count = AO46_MAX_SAMPLERS;
    while (count > 0 && !mc->sampler_views[shader][count - 1]) {
        count--;
    }
    mc->num_sampler_views[shader] = (uint)count;

    count = AO46_MAX_SAMPLERS;
    while (count > 0 && !mc->samplers[shader][count - 1]) {
        count--;
    }
    mc->num_samplers[shader] = (uint)count;
}

static void
ao46_metal_trim_shader_buffer_count(struct ao46_metal_context *mc,
                                    mesa_shader_stage shader)
{
    int count = AO46_MAX_SHADER_BUFFERS;
    while (count > 0 && !mc->shader_buffers[shader][count - 1].buffer) {
        count--;
    }
    mc->num_shader_buffers[shader] = (uint)count;
}

static void
ao46_metal_trim_image_count(struct ao46_metal_context *mc,
                            mesa_shader_stage shader)
{
    int count = AO46_MAX_IMAGE_UNITS;
    while (count > 0 && !mc->image_views[shader][count - 1].resource) {
        count--;
    }
    mc->num_image_views[shader] = (uint)count;
}

static bool
ao46_metal_nir_uses_draw_parameters(const struct nir_shader *nir,
                                    bool *out_uses_draw_id)
{
    bool uses_parameters = false;

    if (out_uses_draw_id) {
        *out_uses_draw_id = false;
    }
    if (!nir) {
        return false;
    }
    nir_foreach_function_impl(impl, nir) {
        nir_foreach_block(block, impl) {
            nir_foreach_instr(instr, block) {
                if (instr->type == nir_instr_type_intrinsic) {
                    nir_intrinsic_op op =
                        nir_instr_as_intrinsic(instr)->intrinsic;
                    if (op == nir_intrinsic_load_draw_id ||
                        op == nir_intrinsic_load_base_vertex ||
                        op == nir_intrinsic_load_base_instance) {
                        uses_parameters = true;
                        if (op == nir_intrinsic_load_draw_id && out_uses_draw_id) {
                            *out_uses_draw_id = true;
                        }
                    }
                }
            }
        }
    }
    return uses_parameters;
}

static uint16_t
ao46_metal_nir_image_mask(const struct nir_shader *nir)
{
    uint16_t mask = 0;

    if (!nir) {
        return 0;
    }
    nir_foreach_variable_with_modes(variable, nir, nir_var_image) {
        if (variable->data.binding < AO46_MAX_IMAGE_UNITS) {
            mask |= UINT16_C(1) << variable->data.binding;
        }
    }
    return mask;
}

/* ----------------------------------------------------------------------
 * Shader creation (NIR -> MTLFunction)
 * ---------------------------------------------------------------------- */
static struct ao46_metal_shader *
ao46_metal_create_shader_state(const struct pipe_shader_state *shader)
{
    if (!shader || shader->type != PIPE_SHADER_IR_NIR || !shader->ir.nir) {
        fprintf(stderr, "AO46 Metal: invalid shader or missing NIR\n");
        return NULL;
    }

    struct ao46_metal_shader *ms = CALLOC_STRUCT(ao46_metal_shader);
    if (!ms) {
        fprintf(stderr, "AO46 Metal: out of memory for shader cache\n");
        return NULL;
    }

    struct nir_shader *nir = (struct nir_shader *)shader->ir.nir;
    const char *entry_name = "main";
    nir_function_impl *entrypoint = nir_shader_get_entrypoint(nir);
    if (entrypoint && entrypoint->function && entrypoint->function->name) {
        entry_name = entrypoint->function->name;
    }
    NSError *error = nil;
    id<MTLFunction> func = ao46_metal_compile_nir_to_msl(nir, entry_name, nil, &error);
    if (!func) {
        NSLog(@"AO46 Metal: Shader compilation failed: %@", error);
        FREE(ms);
        return NULL;
    }
    ms->function = func;
    ms->nir = nir;
    ms->stream_output = shader->stream_output;
    ms->uses_draw_parameters =
        ao46_metal_nir_uses_draw_parameters(nir, &ms->uses_draw_id);
    ms->image_mask = ao46_metal_nir_image_mask(nir);
    return ms;
}

static void
ao46_metal_destroy_shader_state(struct ao46_metal_shader *shader)
{
    if (!shader) return;
    [shader->compute_pipeline release];
    [shader->static_sample_mask_function release];
    [shader->function release];
    shader->compute_pipeline = nil;
    shader->static_sample_mask_function = nil;
    shader->function = nil;
    FREE(shader);
}

static id<MTLFunction>
ao46_metal_get_fragment_function(struct ao46_metal_shader *shader,
                                 uint32_t sample_mask)
{
    const char *entry_name = "main";
    nir_function_impl *entrypoint;
    NSError *error = nil;

    if (!shader || !shader->nir) {
        return nil;
    }
    if (sample_mask == UINT32_MAX) {
        return shader->function;
    }
    if (shader->static_sample_mask_function &&
        shader->static_sample_mask == sample_mask) {
        return shader->static_sample_mask_function;
    }

    entrypoint = nir_shader_get_entrypoint(shader->nir);
    if (entrypoint && entrypoint->function && entrypoint->function->name) {
        entry_name = entrypoint->function->name;
    }

    id<MTLFunction> function =
        ao46_metal_compile_nir_to_msl_with_static_sample_mask(
            shader->nir, entry_name, nil, sample_mask, &error);
    if (!function) {
        NSLog(@"AO46 Metal: static sample-mask shader compilation failed: %@", error);
        return nil;
    }

    [shader->static_sample_mask_function release];
    shader->static_sample_mask_function = function;
    shader->static_sample_mask = sample_mask;
    return function;
}

static void *
ao46_metal_create_vs_state(struct pipe_context *ctx,
                           const struct pipe_shader_state *shader)
{
    (void)ctx;
    return ao46_metal_create_shader_state(shader);
}

static void
ao46_metal_bind_vs_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->vs_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_vs_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void *
ao46_metal_create_fs_state(struct pipe_context *ctx,
                           const struct pipe_shader_state *shader)
{
    (void)ctx;
    return ao46_metal_create_shader_state(shader);
}

static void
ao46_metal_bind_fs_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->fs_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_fs_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void *
ao46_metal_create_gs_state(struct pipe_context *ctx,
                           const struct pipe_shader_state *shader)
{
    (void)ctx;
    return ao46_metal_create_shader_state(shader);
}

static void
ao46_metal_bind_gs_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->gs_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_gs_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void *
ao46_metal_create_tcs_state(struct pipe_context *ctx,
                            const struct pipe_shader_state *shader)
{
    (void)ctx;
    if (!shader || shader->type != PIPE_SHADER_IR_NIR || !shader->ir.nir ||
        shader->ir.nir->info.stage != MESA_SHADER_TESS_CTRL) {
        return NULL;
    }

    struct ao46_metal_shader *state = CALLOC_STRUCT(ao46_metal_shader);
    if (!state) {
        return NULL;
    }
    state->nir = shader->ir.nir;
    return state;
}

static void
ao46_metal_bind_tcs_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->tcs_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_tcs_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void *
ao46_metal_create_tes_state(struct pipe_context *ctx,
                            const struct pipe_shader_state *shader)
{
    (void)ctx;
    if (!shader || shader->type != PIPE_SHADER_IR_NIR || !shader->ir.nir ||
        shader->ir.nir->info.stage != MESA_SHADER_TESS_EVAL) {
        return NULL;
    }

    struct ao46_metal_shader *state = CALLOC_STRUCT(ao46_metal_shader);
    if (!state) {
        return NULL;
    }
    state->nir = shader->ir.nir;
    return state;
}

static void
ao46_metal_bind_tes_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->tes_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_tes_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void
ao46_metal_set_tess_state(struct pipe_context *ctx,
                          const float default_outer_level[4],
                          const float default_inner_level[2])
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);

    if (!mc || !default_outer_level || !default_inner_level) {
        return;
    }
    memcpy(mc->tess_outer_level, default_outer_level,
           sizeof(mc->tess_outer_level));
    memcpy(mc->tess_inner_level, default_inner_level,
           sizeof(mc->tess_inner_level));
    mc->tess_state_set = true;
}

static void
ao46_metal_set_patch_vertices(struct pipe_context *ctx,
                              uint8_t patch_vertices)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);

    if (!mc) {
        return;
    }
    mc->patch_vertices = patch_vertices >= 1 && patch_vertices <= 32
                             ? patch_vertices
                             : 0;
}

static void *
ao46_metal_create_compute_state(struct pipe_context *ctx,
                                const struct pipe_compute_state *state)
{
    struct ao46_metal_shader *ms;
    struct pipe_shader_state shader_state = {0};
    NSError *error = nil;

    (void)ctx;
    if (!state || state->ir_type != PIPE_SHADER_IR_NIR || !state->prog) {
        return NULL;
    }

    shader_state.type = state->ir_type;
    shader_state.ir.nir = (struct nir_shader *)state->prog;
    ms = ao46_metal_create_shader_state(&shader_state);
    if (!ms) {
        return NULL;
    }

    ms->compute_pipeline =
        [g_mtl_device newComputePipelineStateWithFunction:ms->function error:&error];
    if (!ms->compute_pipeline) {
        NSLog(@"AO46 Metal: Compute pipeline creation failed: %@", error);
        ao46_metal_destroy_shader_state(ms);
        return NULL;
    }

    ms->workgroup_size[0] = MAX2(ms->nir->info.workgroup_size[0], 1u);
    ms->workgroup_size[1] = MAX2(ms->nir->info.workgroup_size[1], 1u);
    ms->workgroup_size[2] = MAX2(ms->nir->info.workgroup_size[2], 1u);
    return ms;
}

static void
ao46_metal_bind_compute_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->cs_shader = (struct ao46_metal_shader *)hwcso;
}

static void
ao46_metal_delete_compute_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    ao46_metal_destroy_shader_state((struct ao46_metal_shader *)hwcso);
}

static void *
ao46_metal_create_blend_state(struct pipe_context *ctx,
                              const struct pipe_blend_state *blend)
{
    (void)ctx;
    struct ao46_metal_blend_state *state = CALLOC_STRUCT(ao46_metal_blend_state);
    if (!state) return NULL;
    state->base = *blend;
    return state;
}

static void
ao46_metal_bind_blend_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->blend = (struct ao46_metal_blend_state *)hwcso;
}

static void
ao46_metal_delete_blend_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    FREE(hwcso);
}

static void *
ao46_metal_create_rasterizer_state(struct pipe_context *ctx,
                                   const struct pipe_rasterizer_state *raster)
{
    (void)ctx;
    struct ao46_metal_rasterizer_state *state = CALLOC_STRUCT(ao46_metal_rasterizer_state);
    if (!state) return NULL;
    state->base = *raster;
    return state;
}

static void
ao46_metal_bind_rasterizer_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->raster = (struct ao46_metal_rasterizer_state *)hwcso;
}

static void
ao46_metal_delete_rasterizer_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    FREE(hwcso);
}

static void *
ao46_metal_create_depth_stencil_alpha_state(
    struct pipe_context *ctx,
    const struct pipe_depth_stencil_alpha_state *dsa)
{
    struct ao46_metal_depth_stencil_alpha_state *state =
        CALLOC_STRUCT(ao46_metal_depth_stencil_alpha_state);
    if (!state) return NULL;
    state->base = *dsa;

    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
    desc.depthCompareFunction = dsa->depth_enabled ?
        ao46_metal_compare_function(dsa->depth_func) :
        MTLCompareFunctionAlways;
    desc.depthWriteEnabled = dsa->depth_enabled && dsa->depth_writemask;

    MTLStencilDescriptor *front = nil;
    MTLStencilDescriptor *back = nil;
    if (dsa->stencil[0].enabled) {
        front = [[MTLStencilDescriptor alloc] init];
        ao46_metal_fill_stencil_descriptor(front, &dsa->stencil[0]);
        desc.frontFaceStencil = front;

        back = [[MTLStencilDescriptor alloc] init];
        if (dsa->stencil[1].enabled) {
            ao46_metal_fill_stencil_descriptor(back, &dsa->stencil[1]);
        } else {
            ao46_metal_fill_stencil_descriptor(back, &dsa->stencil[0]);
        }
        desc.backFaceStencil = back;
    }

    if (ctx && g_mtl_device) {
        state->mtl_state = [g_mtl_device newDepthStencilStateWithDescriptor:desc];
    }

    [front release];
    [back release];
    [desc release];
    return state;
}

static void
ao46_metal_bind_depth_stencil_alpha_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->dsa = (struct ao46_metal_depth_stencil_alpha_state *)hwcso;
}

static void
ao46_metal_delete_depth_stencil_alpha_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    struct ao46_metal_depth_stencil_alpha_state *state = hwcso;
    if (!state) return;
    [state->mtl_state release];
    state->mtl_state = nil;
    FREE(state);
}

static void
ao46_metal_set_blend_color(struct pipe_context *ctx,
                           const struct pipe_blend_color *blend_color)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (!mc) {
        return;
    }

    if (blend_color) {
        mc->blend_color = *blend_color;
    } else {
        memset(&mc->blend_color, 0, sizeof(mc->blend_color));
    }
}

static void
ao46_metal_set_stencil_ref(struct pipe_context *ctx,
                           const struct pipe_stencil_ref ref)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (!mc) {
        return;
    }

    mc->stencil_ref = ref;
}

static void *
ao46_metal_create_vertex_elements_state(struct pipe_context *ctx,
                                        unsigned num_elements,
                                        const struct pipe_vertex_element *elements)
{
    (void)ctx;
    struct ao46_metal_vertex_elements_state *state =
        CALLOC_STRUCT(ao46_metal_vertex_elements_state);
    if (!state || num_elements > PIPE_MAX_ATTRIBS ||
        (num_elements != 0 && !elements)) {
        FREE(state);
        return NULL;
    }

    for (unsigned i = 0; i < num_elements; ++i) {
        const struct pipe_vertex_element *element = &elements[i];

        if (element->vertex_buffer_index >= PIPE_MAX_ATTRIBS ||
            (!ao46_metal_vertex_format_uses_vbuf(element->src_format) &&
             ao46_metal_vertex_format(element->src_format) ==
                 MTLVertexFormatInvalid)) {
            FREE(state);
            return NULL;
        }

        for (unsigned j = 0; j < i; ++j) {
            const struct pipe_vertex_element *other = &elements[j];

            if (other->vertex_buffer_index == element->vertex_buffer_index &&
                (other->src_stride != element->src_stride ||
                 other->instance_divisor != element->instance_divisor)) {
                FREE(state);
                return NULL;
            }
        }
    }

    state->num_elements = num_elements;
    memcpy(state->elements, elements,
           state->num_elements * sizeof(struct pipe_vertex_element));
    return state;
}

static void
ao46_metal_bind_vertex_elements_state(struct pipe_context *ctx, void *hwcso)
{
    ao46_metal_context(ctx)->vertex_elements_state =
        (struct ao46_metal_vertex_elements_state *)hwcso;
}

static void
ao46_metal_delete_vertex_elements_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    FREE(hwcso);
}

/* ----------------------------------------------------------------------
 * Sampler support
 * ---------------------------------------------------------------------- */
static id<MTLSamplerState>
ao46_metal_create_mtl_sampler_state(const struct pipe_sampler_state *state)
{
    if (!state) return nil;

    MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];

    desc.minFilter = state->min_img_filter == PIPE_TEX_FILTER_LINEAR ?
                     MTLSamplerMinMagFilterLinear :
                     MTLSamplerMinMagFilterNearest;
    desc.magFilter = state->mag_img_filter == PIPE_TEX_FILTER_LINEAR ?
                     MTLSamplerMinMagFilterLinear :
                     MTLSamplerMinMagFilterNearest;

    if (state->min_mip_filter != PIPE_TEX_MIPFILTER_NONE) {
        desc.mipFilter = (state->min_mip_filter == PIPE_TEX_MIPFILTER_NEAREST) ?
                         MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    } else {
        desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
    }

    switch (state->wrap_s) {
        case PIPE_TEX_WRAP_REPEAT:
            desc.sAddressMode = MTLSamplerAddressModeRepeat;
            break;
        case PIPE_TEX_WRAP_CLAMP_TO_EDGE:
            desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
            break;
        case PIPE_TEX_WRAP_MIRROR_REPEAT:
            desc.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
            break;
        case PIPE_TEX_WRAP_CLAMP_TO_BORDER:
            desc.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
            break;
        default:
            desc.sAddressMode = MTLSamplerAddressModeRepeat;
            break;
    }

    switch (state->wrap_t) {
        case PIPE_TEX_WRAP_REPEAT:
            desc.tAddressMode = MTLSamplerAddressModeRepeat;
            break;
        case PIPE_TEX_WRAP_CLAMP_TO_EDGE:
            desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
            break;
        case PIPE_TEX_WRAP_MIRROR_REPEAT:
            desc.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
            break;
        case PIPE_TEX_WRAP_CLAMP_TO_BORDER:
            desc.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
            break;
        default:
            desc.tAddressMode = desc.sAddressMode;
            break;
    }

    desc.rAddressMode = desc.tAddressMode;
    desc.compareFunction = ao46_metal_compare_function(state->compare_func);
    desc.lodMinClamp = state->min_lod;
    desc.lodMaxClamp = state->max_lod;
    desc.maxAnisotropy = state->max_anisotropy > 1 ? state->max_anisotropy : 1;

    id<MTLSamplerState> sampler = [g_mtl_device newSamplerStateWithDescriptor:desc];
    [desc release];
    return sampler;
}

static void *
ao46_metal_create_sampler_state(struct pipe_context *ctx,
                                const struct pipe_sampler_state *sampler)
{
    (void)ctx;
    struct ao46_metal_sampler_state *state = CALLOC_STRUCT(ao46_metal_sampler_state);
    if (!state) return NULL;
    state->base = *sampler;
    state->mtl_sampler = ao46_metal_create_mtl_sampler_state(sampler);
    return state;
}

static struct pipe_sampler_view *
ao46_metal_create_sampler_view(struct pipe_context *ctx,
                               struct pipe_resource *texture,
                               const struct pipe_sampler_view *templ)
{
    struct ao46_metal_sampler_view *view;
    struct ao46_metal_resource *mr;
    MTLPixelFormat pixel_format;
    NSUInteger slice_count;
    unsigned level_count;
    bool full_levels;
    bool full_slices;
    MTLTextureType view_type;

    if (!ctx || !texture || !templ) {
        return NULL;
    }

    mr = ao46_metal_resource(texture);
    if (texture->target != PIPE_BUFFER && !mr->mtl_texture) {
        return NULL;
    }

    view = CALLOC_STRUCT(ao46_metal_sampler_view);
    if (!view) {
        return NULL;
    }

    pipe_reference_init(&view->base.reference, 1);
    view->base.format = templ->format;
    view->base.astc_decode_format = templ->astc_decode_format;
    view->base.is_tex2d_from_buf = templ->is_tex2d_from_buf;
    view->base.target = templ->target;
    view->base.swizzle_r = templ->swizzle_r;
    view->base.swizzle_g = templ->swizzle_g;
    view->base.swizzle_b = templ->swizzle_b;
    view->base.swizzle_a = templ->swizzle_a;
    view->base.context = ctx;
    view->base.u = templ->u;
    pipe_resource_reference(&view->base.texture, texture);

    if (texture->target == PIPE_BUFFER) {
        unsigned offset = view->base.u.buf.offset;
        unsigned size = view->base.u.buf.size;
        unsigned available = offset < texture->width0 ? texture->width0 - offset : 0;

        if (!mr->mtl_buffer || offset >= texture->width0) {
            pipe_resource_reference(&view->base.texture, NULL);
            FREE(view);
            return NULL;
        }

        if (!size || size > available) {
            size = available;
        }
        view->base.u.buf.size = size;

        if (ao46_metal_rgb32_buffer_texture_format(view->base.format)) {
            if (!g_mtl_adapter.gpu_addressable_buffers ||
                (offset % sizeof(uint32_t)) != 0 ||
                size == 0 || (size % (3 * sizeof(uint32_t))) != 0 ||
                view->base.swizzle_r != PIPE_SWIZZLE_X ||
                view->base.swizzle_g != PIPE_SWIZZLE_Y ||
                view->base.swizzle_b != PIPE_SWIZZLE_Z ||
                view->base.swizzle_a != PIPE_SWIZZLE_W) {
                pipe_resource_reference(&view->base.texture, NULL);
                FREE(view);
                return NULL;
            }

            /* Mesa NIR lowers this packed view through the per-stage address
             * table when the render pipeline is selected. */
            return &view->base;
        }

        view->mtl_texture = ao46_metal_create_buffer_texture_view(mr->mtl_buffer,
                                                                  view->base.format,
                                                                  offset,
                                                                  size);
        if (!view->mtl_texture) {
            pipe_resource_reference(&view->base.texture, NULL);
            FREE(view);
            return NULL;
        }

        return &view->base;
    }

    pixel_format = ao46_metal_pixel_format(view->base.format);
    slice_count = ao46_metal_texture_uses_slices(texture) || ao46_metal_texture_is_3d(texture) ?
        (NSUInteger)(view->base.u.tex.last_layer - view->base.u.tex.first_layer + 1) : 1u;
    level_count = view->base.u.tex.last_level - view->base.u.tex.first_level + 1;
    view_type = ao46_metal_texture_type_for_sampler_view(texture,
                                                         view->base.target,
                                                         MAX2(slice_count, 1u));
    full_levels = view->base.u.tex.first_level == 0 &&
        view->base.u.tex.last_level == texture->last_level;
    full_slices = view->base.u.tex.first_layer == 0 &&
        slice_count == ao46_metal_texture_slice_count(texture, view->base.u.tex.first_level);

    if (pixel_format == mr->mtl_texture.pixelFormat &&
        view_type == mr->mtl_texture.textureType &&
        full_levels && full_slices) {
        view->mtl_texture = [mr->mtl_texture retain];
    } else if (texture->nr_samples > 1) {
        view->mtl_texture = nil;
    } else {
        view->mtl_texture = ao46_metal_create_texture_view(mr->mtl_texture,
                                                           pixel_format,
                                                           view_type,
                                                           view->base.u.tex.first_level,
                                                           MAX2(level_count, 1u),
                                                           view->base.u.tex.first_layer,
                                                           MAX2(slice_count, 1u));
    }

    if (!view->mtl_texture) {
        pipe_resource_reference(&view->base.texture, NULL);
        FREE(view);
        return NULL;
    }

    return &view->base;
}

static void
ao46_metal_sampler_view_destroy(struct pipe_context *ctx,
                                struct pipe_sampler_view *view)
{
    struct ao46_metal_sampler_view *mv = ao46_metal_sampler_view(view);

    (void)ctx;
    if (!mv) {
        return;
    }

    [mv->mtl_texture release];
    mv->mtl_texture = nil;
    pipe_resource_reference(&mv->base.texture, NULL);
    FREE(mv);
}

static void
ao46_metal_sampler_view_release(struct pipe_context *ctx,
                                struct pipe_sampler_view *view)
{
    (void)ctx;
    pipe_sampler_view_reference(&view, NULL);
}

static void
ao46_metal_bind_sampler_states(struct pipe_context *ctx,
                               mesa_shader_stage shader,
                               unsigned start_slot,
                               unsigned num_samplers,
                               void **samplers)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (!mc || shader < 0 || shader >= MESA_SHADER_STAGES) return;

    unsigned limit = MIN2(start_slot + num_samplers, AO46_MAX_SAMPLERS);
    for (unsigned slot = start_slot, i = 0; slot < limit; slot++, i++) {
        mc->samplers[shader][slot] =
            samplers ? (struct ao46_metal_sampler_state *)samplers[i] : NULL;
    }

    ao46_metal_trim_stage_bind_counts(mc, shader);
}

static void
ao46_metal_delete_sampler_state(struct pipe_context *ctx, void *hwcso)
{
    (void)ctx;
    struct ao46_metal_sampler_state *state = hwcso;
    if (!state) return;
    [state->mtl_sampler release];
    state->mtl_sampler = nil;
    FREE(state);
}

// Helper: get MTLTexture from pipe_sampler_view
static id<MTLTexture>
ao46_metal_get_texture_from_view(struct pipe_sampler_view *view)
{
    if (!view || !view->texture) return nil;
    struct ao46_metal_sampler_view *mv = ao46_metal_sampler_view(view);
    if (mv->mtl_texture) {
        return mv->mtl_texture;
    }
    return ao46_metal_resource(view->texture)->mtl_texture;
}

static id<MTLTexture>
ao46_metal_get_texture_from_image_view(const struct pipe_image_view *image)
{
    struct ao46_metal_resource *mr;
    MTLPixelFormat pixel_format;
    MTLTextureType view_type;
    NSUInteger slice_count;
    bool full_view;

    if (!image || !image->resource) {
        return nil;
    }

    mr = ao46_metal_resource(image->resource);
    if (image->resource->target == PIPE_BUFFER) {
        unsigned offset;
        unsigned size;

        if (!mr->mtl_buffer) {
            return nil;
        }

        offset = image->u.buf.offset;
        if (offset >= image->resource->width0) {
            return nil;
        }

        size = image->u.buf.size;
        if (!size || size > image->resource->width0 - offset) {
            size = image->resource->width0 - offset;
        }

        return ao46_metal_create_buffer_texture_view(mr->mtl_buffer,
                                                     image->format,
                                                     offset,
                                                     size);
    }

    if (!mr->mtl_texture) {
        return nil;
    }

    if (ao46_metal_texture_is_3d(image->resource) && !image->u.tex.is_2d_view_of_3d) {
        return [mr->mtl_texture retain];
    }

    pixel_format = ao46_metal_pixel_format(image->format);
    if (pixel_format == MTLPixelFormatInvalid) {
        pixel_format = mr->mtl_texture.pixelFormat;
    }

    slice_count = image->u.tex.last_layer >= image->u.tex.first_layer ?
        (NSUInteger)(image->u.tex.last_layer - image->u.tex.first_layer + 1) : 1u;
    view_type = image->u.tex.is_2d_view_of_3d ?
        (slice_count > 1 ? MTLTextureType2DArray : MTLTextureType2D) :
        ao46_metal_texture_type_for_resource(image->resource);
    full_view = image->u.tex.level == 0 &&
        image->resource->last_level == 0 &&
        image->u.tex.first_layer == 0 &&
        slice_count == ao46_metal_texture_slice_count(image->resource, image->u.tex.level) &&
        pixel_format == mr->mtl_texture.pixelFormat &&
        view_type == mr->mtl_texture.textureType;

    if (full_view) {
        return [mr->mtl_texture retain];
    }
    return ao46_metal_create_texture_view(mr->mtl_texture,
                                          pixel_format,
                                          view_type,
                                          image->u.tex.level,
                                          1u,
                                          image->u.tex.first_layer,
                                          MAX2(slice_count, 1u));
}

/* ----------------------------------------------------------------------
 * Context state setters
 * ---------------------------------------------------------------------- */
static void
ao46_metal_set_framebuffer_state(struct pipe_context *ctx,
                                 const struct pipe_framebuffer_state *fb)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (mc->render_encoder && !ao46_metal_framebuffer_equal(&mc->fb_state, fb)) {
        ao46_metal_context_flush(ctx, NULL, 0);
    }
    util_copy_framebuffer_state(&mc->fb_state, fb);
}

static void
ao46_metal_set_constant_buffer(struct pipe_context *ctx,
                               mesa_shader_stage shader,
                               uint index,
                               const struct pipe_constant_buffer *cb)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (!mc || shader < 0 || shader >= MESA_SHADER_STAGES || index != 0) {
        return;
    }

    if (cb) {
        mc->const_buffers[shader] = *cb;
    } else {
        memset(&mc->const_buffers[shader], 0, sizeof(mc->const_buffers[shader]));
    }

    [mc->const_buffer_mtl[shader] release];
    mc->const_buffer_mtl[shader] = nil;
    mc->const_buffer_dirty[shader] = false;

    if (!cb) {
        return;
    }

    const void *src = NULL;
    size_t size = 0;
    struct pipe_transfer *transfer = NULL;

    if (cb->buffer) {
        struct pipe_resource *buf = cb->buffer;
        src = ctx->buffer_map(ctx, buf, 0, PIPE_MAP_READ, NULL, &transfer);
        if (!src) {
            return;
        }
        size = cb->buffer_size > 0 ? cb->buffer_size : buf->width0;
        src = (const char *)src + cb->buffer_offset;
    } else if (cb->user_buffer && cb->buffer_size > 0) {
        src = cb->user_buffer;
        size = cb->buffer_size;
    }

    if (!src || size == 0) {
        if (transfer) {
            ctx->buffer_unmap(ctx, transfer);
        }
        return;
    }

    id<MTLBuffer> mtl_buf =
        [g_mtl_device newBufferWithBytes:src
                                  length:size
                                 options:MTLResourceStorageModeShared];

    if (transfer) {
        ctx->buffer_unmap(ctx, transfer);
    }

    mc->const_buffer_mtl[shader] = mtl_buf;
    mc->const_buffer_dirty[shader] = mtl_buf != nil;
}

static void
ao46_metal_set_sampler_views(struct pipe_context *ctx,
                             mesa_shader_stage shader,
                             uint start_slot,
                             uint num_views,
                             uint unbind_num_trailing_slots,
                             struct pipe_sampler_view **views)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (!mc || shader < 0 || shader >= MESA_SHADER_STAGES) return;

    unsigned limit = MIN2(start_slot + num_views, AO46_MAX_SAMPLERS);
    for (unsigned slot = start_slot, i = 0; slot < limit; slot++, i++) {
        pipe_sampler_view_reference(&mc->sampler_views[shader][slot],
                                    views ? views[i] : NULL);
    }

    unsigned clear_end = MIN2(limit + unbind_num_trailing_slots, AO46_MAX_SAMPLERS);
    for (unsigned slot = limit; slot < clear_end; slot++) {
        pipe_sampler_view_reference(&mc->sampler_views[shader][slot], NULL);
    }

    ao46_metal_trim_stage_bind_counts(mc, shader);
}

static void
ao46_metal_set_vertex_buffers(struct pipe_context *ctx,
                              unsigned count,
                              const struct pipe_vertex_buffer *buffers)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    memset(mc->vertex_buffers, 0, sizeof(mc->vertex_buffers));
    mc->num_vertex_buffers = MIN2(count, PIPE_MAX_ATTRIBS);
    if (buffers && mc->num_vertex_buffers > 0) {
        memcpy(mc->vertex_buffers, buffers,
               mc->num_vertex_buffers * sizeof(struct pipe_vertex_buffer));
    }
}

static void
ao46_metal_set_sample_mask(struct pipe_context *ctx, unsigned sample_mask)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);

    if (mc) {
        mc->sample_mask = sample_mask;
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr, "[AO46Metal] sample mask=0x%08x\n", sample_mask);
        }
    }
}

static void
ao46_metal_set_min_samples(struct pipe_context *ctx, unsigned min_samples)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);

    if (mc) {
        mc->min_samples = min_samples;
    }
}

static void
ao46_metal_set_clip_state(struct pipe_context *ctx,
                          const struct pipe_clip_state *state)
{
    (void)ctx;
    (void)state;
}

static void
ao46_metal_set_polygon_stipple(struct pipe_context *ctx,
                               const struct pipe_poly_stipple *state)
{
    (void)ctx;
    (void)state;
}

static void
ao46_metal_set_window_rectangles(struct pipe_context *ctx,
                                 bool include,
                                 unsigned num_rectangles,
                                 const struct pipe_scissor_state *rects)
{
    (void)ctx;
    (void)include;
    (void)num_rectangles;
    (void)rects;
}

static void
ao46_metal_set_shader_buffers(struct pipe_context *ctx,
                              mesa_shader_stage shader,
                              unsigned start_slot,
                              unsigned count,
                              const struct pipe_shader_buffer *buffers,
                              unsigned writable_bitmask)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    unsigned limit;

    if (!mc || shader < 0 || shader >= MESA_SHADER_STAGES ||
        start_slot >= AO46_MAX_SHADER_BUFFERS) {
        return;
    }

    limit = MIN2(start_slot + count, AO46_MAX_SHADER_BUFFERS);
    for (unsigned slot = start_slot, i = 0; slot < limit; slot++, i++) {
        struct ao46_metal_shader_buffer_binding *dst = &mc->shader_buffers[shader][slot];

        pipe_resource_reference(&dst->buffer, NULL);
        dst->buffer_offset = 0;
        dst->buffer_size = 0;
        dst->writable = false;

        if (buffers && buffers[i].buffer) {
            pipe_resource_reference(&dst->buffer, buffers[i].buffer);
            dst->buffer_offset = buffers[i].buffer_offset;
            dst->buffer_size = buffers[i].buffer_size;
            dst->writable = (writable_bitmask & (1u << i)) != 0;
        }
    }

    ao46_metal_trim_shader_buffer_count(mc, shader);
}

static void
ao46_metal_set_shader_images(struct pipe_context *ctx,
                             mesa_shader_stage shader,
                             unsigned start_slot,
                             unsigned count,
                             unsigned unbind_num_trailing_slots,
                             const struct pipe_image_view *images)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    unsigned limit;
    unsigned clear_end;

    if (!mc || shader < 0 || shader >= MESA_SHADER_STAGES ||
        start_slot >= AO46_MAX_IMAGE_UNITS) {
        return;
    }

    limit = MIN2(start_slot + count, AO46_MAX_IMAGE_UNITS);
    for (unsigned slot = start_slot, i = 0; slot < limit; slot++, i++) {
        struct pipe_image_view *dst = &mc->image_views[shader][slot];

        [mc->image_binding_textures[shader][slot] release];
        mc->image_binding_textures[shader][slot] = nil;
        pipe_resource_reference(&dst->resource, NULL);
        memset(dst, 0, sizeof(*dst));

        if (images && images[i].resource) {
            *dst = images[i];
            pipe_resource_reference(&dst->resource, images[i].resource);
        }
    }

    clear_end = MIN2(limit + unbind_num_trailing_slots, AO46_MAX_IMAGE_UNITS);
    for (unsigned slot = limit; slot < clear_end; slot++) {
        struct pipe_image_view *dst = &mc->image_views[shader][slot];
        [mc->image_binding_textures[shader][slot] release];
        mc->image_binding_textures[shader][slot] = nil;
        pipe_resource_reference(&dst->resource, NULL);
        memset(dst, 0, sizeof(*dst));
    }

    ao46_metal_trim_image_count(mc, shader);
}

static void
ao46_metal_stream_output_target_destroy(struct pipe_context *ctx,
                                        struct pipe_stream_output_target *target)
{
    (void)ctx;
    if (!target) {
        return;
    }

    pipe_resource_reference(&target->buffer, NULL);
    FREE(target);
}

static struct pipe_stream_output_target *
ao46_metal_create_stream_output_target(struct pipe_context *ctx,
                                       struct pipe_resource *buffer,
                                       unsigned buffer_offset,
                                       unsigned buffer_size)
{
    struct ao46_metal_stream_output_target *target;

    if (!ctx || !buffer || buffer->target != PIPE_BUFFER ||
        buffer_offset >= buffer->width0 || !buffer_size ||
        buffer_size > buffer->width0 - buffer_offset) {
        return NULL;
    }

    target = CALLOC_STRUCT(ao46_metal_stream_output_target);
    if (!target) {
        return NULL;
    }

    pipe_reference_init(&target->base.reference, 1);
    pipe_resource_reference(&target->base.buffer, buffer);
    target->base.context = ctx;
    target->base.buffer_offset = buffer_offset;
    target->base.buffer_size = buffer_size;
    target->write_offset = 0;
    return &target->base;
}

static uint32_t
ao46_metal_stream_output_target_offset(struct pipe_stream_output_target *target)
{
    struct ao46_metal_stream_output_target *metal_target =
        (struct ao46_metal_stream_output_target *)target;

    return metal_target ? metal_target->write_offset : 0;
}

static void
ao46_metal_set_stream_output_targets(struct pipe_context *ctx,
                                     unsigned num_targets,
                                     struct pipe_stream_output_target **targets,
                                     const unsigned *offsets,
                                     enum mesa_prim output_prim)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    unsigned i;

    if (!mc || num_targets > PIPE_MAX_SO_BUFFERS) {
        return;
    }

    for (i = 0; i < num_targets; i++) {
        struct ao46_metal_stream_output_target *target =
            (struct ao46_metal_stream_output_target *)targets[i];

        if (target && offsets && offsets[i] != (unsigned)-1) {
            target->write_offset = offsets[i];
        }

        pipe_so_target_reference(&mc->stream_output_targets[i], targets[i]);
        mc->stream_output_offsets[i] = target ? target->write_offset : 0;
    }

    for (; i < PIPE_MAX_SO_BUFFERS; i++) {
        pipe_so_target_reference(&mc->stream_output_targets[i], NULL);
        mc->stream_output_offsets[i] = 0;
    }

    mc->num_stream_output_targets = num_targets;
    mc->stream_output_prim = output_prim;

    if (getenv("AO46_TRACE_RUNTIME")) {
        fprintf(stderr, "[AO46Metal] stream-output targets=%u primitive=%u\n",
                num_targets, output_prim);
    }
}

static struct pipe_query *
ao46_metal_create_query(struct pipe_context *ctx, unsigned query_type,
                        unsigned index)
{
    struct ao46_metal_query *query;

    (void)ctx;
    switch (query_type) {
        case PIPE_QUERY_PRIMITIVES_GENERATED:
        case PIPE_QUERY_PRIMITIVES_EMITTED:
        case PIPE_QUERY_SO_STATISTICS:
        case PIPE_QUERY_SO_OVERFLOW_PREDICATE:
            if (index >= 1) {
                return NULL;
            }
            break;
        case PIPE_QUERY_SO_OVERFLOW_ANY_PREDICATE:
            index = 0;
            break;
        default:
            return NULL;
    }

    query = CALLOC_STRUCT(ao46_metal_query);
    if (!query) {
        return NULL;
    }
    query->type = query_type;
    query->index = index;
    return (struct pipe_query *)query;
}

static void
ao46_metal_destroy_query(struct pipe_context *ctx, struct pipe_query *query)
{
    (void)ctx;
    FREE(query);
}

static bool
ao46_metal_begin_query(struct pipe_context *ctx, struct pipe_query *query)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    struct ao46_metal_query *mq = (struct ao46_metal_query *)query;

    if (!mc || !mq || mq->active || mq->index >= PIPE_MAX_VERTEX_STREAMS) {
        return false;
    }
    mq->start = mc->so_stats[mq->index];
    memset(&mq->result, 0, sizeof(mq->result));
    mq->active = true;
    mq->ended = false;
    return true;
}

static bool
ao46_metal_end_query(struct pipe_context *ctx, struct pipe_query *query)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    struct ao46_metal_query *mq = (struct ao46_metal_query *)query;
    const struct pipe_query_data_so_statistics *current;

    if (!mc || !mq || !mq->active || mq->index >= PIPE_MAX_VERTEX_STREAMS) {
        return false;
    }
    current = &mc->so_stats[mq->index];
    mq->result.num_primitives_written =
        current->num_primitives_written - mq->start.num_primitives_written;
    mq->result.primitives_storage_needed =
        current->primitives_storage_needed -
        mq->start.primitives_storage_needed;
    mq->active = false;
    mq->ended = true;
    return true;
}

static bool
ao46_metal_get_query_result(struct pipe_context *ctx, struct pipe_query *query,
                            bool wait, union pipe_query_result *result)
{
    struct ao46_metal_query *mq = (struct ao46_metal_query *)query;

    (void)ctx;
    (void)wait;
    if (!mq || !result || !mq->ended) {
        return false;
    }
    memset(result, 0, sizeof(*result));
    switch (mq->type) {
        case PIPE_QUERY_PRIMITIVES_GENERATED:
            result->u64 = mq->result.primitives_storage_needed;
            break;
        case PIPE_QUERY_PRIMITIVES_EMITTED:
            result->u64 = mq->result.num_primitives_written;
            break;
        case PIPE_QUERY_SO_STATISTICS:
            result->so_statistics = mq->result;
            break;
        case PIPE_QUERY_SO_OVERFLOW_PREDICATE:
        case PIPE_QUERY_SO_OVERFLOW_ANY_PREDICATE:
            result->b = mq->result.primitives_storage_needed >
                        mq->result.num_primitives_written;
            break;
        default:
            return false;
    }
    return true;
}

static void
ao46_metal_set_active_query_state(struct pipe_context *ctx, bool enable)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);

    if (mc) {
        mc->active_query_state = enable;
    }
}

static void
ao46_metal_set_viewport_states(struct pipe_context *ctx,
                               uint start_slot,
                               uint num_viewports,
                               const struct pipe_viewport_state *viewports)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (start_slot == 0 && num_viewports > 0) {
        mc->viewport = viewports[0];
    }
}

static void
ao46_metal_set_scissor_states(struct pipe_context *ctx,
                              uint start_slot,
                              uint num_scissors,
                              const struct pipe_scissor_state *scissors)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (start_slot == 0 && num_scissors > 0) {
        mc->scissor = scissors[0];
    }
}

static MTLVertexDescriptor *
ao46_metal_build_vertex_descriptor(const struct ao46_metal_context *mc)
{
    if (!mc->vertex_elements_state) {
        return nil;
    }

    MTLVertexDescriptor *descriptor = [[MTLVertexDescriptor alloc] init];
    for (unsigned i = 0; i < mc->vertex_elements_state->num_elements; i++) {
        const struct pipe_vertex_element *elem = &mc->vertex_elements_state->elements[i];
        if (elem->vertex_buffer_index >= PIPE_MAX_ATTRIBS) {
            [descriptor release];
            return nil;
        }

        MTLVertexFormat format =
            ao46_metal_vertex_format((enum pipe_format)elem->src_format);
        if (format == MTLVertexFormatInvalid) {
            [descriptor release];
            return nil;
        }

        descriptor.attributes[i].format = format;
        descriptor.attributes[i].offset = elem->src_offset;
        descriptor.attributes[i].bufferIndex =
            AO46_BUFFER_SLOT_VERTEX_BASE + elem->vertex_buffer_index;

        MTLVertexBufferLayoutDescriptor *layout =
            descriptor.layouts[AO46_BUFFER_SLOT_VERTEX_BASE + elem->vertex_buffer_index];
        layout.stride = elem->src_stride;
        layout.stepFunction = elem->instance_divisor ?
            MTLVertexStepFunctionPerInstance :
            MTLVertexStepFunctionPerVertex;
        layout.stepRate = elem->instance_divisor ? elem->instance_divisor : 1;
    }

    return descriptor;
}

/* ----------------------------------------------------------------------
 * Pipeline cache
 * ---------------------------------------------------------------------- */
static bool
ao46_metal_lower_clip_halfz_output(nir_builder *builder,
                                    nir_intrinsic_instr *intrinsic,
                                    void *data)
{
    (void)data;
    if (intrinsic->intrinsic != nir_intrinsic_store_output ||
        nir_intrinsic_io_semantics(intrinsic).location != VARYING_SLOT_POS ||
        nir_intrinsic_component(intrinsic) != 0 ||
        intrinsic->src[0].ssa->num_components != 4) {
        return false;
    }

    builder->cursor = nir_before_instr(&intrinsic->instr);
    nir_def *position = intrinsic->src[0].ssa;
    nir_def *half_z = nir_fmul_imm(
        builder,
        nir_fadd(builder, nir_channel(builder, position, 2),
                 nir_channel(builder, position, 3)),
        0.5f);
    nir_src_rewrite(&intrinsic->src[0],
                    nir_vector_insert_imm(builder, position, half_z, 2));
    return true;
}

static id<MTLFunction>
ao46_metal_compile_rgb32_stage_variant(
    const struct ao46_metal_context *mc,
    mesa_shader_stage stage,
    const struct ao46_metal_shader *shader,
    uint32_t sample_mask,
    bool *out_requires_variant)
{
    struct AO46MesaRGB32BufferTextureBinding bindings[AO46_MAX_SAMPLERS];
    struct nir_shader *variant;
    uint16_t texture_slot_mask = 0;
    uint32_t binding_count = 0;
    const char *entry_name = "main";
    nir_function_impl *entrypoint;
    NSError *error = nil;
    id<MTLFunction> function;
    bool uses_rgb32;
    bool lower_clip_depth;
    bool lower_stream_output;
    uint16_t stream_output_buffer_mask = 0;

    if (!out_requires_variant) {
        return nil;
    }
    *out_requires_variant = false;
    if (!mc || !shader || !shader->nir) {
        return nil;
    }
    (void)AO46MesaNIRCollectRGB32BufferTextureSlots(shader->nir,
                                                    &texture_slot_mask);
    lower_clip_depth = stage == MESA_SHADER_VERTEX &&
                       (!mc->raster || !mc->raster->base.clip_halfz);
    lower_stream_output =
        stage == MESA_SHADER_VERTEX && mc->num_stream_output_targets > 0 &&
        shader->stream_output.num_outputs > 0;

    for (unsigned slot = 0; slot < AO46_MAX_SAMPLERS; ++slot) {
        struct pipe_sampler_view *view;

        if (!(texture_slot_mask & (UINT16_C(1) << slot))) {
            continue;
        }
        view = mc->sampler_views[stage][slot];
        if (!view || !ao46_metal_rgb32_buffer_texture_format(view->format)) {
            continue;
        }
        if (!AO46MesaRGB32BufferTextureBindingFromSamplerView(
                view, slot, AO46_BUFFER_SLOT_RGB32_ADDRESS_TABLE,
                &bindings[binding_count])) {
            *out_requires_variant = true;
            return nil;
        }
        ++binding_count;
    }

    uses_rgb32 = binding_count != 0;
    if (!uses_rgb32 && !lower_clip_depth && !lower_stream_output) {
        return nil;
    }
    *out_requires_variant = true;
    variant = nir_shader_clone(NULL, shader->nir);
    if (!variant ||
        (uses_rgb32 &&
         !AO46MesaNIRLowerRGB32BufferTexturesWithAddressTable(
             variant, bindings, binding_count,
             AO46_BUFFER_SLOT_RGB32_ADDRESS_TABLE))) {
        ralloc_free(variant);
        return nil;
    }
    if (lower_clip_depth) {
        (void)nir_lower_clip_halfz(variant);
        (void)nir_shader_intrinsics_pass(
            variant, ao46_metal_lower_clip_halfz_output,
            nir_metadata_control_flow, NULL);
    }
    if (lower_stream_output &&
        !AO46MesaNIRLowerStreamOutput(variant, &shader->stream_output,
                                      &stream_output_buffer_mask)) {
        ralloc_free(variant);
        return nil;
    }

    entrypoint = nir_shader_get_entrypoint(variant);
    if (entrypoint && entrypoint->function && entrypoint->function->name) {
        entry_name = entrypoint->function->name;
    }
    function = stage == MESA_SHADER_FRAGMENT
                   ? ao46_metal_compile_nir_to_msl_with_static_sample_mask(
                         variant, entry_name, nil, sample_mask, &error)
                   : ao46_metal_compile_nir_to_msl(variant, entry_name, nil,
                                                   &error);
    if (!function && error) {
        NSLog(@"AO46 Metal: graphics stage variant compilation failed: %@", error);
    }
    ralloc_free(variant);
    return function;
}

static uint64_t
ao46_metal_compute_pipeline_key(struct ao46_metal_context *mc,
                                enum mesa_prim mode,
                                bool supports_indirect_commands)
{
    uint64_t key = 1469598103934665603ULL;
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->vs_shader);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->fs_shader);
    key = ao46_metal_hash_u64(key, mc->sample_mask);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->blend);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->raster);
    key = ao46_metal_hash_u64(
        key, mc->raster ? mc->raster->base.clip_halfz : false);
    key = ao46_metal_hash_u64(key, mc->num_stream_output_targets > 0);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->dsa);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->vertex_elements_state);
    key = ao46_metal_hash_u64(key, ao46_metal_primitive_topology_class(mode));
    key = ao46_metal_hash_u64(key, supports_indirect_commands);
    key = ao46_metal_hash_u64(key, ao46_metal_framebuffer_sample_count(&mc->fb_state));
    key = ao46_metal_hash_u64(key, mc->fb_state.nr_cbufs);
    for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
        key = ao46_metal_hash_u64(
            key, ao46_metal_attachment_pixel_format(&mc->fb_state.cbufs[i]));
    }
    key = ao46_metal_hash_u64(
        key, ao46_metal_attachment_pixel_format(&mc->fb_state.zsbuf));
    key = ao46_metal_hash_u64(
        key, ao46_metal_surface_has_stencil(&mc->fb_state.zsbuf));
    const mesa_shader_stage rgb32_stages[] = {
        MESA_SHADER_VERTEX,
        MESA_SHADER_FRAGMENT,
    };
    for (unsigned stage_index = 0;
         stage_index < ARRAY_SIZE(rgb32_stages); ++stage_index) {
        mesa_shader_stage stage = rgb32_stages[stage_index];
        for (unsigned slot = 0; slot < AO46_MAX_SAMPLERS; ++slot) {
            struct pipe_sampler_view *view = mc->sampler_views[stage][slot];

            if (!view || !ao46_metal_rgb32_buffer_texture_format(view->format)) {
                continue;
            }
            key = ao46_metal_hash_u64(key, stage);
            key = ao46_metal_hash_u64(key, slot);
            key = ao46_metal_hash_u64(key, (uintptr_t)view->texture);
            key = ao46_metal_hash_u64(key, view->format);
            key = ao46_metal_hash_u64(key, view->u.buf.offset);
            key = ao46_metal_hash_u64(key, view->u.buf.size);
        }
    }
    return key;
}

static void
ao46_metal_shader_for_stage(struct ao46_metal_context *mc,
                            mesa_shader_stage stage,
                            struct ao46_metal_shader **out_shader)
{
    struct ao46_metal_shader *shader = NULL;

    if (mc) {
        switch (stage) {
            case MESA_SHADER_VERTEX: shader = mc->vs_shader; break;
            case MESA_SHADER_FRAGMENT: shader = mc->fs_shader; break;
            case MESA_SHADER_COMPUTE: shader = mc->cs_shader; break;
            default: break;
        }
    }
    if (out_shader) {
        *out_shader = shader;
    }
}

static bool
ao46_metal_prepare_image_bindings(struct ao46_metal_context *mc,
                                  mesa_shader_stage stage)
{
    struct ao46_metal_shader *shader = NULL;
    id<MTLTexture> textures[AO46_MAX_IMAGE_UNITS] = {nil};
    bool valid = true;

    if (!mc || stage < 0 || stage >= MESA_SHADER_STAGES) {
        return false;
    }
    ao46_metal_shader_for_stage(mc, stage, &shader);
    if (!shader || !shader->image_mask) {
        for (unsigned slot = 0; slot < AO46_MAX_IMAGE_UNITS; ++slot) {
            [mc->image_binding_textures[stage][slot] release];
            mc->image_binding_textures[stage][slot] = nil;
        }
        return true;
    }
    for (unsigned slot = 0; slot < AO46_MAX_IMAGE_UNITS; ++slot) {
        if (!(shader->image_mask & (UINT16_C(1) << slot))) {
            continue;
        }
        if (!(mc->image_views[stage][slot].access &
              PIPE_IMAGE_ACCESS_READ_WRITE)) {
            valid = false;
            break;
        }
        textures[slot] = ao46_metal_get_texture_from_image_view(
            &mc->image_views[stage][slot]);
        if (!textures[slot]) {
            valid = false;
            break;
        }
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr,
                    "[AO46Metal] image stage=%d slot=%u texture-index=%u access=0x%x\n",
                    stage, slot, AO46_MESA_IMAGE_TEXTURE_BASE + slot,
                    mc->image_views[stage][slot].access);
        }
    }
    if (!valid) {
        for (unsigned slot = 0; slot < AO46_MAX_IMAGE_UNITS; ++slot) {
            [textures[slot] release];
        }
        return false;
    }
    for (unsigned slot = 0; slot < AO46_MAX_IMAGE_UNITS; ++slot) {
        [mc->image_binding_textures[stage][slot] release];
        mc->image_binding_textures[stage][slot] = textures[slot];
    }
    return true;
}

static bool
ao46_metal_bind_compute_resources(struct ao46_metal_context *mc)
{
    id<MTLComputeCommandEncoder> enc = mc ? mc->compute_encoder : nil;
    id<MTLBuffer> root_buffer;
    id<MTLBuffer> sampler_table_buffer;

    if (!enc) {
        return false;
    }

    root_buffer = (__bridge id<MTLBuffer>)g_mtl_adapter.graphics_root_buffer;
    sampler_table_buffer =
        (__bridge id<MTLBuffer>)g_mtl_adapter.graphics_sampler_table_buffer;
    if (root_buffer)
        [enc setBuffer:root_buffer offset:0 atIndex:AO46_BUFFER_SLOT_CONST0];
    if (sampler_table_buffer)
        [enc setBuffer:sampler_table_buffer
                offset:0
               atIndex:AO46_BUFFER_SLOT_SAMPLER_TABLE];

    if (mc->const_buffer_mtl[MESA_SHADER_COMPUTE]) {
        [enc setBuffer:mc->const_buffer_mtl[MESA_SHADER_COMPUTE]
                offset:0
               atIndex:0];
        mc->const_buffer_dirty[MESA_SHADER_COMPUTE] = false;
    }

    if (!ao46_metal_prepare_image_bindings(mc, MESA_SHADER_COMPUTE)) {
        return false;
    }

    for (uint i = 0; i < mc->num_shader_buffers[MESA_SHADER_COMPUTE] &&
                      i < AO46_MAX_SHADER_BUFFERS; i++) {
        struct ao46_metal_shader_buffer_binding *binding =
            &mc->shader_buffers[MESA_SHADER_COMPUTE][i];
        struct ao46_metal_resource *mr =
            binding->buffer ? ao46_metal_resource(binding->buffer) : NULL;

        if (!mr || !mr->mtl_buffer || binding->buffer_offset >= binding->buffer->width0) {
            continue;
        }

        [enc setBuffer:mr->mtl_buffer
                offset:binding->buffer_offset
               atIndex:i + 2];
    }

    for (uint i = 0; i < mc->num_sampler_views[MESA_SHADER_COMPUTE] &&
                      i < AO46_MAX_SAMPLERS; i++) {
        id<MTLTexture> tex =
            ao46_metal_get_texture_from_view(mc->sampler_views[MESA_SHADER_COMPUTE][i]);
        if (tex) {
            [enc setTexture:tex atIndex:i];
        }
    }

    for (uint i = 0; i < mc->num_samplers[MESA_SHADER_COMPUTE] &&
                      i < AO46_MAX_SAMPLERS; i++) {
        struct ao46_metal_sampler_state *sampler = mc->samplers[MESA_SHADER_COMPUTE][i];
        id<MTLSamplerState> mtl_sampler = sampler ? sampler->mtl_sampler : nil;
        if (mtl_sampler) {
            [enc setSamplerState:mtl_sampler atIndex:i];
        }
    }

    for (uint i = 0; i < mc->num_image_views[MESA_SHADER_COMPUTE] &&
                      i < AO46_MAX_IMAGE_UNITS; i++) {
        id<MTLTexture> tex = mc->image_binding_textures[MESA_SHADER_COMPUTE][i];
        if (!tex) {
            continue;
        }

        [enc setTexture:tex atIndex:AO46_MESA_IMAGE_TEXTURE_BASE + i];
        MTLResourceUsage usage = 0;
        if (mc->image_views[MESA_SHADER_COMPUTE][i].access &
            PIPE_IMAGE_ACCESS_READ) {
            usage |= MTLResourceUsageRead;
        }
        if (mc->image_views[MESA_SHADER_COMPUTE][i].access &
            PIPE_IMAGE_ACCESS_WRITE) {
            usage |= MTLResourceUsageWrite;
        }
        if (usage) {
            [enc useResource:tex usage:usage | MTLResourceUsageRead];
        }
    }
    return true;
}

static bool
ao46_metal_bind_rgb32_address_table(struct ao46_metal_context *mc,
                                    id<MTLRenderCommandEncoder> encoder,
                                    mesa_shader_stage stage)
{
    struct ao46_metal_shader *shader;
    uint64_t addresses[AO46_MAX_SAMPLERS] = {0};
    uint16_t texture_slot_mask = 0;
    bool used = false;

    if (!mc || !encoder ||
        (stage != MESA_SHADER_VERTEX && stage != MESA_SHADER_FRAGMENT)) {
        return false;
    }
    shader = stage == MESA_SHADER_VERTEX ? mc->vs_shader : mc->fs_shader;
    if (!shader || !shader->nir ||
        !AO46MesaNIRCollectRGB32BufferTextureSlots(shader->nir,
                                                    &texture_slot_mask)) {
        return true;
    }

    for (unsigned slot = 0; slot < AO46_MAX_SAMPLERS; ++slot) {
        struct pipe_sampler_view *view = mc->sampler_views[stage][slot];
        struct ao46_metal_resource *resource;
        uint64_t gpu_address;

        if (!(texture_slot_mask & (UINT16_C(1) << slot)) || !view ||
            !ao46_metal_rgb32_buffer_texture_format(view->format)) {
            continue;
        }
        resource = view->texture ? ao46_metal_resource(view->texture) : NULL;
        if (!resource || !resource->mtl_buffer ||
            view->u.buf.offset >= view->texture->width0 ||
            view->u.buf.size > view->texture->width0 - view->u.buf.offset) {
            return false;
        }
        if (@available(macOS 13.0, *)) {
            gpu_address = resource->mtl_buffer.gpuAddress;
        } else {
            return false;
        }
        if (!gpu_address || gpu_address > UINT64_MAX - view->u.buf.offset) {
            return false;
        }
        addresses[slot] = gpu_address + view->u.buf.offset;
        if (@available(macOS 13.0, *)) {
            [encoder useResource:resource->mtl_buffer
                           usage:MTLResourceUsageRead
                          stages:stage == MESA_SHADER_VERTEX
                                     ? MTLRenderStageVertex
                                     : MTLRenderStageFragment];
        } else {
            return false;
        }
        used = true;
    }

    if (!used) {
        return true;
    }
    if (!mc->rgb32_address_tables[stage]) {
        mc->rgb32_address_tables[stage] =
            [g_mtl_device newBufferWithLength:sizeof(addresses)
                                      options:MTLResourceStorageModeShared];
    }
    if (!mc->rgb32_address_tables[stage] ||
        !mc->rgb32_address_tables[stage].contents) {
        return false;
    }
    memcpy(mc->rgb32_address_tables[stage].contents, addresses,
           sizeof(addresses));
    if (stage == MESA_SHADER_VERTEX) {
        [encoder setVertexBuffer:mc->rgb32_address_tables[stage]
                          offset:0
                         atIndex:AO46_BUFFER_SLOT_RGB32_ADDRESS_TABLE];
    } else {
        [encoder setFragmentBuffer:mc->rgb32_address_tables[stage]
                            offset:0
                           atIndex:AO46_BUFFER_SLOT_RGB32_ADDRESS_TABLE];
    }
    return true;
}

static id<MTLRenderPipelineState>
ao46_metal_get_pipeline_state(struct ao46_metal_context *mc,
                              enum mesa_prim mode,
                              bool supports_indirect_commands)
{
    id<MTLFunction> vertex_variant = nil;
    id<MTLFunction> fragment_variant = nil;
    id<MTLFunction> fragment_function = nil;
    bool vertex_requires_variant = false;
    bool fragment_requires_variant = false;
    uint64_t new_key = ao46_metal_compute_pipeline_key(
        mc, mode, supports_indirect_commands);

    if (mc->pipeline_state && mc->pipeline_key == new_key) {
        return mc->pipeline_state;
    }
    if (!mc->vs_shader) {
        return nil;
    }

    vertex_variant = ao46_metal_compile_rgb32_stage_variant(
        mc, MESA_SHADER_VERTEX, mc->vs_shader, UINT32_MAX,
        &vertex_requires_variant);
    if (vertex_requires_variant && !vertex_variant) {
        return nil;
    }
    if (mc->fs_shader) {
        fragment_variant = ao46_metal_compile_rgb32_stage_variant(
            mc, MESA_SHADER_FRAGMENT, mc->fs_shader, mc->sample_mask,
            &fragment_requires_variant);
        if (fragment_requires_variant && !fragment_variant) {
            [vertex_variant release];
            return nil;
        }
        fragment_function = fragment_variant
                                ? fragment_variant
                                : ao46_metal_get_fragment_function(
                                      mc->fs_shader, mc->sample_mask);
        if (!fragment_function) {
            [vertex_variant release];
            return nil;
        }
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex_variant ? vertex_variant
                                         : mc->vs_shader->function;

    desc.fragmentFunction = fragment_function;

    MTLVertexDescriptor *vertex_descriptor = ao46_metal_build_vertex_descriptor(mc);
    if (vertex_descriptor) {
        desc.vertexDescriptor = vertex_descriptor;
    }

    for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *attachment =
            desc.colorAttachments[i];
        attachment.pixelFormat =
            ao46_metal_attachment_pixel_format(&mc->fb_state.cbufs[i]);

        if (mc->blend) {
            unsigned rt_index = mc->blend->base.independent_blend_enable ? i : 0;
            const struct pipe_rt_blend_state *rt = &mc->blend->base.rt[rt_index];
            attachment.blendingEnabled = rt->blend_enable;
            if (rt->blend_enable) {
                attachment.rgbBlendOperation =
                    ao46_metal_blend_operation((enum pipe_blend_func)rt->rgb_func);
                attachment.alphaBlendOperation =
                    ao46_metal_blend_operation((enum pipe_blend_func)rt->alpha_func);
                attachment.sourceRGBBlendFactor =
                    ao46_metal_blend_factor((enum pipe_blendfactor)rt->rgb_src_factor, false);
                attachment.destinationRGBBlendFactor =
                    ao46_metal_blend_factor((enum pipe_blendfactor)rt->rgb_dst_factor, false);
                attachment.sourceAlphaBlendFactor =
                    ao46_metal_blend_factor((enum pipe_blendfactor)rt->alpha_src_factor, true);
                attachment.destinationAlphaBlendFactor =
                    ao46_metal_blend_factor((enum pipe_blendfactor)rt->alpha_dst_factor, true);
            } else {
                attachment.rgbBlendOperation = MTLBlendOperationAdd;
                attachment.alphaBlendOperation = MTLBlendOperationAdd;
                attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
                attachment.destinationRGBBlendFactor = MTLBlendFactorZero;
                attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
                attachment.destinationAlphaBlendFactor = MTLBlendFactorZero;
            }
            attachment.writeMask = ao46_metal_color_write_mask(rt->colormask);
        } else {
            attachment.blendingEnabled = NO;
            attachment.writeMask = MTLColorWriteMaskAll;
        }
    }

    if (mc->fb_state.zsbuf.texture) {
        desc.depthAttachmentPixelFormat =
            ao46_metal_attachment_pixel_format(&mc->fb_state.zsbuf);
        desc.stencilAttachmentPixelFormat =
            ao46_metal_surface_has_stencil(&mc->fb_state.zsbuf) ?
            desc.depthAttachmentPixelFormat :
            MTLPixelFormatInvalid;
    }

    desc.inputPrimitiveTopology = ao46_metal_primitive_topology_class(mode);
    desc.rasterSampleCount = MAX2(ao46_metal_framebuffer_sample_count(&mc->fb_state), 1u);
    desc.alphaToCoverageEnabled = mc->blend ? mc->blend->base.alpha_to_coverage : NO;
    desc.alphaToOneEnabled = mc->blend ? mc->blend->base.alpha_to_one : NO;
    desc.rasterizationEnabled = mc->raster ? !mc->raster->base.rasterizer_discard : YES;
    desc.supportIndirectCommandBuffers = supports_indirect_commands;

    NSError *error = nil;
    id<MTLRenderPipelineState> ps = [g_mtl_device newRenderPipelineStateWithDescriptor:desc error:&error];
    [vertex_variant release];
    [fragment_variant release];
    [vertex_descriptor release];
    [desc release];
    if (!ps) {
        NSLog(@"Pipeline creation error: %@", error);
        return nil;
    }

    [mc->pipeline_state release];
    mc->pipeline_state = ps;
    mc->pipeline_key = new_key;
    return ps;
}

static void
ao46_metal_memory_barrier(struct pipe_context *ctx, unsigned flags)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    MTLBarrierScope scope = 0;

    if (!mc || flags == 0 || (flags & ~PIPE_BARRIER_ALL) != 0) {
        return;
    }

    if (flags & (PIPE_BARRIER_MAPPED_BUFFER | PIPE_BARRIER_SHADER_BUFFER |
                 PIPE_BARRIER_QUERY_BUFFER | PIPE_BARRIER_VERTEX_BUFFER |
                 PIPE_BARRIER_INDEX_BUFFER | PIPE_BARRIER_CONSTANT_BUFFER |
                 PIPE_BARRIER_INDIRECT_BUFFER |
                 PIPE_BARRIER_STREAMOUT_BUFFER |
                 PIPE_BARRIER_UPDATE_BUFFER)) {
        scope |= MTLBarrierScopeBuffers;
    }
    if (flags & (PIPE_BARRIER_TEXTURE | PIPE_BARRIER_IMAGE |
                 PIPE_BARRIER_UPDATE_TEXTURE)) {
        scope |= MTLBarrierScopeTextures;
    }
    if (flags & PIPE_BARRIER_FRAMEBUFFER) {
        scope |= MTLBarrierScopeRenderTargets;
    }

    if (scope != 0 && mc->compute_encoder &&
        [mc->compute_encoder respondsToSelector:
            @selector(memoryBarrierWithScope:)]) {
        [mc->compute_encoder memoryBarrierWithScope:scope];
        return;
    }
    if (scope != 0 && mc->render_encoder &&
        [mc->render_encoder respondsToSelector:
            @selector(memoryBarrierWithScope:afterStages:beforeStages:)]) {
        [mc->render_encoder
            memoryBarrierWithScope:scope
                      afterStages:MTLRenderStageVertex | MTLRenderStageFragment
                     beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
}

static void
ao46_metal_texture_barrier(struct pipe_context *ctx, unsigned flags)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    MTLBarrierScope scope = 0;

    if (!mc || flags == 0 ||
        (flags & ~(PIPE_TEXTURE_BARRIER_SAMPLER |
                   PIPE_TEXTURE_BARRIER_FRAMEBUFFER)) != 0) {
        return;
    }
    if (flags & PIPE_TEXTURE_BARRIER_SAMPLER) {
        scope |= MTLBarrierScopeTextures;
    }
    if (flags & PIPE_TEXTURE_BARRIER_FRAMEBUFFER) {
        scope |= MTLBarrierScopeRenderTargets;
    }

    if (scope != 0 && mc->render_encoder &&
        [mc->render_encoder respondsToSelector:
            @selector(memoryBarrierWithScope:afterStages:beforeStages:)]) {
        [mc->render_encoder
            memoryBarrierWithScope:scope
                      afterStages:MTLRenderStageFragment
                     beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
        return;
    }

    ao46_metal_flush_for_resource_op(ctx);
}

static void
ao46_metal_get_compute_state_info(struct pipe_context *ctx,
                                  void *cso,
                                  struct pipe_compute_state_object_info *info)
{
    struct ao46_metal_shader *shader = (struct ao46_metal_shader *)cso;

    (void)ctx;
    if (!info) {
        return;
    }

    memset(info, 0, sizeof(*info));
    if (!shader) {
        return;
    }

    info->max_threads = shader->compute_pipeline ?
        (unsigned)shader->compute_pipeline.maxTotalThreadsPerThreadgroup : 1024u;
    info->preferred_simd_size = shader->compute_pipeline ?
        (unsigned)MAX2(shader->compute_pipeline.threadExecutionWidth, 1u) : 32u;
    info->simd_sizes = info->preferred_simd_size;
    info->private_memory = shader->nir ? shader->nir->scratch_size : 0u;
}

static uint32_t
ao46_metal_get_compute_state_subgroup_size(struct pipe_context *ctx,
                                           void *cso,
                                           const uint32_t block[3])
{
    struct ao46_metal_shader *shader = (struct ao46_metal_shader *)cso;

    (void)ctx;
    (void)block;
    if (!shader || !shader->compute_pipeline) {
        return 1u;
    }

    return (uint32_t)MAX2(shader->compute_pipeline.threadExecutionWidth, 1u);
}

static void
ao46_metal_launch_grid(struct pipe_context *ctx,
                       const struct pipe_grid_info *info)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    struct ao46_metal_shader *shader;
    uint32_t block_x;
    uint32_t block_y;
    uint32_t block_z;
    NSUInteger threads_per_group;
    MTLSize threadgroup_size;

    if (!mc || !info) {
        return;
    }

    shader = mc->cs_shader;
    if (!shader || !shader->compute_pipeline) {
        return;
    }

    block_x = info->block[0] ? info->block[0] : shader->workgroup_size[0];
    block_y = info->block[1] ? info->block[1] : shader->workgroup_size[1];
    block_z = info->block[2] ? info->block[2] : shader->workgroup_size[2];
    block_x = MAX2(block_x, 1u);
    block_y = MAX2(block_y, 1u);
    block_z = MAX2(block_z, 1u);
    threads_per_group = (NSUInteger)block_x * (NSUInteger)block_y * (NSUInteger)block_z;
    if (!threads_per_group ||
        threads_per_group > shader->compute_pipeline.maxTotalThreadsPerThreadgroup) {
        return;
    }

    if (mc->render_encoder) {
        [mc->render_encoder endEncoding];
        mc->render_encoder = nil;
        mc->render_pass_started = false;
        [mc->render_pass release];
        mc->render_pass = nil;
    }

    if (!mc->cmd_buffer) {
        if (!ao46_metal_context_begin_submission(mc)) {
            return;
        }
    }

    if (!mc->compute_encoder) {
        mc->compute_encoder = [mc->cmd_buffer computeCommandEncoder];
        if (!mc->compute_encoder) {
            return;
        }
    }

    [mc->compute_encoder setComputePipelineState:shader->compute_pipeline];
    if (!ao46_metal_bind_compute_resources(mc)) {
        return;
    }

    threadgroup_size = MTLSizeMake(block_x, block_y, block_z);
    if (info->indirect) {
        struct ao46_metal_resource *mr = ao46_metal_resource(info->indirect);
        if (!mr->mtl_buffer || (info->indirect_offset & 0x3u)) {
            return;
        }

        [mc->compute_encoder dispatchThreadgroupsWithIndirectBuffer:mr->mtl_buffer
                                               indirectBufferOffset:info->indirect_offset
                                              threadsPerThreadgroup:threadgroup_size];
        return;
    }

    [mc->compute_encoder dispatchThreadgroups:MTLSizeMake(MAX2(info->grid[0], 1u),
                                                          MAX2(info->grid[1], 1u),
                                                          MAX2(info->grid[2], 1u))
                          threadsPerThreadgroup:threadgroup_size];
}

static enum mesa_prim
ao46_metal_effective_primitive_mode(const struct pipe_draw_info *info)
{
    if (info && info->was_line_loop && info->mode == MESA_PRIM_LINE_STRIP) {
        return MESA_PRIM_LINE_LOOP;
    }

    return info ? info->mode : MESA_PRIM_TRIANGLES;
}

static bool
ao46_metal_can_emulate_primitive(enum mesa_prim mode)
{
    switch (mode) {
        case MESA_PRIM_POINTS:
        case MESA_PRIM_LINES:
        case MESA_PRIM_LINE_STRIP:
        case MESA_PRIM_LINE_LOOP:
        case MESA_PRIM_TRIANGLES:
        case MESA_PRIM_TRIANGLE_STRIP:
        case MESA_PRIM_TRIANGLE_FAN:
        case MESA_PRIM_QUADS:
        case MESA_PRIM_POLYGON:
            return true;
        default:
            return false;
    }
}

static bool
ao46_metal_primitive_needs_emulation(const struct pipe_draw_info *info)
{
    enum mesa_prim mode = ao46_metal_effective_primitive_mode(info);

    if (mode == MESA_PRIM_LINE_LOOP ||
        mode == MESA_PRIM_TRIANGLE_FAN ||
        mode == MESA_PRIM_QUADS ||
        mode == MESA_PRIM_POLYGON) {
        return true;
    }

    return info && info->primitive_restart && ao46_metal_can_emulate_primitive(mode);
}

static uint32_t
ao46_metal_read_index_value(const void *indices,
                            uint16_t index_size,
                            unsigned index)
{
    switch (index_size) {
        case 2:
            return ((const uint16_t *)indices)[index];
        case 4:
            return ((const uint32_t *)indices)[index];
        default:
            return 0;
    }
}

static bool
ao46_metal_append_emulated_segment(uint32_t *expanded,
                                   size_t *expanded_count,
                                   enum mesa_prim mode,
                                   const uint32_t *segment,
                                   size_t segment_count)
{
    if (!segment_count) {
        return true;
    }

    switch (mode) {
        case MESA_PRIM_POINTS:
            for (size_t i = 0; i < segment_count; i++) {
                expanded[(*expanded_count)++] = segment[i];
            }
            return true;
        case MESA_PRIM_LINES:
            for (size_t i = 0; i + 1 < segment_count; i += 2) {
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
            }
            return true;
        case MESA_PRIM_LINE_STRIP:
            for (size_t i = 0; i + 1 < segment_count; i++) {
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
            }
            return true;
        case MESA_PRIM_LINE_LOOP:
            if (segment_count < 2) {
                return true;
            }
            for (size_t i = 0; i + 1 < segment_count; i++) {
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
            }
            expanded[(*expanded_count)++] = segment[segment_count - 1];
            expanded[(*expanded_count)++] = segment[0];
            return true;
        case MESA_PRIM_TRIANGLES:
            for (size_t i = 0; i + 2 < segment_count; i += 3) {
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
                expanded[(*expanded_count)++] = segment[i + 2];
            }
            return true;
        case MESA_PRIM_TRIANGLE_STRIP:
            for (size_t i = 0; i + 2 < segment_count; i++) {
                if (i & 1) {
                    expanded[(*expanded_count)++] = segment[i + 1];
                    expanded[(*expanded_count)++] = segment[i];
                } else {
                    expanded[(*expanded_count)++] = segment[i];
                    expanded[(*expanded_count)++] = segment[i + 1];
                }
                expanded[(*expanded_count)++] = segment[i + 2];
            }
            return true;
        case MESA_PRIM_TRIANGLE_FAN:
        case MESA_PRIM_POLYGON:
            if (segment_count < 3) {
                return true;
            }
            for (size_t i = 1; i + 1 < segment_count; i++) {
                expanded[(*expanded_count)++] = segment[0];
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
            }
            return true;
        case MESA_PRIM_QUADS:
            for (size_t i = 0; i + 3 < segment_count; i += 4) {
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 1];
                expanded[(*expanded_count)++] = segment[i + 2];
                expanded[(*expanded_count)++] = segment[i];
                expanded[(*expanded_count)++] = segment[i + 2];
                expanded[(*expanded_count)++] = segment[i + 3];
            }
            return true;
        default:
            return false;
    }
}

static MTLPrimitiveType
ao46_metal_emulated_primitive_type(enum mesa_prim mode)
{
    switch (mode) {
        case MESA_PRIM_POINTS:
            return MTLPrimitiveTypePoint;
        case MESA_PRIM_LINES:
        case MESA_PRIM_LINE_STRIP:
        case MESA_PRIM_LINE_LOOP:
            return MTLPrimitiveTypeLine;
        case MESA_PRIM_TRIANGLES:
        case MESA_PRIM_TRIANGLE_STRIP:
        case MESA_PRIM_TRIANGLE_FAN:
        case MESA_PRIM_QUADS:
        case MESA_PRIM_POLYGON:
        default:
            return MTLPrimitiveTypeTriangle;
    }
}

static bool
ao46_metal_build_emulated_index_buffer(struct pipe_context *ctx,
                                       const struct pipe_draw_info *info,
                                       const struct pipe_draw_start_count_bias *draw,
                                       id<MTLBuffer> *out_buffer,
                                       NSUInteger *out_count,
                                       MTLPrimitiveType *out_prim_type,
                                       NSInteger *out_base_vertex)
{
    struct pipe_transfer *transfer = NULL;
    const void *mapped_indices = NULL;
    uint32_t *segment = NULL;
    uint32_t *expanded = NULL;
    size_t segment_count = 0;
    size_t expanded_count = 0;
    size_t source_count;
    size_t max_expanded_count;
    enum mesa_prim mode;
    bool ok = false;

    *out_buffer = nil;
    *out_count = 0;
    *out_prim_type = MTLPrimitiveTypeTriangle;
    *out_base_vertex = 0;

    if (!ctx || !info || !draw || !g_mtl_device) {
        return false;
    }

    mode = ao46_metal_effective_primitive_mode(info);
    if (!ao46_metal_can_emulate_primitive(mode)) {
        return false;
    }

    source_count = draw->count;
    if (!source_count) {
        return true;
    }

    max_expanded_count = MAX2(source_count * 3u, 1u);
    segment = MALLOC(sizeof(uint32_t) * MAX2(source_count, 1u));
    expanded = MALLOC(sizeof(uint32_t) * max_expanded_count);
    if (!segment || !expanded) {
        goto cleanup;
    }

    if (info->index_size) {
        if ((info->index_size != 2 && info->index_size != 4) || !info->index.resource) {
            goto cleanup;
        }

        mapped_indices = ctx->buffer_map(ctx,
                                         info->index.resource,
                                         0,
                                         PIPE_MAP_READ,
                                         NULL,
                                         &transfer);
        if (!mapped_indices) {
            goto cleanup;
        }

        mapped_indices = (const uint8_t *)mapped_indices +
                         ((size_t)draw->start * info->index_size);
        *out_base_vertex = draw->index_bias;
    } else {
        *out_base_vertex = draw->start;
    }

    for (size_t i = 0; i < source_count; i++) {
        uint32_t value = info->index_size ?
            ao46_metal_read_index_value(mapped_indices, info->index_size, (unsigned)i) :
            (uint32_t)i;

        if (info->index_size && info->primitive_restart && value == info->restart_index) {
            if (!ao46_metal_append_emulated_segment(expanded,
                                                    &expanded_count,
                                                    mode,
                                                    segment,
                                                    segment_count)) {
                goto cleanup;
            }
            segment_count = 0;
            continue;
        }

        segment[segment_count++] = value;
    }

    if (!ao46_metal_append_emulated_segment(expanded,
                                            &expanded_count,
                                            mode,
                                            segment,
                                            segment_count)) {
        goto cleanup;
    }

    *out_prim_type = ao46_metal_emulated_primitive_type(mode);
    *out_count = expanded_count;
    if (!expanded_count) {
        ok = true;
        goto cleanup;
    }

    *out_buffer = [g_mtl_device newBufferWithBytes:expanded
                                            length:expanded_count * sizeof(uint32_t)
                                           options:MTLResourceStorageModeShared];
    ok = *out_buffer != nil;

cleanup:
    if (transfer) {
        ctx->buffer_unmap(ctx, transfer);
    }
    FREE(segment);
    FREE(expanded);
    if (!ok) {
        *out_count = 0;
        if (*out_buffer) {
            [*out_buffer release];
            *out_buffer = nil;
        }
    }
    return ok;
}

static MTLPrimitiveType
ao46_metal_primitive_type(enum mesa_prim mode)
{
    switch (mode) {
        case MESA_PRIM_POINTS:
            return MTLPrimitiveTypePoint;
        case MESA_PRIM_LINES:
            return MTLPrimitiveTypeLine;
        case MESA_PRIM_LINE_STRIP:
            return MTLPrimitiveTypeLineStrip;
        case MESA_PRIM_TRIANGLES:
            return MTLPrimitiveTypeTriangle;
        case MESA_PRIM_TRIANGLE_STRIP:
            return MTLPrimitiveTypeTriangleStrip;
        case MESA_PRIM_TRIANGLE_FAN:
            return MTLPrimitiveTypeTriangle;
        default:
            return MTLPrimitiveTypeTriangle;
    }
}

struct ao46_metal_draw_indirect_arguments {
    uint32_t vertex_count;
    uint32_t instance_count;
    uint32_t vertex_start;
    uint32_t base_instance;
};

struct ao46_metal_draw_indexed_indirect_arguments {
    uint32_t index_count;
    uint32_t instance_count;
    uint32_t index_start;
    int32_t base_vertex;
    uint32_t base_instance;
};

static void
ao46_metal_bind_draw_parameters(id<MTLRenderCommandEncoder> encoder,
                                uint32_t draw_id,
                                uint32_t vertex_count,
                                uint32_t first_vertex,
                                uint32_t base_instance,
                                int32_t base_vertex)
{
    const struct AO46MesaDrawParameters parameters = {
        .draw_id = draw_id,
        .vertex_count = vertex_count,
        .first_vertex = first_vertex,
        .base_instance = base_instance,
        .base_vertex = base_vertex,
    };

    [encoder setVertexBytes:&parameters
                     length:sizeof(parameters)
                    atIndex:AO46_BUFFER_SLOT_DRAW_PARAMETERS];
}

static bool
ao46_metal_bind_stream_output(struct ao46_metal_context *mc,
                              id<MTLRenderCommandEncoder> encoder,
                              uint32_t vertex_count,
                              uint32_t instance_count)
{
    uint64_t addresses[PIPE_MAX_SO_BUFFERS] = {0};
    uint8_t buffers_used = 0;

    if (!mc || !encoder || !mc->vs_shader ||
        mc->num_stream_output_targets == 0 ||
        mc->vs_shader->stream_output.num_outputs == 0) {
        return true;
    }
    if (@available(macOS 13.0, *)) {
        for (unsigned i = 0; i < mc->vs_shader->stream_output.num_outputs; ++i) {
            const struct pipe_stream_output *output =
                &mc->vs_shader->stream_output.output[i];
            struct ao46_metal_stream_output_target *target;
            struct ao46_metal_resource *resource;
            uint64_t required;

            if (output->stream != 0 ||
                output->output_buffer >= mc->num_stream_output_targets ||
                output->output_buffer >= PIPE_MAX_SO_BUFFERS ||
                !mc->stream_output_targets[output->output_buffer]) {
                return false;
            }
            if (buffers_used & (UINT8_C(1) << output->output_buffer)) {
                continue;
            }
            target = (struct ao46_metal_stream_output_target *)
                mc->stream_output_targets[output->output_buffer];
            resource = ao46_metal_resource(target->base.buffer);
            required = (uint64_t)vertex_count * instance_count *
                       mc->vs_shader->stream_output.stride[output->output_buffer] *
                       sizeof(uint32_t);
            if (!resource || !resource->mtl_buffer ||
                resource->mtl_buffer.gpuAddress == 0 ||
                target->write_offset > target->base.buffer_size ||
                required > target->base.buffer_size - target->write_offset) {
                return false;
            }
            addresses[output->output_buffer] =
                resource->mtl_buffer.gpuAddress + target->base.buffer_offset +
                target->write_offset;
            target->vertex_stride =
                mc->vs_shader->stream_output.stride[output->output_buffer] *
                sizeof(uint32_t);
            if (getenv("AO46_TRACE_RUNTIME")) {
                fprintf(stderr,
                        "[AO46Metal] stream-output buffer=%u gpu-va=0x%llx "
                        "base=%u offset=%u bytes=%llu\n",
                        output->output_buffer,
                        (unsigned long long)addresses[output->output_buffer],
                        target->base.buffer_offset, target->write_offset,
                        (unsigned long long)required);
            }
            [encoder useResource:resource->mtl_buffer
                           usage:MTLResourceUsageWrite
                          stages:MTLRenderStageVertex];
            buffers_used |= UINT8_C(1) << output->output_buffer;
        }
    } else {
        return false;
    }

    /* Metal copies these bytes into this draw's command state. A shared table
     * would let a later draw overwrite addresses before the GPU consumes it. */
    [encoder setVertexBytes:addresses
                     length:sizeof(addresses)
                    atIndex:AO46_BUFFER_SLOT_STREAM_OUTPUT_DESCRIPTORS];
    return true;
}

static void
ao46_metal_record_primitives(struct ao46_metal_context *mc,
                             enum mesa_prim mode, uint32_t vertex_count,
                             uint32_t instance_count, bool stream_output)
{
    uint64_t primitive_count;

    if (!mc || !mc->active_query_state || instance_count == 0) {
        return;
    }
    primitive_count =
        (uint64_t)u_decomposed_prims_for_vertices(mode, vertex_count) *
        instance_count;
    mc->so_stats[0].primitives_storage_needed += primitive_count;
    if (stream_output) {
        mc->so_stats[0].num_primitives_written += primitive_count;
    }
}

static void
ao46_metal_advance_stream_output(struct ao46_metal_context *mc,
                                 uint32_t vertex_count,
                                 uint32_t instance_count)
{
    uint8_t buffers_used = 0;

    if (!mc || !mc->vs_shader || mc->num_stream_output_targets == 0) {
        return;
    }
    for (unsigned i = 0; i < mc->vs_shader->stream_output.num_outputs; ++i) {
        const struct pipe_stream_output *output =
            &mc->vs_shader->stream_output.output[i];
        struct ao46_metal_stream_output_target *target;
        uint64_t written;

        if (output->output_buffer >= mc->num_stream_output_targets ||
            output->output_buffer >= PIPE_MAX_SO_BUFFERS ||
            (buffers_used & (UINT8_C(1) << output->output_buffer))) {
            continue;
        }
        target = (struct ao46_metal_stream_output_target *)
            mc->stream_output_targets[output->output_buffer];
        if (!target) {
            continue;
        }
        written = (uint64_t)vertex_count * instance_count *
                  mc->vs_shader->stream_output.stride[output->output_buffer] *
                  sizeof(uint32_t);
        target->write_offset += (unsigned)written;
        mc->stream_output_offsets[output->output_buffer] = target->write_offset;
        buffers_used |= UINT8_C(1) << output->output_buffer;
    }
}

static bool
ao46_mtl_gallium_buffer_for_adapter(
    struct pipe_resource *resource, const struct AO46MetalAdapter *adapter,
    struct AO46MetalBuffer *out_buffer)
{
    struct ao46_metal_resource *mr;
    uint64_t gpu_address = 0;

    if (!resource || !adapter || !out_buffer ||
        resource->target != PIPE_BUFFER ||
        !AO46MetalAdapterIsCurrent(adapter)) {
        return false;
    }

    mr = ao46_metal_resource(resource);
    if (!mr || !mr->mtl_buffer ||
        mr->mtl_buffer.device != (__bridge id<MTLDevice>)adapter->device ||
        !mr->mtl_buffer.contents || mr->mtl_buffer.length != resource->width0) {
        return false;
    }
    if (@available(macOS 13.0, *)) {
        gpu_address = mr->mtl_buffer.gpuAddress;
    }

    *out_buffer = (struct AO46MetalBuffer){
        .adapter = adapter,
        .native_buffer = (__bridge void *)mr->mtl_buffer,
        .cpu_mapping = mr->mtl_buffer.contents,
        .gpu_address = gpu_address,
        .length = mr->mtl_buffer.length,
    };
    return AO46MetalBufferIsCurrent(out_buffer);
}

static bool
ao46_mtl_gallium_range(const struct pipe_resource *resource,
                       size_t offset, size_t size)
{
    return resource && resource->target == PIPE_BUFFER && size > 0 &&
           offset <= resource->width0 && size <= resource->width0 - offset;
}

static bool
ao46_mtl_gallium_wait_submission(struct AO46MetalSubmission *submission)
{
    bool completed;

    if (!submission || !submission->native_command_buffer) {
        return false;
    }
    completed = AO46MetalSubmissionWait(submission);
    AO46MetalSubmissionDestroy(submission);
    return completed;
}

static bool
ao46_mtl_gallium_queue_compute(
    const struct AO46MetalComputePipeline *pipeline,
    const struct AO46MetalBufferBinding *bindings, size_t binding_count,
    uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
    uint32_t group_width, uint32_t group_height, uint32_t group_depth,
    struct AO46MetalSubmission *submission)
{
    return pipeline && AO46MetalComputeSubmitClassic(
               pipeline->adapter, pipeline, bindings, binding_count,
               grid_width, grid_height, grid_depth, group_width, group_height,
               group_depth, submission);
}

static void
ao46_mtl_gallium_retire_submissions(
    struct AO46MetalSubmission *submissions, size_t submission_count,
    bool wait_for_last)
{
    if (!submissions) {
        return;
    }
    if (wait_for_last && submission_count != 0) {
        (void)AO46MetalSubmissionWait(&submissions[submission_count - 1]);
    }
    for (size_t i = 0; i < submission_count; ++i) {
        AO46MetalSubmissionDestroy(&submissions[i]);
    }
}

static bool
ao46_mtl_gallium_poly_topology(
    const struct AO46MesaPolyTessellationPlan *plan,
    enum AO46MesaPolyKernel *out_kernel,
    enum AO46MetalPrimitive *out_primitive,
    uint32_t *out_minimum_indices)
{
    if (!plan || !out_kernel || !out_primitive || !out_minimum_indices) {
        return false;
    }

    switch (plan->domain) {
        case AO46_MESA_POLY_TESSELLATION_TRIANGLES:
            *out_kernel = AO46_MESA_POLY_KERNEL_TRIANGLE;
            break;
        case AO46_MESA_POLY_TESSELLATION_QUADS:
            *out_kernel = AO46_MESA_POLY_KERNEL_QUAD;
            break;
        case AO46_MESA_POLY_TESSELLATION_ISOLINES:
            *out_kernel = AO46_MESA_POLY_KERNEL_ISOLINE;
            break;
        default:
            return false;
    }

    switch (plan->output_primitive) {
        case AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES:
            *out_primitive = AO46_METAL_PRIMITIVE_TRIANGLES;
            *out_minimum_indices = 3;
            return true;
        case AO46_MESA_POLY_TESSELLATION_OUTPUT_LINES:
            *out_primitive = AO46_METAL_PRIMITIVE_LINES;
            *out_minimum_indices = 2;
            return true;
        case AO46_MESA_POLY_TESSELLATION_OUTPUT_POINTS:
            *out_primitive = AO46_METAL_PRIMITIVE_POINTS;
            *out_minimum_indices = 1;
            return true;
        default:
            return false;
    }
}

struct ao46_metal_poly_pending {
    struct AO46MetalSubmission compute[5];
    size_t compute_count;
    struct AO46MetalSubmission render;
    bool render_submitted;
};

static bool ao46_mtl_gallium_queue_poly_tessellation(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draw,
    struct ao46_metal_poly_pending *pending);

static bool
ao46_mtl_gallium_finish_poly_pending(
    struct ao46_metal_poly_pending *pending)
{
    bool completed = false;

    if (!pending) {
        return false;
    }
    if (pending->render_submitted) {
        completed = ao46_mtl_gallium_wait_submission(&pending->render);
    }
    ao46_mtl_gallium_retire_submissions(
        pending->compute, pending->compute_count, !pending->render_submitted);
    *pending = (struct ao46_metal_poly_pending){0};
    return completed;
}

static bool
ao46_mtl_gallium_dispatch_poly_tessellation(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draws, unsigned num_draws);

static bool
ao46_mtl_gallium_poly_reserve(size_t *cursor, size_t alignment,
                              size_t bytes, size_t *out_offset)
{
    size_t aligned;

    if (!cursor || !out_offset || alignment == 0 ||
        (alignment & (alignment - 1)) != 0 ||
        *cursor > SIZE_MAX - (alignment - 1)) {
        return false;
    }
    aligned = (*cursor + alignment - 1) & ~(alignment - 1);
    if (bytes > SIZE_MAX - aligned) {
        return false;
    }
    *out_offset = aligned;
    *cursor = aligned + bytes;
    return true;
}

static bool
ao46_mtl_gallium_poly_layout(
    const struct AO46MesaPolyTessellationPlan *plan,
    uint32_t input_vertex_count, uint32_t instance_count,
    uint64_t vertex_outputs,
    struct ao46_metal_poly_package_layout *layout)
{
    const size_t root_bytes = sizeof(uint64_t) + sizeof(uint32_t);
    const size_t heap_bytes_per_patch = 160u * 1024u;
    uint64_t vertex_output_bytes;
    size_t per_patch_words;
    size_t cursor = 0;

    if (!plan || !layout || plan->nr_patches == 0 ||
        input_vertex_count == 0 || instance_count == 0 ||
        input_vertex_count > UINT32_MAX / instance_count ||
        vertex_outputs == 0 ||
        plan->tcs_buffer_bytes == 0 ||
        plan->nr_patches > SIZE_MAX / heap_bytes_per_patch) {
        return false;
    }
    vertex_output_bytes = (uint64_t)input_vertex_count * instance_count *
                          util_bitcount64(vertex_outputs) * 16;
    if (vertex_output_bytes == 0 || vertex_output_bytes > UINT32_MAX) {
        return false;
    }
    per_patch_words = (size_t)plan->nr_patches * sizeof(uint32_t);
    *layout = (struct ao46_metal_poly_package_layout){0};
    layout->vertex_outputs_bytes = (size_t)vertex_output_bytes;
    layout->vertex_input_root_size = AO46MesaVertexInputRootSize();
    layout->heap_data_bytes =
        (size_t)plan->nr_patches * heap_bytes_per_patch;
    if (layout->heap_data_bytes > UINT32_MAX ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 128, root_bytes,
                                       &layout->root_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 128, root_bytes,
                                       &layout->count_root_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256, 16,
                                       &layout->sampler_table_offset) ||
        !ao46_mtl_gallium_poly_reserve(
            &cursor, 256, sizeof(struct poly_vertex_params),
            &layout->vertex_parameters_offset) ||
        !ao46_mtl_gallium_poly_reserve(
            &cursor, 256, layout->vertex_input_root_size,
            &layout->vertex_input_root_offset) ||
        !ao46_mtl_gallium_poly_reserve(
            &cursor, 256, layout->vertex_outputs_bytes,
            &layout->vertex_outputs_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256,
                                       sizeof(struct poly_tess_params),
                                       &layout->parameters_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256,
                                       sizeof(struct poly_heap),
                                       &layout->heap_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256,
                                       layout->heap_data_bytes,
                                       &layout->heap_data_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256, per_patch_words,
                                       &layout->counts_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256,
                                       5 * sizeof(uint32_t),
                                       &layout->draws_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256,
                                       plan->tcs_buffer_bytes,
                                       &layout->factors_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256, per_patch_words,
                                       &layout->coord_allocs_offset) ||
        !ao46_mtl_gallium_poly_reserve(&cursor, 256, 0,
                                       &layout->package_bytes) ||
        layout->package_bytes > UINT32_MAX) {
        return false;
    }
    return true;
}

static enum poly_tess_partitioning
ao46_mtl_gallium_poly_partitioning(const struct nir_shader *tcs,
                                   const struct nir_shader *tes)
{
    enum gl_tess_spacing spacing = MAX2(tcs->info.tess.spacing,
                                        tes->info.tess.spacing);

    switch (spacing) {
        case TESS_SPACING_FRACTIONAL_ODD:
            return POLY_TESS_PARTITIONING_FRACTIONAL_ODD;
        case TESS_SPACING_FRACTIONAL_EVEN:
            return POLY_TESS_PARTITIONING_FRACTIONAL_EVEN;
        case TESS_SPACING_UNSPECIFIED:
        case TESS_SPACING_EQUAL:
        default:
            return POLY_TESS_PARTITIONING_INTEGER;
    }
}

static void
ao46_mtl_gallium_poly_runtime_destroy(
    struct ao46_metal_poly_runtime *runtime)
{
    if (!runtime) {
        return;
    }
    pipe_resource_reference(&runtime->package, NULL);
    AO46MesaPolyKernelExecutorDestroy(&runtime->kernel_executor);
    AO46MesaRenderPipelineDestroy(&runtime->render_pipeline);
    AO46MesaComputePipelineDestroy(&runtime->tcs_pipeline);
    AO46MesaComputePipelineDestroy(&runtime->vs_pipeline);
    *runtime = (struct ao46_metal_poly_runtime){0};
}

static bool
ao46_mtl_gallium_poly_runtime_create(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draw,
    struct ao46_metal_poly_runtime *runtime)
{
    const unsigned parameter_binding = 3;
    const unsigned vertex_parameter_binding = 2;
    const unsigned vertex_input_root_binding = 4;
    const size_t root_bytes = sizeof(uint64_t) + sizeof(uint32_t);
    const struct nir_shader *vs;
    const struct nir_shader *tcs;
    const struct nir_shader *tes;
    struct nir_shader *lowered_vs = NULL;
    struct nir_shader *lowered_tcs = NULL;
    struct nir_shader *lowered_tes = NULL;
    struct nir_shader *fragment = NULL;
    struct ao46_metal_poly_package_layout layout;
    struct pipe_resource package_template = {
        .target = PIPE_BUFFER,
        .format = PIPE_FORMAT_R8_UNORM,
        .height0 = 1,
        .depth0 = 1,
        .array_size = 1,
        .usage = PIPE_USAGE_DEFAULT,
        .bind = PIPE_BIND_VERTEX_BUFFER | PIPE_BIND_INDEX_BUFFER,
    };
    const struct AO46MesaStaticBufferRequirement parameter_requirement = {
        .binding = parameter_binding,
        .minimum_size = sizeof(struct poly_tess_params),
    };
    struct poly_vertex_params *vertex_parameters;
    struct poly_tess_params *parameters;
    struct poly_heap *heap;
    struct AO46MesaVertexBufferRange vertex_buffers[PIPE_MAX_ATTRIBS] = {0};
    void *mapping = NULL;
    size_t mapping_length = 0;
    uint64_t package_address = 0;
    uint64_t parameter_address;
    uint32_t count_mode = POLY_TESS_MODE_COUNT;
    uint32_t emit_mode = POLY_TESS_MODE_WITH_COUNTS;
    uint32_t vertex_buffer_mask = 0;
    enum AO46MetalTextureFormat color_format;
    bool created = false;
    const char *stage = "input validation";

    if (!mc || !info || !draw || !runtime || mc->poly_render_pipeline ||
        mc->poly_tess_draw.parameter_resource ||
        mc->poly_tess_sequence.tcs_pipeline || !mc->vs_shader ||
        !mc->tcs_shader || !mc->tes_shader || !mc->fs_shader ||
        !mc->tess_state_set ||
        mc->patch_vertices == 0 || draw->count == 0 ||
        info->instance_count == 0 ||
        info->index_size != 0 || info->primitive_restart ||
        draw->index_bias != 0 ||
        mc->fb_state.nr_cbufs != 1 || !mc->fb_state.cbufs[0].texture) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr,
                    "[AO46Metal] automatic poly admission rejected: "
                    "ctx=%d shaders=%d%d%d%d tess=%d patch=%u count=%u "
                    "instances=%u first-instance=%u index=%u restart=%d "
                    "start=%u bias=%d cbufs=%u texture=%p\n",
                    mc != NULL,
                    mc && mc->vs_shader != NULL,
                    mc && mc->tcs_shader != NULL,
                    mc && mc->tes_shader != NULL,
                    mc && mc->fs_shader != NULL,
                    mc && mc->tess_state_set,
                    mc ? mc->patch_vertices : 0,
                    draw ? draw->count : 0,
                    info ? info->instance_count : 0,
                    info ? info->start_instance : 0,
                    info ? info->index_size : 0,
                    info && info->primitive_restart,
                    draw ? draw->start : 0,
                    draw ? draw->index_bias : 0,
                    mc ? mc->fb_state.nr_cbufs : 0,
                    mc && mc->fb_state.nr_cbufs
                        ? (void *)mc->fb_state.cbufs[0].texture
                        : NULL);
        }
        return false;
    }
    vs = mc->vs_shader->nir;
    tcs = mc->tcs_shader->nir;
    tes = mc->tes_shader->nir;
    if (!vs || !tcs || !tes || !mc->fs_shader->nir ||
        draw->count % mc->patch_vertices != 0) {
        return false;
    }
    switch (mc->fb_state.cbufs[0].format) {
        case PIPE_FORMAT_R8G8B8A8_UNORM:
            color_format = AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
            break;
        case PIPE_FORMAT_B8G8R8A8_UNORM:
            color_format = AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM;
            break;
        default:
            return false;
    }

    *runtime = (struct ao46_metal_poly_runtime){0};
    stage = "poly plan and package layout";
    if (!AO46MesaPolyTessellationPlanCreate(
            tcs, mc->patch_vertices, draw->count, info->instance_count,
            parameter_binding, &runtime->plan) ||
        !AO46MesaPolyTessellationPlanFinalize(&runtime->plan, tes) ||
        !ao46_mtl_gallium_poly_layout(
            &runtime->plan, draw->count, info->instance_count,
            vs->info.outputs_written, &layout)) {
        goto out;
    }

    lowered_vs = nir_shader_clone(NULL, vs);
    lowered_tcs = nir_shader_clone(NULL, tcs);
    lowered_tes = nir_shader_clone(NULL, tes);
    fragment = nir_shader_clone(NULL, mc->fs_shader->nir);
    stage = "Mesa poly shader clones";
    if (!lowered_vs || !lowered_tcs || !lowered_tes || !fragment) {
        goto out;
    }
    stage = "Mesa VS/TCS/TES poly lowering";
    if ((vs->info.inputs_read != 0 &&
         (!mc->vertex_elements_state ||
          !AO46MesaNIRLowerVertexInputs(
              lowered_vs, mc->vertex_elements_state->elements,
              mc->vertex_elements_state->num_elements,
              vertex_input_root_binding))) ||
        !AO46MesaPolyVertexTessellationLower(
            lowered_vs, lowered_tcs, lowered_tes,
            vertex_parameter_binding, parameter_binding,
            vs->info.outputs_written, (int32_t)draw->start,
            info->start_instance, info->index_size)) {
        goto out;
    }
    stage = "Mesa poly VS compute pipeline";
    if (!AO46MesaComputePipelineCreateWithStaticBuffers(
            &g_mtl_adapter, lowered_vs,
            (UINT16_C(1) << vertex_parameter_binding) |
                (vs->info.inputs_read
                     ? UINT16_C(1) << vertex_input_root_binding
                     : 0),
            &runtime->vs_pipeline)) {
        goto out;
    }
    stage = "Mesa poly TCS compute pipeline";
    if (!AO46MesaComputePipelineCreateWithStaticBuffers(
            &g_mtl_adapter, lowered_tcs,
            (UINT16_C(1) << vertex_parameter_binding) |
                (UINT16_C(1) << parameter_binding),
            &runtime->tcs_pipeline)) {
        goto out;
    }
    stage = "Mesa poly TES render pipeline";
    if (!AO46MesaRenderPipelineCreateWithStageStaticBufferRequirements(
            &g_mtl_adapter, lowered_tes, fragment, color_format, NULL, 0,
            UINT16_C(1) << parameter_binding, &parameter_requirement, 1, 0,
            NULL, 0, &runtime->render_pipeline)) {
        goto out;
    }
    stage = "Mesa poly kernel executor";
    if (!AO46MesaPolyKernelExecutorCreate(&g_mtl_adapter,
                                          &runtime->kernel_executor)) {
        goto out;
    }

    package_template.width0 = layout.package_bytes;
    stage = "transient package allocation";
    runtime->package =
        mc->base.screen->resource_create(mc->base.screen, &package_template);
    if (!runtime->package ||
        !AO46MTLGalliumResourceGetCPUMapping(runtime->package, &mapping,
                                             &mapping_length) ||
        mapping_length < layout.package_bytes ||
        !AO46MTLGalliumResourceGetGPUAddress(runtime->package,
                                             &package_address)) {
        goto out;
    }

    memset(mapping, 0, layout.package_bytes);
    stage = "transient package construction";
    if (vs->info.inputs_read) {
        for (unsigned i = 0;
             i < mc->vertex_elements_state->num_elements; ++i) {
            const struct pipe_vertex_element *element =
                &mc->vertex_elements_state->elements[i];
            const unsigned index = element->vertex_buffer_index;
            const struct pipe_vertex_buffer *binding;
            struct pipe_resource *resource;

            if (!(vs->info.inputs_read &
                  BITFIELD64_BIT(VERT_ATTRIB_GENERIC0 + i))) {
                continue;
            }
            if (index >= mc->num_vertex_buffers ||
                index >= PIPE_MAX_ATTRIBS) {
                goto out;
            }
            binding = &mc->vertex_buffers[index];
            resource = binding->buffer.resource;
            if (binding->is_user_buffer || !resource ||
                resource->target != PIPE_BUFFER ||
                binding->buffer_offset > resource->width0 ||
                !AO46MTLGalliumResourceGetGPUAddress(
                    resource, &vertex_buffers[index].gpu_address)) {
                goto out;
            }
            vertex_buffers[index] = (struct AO46MesaVertexBufferRange){
                .gpu_address = vertex_buffers[index].gpu_address,
                .offset = binding->buffer_offset,
                .size = resource->width0,
                .valid = true,
            };
            vertex_buffer_mask |= UINT32_C(1) << index;
        }
        if (!AO46MesaVertexInputRootBuild(
                (uint8_t *)mapping + layout.vertex_input_root_offset,
                layout.vertex_input_root_size, package_address,
                vs->info.inputs_read,
                mc->vertex_elements_state->elements,
                mc->vertex_elements_state->num_elements, vertex_buffers,
                mc->num_vertex_buffers)) {
            goto out;
        }
    }
    parameter_address = package_address + layout.parameters_offset;
    memcpy((uint8_t *)mapping + layout.root_offset, &parameter_address,
           sizeof(parameter_address));
    memcpy((uint8_t *)mapping + layout.root_offset + sizeof(uint64_t),
           &emit_mode, sizeof(emit_mode));
    memcpy((uint8_t *)mapping + layout.count_root_offset, &parameter_address,
           sizeof(parameter_address));
    memcpy((uint8_t *)mapping + layout.count_root_offset + sizeof(uint64_t),
           &count_mode, sizeof(count_mode));

    heap = (struct poly_heap *)((uint8_t *)mapping + layout.heap_offset);
    *heap = (struct poly_heap){
        .base = package_address + layout.heap_data_offset,
        .bottom = 0,
        .size = (uint32_t)layout.heap_data_bytes,
    };
    vertex_parameters = (struct poly_vertex_params *)(
        (uint8_t *)mapping + layout.vertex_parameters_offset);
    {
        const uint32_t workgroup_size[3] = {64, 1, 1};
        poly_vertex_params_init(vertex_parameters, vs->info.outputs_written,
                                workgroup_size);
    }
    poly_vertex_params_set_draw(vertex_parameters, draw->count,
                                info->instance_count);
    vertex_parameters->output_buffer =
        package_address + layout.vertex_outputs_offset;
    parameters = (struct poly_tess_params *)((uint8_t *)mapping +
                                             layout.parameters_offset);
    *parameters = (struct poly_tess_params){
        .heap = package_address + layout.heap_offset,
        .patch_coord_buffer = package_address + layout.heap_data_offset,
        .coord_allocs = package_address + layout.coord_allocs_offset,
        .out_draws = package_address + layout.draws_offset,
        .tcs_buffer = package_address + layout.factors_offset,
        .counts = package_address + layout.counts_offset,
        .index_buffer = package_address + layout.heap_data_offset,
        .statistic = 0,
        .tcs_per_vertex_outputs = poly_tcs_per_vertex_outputs(tcs),
        .input_patch_size = runtime->plan.input_patch_size,
        .output_patch_size = runtime->plan.output_patch_size,
        .tcs_patch_constants = util_last_bit(tcs->info.patch_outputs_written),
        .patches_per_instance = runtime->plan.patches_per_instance,
        .tcs_stride_el = runtime->plan.tcs_stride_bytes / sizeof(float),
        .nr_patches = runtime->plan.nr_patches,
        .partitioning = ao46_mtl_gallium_poly_partitioning(tcs, tes),
        .points_mode = runtime->plan.point_mode,
        .isolines = runtime->plan.domain ==
                    AO46_MESA_POLY_TESSELLATION_ISOLINES,
        .ccw = !tes->info.tess.ccw,
    };
    memcpy(parameters->tess_level_outer_default, mc->tess_outer_level,
           sizeof(parameters->tess_level_outer_default));
    memcpy(parameters->tess_level_inner_default, mc->tess_inner_level,
           sizeof(parameters->tess_level_inner_default));

    runtime->draw = (struct AO46MetalGalliumPolyTessellationDraw){
        .parameter_resource = runtime->package,
        .parameter_offset = layout.parameters_offset,
        .parameter_size = sizeof(struct poly_tess_params),
        .index_resource = runtime->package,
        .index_offset = layout.heap_data_offset,
        .index_size = layout.heap_data_bytes,
        .indirect_resource = runtime->package,
        .indirect_offset = layout.draws_offset,
        .indirect_size = 5 * sizeof(uint32_t),
        .maximum_index_count = layout.heap_data_bytes / sizeof(uint32_t),
        .input_patch_size = runtime->plan.input_patch_size,
        .input_vertex_count = draw->count,
    };
    runtime->sequence = (struct AO46MetalGalliumPolyTessellationSequence){
        .vs_pipeline = &runtime->vs_pipeline,
        .tcs_pipeline = &runtime->tcs_pipeline,
        .kernel_executor = &runtime->kernel_executor,
        .plan = &runtime->plan,
        .count_root_offset = layout.count_root_offset,
        .root_offset = layout.root_offset,
        .root_size = root_bytes,
        .sampler_table_offset = layout.sampler_table_offset,
        .sampler_table_size = 16,
        .vertex_parameter_offset = layout.vertex_parameters_offset,
        .vertex_parameter_size = sizeof(struct poly_vertex_params),
        .vertex_input_root_offset = layout.vertex_input_root_offset,
        .vertex_input_root_size = vs->info.inputs_read
                                      ? layout.vertex_input_root_size
                                      : 0,
        .vertex_buffer_mask = vertex_buffer_mask,
    };
    created = true;

out:
    ralloc_free(fragment);
    ralloc_free(lowered_tes);
    ralloc_free(lowered_tcs);
    ralloc_free(lowered_vs);
    if (!created) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr, "[AO46Metal] automatic poly setup stopped at %s\n",
                    stage);
        }
        ao46_mtl_gallium_poly_runtime_destroy(runtime);
    }
    return created;
}

static bool
ao46_mtl_gallium_dispatch_state_tracker_poly(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draws, unsigned num_draws)
{
    struct ao46_metal_poly_runtime *runtimes = NULL;
    struct ao46_metal_poly_pending *pending = NULL;
    unsigned queued = 0;
    bool completed = false;

    if (!mc || !draws || num_draws == 0 ||
        num_draws > AO46_METAL_MAX_INDIRECT_DRAWS) {
        return false;
    }
    runtimes = calloc(num_draws, sizeof(*runtimes));
    pending = calloc(num_draws, sizeof(*pending));
    if (!runtimes || !pending) {
        goto out;
    }

    for (; queued < num_draws; ++queued) {
        if (!ao46_mtl_gallium_poly_runtime_create(
                mc, info, &draws[queued], &runtimes[queued])) {
            goto out;
        }
        mc->poly_render_pipeline =
            &runtimes[queued].render_pipeline.metal_pipeline;
        mc->poly_tess_draw = runtimes[queued].draw;
        mc->poly_tess_sequence = runtimes[queued].sequence;
        if (!ao46_mtl_gallium_queue_poly_tessellation(
                mc, info, &draws[queued], &pending[queued])) {
            ++queued;
            goto out;
        }
        mc->poly_render_pipeline = NULL;
        mc->poly_tess_draw =
            (struct AO46MetalGalliumPolyTessellationDraw){0};
        mc->poly_tess_sequence =
            (struct AO46MetalGalliumPolyTessellationSequence){0};
    }
    completed = true;

out:
    mc->poly_render_pipeline = NULL;
    mc->poly_tess_draw = (struct AO46MetalGalliumPolyTessellationDraw){0};
    mc->poly_tess_sequence =
        (struct AO46MetalGalliumPolyTessellationSequence){0};
    for (unsigned i = 0; i < queued; ++i) {
        completed = ao46_mtl_gallium_finish_poly_pending(&pending[i]) &&
                    completed;
        ao46_mtl_gallium_poly_runtime_destroy(&runtimes[i]);
    }
    free(pending);
    free(runtimes);
    return completed;
}

static bool
ao46_mtl_gallium_dispatch_state_tracker_poly_indirect(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_indirect_info *indirect)
{
    const size_t argument_size = 4 * sizeof(uint32_t);
    struct ao46_metal_resource *arguments;
    struct ao46_metal_resource *count_resource = NULL;
    const uint8_t *argument_bytes;
    unsigned draw_count;
    size_t stride;

    if (!mc || !info || !indirect || info->index_size != 0 ||
        info->primitive_restart || !indirect->buffer ||
        indirect->buffer->target != PIPE_BUFFER || indirect->draw_count == 0 ||
        indirect->draw_count > AO46_METAL_MAX_INDIRECT_DRAWS ||
        indirect->offset % sizeof(uint32_t) != 0) {
        return false;
    }
    stride = indirect->stride ? indirect->stride : argument_size;
    if (stride < argument_size || stride % sizeof(uint32_t) != 0 ||
        indirect->draw_count - 1 >
            (SIZE_MAX - argument_size) / stride) {
        return false;
    }
    arguments = ao46_metal_resource(indirect->buffer);
    if (!arguments || !arguments->mtl_buffer ||
        !arguments->mtl_buffer.contents ||
        indirect->offset > indirect->buffer->width0 ||
        (size_t)(indirect->draw_count - 1) * stride + argument_size >
            indirect->buffer->width0 - indirect->offset) {
        return false;
    }

    /* Indirect parameters may have been produced by an earlier Gallium GPU
     * command. Finish that producer before reading unified-memory records. */
    ao46_metal_context_flush(&mc->base, NULL, PIPE_FLUSH_HINT_FINISH);
    draw_count = indirect->draw_count;
    if (indirect->indirect_draw_count) {
        if (indirect->indirect_draw_count->target != PIPE_BUFFER ||
            indirect->indirect_draw_count_offset % sizeof(uint32_t) != 0 ||
            indirect->indirect_draw_count_offset >
                indirect->indirect_draw_count->width0 ||
            sizeof(uint32_t) >
                indirect->indirect_draw_count->width0 -
                    indirect->indirect_draw_count_offset) {
            return false;
        }
        count_resource =
            ao46_metal_resource(indirect->indirect_draw_count);
        if (!count_resource || !count_resource->mtl_buffer ||
            !count_resource->mtl_buffer.contents) {
            return false;
        }
        memcpy(&draw_count,
               (const uint8_t *)count_resource->mtl_buffer.contents +
                   indirect->indirect_draw_count_offset,
               sizeof(draw_count));
        draw_count = MIN2(draw_count, indirect->draw_count);
    }

    argument_bytes =
        (const uint8_t *)arguments->mtl_buffer.contents + indirect->offset;
    for (unsigned i = 0; i < draw_count; ++i) {
        uint32_t command[4];
        struct pipe_draw_info resolved_info = *info;
        struct pipe_draw_start_count_bias resolved_draw = {0};

        memcpy(command, argument_bytes + (size_t)i * stride, sizeof(command));
        if (command[0] == 0 || command[1] == 0) {
            continue;
        }
        resolved_info.instance_count = command[1];
        resolved_info.start_instance = command[3];
        resolved_draw.start = command[2];
        resolved_draw.count = command[0];
        if (!ao46_mtl_gallium_dispatch_state_tracker_poly(
                mc, &resolved_info, &resolved_draw, 1)) {
            return false;
        }
    }
    return true;
}

static bool
ao46_mtl_gallium_queue_poly_tessellation(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draws,
    struct ao46_metal_poly_pending *pending)
{
    const struct AO46MetalGalliumPolyTessellationDraw *draw;
    const struct AO46MetalGalliumPolyTessellationSequence *sequence;
    const struct AO46MetalAdapter *adapter;
    const struct AO46MesaPolyKernelSource *prefix_source;
    struct AO46MetalBuffer package;
    struct AO46MetalBufferBinding vs_bindings[4 + PIPE_MAX_ATTRIBS];
    struct AO46MetalBuffer vertex_buffer_metal[PIPE_MAX_ATTRIBS] = {0};
    struct AO46MetalBufferBinding tcs_bindings[4];
    struct AO46MetalBufferBinding kernel_bindings[2];
    struct AO46MetalBufferBinding vertex_static_binding;
    struct AO46MetalIndexBufferBinding index_binding;
    struct AO46MetalIndirectDrawBinding indirect_binding;
    struct AO46MetalTexture color_target;
    struct ao46_metal_resource *color_resource;
    enum AO46MesaPolyKernel tessellation_kernel;
    enum AO46MetalPrimitive output_primitive;
    uint32_t minimum_indices;
    size_t vs_binding_count = 0;

    if (!mc || !info || !draws || !pending || pending->compute_count != 0 ||
        pending->render_submitted ||
        info->mode != MESA_PRIM_PATCHES || info->index_size != 0 ||
        info->instance_count == 0 || info->primitive_restart ||
        draws[0].index_bias != 0 || draws[0].count == 0 ||
        !mc->tcs_shader || !mc->tes_shader || !mc->tess_state_set ||
        !mc->poly_render_pipeline || mc->fb_state.nr_cbufs != 1 ||
        !mc->fb_state.cbufs[0].texture) {
        return false;
    }

    draw = &mc->poly_tess_draw;
    sequence = &mc->poly_tess_sequence;
    if (!draw->parameter_resource || !draw->index_resource ||
        !draw->indirect_resource || !sequence->tcs_pipeline ||
        !sequence->kernel_executor || !sequence->plan ||
        !sequence->tcs_pipeline->metal_pipeline.native_pipeline ||
        !mc->poly_render_pipeline->native_pipeline ||
        mc->patch_vertices != draw->input_patch_size ||
        draws[0].count != draw->input_vertex_count ||
        draw->input_vertex_count % draw->input_patch_size != 0 ||
        sequence->plan->parameter_buffer_binding != 3 ||
        sequence->plan->parameter_bytes > draw->parameter_size ||
        sequence->plan->input_patch_size != draw->input_patch_size ||
        sequence->plan->nr_patches !=
            (draw->input_vertex_count / draw->input_patch_size) *
                info->instance_count ||
        !sequence->plan->requires_prefix_sum ||
        !sequence->plan->requires_dynamic_index_heap ||
        !AO46MesaPolyTessellationPlanMatchesTCS(sequence->plan,
                                                mc->tcs_shader->nir) ||
        !AO46MesaPolyTessellationPlanMatchesTES(sequence->plan,
                                                mc->tes_shader->nir) ||
        !ao46_mtl_gallium_poly_topology(sequence->plan, &tessellation_kernel,
                                        &output_primitive, &minimum_indices) ||
        draw->maximum_index_count < minimum_indices ||
        !ao46_mtl_gallium_range(draw->parameter_resource,
                                draw->parameter_offset, draw->parameter_size) ||
        !ao46_mtl_gallium_range(draw->parameter_resource,
                                sequence->count_root_offset,
                                sequence->root_size) ||
        !ao46_mtl_gallium_range(draw->parameter_resource,
                                sequence->root_offset, sequence->root_size) ||
        !ao46_mtl_gallium_range(draw->parameter_resource,
                                sequence->sampler_table_offset,
                                sequence->sampler_table_size) ||
        (sequence->vs_pipeline &&
         (!sequence->vs_pipeline->metal_pipeline.native_pipeline ||
          sequence->vertex_parameter_size <
              sizeof(struct poly_vertex_params) ||
          !ao46_mtl_gallium_range(draw->parameter_resource,
                                  sequence->vertex_parameter_offset,
                                  sequence->vertex_parameter_size) ||
          (sequence->vertex_buffer_mask &&
           (!sequence->vertex_input_root_size ||
            !ao46_mtl_gallium_range(draw->parameter_resource,
                                    sequence->vertex_input_root_offset,
                                    sequence->vertex_input_root_size))))) ||
        !ao46_mtl_gallium_range(draw->index_resource, draw->index_offset,
                                draw->index_size) ||
        !ao46_mtl_gallium_range(draw->indirect_resource,
                                draw->indirect_offset, draw->indirect_size)) {
        return false;
    }

    adapter = sequence->tcs_pipeline->metal_pipeline.adapter;
    if (!adapter || sequence->kernel_executor->adapter != adapter ||
        (sequence->vs_pipeline &&
         sequence->vs_pipeline->metal_pipeline.adapter != adapter) ||
        mc->poly_render_pipeline->adapter != adapter ||
        !ao46_mtl_gallium_buffer_for_adapter(draw->parameter_resource,
                                             adapter, &package) ||
        draw->index_resource != draw->parameter_resource ||
        draw->indirect_resource != draw->parameter_resource) {
        return false;
    }

    prefix_source = &sequence->kernel_executor->sources[
        AO46_MESA_POLY_KERNEL_PREFIX_SUM];
    if (!prefix_source->workgroup_size[0] ||
        !prefix_source->workgroup_size[1] ||
        !prefix_source->workgroup_size[2]) {
        return false;
    }

    /* Keep ordinary Gallium commands ordered before the external poly chain. */
    ao46_metal_context_flush(&mc->base, NULL, PIPE_FLUSH_HINT_FINISH);

    if (sequence->vs_pipeline) {
        vs_bindings[vs_binding_count++] = (struct AO46MetalBufferBinding){
            .buffer = &package,
            .offset = sequence->root_offset,
            .size = sequence->root_size,
            .index = 0,
            .writable = true,
        };
        vs_bindings[vs_binding_count++] = (struct AO46MetalBufferBinding){
            .buffer = &package,
            .offset = sequence->sampler_table_offset,
            .size = sequence->sampler_table_size,
            .index = 1,
            .writable = true,
        };
        vs_bindings[vs_binding_count++] = (struct AO46MetalBufferBinding){
            .buffer = &package,
            .offset = sequence->vertex_parameter_offset,
            .size = sequence->vertex_parameter_size,
            .index = 2,
            .writable = true,
        };
        if (sequence->vertex_buffer_mask) {
            vs_bindings[vs_binding_count++] =
                (struct AO46MetalBufferBinding){
                    .buffer = &package,
                    .offset = sequence->vertex_input_root_offset,
                    .size = sequence->vertex_input_root_size,
                    .index = 4,
                };
        }
        for (unsigned i = 0; i < PIPE_MAX_ATTRIBS; ++i) {
            const struct pipe_vertex_buffer *binding;
            struct pipe_resource *resource;

            if (!(sequence->vertex_buffer_mask & (UINT32_C(1) << i))) {
                continue;
            }
            if (i >= mc->num_vertex_buffers) {
                return false;
            }
            binding = &mc->vertex_buffers[i];
            resource = binding->buffer.resource;
            if (binding->is_user_buffer || !resource ||
                binding->buffer_offset >= resource->width0 ||
                !ao46_mtl_gallium_buffer_for_adapter(
                    resource, adapter, &vertex_buffer_metal[i])) {
                return false;
            }
            vs_bindings[vs_binding_count++] =
                (struct AO46MetalBufferBinding){
                    .buffer = &vertex_buffer_metal[i],
                    .offset = binding->buffer_offset,
                    .size = resource->width0 - binding->buffer_offset,
                    /* The shader dereferences the GPU address from root 4.
                     * This slot only retains the resource for the command. */
                    .index = 15,
                };
        }
        if (!ao46_mtl_gallium_queue_compute(
                &sequence->vs_pipeline->metal_pipeline, vs_bindings,
                vs_binding_count,
                sequence->plan->vertex_grid_width,
                sequence->plan->vertex_grid_height, 1,
                sequence->vs_pipeline->reflection.local_size[0],
                sequence->vs_pipeline->reflection.local_size[1],
                sequence->vs_pipeline->reflection.local_size[2],
                &pending->compute[pending->compute_count])) {
            goto out;
        }
        ++pending->compute_count;
    }

    tcs_bindings[0] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = sequence->root_offset,
        .size = sequence->root_size,
        .index = 0,
        .writable = true,
    };
    tcs_bindings[1] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = sequence->sampler_table_offset,
        .size = sequence->sampler_table_size,
        .index = 1,
        .writable = true,
    };
    tcs_bindings[2] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = draw->parameter_offset,
        .size = draw->parameter_size,
        .index = 3,
        .writable = true,
    };
    tcs_bindings[3] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = sequence->vertex_parameter_offset,
        .size = sequence->vertex_parameter_size,
        .index = 2,
        .writable = false,
    };
    if (!ao46_mtl_gallium_queue_compute(
            &sequence->tcs_pipeline->metal_pipeline, tcs_bindings,
            sequence->vs_pipeline ? 4 : 3,
            sequence->plan->tcs_grid_width,
            sequence->plan->vertex_grid_height, 1,
            sequence->tcs_pipeline->reflection.local_size[0],
            sequence->tcs_pipeline->reflection.local_size[1],
            sequence->tcs_pipeline->reflection.local_size[2],
            &pending->compute[pending->compute_count])) {
        goto out;
    }
    ++pending->compute_count;

    kernel_bindings[0] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = sequence->count_root_offset,
        .size = sequence->root_size,
        .index = 0,
        .writable = true,
    };
    kernel_bindings[1] = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = sequence->sampler_table_offset,
        .size = sequence->sampler_table_size,
        .index = 1,
        .writable = true,
    };
    if (!ao46_mtl_gallium_queue_compute(
            &sequence->kernel_executor->pipelines[tessellation_kernel],
            kernel_bindings, 2, sequence->plan->tess_grid_width, 1, 1,
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[0],
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[1],
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[2],
            &pending->compute[pending->compute_count])) {
        goto out;
    }
    ++pending->compute_count;

    kernel_bindings[0].offset = sequence->root_offset;
    if (!ao46_mtl_gallium_queue_compute(
            &sequence->kernel_executor
                 ->pipelines[AO46_MESA_POLY_KERNEL_PREFIX_SUM],
            kernel_bindings, 2, prefix_source->workgroup_size[0], 1, 1,
            prefix_source->workgroup_size[0], prefix_source->workgroup_size[1],
            prefix_source->workgroup_size[2],
            &pending->compute[pending->compute_count])) {
        goto out;
    }
    ++pending->compute_count;
    if (!ao46_mtl_gallium_queue_compute(
            &sequence->kernel_executor->pipelines[tessellation_kernel],
            kernel_bindings, 2, sequence->plan->tess_grid_width, 1, 1,
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[0],
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[1],
            sequence->kernel_executor->sources[tessellation_kernel]
                .workgroup_size[2],
            &pending->compute[pending->compute_count])) {
        goto out;
    }
    ++pending->compute_count;

    color_resource = ao46_metal_resource(mc->fb_state.cbufs[0].texture);
    if (!color_resource || !color_resource->mtl_texture ||
        color_resource->mtl_texture.device !=
            (__bridge id<MTLDevice>)adapter->device ||
        (mc->fb_state.cbufs[0].format != PIPE_FORMAT_R8G8B8A8_UNORM &&
         mc->fb_state.cbufs[0].format != PIPE_FORMAT_B8G8R8A8_UNORM)) {
        goto out;
    }
    color_target = (struct AO46MetalTexture){
        .adapter = adapter,
        .native_texture = (__bridge void *)color_resource->mtl_texture,
        .width = mc->fb_state.width,
        .height = mc->fb_state.height,
        .format = mc->fb_state.cbufs[0].format == PIPE_FORMAT_B8G8R8A8_UNORM
                      ? AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM
                      : AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM,
    };
    index_binding = (struct AO46MetalIndexBufferBinding){
        .buffer = &package,
        .offset = draw->index_offset,
        .size = draw->index_size,
        .count = draw->maximum_index_count,
        .format = AO46_METAL_INDEX_FORMAT_UINT32,
    };
    indirect_binding = (struct AO46MetalIndirectDrawBinding){
        .buffer = &package,
        .offset = draw->indirect_offset,
        .draw_count = 1,
        .gpu_generated = true,
        .maximum_index_count = draw->maximum_index_count,
    };
    vertex_static_binding = (struct AO46MetalBufferBinding){
        .buffer = &package,
        .offset = draw->parameter_offset,
        .size = draw->parameter_size,
        .index = 3,
    };

    if (!AO46MetalRenderSubmitWithStaticVertexBuffers(
            adapter, mc->poly_render_pipeline, &color_target, NULL, 0,
            &index_binding, &indirect_binding, NULL, 0, NULL, 0, NULL, 0,
            &vertex_static_binding, 1, NULL, 0, output_primitive, 0, 0, 0, 0,
            &pending->render)) {
        goto out;
    }
    pending->render_submitted = true;
    return true;

out:
    (void)ao46_mtl_gallium_finish_poly_pending(pending);
    return false;
}

static bool
ao46_mtl_gallium_dispatch_poly_tessellation(
    struct ao46_metal_context *mc, const struct pipe_draw_info *info,
    const struct pipe_draw_start_count_bias *draws, unsigned num_draws)
{
    struct ao46_metal_poly_pending pending = {0};

    if (num_draws != 1 ||
        !ao46_mtl_gallium_queue_poly_tessellation(
            mc, info, draws, &pending)) {
        return false;
    }
    return ao46_mtl_gallium_finish_poly_pending(&pending);
}

/* ----------------------------------------------------------------------
 * Draw call
 * ---------------------------------------------------------------------- */
static void
ao46_metal_draw_vbo(struct pipe_context *ctx,
                    const struct pipe_draw_info *info,
                    unsigned drawid_offset,
                    const struct pipe_draw_indirect_info *indirect,
                    const struct pipe_draw_start_count_bias *draws,
                    unsigned num_draws)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    bool needs_emulation;
    bool trace_runtime = getenv("AO46_TRACE_RUNTIME") != NULL;
    struct ao46_metal_resource *indirect_mr = NULL;
    struct ao46_metal_resource *indirect_count_mr = NULL;
    NSUInteger indirect_offset = 0;
    NSUInteger indirect_stride = 0;
    unsigned indirect_draw_count = 0;
    struct pipe_draw_start_count_bias stream_output_draw = {0};
    id<MTLIndirectCommandBuffer> indirect_commands = nil;
    id<MTLBuffer> indirect_execution_range = nil;
    id<MTLRenderPipelineState> ps = nil;

    if (trace_runtime) {
        fprintf(stderr,
                "[AO46Metal] draw_vbo entry mode=%d indirect=%d draws=%u "
                "start=%u count=%u\n",
                info ? (int)info->mode : -1, indirect != NULL, num_draws,
                draws && num_draws ? draws[0].start : 0,
                draws && num_draws ? draws[0].count : 0);
    }

    if (!mc || !info || info->has_user_indices ||
        (!indirect && (!draws || num_draws == 0))) {
        return;
    }

    if (info->mode == MESA_PRIM_PATCHES) {
        const bool has_explicit_poly_package =
            mc->poly_render_pipeline ||
            mc->poly_tess_draw.parameter_resource ||
            mc->poly_tess_draw.index_resource ||
            mc->poly_tess_draw.indirect_resource ||
            mc->poly_tess_sequence.tcs_pipeline ||
            mc->poly_tess_sequence.kernel_executor ||
            mc->poly_tess_sequence.plan;
        const bool submitted = indirect
            ? (!has_explicit_poly_package &&
               ao46_mtl_gallium_dispatch_state_tracker_poly_indirect(
                   mc, info, indirect))
            : (has_explicit_poly_package
                   ? ao46_mtl_gallium_dispatch_poly_tessellation(
                         mc, info, draws, num_draws)
                   : ao46_mtl_gallium_dispatch_state_tracker_poly(
                         mc, info, draws, num_draws));

        if (!submitted) {
            return;
        }
        return;
    }

    if (indirect && indirect->count_from_stream_output) {
        struct ao46_metal_stream_output_target *target =
            (struct ao46_metal_stream_output_target *)
                indirect->count_from_stream_output;

        if (indirect->buffer || indirect->indirect_draw_count ||
            info->index_size || info->primitive_restart || !target ||
            target->base.context != ctx || target->vertex_stride == 0 ||
            target->write_offset % target->vertex_stride != 0) {
            return;
        }
        stream_output_draw.count =
            target->write_offset / target->vertex_stride;
        draws = &stream_output_draw;
        num_draws = 1;
        indirect = NULL;
    }

    needs_emulation = ao46_metal_primitive_needs_emulation(info);
    if (mc->num_stream_output_targets > 0 && mc->vs_shader &&
        mc->vs_shader->stream_output.num_outputs > 0 &&
        (indirect || info->index_size || needs_emulation)) {
        return;
    }
    if (indirect) {
        const size_t argument_size = info->index_size ? 5 * sizeof(uint32_t)
                                                       : 4 * sizeof(uint32_t);
        size_t required_size;

        if (!indirect->buffer || indirect->offset % sizeof(uint32_t) != 0 ||
            indirect->draw_count == 0 ||
            indirect->draw_count > AO46_METAL_MAX_INDIRECT_DRAWS ||
            info->primitive_restart || needs_emulation ||
            (info->index_size != 0 && info->index_size != 2 &&
             info->index_size != 4)) {
            return;
        }

        indirect_stride = indirect->stride ? indirect->stride : argument_size;
        if (indirect_stride < argument_size ||
            indirect_stride % sizeof(uint32_t) != 0 ||
            indirect->draw_count - 1 >
                (SIZE_MAX - argument_size) / indirect_stride) {
            return;
        }

        required_size = (size_t)(indirect->draw_count - 1) * indirect_stride +
                        argument_size;
        indirect_mr = ao46_metal_resource(indirect->buffer);
        if (!indirect_mr || !indirect_mr->mtl_buffer ||
            indirect->offset > indirect_mr->base.width0 ||
            required_size > indirect_mr->base.width0 - indirect->offset) {
            return;
        }

        indirect_offset = indirect->offset;
        indirect_draw_count = indirect->draw_count;

        if (indirect->indirect_draw_count) {
            if (indirect->indirect_draw_count->target != PIPE_BUFFER ||
                indirect->indirect_draw_count_offset % sizeof(uint32_t) != 0 ||
                indirect->indirect_draw_count_offset >
                    indirect->indirect_draw_count->width0 ||
                sizeof(uint32_t) > indirect->indirect_draw_count->width0 -
                                       indirect->indirect_draw_count_offset) {
                return;
            }
            indirect_count_mr =
                ao46_metal_resource(indirect->indirect_draw_count);
            if (!indirect_count_mr || !indirect_count_mr->mtl_buffer) {
                return;
            }
        }
    }

    /* Metal ICB buffer inheritance cannot vary Mesa's draw-parameter root
     * per command on this path. Resolve only the count for these shaders,
     * then use the ordinary indirect records, which bind each draw exactly. */
    if (indirect_count_mr && mc->vs_shader &&
        mc->vs_shader->uses_draw_parameters) {
        uint32_t selected_count = 0;

        ao46_metal_context_flush(ctx, NULL, PIPE_FLUSH_HINT_FINISH);
        if (!indirect_count_mr->mtl_buffer.contents) {
            return;
        }
        memcpy(&selected_count,
               (const uint8_t *)indirect_count_mr->mtl_buffer.contents +
                   indirect->indirect_draw_count_offset,
               sizeof(selected_count));
        indirect_draw_count = MIN2(indirect_draw_count, selected_count);
        indirect_count_mr = NULL;
        if (indirect_draw_count == 0) {
            return;
        }
    }

    if (mc->compute_encoder) {
        [mc->compute_encoder endEncoding];
        mc->compute_encoder = nil;
    }
    if (indirect_count_mr && mc->render_encoder) {
        [mc->render_encoder endEncoding];
        mc->render_encoder = nil;
        mc->render_pass_started = false;
    }

    ps = ao46_metal_get_pipeline_state(mc, info->mode,
                                       indirect_count_mr != NULL);
    if (!ps) {
        if (trace_runtime) {
            fprintf(stderr,
                    "[AO46Metal] draw dropped: missing pipeline state mode=%d indexed=%u count=%u\n",
                    (int)info->mode,
                    info->index_size != 0,
                    indirect ? indirect_draw_count : draws[0].count);
        }
        return;
    }

    if (!mc->render_encoder) {
        id<MTLTexture> color_textures[PIPE_MAX_COLOR_BUFS] = { nil };
        id<MTLTexture> resolve_textures[PIPE_MAX_COLOR_BUFS] = { nil };
        id<MTLTexture> depth_texture = nil;
        if (!mc->cmd_buffer) {
            if (!ao46_metal_context_begin_submission(mc)) return;
        }

        if (indirect_count_mr) {
            MTLIndirectCommandBufferDescriptor *descriptor =
                [[MTLIndirectCommandBufferDescriptor alloc] init];
            id<MTLComputePipelineState> count_pipeline =
                (__bridge id<MTLComputePipelineState>)
                    g_mtl_adapter.indirect_count_range_pipeline;
            const uint8_t *argument_bytes =
                (const uint8_t *)indirect_mr->mtl_buffer.contents +
                indirect_offset;

            descriptor.commandTypes = info->index_size
                                          ? MTLIndirectCommandTypeDrawIndexed
                                          : MTLIndirectCommandTypeDraw;
            descriptor.inheritPipelineState = YES;
            descriptor.inheritBuffers = YES;
            indirect_commands =
                [g_mtl_device newIndirectCommandBufferWithDescriptor:descriptor
                                                      maxCommandCount:
                                                          indirect_draw_count
                                                               options:0];
            indirect_execution_range =
                [g_mtl_device newBufferWithLength:
                                  sizeof(MTLIndirectCommandBufferExecutionRange)
                                            options:MTLResourceStorageModeShared];
            [descriptor release];
            if (!indirect_commands || !indirect_execution_range ||
                !count_pipeline || !argument_bytes) {
                [indirect_commands release];
                [indirect_execution_range release];
                return;
            }

            for (unsigned i = 0; i < indirect_draw_count; ++i) {
                id<MTLIndirectRenderCommand> command =
                    [indirect_commands indirectRenderCommandAtIndex:i];
                const uint8_t *record = argument_bytes + i * indirect_stride;

                if (info->index_size) {
                    struct ao46_metal_draw_indexed_indirect_arguments args;
                    struct ao46_metal_resource *index_mr =
                        info->index.resource
                            ? ao46_metal_resource(info->index.resource)
                            : NULL;
                    const NSUInteger index_offset_limit =
                        info->index.resource ? info->index.resource->width0 : 0;
                    NSUInteger index_offset;

                    memcpy(&args, record, sizeof(args));
                    if (!index_mr || !index_mr->mtl_buffer ||
                        args.index_start >
                            index_offset_limit / info->index_size ||
                        args.index_count >
                            (index_offset_limit -
                             (NSUInteger)args.index_start * info->index_size) /
                                info->index_size) {
                        [indirect_commands release];
                        [indirect_execution_range release];
                        return;
                    }
                    index_offset = (NSUInteger)args.index_start * info->index_size;
                    [command drawIndexedPrimitives:
                                 ao46_metal_primitive_type(info->mode)
                                           indexCount:args.index_count
                                            indexType:info->index_size == 2
                                                          ? MTLIndexTypeUInt16
                                                          : MTLIndexTypeUInt32
                                         indexBuffer:index_mr->mtl_buffer
                                   indexBufferOffset:index_offset
                                       instanceCount:args.instance_count
                                         baseVertex:args.base_vertex
                                       baseInstance:args.base_instance];
                } else {
                    struct ao46_metal_draw_indirect_arguments args;

                    memcpy(&args, record, sizeof(args));
                    [command drawPrimitives:ao46_metal_primitive_type(info->mode)
                                vertexStart:args.vertex_start
                                vertexCount:args.vertex_count
                              instanceCount:args.instance_count
                               baseInstance:args.base_instance];
                }
            }

            id<MTLComputeCommandEncoder> count_encoder =
                [mc->cmd_buffer computeCommandEncoder];
            if (!count_encoder) {
                [indirect_commands release];
                [indirect_execution_range release];
                return;
            }
            [count_encoder setComputePipelineState:count_pipeline];
            [count_encoder setBuffer:indirect_count_mr->mtl_buffer
                               offset:indirect->indirect_draw_count_offset
                              atIndex:0];
            [count_encoder setBuffer:indirect_execution_range offset:0 atIndex:1];
            [count_encoder setBytes:&indirect_draw_count
                              length:sizeof(indirect_draw_count)
                             atIndex:2];
            [count_encoder dispatchThreads:MTLSizeMake(1, 1, 1)
                     threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [count_encoder endEncoding];
        }

        MTLRenderPassDescriptor *rpd = [[MTLRenderPassDescriptor alloc] init];
        for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
            struct pipe_surface *surf = &mc->fb_state.cbufs[i];
            if (!surf->texture) continue;
            color_textures[i] = ao46_metal_get_surface_texture(surf);
            resolve_textures[i] = ao46_metal_get_framebuffer_resolve_texture(mc, i, surf);
            if (color_textures[i]) {
                rpd.colorAttachments[i].texture = color_textures[i];
                rpd.colorAttachments[i].loadAction = MTLLoadActionLoad;
                if (resolve_textures[i] && color_textures[i].sampleCount > 1) {
                    rpd.colorAttachments[i].resolveTexture = resolve_textures[i];
                    rpd.colorAttachments[i].storeAction =
                        MTLStoreActionStoreAndMultisampleResolve;
                } else {
                    rpd.colorAttachments[i].storeAction = MTLStoreActionStore;
                }
                rpd.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 1);
            }
        }
        if (mc->fb_state.zsbuf.texture) {
            depth_texture = ao46_metal_get_surface_texture(&mc->fb_state.zsbuf);
            if (depth_texture) {
                rpd.depthAttachment.texture = depth_texture;
                rpd.depthAttachment.loadAction = MTLLoadActionLoad;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
                rpd.depthAttachment.clearDepth = 1.0;
                rpd.stencilAttachment.texture = depth_texture;
                rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
                rpd.stencilAttachment.storeAction = MTLStoreActionStore;
                rpd.stencilAttachment.clearStencil = 0;
            }
        }
        [mc->render_pass release];
        mc->render_pass = rpd;
        mc->render_encoder = [mc->cmd_buffer renderCommandEncoderWithDescriptor:rpd];
        for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
            [color_textures[i] release];
            [resolve_textures[i] release];
        }
        [depth_texture release];
        mc->render_pass_started = true;
    }

    id<MTLRenderCommandEncoder> enc = mc->render_encoder;
    if (!enc) {
        [indirect_commands release];
        [indirect_execution_range release];
        return;
    }

    if (trace_runtime) {
        fprintf(stderr,
                "[AO46Metal] draw mode=%d indexed=%u start=%u count=%u emulation=%d vbs=%u elems=%u vs=%p fs=%p\n",
                (int)info->mode,
                info->index_size != 0,
                indirect ? (unsigned)indirect_offset : draws[0].start,
                indirect ? indirect_draw_count : draws[0].count,
                needs_emulation,
                mc->num_vertex_buffers,
                mc->vertex_elements_state ? mc->vertex_elements_state->num_elements : 0,
                (void *)mc->vs_shader,
                (void *)mc->fs_shader);
        fprintf(stderr,
                "[AO46Metal]   viewport scale=(%f,%f,%f) translate=(%f,%f,%f) scissor=(%u,%u)-(%u,%u)\n",
                mc->viewport.scale[0],
                mc->viewport.scale[1],
                mc->viewport.scale[2],
                mc->viewport.translate[0],
                mc->viewport.translate[1],
                mc->viewport.translate[2],
                mc->scissor.minx,
                mc->scissor.miny,
                mc->scissor.maxx,
                mc->scissor.maxy);
        fprintf(stderr,
                "[AO46Metal]   raster discard=%d cull=%u front_ccw=%d fill=(%u,%u) blend_mask=%u\n",
                mc->raster ? mc->raster->base.rasterizer_discard : 0,
                mc->raster ? mc->raster->base.cull_face : PIPE_FACE_NONE,
                mc->raster ? mc->raster->base.front_ccw : 0,
                mc->raster ? mc->raster->base.fill_front : PIPE_POLYGON_MODE_FILL,
                mc->raster ? mc->raster->base.fill_back : PIPE_POLYGON_MODE_FILL,
                mc->blend ? mc->blend->base.rt[0].colormask : PIPE_MASK_RGBA);
        if (mc->vertex_elements_state) {
            for (unsigned i = 0; i < mc->vertex_elements_state->num_elements; i++) {
                const struct pipe_vertex_element *elem = &mc->vertex_elements_state->elements[i];
                fprintf(stderr,
                        "[AO46Metal]   attr%u vb=%u stride=%u src_offset=%u\n",
                        i,
                        elem->vertex_buffer_index,
                        elem->src_stride,
                        elem->src_offset);
            }
        }
        for (unsigned i = 0; i < mc->num_vertex_buffers && i < PIPE_MAX_ATTRIBS; i++) {
            struct pipe_vertex_buffer *vb = &mc->vertex_buffers[i];
            fprintf(stderr,
                    "[AO46Metal]   vb%u resource=%p user=%d offset=%u\n",
                    i,
                    (void *)vb->buffer.resource,
                    vb->is_user_buffer,
                    vb->buffer_offset);
        }
    }
    [enc setRenderPipelineState:ps];
    if (mc->dsa && mc->dsa->mtl_state) {
        [enc setDepthStencilState:mc->dsa->mtl_state];
    }
    [enc setBlendColorRed:mc->blend_color.color[0]
                    green:mc->blend_color.color[1]
                     blue:mc->blend_color.color[2]
                    alpha:mc->blend_color.color[3]];
    [enc setStencilFrontReferenceValue:mc->stencil_ref.ref_value[0]
                    backReferenceValue:mc->stencil_ref.ref_value[1]];
    [enc setFrontFacingWinding:ao46_metal_winding(mc->raster ? &mc->raster->base : NULL)];
    [enc setCullMode:ao46_metal_cull_mode(mc->raster ? mc->raster->base.cull_face : PIPE_FACE_NONE)];
    [enc setTriangleFillMode:ao46_metal_triangle_fill_mode(mc->raster ? &mc->raster->base : NULL)];

    if (mc->raster &&
        (mc->raster->base.offset_point ||
         mc->raster->base.offset_line ||
         mc->raster->base.offset_tri)) {
        [enc setDepthBias:mc->raster->base.offset_units
               slopeScale:mc->raster->base.offset_scale
                    clamp:mc->raster->base.offset_clamp];
    } else {
        [enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    }

    MTLViewport vp;
    vp.originX = mc->viewport.translate[0] - mc->viewport.scale[0];
    /*
     * Gallium's viewport state is expressed in surface coordinates, while
     * Metal's viewport transform is top-origin. Convert explicitly so Mesa's
     * default framebuffer Y flip is not applied a second time here.
     */
    vp.originY = mc->viewport.translate[1] + mc->viewport.scale[1];
    vp.width = mc->viewport.scale[0] * 2.0f;
    vp.height = mc->viewport.scale[1] * -2.0f;
    vp.znear = mc->viewport.translate[2] - mc->viewport.scale[2];
    vp.zfar = mc->viewport.translate[2] + mc->viewport.scale[2];
    [enc setViewport:vp];

    unsigned fb_width = mc->fb_state.width;
    unsigned fb_height = mc->fb_state.height;
    if ((!fb_width || !fb_height) && mc->fb_state.nr_cbufs > 0 &&
        mc->fb_state.cbufs[0].texture) {
        fb_width = mc->fb_state.cbufs[0].texture->width0;
        fb_height = mc->fb_state.cbufs[0].texture->height0;
    }

    MTLScissorRect scissor;
    if (mc->raster && mc->raster->base.scissor) {
        scissor.x = mc->scissor.minx;
        scissor.y = mc->scissor.miny;
        scissor.width = mc->scissor.maxx > mc->scissor.minx ?
            mc->scissor.maxx - mc->scissor.minx : fb_width;
        scissor.height = mc->scissor.maxy > mc->scissor.miny ?
            mc->scissor.maxy - mc->scissor.miny : fb_height;
    } else {
        scissor.x = 0;
        scissor.y = 0;
        scissor.width = fb_width;
        scissor.height = fb_height;
    }
    [enc setScissorRect:scissor];

    const mesa_shader_stage graphics_stages[] = {
        MESA_SHADER_VERTEX,
        MESA_SHADER_FRAGMENT,
    };

    for (unsigned stage_index = 0; stage_index < ARRAY_SIZE(graphics_stages); stage_index++) {
        mesa_shader_stage stage = graphics_stages[stage_index];
        if (!ao46_metal_prepare_image_bindings(mc, stage)) {
            [indirect_commands release];
            [indirect_execution_range release];
            return;
        }

        for (uint i = 0; i < mc->num_image_views[stage] &&
                         i < AO46_MAX_IMAGE_UNITS; ++i) {
            id<MTLTexture> texture = mc->image_binding_textures[stage][i];
            MTLResourceUsage usage = 0;

            if (!texture) {
                continue;
            }
            if (stage == MESA_SHADER_VERTEX) {
                [enc setVertexTexture:texture
                              atIndex:AO46_MESA_IMAGE_TEXTURE_BASE + i];
            } else {
                [enc setFragmentTexture:texture
                                atIndex:AO46_MESA_IMAGE_TEXTURE_BASE + i];
            }
            if (mc->image_views[stage][i].access & PIPE_IMAGE_ACCESS_READ) {
                usage |= MTLResourceUsageRead;
            }
            if (mc->image_views[stage][i].access & PIPE_IMAGE_ACCESS_WRITE) {
                usage |= MTLResourceUsageWrite;
            }
            if (usage) {
                if (@available(macOS 13.0, *)) {
                    [enc useResource:texture
                               usage:usage | MTLResourceUsageRead
                              stages:stage == MESA_SHADER_VERTEX
                                         ? MTLRenderStageVertex
                                         : MTLRenderStageFragment];
                }
            }
        }

        uint num_views = mc->num_sampler_views[stage];
        for (uint i = 0; i < num_views && i < AO46_MAX_SAMPLERS; i++) {
            struct pipe_sampler_view *view = mc->sampler_views[stage][i];
            id<MTLTexture> tex = ao46_metal_get_texture_from_view(view);
            if (tex) {
                if (stage == MESA_SHADER_VERTEX)
                    [enc setVertexTexture:tex atIndex:i];
                else
                    [enc setFragmentTexture:tex atIndex:i];
            }
        }

        uint num_samplers = mc->num_samplers[stage];
        for (uint i = 0; i < num_samplers && i < AO46_MAX_SAMPLERS; i++) {
            struct ao46_metal_sampler_state *sampler = mc->samplers[stage][i];
            id<MTLSamplerState> mtl_sampler = sampler ? sampler->mtl_sampler : nil;
            if (mtl_sampler) {
                if (stage == MESA_SHADER_VERTEX)
                    [enc setVertexSamplerState:mtl_sampler atIndex:i];
                else
                    [enc setFragmentSamplerState:mtl_sampler atIndex:i];
            }
        }

        for (uint i = 0; i < mc->num_shader_buffers[stage] &&
                         i < AO46_MAX_SHADER_BUFFERS; ++i) {
            struct ao46_metal_shader_buffer_binding *binding =
                &mc->shader_buffers[stage][i];
            struct ao46_metal_resource *mr =
                binding->buffer ? ao46_metal_resource(binding->buffer) : NULL;

            if (!mr || !mr->mtl_buffer ||
                binding->buffer_offset >= binding->buffer->width0) {
                continue;
            }
            if (stage == MESA_SHADER_VERTEX) {
                [enc setVertexBuffer:mr->mtl_buffer
                              offset:binding->buffer_offset
                             atIndex:AO46_BUFFER_SLOT_SHADER_BUFFER_BASE + i];
            } else {
                [enc setFragmentBuffer:mr->mtl_buffer
                                offset:binding->buffer_offset
                               atIndex:AO46_BUFFER_SLOT_SHADER_BUFFER_BASE + i];
            }
            if (@available(macOS 13.0, *)) {
                MTLResourceUsage usage = MTLResourceUsageRead;
                if (binding->writable) {
                    usage |= MTLResourceUsageWrite;
                }
                [enc useResource:mr->mtl_buffer
                           usage:usage
                          stages:stage == MESA_SHADER_VERTEX
                                     ? MTLRenderStageVertex
                                     : MTLRenderStageFragment];
            }
        }
    }

    if (!ao46_metal_bind_rgb32_address_table(
            mc, enc, MESA_SHADER_VERTEX) ||
        !ao46_metal_bind_rgb32_address_table(
            mc, enc, MESA_SHADER_FRAGMENT)) {
        [indirect_commands release];
        [indirect_execution_range release];
        return;
    }

    for (unsigned stage_index = 0; stage_index < ARRAY_SIZE(graphics_stages); stage_index++) {
        mesa_shader_stage stage = graphics_stages[stage_index];
        if (mc->const_buffer_mtl[stage] && mc->const_buffer_dirty[stage]) {
            if (stage == MESA_SHADER_VERTEX) {
                [enc setVertexBuffer:mc->const_buffer_mtl[stage]
                              offset:0
                             atIndex:AO46_BUFFER_SLOT_CONST0];
            } else if (stage == MESA_SHADER_FRAGMENT) {
                [enc setFragmentBuffer:mc->const_buffer_mtl[stage]
                                offset:0
                               atIndex:AO46_BUFFER_SLOT_CONST0];
            }
            mc->const_buffer_dirty[stage] = false;
        }
    }

    for (unsigned buffer_index = 0;
         buffer_index < mc->num_vertex_buffers && buffer_index < PIPE_MAX_ATTRIBS;
         buffer_index++) {
        struct pipe_vertex_buffer *vb = &mc->vertex_buffers[buffer_index];
        struct ao46_metal_resource *mr;

        if (vb->is_user_buffer || !vb->buffer.resource) {
            continue;
        }

        mr = ao46_metal_resource(vb->buffer.resource);
        if (!mr->mtl_buffer) {
            continue;
        }

        [enc setVertexBuffer:mr->mtl_buffer
                      offset:vb->buffer_offset
                     atIndex:AO46_BUFFER_SLOT_VERTEX_BASE + buffer_index];
    }

    if (mc->raster && mc->raster->base.cull_face == PIPE_FACE_FRONT_AND_BACK) {
        [indirect_commands release];
        [indirect_execution_range release];
        return;
    }

    MTLPrimitiveType prim_type = ao46_metal_primitive_type(info->mode);
    NSUInteger instance_count = MAX2(info->instance_count, 1u);

    if (indirect) {
        if (indirect_count_mr) {
            [enc executeCommandsInBuffer:indirect_commands
                          indirectBuffer:indirect_execution_range
                    indirectBufferOffset:0];
            [indirect_commands release];
            [indirect_execution_range release];
            return;
        }
        if (info->index_size) {
            struct ao46_metal_resource *index_mr =
                info->index.resource ? ao46_metal_resource(info->index.resource) : NULL;
            if (!index_mr || !index_mr->mtl_buffer) {
                return;
            }

            const MTLIndexType index_type = info->index_size == 2
                                                ? MTLIndexTypeUInt16
                                                : MTLIndexTypeUInt32;
            for (unsigned i = 0; i < indirect_draw_count; ++i) {
                struct ao46_metal_draw_indexed_indirect_arguments arguments;
                const uint8_t *record =
                    (const uint8_t *)indirect_mr->mtl_buffer.contents +
                    indirect_offset + i * indirect_stride;

                memcpy(&arguments, record, sizeof(arguments));
                ao46_metal_bind_draw_parameters(
                    enc, drawid_offset + i, arguments.index_count, 0,
                    arguments.base_instance, arguments.base_vertex);
                [enc drawIndexedPrimitives:prim_type
                                  indexType:index_type
                                indexBuffer:index_mr->mtl_buffer
                          indexBufferOffset:0
                            indirectBuffer:indirect_mr->mtl_buffer
                      indirectBufferOffset:indirect_offset + i * indirect_stride];
                ao46_metal_record_primitives(
                    mc, info->mode, arguments.index_count,
                    arguments.instance_count, false);
            }
        } else {
            for (unsigned i = 0; i < indirect_draw_count; ++i) {
                struct ao46_metal_draw_indirect_arguments arguments;
                const uint8_t *record =
                    (const uint8_t *)indirect_mr->mtl_buffer.contents +
                    indirect_offset + i * indirect_stride;

                memcpy(&arguments, record, sizeof(arguments));
                ao46_metal_bind_draw_parameters(
                    enc, drawid_offset + i, arguments.vertex_count,
                    arguments.vertex_start, arguments.base_instance, 0);
                [enc drawPrimitives:prim_type
                      indirectBuffer:indirect_mr->mtl_buffer
                indirectBufferOffset:indirect_offset + i * indirect_stride];
                ao46_metal_record_primitives(
                    mc, info->mode, arguments.vertex_count,
                    arguments.instance_count, false);
            }
        }
        return;
    }

    for (unsigned draw_index = 0; draw_index < num_draws; draw_index++) {
        const struct pipe_draw_start_count_bias *draw = &draws[draw_index];
        if (!draw->count) {
            continue;
        }

        ao46_metal_bind_draw_parameters(
            enc, drawid_offset + draw_index, draw->count,
            info->index_size ? 0 : draw->start, info->start_instance,
            info->index_size ? draw->index_bias : 0);
        if (!ao46_metal_bind_stream_output(
                mc, enc, draw->count, (uint32_t)instance_count)) {
            continue;
        }

        if (needs_emulation) {
            id<MTLBuffer> emulated_indices = nil;
            NSUInteger emulated_count = 0;
            MTLPrimitiveType emulated_type = MTLPrimitiveTypeTriangle;
            NSInteger emulated_base_vertex = 0;

            if (!ao46_metal_build_emulated_index_buffer(ctx,
                                                        info,
                                                        draw,
                                                        &emulated_indices,
                                                        &emulated_count,
                                                        &emulated_type,
                                                        &emulated_base_vertex)) {
                continue;
            }

            if (emulated_count > 0 && emulated_indices) {
                [enc drawIndexedPrimitives:emulated_type
                                indexCount:emulated_count
                                 indexType:MTLIndexTypeUInt32
                               indexBuffer:emulated_indices
                         indexBufferOffset:0
                             instanceCount:instance_count
                                baseVertex:emulated_base_vertex
                              baseInstance:info->start_instance];
                ao46_metal_record_primitives(
                    mc, info->mode, draw->count, (uint32_t)instance_count,
                    mc->num_stream_output_targets > 0 && mc->vs_shader &&
                        mc->vs_shader->stream_output.num_outputs > 0);
            }

            [emulated_indices release];
            continue;
        }

        if (info->index_size) {
            if (info->index_size != 2 && info->index_size != 4) {
                continue;
            }

            struct pipe_resource *idx_res = info->index.resource;
            if (!idx_res) {
                continue;
            }

            struct ao46_metal_resource *idx_mr = ao46_metal_resource(idx_res);
            if (!idx_mr || !idx_mr->mtl_buffer) {
                continue;
            }

            MTLIndexType idx_type =
                info->index_size == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
            NSUInteger index_buffer_offset = (NSUInteger)draw->start * info->index_size;
            [enc drawIndexedPrimitives:prim_type
                            indexCount:draw->count
                             indexType:idx_type
                           indexBuffer:idx_mr->mtl_buffer
                     indexBufferOffset:index_buffer_offset
                         instanceCount:instance_count
                            baseVertex:draw->index_bias
                          baseInstance:info->start_instance];
        } else {
            [enc drawPrimitives:prim_type
                    vertexStart:draw->start
                    vertexCount:draw->count
                  instanceCount:instance_count
                   baseInstance:info->start_instance];
        }
        ao46_metal_record_primitives(
            mc, info->mode, draw->count, (uint32_t)instance_count,
            mc->num_stream_output_targets > 0 && mc->vs_shader &&
                mc->vs_shader->stream_output.num_outputs > 0);
        ao46_metal_advance_stream_output(
            mc, draw->count, (uint32_t)instance_count);
    }
}

/* ----------------------------------------------------------------------
 * Context flush and finish
 * ---------------------------------------------------------------------- */
static void
ao46_metal_context_flush(struct pipe_context *ctx,
                         struct pipe_fence_handle **fence,
                         unsigned flags)
{
    (void)fence;
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    if (mc->compute_encoder) {
        [mc->compute_encoder endEncoding];
        mc->compute_encoder = nil;
    }
    if (mc->render_encoder) {
        [mc->render_encoder endEncoding];
        mc->render_encoder = nil;
        mc->render_pass_started = false;
    }
    if (mc->submission.native_command_buffer) {
        const bool wait = (flags & PIPE_FLUSH_HINT_FINISH) &&
                          !(flags & PIPE_FLUSH_ASYNC);
        const bool committed =
            AO46MetalSubmissionCommit(&mc->submission, wait);
        if (!committed && !mc->submission.uses_mtl4) {
            id<MTLCommandBuffer> failed_buffer =
                (__bridge id<MTLCommandBuffer>)mc->submission.native_command_buffer;
            fprintf(stderr,
                    "AO46 Metal: command submission failed (status=%ld, error=%s)\n",
                    (long)failed_buffer.status,
                    failed_buffer.error.localizedDescription.UTF8String ?: "unknown");
        }
        AO46MetalSubmissionDestroy(&mc->submission);
        mc->cmd_buffer = nil;
    } else if (mc->cmd_buffer) {
        [mc->cmd_buffer commit];
        if ((flags & PIPE_FLUSH_HINT_FINISH) && !(flags & PIPE_FLUSH_ASYNC)) {
            [mc->cmd_buffer waitUntilCompleted];
        }
        mc->cmd_buffer = nil;
    }
    [mc->render_pass release];
    mc->render_pass = nil;
}

static void
ao46_metal_context_destroy(struct pipe_context *ctx)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    [mc->compute_encoder release];
    [mc->render_encoder release];
    if (mc->submission.native_command_buffer) {
        AO46MetalSubmissionDestroy(&mc->submission);
    } else {
        [mc->cmd_buffer release];
    }
    [mc->render_pass release];
    [mc->pipeline_state release];
    mc->compute_encoder = nil;
    mc->render_encoder = nil;
    mc->cmd_buffer = nil;
    mc->render_pass = nil;
    mc->pipeline_state = nil;
    for (int i = 0; i < MESA_SHADER_STAGES; i++) {
        [mc->const_buffer_mtl[i] release];
        mc->const_buffer_mtl[i] = nil;
        [mc->rgb32_address_tables[i] release];
        mc->rgb32_address_tables[i] = nil;
        for (unsigned j = 0; j < AO46_MAX_SHADER_BUFFERS; j++) {
            pipe_resource_reference(&mc->shader_buffers[i][j].buffer, NULL);
        }
        for (unsigned j = 0; j < AO46_MAX_IMAGE_UNITS; j++) {
            [mc->image_binding_textures[i][j] release];
            mc->image_binding_textures[i][j] = nil;
            pipe_resource_reference(&mc->image_views[i][j].resource, NULL);
        }
        for (unsigned j = 0; j < AO46_MAX_SAMPLERS; j++) {
            pipe_sampler_view_reference(&mc->sampler_views[i][j], NULL);
        }
    }
    for (unsigned i = 0; i < PIPE_MAX_SO_BUFFERS; i++) {
        pipe_so_target_reference(&mc->stream_output_targets[i], NULL);
    }
    pipe_resource_reference(&mc->poly_tess_draw.parameter_resource, NULL);
    pipe_resource_reference(&mc->poly_tess_draw.index_resource, NULL);
    pipe_resource_reference(&mc->poly_tess_draw.indirect_resource, NULL);
    if (mc->base.const_uploader &&
        mc->base.const_uploader != mc->base.stream_uploader) {
        u_upload_destroy(mc->base.const_uploader);
    }
    if (mc->base.stream_uploader) {
        u_upload_destroy(mc->base.stream_uploader);
    }
    util_unreference_framebuffer_state(&mc->fb_state);
    FREE(mc);
}

/* ======================================================================
 * Screen context creation
 * ====================================================================== */
static struct pipe_context *
ao46_metal_screen_context_create(struct pipe_screen *screen,
                                 void *priv,
                                 unsigned flags)
{
    if (!ao46_metal_init()) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr, "[AO46Metal] pipe_context creation failed: Metal initialization\n");
        }
        return NULL;
    }

    struct ao46_metal_context *mc = CALLOC_STRUCT(ao46_metal_context);
    if (!mc) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr, "[AO46Metal] pipe_context creation failed: context allocation\n");
        }
        return NULL;
    }

    mc->base.screen = screen;
    mc->base.priv = priv;
    mc->sample_mask = UINT32_MAX;
    mc->active_query_state = true;
    mc->base.stream_uploader = u_upload_create_default(&mc->base);
    if (!mc->base.stream_uploader) {
        if (getenv("AO46_TRACE_RUNTIME")) {
            fprintf(stderr, "[AO46Metal] pipe_context creation failed: stream uploader\n");
        }
        FREE(mc);
        return NULL;
    }
    mc->base.const_uploader = mc->base.stream_uploader;
    mc->base.destroy = ao46_metal_context_destroy;
    mc->base.flush = ao46_metal_context_flush;
    mc->base.draw_vbo = ao46_metal_draw_vbo;
    mc->base.resource_copy_region = ao46_metal_resource_copy_region;
    mc->base.resource_release = u_default_resource_release;
    mc->base.blit = ao46_metal_blit;
    mc->base.generate_mipmap = ao46_metal_generate_mipmap;
    mc->base.clear = ao46_metal_clear;
    mc->base.clear_render_target = ao46_metal_clear_render_target;
    mc->base.clear_depth_stencil = ao46_metal_clear_depth_stencil;
    mc->base.clear_texture = ao46_metal_clear_texture;
    mc->base.clear_buffer = ao46_metal_clear_buffer;
    mc->base.set_framebuffer_state = ao46_metal_set_framebuffer_state;
    mc->base.set_vertex_buffers = ao46_metal_set_vertex_buffers;
    mc->base.set_viewport_states = ao46_metal_set_viewport_states;
    mc->base.set_scissor_states = ao46_metal_set_scissor_states;
    mc->base.set_window_rectangles = ao46_metal_set_window_rectangles;
    mc->base.set_clip_state = ao46_metal_set_clip_state;
    mc->base.set_polygon_stipple = ao46_metal_set_polygon_stipple;
    mc->base.set_sample_mask = ao46_metal_set_sample_mask;
    mc->base.set_min_samples = ao46_metal_set_min_samples;
    mc->base.set_constant_buffer = ao46_metal_set_constant_buffer;
    mc->base.set_shader_buffers = ao46_metal_set_shader_buffers;
    mc->base.set_shader_images = ao46_metal_set_shader_images;
    mc->base.create_stream_output_target = ao46_metal_create_stream_output_target;
    mc->base.stream_output_target_destroy = ao46_metal_stream_output_target_destroy;
    mc->base.set_stream_output_targets = ao46_metal_set_stream_output_targets;
    mc->base.stream_output_target_offset = ao46_metal_stream_output_target_offset;
    mc->base.create_query = ao46_metal_create_query;
    mc->base.destroy_query = ao46_metal_destroy_query;
    mc->base.begin_query = ao46_metal_begin_query;
    mc->base.end_query = ao46_metal_end_query;
    mc->base.get_query_result = ao46_metal_get_query_result;
    mc->base.set_active_query_state = ao46_metal_set_active_query_state;
    mc->base.memory_barrier = ao46_metal_memory_barrier;
    mc->base.texture_barrier = ao46_metal_texture_barrier;
    mc->base.buffer_map = ao46_metal_buffer_map;
    mc->base.transfer_flush_region = ao46_metal_transfer_flush_region;
    mc->base.buffer_unmap = ao46_metal_buffer_unmap;
    mc->base.texture_map = ao46_metal_texture_map;
    mc->base.texture_unmap = ao46_metal_texture_unmap;
    mc->base.buffer_subdata = ao46_metal_buffer_subdata;
    mc->base.texture_subdata = ao46_metal_texture_subdata;
    mc->base.set_sampler_views = ao46_metal_set_sampler_views;
    mc->base.create_sampler_view = ao46_metal_create_sampler_view;
    mc->base.sampler_view_destroy = ao46_metal_sampler_view_destroy;
    mc->base.sampler_view_release = ao46_metal_sampler_view_release;
    mc->base.create_blend_state = ao46_metal_create_blend_state;
    mc->base.bind_blend_state = ao46_metal_bind_blend_state;
    mc->base.delete_blend_state = ao46_metal_delete_blend_state;
    mc->base.set_blend_color = ao46_metal_set_blend_color;
    mc->base.create_sampler_state = ao46_metal_create_sampler_state;
    mc->base.bind_sampler_states = ao46_metal_bind_sampler_states;
    mc->base.delete_sampler_state = ao46_metal_delete_sampler_state;
    mc->base.create_rasterizer_state = ao46_metal_create_rasterizer_state;
    mc->base.bind_rasterizer_state = ao46_metal_bind_rasterizer_state;
    mc->base.delete_rasterizer_state = ao46_metal_delete_rasterizer_state;
    mc->base.create_depth_stencil_alpha_state = ao46_metal_create_depth_stencil_alpha_state;
    mc->base.bind_depth_stencil_alpha_state = ao46_metal_bind_depth_stencil_alpha_state;
    mc->base.delete_depth_stencil_alpha_state = ao46_metal_delete_depth_stencil_alpha_state;
    mc->base.set_stencil_ref = ao46_metal_set_stencil_ref;
    mc->base.create_vs_state = ao46_metal_create_vs_state;
    mc->base.bind_vs_state = ao46_metal_bind_vs_state;
    mc->base.delete_vs_state = ao46_metal_delete_vs_state;
    mc->base.create_gs_state = ao46_metal_create_gs_state;
    mc->base.bind_gs_state = ao46_metal_bind_gs_state;
    mc->base.delete_gs_state = ao46_metal_delete_gs_state;
    mc->base.create_tcs_state = ao46_metal_create_tcs_state;
    mc->base.bind_tcs_state = ao46_metal_bind_tcs_state;
    mc->base.delete_tcs_state = ao46_metal_delete_tcs_state;
    mc->base.create_tes_state = ao46_metal_create_tes_state;
    mc->base.bind_tes_state = ao46_metal_bind_tes_state;
    mc->base.delete_tes_state = ao46_metal_delete_tes_state;
    mc->base.set_tess_state = ao46_metal_set_tess_state;
    mc->base.set_patch_vertices = ao46_metal_set_patch_vertices;
    mc->base.create_fs_state = ao46_metal_create_fs_state;
    mc->base.bind_fs_state = ao46_metal_bind_fs_state;
    mc->base.delete_fs_state = ao46_metal_delete_fs_state;
    mc->base.create_vertex_elements_state = ao46_metal_create_vertex_elements_state;
    mc->base.bind_vertex_elements_state = ao46_metal_bind_vertex_elements_state;
    mc->base.delete_vertex_elements_state = ao46_metal_delete_vertex_elements_state;
    mc->base.create_compute_state = ao46_metal_create_compute_state;
    mc->base.bind_compute_state = ao46_metal_bind_compute_state;
    mc->base.delete_compute_state = ao46_metal_delete_compute_state;
    mc->base.get_compute_state_info = ao46_metal_get_compute_state_info;
    mc->base.get_compute_state_subgroup_size = ao46_metal_get_compute_state_subgroup_size;
    mc->base.launch_grid = ao46_metal_launch_grid;

    mc->viewport.scale[0] = 1.0f; mc->viewport.scale[1] = 1.0f;
    mc->viewport.scale[2] = 1.0f;
    mc->viewport.translate[0] = 0.0f; mc->viewport.translate[1] = 0.0f;
    mc->viewport.translate[2] = 0.0f;
    mc->scissor.minx = 0; mc->scissor.miny = 0;
    mc->scissor.maxx = 0; mc->scissor.maxy = 0;

    if (getenv("AO46_TRACE_RUNTIME")) {
        fprintf(stderr, "[AO46Metal] pipe_context created successfully\n");
    }

    return &mc->base;
}

/* ======================================================================
 * Screen functions
 * ====================================================================== */
static const char *
ao46_metal_screen_get_name(struct pipe_screen *screen)
{
    return "AO46 Metal Gallium";
}

static const char *
ao46_metal_screen_get_vendor(struct pipe_screen *screen)
{
    return "Khronos_AppleICDs";
}

static const nir_shader_compiler_options ao46_metal_nir_options = {
    .lower_fmod = true,
    .lower_uniforms_to_ubo = true,
    .support_indirect_inputs = (uint8_t)BITFIELD_MASK(MESA_SHADER_STAGES),
    .support_indirect_outputs = (uint8_t)BITFIELD_MASK(MESA_SHADER_STAGES),
};

static bool
ao46_metal_screen_is_format_supported(struct pipe_screen *screen,
                                      enum pipe_format format,
                                      enum pipe_texture_target target,
                                      unsigned sample_count,
                                      unsigned storage_sample_count,
                                      unsigned bind)
{
    bool multisampled = sample_count > 1 || storage_sample_count > 1;

    (void)screen;

    if (sample_count > 4 || storage_sample_count > sample_count) {
        return false;
    }

    if (multisampled) {
        if ((target != PIPE_TEXTURE_2D && target != PIPE_TEXTURE_RECT) ||
            (bind & PIPE_BIND_SHADER_IMAGE)) {
            return false;
        }
    }

    if (target == PIPE_BUFFER) {
        if (sample_count > 1 || storage_sample_count > 1) {
            return false;
        }

        if ((bind & PIPE_BIND_VERTEX_BUFFER) &&
            !ao46_metal_vertex_format_uses_vbuf(format) &&
            ao46_metal_vertex_format(format) == MTLVertexFormatInvalid) {
            return false;
        }

        if ((bind & PIPE_BIND_SAMPLER_VIEW) &&
            !ao46_metal_buffer_texture_format_supported(format) &&
            !(ao46_metal_rgb32_buffer_texture_format(format) &&
              g_mtl_adapter.gpu_addressable_buffers)) {
            return false;
        }

        if ((bind & PIPE_BIND_SHADER_IMAGE) &&
            !ao46_metal_buffer_texture_format_supported(format)) {
            return false;
        }

        return true;
    }

    switch (format) {
        case PIPE_FORMAT_R8_UNORM:
        case PIPE_FORMAT_R8_SNORM:
        case PIPE_FORMAT_R8_UINT:
        case PIPE_FORMAT_R8_SINT:
        case PIPE_FORMAT_R8G8_UNORM:
        case PIPE_FORMAT_R8G8_SNORM:
        case PIPE_FORMAT_R8G8_UINT:
        case PIPE_FORMAT_R8G8_SINT:
        case PIPE_FORMAT_B8G8R8A8_UNORM:
        case PIPE_FORMAT_B8G8R8A8_SRGB:
        case PIPE_FORMAT_R8G8B8A8_UNORM:
        case PIPE_FORMAT_R8G8B8A8_SRGB:
        case PIPE_FORMAT_R8G8B8A8_SNORM:
        case PIPE_FORMAT_R8G8B8A8_UINT:
        case PIPE_FORMAT_R8G8B8A8_SINT:
        case PIPE_FORMAT_R10G10B10A2_UNORM:
        case PIPE_FORMAT_B10G10R10A2_UNORM:
        case PIPE_FORMAT_R10G10B10A2_UINT:
        case PIPE_FORMAT_R16_UNORM:
        case PIPE_FORMAT_R16_SNORM:
        case PIPE_FORMAT_R16_UINT:
        case PIPE_FORMAT_R16_SINT:
        case PIPE_FORMAT_R16_FLOAT:
        case PIPE_FORMAT_R16G16_UNORM:
        case PIPE_FORMAT_R16G16_SNORM:
        case PIPE_FORMAT_R16G16_UINT:
        case PIPE_FORMAT_R16G16_SINT:
        case PIPE_FORMAT_R16G16_FLOAT:
        case PIPE_FORMAT_R16G16B16A16_UNORM:
        case PIPE_FORMAT_R16G16B16A16_SNORM:
        case PIPE_FORMAT_R16G16B16A16_UINT:
        case PIPE_FORMAT_R16G16B16A16_SINT:
        case PIPE_FORMAT_R16G16B16A16_FLOAT:
        case PIPE_FORMAT_R11G11B10_FLOAT:
        case PIPE_FORMAT_R9G9B9E5_FLOAT:
        case PIPE_FORMAT_R32_UINT:
        case PIPE_FORMAT_R32_SINT:
        case PIPE_FORMAT_R32_FLOAT:
        case PIPE_FORMAT_R32G32_UINT:
        case PIPE_FORMAT_R32G32_SINT:
        case PIPE_FORMAT_R32G32_FLOAT:
        case PIPE_FORMAT_R32G32B32A32_UINT:
        case PIPE_FORMAT_R32G32B32A32_SINT:
        case PIPE_FORMAT_R32G32B32A32_FLOAT:
        case PIPE_FORMAT_Z32_FLOAT:
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
        case PIPE_FORMAT_RGTC1_UNORM:
        case PIPE_FORMAT_RGTC1_SNORM:
        case PIPE_FORMAT_RGTC2_UNORM:
        case PIPE_FORMAT_RGTC2_SNORM:
            return true;
        default:
            return false;
    }
}

static void
ao46_metal_init_shader_caps(struct pipe_screen *screen)
{
    for (unsigned i = 0; i <= MESA_SHADER_COMPUTE; i++) {
        struct pipe_shader_caps *caps =
            (struct pipe_shader_caps *)&screen->shader_caps[i];

        if (i != MESA_SHADER_VERTEX &&
            i != MESA_SHADER_TESS_CTRL &&
            i != MESA_SHADER_TESS_EVAL &&
            i != MESA_SHADER_FRAGMENT &&
            i != MESA_SHADER_COMPUTE) {
            continue;
        }

        caps->max_instructions = 16384;
        caps->max_alu_instructions = 16384;
        caps->max_tex_instructions = 4096;
        caps->max_tex_indirections = 256;
        caps->max_control_flow_depth = 256;
        caps->max_inputs = i == MESA_SHADER_COMPUTE ? 0 : 32;
        caps->max_outputs = i == MESA_SHADER_FRAGMENT ? PIPE_MAX_COLOR_BUFS :
            (i == MESA_SHADER_COMPUTE ? 0 : 32);
        caps->max_const_buffer0_size = 64 * 1024;
        caps->max_const_buffers = 16;
        caps->max_temps = 256;
        caps->max_texture_samplers = AO46_MAX_SAMPLERS;
        caps->max_sampler_views = AO46_MAX_SAMPLERS;
        caps->max_shader_buffers = AO46_MAX_SHADER_BUFFERS;
        caps->max_shader_images = AO46_MAX_IMAGE_UNITS;
        caps->supported_irs = 1 << PIPE_SHADER_IR_NIR;
        caps->cont_supported = true;
        caps->indirect_temp_addr = true;
        caps->indirect_const_addr = true;
        caps->integers = true;
        caps->fp16 = true;
        caps->int16 = true;
        caps->glsl_16bit_consts = true;
    }
}

static void
ao46_metal_init_compute_caps(struct pipe_screen *screen)
{
    struct pipe_compute_caps *caps =
        (struct pipe_compute_caps *)&screen->compute_caps;

    caps->address_bits = 64;
    caps->grid_dimension = 3;
    caps->max_grid_size[0] = 65535;
    caps->max_grid_size[1] = 65535;
    caps->max_grid_size[2] = 65535;
    caps->max_block_size[0] = 1024;
    caps->max_block_size[1] = 1024;
    caps->max_block_size[2] = 1024;
    caps->max_threads_per_block = 1024;
    caps->max_local_size = 32768;
}

static void
ao46_metal_init_screen_caps(struct pipe_screen *screen)
{
    struct pipe_caps *caps = (struct pipe_caps *)&screen->caps;

    u_init_pipe_screen_caps(screen, 1);
    caps->graphics = true;
    caps->npot_textures = true;
    caps->anisotropic_filter = true;
    caps->occlusion_query = true;
    caps->query_time_elapsed = true;
    caps->texture_swizzle = true;
    caps->texture_mirror_clamp = true;
    caps->texture_mirror_clamp_to_edge = true;
    caps->texture_multisample = true;
    caps->sample_shading = true;
    caps->clip_halfz = true;
    caps->texture_query_lod = true;
    caps->texture_barrier = true;
    caps->generate_mipmap = true;
    caps->blend_equation_separate = true;
    caps->primitive_restart = true;
    caps->primitive_restart_fixed_index = true;
    caps->indep_blend_enable = true;
    caps->indep_blend_func = true;
    caps->dest_surface_srgb_control = true;
    caps->fs_coord_origin_upper_left = true;
    caps->fs_coord_origin_lower_left = true;
    caps->fs_coord_pixel_center_half_integer = true;
    caps->fs_coord_pixel_center_integer = true;
    caps->depth_clip_disable = true;
    caps->shader_stencil_export = true;
    caps->vs_instanceid = true;
    caps->vertex_element_instance_divisor = true;
    caps->fragment_color_clamped = true;
    caps->mixed_framebuffer_sizes = true;
    caps->seamless_cube_map = true;
    caps->seamless_cube_map_per_texture = true;
    caps->conditional_render = true;
    caps->quads_follow_provoking_vertex_convention = true;
    caps->vertex_color_unclamped = true;
    caps->vertex_color_clamped = true;
    caps->user_vertex_buffers = true;
    caps->allow_mapped_buffers_during_execution = true;
    caps->start_instance = true;
    caps->query_timestamp = true;
    caps->cube_map_array = true;
    caps->texture_buffer_objects = true;
    caps->sampler_view_target = true;
    caps->query_pipeline_statistics = true;
    caps->stream_output_pause_resume = true;
    caps->stream_output_interleave_buffers = true;
    caps->fragment_shader_texture_lod = true;
    caps->fragment_shader_derivatives = true;
    caps->vs_layer_viewport = true;
    caps->draw_indirect = true;
    caps->multi_draw_indirect = true;
    caps->multi_draw_indirect_params = true;
    caps->doubles = true;
    caps->int64 = true;
    caps->constant_buffer_offset_alignment = 16;
    caps->min_map_buffer_alignment = 64;
    caps->shader_buffer_offset_alignment = 16;
    caps->max_combined_shader_buffers = 16;
    caps->image_store_formatted = true;
    caps->glsl_feature_level = 460;
    caps->glsl_feature_level_compatibility = 460;
    caps->fake_sw_msaa = true;
    caps->max_dual_source_render_targets = 1;
    caps->max_render_targets = PIPE_MAX_COLOR_BUFS;
    caps->max_texture_2d_size = 16384;
    caps->max_texture_3d_levels = 12;
    caps->max_texture_cube_levels = 15;
    caps->max_stream_output_buffers = PIPE_MAX_SO_BUFFERS;
    caps->max_texture_array_layers = 2048;
    caps->max_stream_output_separate_components = 16 * 4;
    caps->max_stream_output_interleaved_components = 32 * 4;
    caps->max_viewports = PIPE_MAX_VIEWPORTS;
    caps->max_geometry_output_vertices = 1024;
    caps->max_geometry_total_output_components = 4096;
    caps->max_vertex_streams = 1;
    caps->max_vertex_attrib_stride = 2048;
    caps->max_vertex_element_src_offset = 4095;
    caps->max_texture_gather_components = 4;
    caps->min_texture_gather_offset = -8;
    caps->max_texture_gather_offset = 7;
    caps->framebuffer_no_attachment = true;
    caps->viewport_subpixel_bits = 8;
    caps->rasterizer_subpixel_bits = 8;
    caps->max_line_width = 16.0f;
    caps->max_line_width_aa = 16.0f;
    caps->max_point_size = 64.0f;
    caps->max_point_size_aa = 64.0f;
    caps->max_texture_anisotropy = 16.0f;
    caps->max_texture_lod_bias = 16.0f;
    caps->compute = true;
}

static void
ao46_metal_screen_destroy(struct pipe_screen *screen)
{
    FREE(screen);

    pthread_mutex_lock(&g_mtl_lock);
    if (g_mtl_screen_count > 0) {
        --g_mtl_screen_count;
        if (g_mtl_screen_count == 0 && g_mtl_pending_screen_creations == 0)
            ao46_metal_release_shared_objects_locked();
    }
    pthread_mutex_unlock(&g_mtl_lock);
}

static void
ao46_metal_fence_reference(struct pipe_screen *screen,
                           struct pipe_fence_handle **ptr,
                           struct pipe_fence_handle *fence)
{
    (void)screen;

    if (!ptr) {
        return;
    }

    /* Our current backend does not manufacture reusable fence objects yet.
     * Keep the Gallium ownership hooks valid so Mesa teardown paths can
     * safely clear throttle/sync slots without jumping through NULL. */
    *ptr = fence;
}

static bool
ao46_metal_fence_finish(struct pipe_screen *screen,
                        struct pipe_context *ctx,
                        struct pipe_fence_handle *fence,
                        uint64_t timeout)
{
    (void)screen;
    (void)ctx;
    (void)fence;
    (void)timeout;
    return true;
}

static void
ao46_metal_screen_flush_frontbuffer(struct pipe_screen *screen,
                                    struct pipe_context *ctx,
                                    struct pipe_resource *resource,
                                    unsigned level,
                                    unsigned layer,
                                    void *winsys_drawable_handle,
                                    unsigned nboxes,
                                    struct pipe_box *subbox)
{
    (void)screen;
    (void)level;
    (void)layer;
    (void)winsys_drawable_handle;
    (void)nboxes;
    (void)subbox;

    if (!ctx || !resource) {
        return;
    }

    struct pipe_surface surf = {0};
    surf.texture = resource;
    surf.format = resource->format;
    surf.nr_samples = resource->nr_samples;
    ao46_metal_present(ctx, &surf);
}

/* ======================================================================
 * Window surface creation and presentation (public)
 * ====================================================================== */
CGLError
ao46_metal_create_window_surface(struct pipe_context *ctx,
                                 void *window,
                                 struct pipe_resource **out_tex,
                                 struct pipe_surface **out_surf)
{
    NSView *view = (__bridge NSView *)window;
    NSWindow *win = [view window];
    if (!win) return kCGLBadWindow;

    if (!ao46_metal_init()) return kCGLBadConnection;

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = g_mtl_device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.drawableSize = view.bounds.size;
    layer.framebufferOnly = NO;
    layer.opaque = YES;
    layer.displaySyncEnabled = YES;

    view.layer = layer;
    view.wantsLayer = YES;

    struct pipe_resource templ = {
        .target = PIPE_TEXTURE_2D,
        .format = PIPE_FORMAT_B8G8R8A8_UNORM,
        .width0 = (unsigned)view.bounds.size.width,
        .height0 = (unsigned)view.bounds.size.height,
        .depth0 = 1,
        .array_size = 1,
        .bind = PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW,
        .nr_samples = 0,
        .last_level = 0,
    };
    struct ao46_metal_resource *mr = CALLOC_STRUCT(ao46_metal_resource);
    if (!mr) return kCGLBadAlloc;
    mr->base = templ;
    mr->base.screen = ctx->screen;
    pipe_reference_init(&mr->base.reference, 1);
    mr->metal_layer = [layer retain];

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable) {
        mr->mtl_texture = drawable.texture;
    } else {
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType2D;
        desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.width = templ.width0;
        desc.height = templ.height0;
        desc.depth = 1;
        desc.mipmapLevelCount = 1;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        mr->mtl_texture = [g_mtl_device newTextureWithDescriptor:desc];
        [desc release];
    }

    struct pipe_surface *surf = CALLOC_STRUCT(pipe_surface);
    if (!surf) {
        ao46_metal_resource_destroy(ctx->screen, &mr->base);
        return kCGLBadAlloc;
    }
    pipe_reference_init(&surf->reference, 1);
    pipe_resource_reference(&surf->texture, &mr->base);
    surf->format = mr->base.format;
    surf->nr_samples = mr->base.nr_samples;
    surf->first_layer = 0;
    surf->last_layer = 0;
    surf->level = 0;

    *out_tex = &mr->base;
    *out_surf = surf;
    return kCGLNoError;
}

CGLError
ao46_metal_present(struct pipe_context *ctx, struct pipe_surface *surf)
{
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    struct ao46_metal_resource *mr = ao46_metal_resource(surf->texture);

    if (mr->metal_layer) {
        id<CAMetalDrawable> drawable = [mr->metal_layer nextDrawable];
        if (drawable) {
            if (mc->cmd_buffer) {
                [mc->cmd_buffer addScheduledHandler:^(id<MTLCommandBuffer> cb) {
                    [drawable present];
                }];
                if (mc->submission.native_command_buffer) {
                    (void)AO46MetalSubmissionCommit(&mc->submission, false);
                    AO46MetalSubmissionDestroy(&mc->submission);
                } else {
                    [mc->cmd_buffer commit];
                }
                mc->cmd_buffer = nil;
            } else {
                [drawable present];
            }
        }
    }
    return kCGLNoError;
}

/* ======================================================================
 * Public entry point for screen creation
 * ====================================================================== */
static struct pipe_screen *
ao46_metal_screen_create_initialized(void)
{
    struct pipe_screen *screen;

    pthread_mutex_lock(&g_mtl_lock);
    ++g_mtl_pending_screen_creations;
    pthread_mutex_unlock(&g_mtl_lock);

    screen = CALLOC_STRUCT(pipe_screen);
    if (!screen) {
        pthread_mutex_lock(&g_mtl_lock);
        --g_mtl_pending_screen_creations;
        if (g_mtl_screen_count == 0 && g_mtl_pending_screen_creations == 0)
            ao46_metal_release_shared_objects_locked();
        pthread_mutex_unlock(&g_mtl_lock);
        return NULL;
    }

    screen->get_name = ao46_metal_screen_get_name;
    screen->get_vendor = ao46_metal_screen_get_vendor;
    screen->get_device_vendor = ao46_metal_screen_get_vendor;
    screen->get_timestamp = u_default_get_timestamp;
    screen->is_format_supported = ao46_metal_screen_is_format_supported;
    screen->context_create = ao46_metal_screen_context_create;
    screen->destroy = ao46_metal_screen_destroy;
    screen->resource_create = ao46_metal_resource_create;
    screen->resource_destroy = ao46_metal_resource_destroy;
    screen->flush_frontbuffer = ao46_metal_screen_flush_frontbuffer;
    screen->fence_reference = ao46_metal_fence_reference;
    screen->fence_finish = ao46_metal_fence_finish;

    for (unsigned i = 0; i <= MESA_SHADER_COMPUTE; i++) {
        screen->nir_options[i] = &ao46_metal_nir_options;
    }

    ao46_metal_init_shader_caps(screen);
    ao46_metal_init_compute_caps(screen);
    ao46_metal_init_screen_caps(screen);

    pthread_mutex_lock(&g_mtl_lock);
    --g_mtl_pending_screen_creations;
    ++g_mtl_screen_count;
    pthread_mutex_unlock(&g_mtl_lock);
    return screen;
}

struct pipe_screen *
AO46MTLGalliumScreenCreate(const struct AO46MetalAdapter *adapter)
{
    if (!ao46_metal_init_from_adapter(adapter)) return NULL;
    return ao46_metal_screen_create_initialized();
}

bool
AO46MTLGalliumContextBindRenderPipeline(
    struct pipe_context *context,
    const struct AO46MetalRenderPipeline *pipeline)
{
    struct ao46_metal_context *mc;

    if (!context || context->draw_vbo != ao46_metal_draw_vbo) {
        return false;
    }
    if (pipeline && (!pipeline->native_pipeline ||
                     !AO46MetalAdapterIsCurrent(pipeline->adapter))) {
        return false;
    }

    mc = ao46_metal_context(context);
    mc->poly_render_pipeline = pipeline;
    return true;
}

bool
AO46MTLGalliumContextBindPolyTessellationDraw(
    struct pipe_context *context,
    const struct AO46MetalGalliumPolyTessellationDraw *draw)
{
    struct ao46_metal_context *mc;

    if (!context || context->draw_vbo != ao46_metal_draw_vbo) {
        return false;
    }
    mc = ao46_metal_context(context);
    if (!draw) {
        pipe_resource_reference(&mc->poly_tess_draw.parameter_resource, NULL);
        pipe_resource_reference(&mc->poly_tess_draw.index_resource, NULL);
        pipe_resource_reference(&mc->poly_tess_draw.indirect_resource, NULL);
        mc->poly_tess_draw =
            (struct AO46MetalGalliumPolyTessellationDraw){0};
        mc->poly_tess_sequence =
            (struct AO46MetalGalliumPolyTessellationSequence){0};
        return true;
    }

    if (!draw->parameter_resource || !draw->index_resource ||
        !draw->indirect_resource ||
        draw->parameter_resource->screen != context->screen ||
        draw->index_resource->screen != context->screen ||
        draw->indirect_resource->screen != context->screen ||
        draw->parameter_size == 0 || draw->index_size == 0 ||
        draw->indirect_size != 5 * sizeof(uint32_t) ||
        draw->indirect_offset % sizeof(uint32_t) != 0 ||
        draw->maximum_index_count == 0 || draw->input_patch_size == 0 ||
        draw->input_patch_size > 32 ||
        draw->input_vertex_count < draw->input_patch_size ||
        draw->input_vertex_count % draw->input_patch_size != 0 ||
        draw->maximum_index_count > draw->index_size / sizeof(uint32_t) ||
        !ao46_mtl_gallium_range(draw->parameter_resource,
                                draw->parameter_offset, draw->parameter_size) ||
        !ao46_mtl_gallium_range(draw->index_resource, draw->index_offset,
                                draw->index_size) ||
        !ao46_mtl_gallium_range(draw->indirect_resource,
                                draw->indirect_offset, draw->indirect_size)) {
        return false;
    }

    pipe_resource_reference(&mc->poly_tess_draw.parameter_resource,
                            draw->parameter_resource);
    pipe_resource_reference(&mc->poly_tess_draw.index_resource,
                            draw->index_resource);
    pipe_resource_reference(&mc->poly_tess_draw.indirect_resource,
                            draw->indirect_resource);
    mc->poly_tess_draw = *draw;
    return true;
}

bool
AO46MTLGalliumContextBindPolyTessellationSequence(
    struct pipe_context *context,
    const struct AO46MetalGalliumPolyTessellationSequence *sequence)
{
    struct ao46_metal_context *mc;

    if (!context || context->draw_vbo != ao46_metal_draw_vbo) {
        return false;
    }
    mc = ao46_metal_context(context);
    if (!sequence) {
        mc->poly_tess_sequence =
            (struct AO46MetalGalliumPolyTessellationSequence){0};
        return true;
    }
    if (!sequence->tcs_pipeline || !sequence->kernel_executor ||
        !sequence->plan || sequence->root_size == 0 ||
        sequence->sampler_table_size == 0 ||
        sequence->plan->output_primitive ==
            AO46_MESA_POLY_TESSELLATION_OUTPUT_INVALID) {
        return false;
    }

    mc->poly_tess_sequence = *sequence;
    return true;
}

bool
AO46MTLGalliumResourceGetCPUMapping(struct pipe_resource *resource,
                                    void **out_mapping,
                                    size_t *out_length)
{
    struct ao46_metal_resource *mr;

    if (!resource || !out_mapping || !out_length ||
        resource->target != PIPE_BUFFER) {
        return false;
    }
    mr = ao46_metal_resource(resource);
    if (!mr || !mr->mtl_buffer || !mr->mtl_buffer.contents) {
        return false;
    }
    *out_mapping = mr->mtl_buffer.contents;
    *out_length = mr->mtl_buffer.length;
    return true;
}

bool
AO46MTLGalliumResourceGetGPUAddress(struct pipe_resource *resource,
                                   uint64_t *out_address)
{
    struct ao46_metal_resource *mr;

    if (!resource || !out_address || resource->target != PIPE_BUFFER ||
        !AO46MetalAdapterSupportsGPUAddress(&g_mtl_adapter)) {
        return false;
    }
    mr = ao46_metal_resource(resource);
    if (!mr || !mr->mtl_buffer) {
        return false;
    }
    if (@available(macOS 13.0, *)) {
        *out_address = mr->mtl_buffer.gpuAddress;
        return *out_address != 0;
    }
    return false;
}

bool
AO46MTLGalliumResourceWriteGPUAddressRoot(
    struct pipe_resource *root, size_t root_offset,
    struct pipe_resource *target, size_t target_offset)
{
    struct ao46_metal_resource *root_resource;
    uint64_t address;

    if (!root || !target || root->screen != target->screen ||
        root_offset % _Alignof(uint64_t) != 0 ||
        !ao46_mtl_gallium_range(root, root_offset, sizeof(address)) ||
        target_offset >= target->width0 ||
        !AO46MTLGalliumResourceGetGPUAddress(target, &address) ||
        target_offset > UINT64_MAX - address) {
        return false;
    }
    root_resource = ao46_metal_resource(root);
    address += target_offset;
    memcpy((uint8_t *)root_resource->mtl_buffer.contents + root_offset,
           &address, sizeof(address));
    return true;
}

struct pipe_screen *
ao46_metal_screen_create(void)
{
    if (!ao46_metal_init()) return NULL;
    return ao46_metal_screen_create_initialized();
}
