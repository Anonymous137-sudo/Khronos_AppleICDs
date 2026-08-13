/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct agx_macos_device_session;

/* This profile-specific constructor boundary is observed from public Metal
 * allocations and read-only IOGPU disassembly. It does not make the private
 * API admissible: AO46 has no record-construction policy or call helper yet. */
struct AppleAGXNativeResourceRecord {
   uint8_t bytes[0x68];
};

_Static_assert(sizeof(struct AppleAGXNativeResourceRecord) == 0x68,
               "observed IOGPU resource record size");

typedef const void *(*AppleAGXNativeResourceCreateFn)(
   const void *device_ref, const struct AppleAGXNativeResourceRecord *record,
   size_t record_size);
typedef uint64_t (*AppleAGXNativeResourceGetGPUVirtualAddressFn)(
   const void *resource);
typedef uint64_t (*AppleAGXNativeResourceGetGPUVirtualAddressLengthFn)(
   const void *resource);
typedef const void *(*AppleAGXNativeResourceGetDataBytesFn)(const void *resource);
typedef uint64_t (*AppleAGXNativeResourceGetDataSizeFn)(const void *resource);
typedef uint64_t (*AppleAGXNativeResourceGetResidentDataSizeFn)(
   const void *resource);
typedef void (*AppleAGXNativeResourceReleaseFn)(const void *resource);

/*
 * Private lifetime root for Apple's generic IOGPU C API. The Metal device is
 * retained solely to obtain the opaque deviceRef object used by the generic
 * API. AO46 does not create Metal encoders, command buffers, or submissions.
 */
struct AppleAGXNativeBridge {
   void *metal_device;
   const void *device_ref;
   void *iogpu_image;
   const void *command_buffer_storage_pool;
   ptrdiff_t command_buffer_storage_pool_offset;

   void *device_create;
   void *device_get_next_global_trace_id;
   void *command_queue_create;
   void *command_queue_get_connect;
   void *command_queue_get_id;
   void *command_queue_release;
   void *command_queue_submit_command_buffers;
   void *command_buffer_storage_pool_create_storage;
   void *command_buffer_storage_create_ext;
   void *command_buffer_storage_dealloc;
   void *command_buffer_storage_begin_segment;
   void *command_buffer_storage_end_segment;
   void *resource_list_add_resource;
   void *resource_create;
   void *resource_get_gpu_virtual_address;
   void *resource_get_gpu_virtual_address_length;
   void *resource_get_data_bytes;
   void *resource_get_data_size;
   void *resource_get_resident_data_size;
   void *resource_release;
};

/* Opens the bounded Apple-native bridge for the single trace-validated AGX
 * profile. out_bridge must be zero-initialized. Resolving symbols is
 * deliberately separate from invoking them: no resource, queue, or submit ABI
 * is called until its inputs are proven. */
bool AppleAGXNativeBridgeOpen(
   struct AppleAGXNativeBridge *out_bridge,
   const struct agx_macos_device_session *session);
bool AppleAGXNativeBridgeIsCurrent(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
/* Returns only whether the observed symbols and generic device root are
 * present. This includes read-only resource accessors but is not permission to
 * invoke a private constructor, accessor, or mapping operation. */
bool AppleAGXNativeBridgeHasObservedResourceContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
/* Confirms the profile's Apple-owned storage pool and factory entry point.
 * This is read-only discovery only: AO46 does not call the factory or modify
 * the pool until the full carrier lifecycle is recovered. */
bool AppleAGXNativeBridgeHasObservedCarrierPool(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
/* Confirms the exact storage-level segment symbols seen in the active profile.
 * This is only a profile gate; callers must still use the Apple-created
 * storage and command range exposed by AppleAGXConfiguredCarrier. */
bool AppleAGXNativeBridgeHasObservedSegmentContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
/* Confirms the storage segment and resource-list admission symbols observed
 * together in the active carrier profile. */
bool AppleAGXNativeBridgeHasObservedResourceListBindingContract(
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
void AppleAGXNativeBridgeClose(struct AppleAGXNativeBridge *bridge);
