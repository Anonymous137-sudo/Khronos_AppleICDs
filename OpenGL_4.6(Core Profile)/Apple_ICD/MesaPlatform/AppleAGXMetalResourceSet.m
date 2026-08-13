/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXMetalResourceSet.h"
#include "AppleAGXNativeBridge.h"

#include <string.h>

static bool
apple_agx_metal_resource_set_is_current_locked(
   const struct AppleAGXMetalResourceSet *set)
{
   if (!set || !set->initialized || set->finalizing ||
       set->allocation_count > APPLE_AGX_METAL_RESOURCE_SET_CAPACITY ||
       set->next_lease_id == 0) {
      return false;
   }

   for (uint32_t i = 0; i < set->allocation_count; ++i) {
      if (!AppleAGXMetalAllocationIsCurrent(&set->entries[i].allocation))
         return false;
   }

   return true;
}

static struct AppleAGXMetalResourceLeaseRecord *
apple_agx_metal_resource_set_find_lease_locked(
   struct AppleAGXMetalResourceSet *set, uint64_t id)
{
   if (!set || id == 0)
      return NULL;

   for (uint32_t i = 0; i < APPLE_AGX_METAL_RESOURCE_SET_MAX_LEASES; ++i) {
      if (set->leases[i].active && set->leases[i].id == id)
         return &set->leases[i];
   }

   return NULL;
}

static bool
apple_agx_metal_resource_set_resolve_range_locked(
   const struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXMetalResourceRange *range, bool require_cpu_mapping,
   uint64_t *out_gpu_va, uint8_t **out_cpu)
{
   const struct AppleAGXMetalAllocation *allocation;

   if (!apple_agx_metal_resource_set_is_current_locked(set) || !range ||
       range->allocation_index >= set->allocation_count || range->size == 0) {
      return false;
   }

   allocation = &set->entries[range->allocation_index].allocation;
   if (range->offset > allocation->size ||
       range->size > allocation->size - range->offset ||
       range->offset > UINT64_MAX - allocation->gpu_va ||
       (require_cpu_mapping && !allocation->cpu_mapping)) {
      return false;
   }

   if (out_gpu_va)
      *out_gpu_va = allocation->gpu_va + range->offset;
   if (out_cpu)
      *out_cpu = (uint8_t *)allocation->cpu_mapping + range->offset;
   return true;
}

static bool
apple_agx_metal_resource_set_owns_gpu_range(void *context, uint64_t gpu_va,
                                             uint64_t size)
{
   struct AppleAGXMetalResourceSet *set = context;
   bool owns = false;

   if (!set || size == 0 || gpu_va > UINT64_MAX - size)
      return false;

   pthread_mutex_lock(&set->lock);
   if (apple_agx_metal_resource_set_is_current_locked(set)) {
      for (uint32_t i = 0; i < set->allocation_count; ++i) {
         const struct AppleAGXMetalAllocation *allocation =
            &set->entries[i].allocation;
         uint64_t allocation_end = allocation->gpu_va + allocation->size;

         if (allocation_end >= allocation->gpu_va &&
             gpu_va >= allocation->gpu_va && gpu_va + size <= allocation_end) {
            owns = true;
            break;
         }
      }
   }
   pthread_mutex_unlock(&set->lock);
   return owns;
}

static kern_return_t
apple_agx_metal_resource_set_acquire_locked(
   struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXMetalResourceRange *record_range,
   const struct AppleAGXMetalResourceRange *resource_ranges,
   uint32_t resource_range_count, struct AppleAGXMetalResourceLease *out_lease,
   uint8_t **out_record, uint64_t *out_record_size,
   struct agx_macos_resource_binding *out_bindings)
{
   struct AppleAGXMetalResourceLeaseRecord *lease_record = NULL;
   uint32_t allocation_indices[APPLE_AGX_METAL_RESOURCE_LEASE_MAX_ENTRIES];
   uint32_t allocation_count = 0;
   uint64_t unused_gpu_va;

