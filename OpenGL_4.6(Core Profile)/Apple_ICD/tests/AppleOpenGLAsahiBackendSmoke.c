#include "AppleOpenGLAsahi.h"
#include "asahi/lib/agx_macos_device.h"
#include "asahi/lib/agx_macos_mesa_device.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int
verify_phase_statuses(enum AppleOpenGLAsahiBackendState state)
{
   const enum AppleOpenGLAsahiNativePhase phases[] = {
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_BO_AND_VM,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_QUEUE,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_CARRIER_AND_RESOURCES,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_ASAHI_BATCH_SUBMIT,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_FENCE_RETIREMENT,
      APPLE_OPENGL_ASAHI_NATIVE_PHASE_PIPE_SCREEN_AND_PRESENTATION,
   };

   for (unsigned i = 0; i < sizeof(phases) / sizeof(phases[0]); ++i) {
      struct AppleOpenGLAsahiNativePhaseStatus phase_status = {0};

      if (!AppleOpenGLAsahiGetNativePhaseStatus(phases[i], &phase_status) ||
          phase_status.required_readiness == 0 ||
          strcmp(AppleOpenGLAsahiNativePhaseName(phases[i]), "invalid") == 0) {
         fputs("native phase status API rejected a known phase\n", stderr);
         return 1;
      }

      if (state == APPLE_OPENGL_ASAHI_BACKEND_READY) {
         if (phase_status.progress !=
                 APPLE_OPENGL_ASAHI_NATIVE_PHASE_COMPLETE ||
             phase_status.missing_readiness != 0) {
            fputs("ready backend reported an incomplete native phase\n", stderr);
            return 1;
         }
      } else if (state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
         if (phases[i] == APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION) {
            if (phase_status.progress !=
                    APPLE_OPENGL_ASAHI_NATIVE_PHASE_COMPLETE ||
                phase_status.missing_readiness != 0) {
               fputs("profiled device session did not complete phase 2\n",
                     stderr);
               return 1;
            }
         } else if (phase_status.progress !=
                       APPLE_OPENGL_ASAHI_NATIVE_PHASE_PARTIAL ||
                    phase_status.missing_readiness == 0) {
            fputs("incomplete backend misreported a native phase\n", stderr);
            return 1;
         }

         if (phases[i] == APPLE_OPENGL_ASAHI_NATIVE_PHASE_ASAHI_BATCH_SUBMIT &&
             !(phase_status.missing_readiness &
               APPLE_OPENGL_ASAHI_NATIVE_READY_ASAHI_BATCH_EXECUTION)) {
            fputs("phase 6 admitted work without an Asahi execution proof\n",
                  stderr);
            return 1;
         }
         if (phases[i] == APPLE_OPENGL_ASAHI_NATIVE_PHASE_BO_AND_VM &&
             (!(phase_status.missing_readiness &
                APPLE_OPENGL_ASAHI_NATIVE_READY_LOW_VA_BIND) ||
             !(phase_status.missing_readiness &
                APPLE_OPENGL_ASAHI_NATIVE_READY_EXECUTABLE_BO) ||
              !(phase_status.missing_readiness &
                APPLE_OPENGL_ASAHI_NATIVE_READY_SHADER_CODE_ADMISSION))) {
            fputs("phase 3 admitted Mesa shader BOs without native code admission proof\n",
                  stderr);
            return 1;
         }
         if (phases[i] == APPLE_OPENGL_ASAHI_NATIVE_PHASE_FENCE_RETIREMENT &&
             !(phase_status.missing_readiness &
               APPLE_OPENGL_ASAHI_NATIVE_READY_LIVE_FENCE_RETIREMENT)) {
            fputs("phase 7 admitted a fence without live retirement\n", stderr);
            return 1;
         }
         if (phases[i] ==
                APPLE_OPENGL_ASAHI_NATIVE_PHASE_PIPE_SCREEN_AND_PRESENTATION &&
             (!(phase_status.missing_readiness &
                APPLE_OPENGL_ASAHI_NATIVE_READY_PIPE_SCREEN) ||
              !(phase_status.missing_readiness &
                APPLE_OPENGL_ASAHI_NATIVE_READY_PRESENTATION))) {
            fputs("phase 8 admitted a screen or presentation prematurely\n",
                  stderr);
            return 1;
         }
      } else if (phase_status.progress !=
                 APPLE_OPENGL_ASAHI_NATIVE_PHASE_UNAVAILABLE) {
         fputs("unavailable backend reported native phase progress\n", stderr);
         return 1;
      }
   }

   {
      struct AppleOpenGLAsahiNativePhaseStatus invalid = {0};

      if (AppleOpenGLAsahiGetNativePhaseStatus(0, &invalid) ||
          invalid.required_readiness != 0 ||
          strcmp(AppleOpenGLAsahiNativePhaseName(0), "invalid") != 0 ||
          AppleOpenGLAsahiGetNativePhaseStatus(
             APPLE_OPENGL_ASAHI_NATIVE_PHASE_DEVICE_SESSION, NULL)) {
         fputs("native phase status API accepted invalid input\n", stderr);
         return 1;
      }
   }

   return 0;
}

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
   struct AppleOpenGLAsahiNativeDrawableInfo drawable_info = {0};
   struct AppleOpenGLAsahiNativeDrawableLease drawable_lease = {0};
   uint32_t readiness = AppleOpenGLAsahiNativeScreenReadiness();
   uint32_t blockers = AppleOpenGLAsahiContextBlockers();

   if (state == APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED) {
       fprintf(stderr, "unexpected native Asahi backend state: %s\n",
               AppleOpenGLAsahiBackendStateName(state));
       return 1;
   }

   if (verify_phase_statuses(state) != 0)
      return 1;

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

      if (readiness != APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION ||
          blockers != expected) {
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
         uint32_t expected_readiness =
            APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION |
            APPLE_OPENGL_ASAHI_NATIVE_READY_APPLE_BRIDGE |
            APPLE_OPENGL_ASAHI_NATIVE_READY_BOOTSTRAP |
            APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE |
            APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC |
            APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP |
            APPLE_OPENGL_ASAHI_NATIVE_READY_FIXED_BO_BIND |
            APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC |
            APPLE_OPENGL_ASAHI_NATIVE_READY_IOSURFACE_DRAWABLE;

      if (!AppleOpenGLAsahiNativeScreenBootstrapIsReady() ||
             !AppleOpenGLAsahiNativeMesaDeviceIsCurrent() ||
             AppleOpenGLAsahiNativeScreenReadiness() != expected_readiness ||
             AppleOpenGLAsahiNativeMesaDeviceCapabilities() !=
                (AGX_MACOS_MESA_DEVICE_CAP_BO_ALLOC |
                 AGX_MACOS_MESA_DEVICE_CAP_BO_MAP |
                 AGX_MACOS_MESA_DEVICE_CAP_FIXED_BO_BIND |
                 AGX_MACOS_MESA_DEVICE_CAP_COMPLETION_SYNC) ||
             AppleOpenGLAsahiDestroyNativeScreenBootstrap() != KERN_SUCCESS ||
             AppleOpenGLAsahiNativeMesaDeviceIsCurrent() ||
             AppleOpenGLAsahiNativeScreenReadiness() !=
                APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION ||
             AppleOpenGLAsahiNativeMesaDeviceCapabilities() != 0) {
            fputs("automatic native bootstrap did not remain fail-closed\n", stderr);
            return 1;
         }

         if (verify_phase_statuses(state) != 0)
            return 1;
      }
   }

   if (exercise_native_bootstrap &&
       strcmp(exercise_native_bootstrap, "1") == 0 &&
       state == APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE) {
      uint32_t expected_readiness =
         APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION |
         APPLE_OPENGL_ASAHI_NATIVE_READY_APPLE_BRIDGE |
         APPLE_OPENGL_ASAHI_NATIVE_READY_BOOTSTRAP |
         APPLE_OPENGL_ASAHI_NATIVE_READY_MESA_DEVICE |
         APPLE_OPENGL_ASAHI_NATIVE_READY_BO_ALLOC |
         APPLE_OPENGL_ASAHI_NATIVE_READY_BO_MAP |
         APPLE_OPENGL_ASAHI_NATIVE_READY_FIXED_BO_BIND |
         APPLE_OPENGL_ASAHI_NATIVE_READY_COMPLETION_SYNC |
         APPLE_OPENGL_ASAHI_NATIVE_READY_IOSURFACE_DRAWABLE;

      if (!AppleOpenGLAsahiBootstrapMesaDevice() ||
          !AppleOpenGLAsahiNativeScreenBootstrapIsReady() ||
          !AppleOpenGLAsahiNativeMesaDeviceIsCurrent() ||
          AppleOpenGLAsahiNativeScreenReadiness() != expected_readiness ||
          AppleOpenGLAsahiCopyNativeDrawableInfo(&drawable_info) != KERN_SUCCESS ||
          drawable_info.iosurface_id == 0 || drawable_info.width != 1 ||
          drawable_info.height != 1 || drawable_info.bytes_per_row != 4 ||
          drawable_info.generation != 1) {
         fputs("native screen bootstrap lifecycle failed\n", stderr);
         return 1;
      }

      if (AppleOpenGLAsahiAcquireNativeDrawableLease(&drawable_lease) !=
             KERN_SUCCESS ||
          !drawable_lease.winsys.surface ||
          IOSurfaceGetID(drawable_lease.winsys.surface) !=
             drawable_info.iosurface_id ||
          drawable_lease.info.iosurface_id != drawable_lease.winsys.token.id ||
          drawable_lease.info.width != drawable_lease.winsys.width ||
          drawable_lease.info.height != drawable_lease.winsys.height ||
          drawable_lease.info.bytes_per_row !=
             drawable_lease.winsys.bytes_per_row ||
          drawable_lease.info.generation !=
             drawable_lease.winsys.token.generation ||
          !AppleOpenGLAsahiNativeDrawableLeaseIsCurrent(&drawable_lease) ||
          AppleOpenGLAsahiResizeNativeDrawable(8, 4) != KERN_SUCCESS ||
          AppleOpenGLAsahiNativeDrawableLeaseIsCurrent(&drawable_lease)) {
         fputs("native drawable lease did not reject a stale resize\n", stderr);
         AppleOpenGLAsahiReleaseNativeDrawableLease(&drawable_lease);
         return 1;
      }

      AppleOpenGLAsahiReleaseNativeDrawableLease(&drawable_lease);
      if (AppleOpenGLAsahiCopyNativeDrawableInfo(&drawable_info) != KERN_SUCCESS ||
          drawable_info.iosurface_id == 0 || drawable_info.width != 8 ||
          drawable_info.height != 4 || drawable_info.bytes_per_row != 32 ||
          drawable_info.generation != 2 ||
          AppleOpenGLAsahiAcquireNativeDrawableLease(&drawable_lease) !=
             KERN_SUCCESS ||
          !AppleOpenGLAsahiNativeDrawableLeaseIsCurrent(&drawable_lease) ||
          !AppleOpenGLAsahiNativeScreenBootstrapIsReady()) {
         fputs("native drawable lease did not rebind after resize\n", stderr);
         AppleOpenGLAsahiReleaseNativeDrawableLease(&drawable_lease);
         return 1;
      }

      AppleOpenGLAsahiReleaseNativeDrawableLease(&drawable_lease);
      if (AppleOpenGLAsahiDestroyNativeScreenBootstrap() != KERN_SUCCESS ||
          AppleOpenGLAsahiResizeNativeDrawable(8, 4) != kIOReturnNotReady ||
          AppleOpenGLAsahiCopyNativeDrawableInfo(&drawable_info) !=
             kIOReturnNotReady ||
          AppleOpenGLAsahiNativeScreenBootstrapIsReady() ||
          AppleOpenGLAsahiNativeMesaDeviceIsCurrent() ||
          AppleOpenGLAsahiNativeScreenReadiness() !=
             APPLE_OPENGL_ASAHI_NATIVE_READY_SESSION ||
          AppleOpenGLAsahiNativeMesaDeviceCapabilities() != 0) {
         fputs("native screen bootstrap teardown failed\n", stderr);
         return 1;
      }

      if (verify_phase_statuses(state) != 0)
         return 1;
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
