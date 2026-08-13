/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXConfiguredCarrier.h"
#include "AppleAGXNativeBridge.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(void)
{
   struct agx_macos_device_session session = {0};
   struct AppleAGXNativeBridge bridge = {0};
   struct AppleAGXConfiguredCarrier carrier = {0};
   struct AppleAGXOpaqueCarrierSnapshot snapshot = {0};
   struct AppleAGXConfiguredCarrierKernelCommands commands = {0};

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXNativeBridgeHasObservedCarrierPool(&bridge, &session)) {
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXConfiguredCarrierCreate(&bridge, &carrier) ||
       !AppleAGXConfiguredCarrierIsCurrent(&carrier) ||
       !AppleAGXConfiguredCarrierSnapshotRead(&carrier, &snapshot) ||
       !AppleAGXConfiguredCarrierKernelCommandsRead(&carrier, &commands) ||
       snapshot.resource_slot_count != 44 ||
       snapshot.initialized_slot_count != snapshot.resource_slot_count ||
       !commands.start || !commands.current || !commands.end) {
      fputs("Apple AGX configured carrier creation failed\n", stderr);
      AppleAGXConfiguredCarrierDestroy(&carrier);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   printf("Apple AGX configured carrier smoke: storage=%p slots=%u "
          "kernel=[%p..%p..%p] cursor_delta=%td\n",
          carrier.storage, snapshot.resource_slot_count,
          commands.start, commands.current, commands.end,
          (char *)commands.current - (char *)commands.start);

   AppleAGXConfiguredCarrierDestroy(&carrier);
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);
   return 0;
}
