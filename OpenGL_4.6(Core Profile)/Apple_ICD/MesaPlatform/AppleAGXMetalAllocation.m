/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>

#include "AppleAGXMetalAllocation.h"
#include "AppleAGXNativeBridge.h"

static bool
apple_agx_metal_allocation_is_empty(
   const struct AppleAGXMetalAllocation *allocation)
{
   return allocation && !allocation->metal_buffer && !allocation->cpu_mapping &&
          allocation->gpu_va == 0 && allocation->size == 0;
}

static bool
apple_agx_metal_allocation_options(enum AppleAGXMetalAllocationStorage storage,
                                   MTLResourceOptions *out_options)
{
   if (!out_options)
      return false;

   switch (storage) {
   case APPLE_AGX_METAL_ALLOCATION_SHARED:
      *out_options = MTLResourceStorageModeShared;
      return true;
   case APPLE_AGX_METAL_ALLOCATION_WRITE_COMBINED:
      *out_options = MTLResourceStorageModeShared |
                     MTLResourceCPUCacheModeWriteCombined;
      return true;
   case APPLE_AGX_METAL_ALLOCATION_PRIVATE:
      *out_options = MTLResourceStorageModePrivate;
      return true;
   }

   return false;
}

bool
AppleAGXMetalAllocationCreate(
   const struct AppleAGXNativeBridge *bridge, uint64_t size,
   enum AppleAGXMetalAllocationStorage storage,
   struct AppleAGXMetalAllocation *out_allocation)
{
   MTLResourceOptions options;
   id<MTLBuffer> buffer;
   void *cpu_mapping = NULL;
   uint64_t gpu_va;

   if (!bridge || !bridge->metal_device || !out_allocation ||
       !apple_agx_metal_allocation_is_empty(out_allocation) || size == 0 ||
       size > NSUIntegerMax) {
      return false;
   }

   if (!apple_agx_metal_allocation_options(storage, &options))
      return false;

   buffer = [(id<MTLDevice>)bridge->metal_device
      newBufferWithLength:(NSUInteger)size options:options];
   if (!buffer || [buffer length] != (NSUInteger)size) {
      [buffer release];
      return false;
   }

   gpu_va = [buffer gpuAddress];
   if (gpu_va == 0) {
      [buffer release];
      return false;
   }

   if (storage != APPLE_AGX_METAL_ALLOCATION_PRIVATE) {
      cpu_mapping = [buffer contents];
      if (!cpu_mapping) {
         [buffer release];
         return false;
      }
   }

   *out_allocation = (struct AppleAGXMetalAllocation){
      .metal_buffer = buffer,
      .cpu_mapping = cpu_mapping,
      .gpu_va = gpu_va,
      .size = size,
      .storage = storage,
   };
   return true;
}

bool
AppleAGXMetalAllocationIsCurrent(
   const struct AppleAGXMetalAllocation *allocation)
{
   if (!allocation || !allocation->metal_buffer || allocation->gpu_va == 0 ||
       allocation->size == 0 ||
       [(id<MTLBuffer>)allocation->metal_buffer length] != allocation->size) {
      return false;
   }

   switch (allocation->storage) {
   case APPLE_AGX_METAL_ALLOCATION_SHARED:
   case APPLE_AGX_METAL_ALLOCATION_WRITE_COMBINED:
      if (!allocation->cpu_mapping)
         return false;
      break;
   case APPLE_AGX_METAL_ALLOCATION_PRIVATE:
      if (allocation->cpu_mapping)
         return false;
      break;
   default:
      return false;
   }

   return [(id<MTLBuffer>)allocation->metal_buffer gpuAddress] ==
          allocation->gpu_va;
}

void
AppleAGXMetalAllocationDestroy(struct AppleAGXMetalAllocation *allocation)
{
   if (!allocation)
      return;

   if (allocation->metal_buffer)
      [(id)allocation->metal_buffer release];
   *allocation = (struct AppleAGXMetalAllocation){0};
}
