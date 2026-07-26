#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>
#import <pthread.h>

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
#include "util/blend.h"
#include "state_tracker/st_context.h"
#include "nir/nir.h"
#include "compiler/shader_enums.h"
#include "compiler/glsl_types.h"

#include "mtl_pub.h"

#define AO46_MAX_SAMPLERS 16  /* Conservative graphics-stage sampler budget */
#ifndef MAX_IMAGE_UNITS
#define MAX_IMAGE_UNITS 8  /* GL_MAX_IMAGE_UNITS */
#endif

/* ======================================================================
 * Metal global objects (defined here, declared extern in mtl_pub.h)
 * ====================================================================== */
id<MTLDevice> g_mtl_device = nil;
id<MTLCommandQueue> g_mtl_queue = nil;
static pthread_mutex_t g_mtl_lock = PTHREAD_MUTEX_INITIALIZER;

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
            g_mtl_device = nil;
            pthread_mutex_unlock(&g_mtl_lock);
            return false;
        }
    }
    pthread_mutex_unlock(&g_mtl_lock);
    return true;
}

static id<MTLCommandBuffer> ao46_metal_get_command_buffer(void)
{
    return [g_mtl_queue commandBuffer];
}

static MTLPixelFormat
ao46_metal_pixel_format(enum pipe_format format)
{
    switch (format) {
        case PIPE_FORMAT_B8G8R8A8_UNORM:
            return MTLPixelFormatBGRA8Unorm;
        case PIPE_FORMAT_B8G8R8A8_SRGB:
            return MTLPixelFormatBGRA8Unorm_sRGB;
        case PIPE_FORMAT_R8G8B8A8_UNORM:
            return MTLPixelFormatRGBA8Unorm;
        case PIPE_FORMAT_R8G8B8A8_SRGB:
            return MTLPixelFormatRGBA8Unorm_sRGB;
        case PIPE_FORMAT_Z32_FLOAT:
            return MTLPixelFormatDepth32Float;
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
            return MTLPixelFormatDepth32Float_Stencil8;
        default:
            return MTLPixelFormatBGRA8Unorm;
    }
}

