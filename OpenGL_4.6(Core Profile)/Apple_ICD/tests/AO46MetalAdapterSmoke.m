/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MetalAdapter.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char ao46_msl_compute_source[] =
   "#include <metal_stdlib>\n"
   "using namespace metal;\n"
   "kernel void ao46_mesa_contract_smoke(device uint *output [[buffer(0)]],\n"
   "                                     uint id [[thread_position_in_grid]]) {\n"
   "  output[id] = id * 3u + 7u;\n"
   "}\n";

static bool
ao46_texture_copy_smoke(const struct AO46MetalAdapter *adapter)
{
   struct AO46MetalTexture source = {0};
   struct AO46MetalTexture destination = {0};
   struct AO46MetalBuffer upload = {0};
   struct AO46MetalBuffer readback = {0};
   struct AO46MetalSubmission submission = {0};
   size_t bytes_per_row = 0;
   size_t transfer_size = 0;
   bool passed = false;

   if (!AO46MetalTextureCreate(adapter, 4, 4,
                               AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM,
                               &source) ||
       !AO46MetalTextureCreate(adapter, 4, 4,
                               AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM,
                               &destination) ||
       !AO46MetalTextureTransferLayout(&source, 4, 4, &bytes_per_row,
                                       &transfer_size) ||
       !AO46MetalBufferCreate(adapter, transfer_size, &upload) ||
       !AO46MetalBufferCreate(adapter, transfer_size, &readback))
      goto out;

   memset(upload.cpu_mapping, 0, upload.length);
   for (uint32_t y = 0; y < 4; ++y) {
      uint8_t *row = (uint8_t *)upload.cpu_mapping + y * bytes_per_row;

      for (uint32_t x = 0; x < 4; ++x) {
         row[x * 4 + 0] = (uint8_t)(x * 31u + y);
         row[x * 4 + 1] = (uint8_t)(y * 47u + x);
         row[x * 4 + 2] = (uint8_t)(x + y * 7u);
         row[x * 4 + 3] = 255;
      }
   }

   if (!AO46MetalTextureUploadSubmit(adapter, &upload, 0, bytes_per_row,
                                     &source, 0, 0, 4, 4, &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto out;
   AO46MetalSubmissionDestroy(&submission);

   if (!AO46MetalTextureCopySubmit(adapter, &source, 0, 0, &destination,
                                   0, 0, 4, 4, &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto out;
   AO46MetalSubmissionDestroy(&submission);

   if (!AO46MetalTextureReadbackSubmit(adapter, &destination, 0, 0, 4, 4,
                                       &readback, 0, bytes_per_row,
                                       &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto out;
   AO46MetalSubmissionDestroy(&submission);

   for (uint32_t y = 0; y < 4; ++y) {
      const uint8_t *row = (const uint8_t *)readback.cpu_mapping +
                           y * bytes_per_row;

      for (uint32_t x = 0; x < 4; ++x) {
         if (row[x * 4 + 0] != (uint8_t)(x * 31u + y) ||
             row[x * 4 + 1] != (uint8_t)(y * 47u + x) ||
             row[x * 4 + 2] != (uint8_t)(x + y * 7u) ||
             row[x * 4 + 3] != 255) {
            goto out;
         }
      }
   }

   passed = true;
out:
   AO46MetalSubmissionDestroy(&submission);
   AO46MetalBufferDestroy(&readback);
   AO46MetalBufferDestroy(&upload);
   AO46MetalTextureDestroy(&destination);
   AO46MetalTextureDestroy(&source);
   return passed;
}

static bool
ao46_iosurface_import_smoke(const struct AO46MetalAdapter *adapter)
{
   const uint32_t iosurface_bgra = UINT32_C(0x42475241);
   const float clear_color[] = {0.25f, 0.5f, 0.75f, 1.0f};
   const size_t width = 4;
   const size_t height = 4;
   const size_t bytes_per_row = width * 4;
   const NSDictionary *properties = @{
      (id)kIOSurfaceWidth: @(width),
      (id)kIOSurfaceHeight: @(height),
      (id)kIOSurfaceBytesPerElement: @4,
      (id)kIOSurfaceBytesPerRow: @(bytes_per_row),
      (id)kIOSurfacePixelFormat: @(iosurface_bgra),
   };
   IOSurfaceRef surface = NULL;
   struct AO46MetalTexture texture = {0};
   struct AO46MetalSubmission submission = {0};
   bool locked = false;
   bool passed = false;

   surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
   if (!surface || IOSurfaceGetAllocSize(surface) < bytes_per_row * height ||
       !AO46MetalTextureImportIOSurface(adapter, (void *)surface,
                                        AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM,
                                        &texture) ||
       !AO46MetalTextureClearSubmit(adapter, &texture, clear_color,
                                    &submission) ||
       !AO46MetalSubmissionWait(&submission))
      goto out;
   AO46MetalSubmissionDestroy(&submission);

   if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS)
      goto out;
   locked = true;
   {
      const uint8_t *pixel = IOSurfaceGetBaseAddress(surface);

      if (!pixel || pixel[0] < 190 || pixel[0] > 192 ||
          pixel[1] < 127 || pixel[1] > 129 || pixel[2] < 63 ||
          pixel[2] > 65 || pixel[3] != 255)
         goto out;
   }
   passed = true;
out:
   if (locked)
      IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
   AO46MetalSubmissionDestroy(&submission);
   AO46MetalTextureDestroy(&texture);
   if (surface)
      CFRelease(surface);
   return passed;
}

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct AO46MetalAdapter retained_adapter = {0};
   struct AO46MetalBuffer output = {0};
   struct AO46MetalComputePipeline pipeline = {0};
   struct AO46MetalSubmission submission = {0};
   struct AO46MetalSubmission lifecycle_submission = {0};
   struct AO46MetalBufferBinding binding;
   uint32_t *values;

   if (!AO46MetalAdapterCreate(&adapter) || !AO46MetalAdapterIsCurrent(&adapter)) {
      fprintf(stderr, "AO46 Metal adapter did not create a usable device/queue\n");
      return 1;
   }

   if (!AO46MetalAdapterCopyRetained(&adapter, &retained_adapter) ||
       !AO46MetalAdapterIsCurrent(&retained_adapter) ||
       retained_adapter.device != adapter.device ||
       retained_adapter.queue != adapter.queue) {
      fprintf(stderr, "AO46 Metal adapter could not retain a shared queue carrier\n");
      AO46MetalAdapterDestroy(&retained_adapter);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }
   AO46MetalAdapterDestroy(&adapter);
   adapter = retained_adapter;
   retained_adapter = (struct AO46MetalAdapter){0};
   if (!AO46MetalAdapterIsCurrent(&adapter)) {
      fprintf(stderr, "AO46 Metal retained adapter lost its shared queue\n");
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   if (!AO46MetalSubmissionBegin(&adapter, &lifecycle_submission) ||
       AO46MetalSubmissionIsComplete(&lifecycle_submission) ||
       AO46MetalSubmissionWait(&lifecycle_submission) ||
       !AO46MetalSubmissionCommit(&lifecycle_submission, true) ||
       !AO46MetalSubmissionIsComplete(&lifecycle_submission)) {
      fprintf(stderr, "AO46 Metal adapter submission lifecycle is invalid\n");
      AO46MetalSubmissionDestroy(&lifecycle_submission);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }
   AO46MetalSubmissionDestroy(&lifecycle_submission);

   if (!AO46MetalBufferCreate(&adapter, 16 * sizeof(uint32_t), &output) ||
       !AO46MetalBufferIsCurrent(&output)) {
      fprintf(stderr, "AO46 Metal adapter did not create a shared buffer\n");
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }
   memset(output.cpu_mapping, 0, output.length);

   if (!AO46MetalComputePipelineCreate(&adapter, ao46_msl_compute_source,
                                       "ao46_mesa_contract_smoke", &pipeline)) {
      fprintf(stderr, "AO46 Metal adapter did not compile MSL input\n");
      AO46MetalBufferDestroy(&output);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }
   if (AO46MetalAdapterSupportsMTL4Submission(&adapter) &&
       !pipeline.uses_mtl4_compiler) {
      fprintf(stderr, "AO46 Metal adapter did not use KK's MTL4 compiler\n");
      AO46MetalComputePipelineDestroy(&pipeline);
      AO46MetalBufferDestroy(&output);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   binding = (struct AO46MetalBufferBinding){
      .buffer = &output,
      .index = 0,
      .writable = true,
   };
   if (!AO46MetalComputeSubmit(&adapter, &pipeline, &binding, 1, 16, 1, 1,
                               16, 1, 1, &submission) ||
       (AO46MetalAdapterSupportsMTL4Submission(&adapter) &&
        !submission.uses_mtl4) ||
       !AO46MetalSubmissionWait(&submission)) {
      fprintf(stderr, "AO46 Metal adapter did not complete an MTL4 GPU dispatch\n");
      AO46MetalSubmissionDestroy(&submission);
      AO46MetalComputePipelineDestroy(&pipeline);
      AO46MetalBufferDestroy(&output);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   values = output.cpu_mapping;
   for (uint32_t i = 0; i < 16; ++i) {
      if (values[i] != i * 3u + 7u) {
         fprintf(stderr, "AO46 Metal adapter readback mismatch at %u\n", i);
         AO46MetalSubmissionDestroy(&submission);
         AO46MetalComputePipelineDestroy(&pipeline);
         AO46MetalBufferDestroy(&output);
         AO46MetalAdapterDestroy(&adapter);
         return 1;
      }
   }

   AO46MetalSubmissionDestroy(&submission);

   if (!ao46_texture_copy_smoke(&adapter)) {
      fprintf(stderr, "AO46 Metal adapter texture copy/readback is invalid\n");
      AO46MetalComputePipelineDestroy(&pipeline);
      AO46MetalBufferDestroy(&output);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   if (!ao46_iosurface_import_smoke(&adapter)) {
      fprintf(stderr, "AO46 Metal adapter IOSurface import/clear is invalid\n");
      AO46MetalComputePipelineDestroy(&pipeline);
      AO46MetalBufferDestroy(&output);
      AO46MetalAdapterDestroy(&adapter);
      return 1;
   }

   AO46MetalComputePipelineDestroy(&pipeline);
   AO46MetalBufferDestroy(&output);
   AO46MetalAdapterDestroy(&adapter);
   return 0;
}
