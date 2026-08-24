/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include "AO46MetalAdapter.h"
#include "kosmickrisp/bridge/mtl_bridge.h"

#include <limits.h>
#include <string.h>

/* Conservative bootstrap cap until the format/capability database is live. */
enum {
   AO46_METAL_BOOTSTRAP_MAX_TEXTURE_DIMENSION_2D = 16384,
   AO46_MESA_ROOT_BUFFER_BYTES = 16,
   AO46_MESA_SAMPLER_TABLE_BYTES = 16384,
   AO46_METAL_MTL4_MAX_THREADS_PER_THREADGROUP = 1024,
};

static bool
ao46_metal_submission_is_empty(const struct AO46MetalSubmission *submission);

/* MTL4 reports completion through its queue feedback callback rather than status. */
@interface AO46MetalMTL4Completion : NSObject {
@public
   NSCondition *_condition;
   BOOL _completed;
   BOOL _succeeded;
}
@end

@implementation AO46MetalMTL4Completion

- (instancetype)init
{
   self = [super init];
   if (self) {
      _condition = [[NSCondition alloc] init];
      _completed = NO;
      _succeeded = NO;
   }
   return self;
}

@end

/* The shared state owns the MTL4 queue/set pair until the final adapter copy. */
@interface AO46MetalMTL4SharedState : NSObject {
@public
   mtl_command_queue *_queue;
   mtl_residency_set *_residency_set;
   mtl_event *_ordering_event;
   mtl_compiler *_compiler;
   uint64_t _last_submission_value;
}
- (instancetype)initWithQueue:(mtl_command_queue *)queue
                 residencySet:(mtl_residency_set *)residencySet
                 orderingEvent:(mtl_event *)orderingEvent
                      compiler:(mtl_compiler *)compiler;
@end

@implementation AO46MetalMTL4SharedState

- (instancetype)initWithQueue:(mtl_command_queue *)queue
                 residencySet:(mtl_residency_set *)residencySet
                 orderingEvent:(mtl_event *)orderingEvent
                      compiler:(mtl_compiler *)compiler
{
   self = [super init];
   if (self) {
      _queue = queue;
      _residency_set = residencySet;
      _ordering_event = orderingEvent;
      _compiler = compiler;
   }
   return self;
}

- (void)dealloc
{
   if (_queue && _residency_set)
      mtl_command_queue_remove_residency_set(_queue, _residency_set);
   if (_residency_set) {
      mtl_residency_set_end_residency(_residency_set);
      mtl_release(_residency_set);
   }
   if (_ordering_event)
      mtl_release(_ordering_event);
   if (_compiler)
      mtl_release(_compiler);
   if (_queue)
      mtl_release(_queue);
}

@end

static void
ao46_metal_mtl4_feedback(struct mtl_feedback_data *feedback)
{
   AO46MetalMTL4Completion *completion =
      (__bridge_transfer AO46MetalMTL4Completion *)feedback->user_data;

   [completion->_condition lock];
   completion->_succeeded = feedback->error == MTL_COMMAND_QUEUE_ERROR_NONE;
   completion->_completed = YES;
   [completion->_condition broadcast];
   [completion->_condition unlock];
}

static bool
ao46_metal_mtl4_completion_wait(void *handle)
{
   AO46MetalMTL4Completion *completion =
      (__bridge AO46MetalMTL4Completion *)handle;
   bool succeeded;

   if (!completion)
      return false;

   [completion->_condition lock];
   while (!completion->_completed)
      [completion->_condition wait];
   succeeded = completion->_succeeded;
   [completion->_condition unlock];
   return succeeded;
}

static bool
ao46_metal_mtl4_completion_is_complete(void *handle)
{
   AO46MetalMTL4Completion *completion =
      (__bridge AO46MetalMTL4Completion *)handle;
   bool completed;

   if (!completion)
      return false;

   [completion->_condition lock];
   completed = completion->_completed;
   [completion->_condition unlock];
   return completed;
}

/* Queue events preserve MTL4 submission order without CPU fence retirement. */
static bool
ao46_metal_mtl4_commit_submission(
   const struct AO46MetalAdapter *adapter, mtl_command_buffer *command_buffer,
   mtl_command_allocator *allocator, mtl_argument_table *argument_table,
   struct AO46MetalSubmission *out_submission)
{
   AO46MetalMTL4SharedState *shared;
   AO46MetalMTL4Completion *completion;
   mtl_commit_options *commit_options;
   void *callback_data;
   uint64_t previous_value;
   uint64_t signal_value;

   if (!AO46MetalAdapterSupportsMTL4Submission(adapter) || !command_buffer ||
       !allocator || !out_submission || !ao46_metal_submission_is_empty(out_submission))
      return false;

   shared = (__bridge AO46MetalMTL4SharedState *)adapter->mtl4_shared_state;
   if (!shared || !shared->_queue || !shared->_ordering_event)
      return false;

   completion = [[AO46MetalMTL4Completion alloc] init];
   commit_options = mtl_new_commit_options();
   if (!completion || !commit_options) {
      if (commit_options)
         mtl_release(commit_options);
      return false;
   }

   callback_data = (void *)CFBridgingRetain(completion);
   mtl_commit_options_add_feedback_handler(
      commit_options, ao46_metal_mtl4_feedback, callback_data);

   *out_submission = (struct AO46MetalSubmission){
      .adapter = adapter,
      .native_command_buffer = command_buffer,
      .native_command_allocator = allocator,
      .native_argument_table = argument_table,
      .native_commit_options = commit_options,
      .native_completion_state = (__bridge_retained void *)completion,
      .uses_mtl4 = true,
   };

   @synchronized (shared) {
      previous_value = shared->_last_submission_value;
      signal_value = previous_value + 1u;
      if (signal_value == 0) {
         /* A wrapped timeline cannot safely describe an ordering edge. */
         mtl_release(commit_options);
         CFBridgingRelease(out_submission->native_completion_state);
         CFBridgingRelease(callback_data);
         *out_submission = (struct AO46MetalSubmission){0};
         return false;
      }

      if (previous_value != 0)
         mtl_wait_for_event(shared->_queue, shared->_ordering_event,
                            previous_value);
      mtl_command_buffer *submitted_command_buffer = command_buffer;
      mtl_command_queue_commit(shared->_queue, &submitted_command_buffer, 1u,
                               commit_options);
      mtl_signal_event(shared->_queue, shared->_ordering_event, signal_value);
      shared->_last_submission_value = signal_value;
   }

   return true;
}

static bool
ao46_metal_adapter_is_empty(const struct AO46MetalAdapter *adapter)
{
   return adapter && !adapter->device && !adapter->queue &&
          !adapter->mtl4_queue && !adapter->mtl4_residency_set &&
          !adapter->mtl4_shared_state &&
          !adapter->graphics_root_buffer && !adapter->graphics_sampler_table_buffer &&
          !adapter->indirect_count_range_pipeline &&
          adapter->registry_id == 0 && !adapter->unified_memory &&
          !adapter->gpu_addressable_buffers && !adapter->mtl4_submission_enabled &&
          adapter->max_buffer_length == 0 &&
          adapter->max_texture_dimension_2d == 0;
}

static bool
ao46_metal_render_pipeline_is_empty(
   const struct AO46MetalRenderPipeline *pipeline)
{
   if (!pipeline || pipeline->adapter || pipeline->native_pipeline ||
       pipeline->native_classic_pipeline ||
       pipeline->color_format != AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM ||
       pipeline->supports_indirect_command_buffers ||
       pipeline->static_texture_mask != 0 || pipeline->static_sampler_mask != 0 ||
       pipeline->static_vertex_texture_mask != 0 ||
       pipeline->static_fragment_texture_mask != 0 ||
       pipeline->static_vertex_sampler_mask != 0 ||
       pipeline->static_fragment_sampler_mask != 0 ||
       pipeline->static_vertex_buffer_mask != 0 ||
       pipeline->static_fragment_buffer_mask != 0 ||
       pipeline->uniform_mask != 0 || pipeline->vertex_attribute_count != 0)
      return false;

   for (size_t i = 0; i < AO46_METAL_MAX_UNIFORM_BINDINGS; ++i) {
      if (pipeline->uniform_bytes[i] != 0)
         return false;
   }

   for (size_t i = 0; i < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS; ++i) {
      if (pipeline->static_vertex_buffer_bytes[i] != 0 ||
          pipeline->static_fragment_buffer_bytes[i] != 0)
         return false;
   }

   return true;
}

static MTLVertexFormat
ao46_metal_vertex_format(enum AO46MetalVertexFormat format)
{
   switch (format) {
   case AO46_METAL_VERTEX_FORMAT_FLOAT2:
      return MTLVertexFormatFloat2;
   case AO46_METAL_VERTEX_FORMAT_FLOAT4:
      return MTLVertexFormatFloat4;
   }

   return MTLVertexFormatInvalid;
}

static enum mtl_vertex_format
ao46_metal_mtl4_vertex_format(enum AO46MetalVertexFormat format)
{
   switch (format) {
   case AO46_METAL_VERTEX_FORMAT_FLOAT2:
      return MTL_VERTEX_FORMAT_FLOAT2;
   case AO46_METAL_VERTEX_FORMAT_FLOAT4:
      return MTL_VERTEX_FORMAT_FLOAT4;
   }

   return MTL_VERTEX_FORMAT_INVALID;
}

static enum mtl_pixel_format
ao46_metal_mtl4_pixel_format(enum AO46MetalTextureFormat format)
{
   switch (format) {
   case AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM:
      return MTL_PIXEL_FORMAT_R8G8B8A8_UNORM;
   case AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM:
      return MTL_PIXEL_FORMAT_B8G8R8A8_UNORM;
   }

   return MTL_PIXEL_FORMAT_INVALID;
}

static size_t
ao46_metal_vertex_format_size(enum AO46MetalVertexFormat format)
{
   switch (format) {
   case AO46_METAL_VERTEX_FORMAT_FLOAT2:
      return 2 * sizeof(float);
   case AO46_METAL_VERTEX_FORMAT_FLOAT4:
      return 4 * sizeof(float);
   }

   return 0;
}

static bool
ao46_metal_vertex_attributes_are_valid(
   const struct AO46MetalVertexAttribute *attributes, size_t attribute_count)
{
   if ((attribute_count == 0 && attributes) ||
       (attribute_count != 0 && !attributes) ||
       attribute_count > AO46_METAL_MAX_VERTEX_ATTRIBUTES)
      return false;

   for (size_t i = 0; i < attribute_count; ++i) {
      size_t format_size = ao46_metal_vertex_format_size(attributes[i].format);

      if (attributes[i].attribute_index >= AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
          attributes[i].buffer_index < 2 ||
          attributes[i].buffer_index > AO46_METAL_MAX_VERTEX_BUFFER_INDEX ||
          !format_size || attributes[i].offset > UINT32_MAX - format_size ||
          attributes[i].stride < attributes[i].offset + format_size)
         return false;

      for (size_t j = 0; j < i; ++j) {
         if (attributes[j].attribute_index == attributes[i].attribute_index)
            return false;
         if (attributes[j].buffer_index == attributes[i].buffer_index &&
             (attributes[j].stride != attributes[i].stride ||
              attributes[j].instance_divisor != attributes[i].instance_divisor))
            return false;
      }
   }

   return true;
}

static bool
ao46_metal_primitive_info(enum AO46MetalPrimitive primitive,
                          uint32_t *out_vertices_per_primitive,
                          MTLPrimitiveType *out_native_primitive)
{
   uint32_t vertices_per_primitive;
   MTLPrimitiveType native_primitive;

   switch (primitive) {
   case AO46_METAL_PRIMITIVE_TRIANGLES:
      vertices_per_primitive = 3;
      native_primitive = MTLPrimitiveTypeTriangle;
      break;
   case AO46_METAL_PRIMITIVE_LINES:
      vertices_per_primitive = 2;
      native_primitive = MTLPrimitiveTypeLine;
      break;
   case AO46_METAL_PRIMITIVE_POINTS:
      vertices_per_primitive = 1;
      native_primitive = MTLPrimitiveTypePoint;
      break;
   default:
      return false;
   }

   if (out_vertices_per_primitive)
      *out_vertices_per_primitive = vertices_per_primitive;
   if (out_native_primitive)
      *out_native_primitive = native_primitive;
   return true;
}

/* Validate a primitive-list EBO and derive its highest post-base vertex. */
static bool
ao46_metal_index_binding_vertex_span(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalIndexBufferBinding *index_binding,
   enum AO46MetalPrimitive primitive, uint32_t vertex_start,
   uint32_t vertex_count, size_t *out_vertex_span,
   MTLIndexType *out_index_type)
{
   uint32_t minimum_index = UINT32_MAX;
   uint32_t maximum_index = 0;
   uint64_t run_length = 0;
   bool has_index = false;
   size_t index_size;
   size_t index_bytes;
   uint32_t vertices_per_primitive;

   if (!out_vertex_span || !out_index_type ||
       !ao46_metal_primitive_info(primitive, &vertices_per_primitive, NULL))
      return false;

   if (!index_binding) {
      if (vertex_count < vertices_per_primitive ||
          vertex_count % vertices_per_primitive != 0 ||
          vertex_start > UINT32_MAX - (vertex_count - 1))
         return false;

      *out_vertex_span = (size_t)vertex_start + vertex_count;
      *out_index_type = MTLIndexTypeUInt16;
      return true;
   }

   switch (index_binding->format) {
   case AO46_METAL_INDEX_FORMAT_UINT16:
      index_size = sizeof(uint16_t);
      *out_index_type = MTLIndexTypeUInt16;
      break;
   case AO46_METAL_INDEX_FORMAT_UINT32:
      index_size = sizeof(uint32_t);
      *out_index_type = MTLIndexTypeUInt32;
      break;
   default:
      return false;
   }

   if (!AO46MetalBufferIsCurrent(index_binding->buffer) ||
       index_binding->buffer->adapter != adapter ||
       !index_binding->buffer->cpu_mapping ||
       index_binding->count < vertices_per_primitive || vertex_start != 0 ||
       index_binding->count > SIZE_MAX / index_size ||
       index_binding->offset % index_size != 0 ||
       index_binding->offset > index_binding->buffer->length ||
       index_binding->size != (size_t)index_binding->count * index_size)
      return false;

   if (index_binding->primitive_restart &&
       index_binding->format == AO46_METAL_INDEX_FORMAT_UINT16 &&
       index_binding->restart_index > UINT16_MAX)
      return false;

   index_bytes = (size_t)index_binding->count * index_size;
   if (index_bytes > index_binding->buffer->length - index_binding->offset)
      return false;

   if (index_binding->format == AO46_METAL_INDEX_FORMAT_UINT16) {
      const uint16_t *indices =
         (const uint16_t *)((const uint8_t *)index_binding->buffer->cpu_mapping +
                            index_binding->offset);

      for (uint32_t i = 0; i < index_binding->count; ++i) {
         const uint32_t index = indices[i];

         if (index_binding->primitive_restart &&
             index == index_binding->restart_index) {
            if (run_length % vertices_per_primitive != 0)
               return false;
            run_length = 0;
            continue;
         }

         minimum_index = index < minimum_index ? index : minimum_index;
         maximum_index = index > maximum_index ? index : maximum_index;
         has_index = true;
         ++run_length;
      }
   } else {
      const uint32_t *indices =
         (const uint32_t *)((const uint8_t *)index_binding->buffer->cpu_mapping +
                            index_binding->offset);

      for (uint32_t i = 0; i < index_binding->count; ++i) {
         const uint32_t index = indices[i];

         if (index_binding->primitive_restart &&
             index == index_binding->restart_index) {
            if (run_length % vertices_per_primitive != 0)
               return false;
            run_length = 0;
            continue;
         }

         minimum_index = index < minimum_index ? index : minimum_index;
         maximum_index = index > maximum_index ? index : maximum_index;
         has_index = true;
         ++run_length;
      }
   }

   if (!has_index || run_length % vertices_per_primitive != 0)
      return false;

   const int64_t minimum_vertex =
      (int64_t)minimum_index + index_binding->base_vertex;
   const int64_t maximum_vertex =
      (int64_t)maximum_index + index_binding->base_vertex;
   if (minimum_vertex < 0 || maximum_vertex > UINT32_MAX)
      return false;

   *out_vertex_span = (size_t)maximum_vertex + 1;
   return true;
}

struct AO46MetalDrawIndirectArguments {
   uint32_t vertex_count;
   uint32_t instance_count;
   uint32_t vertex_start;
   uint32_t base_instance;
};

struct AO46MetalDrawIndexedIndirectArguments {
   uint32_t index_count;
   uint32_t instance_count;
   uint32_t index_start;
   int32_t base_vertex;
   uint32_t base_instance;
};

static bool
ao46_metal_indirect_count_binding_is_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalIndirectDrawBinding *indirect_binding)
{
   const struct AO46MetalBuffer *count_buffer;

   if (!adapter || !indirect_binding)
      return false;

   count_buffer = indirect_binding->count_buffer;
   if (!count_buffer)
      return indirect_binding->count_buffer_offset == 0;

   return AO46MetalBufferIsCurrent(count_buffer) &&
          count_buffer->adapter == adapter &&
          indirect_binding->count_buffer_offset % sizeof(uint32_t) == 0 &&
          indirect_binding->count_buffer_offset <= count_buffer->length &&
          sizeof(uint32_t) <=
             count_buffer->length - indirect_binding->count_buffer_offset;
}

