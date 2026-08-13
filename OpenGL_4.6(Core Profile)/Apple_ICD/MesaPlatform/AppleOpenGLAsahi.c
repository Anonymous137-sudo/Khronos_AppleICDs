/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleOpenGLAsahi.h"
#include "AppleAGXMetalBOProvider.h"
#include "AppleAGXNativeBridge.h"

#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asahi/lib/agx_macos_device.h"
#include "asahi/lib/agx_macos_mesa_device.h"
#include "asahi/lib/agx_macos_screen_bootstrap.h"

#define APPLE_OPENGL_ASAHI_NATIVE_SCREEN_REQUIREMENTS                      \
   (APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE |                          \
    APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC |                             \
    APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP |                               \
    APPLE_OPENGL_ASAHI_NATIVE_READY_VM_BIND |                              \
    APPLE_OPENGL_ASAHI_NATIVE_READY_SUBMIT |                               \
    APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC |                      \
    APPLE_OPENGL_ASAHI_NATIVE_READY_OBJECT_BINDING |                       \
    APPLE_OPENGL_ASAHI_NATIVE_READY_LOW_VA_BIND |                          \
    APPLE_OPENGL_ASAHI_NATIVE_READY_EXECUTABLE_BO |                        \
    APPLE_OPENGL_ASAHI_NATIVE_READY_SHADER_CODE_ADMISSION)
#define APPLE_OPENGL_ASAHI_PHASE_2_REQUIREMENTS \
   APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION
#define APPLE_OPENGL_ASAHI_PHASE_3_REQUIREMENTS                           \
   (APPLE_OPENGL_ASAHI_PHASE_2_REQUIREMENTS |                             \
    APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE |                         \
    APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC |                            \
    APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP |                              \
    APPLE_OPENGL_ASAHI_NATIVE_READY_FIXED_BO_BIND |                       \
    APPLE_OPENGL_ASAHI_NATIVE_READY_VM_BIND |                             \
    APPLE_OPENGL_ASAHI_NATIVE_READY_LOW_VA_BIND |                         \
    APPLE_OPENGL_ASAHI_NATIVE_READY_EXECUTABLE_BO |                       \
    APPLE_OPENGL_ASAHI_NATIVE_READY_SHADER_CODE_ADMISSION)
#define APPLE_OPENGL_ASAHI_PHASE_4_REQUIREMENTS                           \
   (APPLE_OPENGL_ASAHI_PHASE_2_REQUIREMENTS |                             \
    APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE |                         \
    APPLE_OPENGL_ASAHI_NATIVE_READY_SUBMIT |                              \
    APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC)
#define APPLE_OPENGL_ASAHI_PHASE_5_REQUIREMENTS \
   (APPLE_OPENGL_ASAHI_PHASE_3_REQUIREMENTS | \
    APPLE_OPENGL_ASAHI_PHASE_4_REQUIREMENTS | \
    APPLE_OPENGL_ASAHI_NATIVE_READY_OBJECT_BINDING)
#define APPLE_OPENGL_ASAHI_PHASE_6_REQUIREMENTS \
   (APPLE_OPENGL_ASAHI_PHASE_5_REQUIREMENTS | \
    APPLE_OPENGL_ASAHI_NATIVE_READY_ASAHI_BATCH_EXECUTION)
#define APPLE_OPENGL_ASAHI_PHASE_7_REQUIREMENTS \
   (APPLE_OPENGL_ASAHI_PHASE_6_REQUIREMENTS | \
    APPLE_OPENGL_ASAHI_NATIVE_READY_LIVE_FENCE_RETIREMENT)
#define APPLE_OPENGL_ASAHI_PHASE_8_REQUIREMENTS                           \
   (APPLE_OPENGL_ASAHI_PHASE_7_REQUIREMENTS |                             \
    APPLE_OPENGL_ASAHI_NATIVE_READY_IOSURFACE_DRAWABLE |                  \
    APPLE_OPENGL_ASAHI_NATIVE_READY_PIPE_SCREEN |                         \
    APPLE_OPENGL_ASAHI_NATIVE_READY_PRESENTATION)

