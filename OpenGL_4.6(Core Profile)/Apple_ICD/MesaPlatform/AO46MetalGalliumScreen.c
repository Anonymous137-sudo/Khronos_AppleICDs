/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MetalGalliumScreen.h"

#include "AO46MetalAdapter.h"
#include "AO46MesaMSLRenderPipeline.h"
#include "AO46MesaNIRBufferTexture.h"
#include "AO46MesaPolyKernelCatalog.h"
#include "AO46MesaPolyTessellation.h"

#if AO46_HAVE_MESA_LIBKK
#include "AO46MesaMSLComputePipeline.h"
#include "AO46MesaPolyKernelExecutor.h"
#include "nir.h"
#endif

#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "util/box.h"
#include "util/u_inlines.h"
#include "util/ralloc.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct AO46MetalGalliumScreen {
   struct pipe_screen base;
   const struct AO46MetalAdapter *adapter;
};

struct AO46MetalGalliumResource {
   struct pipe_resource base;
   struct AO46MetalBuffer buffer;
   struct AO46MetalTexture texture;
};

struct AO46MetalGalliumFence {
   struct pipe_reference reference;
   struct AO46MetalSubmission submission;
   struct pipe_resource **resources;
   size_t resource_count;
};

struct AO46MetalGalliumTransfer {
   struct pipe_transfer base;
};

struct AO46MetalGalliumSurface {
   struct pipe_surface base;
};

struct AO46MetalGalliumSamplerState {
   struct AO46MetalSampler sampler;
};

struct AO46MetalGalliumSamplerView {
   struct pipe_sampler_view base;
   bool buffer_view;
   size_t buffer_offset;
   size_t buffer_size;
};

struct AO46MetalGalliumVertexElementsState {
   unsigned count;
   struct pipe_vertex_element elements[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
};

/* Owns the NIR accepted through Gallium's TCS/TES state-object callbacks. */
struct AO46MetalGalliumTessellationShaderState {
   struct nir_shader *nir;
   enum mesa_shader_stage stage;
};

#if AO46_HAVE_MESA_LIBKK
/* Owns an immutable Mesa NIR compute variant and its KK-generated Metal PSO. */
struct AO46MetalGalliumComputeState {
   struct nir_shader *nir;
   struct AO46MesaComputePipeline pipeline;
};
#endif

/* Mesa owns stream-output semantics; this target owns the retained buffer range. */
struct AO46MetalGalliumStreamOutputTarget {
   struct pipe_stream_output_target base;
   unsigned write_offset;
};

struct AO46MetalGalliumContext {
   struct pipe_context base;
   struct AO46MetalGalliumFence *last_fence;
   const struct AO46MetalRenderPipeline *draw_pipeline;
   struct AO46MetalGalliumPolyTessellationDraw poly_tess_draw;
   struct AO46MetalGalliumPolyTessellationSequence poly_tess_sequence;
   struct AO46MetalGalliumTessellationShaderState *tcs_state;
   struct AO46MetalGalliumTessellationShaderState *tes_state;
   float tess_outer_level[4];
   float tess_inner_level[2];
   bool tess_state_set;
   uint8_t patch_vertices;
   struct AO46MetalGalliumVertexElementsState *vertex_elements;
   struct pipe_framebuffer_state framebuffer;
   struct pipe_vertex_buffer
      vertex_buffers[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
   unsigned vertex_buffer_count;
   struct pipe_constant_buffer
      constant_buffers[MESA_SHADER_STAGES][AO46_METAL_MAX_UNIFORM_BINDINGS];
   void *fragment_samplers[AO46_METAL_MAX_STATIC_BINDINGS];
   struct pipe_sampler_view *vertex_sampler_views[AO46_METAL_MAX_STATIC_BINDINGS];
   struct pipe_sampler_view *fragment_sampler_views[AO46_METAL_MAX_STATIC_BINDINGS];
   struct pipe_stream_output_target *stream_output_targets[PIPE_MAX_SO_BUFFERS];
   unsigned stream_output_offsets[PIPE_MAX_SO_BUFFERS];
   unsigned num_stream_output_targets;
   enum mesa_prim stream_output_prim;
#if AO46_HAVE_MESA_LIBKK
   struct AO46MetalGalliumComputeState *compute_state;
   struct pipe_shader_buffer
      compute_shader_buffers[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint32_t compute_shader_buffer_mask;
   uint32_t compute_shader_buffer_writable_mask;
#endif
};

static struct AO46MetalGalliumScreen *
ao46_metal_gallium_screen(struct pipe_screen *screen)
{
   return (struct AO46MetalGalliumScreen *)screen;
}

static struct AO46MetalGalliumResource *
ao46_metal_gallium_resource(struct pipe_resource *resource)
{
   return (struct AO46MetalGalliumResource *)resource;
}

static struct AO46MetalGalliumContext *
ao46_metal_gallium_context(struct pipe_context *context)
{
   return (struct AO46MetalGalliumContext *)context;
}

static bool
ao46_metal_gallium_tessellation_states_match_plan(
   const struct AO46MetalGalliumContext *context,
   const struct AO46MesaPolyTessellationPlan *plan)
{
   return context && plan && context->tess_state_set && context->tcs_state &&
          context->tes_state &&
          context->tcs_state->stage == MESA_SHADER_TESS_CTRL &&
          context->tes_state->stage == MESA_SHADER_TESS_EVAL &&
          AO46MesaPolyTessellationPlanMatchesTCS(plan, context->tcs_state->nir) &&
          AO46MesaPolyTessellationPlanMatchesTES(plan, context->tes_state->nir);
}

static bool
ao46_metal_gallium_poly_kernel_for_plan(
   const struct AO46MesaPolyTessellationPlan *plan,
   enum AO46MesaPolyKernel *out_kernel)
{
   if (!plan || !out_kernel)
      return false;

   switch (plan->domain) {
   case AO46_MESA_POLY_TESSELLATION_TRIANGLES:
      *out_kernel = AO46_MESA_POLY_KERNEL_TRIANGLE;
      return true;
   case AO46_MESA_POLY_TESSELLATION_QUADS:
      *out_kernel = AO46_MESA_POLY_KERNEL_QUAD;
      return true;
   case AO46_MESA_POLY_TESSELLATION_ISOLINES:
      *out_kernel = AO46_MESA_POLY_KERNEL_ISOLINE;
      return true;
   default:
      return false;
   }
}

static bool
ao46_metal_gallium_poly_output_primitive(
   const struct AO46MesaPolyTessellationPlan *plan,
   enum AO46MetalPrimitive *out_primitive)
{
   if (!plan || !out_primitive)
      return false;

   switch (plan->output_primitive) {
   case AO46_MESA_POLY_TESSELLATION_OUTPUT_TRIANGLES:
      *out_primitive = AO46_METAL_PRIMITIVE_TRIANGLES;
      return true;
   case AO46_MESA_POLY_TESSELLATION_OUTPUT_LINES:
      *out_primitive = AO46_METAL_PRIMITIVE_LINES;
      return true;
   case AO46_MESA_POLY_TESSELLATION_OUTPUT_POINTS:
      *out_primitive = AO46_METAL_PRIMITIVE_POINTS;
      return true;
   default:
      return false;
   }
}

static uint32_t
ao46_metal_gallium_poly_output_minimum_index_count(
   enum AO46MetalPrimitive primitive)
{
   switch (primitive) {
   case AO46_METAL_PRIMITIVE_TRIANGLES:
      return 3;
   case AO46_METAL_PRIMITIVE_LINES:
      return 2;
   case AO46_METAL_PRIMITIVE_POINTS:
      return 1;
   default:
      return UINT32_MAX;
   }
}

static struct AO46MetalGalliumFence *
ao46_metal_gallium_fence(struct pipe_fence_handle *fence)
{
   return (struct AO46MetalGalliumFence *)fence;
}

static void
ao46_metal_gallium_fence_destroy(struct AO46MetalGalliumFence *fence)
{
   /* Keep MTL4 allocator/table residency valid until the queue reports completion. */
   (void)AO46MetalSubmissionWait(&fence->submission);
   for (size_t i = 0; i < fence->resource_count; ++i)
      pipe_resource_reference(&fence->resources[i], NULL);
   free(fence->resources);
   AO46MetalSubmissionDestroy(&fence->submission);
   free(fence);
}

static void
ao46_metal_gallium_fence_reference(struct pipe_screen *screen,
                                   struct pipe_fence_handle **destination,
                                   struct pipe_fence_handle *source)
{
   struct AO46MetalGalliumFence *old_fence;
   struct AO46MetalGalliumFence *new_fence;

   (void)screen;
   if (!destination || *destination == source)
      return;

   old_fence = *destination ? ao46_metal_gallium_fence(*destination) : NULL;
   new_fence = source ? ao46_metal_gallium_fence(source) : NULL;
   if (pipe_reference(old_fence ? &old_fence->reference : NULL,
                      new_fence ? &new_fence->reference : NULL))
      ao46_metal_gallium_fence_destroy(old_fence);
   *destination = source;
}

static bool
ao46_metal_gallium_fence_finish(struct pipe_screen *screen,
                                struct pipe_context *context,
                                struct pipe_fence_handle *fence,
                                uint64_t timeout)
{
   struct AO46MetalGalliumFence *ao46_fence;

   (void)screen;
   (void)context;
   if (!fence)
      return true;

   ao46_fence = ao46_metal_gallium_fence(fence);
   if (timeout == 0)
      return AO46MetalSubmissionIsComplete(&ao46_fence->submission);

   if (timeout != UINT64_MAX) {
      struct timespec start;
      struct timespec now;

      if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
         return false;

      do {
         struct timespec sleep_time = {.tv_nsec = 1000000};
         time_t seconds;
         long nanoseconds;
         uint64_t elapsed;

         if (AO46MetalSubmissionIsComplete(&ao46_fence->submission))
            return true;
         if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
            return false;

         seconds = now.tv_sec - start.tv_sec;
         nanoseconds = now.tv_nsec - start.tv_nsec;
         if (nanoseconds < 0) {
            --seconds;
            nanoseconds += 1000000000L;
         }
         if (seconds < 0)
            return false;
         elapsed = ((uint64_t)seconds * 1000000000ull) + (uint64_t)nanoseconds;
         if (elapsed >= timeout)
            return false;
         if (timeout - elapsed < (uint64_t)sleep_time.tv_nsec)
            sleep_time.tv_nsec = (long)(timeout - elapsed);
         (void)nanosleep(&sleep_time, NULL);
      } while (true);
   }

   return AO46MetalSubmissionWait(&ao46_fence->submission);
}

static bool
ao46_metal_gallium_wait_for_latest_submission(
   struct AO46MetalGalliumContext *context)
{
   return !context->last_fence ||
          AO46MetalSubmissionWait(&context->last_fence->submission);
}

#if AO46_HAVE_MESA_LIBKK
/* Each operation owns a committed Metal command buffer, so completion is the
 * conservative resource-visibility boundary until encoder-local barriers exist. */
static void
ao46_metal_gallium_memory_barrier(struct pipe_context *context, unsigned flags)
{
   if (!context || flags == 0 || (flags & ~PIPE_BARRIER_ALL) != 0)
      return;

   (void)ao46_metal_gallium_wait_for_latest_submission(
      ao46_metal_gallium_context(context));
}
#endif

/* MTL4 submissions are ordered by the adapter's KK MTLEvent timeline. */
static bool
ao46_metal_gallium_wait_for_submission_backend(
   struct AO46MetalGalliumContext *context, bool uses_mtl4)
{
   return !context || !context->last_fence ||
          context->last_fence->submission.uses_mtl4 == uses_mtl4 ||
          AO46MetalSubmissionWait(&context->last_fence->submission);
}

static void
ao46_metal_gallium_replace_last_fence(
   struct AO46MetalGalliumContext *context,
   struct AO46MetalGalliumFence *new_fence)
{
   struct AO46MetalGalliumFence *old_fence = context->last_fence;

   context->last_fence = new_fence;
   if (old_fence && pipe_reference(&old_fence->reference, NULL))
      ao46_metal_gallium_fence_destroy(old_fence);
}

static bool
ao46_metal_gallium_track_submission(
   struct AO46MetalGalliumContext *context,
   struct AO46MetalSubmission *submission, struct pipe_resource *const *resources,
   size_t resource_count, struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumFence *fence;

   if (!context || !submission || !submission->native_command_buffer ||
       (!resources && resource_count != 0))
      return false;

   fence = calloc(1, sizeof(*fence));
   if (!fence)
      goto fail;

   if (resource_count > 0) {
      fence->resources = calloc(resource_count, sizeof(*fence->resources));
      if (!fence->resources)
         goto fail_with_fence;

      for (size_t i = 0; i < resource_count; ++i) {
         if (!resources[i])
            goto fail_with_fence;
         pipe_resource_reference(&fence->resources[i], resources[i]);
         ++fence->resource_count;
      }
   }

   pipe_reference_init(&fence->reference, 1);
   fence->submission = *submission;
   *submission = (struct AO46MetalSubmission){0};
   ao46_metal_gallium_replace_last_fence(context, fence);
   if (out_fence) {
      context->base.screen->fence_reference(
         context->base.screen, out_fence, (struct pipe_fence_handle *)fence);
   }
   return true;

fail_with_fence:
   ao46_metal_gallium_fence_destroy(fence);
fail:
   (void)AO46MetalSubmissionWait(submission);
   AO46MetalSubmissionDestroy(submission);
   return false;
}

static bool
ao46_metal_gallium_resource_range(struct pipe_resource *resource,
                                  size_t offset, size_t size,
                                  struct AO46MetalGalliumResource **out_resource)
{
   struct AO46MetalGalliumResource *ao46_resource;

   if (!resource || !out_resource || !resource->screen ||
       resource->target != PIPE_BUFFER ||
       offset > resource->width0 || size > resource->width0 - offset)
      return false;

   ao46_resource = ao46_metal_gallium_resource(resource);
   if (!AO46MetalBufferIsCurrent(&ao46_resource->buffer))
      return false;

   *out_resource = ao46_resource;
   return true;
}

static bool
ao46_metal_gallium_texture_resource(
   struct pipe_resource *resource,
   struct AO46MetalGalliumResource **out_resource)
{
   struct AO46MetalGalliumResource *ao46_resource;

   if (!resource || !out_resource || !resource->screen ||
       resource->target != PIPE_TEXTURE_2D || resource->last_level != 0 ||
       resource->depth0 != 1 || resource->array_size != 1)
      return false;

   ao46_resource = ao46_metal_gallium_resource(resource);
   if (!AO46MetalTextureIsCurrent(&ao46_resource->texture))
      return false;

   *out_resource = ao46_resource;
   return true;
}

static bool
ao46_metal_gallium_texture_format(enum pipe_format format,
                                  enum AO46MetalTextureFormat *out_format)
{
   if (!out_format)
      return false;

   switch (format) {
   case PIPE_FORMAT_R8G8B8A8_UNORM:
      *out_format = AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
      return true;
   case PIPE_FORMAT_B8G8R8A8_UNORM:
      *out_format = AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM;
      return true;
   default:
      return false;
   }
}

static void ao46_metal_gallium_context_destroy(struct pipe_context *context);
static void *ao46_metal_gallium_create_sampler_state(
   struct pipe_context *context, const struct pipe_sampler_state *state);
static void ao46_metal_gallium_bind_sampler_states(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned num_samplers, void **samplers);
static void ao46_metal_gallium_delete_sampler_state(struct pipe_context *context,
                                                    void *sampler_state);
static void ao46_metal_gallium_set_sampler_views(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned num_views, unsigned unbind_num_trailing_slots,
   struct pipe_sampler_view **views);
static struct pipe_sampler_view *ao46_metal_gallium_create_sampler_view(
   struct pipe_context *context, struct pipe_resource *texture,
   const struct pipe_sampler_view *template);
static void ao46_metal_gallium_sampler_view_destroy(
   struct pipe_context *context, struct pipe_sampler_view *view);
static void ao46_metal_gallium_resource_copy_region(
   struct pipe_context *context, struct pipe_resource *destination,
   unsigned destination_level, unsigned destination_x, unsigned destination_y,
   unsigned destination_z, struct pipe_resource *source, unsigned source_level,
   const struct pipe_box *source_box);
static void *ao46_metal_gallium_buffer_map(
   struct pipe_context *context, struct pipe_resource *resource, unsigned level,
   unsigned usage, const struct pipe_box *box,
   struct pipe_transfer **out_transfer);
static void ao46_metal_gallium_buffer_unmap(struct pipe_context *context,
                                            struct pipe_transfer *transfer);
static void ao46_metal_gallium_buffer_subdata(
   struct pipe_context *context, struct pipe_resource *resource, unsigned usage,
   unsigned offset, unsigned size, const void *data);
static void ao46_metal_gallium_flush(struct pipe_context *context,
                                     struct pipe_fence_handle **fence,
                                     unsigned flags);
static void ao46_metal_gallium_clear_render_target(
   struct pipe_context *context, struct pipe_surface *destination,
   const union pipe_color_union *color, unsigned destination_x,
   unsigned destination_y, unsigned width, unsigned height,
   bool render_condition_enabled);
static void ao46_metal_gallium_set_framebuffer_state(
   struct pipe_context *context, const struct pipe_framebuffer_state *state);
static void ao46_metal_gallium_set_vertex_buffers(
   struct pipe_context *context, unsigned count,
   const struct pipe_vertex_buffer *buffers);
static void *ao46_metal_gallium_create_vertex_elements_state(
   struct pipe_context *context, unsigned count,
   const struct pipe_vertex_element *elements);
static void ao46_metal_gallium_bind_vertex_elements_state(
   struct pipe_context *context, void *vertex_elements);
static void ao46_metal_gallium_delete_vertex_elements_state(
   struct pipe_context *context, void *vertex_elements);
static void ao46_metal_gallium_set_constant_buffer(
   struct pipe_context *context, mesa_shader_stage shader, uint index,
   const struct pipe_constant_buffer *buffer);
static void ao46_metal_gallium_set_patch_vertices(
   struct pipe_context *context, uint8_t patch_vertices);
static void *ao46_metal_gallium_create_tcs_state(
   struct pipe_context *context, const struct pipe_shader_state *state);
static void ao46_metal_gallium_bind_tcs_state(struct pipe_context *context,
                                              void *shader_state);
static void ao46_metal_gallium_delete_tcs_state(struct pipe_context *context,
                                                void *shader_state);
static void *ao46_metal_gallium_create_tes_state(
   struct pipe_context *context, const struct pipe_shader_state *state);
static void ao46_metal_gallium_bind_tes_state(struct pipe_context *context,
                                              void *shader_state);
static void ao46_metal_gallium_delete_tes_state(struct pipe_context *context,
                                                void *shader_state);
static void ao46_metal_gallium_set_tess_state(
   struct pipe_context *context, const float default_outer_level[4],
   const float default_inner_level[2]);
static struct pipe_stream_output_target *
ao46_metal_gallium_create_stream_output_target(
   struct pipe_context *context, struct pipe_resource *buffer,
   unsigned buffer_offset, unsigned buffer_size);
static void ao46_metal_gallium_stream_output_target_destroy(
   struct pipe_context *context, struct pipe_stream_output_target *target);
static void ao46_metal_gallium_set_stream_output_targets(
   struct pipe_context *context, unsigned num_targets,
   struct pipe_stream_output_target **targets, const unsigned *offsets,
   enum mesa_prim output_prim);
static uint32_t ao46_metal_gallium_stream_output_target_offset(
   struct pipe_stream_output_target *target);
#if AO46_HAVE_MESA_LIBKK
static void *ao46_metal_gallium_create_compute_state(
   struct pipe_context *context, const struct pipe_compute_state *state);
static void ao46_metal_gallium_bind_compute_state(struct pipe_context *context,
                                                  void *compute_state);
static void ao46_metal_gallium_delete_compute_state(struct pipe_context *context,
                                                    void *compute_state);
static void ao46_metal_gallium_set_shader_buffers(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned count, const struct pipe_shader_buffer *buffers,
   unsigned writable_bitmask);
static void ao46_metal_gallium_get_compute_state_info(
   struct pipe_context *context, void *compute_state,
   struct pipe_compute_state_object_info *out_info);
static uint32_t ao46_metal_gallium_get_compute_state_subgroup_size(
   struct pipe_context *context, void *compute_state, const uint32_t block[3]);
static void ao46_metal_gallium_launch_grid(struct pipe_context *context,
                                           const struct pipe_grid_info *info);
#endif
static void ao46_metal_gallium_draw_vbo(
   struct pipe_context *context, const struct pipe_draw_info *info,
   unsigned drawid_offset, const struct pipe_draw_indirect_info *indirect,
   const struct pipe_draw_start_count_bias *draws, unsigned num_draws);
static bool ao46_metal_gallium_render_triangle(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumIndirectDrawBinding *indirect_binding,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, uint32_t vertex_start, uint32_t vertex_count,
   uint32_t instance_count, uint32_t base_instance,
   enum AO46MetalPrimitive primitive,
   struct pipe_fence_handle **out_fence);

static const char *
ao46_metal_gallium_get_name(struct pipe_screen *screen)
{
   (void)screen;
   return "AO46 Metal Gallium bootstrap";
}

static const char *
ao46_metal_gallium_get_vendor(struct pipe_screen *screen)
{
   (void)screen;
   return "Khronos_AppleICDs";
}

static const char *
ao46_metal_gallium_get_device_vendor(struct pipe_screen *screen)
{
   (void)screen;
   return "Apple";
}

static int
ao46_metal_gallium_get_screen_fd(struct pipe_screen *screen)
{
   (void)screen;
   return -1;
}

static struct pipe_context *
ao46_metal_gallium_context_create(struct pipe_screen *screen, void *priv,
                                  unsigned flags)
{
   struct AO46MetalGalliumContext *context;

   context = calloc(1, sizeof(*context));
   if (!context)
      return NULL;

   context->base.screen = screen;
   context->base.priv = priv;
   context->base.destroy = ao46_metal_gallium_context_destroy;
   context->base.resource_copy_region = ao46_metal_gallium_resource_copy_region;
   context->base.buffer_map = ao46_metal_gallium_buffer_map;
   context->base.buffer_unmap = ao46_metal_gallium_buffer_unmap;
   context->base.buffer_subdata = ao46_metal_gallium_buffer_subdata;
   context->base.clear_render_target = ao46_metal_gallium_clear_render_target;
   context->base.flush = ao46_metal_gallium_flush;
   context->base.create_sampler_state = ao46_metal_gallium_create_sampler_state;
   context->base.bind_sampler_states = ao46_metal_gallium_bind_sampler_states;
   context->base.delete_sampler_state = ao46_metal_gallium_delete_sampler_state;
   context->base.set_sampler_views = ao46_metal_gallium_set_sampler_views;
   context->base.create_sampler_view = ao46_metal_gallium_create_sampler_view;
   context->base.sampler_view_destroy = ao46_metal_gallium_sampler_view_destroy;
   context->base.sampler_view_release = u_default_sampler_view_release;
   context->base.set_framebuffer_state = ao46_metal_gallium_set_framebuffer_state;
   context->base.set_vertex_buffers = ao46_metal_gallium_set_vertex_buffers;
   context->base.create_vertex_elements_state =
      ao46_metal_gallium_create_vertex_elements_state;
   context->base.bind_vertex_elements_state =
      ao46_metal_gallium_bind_vertex_elements_state;
   context->base.delete_vertex_elements_state =
      ao46_metal_gallium_delete_vertex_elements_state;
   context->base.set_constant_buffer = ao46_metal_gallium_set_constant_buffer;
   context->base.create_tcs_state = ao46_metal_gallium_create_tcs_state;
   context->base.bind_tcs_state = ao46_metal_gallium_bind_tcs_state;
   context->base.delete_tcs_state = ao46_metal_gallium_delete_tcs_state;
   context->base.create_tes_state = ao46_metal_gallium_create_tes_state;
   context->base.bind_tes_state = ao46_metal_gallium_bind_tes_state;
   context->base.delete_tes_state = ao46_metal_gallium_delete_tes_state;
   context->base.set_tess_state = ao46_metal_gallium_set_tess_state;
   context->base.set_patch_vertices = ao46_metal_gallium_set_patch_vertices;
   context->base.create_stream_output_target =
      ao46_metal_gallium_create_stream_output_target;
   context->base.stream_output_target_destroy =
      ao46_metal_gallium_stream_output_target_destroy;
   context->base.set_stream_output_targets =
      ao46_metal_gallium_set_stream_output_targets;
   context->base.stream_output_target_offset =
      ao46_metal_gallium_stream_output_target_offset;
#if AO46_HAVE_MESA_LIBKK
   context->base.create_compute_state = ao46_metal_gallium_create_compute_state;
   context->base.bind_compute_state = ao46_metal_gallium_bind_compute_state;
   context->base.delete_compute_state = ao46_metal_gallium_delete_compute_state;
   context->base.set_shader_buffers = ao46_metal_gallium_set_shader_buffers;
   context->base.get_compute_state_info =
      ao46_metal_gallium_get_compute_state_info;
   context->base.get_compute_state_subgroup_size =
      ao46_metal_gallium_get_compute_state_subgroup_size;
   context->base.launch_grid = ao46_metal_gallium_launch_grid;
   context->base.memory_barrier = ao46_metal_gallium_memory_barrier;
#endif
   context->base.draw_vbo = ao46_metal_gallium_draw_vbo;
   (void)flags;
   return &context->base;
}

static void
ao46_metal_gallium_context_destroy(struct pipe_context *context)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);