/*
 * Host-provided records are read to prove vertex/index ranges before encoding.
 * Mesa's bounded GPU-produced tessellation record follows the separate path
 * below and never crosses the CPU between its compute stages and TES draw.
 */
static bool
ao46_metal_indirect_binding_is_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalIndexBufferBinding *index_binding,
   const struct AO46MetalIndirectDrawBinding *indirect_binding,
   enum AO46MetalPrimitive primitive,
   size_t *out_vertex_span, uint32_t *out_instance_count)
{
   size_t argument_size;
   size_t argument_stride;
   size_t required_size;
   size_t maximum_vertex_span = 0;
   uint64_t maximum_instance_end = 0;
   uint32_t vertices_per_primitive;

   if (!adapter || !indirect_binding || !out_vertex_span ||
       !out_instance_count ||
       !ao46_metal_primitive_info(primitive, &vertices_per_primitive, NULL) ||
       !AO46MetalBufferIsCurrent(indirect_binding->buffer) ||
       indirect_binding->buffer->adapter != adapter ||
       indirect_binding->offset % sizeof(uint32_t) != 0 ||
       !ao46_metal_indirect_count_binding_is_valid(adapter, indirect_binding) ||
       indirect_binding->draw_count == 0 ||
       indirect_binding->draw_count > AO46_METAL_MAX_INDIRECT_DRAWS)
      return false;

   /*
    * Mesa-owned compute work may author a bounded sequence of indexed records.
    * Keep the sequence GPU-resident: the caller admits only attribute-free
    * pipelines, so no indirect record can select a vertex-buffer range.
    */
   if (indirect_binding->gpu_generated) {
      const size_t argument_size =
         sizeof(struct AO46MetalDrawIndexedIndirectArguments);
      const size_t argument_stride = indirect_binding->stride
                                        ? indirect_binding->stride
                                        : argument_size;
      const size_t maximum_index_bytes =
         (size_t)indirect_binding->maximum_index_count * sizeof(uint32_t);
      size_t required_size;

      if (!index_binding ||
          (indirect_binding->stride &&
           indirect_binding->stride != argument_size) ||
          argument_stride != argument_size ||
          indirect_binding->draw_count - 1 >
             (SIZE_MAX - argument_size) / argument_stride ||
          indirect_binding->offset > indirect_binding->buffer->length ||
          (required_size =
              (size_t)(indirect_binding->draw_count - 1) * argument_stride +
              argument_size) >
             indirect_binding->buffer->length - indirect_binding->offset ||
          !AO46MetalBufferIsCurrent(index_binding->buffer) ||
          index_binding->buffer->adapter != adapter ||
          index_binding->format != AO46_METAL_INDEX_FORMAT_UINT32 ||
          index_binding->primitive_restart ||
          indirect_binding->maximum_index_count < vertices_per_primitive ||
          maximum_index_bytes > index_binding->size ||
          index_binding->offset > index_binding->buffer->length ||
          index_binding->size >
             index_binding->buffer->length - index_binding->offset)
         return false;

      *out_vertex_span = 0;
      *out_instance_count = 1;
      return true;
   }

   if (!indirect_binding->buffer->cpu_mapping)
      return false;

   argument_size = index_binding ? sizeof(struct AO46MetalDrawIndexedIndirectArguments)
                                 : sizeof(struct AO46MetalDrawIndirectArguments);
   argument_stride = indirect_binding->stride ? indirect_binding->stride
                                               : argument_size;
   if (argument_stride < argument_size ||
       argument_stride % sizeof(uint32_t) != 0 ||
       (indirect_binding->draw_count > 1 &&
        indirect_binding->stride != argument_size) ||
       indirect_binding->draw_count - 1 >
          (SIZE_MAX - argument_size) / argument_stride)
      return false;
   required_size = (size_t)(indirect_binding->draw_count - 1) * argument_stride +
                   argument_size;
   if (indirect_binding->offset > indirect_binding->buffer->length ||
       required_size > indirect_binding->buffer->length - indirect_binding->offset)
      return false;

   for (uint32_t draw = 0; draw < indirect_binding->draw_count; ++draw) {
      const uint8_t *argument_bytes =
         (const uint8_t *)indirect_binding->buffer->cpu_mapping +
         indirect_binding->offset + (size_t)draw * argument_stride;
      size_t vertex_span;
      uint32_t instance_count;
      uint32_t base_instance;

      if (index_binding) {
         struct AO46MetalDrawIndexedIndirectArguments arguments;
         struct AO46MetalIndexBufferBinding draw_index_binding;
         MTLIndexType ignored_index_type;
         size_t index_size;

         if (index_binding->primitive_restart)
            return false;
         switch (index_binding->format) {
         case AO46_METAL_INDEX_FORMAT_UINT16:
            index_size = sizeof(uint16_t);
            break;
         case AO46_METAL_INDEX_FORMAT_UINT32:
            index_size = sizeof(uint32_t);
            break;
         default:
            return false;
         }

         memcpy(&arguments, argument_bytes, sizeof(arguments));
         if (arguments.index_count < vertices_per_primitive ||
             arguments.index_count % vertices_per_primitive != 0 ||
             arguments.instance_count == 0 ||
             arguments.index_start > SIZE_MAX / index_size ||
             arguments.index_count > SIZE_MAX / index_size)
            return false;

         draw_index_binding = (struct AO46MetalIndexBufferBinding){
            .buffer = index_binding->buffer,
            .offset = index_binding->offset +
                      (size_t)arguments.index_start * index_size,
            .size = (size_t)arguments.index_count * index_size,
            .count = arguments.index_count,
            .format = index_binding->format,
            .base_vertex = arguments.base_vertex,
         };
         if (!ao46_metal_index_binding_vertex_span(
                adapter, &draw_index_binding, primitive, 0, 0, &vertex_span,
                &ignored_index_type))
            return false;
         instance_count = arguments.instance_count;
         base_instance = arguments.base_instance;
      } else {
         struct AO46MetalDrawIndirectArguments arguments;
         MTLIndexType ignored_index_type;

         memcpy(&arguments, argument_bytes, sizeof(arguments));
         if (arguments.instance_count == 0 ||
             !ao46_metal_index_binding_vertex_span(
                adapter, NULL, primitive, arguments.vertex_start,
                arguments.vertex_count,
                &vertex_span, &ignored_index_type))
            return false;
         instance_count = arguments.instance_count;
         base_instance = arguments.base_instance;
      }

      if ((uint64_t)base_instance + instance_count > UINT32_MAX)
         return false;
      if (vertex_span > maximum_vertex_span)
         maximum_vertex_span = vertex_span;
      if ((uint64_t)base_instance + instance_count > maximum_instance_end)
         maximum_instance_end = (uint64_t)base_instance + instance_count;
   }

   *out_vertex_span = maximum_vertex_span;
   *out_instance_count = (uint32_t)maximum_instance_end;
   return maximum_vertex_span != 0 && maximum_instance_end != 0;
}

static bool
ao46_metal_vertex_attribute_element_count(
   const struct AO46MetalVertexAttribute *attribute, size_t vertex_span,
   uint32_t instance_count, uint32_t base_instance, size_t *out_element_count)
{
   uint64_t instance_end;

   if (!attribute || !out_element_count || instance_count == 0)
      return false;

   if (attribute->instance_divisor == 0) {
      *out_element_count = vertex_span;
      return vertex_span != 0;
   }

   instance_end = (uint64_t)base_instance + instance_count;
   *out_element_count = (size_t)((instance_end + attribute->instance_divisor - 1) /
                                 attribute->instance_divisor);
   return *out_element_count != 0;
}

/* Metal has no primitive-restart switch, so primitive-list runs are emitted separately. */
static void
ao46_metal_encode_indexed_primitives(
   id<MTLRenderCommandEncoder> encoder,
   const struct AO46MetalIndexBufferBinding *index_binding,
   MTLIndexType index_type, enum AO46MetalPrimitive primitive,
   uint32_t instance_count, uint32_t base_instance)
{
   const uint8_t *bytes = (const uint8_t *)index_binding->buffer->cpu_mapping +
                          index_binding->offset;
   const size_t index_size = index_binding->format == AO46_METAL_INDEX_FORMAT_UINT16
                                ? sizeof(uint16_t)
                                : sizeof(uint32_t);
   id<MTLBuffer> index_buffer =
      (__bridge id<MTLBuffer>)index_binding->buffer->native_buffer;
   uint32_t run_start = 0;
   uint32_t run_count = 0;
   MTLPrimitiveType native_primitive;

   if (!ao46_metal_primitive_info(primitive, NULL, &native_primitive))
      return;

   for (uint32_t i = 0; i < index_binding->count; ++i) {
      const uint32_t index = index_binding->format == AO46_METAL_INDEX_FORMAT_UINT16
                                ? ((const uint16_t *)bytes)[i]
                                : ((const uint32_t *)bytes)[i];

      if (index_binding->primitive_restart && index == index_binding->restart_index) {
         if (run_count != 0) {
            [encoder drawIndexedPrimitives:native_primitive
                                 indexCount:run_count
                                  indexType:index_type
                                indexBuffer:index_buffer
                          indexBufferOffset:index_binding->offset +
                                            (size_t)run_start * index_size
                           instanceCount:instance_count
                              baseVertex:index_binding->base_vertex
                            baseInstance:base_instance];
         }
         run_start = i + 1;
         run_count = 0;
         continue;
      }

      ++run_count;
   }

   if (run_count != 0) {
      [encoder drawIndexedPrimitives:native_primitive
                           indexCount:run_count
                            indexType:index_type
                          indexBuffer:index_buffer
                    indexBufferOffset:index_binding->offset +
                                      (size_t)run_start * index_size
                     instanceCount:instance_count
                        baseVertex:index_binding->base_vertex
                      baseInstance:base_instance];
   }
}

static bool
ao46_metal_uniform_bindings_are_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalUniformBufferBinding *bindings, size_t binding_count)
{
   uint16_t observed_mask = 0;

   if ((binding_count == 0 && bindings) ||
       (binding_count != 0 && !bindings) ||
       binding_count > AO46_METAL_MAX_UNIFORM_BINDINGS)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      const struct AO46MetalUniformBufferBinding *binding = &bindings[i];
      uint16_t bit;

      if (binding->binding >= AO46_METAL_MAX_UNIFORM_BINDINGS)
         return false;
      bit = UINT16_C(1) << binding->binding;
      if (!(pipeline->uniform_mask & bit) || (observed_mask & bit) ||
          !AO46MetalBufferIsCurrent(binding->buffer) ||
          binding->buffer->adapter != adapter ||
          binding->size < pipeline->uniform_bytes[binding->binding] ||
          binding->offset > binding->buffer->length ||
          binding->size > binding->buffer->length - binding->offset)
         return false;

      observed_mask |= bit;
   }

   return observed_mask == pipeline->uniform_mask;
}

static bool
ao46_metal_buffer_is_empty(const struct AO46MetalBuffer *buffer)
{
   return buffer && !buffer->adapter && !buffer->native_buffer &&
          !buffer->cpu_mapping && buffer->gpu_address == 0 &&
          buffer->length == 0;
}

static bool
ao46_metal_texture_is_empty(const struct AO46MetalTexture *texture)
{
   return texture && !texture->adapter && !texture->native_texture &&
          !texture->native_iosurface &&
          texture->width == 0 && texture->height == 0 &&
          texture->format == AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
}

static bool
ao46_metal_sampler_is_empty(const struct AO46MetalSampler *sampler)
{
   return sampler && !sampler->adapter && !sampler->native_sampler;
}

static bool
ao46_metal_texture_bindings_are_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTextureBinding *bindings, size_t binding_count,
   uint64_t required_mask, const struct AO46MetalTexture *color_target)
{
   uint64_t observed_mask = 0;

   if ((binding_count == 0 && bindings) ||
       (binding_count != 0 && !bindings) ||
       binding_count > AO46_METAL_MAX_STATIC_BUFFER_BINDINGS)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      uint64_t bit;

      if (bindings[i].index >= AO46_METAL_MAX_STATIC_BINDINGS ||
          !AO46MetalTextureIsCurrent(bindings[i].texture) ||
          bindings[i].texture->adapter != adapter ||
          bindings[i].texture == color_target)
         return false;

      bit = UINT64_C(1) << bindings[i].index;
      if (!(required_mask & bit) || (observed_mask & bit))
         return false;
      observed_mask |= bit;
   }

   return observed_mask == required_mask;
}

static bool
ao46_metal_sampler_bindings_are_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalSamplerBinding *bindings, size_t binding_count,
   uint64_t required_mask)
{
   uint64_t observed_mask = 0;

   if ((binding_count == 0 && bindings) ||
       (binding_count != 0 && !bindings) ||
       binding_count > AO46_METAL_MAX_STATIC_BINDINGS)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      uint64_t bit;

      if (bindings[i].index >= AO46_METAL_MAX_STATIC_BINDINGS ||
          !AO46MetalSamplerIsCurrent(bindings[i].sampler) ||
          bindings[i].sampler->adapter != adapter)
         return false;

      bit = UINT64_C(1) << bindings[i].index;
      if (!(required_mask & bit) || (observed_mask & bit))
         return false;
      observed_mask |= bit;
   }

   return observed_mask == required_mask;
}

static bool
ao46_metal_static_buffer_bindings_are_valid(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint16_t required_mask,
   const size_t required_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS])
{
   uint16_t observed_mask = 0;

   if (!required_bytes || (binding_count == 0 && bindings) ||
       (binding_count != 0 && !bindings) ||
       binding_count > AO46_METAL_MAX_STATIC_BINDINGS)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      const struct AO46MetalBufferBinding *binding = &bindings[i];
      uint16_t bit;

      /* Slots zero and one are the fixed KosmicKrisp graphics ABI. */
      if (binding->index < 2 ||
          binding->index >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
          !AO46MetalBufferIsCurrent(binding->buffer) ||
          binding->buffer->adapter != adapter ||
          binding->offset > binding->buffer->length ||
          binding->size > binding->buffer->length - binding->offset)
         return false;

      bit = UINT16_C(1) << binding->index;
      if (!(required_mask & bit) || (observed_mask & bit))
         return false;
      if (binding->size < required_bytes[binding->index])
         return false;
      observed_mask |= bit;
   }

   return observed_mask == required_mask;
}

static MTLPixelFormat
ao46_metal_pixel_format(enum AO46MetalTextureFormat format)
{
   switch (format) {
   case AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM:
      return MTLPixelFormatRGBA8Unorm;
   case AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM:
      return MTLPixelFormatBGRA8Unorm;
   }

   return MTLPixelFormatInvalid;
}

static uint32_t
ao46_metal_iosurface_pixel_format(enum AO46MetalTextureFormat format)
{
   switch (format) {
   case AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM:
      return UINT32_C(0x52474241); /* FourCC 'RGBA'. */
   case AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM:
      return UINT32_C(0x42475241); /* FourCC 'BGRA'. */
   }

   return 0;
}

static bool
ao46_metal_texture_dimensions_are_valid(const struct AO46MetalTexture *texture,
                                        uint32_t width, uint32_t height)
{
   return AO46MetalTextureIsCurrent(texture) && width > 0 && height > 0 &&
          width <= texture->width && height <= texture->height;
}

static bool
ao46_metal_submission_is_empty(const struct AO46MetalSubmission *submission)
{
   return submission && !submission->adapter && !submission->native_command_buffer &&
          !submission->native_command_allocator &&
          !submission->native_argument_table &&
          !submission->native_commit_options &&
          !submission->native_completion_state &&
          !submission->native_presentation_drawable &&
          !submission->native_presentation_allocation &&
          !submission->uses_mtl4;
}

static void
ao46_metal_mtl4_make_resident(const struct AO46MetalAdapter *adapter)
{
   if (!adapter || !adapter->mtl4_submission_enabled ||
       !adapter->mtl4_residency_set)
      return;

   @synchronized ((__bridge id)adapter->mtl4_residency_set) {
      mtl_residency_set_commit(
         (mtl_residency_set *)adapter->mtl4_residency_set);
      mtl_residency_set_request_residency(
         (mtl_residency_set *)adapter->mtl4_residency_set);
   }
}

static void
ao46_metal_mtl4_add_allocation(const struct AO46MetalAdapter *adapter,
                               void *allocation)
{
   if (!adapter || !adapter->mtl4_submission_enabled ||
       !adapter->mtl4_residency_set || !allocation)
      return;

   @synchronized ((__bridge id)adapter->mtl4_residency_set) {
      mtl_residency_set_add_allocation(
         (mtl_residency_set *)adapter->mtl4_residency_set,
         (mtl_allocation *)allocation);
      mtl_residency_set_commit(
         (mtl_residency_set *)adapter->mtl4_residency_set);
      mtl_residency_set_request_residency(
         (mtl_residency_set *)adapter->mtl4_residency_set);
   }
}

static void
ao46_metal_mtl4_remove_allocation(const struct AO46MetalAdapter *adapter,
                                  void *allocation)
{
   if (!adapter || !adapter->mtl4_submission_enabled ||
       !adapter->mtl4_residency_set || !allocation)
      return;

   @synchronized ((__bridge id)adapter->mtl4_residency_set) {
      mtl_residency_set_remove_allocation(
         (mtl_residency_set *)adapter->mtl4_residency_set,
         (mtl_allocation *)allocation);
      mtl_residency_set_commit(
         (mtl_residency_set *)adapter->mtl4_residency_set);
   }
}

