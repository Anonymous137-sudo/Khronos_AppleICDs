#include "AppleOpenGLAsahi.h"
#include "asahi/lib/agx_macos_device.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(void)
{
   const char *exercise_native_bootstrap =
      getenv("AO46_EXERCISE_NATIVE_SCREEN_BOOTSTRAP");
   const char *enable_native_bootstrap =
      getenv("AO46_ENABLE_NATIVE_SCREEN_BOOTSTRAP");
   enum AppleOpenGLAsahiBackendState state = AppleOpenGLAsahiInitialize();
   const struct agx_macos_device_session *session =
      AppleOpenGLAsahiGetDeviceSession();
   uint32_t blockers = AppleOpenGLAsahiContextBlockers();

   if (state == APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED) {
       fprintf(stderr, "unexpected native Asahi backend state: %s\n",
               AppleOpenGLAsahiBackendStateName(state));
       return 1;
   }

   if (!AppleOpenGLAsahiCoreProfileRequestIsInRange(3, 2) ||
       !AppleOpenGLAsahiCoreProfileRequestIsInRange(3, 3) ||
       !AppleOpenGLAsahiCoreProfileRequestIsInRange(4, 6) ||
       AppleOpenGLAsahiCoreProfileRequestIsInRange(3, 1) ||
       AppleOpenGLAsahiCoreProfileRequestIsInRange(3, 4) ||
       AppleOpenGLAsahiCoreProfileRequestIsInRange(4, 7) ||
       AppleOpenGLAsahiCoreProfileRequestIsInRange(5, 0)) {
      fputs("core-profile range policy is inconsistent\n", stderr);
      return 1;
   }

   if (AppleOpenGLAsahiCanCreateCoreProfile(4, 6) !=
       (state == APPLE_OPENGL_ASAHI_BACKEND_READY)) {
      fprintf(stderr, "GL 4.6 capability disagrees with native backend state\n");
       return 1;
   }

   if (AppleOpenGLAsahiCanPresentWindow() !=
       (state == APPLE_OPENGL_ASAHI_BACKEND_READY)) {
      fprintf(stderr, "window presentation capability disagrees with backend state\n");
      return 1;
   }

   if (state == APPLE_OPENGL_ASAHI_BACKEND_READY) {
      if (blockers != 0) {
         fputs("ready native backend reported context blockers\n", stderr);
         return 1;
      }
   } else if (state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
      uint32_t expected = APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY |
                          APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION |
                          APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION;

      if (blockers != expected) {
         fprintf(stderr, "incomplete backend blockers were %#x, expected %#x\n",
                 blockers, expected);
         return 1;
      }
   } else if (blockers != APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION) {
      fprintf(stderr, "unavailable backend blockers were %#x\n", blockers);
      return 1;
   }

   if (state != APPLE_OPENGL_ASAHI_BACKEND_READY) {
      if (AppleOpenGLAsahiCreateScreen() != NULL) {
         fputs("incomplete native backend created a Mesa screen\n", stderr);
         return 1;
      }

      if (enable_native_bootstrap && strcmp(enable_native_bootstrap, "1") == 0 &&
          state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
         if (!AppleOpenGLAsahiNativeScreenBootstrapIsReady() ||
             AppleOpenGLAsahiDestroyNativeScreenBootstrap() != KERN_SUCCESS) {
            fputs("automatic native bootstrap did not remain fail-closed\n", stderr);
            return 1;
         }
      }
   }

   if (exercise_native_bootstrap &&
       strcmp(exercise_native_bootstrap, "1") == 0 &&
       state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
      if (!AppleOpenGLAsahiBootstrapNativeScreen() ||
          !AppleOpenGLAsahiNativeScreenBootstrapIsReady() ||
          AppleOpenGLAsahiDestroyNativeScreenBootstrap() != KERN_SUCCESS ||
          AppleOpenGLAsahiNativeScreenBootstrapIsReady()) {
         fputs("native screen bootstrap lifecycle failed\n", stderr);
         return 1;
      }
   }

   if (state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE ||
       state == APPLE_OPENGL_ASAHI_BACKEND_READY) {
      if (!session || session->profile == AGX_MACOS_DEVICE_PROFILE_UNSUPPORTED ||
          session->device.connection == IO_OBJECT_NULL) {
         fprintf(stderr, "profiled backend did not retain an AGX session\n");
         return 1;
      }
   } else if (session) {
      fprintf(stderr, "unavailable backend unexpectedly retained an AGX session\n");
      return 1;
   }

   printf("native Asahi backend state: %s\n",
          AppleOpenGLAsahiBackendStateName(state));
   return 0;
}
