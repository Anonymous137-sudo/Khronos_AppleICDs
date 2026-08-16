/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "Vulkan_1.4.3.h"

#include <stddef.h>

_Static_assert(AVK143_CVK_ABI_VERSION == 1,
               "The initial CVK ABI revision must remain stable");
_Static_assert(sizeof(AVK143CVKSurface) == sizeof(uint64_t),
               "CVK surface handles must be fixed width");
_Static_assert(sizeof(AVK143CVKSubmission) == sizeof(uint64_t),
               "CVK submission handles must be fixed width");
_Static_assert(offsetof(struct AVK143CVKInstanceCreateInfo, structure_size) == 0,
               "CVK create records must begin with their size");
_Static_assert(offsetof(struct AVK143CVKSurfaceCreateInfo, structure_size) == 0,
               "CVK surface records must begin with their size");
_Static_assert(offsetof(struct AVK143CVKSurfaceSnapshot, structure_size) == 0,
               "CVK surface snapshots must begin with their size");
_Static_assert(offsetof(struct AVK143CVKSubmissionInfo, structure_size) == 0,
               "CVK submission records must begin with their size");

int
main(void)
{
   const struct AVK143CVKInstanceCreateInfo instance = {
      .structure_size = sizeof(instance),
      .abi_version = AVK143_CVK_ABI_VERSION,
      .requested_api_version = AVK143_CVK_API_VERSION_1_0,
      .application_name = "AVK143 ABI smoke",
   };
   const struct AVK143CVKSurfaceCreateInfo surface = {
      .structure_size = sizeof(surface),
      .abi_version = AVK143_CVK_ABI_VERSION,
      .kind = AVK143_CVK_SURFACE_APPKIT_METAL_LAYER,
   };
   const struct AVK143CVKSubmissionInfo submission = {
      .structure_size = sizeof(submission),
      .abi_version = AVK143_CVK_ABI_VERSION,
      .submission = 7,
      .state = AVK143_CVK_SUBMISSION_RECORDED,
   };
   const struct AVK143CVKSurfaceSnapshot snapshot = {
      .structure_size = sizeof(snapshot),
      .abi_version = AVK143_CVK_ABI_VERSION,
      .state = AVK143_CVK_DRAWABLE_ATTACHED,
      .drawable_width = 64,
      .drawable_height = 32,
      .backing_scale_factor = 1.0f,
      .generation = 1,
   };

   return instance.structure_size == sizeof(instance) &&
                  surface.kind == AVK143_CVK_SURFACE_APPKIT_METAL_LAYER &&
                  snapshot.state == AVK143_CVK_DRAWABLE_ATTACHED &&
                  snapshot.generation != 0 &&
                  submission.state == AVK143_CVK_SUBMISSION_RECORDED
             ? 0
             : 1;
}
