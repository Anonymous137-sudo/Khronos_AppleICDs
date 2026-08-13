/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXMetalAllocation.h"
#include "AppleAGXNativeBridge.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(void)
{
   struct agx_macos_device_session session = {0};
   struct AppleAGXNativeBridge bridge = {0};
   struct AppleAGXMetalAllocation shared = {0};
   struct AppleAGXMetalAllocation private_allocation = {0};
   int passed = 0;

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session)) {
      fputs("Apple AGX public allocation smoke could not open device root\n",
            stderr);
      goto out;
   }

   if (!AppleAGXMetalAllocationCreate(&bridge, 65536,
                                       APPLE_AGX_METAL_ALLOCATION_SHARED,
                                       &shared) ||
       !AppleAGXMetalAllocationCreate(&bridge, 65536,
                                       APPLE_AGX_METAL_ALLOCATION_PRIVATE,
                                       &private_allocation) ||
       !AppleAGXMetalAllocationIsCurrent(&shared) ||
       !AppleAGXMetalAllocationIsCurrent(&private_allocation) ||
       !shared.cpu_mapping || private_allocation.cpu_mapping) {
      fputs("Apple AGX public allocation contract was unexpected\n", stderr);
      goto out;
   }

   ((unsigned char *)shared.cpu_mapping)[0] = 0x46;
   ((unsigned char *)shared.cpu_mapping)[shared.size - 1] = 0xa0;
   printf("AO46_APPLE_AGX_PUBLIC_ALLOCATION shared_gpu_va=%#018llx "
          "private_gpu_va=%#018llx shared_cpu_mapping=1 "
          "private_cpu_mapping=0 bytes=%llu\n",
          (unsigned long long)shared.gpu_va,
          (unsigned long long)private_allocation.gpu_va,
          (unsigned long long)shared.size);
   passed = 1;

out:
   AppleAGXMetalAllocationDestroy(&private_allocation);
   AppleAGXMetalAllocationDestroy(&shared);
   if (AppleAGXMetalAllocationIsCurrent(&shared) ||
       AppleAGXMetalAllocationIsCurrent(&private_allocation)) {
      fputs("Apple AGX public allocation survived teardown\n", stderr);
      passed = 0;
   }
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);
   return passed ? 0 : 1;
}