static pthread_mutex_t apple_opengl_asahi_lock = PTHREAD_MUTEX_INITIALIZER;
static enum AppleOpenGLAsahiBackendState apple_opengl_asahi_state =
   APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED;
static struct agx_macos_device_session apple_opengl_asahi_session;
static bool apple_opengl_asahi_has_session;
static struct agx_macos_screen_bootstrap apple_opengl_asahi_bootstrap;
static bool apple_opengl_asahi_has_bootstrap;
/* The generic IOGPU device is retained before creating any native bootstrap
 * resources. This is an ownership root only: resource/queue/submit calls stay
 * disabled until their private descriptors are independently validated. */
static struct AppleAGXNativeBridge apple_opengl_asahi_apple_bridge;
static bool apple_opengl_asahi_has_apple_bridge;
static struct AppleAGXMetalBOProvider apple_opengl_asahi_bo_provider;
static bool apple_opengl_asahi_has_bo_provider;
/* This remains private until the native factory can transfer it into Mesa's
 * agx_screen_create_macos. Keeping it under the bootstrap lifecycle prevents
 * a stale BO set from escaping after the profiled AGX session is torn down. */
static struct agx_device apple_opengl_asahi_mesa_device;
static bool apple_opengl_asahi_has_mesa_device;

static bool
apple_opengl_asahi_apple_bridge_is_current_locked(void)
{
   return apple_opengl_asahi_has_session &&
          apple_opengl_asahi_has_apple_bridge &&
          AppleAGXNativeBridgeIsCurrent(&apple_opengl_asahi_apple_bridge,
                                        &apple_opengl_asahi_session);
}

static kern_return_t
apple_opengl_asahi_copy_native_drawable_info_locked(
   struct AppleOpenGLAsahiNativeDrawableInfo *out_info)
{
   const struct agx_macos_iosurface *drawable;
   struct agx_macos_iosurface_snapshot snapshot;

   *out_info = (struct AppleOpenGLAsahiNativeDrawableInfo){0};
   if (!apple_opengl_asahi_has_bootstrap ||
       !apple_opengl_asahi_apple_bridge_is_current_locked() ||
       !agx_macos_screen_bootstrap_is_ready(&apple_opengl_asahi_bootstrap)) {
      return kIOReturnNotReady;
   }

   drawable = &apple_opengl_asahi_bootstrap.offscreen;
   if (!agx_macos_iosurface_capture_presentable_snapshot(drawable,
                                                          &snapshot)) {
      return kIOReturnBusy;
   }

   *out_info = (struct AppleOpenGLAsahiNativeDrawableInfo){
      .iosurface_id = snapshot.token.id,
      .width = snapshot.width,
      .height = snapshot.height,
      .bytes_per_row = snapshot.bytes_per_row,
      .pixel_format = snapshot.pixel_format,
      .generation = snapshot.token.generation,
   };
   return KERN_SUCCESS;
}

static char *
apple_opengl_asahi_executable_path(void)
{
   uint32_t size = 0;
   char *path;

   if (_NSGetExecutablePath(NULL, &size) != -1 || size == 0)
      return NULL;

   path = malloc(size);
   if (!path || _NSGetExecutablePath(path, &size) != 0) {
      free(path);
      return NULL;
   }

   return path;
}

enum AppleOpenGLAsahiBackendState
AppleOpenGLAsahiInitialize(void)
{
   enum agx_macos_device_session_status session_status;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (apple_opengl_asahi_state != APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED)
      goto out;

   session_status = agx_macos_device_session_open(&apple_opengl_asahi_session);
   if (session_status == AGX_MACOS_DEVICE_SESSION_NO_DEVICE) {
      apple_opengl_asahi_state = APPLE_OPENGL_ASAHI_BACKEND_NO_DEVICE;
      goto out;
   }

   if (session_status != AGX_MACOS_DEVICE_SESSION_READY) {
      apple_opengl_asahi_state = APPLE_OPENGL_ASAHI_BACKEND_UNSUPPORTED_DEVICE;
      goto out;
   }

   /* Direct BO and notification-queue primitives are trace-validated, but a
    * Mesa screen factory, submit sidecar ABI, and presentation path are not.
    * Do not fall back silently. */
   apple_opengl_asahi_state = APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE;
   apple_opengl_asahi_has_session = true;

out:
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return apple_opengl_asahi_state;
}