   for (unsigned i = 0; i < AO46_METAL_MAX_STATIC_BINDINGS; ++i)
      pipe_sampler_view_reference(&ao46_context->vertex_sampler_views[i], NULL);
   for (unsigned i = 0; i < AO46_METAL_MAX_STATIC_BINDINGS; ++i)
      pipe_sampler_view_reference(&ao46_context->fragment_sampler_views[i], NULL);
   for (unsigned i = 0; i < ao46_context->vertex_buffer_count; ++i)
      pipe_resource_reference(&ao46_context->vertex_buffers[i].buffer.resource,
                              NULL);
   for (unsigned shader = 0; shader < MESA_SHADER_STAGES; ++shader) {
      for (unsigned index = 0; index < AO46_METAL_MAX_UNIFORM_BINDINGS; ++index)
         pipe_resource_reference(
            &ao46_context->constant_buffers[shader][index].buffer, NULL);
   }
   pipe_resource_reference(&ao46_context->poly_tess_draw.parameter_resource,
                           NULL);
   pipe_resource_reference(&ao46_context->poly_tess_draw.index_resource, NULL);
   pipe_resource_reference(&ao46_context->poly_tess_draw.indirect_resource,
                           NULL);
   for (unsigned i = 0; i < PIPE_MAX_SO_BUFFERS; ++i)
      pipe_so_target_reference(&ao46_context->stream_output_targets[i], NULL);
#if AO46_HAVE_MESA_LIBKK
   /* The frontend owns CSOs and must delete them before context destruction. */
   ao46_context->compute_state = NULL;
   for (unsigned i = 0; i < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS; ++i)
      pipe_resource_reference(&ao46_context->compute_shader_buffers[i].buffer,
                              NULL);
#endif
   pipe_resource_reference(&ao46_context->framebuffer.cbufs[0].texture, NULL);
   (void)ao46_metal_gallium_wait_for_latest_submission(ao46_context);
   ao46_metal_gallium_replace_last_fence(ao46_context, NULL);
   free(ao46_context);
}

bool
AO46MetalGalliumContextBindRenderPipeline(
   struct pipe_context *context,
   const struct AO46MetalRenderPipeline *pipeline)
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   if (!pipeline) {
      ao46_context->draw_pipeline = NULL;
      return true;
   }

   if (!pipeline->native_pipeline || !pipeline->adapter ||
       pipeline->adapter != ao46_metal_gallium_screen(context->screen)->adapter ||
       !AO46MetalAdapterIsCurrent(pipeline->adapter) ||
       (pipeline->static_vertex_buffer_mask & UINT16_C(0x0003)) != 0)
      return false;

   ao46_context->draw_pipeline = pipeline;
   return true;
}

bool
AO46MetalGalliumContextCreateRenderPipelineWithCurrentRGB32SamplerViews(
   struct pipe_context *context, struct nir_shader *vertex_nir,
   struct nir_shader *fragment_nir, enum AO46MetalTextureFormat color_format,
   const struct AO46MesaVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, struct AO46MesaRenderPipeline *out_pipeline)
{
   struct AO46MetalGalliumContext *ao46_context;
   const struct AO46MetalGalliumScreen *screen;

   if (!context || !vertex_nir || !fragment_nir || !out_pipeline)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   screen = ao46_metal_gallium_screen(context->screen);
   return AO46MesaRenderPipelineCreateWithDetectedStageRGB32SamplerViews(
      screen->adapter, vertex_nir, fragment_nir, color_format,
      vertex_attributes, vertex_attribute_count,
      ao46_context->vertex_sampler_views, ao46_context->fragment_sampler_views,
      out_pipeline);
}

bool
AO46MetalGalliumContextBindPolyTessellationDraw(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumResource *parameter_resource;
   struct AO46MetalGalliumResource *index_resource;
   struct AO46MetalGalliumResource *indirect_resource;

   if (!context)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   if (!draw) {
      pipe_resource_reference(&ao46_context->poly_tess_draw.parameter_resource,
                              NULL);
      pipe_resource_reference(&ao46_context->poly_tess_draw.index_resource, NULL);
      pipe_resource_reference(&ao46_context->poly_tess_draw.indirect_resource,
                              NULL);
      ao46_context->poly_tess_draw =
         (struct AO46MetalGalliumPolyTessellationDraw){0};
      ao46_context->poly_tess_sequence =
         (struct AO46MetalGalliumPolyTessellationSequence){0};
      return true;
   }

   if (!draw->parameter_resource || !draw->index_resource ||
       !draw->indirect_resource ||
       draw->parameter_resource->screen != context->screen ||
       draw->index_resource->screen != context->screen ||
       draw->indirect_resource->screen != context->screen ||
       draw->parameter_resource->target != PIPE_BUFFER ||
       draw->index_resource->target != PIPE_BUFFER ||
       draw->indirect_resource->target != PIPE_BUFFER ||
       draw->parameter_size == 0 || draw->index_size == 0 ||
       draw->indirect_size != 5 * sizeof(uint32_t) ||
       draw->indirect_offset % sizeof(uint32_t) != 0 ||
       draw->maximum_index_count == 0 ||
       draw->input_patch_size == 0 ||
       draw->input_patch_size > 32 ||
       draw->input_vertex_count < draw->input_patch_size ||
       draw->input_vertex_count % draw->input_patch_size != 0 ||
       draw->maximum_index_count > draw->index_size / sizeof(uint32_t) ||
       !ao46_metal_gallium_resource_range(draw->parameter_resource,
                                           draw->parameter_offset,
                                           draw->parameter_size,
                                           &parameter_resource) ||
       !ao46_metal_gallium_resource_range(draw->index_resource,
                                           draw->index_offset, draw->index_size,
                                           &index_resource) ||
       !ao46_metal_gallium_resource_range(draw->indirect_resource,
                                           draw->indirect_offset,
                                           draw->indirect_size,
                                           &indirect_resource))
      return false;

   pipe_resource_reference(&ao46_context->poly_tess_draw.parameter_resource,
                           draw->parameter_resource);
   pipe_resource_reference(&ao46_context->poly_tess_draw.index_resource,
                           draw->index_resource);
   pipe_resource_reference(&ao46_context->poly_tess_draw.indirect_resource,
                           draw->indirect_resource);
   ao46_context->poly_tess_draw = *draw;
   ao46_context->poly_tess_draw.parameter_resource = draw->parameter_resource;
   ao46_context->poly_tess_draw.index_resource = draw->index_resource;
   ao46_context->poly_tess_draw.indirect_resource = draw->indirect_resource;
   return true;
}

