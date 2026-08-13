/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

struct AppleAGXNativeBridge;

/* This is deliberately an allocation-only public-Metal boundary. An owned
 * MTLBuffer gives AO46 a supported allocation lifetime, CPU mapping where
 * public Metal permits it, and a public GPU virtual address. It does not
 * expose an IOGPU resource object or make a command submission admissible. */
enum AppleAGXMetalAllocationStorage {
   APPLE_AGX_METAL_ALLOCATION_SHARED = 0,
   APPLE_AGX_METAL_ALLOCATION_WRITE_COMBINED,
   APPLE_AGX_METAL_ALLOCATION_PRIVATE,
};

struct AppleAGXMetalAllocation {
   void *metal_buffer;
   void *cpu_mapping;
   uint64_t gpu_va;
   uint64_t size;
   enum AppleAGXMetalAllocationStorage storage;
};

/* Creates an Apple-owned allocation through the retained public Metal device.
 * out_allocation must be zero-initialized. The allocation owns its MTLBuffer
 * until AppleAGXMetalAllocationDestroy is called. */
bool AppleAGXMetalAllocationCreate(
   const struct AppleAGXNativeBridge *bridge, uint64_t size,
   enum AppleAGXMetalAllocationStorage storage,
   struct AppleAGXMetalAllocation *out_allocation);
bool AppleAGXMetalAllocationIsCurrent(
   const struct AppleAGXMetalAllocation *allocation);
void AppleAGXMetalAllocationDestroy(struct AppleAGXMetalAllocation *allocation);
