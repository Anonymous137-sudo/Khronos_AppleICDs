/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MetalBackend.h"

#include "AO46MetalAdapter.h"
#include "AO46MTLGallium.h"

#include <pthread.h>

static pthread_mutex_t ao46_metal_backend_lock = PTHREAD_MUTEX_INITIALIZER;
static struct AO46MetalAdapter ao46_metal_adapter;
static struct pipe_screen *ao46_metal_screen;
static enum AO46MetalBackendState ao46_metal_backend_state =
   AO46_METAL_BACKEND_UNINITIALIZED;

enum AO46MetalBackendState
AO46MetalBackendInitialize(void)
{
   pthread_mutex_lock(&ao46_metal_backend_lock);
   if (ao46_metal_backend_state == AO46_METAL_BACKEND_UNINITIALIZED) {
      if (!AO46MetalAdapterCreate(&ao46_metal_adapter))
         ao46_metal_backend_state = AO46_METAL_BACKEND_NO_DEVICE;
      else
         ao46_metal_backend_state = AO46_METAL_BACKEND_ADAPTER_READY;
   }
   pthread_mutex_unlock(&ao46_metal_backend_lock);
   return ao46_metal_backend_state;
}

const char *
AO46MetalBackendStateName(enum AO46MetalBackendState state)
{
   switch (state) {
   case AO46_METAL_BACKEND_UNINITIALIZED:
      return "uninitialized";
   case AO46_METAL_BACKEND_NO_DEVICE:
      return "no-metal-device";
   case AO46_METAL_BACKEND_ADAPTER_READY:
      return "adapter-ready";
   case AO46_METAL_BACKEND_PIPE_SCREEN_INCOMPLETE:
      return "pipe-screen-incomplete";
   case AO46_METAL_BACKEND_PIPE_SCREEN_READY:
      return "pipe-screen-ready";
   }

   return "invalid";
}

uint32_t
AO46MetalBackendContextBlockers(void)
{
   switch (AO46MetalBackendInitialize()) {
   case AO46_METAL_BACKEND_NO_DEVICE:
      return AO46_METAL_CONTEXT_BLOCKER_DEVICE |
             AO46_METAL_CONTEXT_BLOCKER_PIPE_SCREEN |
             AO46_METAL_CONTEXT_BLOCKER_PIPE_CONTEXT |
             AO46_METAL_CONTEXT_BLOCKER_PRESENTATION;
   case AO46_METAL_BACKEND_ADAPTER_READY:
   case AO46_METAL_BACKEND_PIPE_SCREEN_INCOMPLETE:
      return AO46_METAL_CONTEXT_BLOCKER_PIPE_SCREEN |
             AO46_METAL_CONTEXT_BLOCKER_PIPE_CONTEXT |
             AO46_METAL_CONTEXT_BLOCKER_PRESENTATION;
   case AO46_METAL_BACKEND_PIPE_SCREEN_READY:
      /* The driver routes supported core contexts, but Mesa has not yet
       * audited this Gallium capability set as sufficient for GL 4.6. */
      return AO46_METAL_CONTEXT_BLOCKER_GL46_CAPABILITY;
   case AO46_METAL_BACKEND_UNINITIALIZED:
      break;
   }

   return AO46_METAL_CONTEXT_BLOCKER_DEVICE |
          AO46_METAL_CONTEXT_BLOCKER_PIPE_SCREEN |
          AO46_METAL_CONTEXT_BLOCKER_PIPE_CONTEXT |
          AO46_METAL_CONTEXT_BLOCKER_PRESENTATION;
}

bool
AO46MetalBackendAdapterIsReady(void)
{
   enum AO46MetalBackendState state = AO46MetalBackendInitialize();

   return state == AO46_METAL_BACKEND_ADAPTER_READY ||
          state == AO46_METAL_BACKEND_PIPE_SCREEN_INCOMPLETE ||
          state == AO46_METAL_BACKEND_PIPE_SCREEN_READY;
}

bool
AO46MetalBackendCanPresentWindow(void)
{
   /* Presentation requires the same live Metal pipe_screen as CGL contexts. */
   return (AO46MetalBackendContextBlockers() &
           (AO46_METAL_CONTEXT_BLOCKER_PIPE_CONTEXT |
            AO46_METAL_CONTEXT_BLOCKER_PRESENTATION)) == 0;
}

const struct AO46MetalAdapter *
AO46MetalBackendGetAdapter(void)
{
   if (!AO46MetalBackendAdapterIsReady())
      return NULL;

   return &ao46_metal_adapter;
}

struct pipe_screen *
AO46MetalBackendCreateScreen(void)
{
   if (AO46MetalBackendInitialize() == AO46_METAL_BACKEND_NO_DEVICE)
      return NULL;

   pthread_mutex_lock(&ao46_metal_backend_lock);
   if (!ao46_metal_screen) {
      ao46_metal_screen = AO46MTLGalliumScreenCreate(&ao46_metal_adapter);
      ao46_metal_backend_state = ao46_metal_screen
                                    ? AO46_METAL_BACKEND_PIPE_SCREEN_READY
                                    : AO46_METAL_BACKEND_PIPE_SCREEN_INCOMPLETE;
   }
   pthread_mutex_unlock(&ao46_metal_backend_lock);

   return ao46_metal_screen;
}
