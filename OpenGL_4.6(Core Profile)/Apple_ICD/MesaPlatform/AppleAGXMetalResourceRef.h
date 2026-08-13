/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

struct AppleAGXNativeBridge;

/* Borrowed view of the generic resource owned by an IOGPUMetalBuffer. The
 * MTLBuffer remains the lifetime root; AO46 neither retains nor releases the
 * generic resource pointer. */
struct AppleAGXMetalResourceRef {
   const struct AppleAGXNativeBridge *bridge;
   void *metal_buffer;
   const void *resource_ref;
   const void *resource_list_binding;
   uint64_t gpu_va;
   uint64_t gpu_va_length;
};

/* Reads the profiled inherited resourceRef accessor and validates it against
 * public MTLBuffer address/length reporting. The returned list binding is the
 * profiled `IOGPUMetalBuffer + 0x40` borrowed view observed as input to
 * IOGPUResourceListAddResource. This is a wrapper-identification step only,
 * not an allocation, resource-binding, or submission interface. */
bool AppleAGXMetalResourceRefRead(
   const struct AppleAGXNativeBridge *bridge, void *metal_buffer,
   struct AppleAGXMetalResourceRef *out_ref);
bool AppleAGXMetalResourceRefIsCurrent(
   const struct AppleAGXMetalResourceRef *ref);
