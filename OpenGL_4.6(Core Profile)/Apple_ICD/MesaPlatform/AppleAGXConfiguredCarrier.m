/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>
#import <objc/runtime.h>

#include "AppleAGXConfiguredCarrier.h"

#include "AppleAGXMetalResourceRef.h"
#include "AppleAGXNativeBridge.h"

#include <stdint.h>
#include <string.h>

#define AO46_G16X_QUEUE_INIT_ENCODING "@32@0:8@16@24"
#define AO46_G16X_COMMAND_BUFFER_INIT_ENCODING "@32@0:8@16B24B28"
#define AO46_G16X_GET_KERNEL_COMMANDS_ENCODING "v40@0:8^^v16^^v24^^v32"
#define AO46_G16X_SEGMENT_CURSOR_DELTA 0xacU
#define AO46_G16X_RESOURCE_LIST_OFFSET 0x90U
#define AO46_G16X_STORAGE_IVAR_PREFIX \
   "^{IOGPUMetalCommandBufferStorage="

typedef void (*AppleAGXGetKernelCommandsFn)(id command_buffer,
                                             SEL selector,
                                             void **out_start,
                                             void **out_current,
                                             void **out_end);
typedef void *(*AppleAGXStorageBeginSegmentFn)(void *storage,
                                                void *kernel_cursor);
typedef void (*AppleAGXStorageEndSegmentFn)(void *storage);
typedef void (*AppleAGXResourceListAddResourceFn)(void *resource_list,
                                                   const void *binding);

static bool
apple_agx_configured_carrier_storage(const struct AppleAGXConfiguredCarrier *carrier,
                                     void **out_storage)
{
   Class command_buffer_class;
   Ivar storage_ivar;
   const char *encoding;
   ptrdiff_t offset;
   size_t instance_size;
   void *storage = NULL;

   if (!carrier || !carrier->command_buffer || !out_storage)
      return false;

   command_buffer_class = objc_lookUpClass("IOGPUMetalCommandBuffer");
   storage_ivar = command_buffer_class
      ? class_getInstanceVariable(command_buffer_class, "_storage")
      : NULL;
   encoding = storage_ivar ? ivar_getTypeEncoding(storage_ivar) : NULL;
   offset = storage_ivar ? ivar_getOffset(storage_ivar) : 0;
   instance_size = command_buffer_class ? class_getInstanceSize(command_buffer_class) : 0;
   if (!encoding || strncmp(encoding, AO46_G16X_STORAGE_IVAR_PREFIX,
                            strlen(AO46_G16X_STORAGE_IVAR_PREFIX)) != 0 ||
       offset <= 0 || (size_t)offset > instance_size ||
       sizeof(storage) > instance_size - (size_t)offset) {
      return false;
   }

   memcpy(&storage, (const unsigned char *)carrier->command_buffer + offset,
          sizeof(storage));
   if (!storage)
      return false;

   *out_storage = storage;
   return true;
}

bool
AppleAGXConfiguredCarrierIsCurrent(
   const struct AppleAGXConfiguredCarrier *carrier)
{
   return carrier && carrier->bridge && carrier->bridge->metal_device &&
          carrier->queue && carrier->command_buffer && carrier->queue_descriptor &&
          carrier->storage;
}

bool
AppleAGXConfiguredCarrierCreate(
   const struct AppleAGXNativeBridge *bridge,
   struct AppleAGXConfiguredCarrier *out_carrier)
{
   Class queue_class;
   Class command_buffer_class;
   SEL queue_init_selector;
   SEL command_buffer_init_selector;
   Method queue_init_method;
   Method command_buffer_init_method;
   const char *queue_init_encoding;
   const char *command_buffer_init_encoding;
   id descriptor = nil;
   id queue = nil;
   id command_buffer = nil;
   void *storage = NULL;

   if (!bridge || !out_carrier || out_carrier->bridge || out_carrier->queue ||
       out_carrier->command_buffer || out_carrier->queue_descriptor ||
       out_carrier->storage || !bridge->metal_device) {
      return false;
   }

