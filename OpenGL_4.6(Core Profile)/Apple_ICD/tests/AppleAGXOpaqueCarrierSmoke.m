/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXNativeBridge.h"
#include "AppleAGXOpaqueCarrier.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(void)
{
   struct agx_macos_device_session session = {0};
   struct AppleAGXNativeBridge bridge = {0};
   struct AppleAGXOpaqueCarrier carrier = {0};
   struct AppleAGXOpaqueCarrierSnapshot snapshot = {0};

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXNativeBridgeHasObservedCarrierPool(&bridge, &session)) {
      fputs("Apple AGX opaque carrier profile is unavailable\n", stderr);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXOpaqueCarrierCreate(&bridge, &carrier) ||
       !AppleAGXOpaqueCarrierIsCurrent(&carrier)) {
      fputs("Apple AGX opaque carrier creation failed\n", stderr);
      AppleAGXOpaqueCarrierDestroy(&carrier);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   if (!AppleAGXOpaqueCarrierSnapshotRead(&carrier, &snapshot) ||
       snapshot.resource_slot_count != 0 ||
       snapshot.initialized_slot_count != 0 || snapshot.resource_records ||
       snapshot.slot_descriptors) {
      fputs("Apple AGX opaque carrier was unexpectedly preconfigured\n", stderr);
      AppleAGXOpaqueCarrierDestroy(&carrier);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   printf("Apple AGX opaque carrier smoke: storage=%p trace=%llu slots=%u\n",
          carrier.storage, (unsigned long long)carrier.global_trace_id,
          snapshot.resource_slot_count);

   AppleAGXOpaqueCarrierDestroy(&carrier);
   if (AppleAGXOpaqueCarrierIsCurrent(&carrier)) {
      fputs("Apple AGX opaque carrier survived teardown\n", stderr);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);
   return 0;
}
