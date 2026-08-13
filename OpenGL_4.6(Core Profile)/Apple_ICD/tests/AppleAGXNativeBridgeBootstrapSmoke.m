/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXNativeBridge.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(void)
{
   struct agx_macos_device_session session = {0};
   struct AppleAGXNativeBridge bridge = {0};

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session)) {
      fputs("Apple AGX native bridge bootstrap was rejected\n", stderr);
      agx_macos_device_session_close(&session);
      return 1;
   }

   if (!AppleAGXNativeBridgeIsCurrent(&bridge, &session)) {
      fputs("Apple AGX native bridge did not retain a valid device root\n",
            stderr);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   if (!AppleAGXNativeBridgeHasObservedResourceContract(&bridge, &session)) {
      fputs("Apple AGX native bridge did not retain the resource contract\n",
            stderr);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   if (!AppleAGXNativeBridgeHasObservedCarrierPool(&bridge, &session) ||
       bridge.command_buffer_storage_pool_offset <= 0) {
      fputs("Apple AGX native bridge did not retain the carrier pool\n", stderr);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return 1;
   }

   printf("Apple AGX native bridge bootstrap: device=%p resource=%p queue=%p "
          "carrier-pool=%p carrier-pool-offset=%td submit=%p\n",
          bridge.device_ref, bridge.resource_create, bridge.command_queue_create,
          bridge.command_buffer_storage_pool,
          bridge.command_buffer_storage_pool_offset,
          bridge.command_queue_submit_command_buffers);

   AppleAGXNativeBridgeClose(&bridge);
   if (AppleAGXNativeBridgeIsCurrent(&bridge, &session) ||
       AppleAGXNativeBridgeHasObservedResourceContract(&bridge, &session) ||
       AppleAGXNativeBridgeHasObservedCarrierPool(&bridge, &session)) {
      fputs("Apple AGX native bridge survived teardown\n", stderr);
      agx_macos_device_session_close(&session);
      return 1;
   }

   agx_macos_device_session_close(&session);
   return 0;
}