static MTLVertexFormat
ao46_metal_vertex_format(enum pipe_format format)
{
    switch (format) {
        case PIPE_FORMAT_R32_FLOAT:
            return MTLVertexFormatFloat;
        case PIPE_FORMAT_R32G32_FLOAT:
            return MTLVertexFormatFloat2;
        case PIPE_FORMAT_R32G32B32_FLOAT:
            return MTLVertexFormatFloat3;
        case PIPE_FORMAT_R32G32B32A32_FLOAT:
            return MTLVertexFormatFloat4;
        case PIPE_FORMAT_R16_FLOAT:
            return MTLVertexFormatHalf;
        case PIPE_FORMAT_R16G16_FLOAT:
            return MTLVertexFormatHalf2;
        case PIPE_FORMAT_R16G16B16A16_FLOAT:
            return MTLVertexFormatHalf4;
        case PIPE_FORMAT_R8G8B8A8_UNORM:
            return MTLVertexFormatUChar4Normalized;
        case PIPE_FORMAT_R8G8B8A8_SNORM:
            return MTLVertexFormatChar4Normalized;
        case PIPE_FORMAT_R8G8B8A8_UINT:
            return MTLVertexFormatUChar4;
        case PIPE_FORMAT_R16G16_UNORM:
            return MTLVertexFormatUShort2Normalized;
        case PIPE_FORMAT_R16G16B16A16_UNORM:
            return MTLVertexFormatUShort4Normalized;
        default:
            return MTLVertexFormatInvalid;
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
    switch (format) {
        case PIPE_FORMAT_B8G8R8A8_UNORM:
        case PIPE_FORMAT_B8G8R8A8_SRGB:
        case PIPE_FORMAT_R8G8B8A8_UNORM:
        case PIPE_FORMAT_R8G8B8A8_SRGB:
        case PIPE_FORMAT_Z32_FLOAT:
            return 4;
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
            return 4;
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
            return 8;
        default:
            return 0;
    }
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
ao46_metal_texture_type_for_sampler_view(enum pipe_texture_target target,
                                         NSUInteger slice_count)
{
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
    if (!res) return NULL;

    res->base = *templ;
    res->base.screen = screen;

    MTLPixelFormat mtl_format = ao46_metal_pixel_format(templ->format);

    switch (templ->target) {
        case PIPE_BUFFER: {
            size_t size = templ->width0;
            res->mtl_buffer = [g_mtl_device newBufferWithLength:size
                                                        options:MTLResourceStorageModeShared];
            if (!res->mtl_buffer) {
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
            desc.textureType = ao46_metal_texture_type_for_resource(templ);
            desc.pixelFormat = mtl_format;
            desc.width = templ->width0;
            desc.height = templ->height0;
            desc.depth = templ->target == PIPE_TEXTURE_3D ?
                MAX2((NSUInteger)templ->depth0, 1u) : 1;
            desc.mipmapLevelCount = templ->last_level + 1;
            desc.arrayLength = ao46_metal_texture_array_length(templ);
            desc.usage = MTLTextureUsageRenderTarget |
                MTLTextureUsageShaderRead |
                MTLTextureUsagePixelFormatView;
            if (templ->bind & PIPE_BIND_SHADER_IMAGE) {
                desc.usage |= MTLTextureUsageShaderWrite;
            }
            if (templ->bind & PIPE_BIND_DEPTH_STENCIL) {
                desc.pixelFormat = ao46_metal_pixel_format(templ->format);
                desc.usage |= MTLTextureUsageRenderTarget;
            }
            res->mtl_texture = [g_mtl_device newTextureWithDescriptor:desc];
            [desc release];
            if (!res->mtl_texture) {
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
    struct nir_shader *nir;
};

struct ao46_metal_context {
    /* Texture buffers (GL_TEXTURE_BUFFER) */
    struct pipe_resource *texture_buffer;   /* currently bound buffer texture */
    id<MTLTexture> texture_buffer_mtl;      /* Metal texture wrapping the buffer */
    /* Image units (shader storage images) */
    struct pipe_image_view image_views[8];  /* GL_MAX_IMAGE_UNITS */
    uint num_image_views;
    struct pipe_context base;

    id<MTLCommandBuffer> cmd_buffer;
    MTLRenderPassDescriptor *render_pass;
    id<MTLRenderCommandEncoder> render_encoder;
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
    struct ao46_metal_shader *vs_shader;
    struct ao46_metal_shader *fs_shader;
    struct ao46_metal_shader *cs_shader;
    struct pipe_constant_buffer const_buffers[MESA_SHADER_STAGES];
    id<MTLBuffer> const_buffer_mtl[MESA_SHADER_STAGES];
    bool const_buffer_dirty[MESA_SHADER_STAGES];
    struct pipe_sampler_view *sampler_views[MESA_SHADER_STAGES][AO46_MAX_SAMPLERS];
    struct ao46_metal_sampler_state *samplers[MESA_SHADER_STAGES][AO46_MAX_SAMPLERS];
    uint num_sampler_views[MESA_SHADER_STAGES];
    uint num_samplers[MESA_SHADER_STAGES];
};

static inline struct ao46_metal_context *
ao46_metal_context(struct pipe_context *ctx)
{
    return (struct ao46_metal_context *)ctx;
}

static void *
ao46_metal_buffer_map(struct pipe_context *ctx,
                      struct pipe_resource *resource,
                      unsigned level,
                      unsigned usage,
                      const struct pipe_box *box,
                      struct pipe_transfer **out_transfer)
{
    (void)ctx;
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
    (void)ctx;
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
    if (mc && mc->render_encoder) {
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
    [cmd_buffer commit];
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
        info->src.box.depth != info->dst.box.depth ||
        info->src.format != info->dst.format) {
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

static void
ao46_metal_clear_render_target(struct pipe_context *ctx,
                               struct pipe_surface *dst,
                               const union pipe_color_union *color,
                               unsigned dstx, unsigned dsty,
                               unsigned width, unsigned height,
                               bool render_condition_enabled)
{
    struct pipe_box box;
    id<MTLTexture> surface_texture;

    (void)render_condition_enabled;
    if (!ctx || !dst || !dst->texture || !color) {
        return;
    }

    surface_texture = ao46_metal_get_surface_texture(dst);
    if (!surface_texture) {
        return;
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
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor =
            MTLClearColorMake(color->f[0], color->f[1], color->f[2], color->f[3]);
        encoder = [cmd_buffer renderCommandEncoderWithDescriptor:rpd];
        [encoder endEncoding];
        [rpd release];
        [surface_texture release];
        [cmd_buffer commit];
        return;
    }

    u_box_2d(dstx, dsty, width, height, &box);
    if (ao46_metal_bytes_per_pixel(dst->format) == 4) {
        uint8_t texel[4];
        ao46_metal_pack_color_texel(dst->format, color, texel);
        box.z = 0;
        box.depth = ao46_metal_texture_type_uses_slices(surface_texture.textureType) ?
            (int)MAX2(surface_texture.arrayLength, 1u) : 1;
        (void)ao46_metal_fill_texture_box(surface_texture, dst->format, 0, &box, texel);
    }
    [surface_texture release];
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
    [cmd_buffer commit];
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
    return ms;
}

static void
ao46_metal_destroy_shader_state(struct ao46_metal_shader *shader)
{
    if (!shader) return;
    [shader->function release];
    shader->function = nil;
    FREE(shader);
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
ao46_metal_create_compute_state(struct pipe_context *ctx,
                                const struct pipe_compute_state *state)
{
    (void)ctx;
    (void)state;
    return NULL;
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
    if (!state) return NULL;
    state->num_elements = MIN2(num_elements, PIPE_MAX_ATTRIBS);
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
    if (!mr->mtl_texture) {
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

    pixel_format = ao46_metal_pixel_format(view->base.format);
    slice_count = ao46_metal_texture_uses_slices(texture) || ao46_metal_texture_is_3d(texture) ?
        (NSUInteger)(view->base.u.tex.last_layer - view->base.u.tex.first_layer + 1) : 1u;
    level_count = view->base.u.tex.last_level - view->base.u.tex.first_level + 1;
    view_type = ao46_metal_texture_type_for_sampler_view(view->base.target,
                                                         MAX2(slice_count, 1u));
    full_levels = view->base.u.tex.first_level == 0 &&
        view->base.u.tex.last_level == texture->last_level;
    full_slices = view->base.u.tex.first_layer == 0 &&
        slice_count == ao46_metal_texture_slice_count(texture, view->base.u.tex.first_level);

    if (pixel_format == mr->mtl_texture.pixelFormat &&
        view_type == mr->mtl_texture.textureType &&
        full_levels && full_slices) {
        view->mtl_texture = [mr->mtl_texture retain];
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
    mc->fb_state = *fb;
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
            continue;
        }

        MTLVertexFormat format =
            ao46_metal_vertex_format((enum pipe_format)elem->src_format);
        if (format == MTLVertexFormatInvalid) {
            continue;
        }

        descriptor.attributes[i].format = format;
        descriptor.attributes[i].offset = elem->src_offset;
        descriptor.attributes[i].bufferIndex = elem->vertex_buffer_index;

        MTLVertexBufferLayoutDescriptor *layout =
            descriptor.layouts[elem->vertex_buffer_index];
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
static uint64_t
ao46_metal_compute_pipeline_key(struct ao46_metal_context *mc,
                                enum mesa_prim mode)
{
    uint64_t key = 1469598103934665603ULL;
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->vs_shader);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->fs_shader);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->blend);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->raster);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->dsa);
    key = ao46_metal_hash_u64(key, (uintptr_t)mc->vertex_elements_state);
    key = ao46_metal_hash_u64(key, ao46_metal_primitive_topology_class(mode));
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
    return key;
}

static id<MTLRenderPipelineState>
ao46_metal_get_pipeline_state(struct ao46_metal_context *mc, enum mesa_prim mode)
{
    uint64_t new_key = ao46_metal_compute_pipeline_key(mc, mode);
    if (mc->pipeline_state && mc->pipeline_key == new_key) {
        return mc->pipeline_state;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];

    if (mc->vs_shader) {
        desc.vertexFunction = mc->vs_shader->function;
    } else {
        [desc release];
        return nil;
    }

    desc.fragmentFunction = mc->fs_shader ? mc->fs_shader->function : nil;

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

    NSError *error = nil;
    id<MTLRenderPipelineState> ps = [g_mtl_device newRenderPipelineStateWithDescriptor:desc error:&error];
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
    (void)drawid_offset;
    struct ao46_metal_context *mc = ao46_metal_context(ctx);
    bool needs_emulation = ao46_metal_primitive_needs_emulation(info);
    if (!mc || !info || !draws || num_draws == 0) return;
    if (indirect || info->has_user_indices) return;

    if (!mc->render_encoder) {
        id<MTLTexture> color_textures[PIPE_MAX_COLOR_BUFS] = { nil };
        id<MTLTexture> depth_texture = nil;
        mc->cmd_buffer = ao46_metal_get_command_buffer();
        if (!mc->cmd_buffer) return;

        MTLRenderPassDescriptor *rpd = [[MTLRenderPassDescriptor alloc] init];
        for (unsigned i = 0; i < mc->fb_state.nr_cbufs; i++) {
            struct pipe_surface *surf = &mc->fb_state.cbufs[i];
            if (!surf->texture) continue;
            color_textures[i] = ao46_metal_get_surface_texture(surf);
            if (color_textures[i]) {
                rpd.colorAttachments[i].texture = color_textures[i];
                rpd.colorAttachments[i].loadAction = MTLLoadActionLoad;
                rpd.colorAttachments[i].storeAction = MTLStoreActionStore;
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
        }
        [depth_texture release];
        mc->render_pass_started = true;
    }

    id<MTLRenderCommandEncoder> enc = mc->render_encoder;
    if (!enc) return;

    id<MTLRenderPipelineState> ps = ao46_metal_get_pipeline_state(mc, info->mode);
    if (!ps) return;
    [enc setRenderPipelineState:ps];
    [enc setDepthStencilState:mc->dsa ? mc->dsa->mtl_state : nil];
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
    vp.originY = mc->viewport.translate[1] - mc->viewport.scale[1];
    vp.width = mc->viewport.scale[0] * 2.0f;
    vp.height = mc->viewport.scale[1] * 2.0f;
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
    scissor.x = mc->scissor.minx;
    scissor.y = mc->scissor.miny;
    scissor.width = mc->scissor.maxx > mc->scissor.minx ?
        mc->scissor.maxx - mc->scissor.minx : fb_width;
    scissor.height = mc->scissor.maxy > mc->scissor.miny ?
        mc->scissor.maxy - mc->scissor.miny : fb_height;
    [enc setScissorRect:scissor];

    const mesa_shader_stage graphics_stages[] = {
        MESA_SHADER_VERTEX,
        MESA_SHADER_FRAGMENT,
    };

    for (unsigned stage_index = 0; stage_index < ARRAY_SIZE(graphics_stages); stage_index++) {
        mesa_shader_stage stage = graphics_stages[stage_index];
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
    }

    for (unsigned stage_index = 0; stage_index < ARRAY_SIZE(graphics_stages); stage_index++) {
        mesa_shader_stage stage = graphics_stages[stage_index];
        if (mc->const_buffer_mtl[stage] && mc->const_buffer_dirty[stage]) {
            NSUInteger bufferIndex = (stage == MESA_SHADER_VERTEX) ? 1 : 2;
            if (stage == MESA_SHADER_VERTEX) {
                [enc setVertexBuffer:mc->const_buffer_mtl[stage]
                              offset:0
                             atIndex:bufferIndex];
            } else if (stage == MESA_SHADER_FRAGMENT) {
                [enc setFragmentBuffer:mc->const_buffer_mtl[stage]
                                offset:0
                               atIndex:bufferIndex];
            }
            mc->const_buffer_dirty[stage] = false;
        }
    }

    if (mc->vertex_elements_state) {
        for (unsigned i = 0; i < mc->vertex_elements_state->num_elements; i++) {
            const struct pipe_vertex_element *elem = &mc->vertex_elements_state->elements[i];
            uint buffer_index = elem->vertex_buffer_index;
            if (buffer_index >= mc->num_vertex_buffers || buffer_index >= PIPE_MAX_ATTRIBS) {
                continue;
            }

            struct pipe_vertex_buffer *vb = &mc->vertex_buffers[buffer_index];
            if (vb->is_user_buffer || !vb->buffer.resource) {
                continue;
            }

            struct ao46_metal_resource *mr = ao46_metal_resource(vb->buffer.resource);
            if (!mr->mtl_buffer) {
                continue;
            }

            NSUInteger offset = vb->buffer_offset + elem->src_offset;
            [enc setVertexBuffer:mr->mtl_buffer
                          offset:offset
                         atIndex:buffer_index];
        }
    }

    if (mc->raster && mc->raster->base.cull_face == PIPE_FACE_FRONT_AND_BACK) {
        return;
    }

    MTLPrimitiveType prim_type = ao46_metal_primitive_type(info->mode);
    NSUInteger instance_count = MAX2(info->instance_count, 1u);

    for (unsigned draw_index = 0; draw_index < num_draws; draw_index++) {
        const struct pipe_draw_start_count_bias *draw = &draws[draw_index];
        if (!draw->count) {
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
    if (mc->render_encoder) {
        [mc->render_encoder endEncoding];
        mc->render_encoder = nil;
        mc->render_pass_started = false;
    }
    if (mc->cmd_buffer) {
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
    [mc->cmd_buffer release];
    [mc->render_pass release];
    [mc->pipeline_state release];
    mc->cmd_buffer = nil;
    mc->render_pass = nil;
    mc->pipeline_state = nil;
    for (int i = 0; i < MESA_SHADER_STAGES; i++) {
        [mc->const_buffer_mtl[i] release];
        mc->const_buffer_mtl[i] = nil;
        for (unsigned j = 0; j < AO46_MAX_SAMPLERS; j++) {
            pipe_sampler_view_reference(&mc->sampler_views[i][j], NULL);
        }
    }
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
    if (!ao46_metal_init()) return NULL;

    struct ao46_metal_context *mc = CALLOC_STRUCT(ao46_metal_context);
    if (!mc) return NULL;

    mc->base.screen = screen;
    mc->base.priv = priv;
    mc->base.destroy = ao46_metal_context_destroy;
    mc->base.flush = ao46_metal_context_flush;
    mc->base.draw_vbo = ao46_metal_draw_vbo;
    mc->base.resource_copy_region = ao46_metal_resource_copy_region;
    mc->base.blit = ao46_metal_blit;
    mc->base.clear = ao46_metal_clear;
    mc->base.clear_render_target = ao46_metal_clear_render_target;
    mc->base.clear_depth_stencil = ao46_metal_clear_depth_stencil;
    mc->base.clear_texture = ao46_metal_clear_texture;
    mc->base.clear_buffer = ao46_metal_clear_buffer;
    mc->base.set_framebuffer_state = ao46_metal_set_framebuffer_state;
    mc->base.set_vertex_buffers = ao46_metal_set_vertex_buffers;
    mc->base.set_viewport_states = ao46_metal_set_viewport_states;
    mc->base.set_scissor_states = ao46_metal_set_scissor_states;
    mc->base.set_constant_buffer = ao46_metal_set_constant_buffer;
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
    mc->base.create_fs_state = ao46_metal_create_fs_state;
    mc->base.bind_fs_state = ao46_metal_bind_fs_state;
    mc->base.delete_fs_state = ao46_metal_delete_fs_state;
    mc->base.create_vertex_elements_state = ao46_metal_create_vertex_elements_state;
    mc->base.bind_vertex_elements_state = ao46_metal_bind_vertex_elements_state;
    mc->base.delete_vertex_elements_state = ao46_metal_delete_vertex_elements_state;
    mc->base.create_compute_state = ao46_metal_create_compute_state;
    mc->base.bind_compute_state = ao46_metal_bind_compute_state;
    mc->base.delete_compute_state = ao46_metal_delete_compute_state;

    mc->viewport.scale[0] = 1.0f; mc->viewport.scale[1] = 1.0f;
    mc->viewport.scale[2] = 1.0f;
    mc->viewport.translate[0] = 0.0f; mc->viewport.translate[1] = 0.0f;
    mc->viewport.translate[2] = 0.0f;
    mc->scissor.minx = 0; mc->scissor.miny = 0;
    mc->scissor.maxx = 0; mc->scissor.maxy = 0;

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
    (void)screen;
    (void)bind;

    if (sample_count > 1 || storage_sample_count > 1) {
        return false;
    }

    if (target == PIPE_BUFFER) {
        return true;
    }

    switch (format) {
        case PIPE_FORMAT_B8G8R8A8_UNORM:
        case PIPE_FORMAT_B8G8R8A8_SRGB:
        case PIPE_FORMAT_R8G8B8A8_UNORM:
        case PIPE_FORMAT_R8G8B8A8_SRGB:
        case PIPE_FORMAT_Z32_FLOAT:
        case PIPE_FORMAT_Z32_FLOAT_S8X24_UINT:
        case PIPE_FORMAT_Z24_UNORM_S8_UINT:
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

        if (i != MESA_SHADER_VERTEX && i != MESA_SHADER_FRAGMENT) {
            continue;
        }

        caps->max_instructions = 16384;
        caps->max_alu_instructions = 16384;
        caps->max_tex_instructions = 4096;
        caps->max_tex_indirections = 256;
        caps->max_control_flow_depth = 256;
        caps->max_inputs = 32;
        caps->max_outputs = i == MESA_SHADER_FRAGMENT ? PIPE_MAX_COLOR_BUFS : 32;
        caps->max_const_buffer0_size = 64 * 1024;
        caps->max_const_buffers = 16;
        caps->max_temps = 256;
        caps->max_texture_samplers = AO46_MAX_SAMPLERS;
        caps->max_sampler_views = AO46_MAX_SAMPLERS;
        caps->max_shader_buffers = 8;
        caps->max_shader_images = 8;
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
    caps->blend_equation_separate = true;
    caps->primitive_restart = false;
    caps->primitive_restart_fixed_index = false;
    caps->indep_blend_enable = true;
    caps->indep_blend_func = true;
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
    caps->vertex_color_unclamped = true;
    caps->vertex_color_clamped = true;
    caps->user_vertex_buffers = true;
    caps->start_instance = true;
    caps->query_timestamp = true;
    caps->cube_map_array = true;
    caps->texture_buffer_objects = true;
    caps->query_pipeline_statistics = true;
    caps->fragment_shader_texture_lod = true;
    caps->fragment_shader_derivatives = true;
    caps->vs_layer_viewport = true;
    caps->draw_indirect = true;
    caps->doubles = true;
    caps->int64 = true;
    caps->constant_buffer_offset_alignment = 16;
    caps->min_map_buffer_alignment = 64;
    caps->glsl_feature_level = 460;
    caps->glsl_feature_level_compatibility = 460;
    caps->max_render_targets = PIPE_MAX_COLOR_BUFS;
    caps->max_texture_2d_size = 16384;
    caps->max_texture_3d_levels = 12;
    caps->max_texture_cube_levels = 14;
    caps->max_stream_output_buffers = PIPE_MAX_SO_BUFFERS;
    caps->max_texture_array_layers = 2048;
    caps->max_stream_output_separate_components = 16 * 4;
    caps->max_stream_output_interleaved_components = 32 * 4;
    caps->max_viewports = PIPE_MAX_VIEWPORTS;
    caps->max_geometry_output_vertices = 1024;
    caps->max_geometry_total_output_components = 4096;
    caps->max_vertex_streams = 1;
    caps->max_vertex_attrib_stride = 2048;
    caps->compute = false;
}

static void
ao46_metal_screen_destroy(struct pipe_screen *screen)
{
    FREE(screen);
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
    }

    struct pipe_surface *surf = CALLOC_STRUCT(pipe_surface);
    if (!surf) {
        FREE(mr);
        return kCGLBadAlloc;
    }
    surf->texture = &mr->base;
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
                [mc->cmd_buffer commit];
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
struct pipe_screen *
ao46_metal_screen_create(void)
{
    if (!ao46_metal_init()) return NULL;

    struct pipe_screen *screen = CALLOC_STRUCT(pipe_screen);
    if (!screen) return NULL;

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

    for (unsigned i = 0; i <= MESA_SHADER_COMPUTE; i++) {
        screen->nir_options[i] = &ao46_metal_nir_options;
    }

    ao46_metal_init_shader_caps(screen);
    ao46_metal_init_compute_caps(screen);
    ao46_metal_init_screen_caps(screen);

    return screen;
}