/* Converts Gallium's one-word indirect count into Metal's ICB execution range. */
static id<MTLComputePipelineState>
ao46_metal_create_indirect_count_range_pipeline(id<MTLDevice> device)
{
   static const char source[] =
      "#include <metal_stdlib>\n"
      "using namespace metal;\n"
      "kernel void ao46_indirect_count_range(\n"
      "  device const uint *count [[buffer(0)]],\n"
      "  device uint2 *range [[buffer(1)]],\n"
      "  constant uint &maximum [[buffer(2)]],\n"
      "  uint lane [[thread_position_in_grid]]) {\n"
      "  if (lane == 0) range[0] = uint2(0, min(count[0], maximum));\n"
      "}\n";
   NSError *error = nil;
   id<MTLLibrary> library;
   id<MTLFunction> function;

   if (!device)
      return nil;

   library = [device newLibraryWithSource:[NSString stringWithUTF8String:source]
                                   options:nil error:&error];
   function = library && !error
                 ? [library newFunctionWithName:@"ao46_indirect_count_range"]
                 : nil;
   return function ? [device newComputePipelineStateWithFunction:function
                                                            error:&error]
                   : nil;
}

bool
AO46MetalAdapterCreate(struct AO46MetalAdapter *out_adapter)
{
   __block bool created = false;

   if (!out_adapter || !ao46_metal_adapter_is_empty(out_adapter))
      return false;

   @autoreleasepool {
      /* KK selects an actual Metal 4 device instead of the generic default. */
      id<MTLDevice> device =
         (__bridge_transfer id<MTLDevice>)mtl_device_create();
      id<MTLCommandQueue> queue = device ? [device newCommandQueue] : nil;
      id<MTLBuffer> root_buffer =
         device ? [device newBufferWithLength:AO46_MESA_ROOT_BUFFER_BYTES
                                      options:MTLResourceStorageModeShared]
                : nil;
      id<MTLBuffer> sampler_table_buffer =
         device ? [device newBufferWithLength:AO46_MESA_SAMPLER_TABLE_BYTES
                                      options:MTLResourceStorageModeShared]
                : nil;
      id<MTLComputePipelineState> indirect_count_range_pipeline =
         ao46_metal_create_indirect_count_range_pipeline(device);
      mtl_command_queue *mtl4_queue = NULL;
      mtl_residency_set *mtl4_residency_set = NULL;
      mtl_event *mtl4_ordering_event = NULL;
      mtl_compiler *mtl4_compiler = NULL;
      AO46MetalMTL4SharedState *mtl4_shared_state = nil;
      bool gpu_addressable_buffers = false;
      bool mtl4_submission_enabled = false;

      if (@available(macOS 13.0, *)) {
         gpu_addressable_buffers = root_buffer.gpuAddress != 0 &&
                                   sampler_table_buffer.gpuAddress != 0;
      }

      if (queue && root_buffer && sampler_table_buffer &&
          indirect_count_range_pipeline && device.maxBufferLength > 0) {
         if (@available(macOS 26.0, *)) {
            mtl4_queue = mtl_new_command_queue(
               (__bridge mtl_device *)device);
            mtl4_residency_set = mtl_new_residency_set(
               (__bridge mtl_device *)device);
            mtl4_ordering_event = mtl_new_event((__bridge mtl_device *)device);
            mtl4_compiler = mtl_new_compiler((__bridge mtl_device *)device);
            if (mtl4_queue && mtl4_residency_set && mtl4_ordering_event &&
                mtl4_compiler) {
               mtl_command_queue_add_residency_set(mtl4_queue,
                                                   mtl4_residency_set);
               mtl_residency_set_add_allocation(
                  mtl4_residency_set, (__bridge mtl_allocation *)root_buffer);
               mtl_residency_set_add_allocation(
                  mtl4_residency_set,
                  (__bridge mtl_allocation *)sampler_table_buffer);
               mtl_residency_set_commit(mtl4_residency_set);
               mtl_residency_set_request_residency(mtl4_residency_set);
               mtl4_shared_state = [[AO46MetalMTL4SharedState alloc]
                  initWithQueue:mtl4_queue residencySet:mtl4_residency_set
                   orderingEvent:mtl4_ordering_event compiler:mtl4_compiler];
               if (mtl4_shared_state) {
                  mtl4_submission_enabled = gpu_addressable_buffers;
               } else {
                  mtl_command_queue_remove_residency_set(mtl4_queue,
                                                         mtl4_residency_set);
                  mtl_release(mtl4_compiler);
                  mtl_release(mtl4_ordering_event);
                  mtl_release(mtl4_residency_set);
                  mtl_release(mtl4_queue);
                  mtl4_residency_set = NULL;
                  mtl4_queue = NULL;
                  mtl4_ordering_event = NULL;
                  mtl4_compiler = NULL;
               }
            } else {
               if (mtl4_compiler)
                  mtl_release(mtl4_compiler);
               if (mtl4_ordering_event)
                  mtl_release(mtl4_ordering_event);
               if (mtl4_residency_set)
                  mtl_release(mtl4_residency_set);
               if (mtl4_queue)
                  mtl_release(mtl4_queue);
               mtl4_residency_set = NULL;
               mtl4_queue = NULL;
               mtl4_ordering_event = NULL;
               mtl4_compiler = NULL;
            }
         }

         out_adapter->device = (__bridge_retained void *)device;
         out_adapter->queue = (__bridge_retained void *)queue;
         out_adapter->mtl4_queue = mtl4_queue;
         out_adapter->mtl4_residency_set = mtl4_residency_set;
         out_adapter->mtl4_shared_state =
            mtl4_shared_state ? (__bridge_retained void *)mtl4_shared_state : NULL;
         out_adapter->graphics_root_buffer = (__bridge_retained void *)root_buffer;
         out_adapter->graphics_sampler_table_buffer =
            (__bridge_retained void *)sampler_table_buffer;
         out_adapter->indirect_count_range_pipeline =
            (__bridge_retained void *)indirect_count_range_pipeline;
         out_adapter->registry_id =
            mtl_device_get_registry_id((__bridge mtl_device *)device);
         out_adapter->max_buffer_length =
            (size_t)mtl_device_max_buffer_length((__bridge mtl_device *)device);
         out_adapter->max_texture_dimension_2d =
            AO46_METAL_BOOTSTRAP_MAX_TEXTURE_DIMENSION_2D;
         if (@available(macOS 10.15, *))
            out_adapter->unified_memory = device.hasUnifiedMemory;
         out_adapter->gpu_addressable_buffers = gpu_addressable_buffers;
         out_adapter->mtl4_submission_enabled = mtl4_submission_enabled;
         created = true;
      }
   }

   return created;
}

void
AO46MetalAdapterDestroy(struct AO46MetalAdapter *adapter)
{
   if (!adapter)
      return;

   if (adapter->mtl4_shared_state)
      CFBridgingRelease(adapter->mtl4_shared_state);
   if (adapter->indirect_count_range_pipeline)
      CFBridgingRelease(adapter->indirect_count_range_pipeline);
   if (adapter->graphics_sampler_table_buffer)
      CFBridgingRelease(adapter->graphics_sampler_table_buffer);
   if (adapter->graphics_root_buffer)
      CFBridgingRelease(adapter->graphics_root_buffer);
   if (adapter->queue)
      CFBridgingRelease(adapter->queue);
   if (adapter->device)
      CFBridgingRelease(adapter->device);
   *adapter = (struct AO46MetalAdapter){0};
}

bool
AO46MetalAdapterIsCurrent(const struct AO46MetalAdapter *adapter)
{
   id<MTLDevice> device;
   id<MTLCommandQueue> queue;
   id<MTLBuffer> root_buffer;
   id<MTLBuffer> sampler_table_buffer;

   if (!adapter || !adapter->device || !adapter->queue ||
       !adapter->graphics_root_buffer || !adapter->graphics_sampler_table_buffer ||
       !adapter->indirect_count_range_pipeline ||
       adapter->registry_id == 0 || adapter->max_buffer_length == 0 ||
       adapter->max_texture_dimension_2d == 0)
      return false;

   if (adapter->mtl4_submission_enabled &&
       (!adapter->mtl4_queue || !adapter->mtl4_residency_set ||
        !adapter->mtl4_shared_state ||
        !adapter->gpu_addressable_buffers))
      return false;

   if (adapter->mtl4_submission_enabled) {
      AO46MetalMTL4SharedState *shared =
         (__bridge AO46MetalMTL4SharedState *)adapter->mtl4_shared_state;

      if (!shared || !shared->_compiler)
         return false;
   }

   device = (__bridge id<MTLDevice>)adapter->device;
   queue = (__bridge id<MTLCommandQueue>)adapter->queue;
   root_buffer = (__bridge id<MTLBuffer>)adapter->graphics_root_buffer;
   sampler_table_buffer =
      (__bridge id<MTLBuffer>)adapter->graphics_sampler_table_buffer;

   if (queue.device != device || root_buffer.device != device ||
       sampler_table_buffer.device != device ||
       root_buffer.length < AO46_MESA_ROOT_BUFFER_BYTES ||
       sampler_table_buffer.length < AO46_MESA_SAMPLER_TABLE_BYTES ||
       device.registryID != adapter->registry_id)
      return false;

   if (!adapter->gpu_addressable_buffers)
      return true;

   if (@available(macOS 13.0, *))
      return root_buffer.gpuAddress != 0 && sampler_table_buffer.gpuAddress != 0;

   return false;
}

bool
AO46MetalAdapterSupportsGPUAddress(const struct AO46MetalAdapter *adapter)
{
   return AO46MetalAdapterIsCurrent(adapter) &&
          adapter->gpu_addressable_buffers;
}

bool
AO46MetalAdapterSupportsMTL4Submission(const struct AO46MetalAdapter *adapter)
{
   return AO46MetalAdapterSupportsGPUAddress(adapter) &&
          adapter->mtl4_submission_enabled && adapter->mtl4_queue &&
          adapter->mtl4_residency_set;
}

bool
AO46MetalAdapterTrackExternalAllocation(
   const struct AO46MetalAdapter *adapter, void *native_allocation)
{
   if (!AO46MetalAdapterIsCurrent(adapter) || !native_allocation)
      return false;

   ao46_metal_mtl4_add_allocation(adapter, native_allocation);
   return true;
}

void
AO46MetalAdapterUntrackExternalAllocation(
   const struct AO46MetalAdapter *adapter, void *native_allocation)
{
   if (!adapter || !native_allocation)
      return;

   ao46_metal_mtl4_remove_allocation(adapter, native_allocation);
}

bool
AO46MetalAdapterCopyRetained(const struct AO46MetalAdapter *adapter,
                             struct AO46MetalAdapter *out_adapter)
{
   if (!AO46MetalAdapterIsCurrent(adapter) || !out_adapter ||
       !ao46_metal_adapter_is_empty(out_adapter))
      return false;

   *out_adapter = *adapter;
   out_adapter->device = (void *)CFRetain((CFTypeRef)adapter->device);
   out_adapter->queue = (void *)CFRetain((CFTypeRef)adapter->queue);
   if (adapter->mtl4_shared_state)
      out_adapter->mtl4_shared_state =
         (void *)CFRetain((CFTypeRef)adapter->mtl4_shared_state);
   out_adapter->graphics_root_buffer =
      (void *)CFRetain((CFTypeRef)adapter->graphics_root_buffer);
   out_adapter->graphics_sampler_table_buffer =
      (void *)CFRetain((CFTypeRef)adapter->graphics_sampler_table_buffer);
   out_adapter->indirect_count_range_pipeline =
      (void *)CFRetain((CFTypeRef)adapter->indirect_count_range_pipeline);
   return true;
}

bool
AO46MetalSubmissionBegin(const struct AO46MetalAdapter *adapter,
                         struct AO46MetalSubmission *out_submission)
{
   if (!AO46MetalAdapterIsCurrent(adapter) || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission))
      return false;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

      if (!command_buffer)
         return false;

      *out_submission = (struct AO46MetalSubmission){
         .adapter = adapter,
         .native_command_buffer = (__bridge_retained void *)command_buffer,
      };
   }

   return true;
}

bool
AO46MetalSubmissionCommit(struct AO46MetalSubmission *submission, bool wait)
{
   id<MTLCommandBuffer> command_buffer;

   if (!submission || !AO46MetalAdapterIsCurrent(submission->adapter) ||
       !submission->native_command_buffer)
      return false;

   if (submission->uses_mtl4)
      return !wait || AO46MetalSubmissionWait(submission);

   command_buffer = (__bridge id<MTLCommandBuffer>)submission->native_command_buffer;
   if (command_buffer.status != MTLCommandBufferStatusNotEnqueued)
      return false;

   [command_buffer commit];
   return !wait || AO46MetalSubmissionWait(submission);
}

bool
AO46MetalBufferCreate(const struct AO46MetalAdapter *adapter, size_t length,
                      struct AO46MetalBuffer *out_buffer)
{
   __block bool created = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !out_buffer ||
       !ao46_metal_buffer_is_empty(out_buffer) || length == 0 ||
      length > NSUIntegerMax || length > adapter->max_buffer_length)
      return false;

   @autoreleasepool {
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      id<MTLBuffer> buffer =
         [device newBufferWithLength:(NSUInteger)length
                              options:MTLResourceStorageModeShared];
      void *contents = buffer ? buffer.contents : NULL;
      uint64_t gpu_address = 0;

      if (@available(macOS 13.0, *))
         gpu_address = buffer.gpuAddress;

      if (buffer && buffer.length == (NSUInteger)length && contents) {
         *out_buffer = (struct AO46MetalBuffer){
            .adapter = adapter,
            .native_buffer = (__bridge_retained void *)buffer,
            .cpu_mapping = contents,
            .gpu_address = gpu_address,
            .length = length,
         };
         ao46_metal_mtl4_add_allocation(adapter, out_buffer->native_buffer);
         created = true;
      }
   }

   return created;
}

void
AO46MetalBufferDestroy(struct AO46MetalBuffer *buffer)
{
   if (!buffer)
      return;

   ao46_metal_mtl4_remove_allocation(buffer->adapter, buffer->native_buffer);
   if (buffer->native_buffer)
      CFBridgingRelease(buffer->native_buffer);
   *buffer = (struct AO46MetalBuffer){0};
}

bool
AO46MetalBufferIsCurrent(const struct AO46MetalBuffer *buffer)
{
   id<MTLBuffer> native_buffer;

   if (!buffer || !AO46MetalAdapterIsCurrent(buffer->adapter) ||
       !buffer->native_buffer || !buffer->cpu_mapping || buffer->length == 0)
      return false;

   native_buffer = (__bridge id<MTLBuffer>)buffer->native_buffer;
   if (native_buffer.device != (__bridge id<MTLDevice>)buffer->adapter->device ||
       native_buffer.length != buffer->length ||
       native_buffer.contents != buffer->cpu_mapping)
      return false;

   if (buffer->gpu_address == 0)
      return true;

   if (@available(macOS 13.0, *))
      return native_buffer.gpuAddress == buffer->gpu_address;

   return false;
}

bool
AO46MetalBufferGetGPUAddress(const struct AO46MetalBuffer *buffer,
                             uint64_t *out_gpu_address)
{
   if (!out_gpu_address || !AO46MetalBufferIsCurrent(buffer) ||
       !AO46MetalAdapterSupportsGPUAddress(buffer->adapter) ||
       buffer->gpu_address == 0)
      return false;

   *out_gpu_address = buffer->gpu_address;
   return true;
}

bool
AO46MetalBufferWriteGPUAddressRoot(struct AO46MetalBuffer *root,
                                   size_t root_offset,
                                   const struct AO46MetalBuffer *target,
                                   size_t target_offset)
{
   uint64_t address;

   if (!root || !target || !AO46MetalBufferIsCurrent(root) ||
       !root->cpu_mapping ||
       root->adapter != target->adapter ||
       !AO46MetalBufferGetGPUAddress(target, &address) ||
       root_offset % _Alignof(uint64_t) != 0 ||
       root_offset > root->length ||
       sizeof(address) > root->length - root_offset ||
       target_offset >= target->length ||
       target_offset > UINT64_MAX - address)
      return false;

   address += target_offset;
   memcpy((uint8_t *)root->cpu_mapping + root_offset, &address, sizeof(address));
   return true;
}

bool
AO46MetalTextureCreate(const struct AO46MetalAdapter *adapter, uint32_t width,
                       uint32_t height, enum AO46MetalTextureFormat format,
                       struct AO46MetalTexture *out_texture)
{
   __block bool created = false;
   MTLPixelFormat pixel_format = ao46_metal_pixel_format(format);

   if (!AO46MetalAdapterIsCurrent(adapter) || !out_texture ||
       !ao46_metal_texture_is_empty(out_texture) ||
       pixel_format == MTLPixelFormatInvalid || width == 0 || height == 0 ||
       width > adapter->max_texture_dimension_2d ||
       height > adapter->max_texture_dimension_2d)
      return false;

   @autoreleasepool {
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      MTLTextureDescriptor *descriptor =
         [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format
                                                              width:width
                                                             height:height
                                                          mipmapped:NO];
      descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      descriptor.storageMode = MTLStorageModePrivate;
      id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];