const struct agx_macos_device_session *
AppleOpenGLAsahiGetDeviceSession(void)
{
   const struct agx_macos_device_session *session = NULL;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (apple_opengl_asahi_has_session)
      session = &apple_opengl_asahi_session;
   pthread_mutex_unlock(&apple_opengl_asahi_lock);

   return session;
}

static uint32_t
apple_opengl_asahi_native_screen_readiness_locked(void)
{
   uint32_t readiness = 0;
   uint32_t capabilities;

   if (apple_opengl_asahi_has_session &&
       agx_macos_device_session_is_open(&apple_opengl_asahi_session)) {
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION;
   }

   if (!apple_opengl_asahi_apple_bridge_is_current_locked())
      return readiness;

   readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_APPLE_BRIDGE;
   if (!apple_opengl_asahi_has_bootstrap ||
       !agx_macos_screen_bootstrap_is_ready(&apple_opengl_asahi_bootstrap)) {
      return readiness;
   }

   readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_BOOTSTRAP |
                APPLE_OPENGL_ASAHI_NATIVE_READY_IOSURFACE_DRAWABLE;
   if (!apple_opengl_asahi_has_mesa_device ||
       !apple_opengl_asahi_has_bo_provider ||
       !AppleAGXMetalBOProviderIsCurrent(&apple_opengl_asahi_bo_provider) ||
       !agx_macos_mesa_device_is_current(&apple_opengl_asahi_mesa_device)) {
      return readiness;
   }

   readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE;
   capabilities =
      agx_macos_mesa_device_capabilities(&apple_opengl_asahi_mesa_device);
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_BO_ALLOC)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_BO_MAP)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_FIXED_BO_BIND)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_FIXED_BO_BIND;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_VM_BIND)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_VM_BIND;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_SUBMIT)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_SUBMIT;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_COMPLETION_SYNC)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_OBJECT_BIND)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_OBJECT_BINDING;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_LOW_VA_BIND)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_LOW_VA_BIND;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_EXECUTABLE_BO)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_EXECUTABLE_BO;
   if (capabilities & AGX_MACOS_MESA_DEVICE_CAP_SHADER_CODE_ADMISSION)
      readiness |= APPLE_OPENGL_ASAHI_NATIVE_READY_SHADER_CODE_ADMISSION;

   return readiness;
}

uint32_t
AppleOpenGLAsahiNativeScreenReadiness(void)
{
   uint32_t readiness;

   (void)AppleOpenGLAsahiInitialize();
   pthread_mutex_lock(&apple_opengl_asahi_lock);
   readiness = apple_opengl_asahi_native_screen_readiness_locked();
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return readiness;
}

static uint32_t
apple_opengl_asahi_phase_requirements(enum AppleOpenGLAsahiNativePhase phase)
{
   switch (phase) {
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION:
      return APPLE_OPENGL_ASAHI_PHASE_2_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_BO_AND_VM:
      return APPLE_OPENGL_ASAHI_PHASE_3_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_QUEUE:
      return APPLE_OPENGL_ASAHI_PHASE_4_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_CARRIER_AND_RESOURCES:
      return APPLE_OPENGL_ASAHI_PHASE_5_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_ASAHI_BATCH_SUBMIT:
      return APPLE_OPENGL_ASAHI_PHASE_6_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_FENCE_RETIREMENT:
      return APPLE_OPENGL_ASAHI_PHASE_7_REQUIREMENTS;
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_PIPE_SCREEN_AND_PRESENTATION:
      return APPLE_OPENGL_ASAHI_PHASE_8_REQUIREMENTS;
   }

   return 0;
}