bool
AO46MetalGalliumContextBindPolyTessellationSequence(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence)
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   if (!sequence) {
      ao46_context->poly_tess_sequence =
         (struct AO46MetalGalliumPolyTessellationSequence){0};
      return true;
   }

   if (!sequence->tcs_pipeline || !sequence->kernel_executor || !sequence->plan ||
       sequence->root_size == 0 || sequence->sampler_table_size == 0 ||
       sequence->plan->output_primitive ==
          AO46_MESA_POLY_TESSELLATION_OUTPUT_INVALID)
      return false;

   ao46_context->poly_tess_sequence = *sequence;
   return true;
}

static void
ao46_metal_gallium_tessellation_shader_state_destroy(void *shader_state)
{
   struct AO46MetalGalliumTessellationShaderState *state = shader_state;

   if (!state)
      return;
   ralloc_free(state->nir);
   free(state);
}

static void *
ao46_metal_gallium_create_tessellation_shader_state(
   const struct pipe_shader_state *state, enum mesa_shader_stage expected_stage)
{
   struct AO46MetalGalliumTessellationShaderState *ao46_state;

   if (!state || state->type != PIPE_SHADER_IR_NIR || !state->ir.nir)
      return NULL;

   ao46_state = calloc(1, sizeof(*ao46_state));
   if (!ao46_state)
      return NULL;

   ao46_state->nir = state->ir.nir;
   ao46_state->stage = expected_stage;
   return ao46_state;
}

static void *
ao46_metal_gallium_create_tcs_state(struct pipe_context *context,
                                    const struct pipe_shader_state *state)
{
   (void)context;
   return ao46_metal_gallium_create_tessellation_shader_state(
      state, MESA_SHADER_TESS_CTRL);
}

static void
ao46_metal_gallium_bind_tcs_state(struct pipe_context *context,
                                  void *shader_state)
{
   if (context)
      ao46_metal_gallium_context(context)->tcs_state = shader_state;
}

static void
ao46_metal_gallium_delete_tcs_state(struct pipe_context *context,
                                    void *shader_state)
{
   if (context && ao46_metal_gallium_context(context)->tcs_state == shader_state)
      ao46_metal_gallium_context(context)->tcs_state = NULL;
   ao46_metal_gallium_tessellation_shader_state_destroy(shader_state);
}

static void *
ao46_metal_gallium_create_tes_state(struct pipe_context *context,
                                    const struct pipe_shader_state *state)
{
   (void)context;
   return ao46_metal_gallium_create_tessellation_shader_state(
      state, MESA_SHADER_TESS_EVAL);
}

static void
ao46_metal_gallium_bind_tes_state(struct pipe_context *context,
                                  void *shader_state)
{
   if (context)
      ao46_metal_gallium_context(context)->tes_state = shader_state;
}

static void
ao46_metal_gallium_delete_tes_state(struct pipe_context *context,
                                    void *shader_state)
{
   if (context && ao46_metal_gallium_context(context)->tes_state == shader_state)
      ao46_metal_gallium_context(context)->tes_state = NULL;
   ao46_metal_gallium_tessellation_shader_state_destroy(shader_state);
}

static void
ao46_metal_gallium_set_tess_state(
   struct pipe_context *context, const float default_outer_level[4],
   const float default_inner_level[2])
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context || !default_outer_level || !default_inner_level)
      return;

   ao46_context = ao46_metal_gallium_context(context);
   memcpy(ao46_context->tess_outer_level, default_outer_level,
          sizeof(ao46_context->tess_outer_level));
   memcpy(ao46_context->tess_inner_level, default_inner_level,
          sizeof(ao46_context->tess_inner_level));
   ao46_context->tess_state_set = true;
}

static void
ao46_metal_gallium_set_patch_vertices(struct pipe_context *context,
                                      uint8_t patch_vertices)
{
   if (!context)
      return;

   ao46_metal_gallium_context(context)->patch_vertices =
      patch_vertices >= 1 && patch_vertices <= 32 ? patch_vertices : 0;
}

static void
ao46_metal_gallium_set_framebuffer_state(
   struct pipe_context *context, const struct pipe_framebuffer_state *state)
{
   struct AO46MetalGalliumContext *ao46_context;
   const struct pipe_surface *color;

   if (!context)
      return;

   ao46_context = ao46_metal_gallium_context(context);
   pipe_resource_reference(&ao46_context->framebuffer.cbufs[0].texture, NULL);
   ao46_context->framebuffer = (struct pipe_framebuffer_state){0};

   if (!state || state->nr_cbufs != 1 || state->zsbuf.texture ||
       state->resolve)
      return;

   color = &state->cbufs[0];
   if (!color->texture || color->texture->screen != context->screen ||
       color->level != 0 || color->first_layer != 0 || color->last_layer != 0 ||
       color->format != color->texture->format)
      return;

   ao46_context->framebuffer.width = state->width;
   ao46_context->framebuffer.height = state->height;
   ao46_context->framebuffer.layers = state->layers;
   ao46_context->framebuffer.samples = state->samples;
   ao46_context->framebuffer.nr_cbufs = 1;
   ao46_context->framebuffer.cbufs[0] = *color;
   ao46_context->framebuffer.cbufs[0].texture = NULL;
   pipe_resource_reference(&ao46_context->framebuffer.cbufs[0].texture,
                           color->texture);
}

static void
ao46_metal_gallium_set_vertex_buffers(
   struct pipe_context *context, unsigned count,
   const struct pipe_vertex_buffer *buffers)
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context || count > AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
       (count != 0 && !buffers))
      return;

   for (unsigned i = 0; i < count; ++i) {
      if (buffers[i].is_user_buffer ||
          (buffers[i].buffer.resource &&
           buffers[i].buffer.resource->screen != context->screen))
         return;
   }

   ao46_context = ao46_metal_gallium_context(context);
   for (unsigned i = 0; i < ao46_context->vertex_buffer_count; ++i)
      pipe_resource_reference(&ao46_context->vertex_buffers[i].buffer.resource,
                              NULL);
   memset(ao46_context->vertex_buffers, 0, sizeof(ao46_context->vertex_buffers));

   for (unsigned i = 0; i < count; ++i) {
      ao46_context->vertex_buffers[i] = buffers[i];
      ao46_context->vertex_buffers[i].buffer.resource = NULL;
      pipe_resource_reference(&ao46_context->vertex_buffers[i].buffer.resource,
                              buffers[i].buffer.resource);
   }
   ao46_context->vertex_buffer_count = count;
}

static bool
ao46_metal_gallium_vertex_element_format(
   enum pipe_format format, enum AO46MetalVertexFormat *out_format)
{
   if (!out_format)
      return false;

   switch (format) {
   case PIPE_FORMAT_R32G32_FLOAT:
      *out_format = AO46_METAL_VERTEX_FORMAT_FLOAT2;
      return true;
   case PIPE_FORMAT_R32G32B32A32_FLOAT:
      *out_format = AO46_METAL_VERTEX_FORMAT_FLOAT4;
      return true;
   default:
      return false;
   }
}

static size_t
ao46_metal_gallium_vertex_format_size(enum AO46MetalVertexFormat format)
{
   switch (format) {
   case AO46_METAL_VERTEX_FORMAT_FLOAT2:
      return 2 * sizeof(float);
   case AO46_METAL_VERTEX_FORMAT_FLOAT4:
      return 4 * sizeof(float);
   }

   return 0;
}

static void *
ao46_metal_gallium_create_vertex_elements_state(
   struct pipe_context *context, unsigned count,
   const struct pipe_vertex_element *elements)
{
   struct AO46MetalGalliumVertexElementsState *state;

   if (!context || count > AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
       (count != 0 && !elements))
      return NULL;

   for (unsigned i = 0; i < count; ++i) {
      enum AO46MetalVertexFormat format;
      size_t element_size;

      if (elements[i].dual_slot ||
          elements[i].vertex_buffer_index < 2 ||
          elements[i].vertex_buffer_index > AO46_METAL_MAX_VERTEX_BUFFER_INDEX ||
          elements[i].src_stride == 0 ||
          !ao46_metal_gallium_vertex_element_format(elements[i].src_format,
                                                     &format))
         return NULL;

      element_size = ao46_metal_gallium_vertex_format_size(format);
      if (elements[i].src_offset > elements[i].src_stride ||
          element_size > elements[i].src_stride - elements[i].src_offset)
         return NULL;
   }

   state = calloc(1, sizeof(*state));
   if (!state)
      return NULL;

   state->count = count;
   if (count)
      memcpy(state->elements, elements, count * sizeof(*elements));
   return state;
}

static void
ao46_metal_gallium_bind_vertex_elements_state(
   struct pipe_context *context, void *vertex_elements)
{
   if (!context)
      return;

   ao46_metal_gallium_context(context)->vertex_elements = vertex_elements;
}

static void
ao46_metal_gallium_delete_vertex_elements_state(
   struct pipe_context *context, void *vertex_elements)
{
   if (!vertex_elements)
      return;

   if (context && ao46_metal_gallium_context(context)->vertex_elements ==
                      vertex_elements)
      ao46_metal_gallium_context(context)->vertex_elements = NULL;
   free(vertex_elements);
}

static bool
ao46_metal_gallium_vertex_elements_match_pipeline(
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalGalliumVertexElementsState *state)
{
   if (!state)
      return true;

   if (!pipeline || state->count != pipeline->vertex_attribute_count)
      return false;

   for (unsigned i = 0; i < state->count; ++i) {
      const struct AO46MetalVertexAttribute *attribute =
         &pipeline->vertex_attributes[i];
      enum AO46MetalVertexFormat format;

      if (!ao46_metal_gallium_vertex_element_format(state->elements[i].src_format,
                                                     &format) ||
          attribute->attribute_index != i ||
          attribute->buffer_index != state->elements[i].vertex_buffer_index ||
          attribute->offset != state->elements[i].src_offset ||
          attribute->stride != state->elements[i].src_stride ||
          attribute->instance_divisor != state->elements[i].instance_divisor ||
          attribute->format != format)
         return false;
   }

   return true;
}

static bool
ao46_metal_gallium_uniform_stage_is_supported(mesa_shader_stage shader)
{
   return shader == MESA_SHADER_VERTEX || shader == MESA_SHADER_FRAGMENT;
}

static void
ao46_metal_gallium_set_constant_buffer(
   struct pipe_context *context, mesa_shader_stage shader, uint index,
   const struct pipe_constant_buffer *buffer)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct pipe_constant_buffer *destination;

   if (!context || !ao46_metal_gallium_uniform_stage_is_supported(shader) ||
       index >= AO46_METAL_MAX_UNIFORM_BINDINGS)
      return;

   ao46_context = ao46_metal_gallium_context(context);
   destination = &ao46_context->constant_buffers[shader][index];
   pipe_resource_reference(&destination->buffer, NULL);
   *destination = (struct pipe_constant_buffer){0};

   if (buffer && (buffer->user_buffer ||
                  (buffer->buffer &&
                   buffer->buffer->screen != context->screen)))
      return;

   if (!buffer || !buffer->buffer)
      return;

   *destination = *buffer;
   destination->buffer = NULL;
   pipe_resource_reference(&destination->buffer, buffer->buffer);
}

static struct pipe_stream_output_target *
ao46_metal_gallium_create_stream_output_target(
   struct pipe_context *context, struct pipe_resource *buffer,
   unsigned buffer_offset, unsigned buffer_size)
{
   struct AO46MetalGalliumStreamOutputTarget *target;

   if (!context || !buffer || buffer->screen != context->screen ||
       buffer->target != PIPE_BUFFER || buffer_offset >= buffer->width0 ||
       buffer_size == 0 || buffer_size > buffer->width0 - buffer_offset)
      return NULL;

   target = calloc(1, sizeof(*target));
   if (!target)
      return NULL;

   pipe_reference_init(&target->base.reference, 1);
   pipe_resource_reference(&target->base.buffer, buffer);
   target->base.context = context;
   target->base.buffer_offset = buffer_offset;
   target->base.buffer_size = buffer_size;
   target->write_offset = buffer_offset;
   return &target->base;
}

static void
ao46_metal_gallium_stream_output_target_destroy(
   struct pipe_context *context, struct pipe_stream_output_target *target)
{
   (void)context;
   if (!target)
      return;

   pipe_resource_reference(&target->buffer, NULL);
   free(target);
}

static uint32_t
ao46_metal_gallium_stream_output_target_offset(
   struct pipe_stream_output_target *target)
{
   const struct AO46MetalGalliumStreamOutputTarget *ao46_target =
      (const struct AO46MetalGalliumStreamOutputTarget *)target;

   return ao46_target ? ao46_target->write_offset : 0;
}

static void
ao46_metal_gallium_set_stream_output_targets(
   struct pipe_context *context, unsigned num_targets,
   struct pipe_stream_output_target **targets, const unsigned *offsets,
   enum mesa_prim output_prim)
{
   struct AO46MetalGalliumContext *ao46_context;
   unsigned i;

   if (!context || num_targets > PIPE_MAX_SO_BUFFERS ||
       (num_targets != 0 && !targets))
      return;

   for (i = 0; i < num_targets; ++i) {
      struct AO46MetalGalliumStreamOutputTarget *target =
         (struct AO46MetalGalliumStreamOutputTarget *)targets[i];
      unsigned write_offset;

      if (!target)
         continue;
      if (target->base.context != context || !target->base.buffer ||
          target->base.buffer->screen != context->screen)
         return;

      write_offset = offsets ? offsets[i] : target->write_offset;
      if (write_offset == (unsigned)-1)
         continue;
      if (write_offset < target->base.buffer_offset ||
          write_offset > target->base.buffer_offset + target->base.buffer_size)
         return;
   }

   ao46_context = ao46_metal_gallium_context(context);
   for (i = 0; i < num_targets; ++i) {
      struct AO46MetalGalliumStreamOutputTarget *target =
         (struct AO46MetalGalliumStreamOutputTarget *)targets[i];

      if (target && offsets && offsets[i] != (unsigned)-1)
         target->write_offset = offsets[i];

      pipe_so_target_reference(&ao46_context->stream_output_targets[i],
                               targets[i]);
      ao46_context->stream_output_offsets[i] = target ? target->write_offset : 0;
   }
   for (; i < PIPE_MAX_SO_BUFFERS; ++i) {
      pipe_so_target_reference(&ao46_context->stream_output_targets[i], NULL);
      ao46_context->stream_output_offsets[i] = 0;
   }

   ao46_context->num_stream_output_targets = num_targets;
   ao46_context->stream_output_prim = output_prim;
}

#if AO46_HAVE_MESA_LIBKK
static void *
ao46_metal_gallium_create_compute_state(
   struct pipe_context *context, const struct pipe_compute_state *state)
{
   const struct AO46MetalGalliumScreen *screen;
   const struct nir_shader *source;
   struct AO46MetalGalliumComputeState *compute_state;