      if (texture && texture.width == width && texture.height == height &&
          texture.pixelFormat == pixel_format) {
         *out_texture = (struct AO46MetalTexture){
            .adapter = adapter,
            .native_texture = (__bridge_retained void *)texture,
            .width = width,
            .height = height,
            .format = format,
         };
         ao46_metal_mtl4_add_allocation(adapter, out_texture->native_texture);
         created = true;
      }
   }

   return created;
}

bool
AO46MetalTextureImportIOSurface(
   const struct AO46MetalAdapter *adapter, void *native_iosurface,
   enum AO46MetalTextureFormat format, struct AO46MetalTexture *out_texture)
{
   __block bool imported = false;
   const MTLPixelFormat pixel_format = ao46_metal_pixel_format(format);
   const uint32_t surface_format = ao46_metal_iosurface_pixel_format(format);

   if (!AO46MetalAdapterIsCurrent(adapter) || !native_iosurface ||
       !out_texture || !ao46_metal_texture_is_empty(out_texture) ||
       pixel_format == MTLPixelFormatInvalid || surface_format == 0)
      return false;

   @autoreleasepool {
      IOSurfaceRef surface = (IOSurfaceRef)native_iosurface;
      const size_t width = IOSurfaceGetWidth(surface);
      const size_t height = IOSurfaceGetHeight(surface);
      const size_t bytes_per_element = IOSurfaceGetBytesPerElement(surface);
      const size_t bytes_per_row = IOSurfaceGetBytesPerRow(surface);
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      MTLTextureDescriptor *descriptor;
      id<MTLTexture> texture;

      if (IOSurfaceGetPlaneCount(surface) != 0 ||
          IOSurfaceGetPixelFormat(surface) != surface_format ||
          bytes_per_element != 4 || width == 0 || height == 0 ||
          width > adapter->max_texture_dimension_2d ||
          height > adapter->max_texture_dimension_2d ||
          width > UINT32_MAX || height > UINT32_MAX ||
          width > SIZE_MAX / bytes_per_element ||
          bytes_per_row < width * bytes_per_element)
         return false;

      descriptor =
         [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format
                                                             width:width
                                                            height:height
                                                         mipmapped:NO];
      descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      descriptor.storageMode = MTLStorageModeShared;
      texture = [device newTextureWithDescriptor:descriptor
                                        iosurface:surface
                                            plane:0];

      if (!texture || texture.width != width || texture.height != height ||
          texture.pixelFormat != pixel_format)
         return false;

      *out_texture = (struct AO46MetalTexture){
         .adapter = adapter,
         .native_texture = (__bridge_retained void *)texture,
         .native_iosurface = (void *)CFRetain(surface),
         .width = (uint32_t)width,
         .height = (uint32_t)height,
         .format = format,
      };
      ao46_metal_mtl4_add_allocation(adapter, out_texture->native_texture);
      imported = true;
   }

   return imported;
}

void
AO46MetalTextureDestroy(struct AO46MetalTexture *texture)
{
   if (!texture)
      return;

   ao46_metal_mtl4_remove_allocation(texture->adapter,
                                     texture->native_texture);
   if (texture->native_texture)
      CFBridgingRelease(texture->native_texture);
   if (texture->native_iosurface)
      CFRelease(texture->native_iosurface);
   *texture = (struct AO46MetalTexture){0};
}

bool
AO46MetalTextureIsCurrent(const struct AO46MetalTexture *texture)
{
   id<MTLTexture> native_texture;

   if (!texture || !AO46MetalAdapterIsCurrent(texture->adapter) ||
       !texture->native_texture || texture->width == 0 || texture->height == 0 ||
       ao46_metal_pixel_format(texture->format) == MTLPixelFormatInvalid)
      return false;

   native_texture = (__bridge id<MTLTexture>)texture->native_texture;
   return native_texture.device ==
             (__bridge id<MTLDevice>)texture->adapter->device &&
          native_texture.width == texture->width &&
          native_texture.height == texture->height &&
          native_texture.pixelFormat == ao46_metal_pixel_format(texture->format);
}

static bool
ao46_metal_sampler_filter(enum AO46MetalSamplerFilter filter,
                          MTLSamplerMinMagFilter *out_filter)
{
   if (!out_filter)
      return false;

   switch (filter) {
   case AO46_METAL_SAMPLER_FILTER_NEAREST:
      *out_filter = MTLSamplerMinMagFilterNearest;
      return true;
   case AO46_METAL_SAMPLER_FILTER_LINEAR:
      *out_filter = MTLSamplerMinMagFilterLinear;
      return true;
   default:
      return false;
   }
}

static bool
ao46_metal_sampler_address_mode(enum AO46MetalSamplerAddressMode address_mode,
                                MTLSamplerAddressMode *out_address_mode)
{
   if (!out_address_mode)
      return false;

   switch (address_mode) {
   case AO46_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE:
      *out_address_mode = MTLSamplerAddressModeClampToEdge;
      return true;
   case AO46_METAL_SAMPLER_ADDRESS_REPEAT:
      *out_address_mode = MTLSamplerAddressModeRepeat;
      return true;
   default:
      return false;
   }
}

bool
AO46MetalSamplerCreate(const struct AO46MetalAdapter *adapter,
                       const struct AO46MetalSamplerDescriptor *descriptor,
                       struct AO46MetalSampler *out_sampler)
{
   __block bool created = false;
   MTLSamplerMinMagFilter min_filter;
   MTLSamplerMinMagFilter mag_filter;
   MTLSamplerAddressMode address_s;
   MTLSamplerAddressMode address_t;
   MTLSamplerAddressMode address_r;

   if (!AO46MetalAdapterIsCurrent(adapter) || !descriptor || !out_sampler ||
       !ao46_metal_sampler_is_empty(out_sampler) ||
       !ao46_metal_sampler_filter(descriptor->min_filter, &min_filter) ||
       !ao46_metal_sampler_filter(descriptor->mag_filter, &mag_filter) ||
       !ao46_metal_sampler_address_mode(descriptor->address_s, &address_s) ||
       !ao46_metal_sampler_address_mode(descriptor->address_t, &address_t) ||
       !ao46_metal_sampler_address_mode(descriptor->address_r, &address_r))
      return false;

   @autoreleasepool {
      MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
      id<MTLSamplerState> native_sampler;

      descriptor.minFilter = min_filter;
      descriptor.magFilter = mag_filter;
      descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
      descriptor.sAddressMode = address_s;
      descriptor.tAddressMode = address_t;
      descriptor.rAddressMode = address_r;
      descriptor.maxAnisotropy = 1;
      native_sampler = [(__bridge id<MTLDevice>)adapter->device
         newSamplerStateWithDescriptor:descriptor];
      if (native_sampler) {
         *out_sampler = (struct AO46MetalSampler){
            .adapter = adapter,
            .native_sampler = (__bridge_retained void *)native_sampler,
         };
         created = true;
      }
   }

   return created;
}

bool
AO46MetalSamplerCreateNearestClamp(const struct AO46MetalAdapter *adapter,
                                   struct AO46MetalSampler *out_sampler)
{
   static const struct AO46MetalSamplerDescriptor descriptor = {
      .min_filter = AO46_METAL_SAMPLER_FILTER_NEAREST,
      .mag_filter = AO46_METAL_SAMPLER_FILTER_NEAREST,
      .address_s = AO46_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE,
      .address_t = AO46_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE,
      .address_r = AO46_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE,
   };

   return AO46MetalSamplerCreate(adapter, &descriptor, out_sampler);
}

void
AO46MetalSamplerDestroy(struct AO46MetalSampler *sampler)
{
   if (!sampler)
      return;

   if (sampler->native_sampler)
      CFBridgingRelease(sampler->native_sampler);
   *sampler = (struct AO46MetalSampler){0};
}

bool
AO46MetalSamplerIsCurrent(const struct AO46MetalSampler *sampler)
{
   id<MTLSamplerState> native_sampler;

   if (!sampler || !AO46MetalAdapterIsCurrent(sampler->adapter) ||
       !sampler->native_sampler)
      return false;

   native_sampler = (__bridge id<MTLSamplerState>)sampler->native_sampler;
   return native_sampler.device ==
          (__bridge id<MTLDevice>)sampler->adapter->device;
}

bool
AO46MetalTextureTransferLayout(const struct AO46MetalTexture *texture,
                               uint32_t width, uint32_t height,
                               size_t *out_bytes_per_row, size_t *out_size)
{
   id<MTLDevice> device;
   size_t bytes_per_row;
   size_t alignment;

   if (!ao46_metal_texture_dimensions_are_valid(texture, width, height) ||
       !out_bytes_per_row || !out_size)
      return false;

   device = (__bridge id<MTLDevice>)texture->adapter->device;
   alignment = [device minimumLinearTextureAlignmentForPixelFormat:
                         ao46_metal_pixel_format(texture->format)];
   bytes_per_row = (size_t)width * 4;
   if (alignment == 0 || alignment > SIZE_MAX ||
       bytes_per_row > SIZE_MAX - (alignment - 1))
      return false;

   bytes_per_row = ((bytes_per_row + alignment - 1) / alignment) * alignment;
   if (height > SIZE_MAX / bytes_per_row)
      return false;

   *out_bytes_per_row = bytes_per_row;
   *out_size = bytes_per_row * height;
   return true;
}

static bool
ao46_metal_mtl4_copy_begin(const struct AO46MetalAdapter *adapter,
                           mtl_command_allocator **out_allocator,
                           mtl_command_buffer **out_command_buffer,
                           mtl_compute_encoder **out_encoder)
{
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_compute_encoder *encoder = NULL;

   if (!AO46MetalAdapterSupportsMTL4Submission(adapter) || !out_allocator ||
       !out_command_buffer || !out_encoder)
      return false;

   *out_allocator = NULL;
   *out_command_buffer = NULL;
   *out_encoder = NULL;
   ao46_metal_mtl4_make_resident(adapter);
   allocator = mtl_new_command_allocator((mtl_device *)adapter->device);
   command_buffer = mtl_new_command_buffer((mtl_device *)adapter->device);
   if (!allocator || !command_buffer)
      goto fail;

   mtl_begin_command_buffer(command_buffer, allocator);
   encoder = mtl_new_compute_command_encoder(command_buffer);
   if (!encoder) {
      mtl_end_command_buffer(command_buffer);
      goto fail;
   }

   *out_allocator = allocator;
   *out_command_buffer = command_buffer;
   *out_encoder = encoder;
   return true;

fail:
   if (command_buffer)
      mtl_release(command_buffer);
   if (allocator)
      mtl_release(allocator);
   return false;
}

static bool
ao46_metal_mtl4_copy_finish(const struct AO46MetalAdapter *adapter,
                            mtl_command_allocator *allocator,
                            mtl_command_buffer *command_buffer,
                            mtl_compute_encoder *encoder,
                            struct AO46MetalSubmission *out_submission)
{
   bool submitted;

   if (!allocator || !command_buffer || !encoder)
      return false;

   mtl_end_encoding(encoder);
   mtl_release(encoder);
   mtl_end_command_buffer(command_buffer);
   submitted = ao46_metal_mtl4_commit_submission(
      adapter, command_buffer, allocator, NULL, out_submission);
   if (!submitted) {
      mtl_release(command_buffer);
      mtl_release(allocator);
   }
   return submitted;
}

static bool
ao46_metal_mtl4_buffer_blit_submit(
   const struct AO46MetalAdapter *adapter, const struct AO46MetalBuffer *source,
   size_t source_offset, const struct AO46MetalBuffer *destination,
   size_t destination_offset, size_t size,
   struct AO46MetalSubmission *out_submission)
{
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_compute_encoder *encoder = NULL;

   if (!ao46_metal_mtl4_copy_begin(adapter, &allocator, &command_buffer,
                                   &encoder))
      return false;
   mtl_copy_from_buffer_to_buffer(
      encoder, (mtl_buffer *)source->native_buffer, source_offset,
      (mtl_buffer *)destination->native_buffer, destination_offset, size);
   return ao46_metal_mtl4_copy_finish(adapter, allocator, command_buffer,
                                      encoder, out_submission);
}

static bool
ao46_metal_mtl4_texture_transfer_submit(
   const struct AO46MetalAdapter *adapter, const struct AO46MetalBuffer *buffer,
   size_t buffer_offset, size_t bytes_per_row, size_t bytes_per_image,
   const struct AO46MetalTexture *texture, uint32_t texture_x,
   uint32_t texture_y, uint32_t width, uint32_t height, bool upload,
   struct AO46MetalSubmission *out_submission)
{
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_compute_encoder *encoder = NULL;
   struct mtl_buffer_image_copy copy = {
      .image_size = {.x = width, .y = height, .z = 1},
      .image_origin = {.x = texture_x, .y = texture_y, .z = 0},
      .buffer = (mtl_buffer *)buffer->native_buffer,
      .image = (mtl_texture *)texture->native_texture,
      .buffer_offset_B = buffer_offset,
      .buffer_stride_B = bytes_per_row,
      .buffer_2d_image_size_B = bytes_per_image,
      .image_slice = 0,
      .image_level = 0,
      .options = MTL_BLIT_OPTION_NONE,
   };

   if (!ao46_metal_mtl4_copy_begin(adapter, &allocator, &command_buffer,
                                   &encoder))
      return false;
   if (upload)
      mtl_copy_from_buffer_to_texture(encoder, &copy);
   else
      mtl_copy_from_texture_to_buffer(encoder, &copy);
   return ao46_metal_mtl4_copy_finish(adapter, allocator, command_buffer,
                                      encoder, out_submission);
}

static bool
ao46_metal_mtl4_texture_copy_submit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTexture *source, uint32_t source_x, uint32_t source_y,
   const struct AO46MetalTexture *destination, uint32_t destination_x,
   uint32_t destination_y, uint32_t width, uint32_t height,
   struct AO46MetalSubmission *out_submission)
{
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_compute_encoder *encoder = NULL;

   if (!ao46_metal_mtl4_copy_begin(adapter, &allocator, &command_buffer,
                                   &encoder))
      return false;

   mtl_copy_from_texture_to_texture(
      encoder, (mtl_texture *)source->native_texture, 0, 0,
      (struct mtl_origin){.x = source_x, .y = source_y, .z = 0},
      (struct mtl_size){.x = width, .y = height, .z = 1},
      (mtl_texture *)destination->native_texture, 0, 0,
      (struct mtl_origin){.x = destination_x, .y = destination_y, .z = 0});
   return ao46_metal_mtl4_copy_finish(adapter, allocator, command_buffer,
                                      encoder, out_submission);
}

static bool
ao46_metal_mtl4_texture_clear_submit(
   const struct AO46MetalAdapter *adapter, const struct AO46MetalTexture *texture,
   const float color[4], struct AO46MetalSubmission *out_submission)
{
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_render_pass_descriptor *render_pass = NULL;
   mtl_render_encoder *encoder = NULL;
   bool submitted;

   if (!AO46MetalAdapterSupportsMTL4Submission(adapter))
      return false;

   ao46_metal_mtl4_make_resident(adapter);
   allocator = mtl_new_command_allocator((mtl_device *)adapter->device);
   command_buffer = mtl_new_command_buffer((mtl_device *)adapter->device);
   render_pass = mtl_new_render_pass_descriptor();
   if (!allocator || !command_buffer || !render_pass)
      goto fail;

   mtl_render_pass_attachment_descriptor *attachment =
      mtl_render_pass_descriptor_get_color_attachment(render_pass, 0);
   mtl_render_pass_attachment_descriptor_set_texture(
      attachment, (mtl_texture *)texture->native_texture);
   mtl_render_pass_attachment_descriptor_set_load_action(
      attachment, MTL_LOAD_ACTION_CLEAR);
   mtl_render_pass_attachment_descriptor_set_store_action(
      attachment, MTL_STORE_ACTION_STORE);
   mtl_render_pass_attachment_descriptor_set_clear_color(
      attachment, (struct mtl_clear_color){
         .red = color[0], .green = color[1], .blue = color[2], .alpha = color[3],
      });
   mtl_render_pass_descriptor_set_render_target_width(render_pass, texture->width);
   mtl_render_pass_descriptor_set_render_target_height(render_pass, texture->height);
   mtl_render_pass_descriptor_set_default_raster_sample_count(render_pass, 1);

   mtl_begin_command_buffer(command_buffer, allocator);
   encoder = mtl_new_render_command_encoder_with_descriptor(command_buffer,
                                                            render_pass);
   if (!encoder) {
      mtl_end_command_buffer(command_buffer);
      goto fail;
   }
   mtl_end_encoding(encoder);
   mtl_release(encoder);
   encoder = NULL;
   mtl_end_command_buffer(command_buffer);
   mtl_release(render_pass);
   render_pass = NULL;

   submitted = ao46_metal_mtl4_commit_submission(
      adapter, command_buffer, allocator, NULL, out_submission);
   if (!submitted)
      goto fail;
   return true;

fail:
   if (encoder) {
      mtl_end_encoding(encoder);
      mtl_release(encoder);
   }
   if (render_pass)
      mtl_release(render_pass);
   if (command_buffer)
      mtl_release(command_buffer);
   if (allocator)
      mtl_release(allocator);
   return false;
}

