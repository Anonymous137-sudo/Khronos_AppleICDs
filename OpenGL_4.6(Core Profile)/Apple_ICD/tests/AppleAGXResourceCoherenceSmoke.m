/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <Metal/Metal.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
   AO46_COHERENCE_BYTES = 4096,
   AO46_COHERENCE_FIRST_OFFSET = 0,
   AO46_COHERENCE_LAST_OFFSET = AO46_COHERENCE_BYTES - 1,
};

static int
ao46_check_byte_pair(const uint8_t *contents, uint8_t first, uint8_t last)
{
   return contents && contents[AO46_COHERENCE_FIRST_OFFSET] == first &&
          contents[AO46_COHERENCE_LAST_OFFSET] == last;
}

static int
ao46_copy_and_wait(id<MTLCommandQueue> queue, id<MTLBuffer> source,
                   id<MTLBuffer> intermediate, id<MTLBuffer> destination)
{
   id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
   id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];

   if (!command_buffer || !blit)
      return 0;

   [blit copyFromBuffer:source
            sourceOffset:0
                toBuffer:intermediate
       destinationOffset:0
                    size:AO46_COHERENCE_BYTES];
   [blit copyFromBuffer:intermediate
            sourceOffset:0
                toBuffer:destination
       destinationOffset:0
                    size:AO46_COHERENCE_BYTES];
   [blit endEncoding];
   [command_buffer commit];
   [command_buffer waitUntilCompleted];
   return command_buffer.status == MTLCommandBufferStatusCompleted;
}

int
main(void)
{
   id<MTLDevice> device = MTLCreateSystemDefaultDevice();
   id<MTLCommandQueue> queue;
   id<MTLBuffer> source;
   id<MTLBuffer> private_buffer;
   id<MTLBuffer> destination;
   uint8_t *source_contents;
   uint8_t *destination_contents;
   int first_round_trip;
   int second_round_trip;

   if (!device) {
      fputs("Apple AGX coherence smoke requires a Metal device\n", stderr);
      return 77;
   }

   queue = [device newCommandQueue];
   source = [device newBufferWithLength:AO46_COHERENCE_BYTES
                                 options:MTLResourceStorageModeShared];
   private_buffer = [device newBufferWithLength:AO46_COHERENCE_BYTES
                                         options:MTLResourceStorageModePrivate];
   destination = [device newBufferWithLength:AO46_COHERENCE_BYTES
                                      options:MTLResourceStorageModeShared];
   source_contents = [source contents];
   destination_contents = [destination contents];
   if (!queue || !source || !private_buffer || !destination || !source_contents ||
       !destination_contents) {
      fputs("Apple AGX coherence smoke could not allocate public Metal buffers\n",
            stderr);
      [destination release];
      [private_buffer release];
      [source release];
      [queue release];
      [device release];
      return 1;
   }

   memset(source_contents, 0, AO46_COHERENCE_BYTES);
   memset(destination_contents, 0, AO46_COHERENCE_BYTES);
   source_contents[AO46_COHERENCE_FIRST_OFFSET] = 0x46;
   source_contents[AO46_COHERENCE_LAST_OFFSET] = 0xa0;
   first_round_trip = ao46_copy_and_wait(queue, source, private_buffer, destination) &&
      ao46_check_byte_pair(destination_contents, 0x46, 0xa0);

   destination_contents[AO46_COHERENCE_FIRST_OFFSET] = 0x4f;
   destination_contents[AO46_COHERENCE_LAST_OFFSET] = 0x46;
   second_round_trip = ao46_copy_and_wait(queue, destination, private_buffer, source) &&
      ao46_check_byte_pair(source_contents, 0x4f, 0x46);

   printf("AO46_APPLE_AGX_RESOURCE_COHERENCE cpu_to_gpu_to_cpu=%u "
          "gpu_to_cpu_to_gpu=%u bytes=%u\n",
          first_round_trip ? 1u : 0u, second_round_trip ? 1u : 0u,
          AO46_COHERENCE_BYTES);

   [destination release];
   [private_buffer release];
   [source release];
   [queue release];
   [device release];
   return first_round_trip && second_round_trip ? 0 : 1;
}