   if (!context || !state || state->ir_type != PIPE_SHADER_IR_NIR ||
       !state->prog || state->static_shared_mem != 0)
      return NULL;

   source = state->prog;
   if (source->info.stage != MESA_SHADER_COMPUTE || source->info.shared_size != 0)
      return NULL;

   compute_state = calloc(1, sizeof(*compute_state));
   if (!compute_state)
      return NULL;

   compute_state->nir = nir_shader_clone(NULL, source);
   screen = ao46_metal_gallium_screen(context->screen);
   if (!compute_state->nir ||
       !AO46MesaComputePipelineCreate(screen->adapter, compute_state->nir,
                                      &compute_state->pipeline)) {
      ralloc_free(compute_state->nir);
      free(compute_state);
      return NULL;
   }

   return compute_state;
}

static void
ao46_metal_gallium_bind_compute_state(struct pipe_context *context,
                                      void *compute_state)
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context)
      return;

   ao46_context = ao46_metal_gallium_context(context);
   ao46_context->compute_state = compute_state;
}

static void
ao46_metal_gallium_delete_compute_state(struct pipe_context *context,
                                        void *compute_state)
{
   struct AO46MetalGalliumComputeState *state = compute_state;

   if (!state)
      return;

   if (context && ao46_metal_gallium_context(context)->compute_state == state)
      ao46_metal_gallium_context(context)->compute_state = NULL;

   AO46MesaComputePipelineDestroy(&state->pipeline);
   ralloc_free(state->nir);
   free(state);
}

static void
ao46_metal_gallium_set_shader_buffers(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned count, const struct pipe_shader_buffer *buffers,
   unsigned writable_bitmask)
{
   struct AO46MetalGalliumContext *ao46_context;
   uint32_t changed_mask;

   if (!context || shader != MESA_SHADER_COMPUTE ||
       start_slot > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
       count > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS - start_slot)
      return;

   for (unsigned i = 0; i < count; ++i) {
      struct AO46MetalGalliumResource *resource;
      const struct pipe_shader_buffer *buffer = buffers ? &buffers[i] : NULL;

      if (!buffer || !buffer->buffer)
         continue;

      if (buffer->buffer->screen != context->screen ||
          buffer->buffer->target != PIPE_BUFFER || buffer->buffer_size == 0 ||
          !ao46_metal_gallium_resource_range(buffer->buffer,
                                              buffer->buffer_offset,
                                              buffer->buffer_size, &resource))
         return;
   }

   ao46_context = ao46_metal_gallium_context(context);
   changed_mask = ((UINT32_C(1) << count) - 1) << start_slot;
   for (unsigned i = 0; i < count; ++i) {
      const struct pipe_shader_buffer *buffer = buffers ? &buffers[i] : NULL;
      struct pipe_shader_buffer *destination =
         &ao46_context->compute_shader_buffers[start_slot + i];

      pipe_resource_reference(&destination->buffer,
                              buffer ? buffer->buffer : NULL);
      destination->buffer_offset = buffer && buffer->buffer ?
         buffer->buffer_offset : 0;
      destination->buffer_size = buffer && buffer->buffer ?
         buffer->buffer_size : 0;
   }

   ao46_context->compute_shader_buffer_mask &= ~changed_mask;
   ao46_context->compute_shader_buffer_writable_mask &= ~changed_mask;
   for (unsigned i = 0; i < count; ++i) {
      const uint32_t bit = UINT32_C(1) << (start_slot + i);

      if (buffers && buffers[i].buffer) {
         ao46_context->compute_shader_buffer_mask |= bit;
         if (writable_bitmask & (UINT32_C(1) << i))
            ao46_context->compute_shader_buffer_writable_mask |= bit;
      }
   }
}

static void
ao46_metal_gallium_get_compute_state_info(
   struct pipe_context *context, void *compute_state,
   struct pipe_compute_state_object_info *out_info)
{
   const struct AO46MetalGalliumComputeState *state = compute_state;

   (void)context;
   if (!out_info)
      return;

   *out_info = (struct pipe_compute_state_object_info){0};
   if (!state)
      return;

   out_info->max_threads = state->pipeline.reflection.max_threads_per_threadgroup;
   out_info->preferred_simd_size = state->pipeline.reflection.thread_execution_width;
}

static uint32_t
ao46_metal_gallium_get_compute_state_subgroup_size(
   struct pipe_context *context, void *compute_state, const uint32_t block[3])
{
   const struct AO46MetalGalliumComputeState *state = compute_state;

   (void)context;
   (void)block;
   return state ? state->pipeline.reflection.thread_execution_width : 0;
}

static bool
ao46_metal_gallium_compute_grid_size(uint block_count, uint block_size,
                                     uint32_t *out_size)
{
   const uint64_t size = (uint64_t)block_count * block_size;

   if (block_count == 0 || block_size == 0 || size > UINT32_MAX)
      return false;

   *out_size = (uint32_t)size;
   return true;
}

static void
ao46_metal_gallium_launch_grid(struct pipe_context *context,
                               const struct pipe_grid_info *info)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumComputeState *state;
   struct pipe_resource *resources[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   uint32_t offsets[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS] = {0};
   uint32_t indices[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS] = {0};
   bool writable[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS] = {0};
   struct pipe_fence_handle *fence = NULL;
   struct AO46MetalGalliumResource *indirect_resource = NULL;
   uint32_t grid_size[3] = {0};
   uint32_t required_mask;
   uint32_t resource_count = 0;

   if (!context || !info || info->work_dim == 0 || info->work_dim > 3 ||
       info->variable_shared_mem != 0 ||
       info->indirect_draw_count || info->draw_count != 0 ||
       info->num_globals > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
       (info->num_globals != 0 && !info->globals))
      return;

   ao46_context = ao46_metal_gallium_context(context);
   state = ao46_context->compute_state;
   if (!state)
      return;

   for (unsigned axis = 0; axis < 3; ++axis) {
      const uint32_t expected_block = state->pipeline.reflection.local_size[axis];

      if (expected_block == 0 || info->block[axis] != expected_block ||
          info->grid_base[axis] != 0 ||
          (info->last_block[axis] != 0 &&
           info->last_block[axis] != info->block[axis]) ||
          (!info->indirect &&
           ((axis >= info->work_dim && info->grid[axis] != 1) ||
            !ao46_metal_gallium_compute_grid_size(info->grid[axis],
                                                   info->block[axis],
                                                   &grid_size[axis]))))
         return;
   }

   if (info->indirect &&
       (info->indirect->screen != context->screen ||
        info->indirect->target != PIPE_BUFFER || info->indirect_stride != 0 ||
        !(info->indirect->bind & PIPE_BIND_COMMAND_ARGS_BUFFER) ||
        info->indirect_offset % sizeof(uint32_t) != 0 ||
        !ao46_metal_gallium_resource_range(
           info->indirect, info->indirect_offset, 3 * sizeof(uint32_t),
           &indirect_resource)))
      return;

   required_mask = state->pipeline.reflection.required_buffer_mask;
   if (info->num_globals != 0) {
      if ((required_mask >> info->num_globals) != 0)
         return;

      for (uint32_t i = 0; i < info->num_globals; ++i) {
         if (!info->globals[i] || info->globals[i]->screen != context->screen ||
             info->globals[i]->target != PIPE_BUFFER)
            return;

         resources[i] = info->globals[i];
         indices[i] = i;
      }
      resource_count = info->num_globals;
   } else {
      if ((ao46_context->compute_shader_buffer_mask & required_mask) !=
          required_mask)
         return;

      for (uint32_t slot = 0;
           slot < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS; ++slot) {
         const uint32_t bit = UINT32_C(1) << slot;
         const struct pipe_shader_buffer *buffer;
         struct AO46MetalGalliumResource *resource;

         if (!(required_mask & bit))
            continue;

         buffer = &ao46_context->compute_shader_buffers[slot];
         if (!buffer->buffer || buffer->buffer_size == 0 ||
             !ao46_metal_gallium_resource_range(buffer->buffer,
                                                 buffer->buffer_offset,
                                                 buffer->buffer_size,
                                                 &resource))
            return;

         resources[resource_count] = buffer->buffer;
         offsets[resource_count] = buffer->buffer_offset;
         indices[resource_count++] = slot;
         writable[resource_count - 1] =
            (ao46_context->compute_shader_buffer_writable_mask & bit) != 0;
      }
   }

   if (!(info->indirect
            ? AO46MesaComputePipelineDispatchIndirectWithAccess(
                 &state->pipeline, context, resources, offsets, indices,
                 info->num_globals == 0 ? writable : NULL, resource_count,
                 info->indirect, info->indirect_offset, &fence)
            : AO46MesaComputePipelineDispatchWithAccess(
                 &state->pipeline, context, resources, offsets, indices,
                 info->num_globals == 0 ? writable : NULL, resource_count,
                 grid_size[0], grid_size[1], grid_size[2], &fence)) ||
       !fence)
      return;

   context->screen->fence_reference(context->screen, &fence, NULL);
}
#endif

struct AO46MetalGalliumDrawIndirectArguments {
   uint32_t vertex_count;
   uint32_t instance_count;
   uint32_t vertex_start;
   uint32_t base_instance;
};

struct AO46MetalGalliumDrawIndexedIndirectArguments {
   uint32_t index_count;
   uint32_t instance_count;
   uint32_t index_start;
   int32_t base_vertex;
   uint32_t base_instance;
};

#if AO46_HAVE_MESA_LIBKK
/*
 * Runs Mesa poly's pre-TES stages against one retained package. Every stage
 * shares the adapter's serial queue; only the terminal TES render fence is
 * exposed after the package has reached the draw path.
 */
static bool
ao46_metal_gallium_dispatch_poly_tessellation(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence)
{
   const struct AO46MetalAdapter *adapter;
   const struct AO46MesaPolyKernelSource *prefix_source;
   enum AO46MesaPolyKernel tessellation_kernel;
   enum AO46MetalPrimitive output_primitive;
   struct AO46MetalGalliumResource *root_resource;
   struct AO46MetalGalliumResource *count_root_resource;
   struct AO46MetalGalliumResource *sampler_resource;
   struct pipe_resource *const tcs_resources[] = {
      draw->parameter_resource,
      draw->parameter_resource,
      draw->parameter_resource,
   };
   const uint32_t tcs_offsets[] = {
      sequence->root_offset,
      sequence->sampler_table_offset,
      (uint32_t)draw->parameter_offset,
   };
   const uint32_t tcs_indices[] = {0, 1, 3};
   struct pipe_fence_handle *fence = NULL;
   bool submitted = false;

   if (!context || !draw || !sequence || !sequence->tcs_pipeline ||
       !sequence->kernel_executor || !sequence->plan ||
       draw->parameter_offset > UINT32_MAX ||
       sequence->count_root_offset > UINT32_MAX ||
       sequence->root_offset > UINT32_MAX ||
       sequence->sampler_table_offset > UINT32_MAX ||
       !draw->parameter_resource ||
       !ao46_metal_gallium_resource_range(
          draw->parameter_resource, sequence->root_offset, sequence->root_size,
          &root_resource) ||
       !ao46_metal_gallium_resource_range(
          draw->parameter_resource, sequence->count_root_offset,
          sequence->root_size, &count_root_resource) ||
       !ao46_metal_gallium_resource_range(
          draw->parameter_resource, sequence->sampler_table_offset,
          sequence->sampler_table_size, &sampler_resource))
      return false;

   adapter = ao46_metal_gallium_screen(context->screen)->adapter;
   if (sequence->tcs_pipeline->metal_pipeline.adapter != adapter ||
       !sequence->tcs_pipeline->metal_pipeline.native_pipeline ||
       sequence->kernel_executor->adapter != adapter ||
       sequence->plan->parameter_buffer_binding != 3 ||
       sequence->plan->parameter_bytes > draw->parameter_size ||
       sequence->plan->input_patch_size != draw->input_patch_size ||
       sequence->plan->patches_per_instance !=
          draw->input_vertex_count / draw->input_patch_size ||
       sequence->plan->nr_patches !=
          draw->input_vertex_count / draw->input_patch_size ||
       sequence->plan->output_patch_size == 0 ||
       sequence->plan->nr_patches == 0 ||
       sequence->plan->tcs_grid_width == 0 ||
       sequence->plan->tess_grid_width == 0 ||
       !sequence->plan->requires_prefix_sum ||
       !sequence->plan->requires_dynamic_index_heap ||
       !ao46_metal_gallium_tessellation_states_match_plan(
          ao46_metal_gallium_context(context), sequence->plan) ||
       !ao46_metal_gallium_poly_kernel_for_plan(sequence->plan,
                                                 &tessellation_kernel) ||
       !ao46_metal_gallium_poly_output_primitive(sequence->plan,
                                                  &output_primitive) ||
       draw->maximum_index_count <
          ao46_metal_gallium_poly_output_minimum_index_count(output_primitive) ||
       !root_resource->buffer.cpu_mapping ||
       !count_root_resource->buffer.cpu_mapping ||
       !sampler_resource->buffer.cpu_mapping)
      return false;

   prefix_source = &sequence->kernel_executor->sources[
      AO46_MESA_POLY_KERNEL_PREFIX_SUM];
   if (prefix_source->workgroup_size[0] == 0 ||
       prefix_source->workgroup_size[1] == 0 ||
       prefix_source->workgroup_size[2] == 0)
      return false;

   submitted = AO46MesaComputePipelineDispatch(
      sequence->tcs_pipeline, context, tcs_resources, tcs_offsets, tcs_indices,
      3, sequence->plan->tcs_grid_width, 1, 1, &fence);
   if (!submitted || !fence)
      goto out;
   context->screen->fence_reference(context->screen, &fence, NULL);

   submitted = AO46MesaPolyKernelExecutorSubmitGallium(
      sequence->kernel_executor, tessellation_kernel, context,
      draw->parameter_resource, sequence->count_root_offset,
      draw->parameter_resource, sequence->sampler_table_offset,
      sequence->plan->tess_grid_width, 1, 1, &fence);
   if (!submitted || !fence)
      goto out;
   context->screen->fence_reference(context->screen, &fence, NULL);

   submitted = AO46MesaPolyKernelExecutorSubmitGallium(
      sequence->kernel_executor, AO46_MESA_POLY_KERNEL_PREFIX_SUM, context,
      draw->parameter_resource, sequence->root_offset, draw->parameter_resource,
      sequence->sampler_table_offset, prefix_source->workgroup_size[0], 1, 1,
      &fence);
   if (!submitted || !fence)
      goto out;
   context->screen->fence_reference(context->screen, &fence, NULL);

   submitted = AO46MesaPolyKernelExecutorSubmitGallium(
      sequence->kernel_executor, tessellation_kernel, context,
      draw->parameter_resource, sequence->root_offset, draw->parameter_resource,
      sequence->sampler_table_offset, sequence->plan->tess_grid_width, 1, 1,
      &fence);
   if (!submitted || !fence)
      goto out;
   context->screen->fence_reference(context->screen, &fence, NULL);
   return true;

out:
   if (fence)
      context->screen->fence_reference(context->screen, &fence, NULL);
   return false;
}
#else
static bool
ao46_metal_gallium_dispatch_poly_tessellation(
   struct pipe_context *context,
   const struct AO46MetalGalliumPolyTessellationDraw *draw,
   const struct AO46MetalGalliumPolyTessellationSequence *sequence)
{
   (void)context;
   (void)draw;
   (void)sequence;
   return false;
}
#endif

/*
 * The bounded state-tracker path accepts one direct draw or a bounded sequence
 * of host-visible indirect records. Metal consumes every record natively; CPU
 * inspection only validates the range/resource contract before submission.
 */