bool
AppleOpenGLAsahiGetNativePhaseStatus(
   enum AppleOpenGLAsahiNativePhase phase,
   struct AppleOpenGLAsahiNativePhaseStatus *out_status)
{
   uint32_t requirements;
   uint32_t readiness;

   if (!out_status)
      return false;

   requirements = apple_opengl_asahi_phase_requirements(phase);
   if (requirements == 0) {
      *out_status = (struct AppleOpenGLAsahiNativePhaseStatus){0};
      return false;
   }

   readiness = AppleOpenGLAsahiNativeScreenReadiness();
   *out_status = (struct AppleOpenGLAsahiNativePhaseStatus){
      .readiness = readiness,
      .required_readiness = requirements,
      .missing_readiness = requirements & ~readiness,
      .progress = (readiness & requirements) == requirements
         ? APPLE_OPENGL_ASAHI_NATIVE_PHASE_COMPLETE
         : readiness != 0 ? APPLE_OPENGL_ASAHI_NATIVE_PHASE_PARTIAL
                          : APPLE_OPENGL_ASAHI_NATIVE_PHASE_UNAVAILABLE,
   };
   return true;
}

const char *
AppleOpenGLAsahiNativePhaseName(enum AppleOpenGLAsahiNativePhase phase)
{
   switch (phase) {
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION:
      return "device-session";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_BO_AND_VM:
      return "bo-and-vm";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_QUEUE:
      return "native-queue";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_CARRIER_AND_RESOURCES:
      return "carrier-and-resources";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_ASAHI_BATCH_SUBMIT:
      return "asahi-batch-submit";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_FENCE_RETIREMENT:
      return "fence-retirement";
   case APPLE_OPENGL_ASAHI_NATIVE_PHASE_PIPE_SCREEN_AND_PRESENTATION:
      return "pipe-screen-and-presentation";
   }

   return "invalid";
}

uint32_t
AppleOpenGLAsahiContextBlockers(void)
{
   (void)AppleOpenGLAsahiInitialize();
   const uint32_t readiness = AppleOpenGLAsahiNativeScreenReadiness();
   const uint32_t screen_requirements =
      APPLE_OPENGL_ASAHI_NATIVE_SCREEN_REQUIREMENTS;
   uint32_t blockers = APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION;

   if (!(readiness & APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION))
      return APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION;

   if ((readiness & screen_requirements) != screen_requirements)
      blockers |= APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY;
   if (!(readiness & APPLE_OPENGL_ASAHI_NATIVE_READY_SUBMIT))
      blockers |= APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION;

   /* IOSurface ownership is ready before a CAMetalLayer/WindowServer present
    * path exists, so it remains an independent framework blocker. */
   return blockers;
}

const char *
AppleOpenGLAsahiContextBlockerName(uint32_t blocker)
{
   switch (blocker) {
   case APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION:
      return "profiled-agx-session";
   case APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY:
      return "macos-pipe-screen";
   case APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION:
      return "validated-agx-submission";
   case APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION:
      return "iosurface-presentation";
   }

   return "unknown";
}

const char *
AppleOpenGLAsahiBackendStateName(enum AppleOpenGLAsahiBackendState state)
{
   switch (state) {
   case APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED:
      return "uninitialized";
   case APPLE_OPENGL_ASAHI_BACKEND_NO_DEVICE:
      return "no-agx-device";
   case APPLE_OPENGL_ASAHI_BACKEND_UNSUPPORTED_DEVICE:
      return "unsupported-agx-device";
   case APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE:
      return "macos-winsys-incomplete";
   case APPLE_OPENGL_ASAHI_BACKEND_READY:
      return "ready";
   }

   return "invalid";
}

bool
AppleOpenGLAsahiCoreProfileRequestIsInRange(unsigned major, unsigned minor)
{
   return (major == 3 && minor >= 2 && minor <= 3) ||
          (major == 4 && minor <= 6);
}

