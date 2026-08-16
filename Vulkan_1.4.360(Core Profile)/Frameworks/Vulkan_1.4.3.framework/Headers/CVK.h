/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CVK is the public versioned platform ABI, not a second Vulkan engine. */
#define CVK_ABI_VERSION UINT32_C(1)
#define CVK_MAKE_API_VERSION(major, minor, patch) \
   ((((uint32_t)(major) & UINT32_C(0x3ff)) << 22) | \
    (((uint32_t)(minor) & UINT32_C(0x3ff)) << 12) | \
    ((uint32_t)(patch) & UINT32_C(0xfff)))
#define CVK_API_VERSION_1_0 CVK_MAKE_API_VERSION(1, 0, 0)

typedef struct CVKInstance_T *CVKInstance;
typedef struct CVKPhysicalDevice_T *CVKPhysicalDevice;
typedef struct CVKDevice_T *CVKDevice;
typedef struct CVKQueue_T *CVKQueue;
typedef uint64_t CVKSurface;
typedef uint64_t CVKSubmission;

typedef enum CVKError {
   kCVKNoError = 0,
   kCVKErrorInitializationFailed = -1,
   kCVKErrorIncompatibleABI = -2,
   kCVKErrorSurfaceLost = -3,
   kCVKErrorDeviceLost = -4,
} CVKError;

typedef enum CVKSurfaceKind {
   kCVKSurfaceNone = 0,
   kCVKSurfaceAppKitMetalLayer = 1,
   kCVKSurfaceIOSurface = 2,
} CVKSurfaceKind;

/* An AppKit drawable lifecycle snapshot, not a VkSurfaceKHR substitute. */
typedef enum CVKDrawableState {
   kCVKDrawableDetached = 0,
   kCVKDrawableAttached = 1,
} CVKDrawableState;

typedef enum CVKSubmissionState {
   kCVKSubmissionRecorded = 0,
   kCVKSubmissionQueued = 1,
   kCVKSubmissionComplete = 2,
   kCVKSubmissionFailed = 3,
} CVKSubmissionState;

typedef struct CVKInstanceCreateInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   uint32_t requested_api_version;
   uint32_t reserved;
   const char *application_name;
   const char *engine_name;
} CVKInstanceCreateInfo;

typedef struct CVKSurfaceCreateInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   CVKSurfaceKind kind;
   uint32_t reserved;
   const void *native_drawable;
} CVKSurfaceCreateInfo;

/*
 * The public NSVulkan_KHR bridge exports this plain-C snapshot before a real
 * Metal-layer-backed CVK surface exists. No Objective-C object crosses it.
 */
typedef struct CVKSurfaceSnapshot {
   uint32_t structure_size;
   uint32_t abi_version;
   CVKDrawableState state;
   uint32_t drawable_width;
   uint32_t drawable_height;
   float backing_scale_factor;
   uint32_t reserved;
   uint64_t generation;
} CVKSurfaceSnapshot;

typedef struct CVKSubmissionInfo {
   uint32_t structure_size;
   uint32_t abi_version;
   CVKSubmission submission;
   CVKSubmissionState state;
   uint64_t completion_value;
} CVKSubmissionInfo;

#ifdef __cplusplus
}
#endif
