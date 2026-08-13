/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXConfiguredCarrier.h"
#include "AppleAGXMetalBOProvider.h"
#include "AppleAGXNativeBridge.h"
#include "asahi/lib/agx_bo.h"
#include "asahi/lib/agx_macos_bo.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77

int
main(int argc, char **argv)
{
   struct agx_macos_device_session session = {0};
   struct agx_macos_bo_set bo_set = {0};
   struct AppleAGXNativeBridge bridge = {0};
   struct AppleAGXMetalBOProvider provider = {0};
   struct AppleAGXConfiguredCarrier carrier = {0};
   struct AppleAGXMetalResourceRef resource = {0};
   struct agx_device device = {0};
   const struct agx_macos_mesa_bo_provider *mesa_provider = NULL;
   struct agx_bo *bo = NULL;
   const void *binding = NULL;
   int status = 1;

   if (argc != 1 ||
       agx_macos_device_session_open(&session) !=
          AGX_MACOS_DEVICE_SESSION_READY ||
       agx_macos_device_session_configure_traced_api(&session, argv[0]) !=
          KERN_SUCCESS ||
       !AppleAGXNativeBridgeOpen(&bridge, &session) ||
       !AppleAGXMetalBOProviderInit(&provider, &bridge, &session) ||
       agx_macos_bo_set_init(&bo_set, &session) != KERN_SUCCESS ||
       !agx_macos_mesa_device_init(&device, &session, &bo_set, NULL) ||
       !agx_macos_mesa_device_attach_bo_provider(
          &device, AppleAGXMetalBOProviderMesaProvider(&provider)) ||
       !AppleAGXConfiguredCarrierCreate(&bridge, &carrier)) {
      status = AO46_SKIP_UNSUPPORTED_PROFILE;
      goto out;
   }

   mesa_provider = AppleAGXMetalBOProviderMesaProvider(&provider);
   if (!mesa_provider ||
       mesa_provider->capabilities != AGX_MACOS_MESA_PLATFORM_BO_CAP_CPU_MAPPABLE) {
      fputs("AO46_AGX_MESA_BO_CARRIER_BINDING provider exposed shader BO capability\n",
            stderr);
      goto out;
   }

   bo = device.ops.bo_alloc(&device, 65536, 0, AGX_BO_WRITEBACK);
   if (!bo || !bo->va || !bo->_map || bo->size != 65536 ||
       !AppleAGXMetalBOProviderReadMesaBOResource(&provider, &device, bo,
                                                   &resource) ||
       !agx_macos_mesa_bo_get_carrier_resource_binding(&device, bo, &binding) ||
       binding != resource.resource_list_binding ||
       bo->va->addr != resource.gpu_va ||
       !AppleAGXConfiguredCarrierAddMetalResource(&carrier, &resource)) {
      fputs("Apple AGX Mesa BO carrier binding smoke failed\n", stderr);
      goto out;
   }

   ((unsigned char *)bo->_map)[0] = 0x46;
   ((unsigned char *)bo->_map)[bo->size - 1] = 0xa0;
   if (((unsigned char *)bo->_map)[0] != 0x46 ||
       ((unsigned char *)bo->_map)[bo->size - 1] != 0xa0) {
      fputs("Apple AGX Mesa BO mapping was not retained\n", stderr);
      goto out;
   }

   printf("AO46_AGX_MESA_BO_CARRIER_BINDING mesa_handle=%u gpu_va=%#llx "
          "binding=%p bytes=%zu\n", bo->handle,
          (unsigned long long)bo->va->addr, binding, bo->size);
   status = 0;

out:
   if (bo)
      agx_bo_unreference(&device, bo);
   AppleAGXConfiguredCarrierDestroy(&carrier);
   if (!agx_macos_mesa_device_destroy(&device) && status == 0)
      status = 1;
   if (bo_set.initialized && agx_macos_bo_set_cleanup(&bo_set) != KERN_SUCCESS &&
       status == 0) {
      status = 1;
   }
   AppleAGXMetalBOProviderDestroy(&provider);
   AppleAGXNativeBridgeClose(&bridge);
   agx_macos_device_session_close(&session);
   return status;
}