bool
AppleOpenGLAsahiBootstrapNativeScreen(void)
{
   char *client_path = NULL;
   kern_return_t result = KERN_SUCCESS;

   if (AppleOpenGLAsahiInitialize() !=
       APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
      return false;
   }

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (apple_opengl_asahi_has_bootstrap &&
       apple_opengl_asahi_apple_bridge_is_current_locked())
      goto ready;
   if (apple_opengl_asahi_has_bootstrap) {
      pthread_mutex_unlock(&apple_opengl_asahi_lock);
      free(client_path);
      return false;
   }

   if (!apple_opengl_asahi_has_session) {
      result = kIOReturnNotOpen;
      goto fail;
   }

   if (!agx_macos_device_session_is_open(&apple_opengl_asahi_session)) {
      result = kIOReturnNotOpen;
      goto fail;
   }

   if (!apple_opengl_asahi_session.api_configured) {
      client_path = apple_opengl_asahi_executable_path();
      if (!client_path) {
         result = kIOReturnNoResources;
         goto fail;
      }

      result = agx_macos_device_session_configure_traced_api(
         &apple_opengl_asahi_session, client_path);
      if (result != KERN_SUCCESS)
         goto fail;
   }

   if (!apple_opengl_asahi_has_apple_bridge) {
      if (!AppleAGXNativeBridgeOpen(&apple_opengl_asahi_apple_bridge,
                                    &apple_opengl_asahi_session)) {
         result = kIOReturnUnsupported;
         goto fail;
      }
      apple_opengl_asahi_has_apple_bridge = true;
   }

   result = agx_macos_screen_bootstrap_init(&apple_opengl_asahi_session, 1, 1,
                                             &apple_opengl_asahi_bootstrap);
   if (result != KERN_SUCCESS)
      goto fail;

   apple_opengl_asahi_has_bootstrap = true;
ready:
   free(client_path);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return true;

fail:
   if (apple_opengl_asahi_has_apple_bridge) {
      AppleAGXNativeBridgeClose(&apple_opengl_asahi_apple_bridge);
      apple_opengl_asahi_has_apple_bridge = false;
   }
   fprintf(stderr, "[OpenGL_4.6] native AGX screen bootstrap failed: %#x\n",
           result);
   free(client_path);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return false;
}

bool
AppleOpenGLAsahiNativeScreenBootstrapIsReady(void)
{
   bool ready;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   ready = apple_opengl_asahi_has_bootstrap &&
           apple_opengl_asahi_apple_bridge_is_current_locked() &&
           agx_macos_screen_bootstrap_is_ready(&apple_opengl_asahi_bootstrap);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return ready;
}

bool
AppleOpenGLAsahiBootstrapMesaDevice(void)
{
   bool ready = false;

   if (!AppleOpenGLAsahiBootstrapNativeScreen())
      return false;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (apple_opengl_asahi_has_mesa_device &&
       apple_opengl_asahi_has_bo_provider &&
       AppleAGXMetalBOProviderIsCurrent(&apple_opengl_asahi_bo_provider) &&
       agx_macos_mesa_device_is_current(&apple_opengl_asahi_mesa_device)) {
      ready = true;
      goto out;
   }

   if (apple_opengl_asahi_has_mesa_device) {
      if (!agx_macos_mesa_device_destroy(&apple_opengl_asahi_mesa_device))
         goto out;
      apple_opengl_asahi_has_mesa_device = false;
   }
   if (apple_opengl_asahi_has_bo_provider) {
      AppleAGXMetalBOProviderDestroy(&apple_opengl_asahi_bo_provider);
      apple_opengl_asahi_has_bo_provider = false;
   }

   if (!apple_opengl_asahi_has_bootstrap ||
       !apple_opengl_asahi_apple_bridge_is_current_locked() ||
       !agx_macos_screen_bootstrap_is_ready(&apple_opengl_asahi_bootstrap)) {
      goto out;
   }

   ready = agx_macos_mesa_device_init(
      &apple_opengl_asahi_mesa_device, &apple_opengl_asahi_session,
      &apple_opengl_asahi_bootstrap.bo_set,
      &apple_opengl_asahi_bootstrap.notification_queue);
   if (ready) {
      ready = AppleAGXMetalBOProviderInit(
                 &apple_opengl_asahi_bo_provider,
                 &apple_opengl_asahi_apple_bridge,
                 &apple_opengl_asahi_session) &&
              agx_macos_mesa_device_attach_bo_provider(
                 &apple_opengl_asahi_mesa_device,
                 AppleAGXMetalBOProviderMesaProvider(
                    &apple_opengl_asahi_bo_provider));
      apple_opengl_asahi_has_bo_provider = ready;
      if (!ready) {
         AppleAGXMetalBOProviderDestroy(&apple_opengl_asahi_bo_provider);
         (void)agx_macos_mesa_device_destroy(&apple_opengl_asahi_mesa_device);
      }
   }
   apple_opengl_asahi_has_mesa_device = ready;

out:
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return ready;
}

