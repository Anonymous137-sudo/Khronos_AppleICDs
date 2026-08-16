/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CVK is a versioned platform ABI, not a second Vulkan object implementation. */
#define AVK143_CVK_ABI_VERSION UINT32_C(1)
#define AVK143_CVK_MAKE_API_VERSION(major, minor, patch) \
   ((((uint32_t)(major) & UINT32_C(0x3ff)) << 22) | \
    (((uint32_t)(minor) & UINT32_C(0x3ff)) << 12) | \
    ((uint32_t)(patch) & UINT32_C(0xfff)))
#define AVK143_CVK_API_VERSION_1_0 AVK143_CVK_MAKE_API_VERSION(1, 0, 0)

typedef struct AVK143CVKInstance_T *AVK143CVKInstance;
typedef struct AVK143CVKPhysicalDevice_T *AVK143CVKPhysicalDevice;
typedef struct AVK143CVKDevice_T *AVK143CVKDevice;
typedef struct AVK143CVKQueue_T *AVK143CVKQueue;
typedef uint64_t AVK143CVKSurface;
typedef uint64_t AVK143CVKSubmission;

enum AVK143CVKStatus {
   AVK143_CVK_SUCCESS = 0,
   AVK143_CVK_ERROR_INITIALIZATION_FAILED = -1,
   AVK143_CVK_ERROR_INCOMPATIBLE_ABI = -2,
   AVK143_CVK_ERROR_SURFACE_LOST = -3,
   AVK143_CVK_ERROR_DEVICE_LOST = -4,
};

enum AVK143CVKSurfaceKind {
   AVK143_CVK_SURFACE_NONE = 0,
   AVK143_CVK_SURFACE_APPKIT_METAL_LAYER = 1,
   AVK143_CVK_SURFACE_IOSURFACE = 2,
};

/* An AppKit drawable lifecycle snapshot, not a VkSurfaceKHR substitute. */
enum AVK143CVKDrawableState {
   AVK143_CVK_DRAWABLE_DETACHED = 0,
   AVK143_CVK_DRAWABLE_ATTACHED = 1,
};

enum AVK143CVKSubmissionState {
   AVK143_CVK_SUBMISSION_RECORDED = 0,
   AVK143_CVK_SUBMISSION_QUEUED = 1,
   AVK143_CVK_SUBMISSION_COMPLETE = 2,
   AVK143_CVK_SUBMISSION_FAILED = 3,
};

struct AVK143CVKInstanceCreateInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   uint32_t requested_api_version;
   uint32_t reserved;
   const char *application_name;
   const char *engine_name;
};

struct AVK143CVKSurfaceCreateInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   enum AVK143CVKSurfaceKind kind;
   uint32_t reserved;
   const void *native_drawable;
};

/*
 * The public NSVulkan_KHR bridge exports this plain-C snapshot before a real
 * Metal-layer-backed CVK surface exists. No Objective-C object crosses it.
 */
struct AVK143CVKSurfaceSnapshot {
   uint32_t structure_size;
   uint32_t abi_version;
   enum AVK143CVKDrawableState state;
   uint32_t drawable_width;
   uint32_t drawable_height;
   float backing_scale_factor;
   uint32_t reserved;
   uint64_t generation;
};

struct AVK143CVKSubmissionInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   AVK143CVKSubmission submission;
   enum AVK143CVKSubmissionState state;
   uint64_t completion_value;
};

#ifdef __cplusplus
}
#endif
