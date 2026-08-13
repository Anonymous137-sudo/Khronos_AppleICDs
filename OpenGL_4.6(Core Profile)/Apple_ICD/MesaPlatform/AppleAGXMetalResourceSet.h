/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

#include <mach/kern_return.h>

#include "AppleAGXMetalAllocation.h"
#include "asahi/lib/agx_macos_submission_build.h"

#define APPLE_AGX_METAL_RESOURCE_SET_CAPACITY 16
#define APPLE_AGX_METAL_RESOURCE_SET_MAX_LEASES 16
#define APPLE_AGX_METAL_RESOURCE_LEASE_MAX_ENTRIES \
   (AGX_MACOS_RESOURCE_RECORD_MAX_BINDINGS + 1)

struct AppleAGXMetalResourceRange {
   uint32_t allocation_index;
   uint64_t offset;
   uint64_t size;
};

struct AppleAGXMetalResourceSetEntry {
   struct AppleAGXMetalAllocation allocation;
   uint32_t lease_count;
};

struct AppleAGXMetalResourceLeaseRecord {
   uint64_t id;
   uint32_t allocation_indices[APPLE_AGX_METAL_RESOURCE_LEASE_MAX_ENTRIES];
   uint32_t allocation_count;
   bool active;
};

struct AppleAGXMetalResourceSet {
   pthread_mutex_t lock;
   struct AppleAGXMetalResourceSetEntry
      entries[APPLE_AGX_METAL_RESOURCE_SET_CAPACITY];
   struct AppleAGXMetalResourceLeaseRecord
      leases[APPLE_AGX_METAL_RESOURCE_SET_MAX_LEASES];
   uint32_t allocation_count;
   uint64_t next_lease_id;
   bool initialized;
   bool finalizing;
};

/* Leases are copy-safe capabilities. Release validates the ID against the set
 * record, so a copied or stale lease cannot release another allocation. */
struct AppleAGXMetalResourceLease {
   struct AppleAGXMetalResourceSet *set;
   uint64_t id;
   bool active;
};

bool AppleAGXMetalResourceSetInit(struct AppleAGXMetalResourceSet *set);
kern_return_t AppleAGXMetalResourceSetAdd(
   struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXNativeBridge *bridge, uint64_t size,
   enum AppleAGXMetalAllocationStorage storage, uint32_t *out_allocation_index);
bool AppleAGXMetalResourceSetIsCurrent(
   const struct AppleAGXMetalResourceSet *set);

/* Pins the record allocation and every resource allocation before encoding
 * one experimentally verified AGX resource-record layout. It has no sidecar
 * encoder and does not submit work. The caller releases out_lease only after
 * the future carrier/completion path no longer references these ranges. */
kern_return_t AppleAGXMetalResourceSetEncodeRecordAndRetain(
   struct AppleAGXMetalResourceSet *set,
   const struct AppleAGXMetalResourceRange *record_range,
   enum agx_macos_resource_record_kind kind,
   const struct AppleAGXMetalResourceRange *resource_ranges,
   uint32_t resource_range_count,
   struct AppleAGXMetalResourceLease *out_lease);
bool AppleAGXMetalResourceLeaseIsCurrent(
   const struct AppleAGXMetalResourceLease *lease);
kern_return_t AppleAGXMetalResourceLeaseRelease(
   struct AppleAGXMetalResourceLease *lease);

/* Destruction fails while a retained resource-record lease exists. */
kern_return_t AppleAGXMetalResourceSetDestroy(
   struct AppleAGXMetalResourceSet *set);