bool
AppleOpenGLAsahiNativeMesaDeviceIsCurrent(void)
{
   bool current;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   current = apple_opengl_asahi_apple_bridge_is_current_locked() &&
      apple_opengl_asahi_has_bo_provider &&
      AppleAGXMetalBOProviderIsCurrent(&apple_opengl_asahi_bo_provider) &&
      apple_opengl_asahi_has_mesa_device &&
      agx_macos_mesa_device_is_current(&apple_opengl_asahi_mesa_device);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return current;
}

uint32_t
AppleOpenGLAsahiNativeMesaDeviceCapabilities(void)
{
   uint32_t capabilities = 0;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (apple_opengl_asahi_apple_bridge_is_current_locked() &&
       apple_opengl_asahi_has_mesa_device) {
      capabilities =
         agx_macos_mesa_device_capabilities(&apple_opengl_asahi_mesa_device);
   }
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return capabilities;
}

kern_return_t
AppleOpenGLAsahiDestroyNativeScreenBootstrap(void)
{
   kern_return_t result;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (!apple_opengl_asahi_has_bootstrap) {
      pthread_mutex_unlock(&apple_opengl_asahi_lock);
      return kIOReturnBadArgument;
   }

   /* agx_device references the bootstrap BO set, so it must be released
    * before the bootstrap invalidates that set. No device pointer is exposed
    * until a complete native screen can assume ownership. */
   if (apple_opengl_asahi_has_mesa_device) {
      if (!agx_macos_mesa_device_destroy(&apple_opengl_asahi_mesa_device)) {
         pthread_mutex_unlock(&apple_opengl_asahi_lock);
         return kIOReturnBusy;
      }
      apple_opengl_asahi_has_mesa_device = false;
   }
   if (apple_opengl_asahi_has_bo_provider) {
      AppleAGXMetalBOProviderDestroy(&apple_opengl_asahi_bo_provider);
      apple_opengl_asahi_has_bo_provider = false;
   }

   result = agx_macos_screen_bootstrap_destroy(&apple_opengl_asahi_bootstrap);
   if (result == KERN_SUCCESS) {
      apple_opengl_asahi_has_bootstrap = false;
      if (apple_opengl_asahi_has_apple_bridge) {
         AppleAGXNativeBridgeClose(&apple_opengl_asahi_apple_bridge);
         apple_opengl_asahi_has_apple_bridge = false;
      }
   }
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return result;
}

kern_return_t
AppleOpenGLAsahiResizeNativeDrawable(uint32_t width, uint32_t height)
{
   kern_return_t result;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   if (!apple_opengl_asahi_has_bootstrap ||
       !apple_opengl_asahi_apple_bridge_is_current_locked()) {
      pthread_mutex_unlock(&apple_opengl_asahi_lock);
      return kIOReturnNotReady;
   }

   result = agx_macos_screen_bootstrap_resize_offscreen(
      &apple_opengl_asahi_bootstrap, width, height);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return result;
}

kern_return_t
AppleOpenGLAsahiCopyNativeDrawableInfo(
   struct AppleOpenGLAsahiNativeDrawableInfo *out_info)
{
   kern_return_t result;

