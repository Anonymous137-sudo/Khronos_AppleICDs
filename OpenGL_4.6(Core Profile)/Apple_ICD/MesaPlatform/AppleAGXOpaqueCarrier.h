/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

struct AppleAGXNativeBridge;

/* A profile-gated Apple-owned command carrier. It is intentionally limited to
 * construction and teardown while command/resource mutation contracts are
 * recovered. The bridge must outlive every active carrier. */
struct AppleAGXOpaqueCarrier {
   const struct AppleAGXNativeBridge *bridge;
   void *storage;
   uint64_t global_trace_id;
};

/* These are observations from the active profile's Apple-created storage,
 * copied out without exposing or mutating its private descriptors. A carrier
 * returned directly by the storage pool is expected to be unconfigured until
 * Apple's command-buffer initializer attaches its slot table. */
struct AppleAGXOpaqueCarrierSnapshot {
   const void *resource_records;
   const void *slot_descriptors;
   uint32_t resource_slot_count;
   uint32_t initialized_slot_count;
};

bool AppleAGXOpaqueCarrierCreate(
   const struct AppleAGXNativeBridge *bridge,
   struct AppleAGXOpaqueCarrier *out_carrier);
bool AppleAGXOpaqueCarrierIsCurrent(
   const struct AppleAGXOpaqueCarrier *carrier);
bool AppleAGXOpaqueCarrierStorageSnapshotRead(
   const void *storage,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot);
bool AppleAGXOpaqueCarrierSnapshotRead(
   const struct AppleAGXOpaqueCarrier *carrier,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot);
void AppleAGXOpaqueCarrierDestroy(struct AppleAGXOpaqueCarrier *carrier);
