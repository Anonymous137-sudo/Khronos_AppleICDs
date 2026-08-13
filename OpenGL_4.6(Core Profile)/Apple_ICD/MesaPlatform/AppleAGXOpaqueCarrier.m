/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXOpaqueCarrier.h"

#include "AppleAGXNativeBridge.h"

#include <string.h>

enum {
   apple_agx_carrier_records_offset = 0x300,
   apple_agx_carrier_slots_offset = 0x310,
   apple_agx_carrier_slot_count_offset = 0x318,
   apple_agx_carrier_max_slots = 64,
};

typedef uint64_t (*AppleAGXNativeNextTraceIdFn)(const void *device_ref);
typedef void *(*AppleAGXNativeCarrierCreateFn)(const void *pool,
                                                uint64_t global_trace_id,
                                                bool retained_references,
                                                bool synchronous_debug);
typedef void (*AppleAGXNativeCarrierDeallocFn)(void *storage);

bool
AppleAGXOpaqueCarrierIsCurrent(const struct AppleAGXOpaqueCarrier *carrier)
{
   return carrier && carrier->bridge && carrier->storage &&
          carrier->global_trace_id != 0 &&
          carrier->bridge->command_buffer_storage_pool &&
          carrier->bridge->command_buffer_storage_pool_create_storage &&
          carrier->bridge->command_buffer_storage_dealloc;
}

bool
AppleAGXOpaqueCarrierSnapshotRead(
   const struct AppleAGXOpaqueCarrier *carrier,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot)
{
   if (!AppleAGXOpaqueCarrierIsCurrent(carrier))
      return false;

   return AppleAGXOpaqueCarrierStorageSnapshotRead(carrier->storage,
                                                   out_snapshot);
}

bool
AppleAGXOpaqueCarrierStorageSnapshotRead(
   const void *storage,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot)
{
   const void *resource_records;
   const void *slot_descriptors;
   uint32_t resource_slot_count;
   uint32_t initialized_slot_count = 0;

   if (!storage || !out_snapshot)
      return false;

   /* The Apple factory initialized these fields. This only validates the
    * captured carrier shape and never writes a descriptor or record. */
   memcpy(&resource_records,
          (const unsigned char *)storage + apple_agx_carrier_records_offset,
          sizeof(resource_records));
   memcpy(&slot_descriptors,
          (const unsigned char *)storage + apple_agx_carrier_slots_offset,
          sizeof(slot_descriptors));
   memcpy(&resource_slot_count,
          (const unsigned char *)storage + apple_agx_carrier_slot_count_offset,
          sizeof(resource_slot_count));
   if (resource_slot_count > apple_agx_carrier_max_slots)
      return false;

   for (uint32_t i = 0;
        slot_descriptors && i < resource_slot_count;
        ++i) {
      const void *slot_descriptor = NULL;

      memcpy(&slot_descriptor,
             (const unsigned char *)slot_descriptors + i * sizeof(slot_descriptor),
             sizeof(slot_descriptor));
      if (slot_descriptor)
         ++initialized_slot_count;
   }

   *out_snapshot = (struct AppleAGXOpaqueCarrierSnapshot){
      .resource_records = resource_records,
      .slot_descriptors = slot_descriptors,
      .resource_slot_count = resource_slot_count,
      .initialized_slot_count = initialized_slot_count,
   };
   return true;
}

bool
AppleAGXOpaqueCarrierCreate(const struct AppleAGXNativeBridge *bridge,
                            struct AppleAGXOpaqueCarrier *out_carrier)
{
   AppleAGXNativeNextTraceIdFn next_trace_id;
   AppleAGXNativeCarrierCreateFn create_carrier;
   uint64_t global_trace_id;
   void *storage;

   if (!bridge || !out_carrier || out_carrier->bridge || out_carrier->storage ||
       !bridge->device_ref ||
       !bridge->command_buffer_storage_pool ||
       !bridge->device_get_next_global_trace_id ||
       !bridge->command_buffer_storage_pool_create_storage ||
       !bridge->command_buffer_storage_dealloc) {
      return false;
   }

   next_trace_id = (AppleAGXNativeNextTraceIdFn)
      bridge->device_get_next_global_trace_id;
   create_carrier = (AppleAGXNativeCarrierCreateFn)
      bridge->command_buffer_storage_pool_create_storage;
   global_trace_id = next_trace_id(bridge->device_ref);
   if (!global_trace_id)
      return false;

   /* This is the exact no-work factory shape captured from an Apple command
    * buffer. It allocates carrier storage only; no resource or queue API is
    * touched here. */
   storage = create_carrier(bridge->command_buffer_storage_pool, global_trace_id,
                            true, false);
   if (!storage)
      return false;

   *out_carrier = (struct AppleAGXOpaqueCarrier){
      .bridge = bridge,
      .storage = storage,
      .global_trace_id = global_trace_id,
   };
   return true;
}

void
AppleAGXOpaqueCarrierDestroy(struct AppleAGXOpaqueCarrier *carrier)
{
   AppleAGXNativeCarrierDeallocFn dealloc_carrier;

   if (!carrier)
      return;

   if (carrier->storage && carrier->bridge &&
       carrier->bridge->command_buffer_storage_dealloc) {
      dealloc_carrier = (AppleAGXNativeCarrierDeallocFn)
         carrier->bridge->command_buffer_storage_dealloc;
      dealloc_carrier(carrier->storage);
   }

   *carrier = (struct AppleAGXOpaqueCarrier){0};
}