static void
ao46_metal_gallium_draw_vbo(
   struct pipe_context *context, const struct pipe_draw_info *info,
   unsigned drawid_offset, const struct pipe_draw_indirect_info *indirect,
   const struct pipe_draw_start_count_bias *draws, unsigned num_draws)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumVertexBinding
      vertex_bindings[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
   struct AO46MetalGalliumStaticBufferBinding
      static_vertex_bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   struct AO46MetalGalliumUniformBufferBinding
      uniform_bindings[AO46_METAL_MAX_UNIFORM_BINDINGS];
   struct AO46MetalGalliumStaticBufferBinding poly_tess_parameter_binding;
   struct AO46MetalGalliumIndexBufferBinding index_binding;
   struct AO46MetalGalliumIndirectDrawBinding indirect_binding;
   const struct AO46MetalGalliumIndexBufferBinding *index = NULL;
   const struct AO46MetalGalliumIndirectDrawBinding *indirect_draw = NULL;
   const struct AO46MetalGalliumPolyTessellationDraw *poly_draw = NULL;
   const struct AO46MetalGalliumPolyTessellationSequence *poly_sequence = NULL;
   struct AO46MetalGalliumResource *indirect_resource;
   struct AO46MetalGalliumResource *indirect_count_resource;
   struct pipe_fence_handle *fence = NULL;
   size_t vertex_binding_count = 0;
   size_t static_vertex_binding_count = 0;
   size_t uniform_binding_count = 0;
   size_t index_size = 0;
   enum AO46MetalIndexFormat index_format = AO46_METAL_INDEX_FORMAT_UINT16;
   uint32_t vertex_start = 0;
   uint32_t vertex_count = 0;
   uint32_t instance_count = 0;
   uint32_t base_instance = 0;
   size_t indirect_argument_size = 0;
   size_t indirect_argument_stride = 0;
   size_t indirect_required_size = 0;
   enum AO46MetalPrimitive primitive = AO46_METAL_PRIMITIVE_TRIANGLES;
   bool indirect_gpu_generated = false;
   bool poly_tess_draw = false;

   if (!context || !info || num_draws != 1 || drawid_offset != 0 ||
       info->increment_draw_id || info->index_bias_varies ||
       (info->mode != MESA_PRIM_TRIANGLES && info->mode != MESA_PRIM_PATCHES) ||
       info->has_user_indices)
      return;

   poly_tess_draw = info->mode == MESA_PRIM_PATCHES;

   if (poly_tess_draw) {
      ao46_context = ao46_metal_gallium_context(context);
      poly_draw = &ao46_context->poly_tess_draw;
      poly_sequence = &ao46_context->poly_tess_sequence;
      if (indirect || info->index_size != 0 || !draws ||
          info->instance_count != 1 || info->start_instance != 0 ||
          draws->start != 0 || draws->index_bias != 0 ||
          !poly_draw->parameter_resource || !poly_draw->index_resource ||
          !poly_draw->indirect_resource ||
          ao46_context->patch_vertices != poly_draw->input_patch_size ||
          draws->count != poly_draw->input_vertex_count)
         return;
   } else if (indirect) {
      indirect_argument_size = info->index_size != 0
                                  ? sizeof(struct AO46MetalGalliumDrawIndexedIndirectArguments)
                                  : sizeof(struct AO46MetalGalliumDrawIndirectArguments);
      indirect_argument_stride = indirect->stride ? indirect->stride
                                                   : indirect_argument_size;

      if (!indirect->buffer || indirect->buffer->screen != context->screen ||
          !(indirect->buffer->bind & PIPE_BIND_COMMAND_ARGS_BUFFER) ||
          indirect->draw_count == 0 ||
          indirect->draw_count > AO46_METAL_MAX_INDIRECT_DRAWS ||
          indirect->count_from_stream_output || indirect->offset % sizeof(uint32_t) != 0 ||
          indirect_argument_stride < indirect_argument_size ||
          indirect_argument_stride % sizeof(uint32_t) != 0 ||
          (indirect->draw_count > 1 &&
           indirect->stride != indirect_argument_size) ||
          indirect->draw_count - 1 >
             (SIZE_MAX - indirect_argument_size) / indirect_argument_stride ||
          info->primitive_restart)
         return;

      if (indirect->indirect_draw_count) {
         if (indirect->indirect_draw_count->screen != context->screen ||
             indirect->indirect_draw_count->target != PIPE_BUFFER ||
             !(indirect->indirect_draw_count->bind &
               PIPE_BIND_COMMAND_ARGS_BUFFER) ||
             indirect->indirect_draw_count_offset % sizeof(uint32_t) != 0 ||
             !ao46_metal_gallium_resource_range(
                indirect->indirect_draw_count,
                indirect->indirect_draw_count_offset, sizeof(uint32_t),
                &indirect_count_resource))
            return;
      }

      indirect_required_size =
         (size_t)(indirect->draw_count - 1) * indirect_argument_stride +
         indirect_argument_size;
      if (!ao46_metal_gallium_resource_range(indirect->buffer, indirect->offset,
                                             indirect_required_size,
                                             &indirect_resource))
         return;

      /*
       * A shader-writable command buffer may contain a Mesa-produced single
       * indexed record. Metal consumes it directly, so the driver must not
       * map it just to reconstruct the already-GPU-owned arguments.
       */
      indirect_gpu_generated =
         !indirect_resource->buffer.cpu_mapping ||
         (indirect->buffer->bind & PIPE_BIND_SHADER_BUFFER) != 0;
      if (indirect_gpu_generated &&
          (indirect->draw_count != 1 || indirect->indirect_draw_count ||
           info->index_size != sizeof(uint32_t)))
         return;
      if (!indirect_gpu_generated && !indirect_resource->buffer.cpu_mapping)
         return;
   } else if (!draws || info->instance_count == 0) {
      return;
   }

   ao46_context = ao46_metal_gallium_context(context);
   if (!ao46_context->draw_pipeline ||
       !ao46_context->framebuffer.cbufs[0].texture ||
       !ao46_metal_gallium_vertex_elements_match_pipeline(
          ao46_context->draw_pipeline, ao46_context->vertex_elements))
      return;

   if (poly_tess_draw) {
      if (ao46_context->draw_pipeline->static_vertex_buffer_mask !=
          (UINT16_C(1) << 3))
         return;
      poly_tess_parameter_binding =
         (struct AO46MetalGalliumStaticBufferBinding){
            .resource = poly_draw->parameter_resource,
            .offset = poly_draw->parameter_offset,
            .size = poly_draw->parameter_size,
            .index = 3,
         };
      static_vertex_bindings[static_vertex_binding_count++] =
         poly_tess_parameter_binding;
      index_binding = (struct AO46MetalGalliumIndexBufferBinding){
         .resource = poly_draw->index_resource,
         .offset = poly_draw->index_offset,
         .size = poly_draw->index_size,
         .count = poly_draw->maximum_index_count,
         .format = AO46_METAL_INDEX_FORMAT_UINT32,
      };
      index = &index_binding;
      indirect_binding = (struct AO46MetalGalliumIndirectDrawBinding){
         .resource = poly_draw->indirect_resource,
         .offset = poly_draw->indirect_offset,
         .draw_count = 1,
         .stride = 5 * sizeof(uint32_t),
         .gpu_generated = true,
         .maximum_index_count = poly_draw->maximum_index_count,
      };
      indirect_draw = &indirect_binding;
   } else if (ao46_context->draw_pipeline->static_vertex_buffer_mask != 0) {
      struct AO46MesaRGB32BufferTextureBinding
         rgb32_bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
      uint32_t rgb32_binding_count = 0;

      if (!AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
             ao46_context->vertex_sampler_views,
             ao46_context->draw_pipeline->static_vertex_buffer_mask,
             rgb32_bindings, AO46_METAL_MAX_STATIC_BUFFER_BINDINGS,
             &rgb32_binding_count))
         return;

      for (uint32_t binding_index = 0; binding_index < rgb32_binding_count;
           ++binding_index) {
         const struct AO46MesaRGB32BufferTextureBinding *rgb32_binding =
            &rgb32_bindings[binding_index];
         struct pipe_sampler_view *base_view =
            ao46_context->vertex_sampler_views[rgb32_binding->buffer_binding];
         struct AO46MetalGalliumSamplerView *view;

         if (!base_view || !base_view->texture ||
             base_view->texture->target != PIPE_BUFFER)
            return;

         view = (struct AO46MetalGalliumSamplerView *)base_view;
         if (!view->buffer_view || view->buffer_offset != base_view->u.buf.offset ||
             view->buffer_size == 0 ||
             view->buffer_size !=
                (size_t)rgb32_binding->element_count * 3 * sizeof(uint32_t))
            return;

         static_vertex_bindings[static_vertex_binding_count++] =
            (struct AO46MetalGalliumStaticBufferBinding){
               .resource = base_view->texture,
               .offset = view->buffer_offset,
               .size = view->buffer_size,
               .index = rgb32_binding->buffer_binding,
            };
      }
   }

   for (unsigned index = 0; index < AO46_METAL_MAX_UNIFORM_BINDINGS; ++index) {
      const uint16_t bit = UINT16_C(1) << index;
      const struct pipe_constant_buffer *vertex_buffer =
         &ao46_context->constant_buffers[MESA_SHADER_VERTEX][index];
      const struct pipe_constant_buffer *fragment_buffer =
         &ao46_context->constant_buffers[MESA_SHADER_FRAGMENT][index];
      const struct pipe_constant_buffer *buffer = NULL;

      if (!(ao46_context->draw_pipeline->uniform_mask & bit))
         continue;

      if (vertex_buffer->buffer && fragment_buffer->buffer &&
          (vertex_buffer->buffer != fragment_buffer->buffer ||
           vertex_buffer->buffer_offset != fragment_buffer->buffer_offset ||
           vertex_buffer->buffer_size != fragment_buffer->buffer_size))
         return;

      buffer = vertex_buffer->buffer ? vertex_buffer : fragment_buffer;
      if (!buffer->buffer || buffer->buffer_size == 0)
         return;

      uniform_bindings[uniform_binding_count++] =
         (struct AO46MetalGalliumUniformBufferBinding){
            .resource = buffer->buffer,
            .offset = buffer->buffer_offset,
            .size = buffer->buffer_size,
            .binding = index,
         };
   }

   for (size_t i = 0;
        i < ao46_context->draw_pipeline->vertex_attribute_count; ++i) {
      const struct AO46MetalVertexAttribute *attribute =
         &ao46_context->draw_pipeline->vertex_attributes[i];
      const struct pipe_vertex_buffer *buffer;
      bool already_bound = false;

      if (attribute->buffer_index >= ao46_context->vertex_buffer_count)
         return;
      buffer = &ao46_context->vertex_buffers[attribute->buffer_index];
      if (!buffer->buffer.resource)
         return;

      for (size_t j = 0; j < vertex_binding_count; ++j) {
         if (vertex_bindings[j].index == attribute->buffer_index) {
            already_bound = true;
            break;
         }
      }
      if (already_bound)
         continue;

      vertex_bindings[vertex_binding_count++] =
         (struct AO46MetalGalliumVertexBinding){
            .resource = buffer->buffer.resource,
            .offset = buffer->buffer_offset,
            .index = attribute->buffer_index,
         };
   }

   switch (info->index_size) {
   case 0:
      if (info->primitive_restart || (!indirect && draws->index_bias != 0))
         return;
      break;
   case 2:
      index_size = sizeof(uint16_t);
      index_format = AO46_METAL_INDEX_FORMAT_UINT16;
      break;
   case 4:
      index_size = sizeof(uint32_t);
      index_format = AO46_METAL_INDEX_FORMAT_UINT32;
      break;
   default:
      return;
   }

   if (poly_tess_draw) {
      vertex_count = 0;
      instance_count = 0;
   } else if (indirect) {
      indirect_binding = (struct AO46MetalGalliumIndirectDrawBinding){
         .resource = indirect->buffer,
         .offset = indirect->offset,
         .draw_count = indirect->draw_count,
         .stride = indirect->stride,
         .count_resource = indirect->indirect_draw_count,
         .count_offset = indirect->indirect_draw_count_offset,
         .gpu_generated = indirect_gpu_generated,
      };
      indirect_draw = &indirect_binding;

      if (info->index_size != 0) {
         if (!info->index.resource ||
             info->index.resource->screen != context->screen ||
             info->index.resource->width0 % index_size != 0)
            return;

         index_binding = (struct AO46MetalGalliumIndexBufferBinding){
            .resource = info->index.resource,
            .offset = 0,
            .size = info->index.resource->width0,
            .count = info->index.resource->width0 / index_size,
            .format = index_format,
         };
         index = &index_binding;
         if (indirect_gpu_generated) {
            indirect_binding.maximum_index_count = index_binding.count;
         }
      }
   } else {
      vertex_start = info->index_size == 0 ? draws->start : 0;
      vertex_count = draws->count;
      instance_count = info->instance_count;
      base_instance = info->start_instance;

      if (info->index_size != 0) {
         if (!info->index.resource ||
             info->index.resource->screen != context->screen ||
             draws->start > SIZE_MAX / index_size ||
             draws->count > SIZE_MAX / index_size)
            return;

         index_binding.resource = info->index.resource;
         index_binding.offset = (size_t)draws->start * index_size;
         index_binding.size = (size_t)draws->count * index_size;
         index_binding.count = draws->count;
         index_binding.format = index_format;
         index_binding.base_vertex = draws->index_bias;
         index_binding.primitive_restart = info->primitive_restart;
         index_binding.restart_index = info->restart_index;
         index = &index_binding;
      }
   }

   if (poly_tess_draw &&
       !ao46_metal_gallium_dispatch_poly_tessellation(context, poly_draw,
                                                       poly_sequence))
      return;
   if (poly_tess_draw &&
       !ao46_metal_gallium_poly_output_primitive(poly_sequence->plan,
                                                  &primitive))
      return;

   if (!ao46_metal_gallium_render_triangle(
          context, ao46_context->draw_pipeline, &ao46_context->framebuffer.cbufs[0],
          uniform_binding_count ? uniform_bindings : NULL, uniform_binding_count,
          index, indirect_draw,
          static_vertex_binding_count ? static_vertex_bindings : NULL,
          static_vertex_binding_count,
          vertex_binding_count ? vertex_bindings : NULL, vertex_binding_count,
          vertex_start, vertex_count, instance_count, base_instance,
          primitive,
          &fence))
      return;

   context->screen->fence_reference(context->screen, &fence, NULL);
}

static bool
ao46_metal_gallium_sampler_state_is_supported(
   const struct pipe_sampler_state *state)
{
   return state && state->wrap_s == PIPE_TEX_WRAP_CLAMP_TO_EDGE &&
          state->wrap_t == PIPE_TEX_WRAP_CLAMP_TO_EDGE &&
          state->wrap_r == PIPE_TEX_WRAP_CLAMP_TO_EDGE &&
          state->min_img_filter == PIPE_TEX_FILTER_NEAREST &&
          state->mag_img_filter == PIPE_TEX_FILTER_NEAREST &&
          state->min_mip_filter == PIPE_TEX_MIPFILTER_NONE &&
          state->compare_mode == PIPE_TEX_COMPARE_NONE &&
          !state->unnormalized_coords && state->max_anisotropy <= 1 &&
          state->lod_bias == 0.0f && state->min_lod == 0.0f &&
          state->max_lod == 0.0f;
}

static void *
ao46_metal_gallium_create_sampler_state(
   struct pipe_context *context, const struct pipe_sampler_state *state)
{
   struct AO46MetalGalliumSamplerState *sampler_state;
   const struct AO46MetalGalliumScreen *screen;

