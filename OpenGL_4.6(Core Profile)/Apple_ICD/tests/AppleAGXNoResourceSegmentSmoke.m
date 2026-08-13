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
   bool passed = false;

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXNativeBridgeHasObservedSegmentContract(&bridge, &session) ||
       !AppleAGXConfiguredCarrierCreate(&bridge, &carrier)) {
      AppleAGXConfiguredCarrierDestroy(&carrier);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   passed = AppleAGXConfiguredCarrierNoResourceSegmentSmoke(&carrier);
   AppleAGXConfiguredCarrierDestroy(&carrier);
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);

   if (!passed) {
      fputs("Apple AGX no-resource segment smoke failed\n", stderr);
      return 1;
   }

   puts("Apple AGX no-resource segment smoke: begin/end completed");
   return 0;
}
