/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>

#include <dlfcn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

#define AO46_IOGPU_PATH \
   "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU"

/* The debugger binds generic IOGPU symbols only after this public control has
 * loaded IOGPU. AO46 does not call those symbols from this executable. */
__attribute__((noinline)) void
ao46_queue_contract_capture_ready(void)
{
}

char ao46_queue_contract_phase[32] = "bootstrap";
unsigned ao46_queue_contract_submission_serial = 0;
uintptr_t ao46_queue_contract_public_command_buffer = 0;
static atomic_uint ao46_queue_contract_completion_count = 0;

static void
ao46_queue_contract_set_phase(const char *phase)
{
   (void)snprintf(ao46_queue_contract_phase,
                  sizeof(ao46_queue_contract_phase), "%s", phase);
   printf("AO46_QUEUE_CONTRACT_CONTROL phase=%s\n", ao46_queue_contract_phase);
   fflush(stdout);
}

static bool
ao46_queue_contract_submit_empty(id<MTLCommandQueue> queue, unsigned serial)
{
   id<MTLCommandBuffer> command_buffer;

   ao46_queue_contract_submission_serial = serial;
   command_buffer = [queue commandBuffer];
   if (!command_buffer)
      return false;

   ao46_queue_contract_public_command_buffer = (uintptr_t)command_buffer;
   printf("AO46_QUEUE_CONTRACT_PUBLIC_COMMAND_BUFFER serial=%u object=%#018llx\n",
          serial,
          (unsigned long long)ao46_queue_contract_public_command_buffer);
   fflush(stdout);

   [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      unsigned completed_count =
         atomic_fetch_add_explicit(&ao46_queue_contract_completion_count, 1,
                                   memory_order_acq_rel) + 1;

      printf("AO46_QUEUE_CONTRACT_COMPLETION serial=%u completed_count=%u "
             "status=%ld\n", serial, completed_count,
             (long)completed.status);
      fflush(stdout);
   }];
   [command_buffer commit];
   [command_buffer waitUntilCompleted];
   ao46_queue_contract_public_command_buffer = 0;
   return command_buffer.status != MTLCommandBufferStatusError &&
          atomic_load_explicit(&ao46_queue_contract_completion_count,
                               memory_order_acquire) >= serial;
}

int
main(void)
{
   id<MTLDevice> device;
   id<MTLCommandQueue> queue;
   void *iogpu_image;

   @autoreleasepool {
      device = MTLCreateSystemDefaultDevice();
      iogpu_image = dlopen(AO46_IOGPU_PATH, RTLD_NOW | RTLD_LOCAL);
      if (!device || !iogpu_image ||
          !dlsym(iogpu_image, "IOGPUCommandQueueCreate") ||
          !dlsym(iogpu_image, "IOGPUCommandQueueSubmitCommandBuffers")) {
         fputs("Apple IOGPU queue contract is unavailable\n", stderr);
         if (iogpu_image)
            dlclose(iogpu_image);
         if (device)
            [device release];
         return 77;
      }

      ao46_queue_contract_capture_ready();

      ao46_queue_contract_set_phase("queue-create");
      queue = [device newCommandQueue];
      if (!queue) {
         fputs("Apple Metal queue control did not create a queue\n", stderr);
         dlclose(iogpu_image);
         [device release];
         return 1;
      }

      /* Two empty command buffers establish ordered queue reuse, descriptor
       * lifetime, and public completion without creating any Metal encoder or
       * GPU payload. */
      for (unsigned serial = 1; serial <= 2; ++serial) {
         char phase[32];

         (void)snprintf(phase, sizeof(phase), "empty-submit-%u", serial);
         ao46_queue_contract_set_phase(phase);
         if (!ao46_queue_contract_submit_empty(queue, serial)) {
            fputs("Apple empty command buffer completion contract failed\n",
                  stderr);
            [queue release];
            dlclose(iogpu_image);
            [device release];
            return 1;
         }
      }

      if (atomic_load_explicit(&ao46_queue_contract_completion_count,
                               memory_order_acquire) != 2) {
         fputs("Apple queue control did not observe both completions\n", stderr);
         [queue release];
         dlclose(iogpu_image);
         [device release];
         return 1;
      }

      ao46_queue_contract_set_phase("release");
      [queue release];
      dlclose(iogpu_image);
      [device release];
   }

   return 0;
}