   if (!apple_agx_metal_resource_set_is_current_locked(set) || !record_range ||
       !resource_ranges || !out_lease || out_lease->active || !out_record ||
       !out_record_size || !out_bindings ||
       resource_range_count > AGX_MACOS_RESOURCE_RECORD_MAX_BINDINGS ||
       !apple_agx_metal_resource_set_resolve_range_locked(
          set, record_range, true, &unused_gpu_va, out_record)) {
      return kIOReturnBadArgument;
   }

   allocation_indices[allocation_count++] = record_range->allocation_index;
   for (uint32_t i = 0; i < resource_range_count; ++i) {
      bool duplicate = false;

      if (!apple_agx_metal_resource_set_resolve_range_locked(
             set, &resource_ranges[i], false, &out_bindings[i].gpu_va, NULL)) {
         return kIOReturnBadArgument;
      }
      out_bindings[i].byte_size = resource_ranges[i].size;

      for (uint32_t j = 0; j < allocation_count; ++j)
         duplicate |= allocation_indices[j] == resource_ranges[i].allocation_index;
      if (!duplicate)
         allocation_indices[allocation_count++] = resource_ranges[i].allocation_index;
   }

   for (uint32_t i = 0; i < APPLE_AGX_METAL_RESOURCE_SET_MAX_LEASES; ++i) {
      if (!set->leases[i].active) {
         lease_record = &set->leases[i];
         break;
      }
   }
   if (!lease_record || set->next_lease_id == UINT64_MAX)
      return kIOReturnNoResources;

   for (uint32_t i = 0; i < allocation_count; ++i)
      set->entries[allocation_indices[i]].lease_count++;

   *lease_record = (struct AppleAGXMetalResourceLeaseRecord){
      .id = set->next_lease_id++,
      .allocation_count = allocation_count,
      .active = true,
   };
   memcpy(lease_record->allocation_indices, allocation_indices,
          allocation_count * sizeof(allocation_indices[0]));
   *out_lease = (struct AppleAGXMetalResourceLease){
      .set = set,
      .id = lease_record->id,
      .active = true,
   };
   *out_record_size = record_range->size;
   return KERN_SUCCESS;
}

bool
AppleAGXMetalResourceSetInit(struct AppleAGXMetalResourceSet *set)
{
   if (!set)
      return false;

   *set = (struct AppleAGXMetalResourceSet){
      .next_lease_id = 1,
   };
   if (pthread_mutex_init(&set->lock, NULL) != 0)
      return false;

   set->initialized = true;
   return true;
}

kern_return_t
AppleAGXMetalResourceSetAdd(
   struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXNativeBridge *bridge, uint64_t size,
   enum AppleAGXMetalAllocationStorage storage, uint32_t *out_allocation_index)
{
   uint32_t index;

   if (!set || !out_allocation_index)
      return kIOReturnBadArgument;

   pthread_mutex_lock(&set->lock);
   if (!apple_agx_metal_resource_set_is_current_locked(set) ||
       set->allocation_count == APPLE_AGX_METAL_RESOURCE_SET_CAPACITY) {
      pthread_mutex_unlock(&set->lock);
      return kIOReturnNoResources;
   }

   index = set->allocation_count;
   if (!AppleAGXMetalAllocationCreate(bridge, size, storage,
                                       &set->entries[index].allocation)) {
      pthread_mutex_unlock(&set->lock);
      return kIOReturnNoMemory;
   }

   set->allocation_count++;
   *out_allocation_index = index;
   pthread_mutex_unlock(&set->lock);
   return KERN_SUCCESS;
}

bool
AppleAGXMetalResourceSetIsCurrent(const struct AppleAGXMetalResourceSet *set)
{
   bool current;

   if (!set)
      return false;

   pthread_mutex_lock((pthread_mutex_t *)&set->lock);
   current = apple_agx_metal_resource_set_is_current_locked(set);
   pthread_mutex_unlock((pthread_mutex_t *)&set->lock);
   return current;
}

kern_return_t
AppleAGXMetalResourceSetEncodeRecordAndRetain(
   struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXMetalResourceRange *record_range,
   enum agx_macos_resource_record_kind kind,
   const struct AppleAGXMetalResourceRange *resource_ranges,
   uint32_t resource_range_count,
   struct AppleAGXMetalResourceLease *out_lease)
{
   struct agx_macos_resource_record_layout layout;
   struct agx_macos_resource_binding
      bindings[AGX_MACOS_RESOURCE_RECORD_MAX_BINDINGS] = {0};
   uint8_t *record;
   uint64_t record_size;
   kern_return_t result;