bool
AO46MetalTextureClearSubmit(const struct AO46MetalAdapter *adapter,
                            const struct AO46MetalTexture *texture,
                            const float color[4],
                            struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !AO46MetalTextureIsCurrent(texture) ||
       texture->adapter != adapter || !color || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission))
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       ao46_metal_mtl4_texture_clear_submit(adapter, texture, color,
                                            out_submission))
      return true;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLTexture> native_texture = (__bridge id<MTLTexture>)texture->native_texture;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      MTLRenderPassDescriptor *render_pass = [MTLRenderPassDescriptor renderPassDescriptor];

      render_pass.colorAttachments[0].texture = native_texture;
      render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      render_pass.colorAttachments[0].clearColor =
         MTLClearColorMake(color[0], color[1], color[2], color[3]);

      id<MTLRenderCommandEncoder> encoder =
         command_buffer ? [command_buffer renderCommandEncoderWithDescriptor:render_pass]
                        : nil;
      if (encoder) {
         [encoder endEncoding];
         [command_buffer commit];
         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalTextureReadbackSubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTexture *source, uint32_t source_x, uint32_t source_y,
   uint32_t width, uint32_t height, const struct AO46MetalBuffer *destination,
   size_t destination_offset, size_t destination_bytes_per_row,
   struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;
   size_t required_bytes_per_row;
   size_t required_size;

   if (!AO46MetalAdapterIsCurrent(adapter) || !AO46MetalTextureIsCurrent(source) ||
       source->adapter != adapter || !AO46MetalBufferIsCurrent(destination) ||
       destination->adapter != adapter || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission) || source_x > source->width ||
       source_y > source->height || width > source->width - source_x ||
       height > source->height - source_y ||
       !AO46MetalTextureTransferLayout(source, width, height,
                                       &required_bytes_per_row, &required_size) ||
       destination_bytes_per_row != required_bytes_per_row ||
       destination_offset > destination->length ||
       required_size > destination->length - destination_offset)
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       ao46_metal_mtl4_texture_transfer_submit(
          adapter, destination, destination_offset, required_bytes_per_row,
          required_size, source, source_x, source_y, width, height, false,
          out_submission))
      return true;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLTexture> source_texture = (__bridge id<MTLTexture>)source->native_texture;
      id<MTLBuffer> destination_buffer =
         (__bridge id<MTLBuffer>)destination->native_buffer;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLBlitCommandEncoder> encoder =
         command_buffer ? [command_buffer blitCommandEncoder] : nil;

      if (encoder) {
         [encoder copyFromTexture:source_texture
                       sourceSlice:0
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(source_x, source_y, 0)
                        sourceSize:MTLSizeMake(width, height, 1)
                          toBuffer:destination_buffer
                 destinationOffset:destination_offset
            destinationBytesPerRow:required_bytes_per_row
          destinationBytesPerImage:required_size];
         [encoder endEncoding];
         [command_buffer commit];
         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalTextureUploadSubmit(
   const struct AO46MetalAdapter *adapter, const struct AO46MetalBuffer *source,
   size_t source_offset, size_t source_bytes_per_row,
   const struct AO46MetalTexture *destination, uint32_t destination_x,
   uint32_t destination_y, uint32_t width, uint32_t height,
   struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;
   size_t required_bytes_per_row;
   size_t required_size;

   if (!AO46MetalAdapterIsCurrent(adapter) || !AO46MetalBufferIsCurrent(source) ||
       source->adapter != adapter || !AO46MetalTextureIsCurrent(destination) ||
       destination->adapter != adapter || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission) ||
       destination_x > destination->width || destination_y > destination->height ||
       width == 0 || height == 0 || width > destination->width - destination_x ||
       height > destination->height - destination_y ||
       !AO46MetalTextureTransferLayout(destination, width, height,
                                       &required_bytes_per_row, &required_size) ||
       source_bytes_per_row != required_bytes_per_row ||
       source_offset > source->length || required_size > source->length - source_offset)
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       ao46_metal_mtl4_texture_transfer_submit(
          adapter, source, source_offset, required_bytes_per_row, required_size,
          destination, destination_x, destination_y, width, height, true,
          out_submission))
      return true;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLBuffer> source_buffer = (__bridge id<MTLBuffer>)source->native_buffer;
      id<MTLTexture> destination_texture =
         (__bridge id<MTLTexture>)destination->native_texture;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLBlitCommandEncoder> encoder =
         command_buffer ? [command_buffer blitCommandEncoder] : nil;

      if (encoder) {
         [encoder copyFromBuffer:source_buffer
                     sourceOffset:source_offset
                sourceBytesPerRow:source_bytes_per_row
              sourceBytesPerImage:required_size
                       sourceSize:MTLSizeMake(width, height, 1)
                        toTexture:destination_texture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(destination_x, destination_y, 0)];
         [encoder endEncoding];
         [command_buffer commit];
         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalTextureCopySubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalTexture *source, uint32_t source_x, uint32_t source_y,
   const struct AO46MetalTexture *destination, uint32_t destination_x,
   uint32_t destination_y, uint32_t width, uint32_t height,
   struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !AO46MetalTextureIsCurrent(source) ||
       source->adapter != adapter || !AO46MetalTextureIsCurrent(destination) ||
       destination->adapter != adapter || source->format != destination->format ||
       !out_submission || !ao46_metal_submission_is_empty(out_submission) ||
       width == 0 || height == 0 || source_x > source->width ||
       source_y > source->height || width > source->width - source_x ||
       height > source->height - source_y || destination_x > destination->width ||
       destination_y > destination->height ||
       width > destination->width - destination_x ||
       height > destination->height - destination_y)
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       ao46_metal_mtl4_texture_copy_submit(
          adapter, source, source_x, source_y, destination, destination_x,
          destination_y, width, height, out_submission))
      return true;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLTexture> source_texture = (__bridge id<MTLTexture>)source->native_texture;
      id<MTLTexture> destination_texture =
         (__bridge id<MTLTexture>)destination->native_texture;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLBlitCommandEncoder> encoder =
         command_buffer ? [command_buffer blitCommandEncoder] : nil;

      if (encoder) {
         [encoder copyFromTexture:source_texture
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(source_x, source_y, 0)
                       sourceSize:MTLSizeMake(width, height, 1)
                        toTexture:destination_texture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(destination_x, destination_y, 0)];
         [encoder endEncoding];
         [command_buffer commit];
         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalBufferBlitSubmit(const struct AO46MetalAdapter *adapter,
                          const struct AO46MetalBuffer *source,
                          size_t source_offset,
                          const struct AO46MetalBuffer *destination,
                          size_t destination_offset,
                          size_t size,
                          struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !AO46MetalBufferIsCurrent(source) ||
       !AO46MetalBufferIsCurrent(destination) || source->adapter != adapter ||
       destination->adapter != adapter || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission) || size == 0 ||
       source_offset > source->length || size > source->length - source_offset ||
       destination_offset > destination->length ||
       size > destination->length - destination_offset)
      return false;

   if (source->native_buffer == destination->native_buffer &&
       source_offset < destination_offset + size &&
       destination_offset < source_offset + size)
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       ao46_metal_mtl4_buffer_blit_submit(adapter, source, source_offset,
                                          destination, destination_offset, size,
                                          out_submission))
      return true;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLBuffer> source_buffer = (__bridge id<MTLBuffer>)source->native_buffer;
      id<MTLBuffer> destination_buffer =
         (__bridge id<MTLBuffer>)destination->native_buffer;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLBlitCommandEncoder> encoder =
         command_buffer ? [command_buffer blitCommandEncoder] : nil;

      if (encoder) {
         [encoder copyFromBuffer:source_buffer
                     sourceOffset:(NSUInteger)source_offset
                         toBuffer:destination_buffer
                destinationOffset:(NSUInteger)destination_offset
                             size:(NSUInteger)size];
         [encoder endEncoding];
         [command_buffer commit];

         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalComputePipelineCreate(
   const struct AO46MetalAdapter *adapter, const char *msl_source,
   const char *entrypoint, struct AO46MetalComputePipeline *out_pipeline)
{
   __block bool created = false;
   void *mtl4_pipeline = NULL;

   if (!AO46MetalAdapterIsCurrent(adapter) || !msl_source || !entrypoint ||
       !out_pipeline || out_pipeline->adapter || out_pipeline->native_pipeline ||
       out_pipeline->native_classic_pipeline)
      return false;

   if (AO46MetalAdapterSupportsMTL4Submission(adapter)) {
      AO46MetalMTL4SharedState *shared =
         (__bridge AO46MetalMTL4SharedState *)adapter->mtl4_shared_state;
      mtl_library *library = shared && shared->_compiler
                                ? mtl_new_library(
                                     shared->_compiler, msl_source,
                                     MTL_LANGUAGE_VERSION_4_0,
                                     MTL_MATH_MODE_FAST,
                                     MTL_MATH_FLOATING_POINT_FUNCTIONS_FAST)
                                : NULL;
      mtl_function_descriptor *function =
         library ? mtl_new_library_function_descriptor(library, entrypoint) : NULL;
      mtl_compute_pipeline_state *pipeline = function
         ? mtl_new_compute_pipeline_state(
              shared->_compiler, function,
              AO46_METAL_MTL4_MAX_THREADS_PER_THREADGROUP)
         : NULL;

      if (function)
         mtl_release(function);
      if (library)
         mtl_release(library);

      if (pipeline) {
         mtl4_pipeline = pipeline;
      }
   }

   @autoreleasepool {
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      NSError *error = nil;
      NSString *source = [[NSString alloc] initWithUTF8String:msl_source];
      id<MTLLibrary> library;
      id<MTLFunction> function;
      id<MTLComputePipelineState> pipeline;
      NSString *function_name = [NSString stringWithUTF8String:entrypoint];

      library = source ? [device newLibraryWithSource:source options:nil error:&error] : nil;
      function = library && !error
                    ? [library newFunctionWithName:function_name]
                    : nil;
      pipeline = function
                    ? [device newComputePipelineStateWithFunction:function error:&error]
                    : nil;
      if (pipeline && !error) {
         *out_pipeline = (struct AO46MetalComputePipeline){
            .adapter = adapter,
            .native_pipeline = mtl4_pipeline
               ? mtl4_pipeline
               : (__bridge_retained void *)pipeline,
            .native_classic_pipeline = mtl4_pipeline
               ? (__bridge_retained void *)pipeline
               : NULL,
            .uses_mtl4_compiler = mtl4_pipeline != NULL,
            .thread_execution_width = (uint32_t)pipeline.threadExecutionWidth,
            .max_threads_per_threadgroup =
               (uint32_t)pipeline.maxTotalThreadsPerThreadgroup,
         };
         created = true;
      }
   }

   if (!created && mtl4_pipeline)
      mtl_release(mtl4_pipeline);
   return created;
}

void
AO46MetalComputePipelineDestroy(struct AO46MetalComputePipeline *pipeline)
{
   if (!pipeline)
      return;

   if (pipeline->native_pipeline)
      CFBridgingRelease(pipeline->native_pipeline);
   if (pipeline->native_classic_pipeline)
      CFBridgingRelease(pipeline->native_classic_pipeline);
   *pipeline = (struct AO46MetalComputePipeline){0};
}

bool
AO46MetalRenderPipelineCreate(
   const struct AO46MetalAdapter *adapter, const char *vertex_msl_source,
   const char *vertex_entrypoint, const char *fragment_msl_source,
   const char *fragment_entrypoint, enum AO46MetalTextureFormat color_format,
   const struct AO46MetalVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint64_t static_texture_mask,
   uint64_t static_sampler_mask, uint16_t static_fragment_buffer_mask,
   const size_t
      static_fragment_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t uniform_mask,
   const size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS],
   struct AO46MetalRenderPipeline *out_pipeline)
{
   const size_t
      static_vertex_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS] = {0};

   return AO46MetalRenderPipelineCreateWithStaticVertexBuffers(
      adapter, vertex_msl_source, vertex_entrypoint, fragment_msl_source,
      fragment_entrypoint, color_format, vertex_attributes, vertex_attribute_count,
      static_texture_mask, static_sampler_mask, 0, static_vertex_buffer_bytes,
      static_fragment_buffer_mask, static_fragment_buffer_bytes, uniform_mask,
      uniform_bytes, out_pipeline);
}

bool
AO46MetalRenderPipelineCreateWithStaticVertexBuffers(
   const struct AO46MetalAdapter *adapter, const char *vertex_msl_source,
   const char *vertex_entrypoint, const char *fragment_msl_source,
   const char *fragment_entrypoint, enum AO46MetalTextureFormat color_format,
   const struct AO46MetalVertexAttribute *vertex_attributes,
   size_t vertex_attribute_count, uint64_t static_texture_mask,
   uint64_t static_sampler_mask, uint16_t static_vertex_buffer_mask,
   const size_t
      static_vertex_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t static_fragment_buffer_mask,
   const size_t
      static_fragment_buffer_bytes[AO46_METAL_MAX_STATIC_BUFFER_BINDINGS],
   uint16_t uniform_mask,
   const size_t uniform_bytes[AO46_METAL_MAX_UNIFORM_BINDINGS],
   struct AO46MetalRenderPipeline *out_pipeline)
{
   __block bool created = false;
   void *mtl4_pipeline = NULL;
   MTLPixelFormat pixel_format = ao46_metal_pixel_format(color_format);
   const bool supports_indirect_command_buffers =
      static_texture_mask == 0 && static_sampler_mask == 0;

   if (!AO46MetalAdapterIsCurrent(adapter) || !vertex_msl_source ||
       !vertex_entrypoint || !fragment_msl_source || !fragment_entrypoint ||
       !out_pipeline || !ao46_metal_render_pipeline_is_empty(out_pipeline) ||
       pixel_format == MTLPixelFormatInvalid ||
       (static_vertex_buffer_mask & UINT16_C(0x0003)) != 0 ||
       (static_fragment_buffer_mask & UINT16_C(0x0003)) != 0 ||
       !static_vertex_buffer_bytes || !static_fragment_buffer_bytes ||
       !uniform_bytes ||
       !ao46_metal_vertex_attributes_are_valid(vertex_attributes,
                                                vertex_attribute_count))
      return false;

   for (size_t i = 0; i < AO46_METAL_MAX_UNIFORM_BINDINGS; ++i) {
      const uint16_t bit = UINT16_C(1) << i;

      if (uniform_bytes[i] > adapter->max_buffer_length ||
          ((uniform_mask & bit) == 0 && uniform_bytes[i] != 0) ||
          ((uniform_mask & bit) != 0 && uniform_bytes[i] == 0))
         return false;
   }

   for (size_t i = 0; i < AO46_METAL_MAX_STATIC_BUFFER_BINDINGS; ++i) {
      const uint16_t bit = UINT16_C(1) << i;

      if (((static_vertex_buffer_mask & bit) != 0 &&
           static_vertex_buffer_bytes[i] == 0) ||
          ((static_vertex_buffer_mask & bit) == 0 &&
           static_vertex_buffer_bytes[i] != 0) ||
          static_vertex_buffer_bytes[i] > adapter->max_buffer_length ||
          ((static_fragment_buffer_mask & bit) != 0 &&
           static_fragment_buffer_bytes[i] == 0) ||
          ((static_fragment_buffer_mask & bit) == 0 &&
           static_fragment_buffer_bytes[i] != 0) ||
          static_fragment_buffer_bytes[i] > adapter->max_buffer_length)
         return false;
   }

   if (AO46MetalAdapterSupportsMTL4Submission(adapter)) {
      AO46MetalMTL4SharedState *shared =
         (__bridge AO46MetalMTL4SharedState *)adapter->mtl4_shared_state;
      mtl_library *vertex_library = shared && shared->_compiler
         ? mtl_new_library(shared->_compiler, vertex_msl_source,
                           MTL_LANGUAGE_VERSION_4_0,
                           MTL_MATH_MODE_FAST,
                           MTL_MATH_FLOATING_POINT_FUNCTIONS_FAST)
         : NULL;
      mtl_function_descriptor *vertex_function = vertex_library
         ? mtl_new_library_function_descriptor(vertex_library, vertex_entrypoint)
         : NULL;
      mtl_library *fragment_library = vertex_function
         ? mtl_new_library(shared->_compiler, fragment_msl_source,
                           MTL_LANGUAGE_VERSION_4_0,
                           MTL_MATH_MODE_FAST,
                           MTL_MATH_FLOATING_POINT_FUNCTIONS_FAST)
         : NULL;
      mtl_function_descriptor *fragment_function = fragment_library
         ? mtl_new_library_function_descriptor(fragment_library,
                                               fragment_entrypoint)
         : NULL;
      mtl_render_pipeline_descriptor *descriptor = fragment_function
         ? mtl_new_render_pipeline_descriptor()
         : NULL;
      mtl_render_pipeline_state *pipeline = NULL;

      if (descriptor) {
         mtl_render_pipeline_descriptor_set_vertex_shader(descriptor,
                                                          vertex_function);
         mtl_render_pipeline_descriptor_set_fragment_shader(descriptor,
                                                            fragment_function);
         mtl_render_pipeline_descriptor_set_input_primitive_topology(
            descriptor, MTL_PRIMITIVE_TOPOLOGY_CLASS_UNSPECIFIED);
         mtl_render_pipeline_descriptor_set_color_attachment_format(
            descriptor, 0, ao46_metal_mtl4_pixel_format(color_format));
         mtl_render_pipeline_descriptor_set_raster_sample_count(descriptor, 1);
         mtl_render_pipeline_descriptor_set_rasterization_enabled(descriptor,
                                                                    true);
         for (size_t i = 0; i < vertex_attribute_count; ++i) {
            const struct AO46MetalVertexAttribute *attribute =
               &vertex_attributes[i];
            const enum mtl_vertex_step_function step_function =
               attribute->instance_divisor == 0
                  ? MTL_VERTEX_STEP_FUNCTION_PER_VERTEX
                  : MTL_VERTEX_STEP_FUNCTION_PER_INSTANCE;

            mtl_render_pipeline_descriptor_set_vertex_attribute(
               descriptor, attribute->attribute_index,
               ao46_metal_mtl4_vertex_format(attribute->format),
               attribute->offset, attribute->buffer_index);
            mtl_render_pipeline_descriptor_set_vertex_buffer_layout(
               descriptor, attribute->buffer_index, attribute->stride,
               step_function,
               attribute->instance_divisor == 0 ? 1 : attribute->instance_divisor);
         }
         pipeline = mtl_new_render_pipeline(shared->_compiler, descriptor);
      }

      if (descriptor)
         mtl_release(descriptor);
      if (fragment_function)
         mtl_release(fragment_function);
      if (fragment_library)
         mtl_release(fragment_library);
      if (vertex_function)
         mtl_release(vertex_function);
      if (vertex_library)
         mtl_release(vertex_library);

      if (pipeline) {
         mtl4_pipeline = pipeline;
      }
   }