   if (!out_info)
      return kIOReturnBadArgument;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   result = apple_opengl_asahi_copy_native_drawable_info_locked(out_info);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return result;
}

kern_return_t
AppleOpenGLAsahiAcquireNativeDrawableLease(
   struct AppleOpenGLAsahiNativeDrawableLease *out_lease)
{
   kern_return_t result;

   if (!out_lease || out_lease->winsys.active || out_lease->winsys.surface)
      return kIOReturnBadArgument;

   *out_lease = (struct AppleOpenGLAsahiNativeDrawableLease){0};
   pthread_mutex_lock(&apple_opengl_asahi_lock);
   result = apple_opengl_asahi_has_bootstrap &&
            apple_opengl_asahi_apple_bridge_is_current_locked()
      ? agx_macos_screen_bootstrap_acquire_offscreen_lease(
           &apple_opengl_asahi_bootstrap, &out_lease->winsys)
      : kIOReturnNotReady;
   if (result == KERN_SUCCESS) {
      out_lease->info = (struct AppleOpenGLAsahiNativeDrawableInfo){
         .iosurface_id = out_lease->winsys.token.id,
         .width = out_lease->winsys.width,
         .height = out_lease->winsys.height,
         .bytes_per_row = out_lease->winsys.bytes_per_row,
         .pixel_format = out_lease->winsys.pixel_format,
         .generation = out_lease->winsys.token.generation,
      };
   }
   if (result != KERN_SUCCESS)
      agx_macos_iosurface_release_lease(&out_lease->winsys);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return result;
}

bool
AppleOpenGLAsahiNativeDrawableLeaseIsCurrent(
   const struct AppleOpenGLAsahiNativeDrawableLease *lease)
{
   bool current;

   if (!lease || !lease->winsys.active || !lease->winsys.surface)
      return false;

   pthread_mutex_lock(&apple_opengl_asahi_lock);
   current = agx_macos_screen_bootstrap_offscreen_lease_is_current(
      &apple_opengl_asahi_bootstrap, &lease->winsys);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return current;
}

void
AppleOpenGLAsahiReleaseNativeDrawableLease(
   struct AppleOpenGLAsahiNativeDrawableLease *lease)
{
   if (!lease)
      return;

   agx_macos_iosurface_release_lease(&lease->winsys);
   *lease = (struct AppleOpenGLAsahiNativeDrawableLease){0};
}

bool
AppleOpenGLAsahiCanCreateCoreProfile(unsigned major, unsigned minor)
{
   return AppleOpenGLAsahiCoreProfileRequestIsInRange(major, minor) &&
          AppleOpenGLAsahiContextBlockers() == 0;
}

bool
AppleOpenGLAsahiCanPresentWindow(void)
{
   return AppleOpenGLAsahiContextBlockers() == 0;
}

struct pipe_screen *
AppleOpenGLAsahiCreateScreen(void)
{
   enum AppleOpenGLAsahiBackendState state = AppleOpenGLAsahiInitialize();
   uint32_t blockers;
   const char *enable_native_bootstrap =
      getenv("AO46_ENABLE_NATIVE_SCREEN_BOOTSTRAP");

   if (state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE &&
       enable_native_bootstrap && strcmp(enable_native_bootstrap, "1") == 0) {
      (void)AppleOpenGLAsahiBootstrapMesaDevice();
   }

   /* Bootstrap is allowed to add native prerequisites. Always make the
    * admission decision from the post-bootstrap state. */
   blockers = AppleOpenGLAsahiContextBlockers();
   if (blockers != 0) {
      uint32_t primary = blockers & APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION
                            ? APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION
                            : APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY;

      fprintf(stderr,
              "[OpenGL_4.6] Mesa Asahi screen unavailable: %s (state=%s, "
              "blockers=%#x)\n",
              AppleOpenGLAsahiContextBlockerName(primary),
              AppleOpenGLAsahiBackendStateName(state), blockers);
      return NULL;
   }

   /* READY may only be set by a native factory that replaces this guard. */
   fputs("[OpenGL_4.6] native screen factory has no implementation\n", stderr);
   return NULL;
}