   queue_class = objc_lookUpClass("IOGPUMetalCommandQueue");
   command_buffer_class = objc_lookUpClass("IOGPUMetalCommandBuffer");
   queue_init_selector = sel_registerName("initWithDevice:descriptor:");
   command_buffer_init_selector =
      sel_registerName("initWithQueue:retainedReferences:synchronousDebugMode:");
   queue_init_method = queue_class
      ? class_getInstanceMethod(queue_class, queue_init_selector)
      : NULL;
   command_buffer_init_method = command_buffer_class
      ? class_getInstanceMethod(command_buffer_class, command_buffer_init_selector)
      : NULL;
   queue_init_encoding = queue_init_method ? method_getTypeEncoding(queue_init_method) : NULL;
   command_buffer_init_encoding = command_buffer_init_method
      ? method_getTypeEncoding(command_buffer_init_method)
      : NULL;
   if (!queue_class || !command_buffer_class || !queue_init_encoding ||
       strcmp(queue_init_encoding, AO46_G16X_QUEUE_INIT_ENCODING) != 0 ||
       !command_buffer_init_encoding ||
       strcmp(command_buffer_init_encoding,
              AO46_G16X_COMMAND_BUFFER_INIT_ENCODING) != 0) {
      return false;
   }

   descriptor = [[MTLCommandQueueDescriptor alloc] init];
   if (!descriptor)
      goto fail;

   /* The direct queue initializer is not a standalone constructor: it
    * requires an Apple-owned 0x410 queue argument record. Use only Apple's
    * public factory to establish that queue state, then retain its private
    * carrier objects without creating an encoder or submitting work. */
   queue = [(id<MTLDevice>)bridge->metal_device
      newCommandQueueWithDescriptor:descriptor];
   if (!queue || ![queue isKindOfClass:queue_class])
      goto fail;

   command_buffer = [(id<MTLCommandQueue>)queue commandBuffer];
   if (!command_buffer || ![command_buffer isKindOfClass:command_buffer_class])
      goto fail;

   {
      const struct AppleAGXConfiguredCarrier candidate = {
         .bridge = bridge,
         .queue = queue,
         .command_buffer = command_buffer,
         .queue_descriptor = descriptor,
      };

      if (!apple_agx_configured_carrier_storage(&candidate, &storage))
         goto fail;
   }

   *out_carrier = (struct AppleAGXConfiguredCarrier){
      .bridge = bridge,
      .queue = queue,
      .command_buffer = command_buffer,
      .queue_descriptor = descriptor,
      .storage = storage,
   };
   return true;

fail:
   if (command_buffer)
      [command_buffer release];
   if (queue)
      [queue release];
   if (descriptor)
      [descriptor release];
   return false;
}

bool
AppleAGXConfiguredCarrierSnapshotRead(
   const struct AppleAGXConfiguredCarrier *carrier,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot)
{
   if (!AppleAGXConfiguredCarrierIsCurrent(carrier) || !out_snapshot)
      return false;

   return AppleAGXOpaqueCarrierStorageSnapshotRead(carrier->storage,
                                                   out_snapshot);
}

bool
AppleAGXConfiguredCarrierKernelCommandsRead(
   const struct AppleAGXConfiguredCarrier *carrier,
   struct AppleAGXConfiguredCarrierKernelCommands *out_commands)
{
   Class command_buffer_class;
   SEL selector;
   Method method;
   const char *encoding;
   AppleAGXGetKernelCommandsFn get_commands;
   void *start = NULL;
   void *current = NULL;
   void *end = NULL;

   if (!AppleAGXConfiguredCarrierIsCurrent(carrier) || !out_commands)
      return false;

   command_buffer_class = objc_lookUpClass("IOGPUMetalCommandBuffer");
   selector = sel_registerName("getCurrentKernelCommandBufferStart:current:end:");
   method = command_buffer_class
      ? class_getInstanceMethod(command_buffer_class, selector)
      : NULL;
   encoding = method ? method_getTypeEncoding(method) : NULL;
   if (!command_buffer_class ||
       ![(id)carrier->command_buffer isKindOfClass:command_buffer_class] ||
       !encoding ||
       strcmp(encoding, AO46_G16X_GET_KERNEL_COMMANDS_ENCODING) != 0) {
      return false;
   }

   get_commands = (AppleAGXGetKernelCommandsFn)[(id)carrier->command_buffer
      methodForSelector:selector];
   if (!get_commands)
      return false;

   get_commands((id)carrier->command_buffer, selector,
                &start, &current, &end);
   if (!start || !current || !end ||
       (uintptr_t)start > (uintptr_t)current ||
       (uintptr_t)current > (uintptr_t)end) {
      return false;
   }

   *out_commands = (struct AppleAGXConfiguredCarrierKernelCommands){
      .start = start,
      .current = current,
      .end = end,
   };
   return true;
}

