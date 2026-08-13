/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>

#include "AppleAGXConfiguredCarrier.h"
#include "AppleAGXMetalResourceRef.h"
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
   struct AppleAGXMetalResourceRef resource = {0};
   id<MTLBuffer> buffer = nil;
   bool passed = false;

   if (agx_macos_device_session_open(&session) !=
       AGX_MACOS_DEVICE_SESSION_READY) {
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXNativeBridgeHasObservedResourceListBindingContract(&bridge,
                                                                    &session) ||
       !AppleAGXConfiguredCarrierCreate(&bridge, &carrier)) {
      AppleAGXConfiguredCarrierDestroy(&carrier);
      AppleAGXNativeBridgeClose(&bridge);
      agx_macos_device_session_close(&session);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   buffer = [(id<MTLDevice>)bridge.metal_device
      newBufferWithLength:4096 options:MTLResourceStorageModeShared];
   passed = buffer && AppleAGXMetalResourceRefRead(&bridge, buffer, &resource) &&
      AppleAGXConfiguredCarrierAddMetalResource(&carrier, &resource);

   if (passed) {
      printf("Apple AGX carrier resource binding smoke: storage=%p binding=%p\n",
             carrier.storage, resource.resource_list_binding);
   }

   AppleAGXConfiguredCarrierDestroy(&carrier);
   if (buffer)
      [buffer release];
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);

   if (!passed) {
      fputs("Apple AGX carrier resource binding smoke failed\n", stderr);
      return 1;
   }

   return 0;
}
