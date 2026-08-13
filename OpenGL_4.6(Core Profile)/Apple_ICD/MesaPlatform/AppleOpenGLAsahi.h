/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <mach/kern_return.h>

#include "asahi/lib/agx_macos_iosurface.h"

struct pipe_screen;
struct agx_macos_device_session;

/* A copied, generation-tagged IOSurface description for the future native
 * Mesa screen factory. It intentionally does not expose or retain an
 * IOSurfaceRef across framework resize or destruction. */
struct AppleOpenGLAsahiNativeDrawableInfo {
   uint32_t iosurface_id;
   uint32_t width;
   uint32_t height;
   uint32_t bytes_per_row;
   uint32_t pixel_format;
   uint64_t generation;
};

/* Owns a retained IOSurface for a native Mesa screen or drawable consumer.
 * Resizing does not invalidate the retained memory, but makes the generation
 * stale so the consumer must acquire the replacement before presenting. */
struct AppleOpenGLAsahiNativeDrawableLease {
   struct agx_macos_iosurface_lease winsys;
   struct AppleOpenGLAsahiNativeDrawableInfo info;
};

enum AppleOpenGLAsahiBackendState {
   APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED = 0,
   APPLE_OPENGL_ASAHI_BACKEND_NO_DEVICE,
   APPLE_OPENGL_ASAHI_BACKEND_UNSUPPORTED_DEVICE,
   APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE,
   APPLE_OPENGL_ASAHI_BACKEND_READY,
};

enum AppleOpenGLAsahiContextBlocker {
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION = 1u << 0,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY = 1u << 1,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION = 1u << 2,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION = 1u << 3,
};

/* This reports concrete native prerequisites owned by the framework. It is
 * diagnostic state only; none of these bits claim that a pipe_screen or GL
 * context has been created. */
enum AppleOpenGLAsahiNativeScreenReadiness {
   APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION = 1u << 0,
   APPLE_OPENGL_ASAHI_NATIVE_READY_APPLE_BRIDGE = 1u << 1,
   APPLE_OPENGL_ASAHI_NATIVE_READY_BOOTSTRAP = 1u << 2,
   APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE = 1u << 3,
   APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC = 1u << 4,
   APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP = 1u << 5,
   APPLE_OPENGL_ASAHI_NATIVE_READY_FIXED_BO_BIND = 1u << 6,
   APPLE_OPENGL_ASAHI_NATIVE_READY_VM_BIND = 1u << 7,
   APPLE_OPENGL_ASAHI_NATIVE_READY_SUBMIT = 1u << 8,
   APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC = 1u << 9,
   APPLE_OPENGL_ASAHI_NATIVE_READY_IOSURFACE_DRAWABLE = 1u << 10,
   APPLE_OPENGL_ASAHI_NATIVE_READY_PIPE_SCREEN = 1u << 11,
   APPLE_OPENGL_ASAHI_NATIVE_READY_PRESENTATION = 1u << 12,
   APPLE_OPENGL_ASAHI_NATIVE_READY_ASAHI_BATCH_EXECUTION = 1u << 13,
   APPLE_OPENGL_ASAHI_NATIVE_READY_LIVE_FENCE_RETIREMENT = 1u << 14,
   APPLE_OPENGL_ASAHI_NATIVE_READY_OBJECT_BINDING = 1u << 15,
   APPLE_OPENGL_ASAHI_NATIVE_READY_LOW_VA_BIND = 1u << 16,
   APPLE_OPENGL_ASAHI_NATIVE_READY_EXECUTABLE_BO = 1u << 17,
   APPLE_OPENGL_ASAHI_NATIVE_READY_SHADER_CODE_ADMISSION = 1u << 18,
};

/* These states are an engineering completion gate, not an advertised GL
 * version. A phase is complete only after its native exit requirements are
 * present in the active framework instance. */
enum AppleOpenGLAsahiNativePhase {
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION = 2,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_BO_AND_VM = 3,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_QUEUE = 4,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_CARRIER_AND_RESOURCES = 5,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_ASAHI_BATCH_SUBMIT = 6,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_FENCE_RETIREMENT = 7,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_PIPE_SCREEN_AND_PRESENTATION = 8,
};

