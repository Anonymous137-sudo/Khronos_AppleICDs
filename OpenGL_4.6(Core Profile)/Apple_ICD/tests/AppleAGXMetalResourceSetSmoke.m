/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXMetalResourceSet.h"
#include "AppleAGXNativeBridge.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>
#include <string.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(void)
{
   struct agx_macos_device_session session = {0};
   struct AppleAGXNativeBridge bridge = {0};
   struct AppleAGXMetalResourceSet set = {0};
   struct AppleAGXMetalResourceLease lease = {0};
   struct AppleAGXMetalResourceLease stale_lease = {0};
   uint32_t record_index;
   uint32_t source_index;
   uint32_t destination_index;
   const struct AppleAGXMetalResourceRange blit_producer_record_range = {
      .allocation_index = 0,
      .offset = 0,
      .size = 0x10,
   };
   const struct AppleAGXMetalResourceRange blit_consumer_record_range = {
      .allocation_index = 0,
      .offset = 0,
      .size = 0x30,
   };
   const struct AppleAGXMetalResourceRange compute_record_range = {
      .allocation_index = 0,
      .offset = 0,
      .size = 0x1bb0,
   };
   struct AppleAGXMetalResourceRange blit_producer_ranges[2] = {
      {.allocation_index = 1, .offset = 0, .size = 0x1000},
      {.allocation_index = 2, .offset = 0x1000, .size = 0x1000},
   };
   const struct AppleAGXMetalResourceRange blit_consumer_ranges[4] = {
      {.allocation_index = 1, .offset = 0x1000, .size = 0x1000},
      {.allocation_index = 2, .offset = 0x2000, .size = 0x1000},
      {.allocation_index = 1, .offset = 0x3000, .size = 0x1000},
      {.allocation_index = 2, .offset = 0x4000, .size = 0x1000},
   };
   const struct AppleAGXMetalResourceRange compute_ranges[2] = {
      {.allocation_index = 1, .offset = 0x4000, .size = 0x1000},
      {.allocation_index = 2, .offset = 0x5000, .size = 0x1000},
   };
   uint64_t encoded_source;
   uint64_t encoded_destination;
   uint64_t encoded_compute_input;
   uint64_t encoded_compute_output;
   uint64_t encoded_consumer[4];
   uint8_t before[0x10];
   int passed = 0;

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }
   if (!AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXMetalResourceSetInit(&set) ||
       AppleAGXMetalResourceSetAdd(&set, &bridge, 65536,
                                   APPLE_AGX_METAL_ALLOCATION_SHARED,
                                   &record_index) != KERN_SUCCESS ||
       AppleAGXMetalResourceSetAdd(&set, &bridge, 65536,
                                   APPLE_AGX_METAL_ALLOCATION_PRIVATE,
                                   &source_index) != KERN_SUCCESS ||
       AppleAGXMetalResourceSetAdd(&set, &bridge, 65536,
                                   APPLE_AGX_METAL_ALLOCATION_SHARED,
                                   &destination_index) != KERN_SUCCESS ||
       record_index != blit_producer_record_range.allocation_index ||
       source_index != blit_producer_ranges[0].allocation_index ||
       destination_index != blit_producer_ranges[1].allocation_index ||
       !AppleAGXMetalResourceSetIsCurrent(&set)) {
      fputs("Apple AGX public resource set setup failed\n", stderr);
      goto out;
   }

   memset(set.entries[record_index].allocation.cpu_mapping, 0xcd,
          compute_record_range.size);
   memcpy(before, set.entries[record_index].allocation.cpu_mapping,
          sizeof(before));
   blit_producer_ranges[1].offset = 65536;
   if (AppleAGXMetalResourceSetEncodeRecordAndRetain(
          &set, &blit_producer_record_range,
          AGX_MACOS_RESOURCE_RECORD_BLIT_PRODUCER, blit_producer_ranges, 2,
          &lease) != kIOReturnBadArgument || lease.active ||
       memcmp(before, set.entries[record_index].allocation.cpu_mapping,
              sizeof(before)) != 0) {
      fputs("Apple AGX public resource set accepted invalid range\n", stderr);
      goto out;
   }

   blit_producer_ranges[1].offset = 0x1000;
   if (AppleAGXMetalResourceSetEncodeRecordAndRetain(
          &set, &blit_producer_record_range,
          AGX_MACOS_RESOURCE_RECORD_BLIT_PRODUCER, blit_producer_ranges, 2,
          &lease) != KERN_SUCCESS ||
       !AppleAGXMetalResourceLeaseIsCurrent(&lease) ||
       AppleAGXMetalResourceSetDestroy(&set) != kIOReturnBusy) {
      fputs("Apple AGX public resource set did not retain record resources\n",
            stderr);
      goto out;
   }

   memcpy(&encoded_source, set.entries[record_index].allocation.cpu_mapping,
          sizeof(encoded_source));
   memcpy(&encoded_destination,
          (uint8_t *)set.entries[record_index].allocation.cpu_mapping + 0x8,
          sizeof(encoded_destination));
   if (encoded_source != set.entries[source_index].allocation.gpu_va ||
       encoded_destination != set.entries[destination_index].allocation.gpu_va +
                                 blit_producer_ranges[1].offset) {
      fputs("Apple AGX public resource set encoded unexpected GPU addresses\n",
            stderr);
      goto out;
   }

   stale_lease = lease;
   if (AppleAGXMetalResourceLeaseRelease(&lease) != KERN_SUCCESS || lease.active ||
       AppleAGXMetalResourceLeaseRelease(&stale_lease) != kIOReturnBadArgument) {
      fputs("Apple AGX public resource set record ownership failed\n", stderr);
      goto out;
   }

   if (AppleAGXMetalResourceSetEncodeRecordAndRetain(
          &set, &compute_record_range, AGX_MACOS_RESOURCE_RECORD_COMPUTE,
          compute_ranges, 2, &lease) != KERN_SUCCESS) {
      fputs("Apple AGX public resource set did not encode compute bindings\n",
            stderr);
      goto out;
   }
   memcpy(&encoded_compute_input,
          (uint8_t *)set.entries[record_index].allocation.cpu_mapping + 0x1ba0,
          sizeof(encoded_compute_input));
   memcpy(&encoded_compute_output,
          (uint8_t *)set.entries[record_index].allocation.cpu_mapping + 0x1ba8,
          sizeof(encoded_compute_output));
   if (encoded_compute_input !=
          set.entries[source_index].allocation.gpu_va + compute_ranges[0].offset ||
       encoded_compute_output !=
          set.entries[destination_index].allocation.gpu_va +
             compute_ranges[1].offset ||
       AppleAGXMetalResourceLeaseRelease(&lease) != KERN_SUCCESS) {
      fputs("Apple AGX public resource set encoded unexpected compute addresses\n",
            stderr);
      goto out;
   }

   if (AppleAGXMetalResourceSetEncodeRecordAndRetain(
          &set, &blit_consumer_record_range,
          AGX_MACOS_RESOURCE_RECORD_BLIT_CONSUMER, blit_consumer_ranges, 4,
          &lease) != KERN_SUCCESS) {
      fputs("Apple AGX public resource set did not encode blit-consumer bindings\n",
            stderr);
      goto out;
   }
   memcpy(encoded_consumer, set.entries[record_index].allocation.cpu_mapping,
          2 * sizeof(encoded_consumer[0]));
   memcpy(encoded_consumer + 2,
          (uint8_t *)set.entries[record_index].allocation.cpu_mapping + 0x20,
          2 * sizeof(encoded_consumer[0]));
   if (encoded_consumer[0] !=
          set.entries[source_index].allocation.gpu_va +
             blit_consumer_ranges[0].offset ||
       encoded_consumer[1] !=
          set.entries[destination_index].allocation.gpu_va +
             blit_consumer_ranges[1].offset ||
       encoded_consumer[2] !=
          set.entries[source_index].allocation.gpu_va +
             blit_consumer_ranges[2].offset ||
       encoded_consumer[3] !=
          set.entries[destination_index].allocation.gpu_va +
             blit_consumer_ranges[3].offset ||
       AppleAGXMetalResourceLeaseRelease(&lease) != KERN_SUCCESS ||
       AppleAGXMetalResourceSetDestroy(&set) != KERN_SUCCESS) {
      fputs("Apple AGX public resource set encoded unexpected blit-consumer addresses\n",
            stderr);
      goto out;
   }

   printf("AO46_APPLE_AGX_PUBLIC_RESOURCE_SET record_layouts=3 "
          "source_gpu_va=%#018llx destination_gpu_va=%#018llx\n",
          (unsigned long long)encoded_source,
          (unsigned long long)encoded_destination);
   passed = 1;

out:
   if (lease.active)
      (void)AppleAGXMetalResourceLeaseRelease(&lease);
   if (set.initialized)
      (void)AppleAGXMetalResourceSetDestroy(&set);
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);
   return passed ? 0 : 1;
}
