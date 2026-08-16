/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "Vulkan_1.4.3.h"

#include <stddef.h>

_Static_assert(CVK_ABI_VERSION == 1,
               "The initial CVK ABI revision must remain stable");
_Static_assert(sizeof(CVKSurface) == sizeof(uint64_t),
               "CVK surface handles must be fixed width");
_Static_assert(sizeof(CVKSubmission) == sizeof(uint64_t),
               "CVK submission handles must be fixed width");
_Static_assert(offsetof(CVKInstanceCreateInfo, structure_size) == 0,
               "CVK create records must begin with their size");
_Static_assert(offsetof(CVKSurfaceCreateInfo, structure_size) == 0,
               "CVK surface records must begin with their size");
_Static_assert(offsetof(CVKSurfaceSnapshot, structure_size) == 0,
               "CVK surface snapshots must begin with their size");
_Static_assert(offsetof(CVKSubmissionInfo, structure_size) == 0,
               "CVK submission records must begin with their size");

int
main(void)
{
   const CVKInstanceCreateInfo instance = {
      .structure_size = sizeof(instance),
      .abi_version = CVK_ABI_VERSION,
      .requested_api_version = CVK_API_VERSION_1_0,
      .application_name = "AVK143 ABI smoke",
   };
   const CVKSurfaceCreateInfo surface = {
      .structure_size = sizeof(surface),
      .abi_version = CVK_ABI_VERSION,
      .kind = kCVKSurfaceAppKitMetalLayer,
   };
   const CVKSubmissionInfo submission = {
      .structure_size = sizeof(submission),
      .abi_version = CVK_ABI_VERSION,
      .submission = 7,
      .state = kCVKSubmissionRecorded,
   };
   const CVKSurfaceSnapshot snapshot = {
      .structure_size = sizeof(snapshot),
      .abi_version = CVK_ABI_VERSION,
      .state = kCVKDrawableAttached,
      .drawable_width = 64,
      .drawable_height = 32,
      .backing_scale_factor = 1.0f,
      .generation = 1,
   };

   return instance.structure_size == sizeof(instance) &&
                  surface.kind == kCVKSurfaceAppKitMetalLayer &&
                  snapshot.state == kCVKDrawableAttached &&
                  snapshot.generation != 0 &&
                  submission.state == kCVKSubmissionRecorded
             ? 0
             : 1;
}
