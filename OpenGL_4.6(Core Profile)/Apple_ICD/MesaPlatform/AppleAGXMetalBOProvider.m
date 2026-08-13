/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleAGXMetalBOProvider.h"

#include "AppleAGXNativeBridge.h"

#include "asahi/compiler/agx_compile.h"

#include <stdlib.h>

struct AppleAGXMetalBOBacking {
   struct AppleAGXMetalAllocation allocation;
   struct AppleAGXMetalResourceRef resource;
};

static bool
apple_agx_metal_bo_backing_is_current(
   const struct AppleAGXMetalBOBacking *backing)
{
   return backing && AppleAGXMetalAllocationIsCurrent(&backing->allocation) &&
          AppleAGXMetalResourceRefIsCurrent(&backing->resource) &&
          backing->resource.metal_buffer == backing->allocation.metal_buffer &&
          backing->resource.gpu_va == backing->allocation.gpu_va &&
          backing->resource.gpu_va_length >= backing->allocation.size &&
          backing->resource.resource_list_binding != NULL;
}

static bool
apple_agx_metal_bo_provider_is_current(const void *context,
                                      const struct agx_macos_mesa_platform_bo *bo)
{
   const struct AppleAGXMetalBOProvider *provider = context;
   const struct AppleAGXMetalBOBacking *backing = bo ? bo->owner : NULL;

   return AppleAGXMetalBOProviderIsCurrent(provider) &&
          apple_agx_metal_bo_backing_is_current(backing) &&
          bo->cpu == backing->allocation.cpu_mapping &&
          bo->gpu_va == backing->allocation.gpu_va &&
          bo->size == backing->allocation.size &&
          bo->carrier_resource_binding == backing->resource.resource_list_binding;
}

static bool
apple_agx_metal_bo_provider_create(
   void *context, uint64_t size, enum agx_bo_flags flags,
   struct agx_macos_mesa_platform_bo *out_bo)
{
   struct AppleAGXMetalBOProvider *provider = context;
   struct AppleAGXMetalBOBacking *backing;
   enum AppleAGXMetalAllocationStorage storage;

   if (!AppleAGXMetalBOProviderIsCurrent(provider) || !out_bo || out_bo->owner ||
       out_bo->cpu || out_bo->gpu_va != 0 || out_bo->size != 0 ||
       out_bo->carrier_resource_binding || size == 0 ||
       (flags & ~AGX_BO_WRITEBACK) != 0) {
      return false;
   }

   storage = flags & AGX_BO_WRITEBACK
      ? APPLE_AGX_METAL_ALLOCATION_SHARED
      : APPLE_AGX_METAL_ALLOCATION_WRITE_COMBINED;
   backing = calloc(1, sizeof(*backing));
   if (!backing ||
       !AppleAGXMetalAllocationCreate(provider->bridge, size, storage,
                                       &backing->allocation) ||
       !AppleAGXMetalResourceRefRead(provider->bridge,
                                     backing->allocation.metal_buffer,
                                     &backing->resource) ||
       !apple_agx_metal_bo_backing_is_current(backing) ||
       (backing->allocation.gpu_va & (AIL_PAGESIZE - 1)) != 0) {
      if (backing) {
         AppleAGXMetalAllocationDestroy(&backing->allocation);
         free(backing);
      }
      return false;
   }

   *out_bo = (struct agx_macos_mesa_platform_bo){
      .owner = backing,
      .cpu = backing->allocation.cpu_mapping,
      .gpu_va = backing->allocation.gpu_va,
      .size = backing->allocation.size,
      .carrier_resource_binding = backing->resource.resource_list_binding,
      .shader_provenance = NULL,
   };
   return true;
}

static void
apple_agx_metal_bo_provider_destroy(
   void *context, struct agx_macos_mesa_platform_bo *bo)
{
   struct AppleAGXMetalBOProvider *provider = context;
   struct AppleAGXMetalBOBacking *backing = bo ? bo->owner : NULL;

   (void)provider;
   if (backing) {
      AppleAGXMetalAllocationDestroy(&backing->allocation);
      free(backing);
   }
   if (bo)
      *bo = (struct agx_macos_mesa_platform_bo){0};
}

bool
AppleAGXMetalBOProviderInit(
   struct AppleAGXMetalBOProvider *provider,
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session)
{
   if (!provider || provider->bridge || provider->session ||
       provider->mesa_provider.context || !bridge || !session ||
       !AppleAGXNativeBridgeHasObservedResourceListBindingContract(bridge,
                                                                    session)) {
      return false;
   }

   *provider = (struct AppleAGXMetalBOProvider){
      .bridge = bridge,
      .session = session,
      .mesa_provider = {
         .context = provider,
         .capabilities = AGX_MACOS_MESA_PLATFORM_BO_CAP_CPU_MAPPABLE,
         .create = apple_agx_metal_bo_provider_create,
         .is_current = apple_agx_metal_bo_provider_is_current,
         .destroy = apple_agx_metal_bo_provider_destroy,
      },
   };
   return true;
}

bool
AppleAGXMetalBOProviderIsCurrent(
   const struct AppleAGXMetalBOProvider *provider)
{
   return provider && provider->bridge && provider->session &&
          provider->mesa_provider.context == provider &&
          provider->mesa_provider.capabilities ==
             AGX_MACOS_MESA_PLATFORM_BO_CAP_CPU_MAPPABLE &&
          provider->mesa_provider.create == apple_agx_metal_bo_provider_create &&
          provider->mesa_provider.is_current == apple_agx_metal_bo_provider_is_current &&
          provider->mesa_provider.destroy == apple_agx_metal_bo_provider_destroy &&
          AppleAGXNativeBridgeHasObservedResourceListBindingContract(
             provider->bridge, provider->session);
}

const struct agx_macos_mesa_bo_provider *
AppleAGXMetalBOProviderMesaProvider(
   const struct AppleAGXMetalBOProvider *provider)
{
   return AppleAGXMetalBOProviderIsCurrent(provider)
      ? &provider->mesa_provider
      : NULL;
}

bool
AppleAGXMetalBOProviderReadMesaBOResource(
   const struct AppleAGXMetalBOProvider *provider,
   const struct agx_device *device, const struct agx_bo *bo,
   struct AppleAGXMetalResourceRef *out_ref)
{
   struct agx_macos_mesa_platform_bo platform_bo = {0};
   const struct AppleAGXMetalBOBacking *backing;

   if (!AppleAGXMetalBOProviderIsCurrent(provider) || !out_ref ||
       out_ref->bridge || out_ref->metal_buffer || out_ref->resource_ref ||
       out_ref->resource_list_binding || out_ref->gpu_va ||
       out_ref->gpu_va_length ||
       !agx_macos_mesa_bo_get_platform_backing(
          device, bo, &provider->mesa_provider, &platform_bo)) {
      return false;
   }

   backing = platform_bo.owner;
   if (!apple_agx_metal_bo_backing_is_current(backing) ||
       platform_bo.carrier_resource_binding !=
          backing->resource.resource_list_binding) {
      return false;
   }

   *out_ref = backing->resource;
   return true;
}

void
AppleAGXMetalBOProviderDestroy(struct AppleAGXMetalBOProvider *provider)
{
   if (provider)
      *provider = (struct AppleAGXMetalBOProvider){0};
}