enum AppleOpenGLAsahiNativePhaseProgress {
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_UNAVAILABLE = 0,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_PARTIAL,
   APPLE_OPENGL_ASAHI_NATIVE_PHASE_COMPLETE,
};

struct AppleOpenGLAsahiNativePhaseStatus {
   uint32_t readiness;
   uint32_t required_readiness;
   uint32_t missing_readiness;
   enum AppleOpenGLAsahiNativePhaseProgress progress;
};

enum AppleOpenGLAsahiBackendState AppleOpenGLAsahiInitialize(void);
const char *AppleOpenGLAsahiBackendStateName(
   enum AppleOpenGLAsahiBackendState state);
const struct agx_macos_device_session *AppleOpenGLAsahiGetDeviceSession(void);
uint32_t AppleOpenGLAsahiNativeScreenReadiness(void);
bool AppleOpenGLAsahiGetNativePhaseStatus(
   enum AppleOpenGLAsahiNativePhase phase,
   struct AppleOpenGLAsahiNativePhaseStatus *out_status);
const char *AppleOpenGLAsahiNativePhaseName(
   enum AppleOpenGLAsahiNativePhase phase);
/* A zero mask permits screen creation. AO46 never lowers a request to a
 * fallback backend when any native prerequisite is still missing. */
uint32_t AppleOpenGLAsahiContextBlockers(void);
const char *AppleOpenGLAsahiContextBlockerName(uint32_t blocker);
/* Checks only whether AO46's core-profile request is in its supported API
 * range. It does not imply native winsys readiness or expose a GL version. */
bool AppleOpenGLAsahiCoreProfileRequestIsInRange(unsigned major,
                                                 unsigned minor);
/* Creates the native AGX screen ownership root for WIP diagnostics. It does
 * not create a Mesa pipe_screen or expose a GL context. */
bool AppleOpenGLAsahiBootstrapNativeScreen(void);
bool AppleOpenGLAsahiNativeScreenBootstrapIsReady(void);
/* Creates the private Mesa agx_device from the trace-validated native BO
 * path. This is diagnostic lifecycle coverage only: generic VM binding,
 * submission, and completion sync remain unavailable, so it cannot create a
 * pipe_screen or expose a context. */
bool AppleOpenGLAsahiBootstrapMesaDevice(void);
bool AppleOpenGLAsahiNativeMesaDeviceIsCurrent(void);
uint32_t AppleOpenGLAsahiNativeMesaDeviceCapabilities(void);
kern_return_t AppleOpenGLAsahiDestroyNativeScreenBootstrap(void);
/* Resizes the native bootstrap drawable. This never creates a Mesa screen or
 * makes a core-profile context admissible. */
kern_return_t AppleOpenGLAsahiResizeNativeDrawable(uint32_t width,
                                                   uint32_t height);
/* Copies the current, unlocked bootstrap drawable identity. The caller must
 * compare generation after asynchronous work; a resize makes old snapshots
 * stale. This does not make a Mesa context or presentation available. */
kern_return_t AppleOpenGLAsahiCopyNativeDrawableInfo(
   struct AppleOpenGLAsahiNativeDrawableInfo *out_info);
/* Acquires the current unlocked bootstrap IOSurface. The caller owns the
 * lease until release and must re-check it after asynchronous work or resize. */
kern_return_t AppleOpenGLAsahiAcquireNativeDrawableLease(
   struct AppleOpenGLAsahiNativeDrawableLease *out_lease);
bool AppleOpenGLAsahiNativeDrawableLeaseIsCurrent(
   const struct AppleOpenGLAsahiNativeDrawableLease *lease);
void AppleOpenGLAsahiReleaseNativeDrawableLease(
   struct AppleOpenGLAsahiNativeDrawableLease *lease);
bool AppleOpenGLAsahiCanCreateCoreProfile(unsigned major, unsigned minor);
bool AppleOpenGLAsahiCanPresentWindow(void);
struct pipe_screen *AppleOpenGLAsahiCreateScreen(void);