   @autoreleasepool {
      id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
      NSError *vertex_error = nil;
      NSError *fragment_error = nil;
      NSError *pipeline_error = nil;
      NSString *vertex_source =
         [[NSString alloc] initWithUTF8String:vertex_msl_source];
      NSString *fragment_source =
         [[NSString alloc] initWithUTF8String:fragment_msl_source];
      NSString *vertex_name =
         [NSString stringWithUTF8String:vertex_entrypoint];
      NSString *fragment_name =
         [NSString stringWithUTF8String:fragment_entrypoint];
      id<MTLLibrary> vertex_library =
         vertex_source ? [device newLibraryWithSource:vertex_source
                                              options:nil
                                                error:&vertex_error]
                       : nil;
      id<MTLLibrary> fragment_library =
         fragment_source ? [device newLibraryWithSource:fragment_source
                                                options:nil
                                                  error:&fragment_error]
                         : nil;
      id<MTLFunction> vertex_function =
         vertex_library && !vertex_error ? [vertex_library newFunctionWithName:vertex_name]
                                         : nil;
      id<MTLFunction> fragment_function =
         fragment_library && !fragment_error
            ? [fragment_library newFunctionWithName:fragment_name]
            : nil;
      MTLRenderPipelineDescriptor *descriptor =
         [[MTLRenderPipelineDescriptor alloc] init];

      descriptor.vertexFunction = vertex_function;
      descriptor.fragmentFunction = fragment_function;
      descriptor.colorAttachments[0].pixelFormat = pixel_format;
      /* Texture/sampler-bearing Mesa stages use the direct path for now. */
      descriptor.supportIndirectCommandBuffers = supports_indirect_command_buffers;
      for (size_t i = 0; i < vertex_attribute_count; ++i) {
         const struct AO46MetalVertexAttribute *attribute = &vertex_attributes[i];
         MTLVertexAttributeDescriptor *metal_attribute =
            descriptor.vertexDescriptor.attributes[attribute->attribute_index];
         MTLVertexBufferLayoutDescriptor *metal_layout =
            descriptor.vertexDescriptor.layouts[attribute->buffer_index];

         metal_attribute.format = ao46_metal_vertex_format(attribute->format);
         metal_attribute.offset = attribute->offset;
         metal_attribute.bufferIndex = attribute->buffer_index;
         metal_layout.stride = attribute->stride;
         metal_layout.stepFunction = attribute->instance_divisor == 0
                                       ? MTLVertexStepFunctionPerVertex
                                       : MTLVertexStepFunctionPerInstance;
         metal_layout.stepRate = attribute->instance_divisor == 0
                                   ? 1
                                   : attribute->instance_divisor;
      }
      id<MTLRenderPipelineState> pipeline =
         vertex_function && fragment_function
            ? [device newRenderPipelineStateWithDescriptor:descriptor
                                                       error:&pipeline_error]
            : nil;
      if (pipeline && !pipeline_error) {
         *out_pipeline = (struct AO46MetalRenderPipeline){
            .adapter = adapter,
            .native_pipeline = mtl4_pipeline
               ? mtl4_pipeline
               : (__bridge_retained void *)pipeline,
            .native_classic_pipeline = mtl4_pipeline
               ? (__bridge_retained void *)pipeline
               : NULL,
            .uses_mtl4_compiler = mtl4_pipeline != NULL,
            .color_format = color_format,
            .supports_indirect_command_buffers = supports_indirect_command_buffers,
            .static_texture_mask = static_texture_mask,
            .static_sampler_mask = static_sampler_mask,
            .static_vertex_buffer_mask = static_vertex_buffer_mask,
            .static_fragment_buffer_mask = static_fragment_buffer_mask,
            .uniform_mask = uniform_mask,
            .vertex_attribute_count = (uint32_t)vertex_attribute_count,
         };
         memcpy(out_pipeline->uniform_bytes, uniform_bytes,
                sizeof(out_pipeline->uniform_bytes));
         memcpy(out_pipeline->static_fragment_buffer_bytes,
                static_fragment_buffer_bytes,
                sizeof(out_pipeline->static_fragment_buffer_bytes));
         memcpy(out_pipeline->static_vertex_buffer_bytes,
                static_vertex_buffer_bytes,
                sizeof(out_pipeline->static_vertex_buffer_bytes));
         memcpy(out_pipeline->vertex_attributes, vertex_attributes,
                vertex_attribute_count * sizeof(*vertex_attributes));
         created = true;
      }
   }

   if (!created && mtl4_pipeline)
      mtl_release(mtl4_pipeline);
   return created;
}

void
AO46MetalRenderPipelineDestroy(struct AO46MetalRenderPipeline *pipeline)
{
   if (!pipeline)
      return;

   if (pipeline->native_pipeline)
      CFBridgingRelease(pipeline->native_pipeline);
   if (pipeline->native_classic_pipeline)
      CFBridgingRelease(pipeline->native_classic_pipeline);
   *pipeline = (struct AO46MetalRenderPipeline){0};
}

static bool
ao46_metal_mtl4_render_submit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalTexture *color_target,
   const struct AO46MetalUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalIndexBufferBinding *index_binding,
   const struct AO46MetalVertexBufferBinding *vertex_bindings,
   size_t vertex_binding_count,
   const struct AO46MetalTextureBinding *texture_bindings,
   size_t texture_binding_count,
   const struct AO46MetalSamplerBinding *sampler_bindings,
   size_t sampler_binding_count,
   const struct AO46MetalBufferBinding *vertex_static_buffer_bindings,
   size_t vertex_static_buffer_binding_count,
   const struct AO46MetalBufferBinding *fragment_buffer_bindings,
   size_t fragment_buffer_binding_count,
   enum AO46MetalPrimitive primitive, uint32_t vertex_start,
   uint32_t vertex_count, uint32_t instance_count, uint32_t base_instance,
   struct AO46MetalSubmission *out_submission);

bool
AO46MetalRenderSubmit(const struct AO46MetalAdapter *adapter,
                      const struct AO46MetalRenderPipeline *pipeline,
                      const struct AO46MetalTexture *color_target,
                      const struct AO46MetalUniformBufferBinding *uniform_bindings,
                      size_t uniform_binding_count,
                      const struct AO46MetalIndexBufferBinding *index_binding,
                      const struct AO46MetalIndirectDrawBinding *indirect_binding,
                      const struct AO46MetalVertexBufferBinding *vertex_bindings,
                      size_t vertex_binding_count,
                      const struct AO46MetalTextureBinding *texture_bindings,
                      size_t texture_binding_count,
                      const struct AO46MetalSamplerBinding *sampler_bindings,
                      size_t sampler_binding_count,
                      const struct AO46MetalBufferBinding *fragment_buffer_bindings,
                      size_t fragment_buffer_binding_count,
                      enum AO46MetalPrimitive primitive,
                      uint32_t vertex_start,
                      uint32_t vertex_count,
                      uint32_t instance_count,
                      uint32_t base_instance,
                      struct AO46MetalSubmission *out_submission)
{
   return AO46MetalRenderSubmitWithStaticVertexBuffers(
      adapter, pipeline, color_target, uniform_bindings, uniform_binding_count,
      index_binding, indirect_binding, vertex_bindings, vertex_binding_count,
      texture_bindings, texture_binding_count, sampler_bindings,
      sampler_binding_count, NULL, 0, fragment_buffer_bindings,
      fragment_buffer_binding_count, primitive, vertex_start, vertex_count,
      instance_count, base_instance, out_submission);
}

