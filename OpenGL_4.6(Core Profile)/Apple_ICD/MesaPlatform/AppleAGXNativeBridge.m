/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "AppleAGXNativeBridge.h"

#include <dlfcn.h>
#include <string.h>

#include "asahi/lib/agx_macos_device.h"

#define AO46_IOGPU_PATH \
   "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU"
#define AO46_G16X_DEVICE_REF_ENCODING "^{__IOGPUDevice=}16@0:8"

struct AppleAGXNativeBridgeSymbol {
   const char *name;
   size_t offset;
};

static const struct AppleAGXNativeBridgeSymbol apple_agx_native_symbols[] = {
   { "IOGPUDeviceCreate", offsetof(struct AppleAGXNativeBridge, device_create) },
   { "IOGPUDeviceGetNextGlobalTraceID",
     offsetof(struct AppleAGXNativeBridge, device_get_next_global_trace_id) },
   { "IOGPUCommandQueueCreate", offsetof(struct AppleAGXNativeBridge,
                                            command_queue_create) },
   { "IOGPUCommandQueueGetConnect", offsetof(struct AppleAGXNativeBridge,
                                                command_queue_get_connect) },
   { "IOGPUCommandQueueGetID", offsetof(struct AppleAGXNativeBridge,
                                           command_queue_get_id) },
   { "IOGPUCommandQueueRelease", offsetof(struct AppleAGXNativeBridge,
                                            command_queue_release) },
   { "IOGPUCommandQueueSubmitCommandBuffers",
     offsetof(struct AppleAGXNativeBridge, command_queue_submit_command_buffers) },
   { "IOGPUMetalCommandBufferStoragePoolCreateStorage",
     offsetof(struct AppleAGXNativeBridge,
              command_buffer_storage_pool_create_storage) },
   { "IOGPUMetalCommandBufferStorageCreateExt",
     offsetof(struct AppleAGXNativeBridge, command_buffer_storage_create_ext) },
   { "IOGPUMetalCommandBufferStorageDealloc",
     offsetof(struct AppleAGXNativeBridge, command_buffer_storage_dealloc) },
   { "IOGPUMetalCommandBufferStorageBeginSegment",
     offsetof(struct AppleAGXNativeBridge,
              command_buffer_storage_begin_segment) },
   { "IOGPUMetalCommandBufferStorageEndSegment",
     offsetof(struct AppleAGXNativeBridge,
              command_buffer_storage_end_segment) },
   { "IOGPUResourceListAddResource",
     offsetof(struct AppleAGXNativeBridge, resource_list_add_resource) },
   { "IOGPUResourceCreate", offsetof(struct AppleAGXNativeBridge,
                                       resource_create) },
   { "IOGPUResourceGetGPUVirtualAddress",
     offsetof(struct AppleAGXNativeBridge, resource_get_gpu_virtual_address) },
   { "IOGPUResourceGetGPUVirtualAddressLength",
     offsetof(struct AppleAGXNativeBridge,
              resource_get_gpu_virtual_address_length) },
   { "IOGPUResourceGetDataBytes", offsetof(struct AppleAGXNativeBridge,
                                               resource_get_data_bytes) },
   { "IOGPUResourceGetDataSize", offsetof(struct AppleAGXNativeBridge,
                                              resource_get_data_size) },
   { "IOGPUResourceGetResidentDataSize",
     offsetof(struct AppleAGXNativeBridge, resource_get_resident_data_size) },
   { "IOGPUResourceRelease", offsetof(struct AppleAGXNativeBridge,
                                        resource_release) },
};

static bool
apple_agx_native_bridge_resolve_symbols(struct AppleAGXNativeBridge *bridge)
{
   for (unsigned i = 0;
        i < sizeof(apple_agx_native_symbols) / sizeof(apple_agx_native_symbols[0]);
        ++i) {
      const struct AppleAGXNativeBridgeSymbol *required =
         &apple_agx_native_symbols[i];
      void *symbol = dlsym(bridge->iogpu_image, required->name);
      Dl_info image = {0};

      if (!symbol || !dladdr(symbol, &image) || !image.dli_fname ||
          !strstr(image.dli_fname, "IOGPU.framework") || !image.dli_sname ||
          strcmp(image.dli_sname, required->name) != 0) {
         return false;
      }

      *(void **)((unsigned char *)bridge + required->offset) = symbol;
   }

   return true;
}