   if (!context || !ao46_metal_gallium_sampler_state_is_supported(state))
      return NULL;

   screen = ao46_metal_gallium_screen(context->screen);
   sampler_state = calloc(1, sizeof(*sampler_state));
   if (!sampler_state ||
       !AO46MetalSamplerCreateNearestClamp(screen->adapter,
                                           &sampler_state->sampler)) {
      free(sampler_state);
      return NULL;
   }

   return sampler_state;
}

static void
ao46_metal_gallium_bind_sampler_states(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned num_samplers, void **samplers)
{
   struct AO46MetalGalliumContext *ao46_context;

   if (!context || shader != MESA_SHADER_FRAGMENT ||
       start_slot > AO46_METAL_MAX_STATIC_BINDINGS ||
       num_samplers > AO46_METAL_MAX_STATIC_BINDINGS - start_slot ||
       (num_samplers != 0 && !samplers))
      return;

   ao46_context = ao46_metal_gallium_context(context);
   for (unsigned i = 0; i < num_samplers; ++i) {
      struct AO46MetalGalliumSamplerState *state = samplers[i];

      if (state && !AO46MetalSamplerIsCurrent(&state->sampler))
         return;
   }
   for (unsigned i = 0; i < num_samplers; ++i)
      ao46_context->fragment_samplers[start_slot + i] = samplers[i];
}

static void
ao46_metal_gallium_delete_sampler_state(struct pipe_context *context,
                                        void *sampler_state)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumSamplerState *state = sampler_state;

   if (!context || !state)
      return;

   ao46_context = ao46_metal_gallium_context(context);
   for (unsigned i = 0; i < AO46_METAL_MAX_STATIC_BINDINGS; ++i) {
      if (ao46_context->fragment_samplers[i] == sampler_state)
         ao46_context->fragment_samplers[i] = NULL;
   }
   AO46MetalSamplerDestroy(&state->sampler);
   free(state);
}

static bool
ao46_metal_gallium_sampler_view_is_supported(
   struct pipe_resource *texture, const struct pipe_sampler_view *template)
{
   const size_t rgb32_texel_bytes = 3 * sizeof(uint32_t);

   if (!texture || !template ||
       (!template->texture || template->texture != texture) ||
       template->swizzle_r != PIPE_SWIZZLE_X ||
       template->swizzle_g != PIPE_SWIZZLE_Y ||
       template->swizzle_b != PIPE_SWIZZLE_Z ||
       template->swizzle_a != PIPE_SWIZZLE_W)
      return false;

   if (texture->target == PIPE_BUFFER) {
      const size_t offset = template->u.buf.offset;
      size_t size;

      if (offset >= texture->width0)
         return false;
      size = template->u.buf.size ? template->u.buf.size
                                  : texture->width0 - offset;

      return template->target == PIPE_BUFFER &&
             (template->format == PIPE_FORMAT_R32G32B32_FLOAT ||
              template->format == PIPE_FORMAT_R32G32B32_UINT ||
              template->format == PIPE_FORMAT_R32G32B32_SINT) &&
             texture->format == template->format &&
             size != 0 && size <= texture->width0 - offset &&
             offset % rgb32_texel_bytes == 0 && size % rgb32_texel_bytes == 0;
   }

   return texture && template && texture->target == PIPE_TEXTURE_2D &&
          texture->last_level == 0 && texture->depth0 == 1 &&
          texture->array_size == 1 && template->target == PIPE_TEXTURE_2D &&
          template->format == texture->format &&
          template->u.tex.first_level == 0 && template->u.tex.last_level == 0 &&
          template->u.tex.first_layer == 0 && template->u.tex.last_layer == 0 &&
          template->u.tex.min_lod_clamp == 0.0f;
}

static struct pipe_sampler_view *
ao46_metal_gallium_create_sampler_view(
   struct pipe_context *context, struct pipe_resource *texture,
   const struct pipe_sampler_view *template)
{
   struct AO46MetalGalliumSamplerView *view;
   struct AO46MetalGalliumResource *resource;
   size_t buffer_size = 0;

   if (!context || !texture || texture->screen != context->screen ||
       !ao46_metal_gallium_sampler_view_is_supported(texture, template))
      return NULL;

   if (texture->target == PIPE_BUFFER) {
      buffer_size = template->u.buf.size ? template->u.buf.size
                                          : texture->width0 - template->u.buf.offset;
      if (!ao46_metal_gallium_resource_range(texture, template->u.buf.offset,
                                              buffer_size, &resource))
         return NULL;
   } else if (!ao46_metal_gallium_texture_resource(texture, &resource)) {
      return NULL;
   }

   view = calloc(1, sizeof(*view));
   if (!view)
      return NULL;

   view->base = *template;
   view->base.texture = NULL;
   view->base.context = context;
   pipe_reference_init(&view->base.reference, 1);
   pipe_resource_reference(&view->base.texture, texture);
   view->buffer_view = texture->target == PIPE_BUFFER;
   view->buffer_offset = view->buffer_view ? template->u.buf.offset : 0;
   view->buffer_size = view->buffer_view ? buffer_size : 0;
   return &view->base;
}

static void
ao46_metal_gallium_sampler_view_destroy(
   struct pipe_context *context, struct pipe_sampler_view *view)
{
   (void)context;
   if (!view)
      return;

   pipe_resource_reference(&view->texture, NULL);
   free(view);
}

static void
ao46_metal_gallium_set_sampler_views(
   struct pipe_context *context, mesa_shader_stage shader, unsigned start_slot,
   unsigned num_views, unsigned unbind_num_trailing_slots,
   struct pipe_sampler_view **views)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct pipe_sampler_view **stage_views;

   if (!context || (shader != MESA_SHADER_VERTEX &&
                    shader != MESA_SHADER_FRAGMENT) ||
       start_slot > AO46_METAL_MAX_STATIC_BINDINGS ||
       num_views > AO46_METAL_MAX_STATIC_BINDINGS - start_slot ||
       unbind_num_trailing_slots >
          AO46_METAL_MAX_STATIC_BINDINGS - start_slot - num_views ||
       (num_views != 0 && !views))
      return;

   for (unsigned i = 0; i < num_views; ++i) {
      struct AO46MetalGalliumResource *resource;

      if (views[i] &&
          (!views[i]->texture || views[i]->context != context ||
           (shader == MESA_SHADER_VERTEX &&
            views[i]->texture->target != PIPE_BUFFER) ||
           !ao46_metal_gallium_sampler_view_is_supported(views[i]->texture,
                                                          views[i]) ||
           (views[i]->texture->target == PIPE_BUFFER
               ? !ao46_metal_gallium_resource_range(
                    views[i]->texture, views[i]->u.buf.offset,
                    views[i]->u.buf.size ? views[i]->u.buf.size
                                         : views[i]->texture->width0 -
                                              views[i]->u.buf.offset,
                    &resource)
               : !ao46_metal_gallium_texture_resource(views[i]->texture,
                                                       &resource))))
         return;
   }

   ao46_context = ao46_metal_gallium_context(context);
   stage_views = shader == MESA_SHADER_VERTEX
                    ? ao46_context->vertex_sampler_views
                    : ao46_context->fragment_sampler_views;
   for (unsigned i = 0; i < num_views; ++i)
      pipe_sampler_view_reference(&stage_views[start_slot + i], views[i]);
   for (unsigned i = 0; i < unbind_num_trailing_slots; ++i)
      pipe_sampler_view_reference(&stage_views[start_slot + num_views + i], NULL);
}

static void
ao46_metal_gallium_resource_copy_region(
   struct pipe_context *context, struct pipe_resource *destination,
   unsigned destination_level, unsigned destination_x, unsigned destination_y,
   unsigned destination_z, struct pipe_resource *source, unsigned source_level,
   const struct pipe_box *source_box)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);
   struct AO46MetalGalliumResource *source_resource;
   struct AO46MetalGalliumResource *destination_resource;
   struct AO46MetalSubmission submission = {0};
   struct pipe_resource *resources[] = {source, destination};

   if (!source_box || !source || !destination ||
       source->screen != context->screen ||
       destination->screen != context->screen || destination_level != 0 ||
       source_level != 0 || destination_z != 0)
      return;

   if (!ao46_metal_gallium_wait_for_submission_backend(ao46_context, false))
      return;

   if (source->target == PIPE_BUFFER && destination->target == PIPE_BUFFER) {
      if (source_box->x < 0 || source_box->y != 0 || source_box->z != 0 ||
          destination_y != 0 ||
          source_box->width <= 0 || source_box->height != 1 ||
          source_box->depth != 1 ||
          !ao46_metal_gallium_resource_range(source, (size_t)source_box->x,
                                             (size_t)source_box->width,
                                             &source_resource) ||
          !ao46_metal_gallium_resource_range(destination, destination_x,
                                             (size_t)source_box->width,
                                             &destination_resource) ||
          !AO46MetalBufferBlitSubmit(source_resource->buffer.adapter,
                                     &source_resource->buffer, source_box->x,
                                     &destination_resource->buffer, destination_x,
                                     source_box->width, &submission))
         return;
   } else if (source->target == PIPE_TEXTURE_2D &&
              destination->target == PIPE_BUFFER) {
      size_t bytes_per_row;
      size_t required_size;

      if (source_box->x < 0 || source_box->y < 0 || source_box->z != 0 ||
          destination_y != 0 ||
          source_box->width <= 0 || source_box->height <= 0 ||
          source_box->depth != 1 ||
          !ao46_metal_gallium_texture_resource(source, &source_resource) ||
          !AO46MetalTextureTransferLayout(&source_resource->texture,
                                          (uint32_t)source_box->width,
                                          (uint32_t)source_box->height,
                                          &bytes_per_row, &required_size) ||
          !ao46_metal_gallium_resource_range(destination, destination_x,
                                             required_size,
                                             &destination_resource) ||
          !AO46MetalTextureReadbackSubmit(
             source_resource->texture.adapter, &source_resource->texture,
             (uint32_t)source_box->x, (uint32_t)source_box->y,
             (uint32_t)source_box->width, (uint32_t)source_box->height,
             &destination_resource->buffer, destination_x, bytes_per_row,
             &submission))
         return;
   } else if (source->target == PIPE_TEXTURE_2D &&
              destination->target == PIPE_TEXTURE_2D) {
      if (source_box->x < 0 || source_box->y < 0 || source_box->z != 0 ||
          source_box->width <= 0 || source_box->height <= 0 ||
          source_box->depth != 1 || !ao46_metal_gallium_texture_resource(
             source, &source_resource) || !ao46_metal_gallium_texture_resource(
             destination, &destination_resource) ||
          !AO46MetalTextureCopySubmit(
             source_resource->texture.adapter, &source_resource->texture,
             (uint32_t)source_box->x, (uint32_t)source_box->y,
             &destination_resource->texture, destination_x, destination_y,
             (uint32_t)source_box->width, (uint32_t)source_box->height,
             &submission))
         return;
   } else {
      return;
   }

   (void)ao46_metal_gallium_track_submission(ao46_context, &submission,
                                              resources, 2, NULL);
}

static void *
ao46_metal_gallium_buffer_map(struct pipe_context *context,
                              struct pipe_resource *resource, unsigned level,
                              unsigned usage, const struct pipe_box *box,
                              struct pipe_transfer **out_transfer)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);
   struct AO46MetalGalliumResource *ao46_resource;
   struct AO46MetalGalliumTransfer *transfer;

   if (out_transfer)
      *out_transfer = NULL;

   if (!box || !out_transfer || !resource || resource->screen != context->screen ||
       level != 0 ||
       box->x < 0 || box->y != 0 ||
       box->z != 0 || box->width <= 0 || box->height != 1 || box->depth != 1 ||
       !ao46_metal_gallium_resource_range(resource, (size_t)box->x,
                                          (size_t)box->width, &ao46_resource) ||
       (!(usage & PIPE_MAP_UNSYNCHRONIZED) &&
        !ao46_metal_gallium_wait_for_latest_submission(ao46_context)))
      return NULL;

   transfer = calloc(1, sizeof(*transfer));
   if (!transfer)
      return NULL;

   pipe_resource_reference(&transfer->base.resource, resource);
   transfer->base.usage = usage;
   transfer->base.level = level;
   transfer->base.box = *box;
   *out_transfer = &transfer->base;
   return (uint8_t *)ao46_resource->buffer.cpu_mapping + box->x;
}

static void
ao46_metal_gallium_buffer_unmap(struct pipe_context *context,
                                struct pipe_transfer *transfer)
{
   (void)context;
   if (!transfer)
      return;

   pipe_resource_reference(&transfer->resource, NULL);
   free(transfer);
}

static void
ao46_metal_gallium_buffer_subdata(struct pipe_context *context,
                                  struct pipe_resource *resource,
                                  unsigned usage, unsigned offset,
                                  unsigned size, const void *data)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);
   struct AO46MetalGalliumResource *ao46_resource;

   if (!data || size == 0 || !resource || resource->screen != context->screen ||
       !ao46_metal_gallium_resource_range(resource, offset, size,
                                          &ao46_resource) ||
       (!(usage & PIPE_MAP_UNSYNCHRONIZED) &&
        !ao46_metal_gallium_wait_for_latest_submission(ao46_context)))
      return;

   memcpy((uint8_t *)ao46_resource->buffer.cpu_mapping + offset, data, size);
}

static void
ao46_metal_gallium_clear_render_target(
   struct pipe_context *context, struct pipe_surface *destination,
   const union pipe_color_union *color, unsigned destination_x,
   unsigned destination_y, unsigned width, unsigned height,
   bool render_condition_enabled)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);
   struct AO46MetalGalliumResource *destination_resource;
   struct AO46MetalSubmission submission = {0};
   struct pipe_resource *resources[] = {
      destination ? destination->texture : NULL,
   };

   if (!ao46_metal_gallium_wait_for_submission_backend(ao46_context, false))
      return;

   if (!destination || !color || !destination->texture ||
       destination->texture->screen != context->screen ||
       destination->level != 0 || destination->first_layer != 0 ||
       destination->last_layer != 0 || destination_x != 0 || destination_y != 0 ||
       destination->format != destination->texture->format ||
       width != destination->texture->width0 ||
       height != destination->texture->height0 || render_condition_enabled ||
       !ao46_metal_gallium_texture_resource(destination->texture,
                                            &destination_resource) ||
       !AO46MetalTextureClearSubmit(destination_resource->texture.adapter,
                                    &destination_resource->texture, color->f,
                                    &submission))
      return;

   (void)ao46_metal_gallium_track_submission(ao46_context, &submission,
                                              resources, 1, NULL);
}

static void
ao46_metal_gallium_flush(struct pipe_context *context,
                         struct pipe_fence_handle **fence, unsigned flags)
{
   struct AO46MetalGalliumContext *ao46_context =
      ao46_metal_gallium_context(context);

   (void)flags;
   if (fence) {
      context->screen->fence_reference(
         context->screen, fence,
         (struct pipe_fence_handle *)ao46_context->last_fence);
   }
}

static bool
ao46_metal_gallium_is_format_supported(struct pipe_screen *screen,
                                       enum pipe_format format,
                                       enum pipe_texture_target target,
                                       unsigned sample_count,
                                       unsigned storage_sample_count,
                                       unsigned bindings)
{
   (void)screen;

   if (format == PIPE_FORMAT_NONE || sample_count > 1 ||
       storage_sample_count > 1)
      return false;

   if (target == PIPE_BUFFER)
      return (bindings & (PIPE_BIND_RENDER_TARGET | PIPE_BIND_DEPTH_STENCIL)) == 0;

   if (target == PIPE_TEXTURE_2D) {
      enum AO46MetalTextureFormat metal_format;

      return ao46_metal_gallium_texture_format(format, &metal_format) &&
             (bindings & ~(PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW)) == 0;
   }

   return false;
}