   if (!set || !out_lease || out_lease->active ||
       !agx_macos_resource_record_layout_get(kind, &layout) ||
       resource_range_count != layout.binding_count) {
      return kIOReturnBadArgument;
   }

   pthread_mutex_lock(&set->lock);
   result = apple_agx_metal_resource_set_acquire_locked(
      set, record_range, resource_ranges, resource_range_count, out_lease,
      &record, &record_size, bindings);
   pthread_mutex_unlock(&set->lock);
   if (result != KERN_SUCCESS)
      return result;

   result = agx_macos_resource_record_encode(
      record, record_size, kind, bindings, resource_range_count,
      apple_agx_metal_resource_set_owns_gpu_range, set);
   if (result != KERN_SUCCESS)
      (void)AppleAGXMetalResourceLeaseRelease(out_lease);
   return result;
}

bool
AppleAGXMetalResourceLeaseIsCurrent(
   const struct AppleAGXMetalResourceLease *lease)
{
   struct AppleAGXMetalResourceSet *set;
   bool current;

   if (!lease || !lease->active || !lease->set || lease->id == 0)
      return false;

   set = lease->set;
   pthread_mutex_lock(&set->lock);
   current = apple_agx_metal_resource_set_is_current_locked(set) &&
      apple_agx_metal_resource_set_find_lease_locked(set, lease->id) != NULL;
   pthread_mutex_unlock(&set->lock);
   return current;
}

kern_return_t
AppleAGXMetalResourceLeaseRelease(struct AppleAGXMetalResourceLease *lease)
{
   struct AppleAGXMetalResourceSet *set;
   struct AppleAGXMetalResourceLeaseRecord *lease_record;

   if (!lease || !lease->active || !lease->set || lease->id == 0)
      return kIOReturnBadArgument;

   set = lease->set;
   pthread_mutex_lock(&set->lock);
   lease_record = apple_agx_metal_resource_set_find_lease_locked(set, lease->id);
   if (!lease_record) {
      pthread_mutex_unlock(&set->lock);
      return kIOReturnBadArgument;
   }

   for (uint32_t i = 0; i < lease_record->allocation_count; ++i) {
      struct AppleAGXMetalResourceSetEntry *entry =
         &set->entries[lease_record->allocation_indices[i]];

      if (entry->lease_count == 0) {
         pthread_mutex_unlock(&set->lock);
         return kIOReturnBadArgument;
      }
      entry->lease_count--;
   }
   *lease_record = (struct AppleAGXMetalResourceLeaseRecord){0};
   pthread_mutex_unlock(&set->lock);
   *lease = (struct AppleAGXMetalResourceLease){0};
   return KERN_SUCCESS;
}

kern_return_t
AppleAGXMetalResourceSetDestroy(struct AppleAGXMetalResourceSet *set)
{
   if (!set || !set->initialized)
      return kIOReturnBadArgument;

   pthread_mutex_lock(&set->lock);
   if (set->finalizing) {
      pthread_mutex_unlock(&set->lock);
      return kIOReturnBusy;
   }

   for (uint32_t i = 0; i < set->allocation_count; ++i) {
      if (set->entries[i].lease_count != 0) {
         pthread_mutex_unlock(&set->lock);
         return kIOReturnBusy;
      }
   }
   for (uint32_t i = 0; i < APPLE_AGX_METAL_RESOURCE_SET_MAX_LEASES; ++i) {
      if (set->leases[i].active) {
         pthread_mutex_unlock(&set->lock);
         return kIOReturnBusy;
      }
   }
   set->finalizing = true;
   pthread_mutex_unlock(&set->lock);

   for (uint32_t i = 0; i < set->allocation_count; ++i)
      AppleAGXMetalAllocationDestroy(&set->entries[i].allocation);
   pthread_mutex_destroy(&set->lock);
   *set = (struct AppleAGXMetalResourceSet){0};
   return KERN_SUCCESS;
}