bool
AO46MetalRenderSubmitWithStaticVertexBuffers(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalTexture *color_target,
   const struct AO46MetalUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalIndexBufferBinding *index_binding,
   const struct AO46MetalIndirectDrawBinding *indirect_binding,
   const struct AO46MetalVertexBufferBinding *vertex_bindings,
   size_t vertex_binding_count,
   const struct AO46MetalTextureBinding *texture_bindings,
   size_t texture_binding_count,
   const struct AO46MetalSamplerBinding *sampler_bindings,
   size_t sampler_binding_count,
   const struct AO46MetalBufferBinding *vertex_static_buffer_bindings,
   size_t vertex_static_buffer_binding_count,
   const struct AO46MetalBufferBinding *fragment_buffer_bindings,
   size_t fragment_buffer_binding_count,
   enum AO46MetalPrimitive primitive, uint32_t vertex_start,
   uint32_t vertex_count, uint32_t instance_count, uint32_t base_instance,
   struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;
   size_t vertex_span = 0;
   MTLIndexType index_type = MTLIndexTypeUInt16;
   uint32_t validated_vertex_start = vertex_start;
   uint32_t validated_vertex_count = vertex_count;
   uint32_t validated_instance_count = instance_count;
   uint32_t validated_base_instance = base_instance;
   MTLPrimitiveType native_primitive;

   if (!AO46MetalAdapterIsCurrent(adapter) || !pipeline ||
       pipeline->adapter != adapter || !pipeline->native_pipeline ||
       !AO46MetalTextureIsCurrent(color_target) ||
       color_target->adapter != adapter ||
       pipeline->color_format != color_target->format ||
       pipeline->vertex_attribute_count > AO46_METAL_MAX_VERTEX_ATTRIBUTES ||
       !ao46_metal_uniform_bindings_are_valid(adapter, pipeline,
                                               uniform_bindings,
                                               uniform_binding_count) ||
       !ao46_metal_vertex_attributes_are_valid(
          pipeline->vertex_attribute_count ? pipeline->vertex_attributes : NULL,
          pipeline->vertex_attribute_count) ||
       (vertex_binding_count == 0 && vertex_bindings) ||
       (vertex_binding_count != 0 && !vertex_bindings) ||
       vertex_binding_count > pipeline->vertex_attribute_count ||
       !ao46_metal_texture_bindings_are_valid(
          adapter, texture_bindings, texture_binding_count,
          pipeline->static_texture_mask, color_target) ||
       !ao46_metal_sampler_bindings_are_valid(
          adapter, sampler_bindings, sampler_binding_count,
          pipeline->static_sampler_mask) ||
       !ao46_metal_static_buffer_bindings_are_valid(
          adapter, vertex_static_buffer_bindings,
          vertex_static_buffer_binding_count,
          pipeline->static_vertex_buffer_mask,
          pipeline->static_vertex_buffer_bytes) ||
       !ao46_metal_static_buffer_bindings_are_valid(
          adapter, fragment_buffer_bindings, fragment_buffer_binding_count,
          pipeline->static_fragment_buffer_mask,
          pipeline->static_fragment_buffer_bytes) ||
       !out_submission || !ao46_metal_submission_is_empty(out_submission) ||
       !ao46_metal_primitive_info(primitive, NULL, &native_primitive))
      return false;

   if (indirect_binding && indirect_binding->count_buffer &&
       !pipeline->supports_indirect_command_buffers)
      return false;

   if (!indirect_binding && instance_count == 0)
      return false;

   if (indirect_binding) {
      if (indirect_binding->gpu_generated &&
          pipeline->vertex_attribute_count != 0)
         return false;
      if (!ao46_metal_indirect_binding_is_valid(
             adapter, index_binding, indirect_binding, primitive, &vertex_span,
             &validated_instance_count))
         return false;
      validated_base_instance = 0;

      if (index_binding) {
         switch (index_binding->format) {
         case AO46_METAL_INDEX_FORMAT_UINT16:
            index_type = MTLIndexTypeUInt16;
            break;
         case AO46_METAL_INDEX_FORMAT_UINT32:
            index_type = MTLIndexTypeUInt32;
            break;
         default:
            return false;
         }
      }
   } else if (!ao46_metal_index_binding_vertex_span(
                 adapter, index_binding, primitive, validated_vertex_start,
                 validated_vertex_count, &vertex_span, &index_type)) {
      return false;
   }

   for (size_t i = 0; i < vertex_binding_count; ++i) {
      if (!AO46MetalBufferIsCurrent(vertex_bindings[i].buffer) ||
          vertex_bindings[i].buffer->adapter != adapter ||
          vertex_bindings[i].index < 2 ||
          vertex_bindings[i].index > AO46_METAL_MAX_VERTEX_BUFFER_INDEX ||
          vertex_bindings[i].offset >= vertex_bindings[i].buffer->length)
         return false;

      for (size_t j = 0; j < i; ++j) {
         if (vertex_bindings[j].index == vertex_bindings[i].index)
            return false;
      }

      for (size_t j = 0; j < vertex_static_buffer_binding_count; ++j) {
         if (vertex_static_buffer_bindings[j].index == vertex_bindings[i].index)
            return false;
      }
   }

   for (size_t i = 0; i < pipeline->vertex_attribute_count; ++i) {
      const struct AO46MetalVertexAttribute *attribute =
         &pipeline->vertex_attributes[i];
      const struct AO46MetalVertexBufferBinding *binding = NULL;
      size_t element_count;
      size_t required_bytes;

      for (size_t j = 0; j < vertex_binding_count; ++j) {
         if (vertex_bindings[j].index == attribute->buffer_index) {
            binding = &vertex_bindings[j];
            break;
         }
      }

      if (!binding || !ao46_metal_vertex_attribute_element_count(
                          attribute, vertex_span, validated_instance_count,
                          validated_base_instance, &element_count) ||
          attribute->offset > SIZE_MAX -
                                      ao46_metal_vertex_format_size(attribute->format) ||
          element_count - 1 >
             (SIZE_MAX - attribute->offset -
              ao46_metal_vertex_format_size(attribute->format)) /
                attribute->stride)
         return false;

      required_bytes = attribute->offset +
                       (element_count - 1) * attribute->stride +
                       ao46_metal_vertex_format_size(attribute->format);
      if (binding->offset > binding->buffer->length ||
          required_bytes > binding->buffer->length - binding->offset)
         return false;
   }

   for (size_t i = 0; i < vertex_binding_count; ++i) {
      bool used = false;

      for (size_t j = 0; j < pipeline->vertex_attribute_count; ++j) {
         if (pipeline->vertex_attributes[j].buffer_index ==
             vertex_bindings[i].index) {
            used = true;
            break;
         }
      }
      if (!used)
         return false;
   }

   /* MTL4 tables lack AO46's stage-specific texture/sampler binding coverage. */
   if (AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       pipeline->uses_mtl4_compiler && !indirect_binding &&
       pipeline->static_vertex_texture_mask == 0 &&
       pipeline->static_vertex_sampler_mask == 0 &&
       !(index_binding && index_binding->primitive_restart)) {
      if (ao46_metal_mtl4_render_submit(
             adapter, pipeline, color_target, uniform_bindings,
             uniform_binding_count, index_binding, vertex_bindings,
             vertex_binding_count, texture_bindings, texture_binding_count,
             sampler_bindings, sampler_binding_count,
             vertex_static_buffer_bindings,
             vertex_static_buffer_binding_count, fragment_buffer_bindings,
             fragment_buffer_binding_count, primitive, validated_vertex_start,
             validated_vertex_count, validated_instance_count,
             validated_base_instance, out_submission))
         return true;
   }

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLTexture> texture =
         (__bridge id<MTLTexture>)color_target->native_texture;
      id<MTLBuffer> root_buffer =
         (__bridge id<MTLBuffer>)adapter->graphics_root_buffer;
      NSUInteger root_offset = 0;
      id<MTLBuffer> sampler_table_buffer =
         (__bridge id<MTLBuffer>)adapter->graphics_sampler_table_buffer;
      id<MTLRenderPipelineState> native_pipeline =
         (__bridge id<MTLRenderPipelineState>)(
            pipeline->native_classic_pipeline
               ? pipeline->native_classic_pipeline
               : pipeline->native_pipeline);
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLIndirectCommandBuffer> indirect_command_list = nil;
      id<MTLBuffer> indirect_execution_range = nil;
      MTLRenderPassDescriptor *render_pass = [MTLRenderPassDescriptor renderPassDescriptor];

      if (command_buffer && indirect_binding && indirect_binding->count_buffer) {
         id<MTLDevice> device = (__bridge id<MTLDevice>)adapter->device;
         id<MTLBuffer> count_buffer = (__bridge id<MTLBuffer>)
            indirect_binding->count_buffer->native_buffer;
         id<MTLComputePipelineState> range_pipeline =
            (__bridge id<MTLComputePipelineState>)adapter->indirect_count_range_pipeline;
         MTLIndirectCommandBufferDescriptor *descriptor =
            [[MTLIndirectCommandBufferDescriptor alloc] init];
         const size_t argument_size = index_binding
            ? sizeof(struct AO46MetalDrawIndexedIndirectArguments)
            : sizeof(struct AO46MetalDrawIndirectArguments);
         const size_t argument_stride = indirect_binding->stride
            ? indirect_binding->stride : argument_size;
         id<MTLComputeCommandEncoder> count_encoder;

         descriptor.commandTypes = index_binding
            ? MTLIndirectCommandTypeDrawIndexed : MTLIndirectCommandTypeDraw;
         descriptor.inheritPipelineState = YES;
         descriptor.inheritBuffers = YES;
         indirect_command_list = [device newIndirectCommandBufferWithDescriptor:descriptor
                                                                  maxCommandCount:
                                                                     indirect_binding->draw_count
                                                                           options:0];
         indirect_execution_range = [device newBufferWithLength:
            sizeof(MTLIndirectCommandBufferExecutionRange)
                                                   options:MTLResourceStorageModeShared];
         if (!indirect_command_list || !indirect_execution_range ||
             !range_pipeline)
            return false;

         for (uint32_t draw = 0; draw < indirect_binding->draw_count; ++draw) {
            const uint8_t *argument_bytes =
               (const uint8_t *)indirect_binding->buffer->cpu_mapping +
               indirect_binding->offset + (size_t)draw * argument_stride;
            id<MTLIndirectRenderCommand> command =
               [indirect_command_list indirectRenderCommandAtIndex:draw];

            if (index_binding) {
               struct AO46MetalDrawIndexedIndirectArguments arguments;
               id<MTLBuffer> index_buffer = (__bridge id<MTLBuffer>)
                  index_binding->buffer->native_buffer;
               NSUInteger index_offset;

               memcpy(&arguments, argument_bytes, sizeof(arguments));
               index_offset = (NSUInteger)(
                  index_binding->offset + (size_t)arguments.index_start *
                  (index_binding->format == AO46_METAL_INDEX_FORMAT_UINT16
                      ? sizeof(uint16_t) : sizeof(uint32_t)));
               [command drawIndexedPrimitives:native_primitive
                                    indexCount:arguments.index_count
                                     indexType:index_type
                                  indexBuffer:index_buffer
                            indexBufferOffset:index_offset
                                instanceCount:arguments.instance_count
                                  baseVertex:arguments.base_vertex
                                baseInstance:arguments.base_instance];
            } else {
               struct AO46MetalDrawIndirectArguments arguments;

               memcpy(&arguments, argument_bytes, sizeof(arguments));
               [command drawPrimitives:native_primitive
                             vertexStart:arguments.vertex_start
                             vertexCount:arguments.vertex_count
                           instanceCount:arguments.instance_count
                            baseInstance:arguments.base_instance];
            }
         }

         count_encoder = [command_buffer computeCommandEncoder];
         if (!count_encoder)
            return false;
         [count_encoder setComputePipelineState:range_pipeline];
         [count_encoder setBuffer:count_buffer
                            offset:indirect_binding->count_buffer_offset atIndex:0];
         [count_encoder setBuffer:indirect_execution_range offset:0 atIndex:1];
         [count_encoder setBytes:&indirect_binding->draw_count
                           length:sizeof(indirect_binding->draw_count) atIndex:2];
         [count_encoder dispatchThreads:MTLSizeMake(1, 1, 1)
                  threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
         [count_encoder endEncoding];
      }

      for (size_t i = 0; i < uniform_binding_count; ++i) {
         if (uniform_bindings[i].binding != 0)
            continue;

         root_buffer =
            (__bridge id<MTLBuffer>)uniform_bindings[i].buffer->native_buffer;
         root_offset = (NSUInteger)uniform_bindings[i].offset;
         break;
      }

      render_pass.colorAttachments[0].texture = texture;
      render_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
      render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> encoder =
         command_buffer ? [command_buffer renderCommandEncoderWithDescriptor:render_pass]
                        : nil;
      if (encoder) {
         MTLViewport viewport = {
            .originX = 0.0,
            .originY = 0.0,
            .width = color_target->width,
            .height = color_target->height,
            .znear = 0.0,
            .zfar = 1.0,
         };

         [encoder setViewport:viewport];
         [encoder setCullMode:MTLCullModeNone];
         [encoder setRenderPipelineState:native_pipeline];
         [encoder setVertexBuffer:root_buffer offset:root_offset atIndex:0];
         [encoder setVertexBuffer:sampler_table_buffer offset:0 atIndex:1];
         for (size_t i = 0; i < uniform_binding_count; ++i) {
            if (uniform_bindings[i].binding == 0)
               continue;

            id<MTLBuffer> uniform_buffer =
               (__bridge id<MTLBuffer>)uniform_bindings[i].buffer->native_buffer;
            const NSUInteger offset = (NSUInteger)uniform_bindings[i].offset;
            const NSUInteger slot = AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX +
                                    uniform_bindings[i].binding - 1;

            [encoder setVertexBuffer:uniform_buffer offset:offset atIndex:slot];
            [encoder setFragmentBuffer:uniform_buffer offset:offset atIndex:slot];
         }
         for (size_t i = 0; i < vertex_static_buffer_binding_count; ++i) {
            id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)
               vertex_static_buffer_bindings[i].buffer->native_buffer;
            [encoder setVertexBuffer:buffer
                               offset:vertex_static_buffer_bindings[i].offset
                              atIndex:vertex_static_buffer_bindings[i].index];
         }
         for (size_t i = 0; i < vertex_binding_count; ++i) {
            id<MTLBuffer> vertex_buffer =
               (__bridge id<MTLBuffer>)vertex_bindings[i].buffer->native_buffer;
            [encoder setVertexBuffer:vertex_buffer
                               offset:vertex_bindings[i].offset
                              atIndex:vertex_bindings[i].index];
         }
         [encoder setFragmentBuffer:root_buffer offset:root_offset atIndex:0];
         [encoder setFragmentBuffer:sampler_table_buffer offset:0 atIndex:1];
         for (size_t i = 0; i < fragment_buffer_binding_count; ++i) {
            id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)
               fragment_buffer_bindings[i].buffer->native_buffer;
            [encoder setFragmentBuffer:buffer
                                 offset:fragment_buffer_bindings[i].offset
                                atIndex:fragment_buffer_bindings[i].index];
         }
         for (size_t i = 0; i < texture_binding_count; ++i) {
            id<MTLTexture> native_texture =
               (__bridge id<MTLTexture>)texture_bindings[i].texture->native_texture;
            [encoder setVertexTexture:native_texture atIndex:texture_bindings[i].index];
            [encoder setFragmentTexture:native_texture atIndex:texture_bindings[i].index];
         }
         for (size_t i = 0; i < sampler_binding_count; ++i) {
            id<MTLSamplerState> native_sampler =
               (__bridge id<MTLSamplerState>)sampler_bindings[i].sampler->native_sampler;
            [encoder setVertexSamplerState:native_sampler
                                    atIndex:sampler_bindings[i].index];
            [encoder setFragmentSamplerState:native_sampler
                                      atIndex:sampler_bindings[i].index];
         }
         if (indirect_binding) {
            id<MTLBuffer> indirect_buffer =
               (__bridge id<MTLBuffer>)indirect_binding->buffer->native_buffer;
            const size_t argument_size =
               index_binding ? sizeof(struct AO46MetalDrawIndexedIndirectArguments)
                             : sizeof(struct AO46MetalDrawIndirectArguments);
            const size_t argument_stride =
               indirect_binding->stride ? indirect_binding->stride : argument_size;

            if (indirect_binding->count_buffer) {
               /* The preceding compute encoder wrote this range from Mesa's count BO. */
               [encoder executeCommandsInBuffer:indirect_command_list
                                  indirectBuffer:indirect_execution_range
                            indirectBufferOffset:0];
            } else {
               for (uint32_t draw = 0; draw < indirect_binding->draw_count; ++draw) {
                  const NSUInteger argument_offset = (NSUInteger)(
                     indirect_binding->offset + (size_t)draw * argument_stride);

                  if (index_binding) {
                     id<MTLBuffer> index_buffer = (__bridge id<MTLBuffer>)
                        index_binding->buffer->native_buffer;
                     [encoder drawIndexedPrimitives:native_primitive
                                           indexType:index_type
                                         indexBuffer:index_buffer
                                   indexBufferOffset:(NSUInteger)index_binding->offset
                                     indirectBuffer:indirect_buffer
                               indirectBufferOffset:argument_offset];
                  } else {
                     [encoder drawPrimitives:native_primitive
                              indirectBuffer:indirect_buffer
                        indirectBufferOffset:argument_offset];
                  }
               }
            }
         } else if (index_binding) {
            ao46_metal_encode_indexed_primitives(
               encoder, index_binding, index_type, primitive,
               validated_instance_count, validated_base_instance);
         } else {
            [encoder drawPrimitives:native_primitive
                         vertexStart:validated_vertex_start
                         vertexCount:validated_vertex_count
                       instanceCount:validated_instance_count
                        baseInstance:validated_base_instance];
         }
         [encoder endEncoding];
         [command_buffer commit];
         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

static bool
ao46_metal_mtl4_compute_submit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission)
{
   mtl_argument_table_descriptor *descriptor = NULL;
   mtl_argument_table *argument_table = NULL;
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_compute_encoder *encoder = NULL;
   uint32_t highest_binding = 0;
   uint32_t bound_mask = 0;
   bool command_buffer_begun = false;

   if (!AO46MetalAdapterSupportsMTL4Submission(adapter) ||
       !pipeline->uses_mtl4_compiler)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      uint64_t address;

      if (bindings[i].index >= AO46_METAL_MAX_STATIC_BUFFER_BINDINGS ||
          (bound_mask & (UINT32_C(1) << bindings[i].index)) ||
          !AO46MetalBufferGetGPUAddress(bindings[i].buffer, &address) ||
          bindings[i].offset > bindings[i].buffer->length ||
          bindings[i].offset > UINT64_MAX - address)
         return false;

      bound_mask |= UINT32_C(1) << bindings[i].index;
      if (bindings[i].index > highest_binding)
         highest_binding = bindings[i].index;
   }

   ao46_metal_mtl4_make_resident(adapter);
   descriptor = mtl_new_argument_table_descriptor();
   if (!descriptor)
      goto fail;
   mtl_set_max_buffer_binding_count(descriptor, highest_binding + 1u);

   argument_table = mtl_new_argument_table((mtl_device *)adapter->device,
                                           descriptor);
   if (!argument_table)
      goto fail;
   mtl_release(descriptor);
   descriptor = NULL;

   for (size_t i = 0; i < binding_count; ++i) {
      uint64_t address;

      if (!AO46MetalBufferGetGPUAddress(bindings[i].buffer, &address))
         goto fail;
      mtl_set_address(argument_table, address + bindings[i].offset,
                      bindings[i].index);
   }

   allocator = mtl_new_command_allocator((mtl_device *)adapter->device);
   command_buffer = mtl_new_command_buffer((mtl_device *)adapter->device);
   if (!allocator || !command_buffer)
      goto fail;

   mtl_begin_command_buffer(command_buffer, allocator);
   command_buffer_begun = true;
   encoder = mtl_new_compute_command_encoder(command_buffer);
   if (!encoder)
      goto fail;

   mtl_compute_set_argument_table(encoder, argument_table);
   mtl_compute_set_pipeline_state(
      encoder, (mtl_compute_pipeline_state *)pipeline->native_pipeline);
   mtl_dispatch_threads(
      encoder,
      (struct mtl_size){.x = grid_width, .y = grid_height, .z = grid_depth},
      (struct mtl_size){.x = threads_per_threadgroup_width,
                        .y = threads_per_threadgroup_height,
                        .z = threads_per_threadgroup_depth});
   mtl_end_encoding(encoder);
   mtl_release(encoder);
   encoder = NULL;
   mtl_end_command_buffer(command_buffer);
   command_buffer_begun = false;

   if (!ao46_metal_mtl4_commit_submission(
          adapter, command_buffer, allocator, argument_table, out_submission))
      goto fail;
   command_buffer = NULL;
   allocator = NULL;
   argument_table = NULL;
   return true;

fail:
   if (encoder) {
      mtl_end_encoding(encoder);
      mtl_release(encoder);
   }
   if (command_buffer && command_buffer_begun)
      mtl_end_command_buffer(command_buffer);
   if (command_buffer)
      mtl_release(command_buffer);
   if (allocator)
      mtl_release(allocator);
   if (argument_table)
      mtl_release(argument_table);
   if (descriptor)
      mtl_release(descriptor);
   return false;
}

/*
 * MTL4 argument tables describe GPU-addressed buffers shared by shader stages.
 * Keep the first render migration to buffer-only draws: KK's current bridge has
 * no texture or sampler argument-table setters yet, so those draws retain the
 * classic public-Metal path below.
 */
static bool
ao46_metal_mtl4_record_address(uint64_t address, uint32_t index,
                               uint64_t addresses[31],
                               uint32_t *observed_mask,
                               uint32_t *highest_index)
{
   const uint32_t bit = UINT32_C(1) << index;

   if (!addresses || !observed_mask || !highest_index || index >= 31 ||
       address == 0)
      return false;

   if (*observed_mask & bit)
      return addresses[index] == address;

   addresses[index] = address;
   *observed_mask |= bit;
   if (index > *highest_index)
      *highest_index = index;
   return true;
}

static bool
ao46_metal_mtl4_record_buffer_address(const struct AO46MetalBuffer *buffer,
                                      size_t offset, uint32_t index,
                                      uint64_t addresses[31],
                                      uint32_t *observed_mask,
                                      uint32_t *highest_index)
{
   uint64_t address;

   if (!buffer || !AO46MetalBufferGetGPUAddress(buffer, &address) ||
       offset > buffer->length || offset > UINT64_MAX - address)
      return false;

   return ao46_metal_mtl4_record_address(address + offset, index, addresses,
                                         observed_mask, highest_index);
}

static bool
ao46_metal_mtl4_render_submit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalRenderPipeline *pipeline,
   const struct AO46MetalTexture *color_target,
   const struct AO46MetalUniformBufferBinding *uniform_bindings,
   size_t uniform_binding_count,
   const struct AO46MetalIndexBufferBinding *index_binding,
   const struct AO46MetalVertexBufferBinding *vertex_bindings,
   size_t vertex_binding_count,
   const struct AO46MetalTextureBinding *texture_bindings,
   size_t texture_binding_count,
   const struct AO46MetalSamplerBinding *sampler_bindings,
   size_t sampler_binding_count,
   const struct AO46MetalBufferBinding *vertex_static_buffer_bindings,
   size_t vertex_static_buffer_binding_count,
   const struct AO46MetalBufferBinding *fragment_buffer_bindings,
   size_t fragment_buffer_binding_count,
   enum AO46MetalPrimitive primitive, uint32_t vertex_start,
   uint32_t vertex_count, uint32_t instance_count, uint32_t base_instance,
   struct AO46MetalSubmission *out_submission)
{
   uint64_t addresses[31] = {0};
   uint32_t observed_mask = 0;
   uint32_t highest_index = 1;
   uint32_t highest_texture_index = 0;
   uint32_t highest_sampler_index = 0;
   bool has_texture_bindings = false;
   bool has_sampler_bindings = false;
   mtl_argument_table_descriptor *descriptor = NULL;
   mtl_argument_table *argument_table = NULL;
   mtl_command_allocator *allocator = NULL;
   mtl_command_buffer *command_buffer = NULL;
   mtl_render_pass_descriptor *render_pass = NULL;
   mtl_render_encoder *encoder = NULL;
   bool command_buffer_begun = false;
   enum mtl_primitive_type mtl_primitive;
   enum mtl_index_type mtl_index;

   switch (primitive) {
   case AO46_METAL_PRIMITIVE_TRIANGLES:
      mtl_primitive = MTL_PRIMITIVE_TYPE_TRIANGLE;
      break;
   case AO46_METAL_PRIMITIVE_LINES:
      mtl_primitive = MTL_PRIMITIVE_TYPE_LINE;
      break;
   case AO46_METAL_PRIMITIVE_POINTS:
      mtl_primitive = MTL_PRIMITIVE_TYPE_POINT;
      break;
   default:
      return false;
   }

   if (!AO46MetalAdapterSupportsMTL4Submission(adapter) ||
       !pipeline->uses_mtl4_compiler)
      return false;

   /* Slots zero and one are the stable Mesa/KK graphics ABI. */
   {
      uint64_t root_address;
      uint64_t sampler_table_address;

      if (@available(macOS 13.0, *)) {
         root_address =
            ((__bridge id<MTLBuffer>)adapter->graphics_root_buffer).gpuAddress;
         sampler_table_address =
            ((__bridge id<MTLBuffer>)adapter->graphics_sampler_table_buffer)
               .gpuAddress;
      } else {
         return false;
      }

      for (size_t i = 0; i < uniform_binding_count; ++i) {
         if (uniform_bindings[i].binding == 0) {
            if (!ao46_metal_mtl4_record_buffer_address(
                   uniform_bindings[i].buffer, uniform_bindings[i].offset, 0,
                   addresses,
                   &observed_mask, &highest_index))
               return false;
         }
      }

      if (!(observed_mask & UINT32_C(1)) &&
          !ao46_metal_mtl4_record_address(root_address, 0, addresses,
                                          &observed_mask, &highest_index))
         return false;
      if (!ao46_metal_mtl4_record_address(sampler_table_address, 1, addresses,
                                          &observed_mask, &highest_index))
         return false;
   }