bool
AppleAGXConfiguredCarrierNoResourceSegmentSmoke(
   const struct AppleAGXConfiguredCarrier *carrier)
{
   struct AppleAGXConfiguredCarrierKernelCommands commands = {0};
   struct AppleAGXOpaqueCarrierSnapshot before = {0};
   struct AppleAGXOpaqueCarrierSnapshot after = {0};
   AppleAGXStorageBeginSegmentFn begin_segment;
   AppleAGXStorageEndSegmentFn end_segment;
   void *segment;

   if (!AppleAGXConfiguredCarrierIsCurrent(carrier) ||
       !carrier->bridge->command_buffer_storage_begin_segment ||
       !carrier->bridge->command_buffer_storage_end_segment ||
       !AppleAGXConfiguredCarrierKernelCommandsRead(carrier, &commands) ||
       (uintptr_t)commands.current - (uintptr_t)commands.start !=
          AO46_G16X_SEGMENT_CURSOR_DELTA ||
       !AppleAGXConfiguredCarrierSnapshotRead(carrier, &before)) {
      return false;
   }

   begin_segment = (AppleAGXStorageBeginSegmentFn)carrier->bridge
      ->command_buffer_storage_begin_segment;
   end_segment = (AppleAGXStorageEndSegmentFn)carrier->bridge
      ->command_buffer_storage_end_segment;
   segment = begin_segment(carrier->storage, commands.current);
   /* End the storage transition even when the observed return handle is
    * unexpectedly null; an isolated probe must not leave carrier state open. */
   end_segment(carrier->storage);
   return segment && AppleAGXConfiguredCarrierSnapshotRead(carrier, &after) &&
          after.resource_slot_count == before.resource_slot_count &&
          after.initialized_slot_count == before.initialized_slot_count;
}

bool
AppleAGXConfiguredCarrierAddMetalResource(
   const struct AppleAGXConfiguredCarrier *carrier,
   const struct AppleAGXMetalResourceRef *resource_ref)
{
   struct AppleAGXConfiguredCarrierKernelCommands commands = {0};
   struct AppleAGXOpaqueCarrierSnapshot before = {0};
   struct AppleAGXOpaqueCarrierSnapshot after = {0};
   AppleAGXStorageBeginSegmentFn begin_segment;
   AppleAGXStorageEndSegmentFn end_segment;
   AppleAGXResourceListAddResourceFn add_resource;
   void *segment;
   void *resource_list;

   if (!AppleAGXConfiguredCarrierIsCurrent(carrier) ||
       !AppleAGXMetalResourceRefIsCurrent(resource_ref) ||
       resource_ref->bridge != carrier->bridge ||
       !carrier->bridge->command_buffer_storage_begin_segment ||
       !carrier->bridge->command_buffer_storage_end_segment ||
       !carrier->bridge->resource_list_add_resource ||
       !AppleAGXConfiguredCarrierKernelCommandsRead(carrier, &commands) ||
       (uintptr_t)commands.current - (uintptr_t)commands.start !=
          AO46_G16X_SEGMENT_CURSOR_DELTA ||
       (uintptr_t)carrier->storage >
          UINTPTR_MAX - AO46_G16X_RESOURCE_LIST_OFFSET ||
       !AppleAGXConfiguredCarrierSnapshotRead(carrier, &before)) {
      return false;
   }

   begin_segment = (AppleAGXStorageBeginSegmentFn)carrier->bridge
      ->command_buffer_storage_begin_segment;
   end_segment = (AppleAGXStorageEndSegmentFn)carrier->bridge
      ->command_buffer_storage_end_segment;
   add_resource = (AppleAGXResourceListAddResourceFn)carrier->bridge
      ->resource_list_add_resource;
   resource_list = (uint8_t *)carrier->storage + AO46_G16X_RESOURCE_LIST_OFFSET;

   segment = begin_segment(carrier->storage, commands.current);
   if (segment)
      add_resource(resource_list, resource_ref->resource_list_binding);
   end_segment(carrier->storage);

   return segment && AppleAGXConfiguredCarrierSnapshotRead(carrier, &after) &&
          after.resource_slot_count == before.resource_slot_count &&
          after.initialized_slot_count == before.initialized_slot_count;
}

void
AppleAGXConfiguredCarrierDestroy(struct AppleAGXConfiguredCarrier *carrier)
{
   if (!carrier)
      return;

   if (carrier->command_buffer)
      [(id)carrier->command_buffer release];
   if (carrier->queue)
      [(id)carrier->queue release];
   if (carrier->queue_descriptor)
      [(id)carrier->queue_descriptor release];

   *carrier = (struct AppleAGXConfiguredCarrier){0};
}
