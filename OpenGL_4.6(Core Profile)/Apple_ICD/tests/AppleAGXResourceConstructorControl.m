/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define AO46_IOGPU_PATH \
   "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU"
#define AO46_G16X_DEVICE_REF_ENCODING "^{__IOGPUDevice=}16@0:8"
#define AO46_RESOURCE_CONSTRUCTOR_BUFFER_COUNT 13

static const char *const ao46_resource_constructor_phases[
   AO46_RESOURCE_CONSTRUCTOR_BUFFER_COUNT] = {
      "shared-4k-a",
      "shared-4k-b",
      "shared-128k",
      "private-4k",
      "writecombined-4k",
      "shared-untracked-4k",
      "shared-8k",
      "shared-16k",
      "shared-16k-b",
      "shared-16k-writecombined",
      "shared-32k",
      "shared-16k-after-failure",
      "shared-16k-after-failure-b",
   };

static const NSUInteger ao46_resource_constructor_lengths[
   AO46_RESOURCE_CONSTRUCTOR_BUFFER_COUNT] = {
      4096,
      4096,
      131072,
      4096,
      4096,
      4096,
      8192,
      16384,
      16384,
      16384,
      32768,
      16384,
      16384,
   };

/* The debugger stops here only after IOGPU has been dynamically loaded. This
 * lets the capture script bind Apple's exported constructor without guessed
 * addresses or an AO46 call to that private function. */
__attribute__((noinline)) void
ao46_resource_constructor_capture_ready(void)
{
}

/* Read by the LLDB-only capture callback. It identifies the public Metal
 * allocation that caused each generic IOGPUResourceCreate call. */
char ao46_resource_constructor_phase[32] = "bootstrap";

static const void *
ao46_resource_constructor_device_ref(id<MTLDevice> device)
{
   Class device_class = objc_lookUpClass("IOGPUMetalDevice");
   SEL device_ref_selector = sel_registerName("deviceRef");
   Method device_ref_method = device_class
      ? class_getInstanceMethod(device_class, device_ref_selector)
      : NULL;
   const char *encoding = device_ref_method
      ? method_getTypeEncoding(device_ref_method)
      : NULL;
   IMP implementation;
   const void *(*device_ref)(id, SEL);

   if (!device_class || ![(id)device isKindOfClass:device_class] || !encoding ||
       strcmp(encoding, AO46_G16X_DEVICE_REF_ENCODING) != 0) {
      return NULL;
   }

   implementation = [(id)device methodForSelector:device_ref_selector];
   if (!implementation)
      return NULL;

   device_ref = (const void *(*)(id, SEL))implementation;
   return device_ref((id)device, device_ref_selector);
}

static id<MTLBuffer>
ao46_resource_constructor_allocate(id<MTLDevice> device, const char *phase,
                                   NSUInteger length,
                                   MTLResourceOptions options)
{
   (void)snprintf(ao46_resource_constructor_phase,
                  sizeof(ao46_resource_constructor_phase), "%s", phase);
   printf("AO46_RESOURCE_CONSTRUCTOR_CONTROL phase=%s bytes=%lu options=%#llx\n",
          ao46_resource_constructor_phase, (unsigned long)length,
          (unsigned long long)options);
   fflush(stdout);
   return [device newBufferWithLength:length options:options];
}