   for (size_t i = 0; i < uniform_binding_count; ++i) {
      if (uniform_bindings[i].binding != 0 &&
          !ao46_metal_mtl4_record_buffer_address(
             uniform_bindings[i].buffer, uniform_bindings[i].offset,
             AO46_METAL_FIRST_UNIFORM_BUFFER_INDEX +
                uniform_bindings[i].binding - 1,
             addresses, &observed_mask, &highest_index))
         return false;
   }
   for (size_t i = 0; i < vertex_static_buffer_binding_count; ++i) {
      if (!ao46_metal_mtl4_record_buffer_address(
             vertex_static_buffer_bindings[i].buffer,
             vertex_static_buffer_bindings[i].offset,
             vertex_static_buffer_bindings[i].index, addresses, &observed_mask,
             &highest_index))
         return false;
   }
   for (size_t i = 0; i < vertex_binding_count; ++i) {
      if (!ao46_metal_mtl4_record_buffer_address(
             vertex_bindings[i].buffer, vertex_bindings[i].offset,
             vertex_bindings[i].index, addresses, &observed_mask,
             &highest_index))
         return false;
   }
   for (size_t i = 0; i < fragment_buffer_binding_count; ++i) {
      if (!ao46_metal_mtl4_record_buffer_address(
             fragment_buffer_bindings[i].buffer,
             fragment_buffer_bindings[i].offset,
             fragment_buffer_bindings[i].index, addresses, &observed_mask,
             &highest_index))
         return false;
   }
   for (size_t i = 0; i < texture_binding_count; ++i) {
      id<MTLTexture> texture =
         (__bridge id<MTLTexture>)texture_bindings[i].texture->native_texture;

      if (texture_bindings[i].index >= 128 || texture.gpuResourceID._impl == 0)
         return false;
      if (texture_bindings[i].index > highest_texture_index)
         highest_texture_index = texture_bindings[i].index;
      has_texture_bindings = true;
   }
   for (size_t i = 0; i < sampler_binding_count; ++i) {
      id<MTLSamplerState> sampler =
         (__bridge id<MTLSamplerState>)sampler_bindings[i].sampler->native_sampler;

      if (sampler_bindings[i].index >= 16 || sampler.gpuResourceID._impl == 0)
         return false;
      if (sampler_bindings[i].index > highest_sampler_index)
         highest_sampler_index = sampler_bindings[i].index;
      has_sampler_bindings = true;
   }

   ao46_metal_mtl4_make_resident(adapter);
   descriptor = mtl_new_argument_table_descriptor();
   if (!descriptor)
      goto fail;
   mtl_set_max_buffer_binding_count(descriptor, highest_index + 1u);
   if (has_texture_bindings)
      mtl_set_max_texture_binding_count(descriptor, highest_texture_index + 1u);
   if (has_sampler_bindings)
      mtl_set_max_sampler_binding_count(descriptor, highest_sampler_index + 1u);
   argument_table = mtl_new_argument_table((mtl_device *)adapter->device,
                                           descriptor);
   if (!argument_table)
      goto fail;
   mtl_release(descriptor);
   descriptor = NULL;

   for (uint32_t index = 0; index <= highest_index; ++index) {
      if (observed_mask & (UINT32_C(1) << index))
         mtl_set_address(argument_table, addresses[index], index);
   }
   for (size_t i = 0; i < texture_binding_count; ++i) {
      id<MTLTexture> texture =
         (__bridge id<MTLTexture>)texture_bindings[i].texture->native_texture;
      mtl_set_texture(argument_table, texture.gpuResourceID._impl,
                      texture_bindings[i].index);
   }
   for (size_t i = 0; i < sampler_binding_count; ++i) {
      id<MTLSamplerState> sampler =
         (__bridge id<MTLSamplerState>)sampler_bindings[i].sampler->native_sampler;
      mtl_set_sampler_state(argument_table, sampler.gpuResourceID._impl,
                            sampler_bindings[i].index);
   }

   allocator = mtl_new_command_allocator((mtl_device *)adapter->device);
   command_buffer = mtl_new_command_buffer((mtl_device *)adapter->device);
   render_pass = mtl_new_render_pass_descriptor();
   if (!allocator || !command_buffer || !render_pass)
      goto fail;

   mtl_render_pass_attachment_descriptor *color_attachment =
      mtl_render_pass_descriptor_get_color_attachment(render_pass, 0);
   mtl_render_pass_attachment_descriptor_set_texture(
      color_attachment, (mtl_texture *)color_target->native_texture);
   mtl_render_pass_attachment_descriptor_set_load_action(
      color_attachment, MTL_LOAD_ACTION_LOAD);
   mtl_render_pass_attachment_descriptor_set_store_action(
      color_attachment, MTL_STORE_ACTION_STORE);
   mtl_render_pass_descriptor_set_render_target_width(render_pass,
                                                       color_target->width);
   mtl_render_pass_descriptor_set_render_target_height(render_pass,
                                                        color_target->height);
   mtl_render_pass_descriptor_set_default_raster_sample_count(render_pass, 1);

   mtl_begin_command_buffer(command_buffer, allocator);
   command_buffer_begun = true;
   encoder = mtl_new_render_command_encoder_with_descriptor(command_buffer,
                                                            render_pass);
   if (!encoder)
      goto fail;

   struct mtl_viewport viewport = {
      .originX = 0.0,
      .originY = 0.0,
      .width = color_target->width,
      .height = color_target->height,
      .znear = 0.0,
      .zfar = 1.0,
   };
   mtl_set_viewports(encoder, &viewport, 1);
   mtl_set_cull_mode(encoder, MTL_CULL_MODE_NONE);
   mtl_render_set_pipeline_state(
      encoder, (mtl_render_pipeline_state *)pipeline->native_pipeline);
   mtl_render_set_argument_table(
      encoder, argument_table,
      MTL_RENDER_STAGE_VERTEX | MTL_RENDER_STAGE_FRAGMENT);

   if (index_binding) {
      uint64_t index_address;

      if (!AO46MetalBufferGetGPUAddress(index_binding->buffer, &index_address) ||
          index_binding->offset > UINT64_MAX - index_address)
         goto fail;
      switch (index_binding->format) {
      case AO46_METAL_INDEX_FORMAT_UINT16:
         mtl_index = MTL_INDEX_TYPE_UINT16;
         break;
      case AO46_METAL_INDEX_FORMAT_UINT32:
         mtl_index = MTL_INDEX_TYPE_UINT32;
         break;
      default:
         goto fail;
      }
      mtl_draw_indexed_primitives(
         encoder, mtl_primitive, index_binding->count, mtl_index,
         index_address + index_binding->offset, index_binding->size,
         instance_count, index_binding->base_vertex, base_instance);
   } else {
      mtl_draw_primitives(encoder, mtl_primitive, vertex_start, vertex_count,
                          instance_count, base_instance);
   }

   mtl_end_encoding(encoder);
   mtl_release(encoder);
   encoder = NULL;
   mtl_end_command_buffer(command_buffer);
   command_buffer_begun = false;
   mtl_release(render_pass);
   render_pass = NULL;

   if (!ao46_metal_mtl4_commit_submission(
          adapter, command_buffer, allocator, argument_table, out_submission))
      goto fail;
   command_buffer = NULL;
   allocator = NULL;
   argument_table = NULL;
   return true;

fail:
   if (encoder) {
      mtl_end_encoding(encoder);
      mtl_release(encoder);
   }
   if (command_buffer && command_buffer_begun)
      mtl_end_command_buffer(command_buffer);
   if (render_pass)
      mtl_release(render_pass);
   if (command_buffer)
      mtl_release(command_buffer);
   if (allocator)
      mtl_release(allocator);
   if (argument_table)
      mtl_release(argument_table);
   if (descriptor)
      mtl_release(descriptor);
   return false;
}

static bool
ao46_metal_compute_submit_internal(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission, bool allow_mtl4)
{
   __block bool submitted = false;

   if (!AO46MetalAdapterIsCurrent(adapter) || !pipeline ||
       pipeline->adapter != adapter || !pipeline->native_pipeline ||
       pipeline->thread_execution_width == 0 ||
       pipeline->max_threads_per_threadgroup == 0 ||
       !bindings || binding_count == 0 || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission) ||
       grid_width == 0 || grid_height == 0 || grid_depth == 0 ||
       threads_per_threadgroup_width == 0 ||
       threads_per_threadgroup_height == 0 || threads_per_threadgroup_depth == 0)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      if (!AO46MetalBufferIsCurrent(bindings[i].buffer) ||
          bindings[i].buffer->adapter != adapter ||
          bindings[i].offset >= bindings[i].buffer->length)
       return false;
   }

   if ((uint64_t)threads_per_threadgroup_width *
          threads_per_threadgroup_height * threads_per_threadgroup_depth >
       pipeline->max_threads_per_threadgroup)
      return false;

   /* MTL4 owns this lifecycle when its compiler PSO and address ABI are live. */
   if (allow_mtl4 && AO46MetalAdapterSupportsMTL4Submission(adapter) &&
       pipeline->uses_mtl4_compiler &&
       ao46_metal_mtl4_compute_submit(
          adapter, pipeline, bindings, binding_count, grid_width, grid_height,
          grid_depth, threads_per_threadgroup_width,
          threads_per_threadgroup_height, threads_per_threadgroup_depth,
          out_submission)) {
      return true;
   }

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLComputePipelineState> native_pipeline =
         (__bridge id<MTLComputePipelineState>)(
            pipeline->native_classic_pipeline
               ? pipeline->native_classic_pipeline
               : pipeline->native_pipeline);
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLComputeCommandEncoder> encoder =
         command_buffer ? [command_buffer computeCommandEncoder] : nil;

      if (encoder) {
         [encoder setComputePipelineState:native_pipeline];
         for (size_t i = 0; i < binding_count; ++i) {
            id<MTLBuffer> buffer =
               (__bridge id<MTLBuffer>)bindings[i].buffer->native_buffer;
            [encoder setBuffer:buffer offset:bindings[i].offset atIndex:bindings[i].index];
            [encoder useResource:buffer
                            usage:bindings[i].writable
                                     ? MTLResourceUsageRead | MTLResourceUsageWrite
                                     : MTLResourceUsageRead];
         }

         [encoder dispatchThreads:MTLSizeMake(grid_width, grid_height, grid_depth)
            threadsPerThreadgroup:MTLSizeMake(threads_per_threadgroup_width,
                                              threads_per_threadgroup_height,
                                              threads_per_threadgroup_depth)];
         [encoder endEncoding];
         [command_buffer commit];

         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalComputeSubmit(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission)
{
   return ao46_metal_compute_submit_internal(
      adapter, pipeline, bindings, binding_count, grid_width, grid_height,
      grid_depth, threads_per_threadgroup_width,
      threads_per_threadgroup_height, threads_per_threadgroup_depth,
      out_submission, true);
}

bool
AO46MetalComputeSubmitClassic(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   uint32_t grid_width, uint32_t grid_height, uint32_t grid_depth,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission)
{
   return ao46_metal_compute_submit_internal(
      adapter, pipeline, bindings, binding_count, grid_width, grid_height,
      grid_depth, threads_per_threadgroup_width,
      threads_per_threadgroup_height, threads_per_threadgroup_depth,
      out_submission, false);
}

bool
AO46MetalComputeSubmitIndirect(
   const struct AO46MetalAdapter *adapter,
   const struct AO46MetalComputePipeline *pipeline,
   const struct AO46MetalBufferBinding *bindings, size_t binding_count,
   const struct AO46MetalBuffer *indirect_buffer, size_t indirect_offset,
   uint32_t threads_per_threadgroup_width,
   uint32_t threads_per_threadgroup_height,
   uint32_t threads_per_threadgroup_depth,
   struct AO46MetalSubmission *out_submission)
{
   __block bool submitted = false;
   const size_t indirect_size = 3 * sizeof(uint32_t);

   if (!AO46MetalAdapterIsCurrent(adapter) || !pipeline ||
       pipeline->adapter != adapter || !pipeline->native_classic_pipeline ||
       pipeline->thread_execution_width == 0 ||
       pipeline->max_threads_per_threadgroup == 0 || !bindings ||
       binding_count == 0 || !AO46MetalBufferIsCurrent(indirect_buffer) ||
       indirect_buffer->adapter != adapter || indirect_offset % sizeof(uint32_t) != 0 ||
       indirect_offset > indirect_buffer->length ||
       indirect_size > indirect_buffer->length - indirect_offset || !out_submission ||
       !ao46_metal_submission_is_empty(out_submission) ||
       threads_per_threadgroup_width == 0 ||
       threads_per_threadgroup_height == 0 || threads_per_threadgroup_depth == 0)
      return false;

   for (size_t i = 0; i < binding_count; ++i) {
      if (!AO46MetalBufferIsCurrent(bindings[i].buffer) ||
          bindings[i].buffer->adapter != adapter ||
          bindings[i].offset >= bindings[i].buffer->length)
         return false;
   }

   if ((uint64_t)threads_per_threadgroup_width *
          threads_per_threadgroup_height * threads_per_threadgroup_depth >
       pipeline->max_threads_per_threadgroup)
      return false;

   @autoreleasepool {
      id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)adapter->queue;
      id<MTLComputePipelineState> native_pipeline =
         (__bridge id<MTLComputePipelineState>)pipeline->native_classic_pipeline;
      id<MTLBuffer> native_indirect_buffer =
         (__bridge id<MTLBuffer>)indirect_buffer->native_buffer;
      id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
      id<MTLComputeCommandEncoder> encoder =
         command_buffer ? [command_buffer computeCommandEncoder] : nil;

      if (encoder) {
         [encoder setComputePipelineState:native_pipeline];
         for (size_t i = 0; i < binding_count; ++i) {
            id<MTLBuffer> buffer =
               (__bridge id<MTLBuffer>)bindings[i].buffer->native_buffer;
            [encoder setBuffer:buffer offset:bindings[i].offset atIndex:bindings[i].index];
            [encoder useResource:buffer
                            usage:bindings[i].writable
                                     ? MTLResourceUsageRead | MTLResourceUsageWrite
                                     : MTLResourceUsageRead];
         }
         [encoder useResource:native_indirect_buffer usage:MTLResourceUsageRead];
         [encoder dispatchThreadgroupsWithIndirectBuffer:native_indirect_buffer
                                    indirectBufferOffset:indirect_offset
                                     threadsPerThreadgroup:MTLSizeMake(
                                        threads_per_threadgroup_width,
                                        threads_per_threadgroup_height,
                                        threads_per_threadgroup_depth)];
         [encoder endEncoding];
         [command_buffer commit];

         *out_submission = (struct AO46MetalSubmission){
            .adapter = adapter,
            .native_command_buffer = (__bridge_retained void *)command_buffer,
         };
         submitted = true;
      }
   }

   return submitted;
}

bool
AO46MetalSubmissionWait(struct AO46MetalSubmission *submission)
{
   id<MTLCommandBuffer> command_buffer;

   if (!submission || !AO46MetalAdapterIsCurrent(submission->adapter) ||
       !submission->native_command_buffer)
      return false;

   if (submission->uses_mtl4)
      return ao46_metal_mtl4_completion_wait(
         submission->native_completion_state);

   command_buffer = (__bridge id<MTLCommandBuffer>)submission->native_command_buffer;
   if (command_buffer.status == MTLCommandBufferStatusNotEnqueued)
      return false;
   [command_buffer waitUntilCompleted];
   return command_buffer.status == MTLCommandBufferStatusCompleted;
}

bool
AO46MetalSubmissionIsComplete(const struct AO46MetalSubmission *submission)
{
   id<MTLCommandBuffer> command_buffer;

   if (!submission || !AO46MetalAdapterIsCurrent(submission->adapter) ||
       !submission->native_command_buffer)
      return false;

   if (submission->uses_mtl4)
      return ao46_metal_mtl4_completion_is_complete(
         submission->native_completion_state);

   command_buffer = (__bridge id<MTLCommandBuffer>)submission->native_command_buffer;
   return command_buffer.status == MTLCommandBufferStatusCompleted;
}

void
AO46MetalSubmissionDestroy(struct AO46MetalSubmission *submission)
{
   if (!submission)
      return;

   if (submission->uses_mtl4) {
      /* MTL4 allocators and argument tables outlive the queue until feedback. */
      (void)AO46MetalSubmissionWait(submission);
      if (submission->native_commit_options)
         mtl_release(submission->native_commit_options);
      if (submission->native_argument_table)
         mtl_release(submission->native_argument_table);
      if (submission->native_command_allocator)
         mtl_release(submission->native_command_allocator);
      if (submission->native_command_buffer)
         mtl_release(submission->native_command_buffer);
      if (submission->native_completion_state)
         CFBridgingRelease(submission->native_completion_state);
      if (submission->native_presentation_allocation) {
         AO46MetalAdapterUntrackExternalAllocation(
            submission->adapter, submission->native_presentation_allocation);
         CFBridgingRelease(submission->native_presentation_allocation);
      }
      if (submission->native_presentation_drawable)
         CFBridgingRelease(submission->native_presentation_drawable);
   } else if (submission->native_command_buffer) {
      CFBridgingRelease(submission->native_command_buffer);
   }
   *submission = (struct AO46MetalSubmission){0};
}