static bool
ao46_metal_gallium_can_create_resource(
   struct pipe_screen *screen, const struct pipe_resource *template)
{
   const struct AO46MetalGalliumScreen *ao46_screen =
      ao46_metal_gallium_screen(screen);

   if (!template || !AO46MetalAdapterIsCurrent(ao46_screen->adapter) ||
       template->format == PIPE_FORMAT_NONE)
      return false;

   if (template->target == PIPE_BUFFER)
      return template->width0 > 0 &&
             (size_t)template->width0 <= ao46_screen->adapter->max_buffer_length;

   if (template->target == PIPE_TEXTURE_2D) {
      enum AO46MetalTextureFormat metal_format;

      return ao46_metal_gallium_texture_format(template->format, &metal_format) &&
             template->width0 > 0 && template->height0 > 0 &&
             template->depth0 == 1 && template->array_size == 1 &&
             template->last_level == 0 && template->nr_samples <= 1 &&
             template->width0 <= ao46_screen->adapter->max_texture_dimension_2d &&
             template->height0 <= ao46_screen->adapter->max_texture_dimension_2d &&
             (template->bind & ~(PIPE_BIND_RENDER_TARGET | PIPE_BIND_SAMPLER_VIEW)) == 0;
   }

   return false;
}

static struct pipe_resource *
ao46_metal_gallium_resource_create(struct pipe_screen *screen,
                                   const struct pipe_resource *template)
{
   struct AO46MetalGalliumScreen *ao46_screen = ao46_metal_gallium_screen(screen);
   struct AO46MetalGalliumResource *resource;

   if (!ao46_metal_gallium_can_create_resource(screen, template))
      return NULL;

   resource = calloc(1, sizeof(*resource));
   if (!resource)
      return NULL;

   resource->base = *template;
   resource->base.screen = screen;
   resource->base.next = NULL;
   pipe_reference_init(&resource->base.reference, 1);

   if (resource->base.target == PIPE_BUFFER &&
       !AO46MetalBufferCreate(ao46_screen->adapter, resource->base.width0,
                              &resource->buffer)) {
      free(resource);
      return NULL;
   }

   if (resource->base.target == PIPE_TEXTURE_2D) {
      enum AO46MetalTextureFormat metal_format;

      if (!ao46_metal_gallium_texture_format(resource->base.format,
                                             &metal_format) ||
          !AO46MetalTextureCreate(ao46_screen->adapter, resource->base.width0,
                                  resource->base.height0, metal_format,
                                  &resource->texture)) {
         free(resource);
         return NULL;
      }
   }

   if (resource->base.target != PIPE_BUFFER &&
       resource->base.target != PIPE_TEXTURE_2D) {
      free(resource);
      return NULL;
   }

   return &resource->base;
}

static void
ao46_metal_gallium_resource_destroy(struct pipe_screen *screen,
                                    struct pipe_resource *resource)
{
   (void)screen;
   AO46MetalBufferDestroy(&ao46_metal_gallium_resource(resource)->buffer);
   AO46MetalTextureDestroy(&ao46_metal_gallium_resource(resource)->texture);
   free(resource);
}

static void
ao46_metal_gallium_destroy(struct pipe_screen *screen)
{
   free(ao46_metal_gallium_screen(screen));
}

struct pipe_screen *
AO46MetalGalliumScreenCreate(const struct AO46MetalAdapter *adapter)
{
   struct AO46MetalGalliumScreen *screen;
   struct pipe_caps *caps;

   if (!AO46MetalAdapterIsCurrent(adapter))
      return NULL;

   screen = calloc(1, sizeof(*screen));
   if (!screen)
      return NULL;

   screen->adapter = adapter;
   caps = (struct pipe_caps *)&screen->base.caps;
   caps->accelerated = true;
   caps->vendor_id = 0x106b;
   caps->device_id = (uint32_t)adapter->registry_id;
   caps->uma = adapter->unified_memory;
   caps->endianness = PIPE_ENDIAN_LITTLE;
   caps->min_map_buffer_alignment = 64;
   caps->constant_buffer_offset_alignment = 1;

   screen->base.destroy = ao46_metal_gallium_destroy;
   screen->base.get_name = ao46_metal_gallium_get_name;
   screen->base.get_vendor = ao46_metal_gallium_get_vendor;
   screen->base.get_device_vendor = ao46_metal_gallium_get_device_vendor;
   screen->base.get_screen_fd = ao46_metal_gallium_get_screen_fd;
   screen->base.context_create = ao46_metal_gallium_context_create;
   screen->base.fence_reference = ao46_metal_gallium_fence_reference;
   screen->base.fence_finish = ao46_metal_gallium_fence_finish;
   screen->base.is_format_supported = ao46_metal_gallium_is_format_supported;
   screen->base.can_create_resource = ao46_metal_gallium_can_create_resource;
   screen->base.resource_create = ao46_metal_gallium_resource_create;
   screen->base.resource_destroy = ao46_metal_gallium_resource_destroy;

   return &screen->base;
}

bool
AO46MetalGalliumContextPrepareForExternalMTL4Submission(
   struct pipe_context *context)
{
   if (!context)
      return false;

   return ao46_metal_gallium_wait_for_submission_backend(
      ao46_metal_gallium_context(context), true);
}

bool
AO46MetalGalliumResourceGetCPUMapping(struct pipe_resource *resource,
                                      void **out_mapping, size_t *out_length)
{
   struct AO46MetalGalliumResource *ao46_resource;

   if (!resource || !out_mapping || !out_length ||
       resource->target != PIPE_BUFFER || !resource->screen ||
       resource->screen->resource_destroy != ao46_metal_gallium_resource_destroy)
      return false;

   ao46_resource = ao46_metal_gallium_resource(resource);
   if (!AO46MetalBufferIsCurrent(&ao46_resource->buffer))
      return false;

   *out_mapping = ao46_resource->buffer.cpu_mapping;
   *out_length = ao46_resource->buffer.length;
   return true;
}

bool
AO46MetalGalliumResourceGetMetalBuffer(
   struct pipe_resource *resource, const struct AO46MetalBuffer **out_buffer)
{
   struct AO46MetalGalliumResource *ao46_resource;

   if (!resource || !out_buffer || resource->target != PIPE_BUFFER ||
       !resource->screen ||
       resource->screen->resource_destroy != ao46_metal_gallium_resource_destroy)
      return false;

   ao46_resource = ao46_metal_gallium_resource(resource);
   if (!AO46MetalBufferIsCurrent(&ao46_resource->buffer))
      return false;

   *out_buffer = &ao46_resource->buffer;
   return true;
}

bool
AO46MetalGalliumResourceGetMetalTexture(
   struct pipe_resource *resource, const struct AO46MetalTexture **out_texture)
{
   struct AO46MetalGalliumResource *ao46_resource;

   if (!out_texture || !ao46_metal_gallium_texture_resource(resource,
                                                             &ao46_resource))
      return false;

   *out_texture = &ao46_resource->texture;
   return true;
}

bool
AO46MetalGalliumResourceWriteGPUAddressRoot(
   struct pipe_resource *root, size_t root_offset,
   struct pipe_resource *target, size_t target_offset)
{
   struct AO46MetalGalliumResource *root_resource;
   struct AO46MetalGalliumResource *target_resource;

   if (!root || !target || root->screen != target->screen ||
       !ao46_metal_gallium_resource_range(root, root_offset,
                                          sizeof(uint64_t), &root_resource) ||
       !ao46_metal_gallium_resource_range(target, target_offset, 1,
                                          &target_resource))
      return false;

   return AO46MetalBufferWriteGPUAddressRoot(
      &root_resource->buffer, root_offset, &target_resource->buffer,
      target_offset);
}

struct pipe_surface *
AO46MetalGalliumSurfaceCreate(struct pipe_resource *texture)
{
   struct AO46MetalGalliumResource *resource;
   struct AO46MetalGalliumSurface *surface;

   if (!texture || !(texture->bind & PIPE_BIND_RENDER_TARGET) ||
       !ao46_metal_gallium_texture_resource(texture, &resource))
      return NULL;

   surface = calloc(1, sizeof(*surface));
   if (!surface)
      return NULL;

   pipe_reference_init(&surface->base.reference, 1);
   pipe_resource_reference(&surface->base.texture, texture);
   surface->base.format = texture->format;
   surface->base.level = 0;
   surface->base.first_layer = 0;
   surface->base.last_layer = 0;
   return &surface->base;
}

void
AO46MetalGalliumSurfaceDestroy(struct pipe_surface *surface)
{
   if (!surface)
      return;

   pipe_resource_reference(&surface->texture, NULL);
   free(surface);
}

bool
AO46MetalGalliumTextureGetTransferLayout(
   struct pipe_resource *texture, uint32_t width, uint32_t height,
   size_t *out_bytes_per_row, size_t *out_size)
{
   struct AO46MetalGalliumResource *resource;

   return ao46_metal_gallium_texture_resource(texture, &resource) &&
          AO46MetalTextureTransferLayout(&resource->texture, width, height,
                                         out_bytes_per_row, out_size);
}

bool
AO46MetalGalliumTextureUpload(
   struct pipe_context *context, struct pipe_resource *destination,
   uint32_t destination_x, uint32_t destination_y, uint32_t width,
   uint32_t height, struct pipe_resource *source, size_t source_offset,
   size_t source_bytes_per_row, struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumResource *destination_resource;
   struct AO46MetalGalliumResource *source_resource;
   struct AO46MetalSubmission submission = {0};
   struct pipe_resource *resources[] = {destination, source};

   if (!context || !destination || !source || !out_fence ||
       destination->screen != context->screen || source->screen != context->screen ||
       width == 0 || height == 0)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   if (!ao46_metal_gallium_wait_for_submission_backend(ao46_context, false))
      return false;

   if (
       !ao46_metal_gallium_texture_resource(destination, &destination_resource) ||
       !ao46_metal_gallium_resource_range(source, source_offset, 1,
                                          &source_resource) ||
       !AO46MetalTextureUploadSubmit(
          destination_resource->texture.adapter, &source_resource->buffer,
          source_offset, source_bytes_per_row, &destination_resource->texture,
          destination_x, destination_y, width, height, &submission))
      return false;

   if (ao46_metal_gallium_track_submission(ao46_context, &submission, resources,
                                           ARRAY_SIZE(resources), out_fence))
      return true;

   if (submission.native_command_buffer) {
      (void)AO46MetalSubmissionWait(&submission);
      AO46MetalSubmissionDestroy(&submission);
   }
   return false;
}

bool
AO46MetalGalliumComputeDispatch(
   struct pipe_context *context,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalGalliumComputeBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalBufferBinding *metal_bindings;
   struct pipe_resource **resources;
   struct AO46MetalSubmission submission = {0};
   bool submitted = false;

   if (!context || !pipeline || !bindings || binding_count == 0 ||
       binding_count > 32 || !out_fence || grid_width == 0 || grid_height == 0 ||
       grid_depth == 0 || threads_per_threadgroup_width == 0 ||
       threads_per_threadgroup_height == 0 || threads_per_threadgroup_depth == 0)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   metal_bindings = calloc(binding_count, sizeof(*metal_bindings));
   resources = calloc(binding_count, sizeof(*resources));
   if (!metal_bindings || !resources)
      goto out;

   if (!ao46_metal_gallium_wait_for_submission_backend(
          ao46_context,
          AO46MetalAdapterSupportsMTL4Submission(pipeline->adapter)))
      goto out;

   for (size_t i = 0; i < binding_count; ++i) {
      struct AO46MetalGalliumResource *resource;

      if (!bindings[i].resource || bindings[i].resource->screen != context->screen ||
          !ao46_metal_gallium_resource_range(bindings[i].resource,
                                             bindings[i].offset, 1, &resource))
         goto out;
      for (size_t j = 0; j < i; ++j) {
         if (bindings[j].index == bindings[i].index)
            goto out;
      }

      metal_bindings[i] = (struct AO46MetalBufferBinding){
         .buffer = &resource->buffer,
         .offset = bindings[i].offset,
         .index = bindings[i].index,
         .writable = bindings[i].writable,
      };
      resources[i] = bindings[i].resource;
   }

   if (!AO46MetalComputeSubmit(pipeline->adapter, pipeline, metal_bindings,
                               binding_count, grid_width, grid_height, grid_depth,
                               threads_per_threadgroup_width,
                               threads_per_threadgroup_height,
                               threads_per_threadgroup_depth, &submission))
      goto out;

   submitted = ao46_metal_gallium_track_submission(
      ao46_context, &submission, resources, binding_count, out_fence);

out:
   if (submission.native_command_buffer) {
      (void)AO46MetalSubmissionWait(&submission);
      AO46MetalSubmissionDestroy(&submission);
   }
   free(resources);
   free(metal_bindings);
   return submitted;
}

bool
AO46MetalGalliumComputeDispatchIndirect(
   struct pipe_context *context,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalGalliumComputeBinding *bindings, size_t binding_count,
   struct pipe_resource *indirect_resource, size_t indirect_offset,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumResource *indirect;
   struct AO46MetalBufferBinding *metal_bindings;
   struct pipe_resource **resources;
   struct AO46MetalSubmission submission = {0};
   bool submitted = false;

   if (!context || !pipeline || !bindings || binding_count == 0 ||
       binding_count > 32 || !indirect_resource || !out_fence ||
       indirect_offset % sizeof(uint32_t) != 0 ||
       threads_per_threadgroup_width == 0 ||
       threads_per_threadgroup_height == 0 || threads_per_threadgroup_depth == 0)
      return false;

   ao46_context = ao46_metal_gallium_context(context);
   metal_bindings = calloc(binding_count, sizeof(*metal_bindings));
   resources = calloc(binding_count + 1, sizeof(*resources));
   if (!metal_bindings || !resources ||
       indirect_resource->screen != context->screen ||
       !ao46_metal_gallium_resource_range(indirect_resource, indirect_offset,
                                          3 * sizeof(uint32_t), &indirect))
      goto out;

   /* Indirect dispatch uses the public classic Metal encoder, not MTL4. */
   if (!ao46_metal_gallium_wait_for_submission_backend(ao46_context, false))
      goto out;

   for (size_t i = 0; i < binding_count; ++i) {
      struct AO46MetalGalliumResource *resource;

      if (!bindings[i].resource || bindings[i].resource->screen != context->screen ||
          !ao46_metal_gallium_resource_range(bindings[i].resource,
                                             bindings[i].offset, 1, &resource))
         goto out;
      for (size_t j = 0; j < i; ++j) {
         if (bindings[j].index == bindings[i].index)
            goto out;
      }

      metal_bindings[i] = (struct AO46MetalBufferBinding){
         .buffer = &resource->buffer,
         .offset = bindings[i].offset,
         .index = bindings[i].index,
         .writable = bindings[i].writable,
      };
      resources[i] = bindings[i].resource;
   }
   resources[binding_count] = indirect_resource;

   if (!AO46MetalComputeSubmitIndirect(
          pipeline->adapter, pipeline, metal_bindings, binding_count,
          &indirect->buffer, indirect_offset, threads_per_threadgroup_width,
          threads_per_threadgroup_height, threads_per_threadgroup_depth,
          &submission))
      goto out;

   submitted = ao46_metal_gallium_track_submission(
      ao46_context, &submission, resources, binding_count + 1, out_fence);

out:
   if (submission.native_command_buffer) {
      (void)AO46MetalSubmissionWait(&submission);
      AO46MetalSubmissionDestroy(&submission);
   }
   free(resources);
   free(metal_bindings);
   return submitted;
}