static bool
apple_agx_native_bridge_resolve_carrier_pool(struct AppleAGXNativeBridge *bridge,
                                             Class device_class)
{
   Ivar pool_ivar;
   const char *encoding;
   ptrdiff_t offset;
   size_t instance_size;
   const void *pool = NULL;

   if (!bridge || !bridge->metal_device || !device_class)
      return false;

   pool_ivar = class_getInstanceVariable(device_class,
                                         "_commandBufferStoragePool");
   encoding = pool_ivar ? ivar_getTypeEncoding(pool_ivar) : NULL;
   offset = pool_ivar ? ivar_getOffset(pool_ivar) : 0;
   instance_size = class_getInstanceSize(device_class);
   if (!encoding || encoding[0] != '^' || offset <= 0 ||
       (size_t)offset > instance_size ||
       sizeof(pool) > instance_size - (size_t)offset) {
      return false;
   }

   /* The profiled runtime declares this as a raw storage-pool pointer, not an
    * Objective-C object. Read only that pointer after validating its runtime
    * type and bounds; the pool remains wholly Apple-owned. */
   memcpy(&pool, (const unsigned char *)bridge->metal_device + offset,
          sizeof(pool));
   if (!pool)
      return false;

   bridge->command_buffer_storage_pool = pool;
   bridge->command_buffer_storage_pool_offset = offset;
   return true;
}

bool
AppleAGXNativeBridgeIsCurrent(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   if (!bridge || !agx_macos_device_session_is_open(session) ||
       !bridge->metal_device ||
       !bridge->device_ref || !bridge->iogpu_image ||
       !bridge->command_buffer_storage_pool ||
       bridge->command_buffer_storage_pool_offset <= 0) {
      return false;
   }

   for (unsigned i = 0;
        i < sizeof(apple_agx_native_symbols) / sizeof(apple_agx_native_symbols[0]);
        ++i) {
      if (!*(void *const *)((const unsigned char *)bridge +
                            apple_agx_native_symbols[i].offset)) {
         return false;
      }
   }

   return true;
}

bool
AppleAGXNativeBridgeHasObservedCarrierPool(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   return AppleAGXNativeBridgeIsCurrent(bridge, session) &&
          bridge->command_buffer_storage_pool_create_storage;
}

bool
AppleAGXNativeBridgeHasObservedSegmentContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   return AppleAGXNativeBridgeHasObservedCarrierPool(bridge, session) &&
          bridge->command_buffer_storage_begin_segment &&
          bridge->command_buffer_storage_end_segment;
}

bool
AppleAGXNativeBridgeHasObservedResourceListBindingContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   return AppleAGXNativeBridgeHasObservedSegmentContract(bridge, session) &&
          bridge->resource_list_add_resource;
}

bool
AppleAGXNativeBridgeHasObservedResourceContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   return AppleAGXNativeBridgeIsCurrent(bridge, session) &&
          bridge->resource_create && bridge->resource_get_gpu_virtual_address &&
          bridge->resource_get_gpu_virtual_address_length &&
          bridge->resource_get_data_bytes && bridge->resource_get_data_size &&
          bridge->resource_get_resident_data_size &&
          bridge->resource_release;
}

bool
AppleAGXNativeBridgeOpen(
   struct AppleAGXNativeBridge *out_bridge,
   const struct agx_macos_device_session *session)
{
   struct AppleAGXNativeBridge bridge = {0};
   Class device_class;
   Method device_ref_method;
   SEL device_ref_selector;
   const char *encoding;
   IMP device_ref_implementation;
   const void *(*device_ref)(id, SEL);

   if (!out_bridge || !agx_macos_device_session_is_open(session) ||
       out_bridge->metal_device ||
       out_bridge->device_ref || out_bridge->iogpu_image) {
      return false;
   }

   @autoreleasepool {
      bridge.metal_device = MTLCreateSystemDefaultDevice();
   }
   if (!bridge.metal_device)
      return false;

   device_class = objc_lookUpClass("IOGPUMetalDevice");
   device_ref_selector = sel_registerName("deviceRef");
   device_ref_method = device_class
      ? class_getInstanceMethod(device_class, device_ref_selector)
      : NULL;
   encoding = device_ref_method ? method_getTypeEncoding(device_ref_method) : NULL;
   if (!device_class || ![(id)bridge.metal_device isKindOfClass:device_class] ||
       !encoding || strcmp(encoding, AO46_G16X_DEVICE_REF_ENCODING) != 0) {
      goto fail;
   }

   device_ref_implementation = [(id)bridge.metal_device
      methodForSelector:device_ref_selector];
   if (!device_ref_implementation)
      goto fail;

   device_ref = (const void *(*)(id, SEL))device_ref_implementation;
   bridge.device_ref = device_ref((id)bridge.metal_device, device_ref_selector);
   if (!bridge.device_ref)
      goto fail;

   bridge.iogpu_image = dlopen(AO46_IOGPU_PATH, RTLD_NOW | RTLD_LOCAL);
   if (!bridge.iogpu_image || !apple_agx_native_bridge_resolve_symbols(&bridge))
      goto fail;
   if (!apple_agx_native_bridge_resolve_carrier_pool(&bridge, device_class))
      goto fail;

   *out_bridge = bridge;
   return true;

fail:
   AppleAGXNativeBridgeClose(&bridge);
   return false;
}

void
AppleAGXNativeBridgeClose(struct AppleAGXNativeBridge *bridge)
{
   if (!bridge)
      return;

   if (bridge->metal_device)
      [(id)bridge->metal_device release];
   if (bridge->iogpu_image)
      dlclose(bridge->iogpu_image);

   *bridge = (struct AppleAGXNativeBridge){0};
}
