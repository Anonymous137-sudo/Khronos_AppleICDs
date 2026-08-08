/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AppleOpenGLAsahi.h"

#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asahi/lib/agx_macos_device.h"
#include "asahi/lib/agx_macos_screen_bootstrap.h"

static pthread_mutex_t apple_opengl_asahi_lock = PTHREAD_MUTEX_INITIALIZER;
static enum AppleOpenGLAsahiBackendState apple_opengl_asahi_state =
   APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED;
static struct agx_macos_device_session apple_opengl_asahi_session;
static bool apple_opengl_asahi_has_session;
static struct agx_macos_screen_bootstrap apple_opengl_asahi_bootstrap;
static bool apple_opengl_asahi_has_bootstrap;

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

uint32_t
AppleOpenGLAsahiContextBlockers(void)
{
   enum AppleOpenGLAsahiBackendState state = AppleOpenGLAsahiInitialize();
   const struct agx_macos_device_session *session =
      AppleOpenGLAsahiGetDeviceSession();

   if (state == APPLE_OPENGL_ASAHI_BACKEND_READY)
      return 0;

   if (!session || session->profile == AGX_MACOS_DEVICE_PROFILE_UNSUPPORTED ||
       session->device.connection == IO_OBJECT_NULL) {
      return APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION;
   }

   return APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY |
          APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION |
          APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION;
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
   if (apple_opengl_asahi_has_bootstrap)
      goto ready;

   if (!apple_opengl_asahi_has_session) {
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
           agx_macos_screen_bootstrap_is_ready(&apple_opengl_asahi_bootstrap);
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return ready;
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

   result = agx_macos_screen_bootstrap_destroy(&apple_opengl_asahi_bootstrap);
   if (result == KERN_SUCCESS)
      apple_opengl_asahi_has_bootstrap = false;
   pthread_mutex_unlock(&apple_opengl_asahi_lock);
   return result;
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
      (void)AppleOpenGLAsahiBootstrapNativeScreen();
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
