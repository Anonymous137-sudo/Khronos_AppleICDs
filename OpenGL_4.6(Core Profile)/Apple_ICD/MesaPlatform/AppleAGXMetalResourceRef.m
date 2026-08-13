/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>
#import <objc/runtime.h>

#include "AppleAGXMetalResourceRef.h"

#include "AppleAGXNativeBridge.h"

#include <string.h>

#define AO46_G16X_RESOURCE_REF_ENCODING \
   "^{__IOGPUResource={__CFRuntimeBase=QAQ}^{__IOGPUDevice}^vQQIIQQ" \
   "^{IOGPUClientSharedRO}QQQQ^v[0Q]}16@0:8"
#define AO46_G16X_RESOURCE_IVAR_PREFIX "{_IOGPUMetalResource="
#define AO46_G16X_RESOURCE_IVAR_OFFSET 0x20
#define AO46_G16X_RESOURCE_LIST_BINDING_OFFSET 0x40

typedef const void *(*AppleAGXResourceRefFn)(id resource, SEL selector);

static bool
apple_agx_metal_resource_ref_read(
   const struct AppleAGXNativeBridge *bridge, void *metal_buffer,
   const void **out_resource_ref, uint64_t *out_gpu_va,
   uint64_t *out_gpu_va_length)
{
   Class buffer_class;
   Class resource_class;
   SEL selector;
   Method method;
   Ivar resource_ivar;
   const char *encoding;
   const char *resource_ivar_encoding;
   ptrdiff_t resource_ivar_offset;
   size_t resource_instance_size;
   AppleAGXResourceRefFn resource_ref;
   const void *native_ref;
   uint64_t public_gpu_va;
   uint64_t public_length;
   uint64_t native_gpu_va;
   uint64_t native_gpu_va_length;

   if (!bridge || !bridge->resource_get_gpu_virtual_address ||
       !bridge->resource_get_gpu_virtual_address_length || !metal_buffer ||
       !out_resource_ref || !out_gpu_va || !out_gpu_va_length) {
      return false;
   }

   buffer_class = objc_lookUpClass("IOGPUMetalBuffer");
   resource_class = objc_lookUpClass("IOGPUMetalResource");
   selector = sel_registerName("resourceRef");
   method = resource_class
      ? class_getInstanceMethod(resource_class, selector)
      : NULL;
   encoding = method ? method_getTypeEncoding(method) : NULL;
   resource_ivar = resource_class
      ? class_getInstanceVariable(resource_class, "_res")
      : NULL;
   resource_ivar_encoding =
      resource_ivar ? ivar_getTypeEncoding(resource_ivar) : NULL;
   resource_ivar_offset = resource_ivar ? ivar_getOffset(resource_ivar) : 0;
   resource_instance_size = resource_class
      ? class_getInstanceSize(resource_class)
      : 0;
   if (!buffer_class || !resource_class ||
       ![(id)metal_buffer isKindOfClass:buffer_class] || !encoding ||
       strcmp(encoding, AO46_G16X_RESOURCE_REF_ENCODING) != 0 ||
       !resource_ivar_encoding ||
       strncmp(resource_ivar_encoding, AO46_G16X_RESOURCE_IVAR_PREFIX,
               strlen(AO46_G16X_RESOURCE_IVAR_PREFIX)) != 0 ||
       resource_ivar_offset != AO46_G16X_RESOURCE_IVAR_OFFSET ||
       resource_instance_size < AO46_G16X_RESOURCE_LIST_BINDING_OFFSET) {
      return false;
   }

   resource_ref = (AppleAGXResourceRefFn)[(id)metal_buffer
      methodForSelector:selector];
   if (!resource_ref)
      return false;

   native_ref = resource_ref((id)metal_buffer, selector);
   if (!native_ref)
      return false;

   public_gpu_va = [(id<MTLBuffer>)metal_buffer gpuAddress];
   public_length = [(id<MTLBuffer>)metal_buffer length];
   native_gpu_va = ((AppleAGXNativeResourceGetGPUVirtualAddressFn)bridge
      ->resource_get_gpu_virtual_address)(native_ref);
   native_gpu_va_length =
      ((AppleAGXNativeResourceGetGPUVirtualAddressLengthFn)bridge
         ->resource_get_gpu_virtual_address_length)(native_ref);
   if (public_gpu_va == 0 || public_length == 0 ||
       native_gpu_va != public_gpu_va || native_gpu_va_length < public_length) {
      return false;
   }

   *out_resource_ref = native_ref;
   *out_gpu_va = native_gpu_va;
   *out_gpu_va_length = native_gpu_va_length;
   return true;
}

bool
AppleAGXMetalResourceRefRead(
   const struct AppleAGXNativeBridge *bridge, void *metal_buffer,
   struct AppleAGXMetalResourceRef *out_ref)
{
   const void *resource_ref = NULL;
   uint64_t gpu_va = 0;
   uint64_t gpu_va_length = 0;

   if (!out_ref || out_ref->bridge || out_ref->metal_buffer ||
       out_ref->resource_ref || out_ref->resource_list_binding || out_ref->gpu_va ||
       out_ref->gpu_va_length ||
       !apple_agx_metal_resource_ref_read(bridge, metal_buffer, &resource_ref,
                                          &gpu_va, &gpu_va_length)) {
      return false;
   }

   *out_ref = (struct AppleAGXMetalResourceRef){
      .bridge = bridge,
      .metal_buffer = metal_buffer,
      .resource_ref = resource_ref,
      .resource_list_binding =
         (const uint8_t *)metal_buffer + AO46_G16X_RESOURCE_LIST_BINDING_OFFSET,
      .gpu_va = gpu_va,
      .gpu_va_length = gpu_va_length,
   };
   return true;
}

bool
AppleAGXMetalResourceRefIsCurrent(
   const struct AppleAGXMetalResourceRef *ref)
{
   const void *resource_ref = NULL;
   uint64_t gpu_va = 0;
   uint64_t gpu_va_length = 0;

   return ref && ref->bridge && ref->metal_buffer && ref->resource_ref &&
          ref->resource_list_binding &&
          apple_agx_metal_resource_ref_read(ref->bridge, ref->metal_buffer,
                                            &resource_ref, &gpu_va,
                                            &gpu_va_length) &&
          resource_ref == ref->resource_ref &&
          ref->resource_list_binding ==
             (const uint8_t *)ref->metal_buffer +
                AO46_G16X_RESOURCE_LIST_BINDING_OFFSET &&
          gpu_va == ref->gpu_va &&
          gpu_va_length == ref->gpu_va_length;
}