bool
AO46MetalGalliumRenderTriangle(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return AO46MetalGalliumRenderTriangleWithUniformBuffers(
      context, pipeline, destination, NULL, 0, vertex_bindings,
      vertex_binding_count, out_fence);
}

static bool
ao46_metal_gallium_render_triangle(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumIndirectDrawBinding *indirect_binding,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, uint32_t vertex_start, uint32_t vertex_count,
   uint32_t instance_count, uint32_t base_instance,
   enum AO46MetalPrimitive primitive,
   struct pipe_fence_handle **out_fence)
{
   struct AO46MetalGalliumContext *ao46_context;
   struct AO46MetalGalliumResource *destination_resource;
   struct AO46MetalGalliumResource *index_resource;
   struct AO46MetalGalliumResource *indirect_resource;
   struct AO46MetalGalliumResource *indirect_count_resource;
   struct AO46MetalUniformBufferBinding
      metal_uniform_bindings[AO46_METAL_MAX_UNIFORM_BINDINGS];
   struct AO46MetalIndexBufferBinding metal_index_binding;
   const struct AO46MetalIndexBufferBinding *metal_index = NULL;
   struct AO46MetalIndirectDrawBinding metal_indirect_binding;
   const struct AO46MetalIndirectDrawBinding *metal_indirect = NULL;
   struct AO46MetalVertexBufferBinding
      metal_bindings[AO46_METAL_MAX_VERTEX_ATTRIBUTES];
   struct AO46MetalTextureBinding
      texture_bindings[AO46_METAL_MAX_STATIC_BINDINGS];
   struct AO46MetalSamplerBinding
      sampler_bindings[AO46_METAL_MAX_STATIC_BINDINGS];
   struct AO46MetalBufferBinding
      vertex_static_buffer_bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   struct AO46MetalBufferBinding
      fragment_buffer_bindings[AO46_METAL_MAX_STATIC_BINDINGS];
   struct AO46MesaRGB32BufferTextureBinding
      rgb32_bindings[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS];
   struct pipe_resource *resources[AO46_METAL_MAX_VERTEX_ATTRIBUTES +
                                   3 * AO46_METAL_MAX_STATIC_BINDINGS +
                                   AO46_METAL_MAX_UNIFORM_BINDINGS + 4] = {
      destination ? destination->texture : NULL,
   };
   struct AO46MetalSubmission submission = {0};
   size_t texture_binding_count = 0;
   size_t sampler_binding_count = 0;
   size_t vertex_static_buffer_binding_count = 0;
   size_t fragment_buffer_binding_count = 0;
   uint32_t rgb32_binding_count = 0;
   size_t resource_count = 1;
   bool submitted = false;

   if (!context || !pipeline || !destination || !destination->texture ||
       !out_fence || destination->texture->screen != context->screen ||
       destination->level != 0 || destination->first_layer != 0 ||
       destination->last_layer != 0 ||
       destination->format != destination->texture->format ||
       (uniform_binding_count == 0 && uniform_bindings) ||
       (uniform_binding_count != 0 && !uniform_bindings) ||
       uniform_binding_count > AO46_METAL_MAX_UNIFORM_BINDINGS ||
       (vertex_binding_count == 0 && vertex_bindings) ||
       (vertex_binding_count != 0 && !vertex_bindings) ||
       vertex_binding_count > AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
       (vertex_static_binding_count == 0 && vertex_static_bindings) ||
       (vertex_static_binding_count != 0 && !vertex_static_bindings) ||
       vertex_static_binding_count > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
       !ao46_metal_gallium_texture_resource(destination->texture,
                                            &destination_resource))
      return false;

   for (size_t i = 0; i < vertex_static_binding_count; ++i) {
      const struct AO46MetalGalliumStaticBufferBinding *binding =
         &vertex_static_bindings[i];
      struct AO46MetalGalliumResource *static_resource;

      if (!binding->resource || binding->resource->screen != context->screen ||
          binding->index < 2 ||
          binding->index >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
          binding->size == 0 ||
          !ao46_metal_gallium_resource_range(binding->resource, binding->offset,
                                             binding->size, &static_resource)) {
         return false;
      }

      for (size_t j = 0; j < i; ++j) {
         if (vertex_static_bindings[j].index == binding->index)
            return false;
      }

      vertex_static_buffer_bindings[vertex_static_buffer_binding_count++] =
         (struct AO46MetalBufferBinding){
            .buffer = &static_resource->buffer,
            .offset = binding->offset,
            .size = binding->size,
            .index = binding->index,
         };
      resources[resource_count++] = binding->resource;
   }

   for (size_t i = 0; i < vertex_binding_count; ++i) {
      struct AO46MetalGalliumResource *vertex_resource;

      if (!vertex_bindings[i].resource ||
          vertex_bindings[i].resource->screen != context->screen ||
          !ao46_metal_gallium_resource_range(vertex_bindings[i].resource,
                                             vertex_bindings[i].offset, 1,
                                             &vertex_resource))
         return false;

      for (size_t j = 0; j < i; ++j) {
         if (vertex_bindings[j].index == vertex_bindings[i].index)
            return false;
      }

      for (size_t j = 0; j < vertex_static_binding_count; ++j) {
         if (vertex_static_bindings[j].index == vertex_bindings[i].index)
            return false;
      }

      metal_bindings[i] = (struct AO46MetalVertexBufferBinding){
         .buffer = &vertex_resource->buffer,
         .offset = vertex_bindings[i].offset,
         .index = vertex_bindings[i].index,
      };
      resources[resource_count++] = vertex_bindings[i].resource;
   }

   for (size_t i = 0; i < uniform_binding_count; ++i) {
      struct AO46MetalGalliumResource *uniform_resource;

      if (!uniform_bindings[i].resource ||
          uniform_bindings[i].resource->screen != context->screen ||
          uniform_bindings[i].binding >= AO46_METAL_MAX_UNIFORM_BINDINGS ||
          !ao46_metal_gallium_resource_range(uniform_bindings[i].resource,
                                             uniform_bindings[i].offset,
                                             uniform_bindings[i].size,
                                             &uniform_resource))
         return false;

      for (size_t j = 0; j < i; ++j) {
         if (uniform_bindings[j].binding == uniform_bindings[i].binding)
            return false;
      }

      metal_uniform_bindings[i] = (struct AO46MetalUniformBufferBinding){
         .buffer = &uniform_resource->buffer,
         .offset = uniform_bindings[i].offset,
         .size = uniform_bindings[i].size,
         .binding = uniform_bindings[i].binding,
      };
      resources[resource_count++] = uniform_bindings[i].resource;
   }

   if (index_binding) {
      if (!index_binding->resource ||
          index_binding->resource->screen != context->screen ||
          !ao46_metal_gallium_resource_range(index_binding->resource,
                                             index_binding->offset,
                                             index_binding->size,
                                             &index_resource)) {
         return false;
      }

      metal_index_binding = (struct AO46MetalIndexBufferBinding){
         .buffer = &index_resource->buffer,
         .offset = index_binding->offset,
         .size = index_binding->size,
         .count = index_binding->count,
         .format = index_binding->format,
         .base_vertex = index_binding->base_vertex,
         .primitive_restart = index_binding->primitive_restart,
         .restart_index = index_binding->restart_index,
      };
      metal_index = &metal_index_binding;
      resources[resource_count++] = index_binding->resource;
   }

   if (indirect_binding) {
      if (!indirect_binding->resource ||
          indirect_binding->resource->screen != context->screen ||
          !ao46_metal_gallium_resource_range(indirect_binding->resource,
                                             indirect_binding->offset, 1,
                                             &indirect_resource))
         return false;

      metal_indirect_binding = (struct AO46MetalIndirectDrawBinding){
         .buffer = &indirect_resource->buffer,
         .offset = indirect_binding->offset,
         .draw_count = indirect_binding->draw_count,
         .stride = indirect_binding->stride,
         .gpu_generated = indirect_binding->gpu_generated,
         .maximum_index_count = indirect_binding->maximum_index_count,
      };
      if (indirect_binding->count_resource) {
         if (indirect_binding->count_resource->screen != context->screen ||
             !ao46_metal_gallium_resource_range(
                indirect_binding->count_resource, indirect_binding->count_offset,
                sizeof(uint32_t), &indirect_count_resource))
            return false;
         metal_indirect_binding.count_buffer = &indirect_count_resource->buffer;
         metal_indirect_binding.count_buffer_offset = indirect_binding->count_offset;
         resources[resource_count++] = indirect_binding->count_resource;
      }
      metal_indirect = &metal_indirect_binding;
      resources[resource_count++] = indirect_binding->resource;
   }

   ao46_context = ao46_metal_gallium_context(context);
   if (!ao46_metal_gallium_wait_for_submission_backend(ao46_context, false))
      return false;
   if (pipeline->static_fragment_buffer_mask &&
       !AO46MesaRGB32BufferTextureBindingsFromSamplerViews(
          ao46_context->fragment_sampler_views,
          pipeline->static_fragment_buffer_mask, rgb32_bindings,
          AO46_METAL_MAX_STATIC_BUFFER_BINDINGS, &rgb32_binding_count))
      return false;
   for (unsigned index = 0; index < AO46_METAL_MAX_STATIC_BINDINGS; ++index) {
      const uint64_t bit = UINT64_C(1) << index;

      if (pipeline->static_texture_mask & bit) {
         struct pipe_sampler_view *view =
            ao46_context->fragment_sampler_views[index];
         struct AO46MetalGalliumResource *texture_resource;

         if (!view || !view->texture || view->texture == destination->texture ||
             !ao46_metal_gallium_sampler_view_is_supported(view->texture, view) ||
             !ao46_metal_gallium_texture_resource(view->texture,
                                                  &texture_resource))
            return false;

         texture_bindings[texture_binding_count++] =
            (struct AO46MetalTextureBinding){
               .texture = &texture_resource->texture,
               .index = index,
            };
         resources[resource_count++] = view->texture;
      }

      if (pipeline->static_fragment_buffer_mask & bit) {
         struct pipe_sampler_view *base_view =
            ao46_context->fragment_sampler_views[index];
         struct AO46MetalGalliumSamplerView *view;
         struct AO46MetalGalliumResource *buffer_resource;
         const struct AO46MesaRGB32BufferTextureBinding *rgb32_binding = NULL;

         if (!base_view || !base_view->texture ||
             !ao46_metal_gallium_sampler_view_is_supported(base_view->texture,
                                                            base_view) ||
             base_view->texture->target != PIPE_BUFFER ||
             !ao46_metal_gallium_resource_range(
                base_view->texture, base_view->u.buf.offset,
                base_view->u.buf.size ? base_view->u.buf.size
                                      : base_view->texture->width0 -
                                           base_view->u.buf.offset,
                &buffer_resource))
            return false;

         for (uint32_t binding_index = 0;
              binding_index < rgb32_binding_count; ++binding_index) {
            if (rgb32_bindings[binding_index].buffer_binding == index) {
               rgb32_binding = &rgb32_bindings[binding_index];
               break;
            }
         }
         if (!rgb32_binding)
            return false;

         view = (struct AO46MetalGalliumSamplerView *)base_view;
         if (!view->buffer_view || view->buffer_offset != base_view->u.buf.offset ||
             view->buffer_size == 0 ||
             view->buffer_size !=
                (size_t)rgb32_binding->element_count * 3 * sizeof(uint32_t))
            return false;

         fragment_buffer_bindings[fragment_buffer_binding_count++] =
            (struct AO46MetalBufferBinding){
               .buffer = &buffer_resource->buffer,
               .offset = view->buffer_offset,
               .size = view->buffer_size,
               .index = index,
            };
         resources[resource_count++] = base_view->texture;
      }

      if (pipeline->static_sampler_mask & bit) {
         struct AO46MetalGalliumSamplerState *sampler_state =
            ao46_context->fragment_samplers[index];

         if (!sampler_state ||
             !AO46MetalSamplerIsCurrent(&sampler_state->sampler))
            return false;

         sampler_bindings[sampler_binding_count++] =
            (struct AO46MetalSamplerBinding){
               .sampler = &sampler_state->sampler,
               .index = index,
            };
      }
   }

   if (!AO46MetalRenderSubmitWithStaticVertexBuffers(
          destination_resource->texture.adapter, pipeline,
          &destination_resource->texture,
          uniform_binding_count ? metal_uniform_bindings : NULL,
          uniform_binding_count, metal_index, metal_indirect,
          vertex_binding_count ? metal_bindings : NULL,
          vertex_binding_count, texture_binding_count ? texture_bindings : NULL,
          texture_binding_count, sampler_binding_count ? sampler_bindings : NULL,
          sampler_binding_count,
          vertex_static_buffer_binding_count ? vertex_static_buffer_bindings : NULL,
          vertex_static_buffer_binding_count,
          fragment_buffer_binding_count ? fragment_buffer_bindings : NULL,
          fragment_buffer_binding_count, primitive, vertex_start, vertex_count,
          instance_count, base_instance, &submission))
      return false;

   submitted = ao46_metal_gallium_track_submission(
      ao46_context, &submission, resources, resource_count, out_fence);
   if (submission.native_command_buffer) {
      (void)AO46MetalSubmissionWait(&submission);
      AO46MetalSubmissionDestroy(&submission);
   }
   return submitted;
}

bool
AO46MetalGalliumRenderTriangleWithUniformBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return ao46_metal_gallium_render_triangle(
      context, pipeline, destination, uniform_bindings, uniform_binding_count,
      NULL, NULL, NULL, 0, vertex_bindings, vertex_binding_count, 0, 3, 1, 0,
      AO46_METAL_PRIMITIVE_TRIANGLES, out_fence);
}

bool
AO46MetalGalliumRenderTriangleWithStaticVertexBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return ao46_metal_gallium_render_triangle(
      context, pipeline, destination, NULL, 0, NULL, NULL,
      vertex_static_bindings, vertex_static_binding_count, vertex_bindings,
      vertex_binding_count, 0, 3, 1, 0, AO46_METAL_PRIMITIVE_TRIANGLES,
      out_fence);
}

bool
AO46MetalGalliumRenderIndexedTriangles(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   return AO46MetalGalliumRenderIndexedTrianglesWithUniformBuffers(
      context, pipeline, destination, NULL, 0, index_binding, vertex_bindings,
      vertex_binding_count, out_fence);
}

bool
AO46MetalGalliumRenderIndexedTrianglesWithUniformBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   if (!index_binding)
      return false;

   return ao46_metal_gallium_render_triangle(
      context, pipeline, destination, uniform_bindings, uniform_binding_count,
      index_binding, NULL, NULL, 0, vertex_bindings, vertex_binding_count, 0, 3,
      1, 0, AO46_METAL_PRIMITIVE_TRIANGLES, out_fence);
}

bool
AO46MetalGalliumRenderIndexedTrianglesWithStaticVertexBuffers(
   struct pipe_context *context, const struct AO46MetalRenderPipeline *pipeline,
   struct pipe_surface *destination,
   const struct AO46MetalGalliumStaticBufferBinding *vertex_static_bindings,
   size_t vertex_static_binding_count,
   const struct AO46MetalGalliumIndexBufferBinding *index_binding,
   const struct AO46MetalGalliumVertexBinding *vertex_bindings,
   size_t vertex_binding_count, struct pipe_fence_handle **out_fence)
{
   if (!index_binding)
      return false;

   return ao46_metal_gallium_render_triangle(
      context, pipeline, destination, NULL, 0, index_binding, NULL,
      vertex_static_bindings, vertex_static_binding_count, vertex_bindings,
      vertex_binding_count, 0, 3, 1, 0, AO46_METAL_PRIMITIVE_TRIANGLES,
      out_fence);
}