int
main(void)
{
   id<MTLDevice> device;
   id<MTLBuffer> buffers[AO46_RESOURCE_CONSTRUCTOR_BUFFER_COUNT] = {nil};
   void *public_contents[AO46_RESOURCE_CONSTRUCTOR_BUFFER_COUNT] = {NULL};
   uint8_t *shared_contents;
   uint8_t *writecombined_contents;
   uint8_t *untracked_contents;
   void *private_contents;
   void *iogpu_image;
   const void *device_ref;
   NSUInteger maximum_buffer_length;
   id<MTLBuffer> rejected_buffer;

   @autoreleasepool {
      device = MTLCreateSystemDefaultDevice();
      iogpu_image = dlopen(AO46_IOGPU_PATH, RTLD_NOW | RTLD_LOCAL);
      if (!device || !iogpu_image || !dlsym(iogpu_image, "IOGPUResourceCreate")) {
         fputs("Apple IOGPU resource constructor is unavailable\n", stderr);
         if (iogpu_image)
            dlclose(iogpu_image);
         if (device)
            [device release];
         return 77;
      }

      ao46_resource_constructor_capture_ready();
      device_ref = ao46_resource_constructor_device_ref(device);
      if (!device_ref) {
         fputs("Apple Metal device did not expose a validated IOGPU device root\n",
               stderr);
         dlclose(iogpu_image);
         [device release];
         return 1;
      }
      printf("AO46_RESOURCE_CONSTRUCTOR_CONTROL device_ref=%#018llx\n",
             (unsigned long long)(uintptr_t)device_ref);
      fflush(stdout);

      /* Public Metal owns these allocations. AO46 only observes the generic
       * C constructor frames that Apple uses to create them. The duplicate
       * shared allocation separates address churn from input-dependent bytes. */
      buffers[0] = ao46_resource_constructor_allocate(
         device, "shared-4k-a", 4096, MTLResourceStorageModeShared);
      buffers[1] = ao46_resource_constructor_allocate(
         device, "shared-4k-b", 4096, MTLResourceStorageModeShared);
      buffers[2] = ao46_resource_constructor_allocate(
         device, "shared-128k", 131072, MTLResourceStorageModeShared);
      buffers[3] = ao46_resource_constructor_allocate(
         device, "private-4k", 4096, MTLResourceStorageModePrivate);
      buffers[4] = ao46_resource_constructor_allocate(
         device, "writecombined-4k", 4096,
         MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined);
      buffers[5] = ao46_resource_constructor_allocate(
         device, "shared-untracked-4k", 4096,
         MTLResourceStorageModeShared | MTLHazardTrackingModeUntracked);
      buffers[6] = ao46_resource_constructor_allocate(
         device, "shared-8k", 8192, MTLResourceStorageModeShared);
      buffers[7] = ao46_resource_constructor_allocate(
         device, "shared-16k", 16384, MTLResourceStorageModeShared);
      buffers[8] = ao46_resource_constructor_allocate(
         device, "shared-16k-b", 16384, MTLResourceStorageModeShared);
      buffers[9] = ao46_resource_constructor_allocate(
         device, "shared-16k-writecombined", 16384,
         MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined);
      buffers[10] = ao46_resource_constructor_allocate(
         device, "shared-32k", 32768, MTLResourceStorageModeShared);
      if (!buffers[0] || !buffers[1] || !buffers[2] || !buffers[3] ||
          !buffers[4] || !buffers[5] || !buffers[6] || !buffers[7] ||
          !buffers[8] || !buffers[9] || !buffers[10]) {
         fputs("Apple Metal allocation control did not create every buffer\n",
               stderr);
         for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
            [buffers[i] release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }

      /* A public request beyond the advertised limit must fail before it can
       * produce a generic resource object. This bounds, but does not replace,
       * a future private-constructor failure cleanup policy. */
      maximum_buffer_length = [device maxBufferLength];
      if (maximum_buffer_length == NSUIntegerMax) {
         fputs("Apple Metal maximum buffer length cannot form a failure probe\n",
               stderr);
         for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
            [buffers[i] release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }
      rejected_buffer = ao46_resource_constructor_allocate(
         device, "oversized-failure", maximum_buffer_length + 1,
         MTLResourceStorageModeShared);
      if (rejected_buffer) {
         fputs("Apple Metal accepted an allocation beyond maxBufferLength\n",
               stderr);
         [rejected_buffer release];
         for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
            [buffers[i] release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }
      printf("AO46_RESOURCE_CONSTRUCTOR_CONTROL allocation_failure "
             "phase=oversized-failure limit=%lu requested=%lu rejected=1\n",
             (unsigned long)maximum_buffer_length,
             (unsigned long)(maximum_buffer_length + 1));
      fflush(stdout);

      buffers[11] = ao46_resource_constructor_allocate(
         device, "shared-16k-after-failure", 16384,
         MTLResourceStorageModeShared);
      buffers[12] = ao46_resource_constructor_allocate(
         device, "shared-16k-after-failure-b", 16384,
         MTLResourceStorageModeShared);
      if (!buffers[11] || !buffers[12]) {
         fputs("Apple Metal did not recover after a null resource constructor return\n",
               stderr);
         for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
            [buffers[i] release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }

      /* This is intentionally a public-Metal mapping control. It establishes
       * which Apple-owned allocation families expose CPU memory before AO46
       * can consider a typed generic resource adapter. */
      for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
         public_contents[i] = [buffers[i] contents];

      shared_contents = public_contents[0];
      writecombined_contents = public_contents[4];
      untracked_contents = public_contents[5];
      private_contents = public_contents[3];
      if (!shared_contents || !writecombined_contents || !untracked_contents) {
         fputs("Apple Metal buffer mapping contract was unexpected\n", stderr);
         for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
            [buffers[i] release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }

      shared_contents[0] = 0x46;
      shared_contents[4095] = 0xa0;
      writecombined_contents[0] = 0x46;
      writecombined_contents[4095] = 0x4f;
      untracked_contents[0] = 0x46;
      untracked_contents[4095] = 0x55;
      printf("AO46_RESOURCE_CONSTRUCTOR_CONTROL mapping shared=1 "
             "writecombined=1 untracked=1 private_pointer=%u "
             "shared_edge=%02x%02x writecombined_edge=%02x%02x "
             "untracked_edge=%02x%02x\n",
             private_contents ? 1u : 0u,
             shared_contents[0], shared_contents[4095],
             writecombined_contents[0], writecombined_contents[4095],
             untracked_contents[0], untracked_contents[4095]);
      for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i) {
         printf("AO46_RESOURCE_CONSTRUCTOR_CONTROL public_mapping phase=%s "
                "contents=%#018llx logical_size=%lu gpu_address=%#018llx\n",
                ao46_resource_constructor_phases[i],
                (unsigned long long)(uintptr_t)public_contents[i],
                (unsigned long)ao46_resource_constructor_lengths[i],
                (unsigned long long)[buffers[i] gpuAddress]);
      }
      fflush(stdout);

      printf("Apple AGX resource constructor control: shared_4k=%p "
             "shared_128k=%p private_4k=%p writecombined_4k=%p\n",
             buffers[0], buffers[2], buffers[3], buffers[4]);
      (void)snprintf(ao46_resource_constructor_phase,
                     sizeof(ao46_resource_constructor_phase), "release");
      fputs("AO46_RESOURCE_CONSTRUCTOR_CONTROL phase=release\n", stdout);
      fflush(stdout);
      for (unsigned i = 0; i < sizeof(buffers) / sizeof(buffers[0]); ++i)
         [buffers[i] release];
      dlclose(iogpu_image);
      [device release];
   }

   return 0;
}
