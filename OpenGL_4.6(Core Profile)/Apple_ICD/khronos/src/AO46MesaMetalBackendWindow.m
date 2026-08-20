/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMetalBackend.h"

#include "AO46MetalAdapter.h"
#include "AO46MetalBackend.h"
#include "AO46MetalDrawable.h"
#include "AO46MetalGalliumScreen.h"
#include "AO46MetalWindow.h"

#include "pipe/p_context.h"
#include "pipe/p_state.h"
#include "util/u_inlines.h"

#include <stdlib.h>

struct ao46_mesa_metal_presentation {
   struct AO46MetalSubmission submission;
   struct pipe_resource *source;
   struct ao46_mesa_metal_presentation *next;
};

struct ao46_mesa_metal_window {
   struct AO46MetalWindowLayer layer;
   struct ao46_mesa_metal_presentation *presentations;
   unsigned swap_interval;
};

static struct ao46_mesa_metal_window *
ao46_mesa_metal_window_state(const struct AO46MesaMetalBackendWindow *window)
{
   return window ? window->private_state : NULL;
}

static void
ao46_mesa_metal_window_collect(struct ao46_mesa_metal_window *window,
                               bool wait)
{
   struct ao46_mesa_metal_presentation **cursor;

   if (!window)
      return;

   cursor = &window->presentations;
   while (*cursor) {
      struct ao46_mesa_metal_presentation *frame = *cursor;

      if (!wait && !AO46MetalSubmissionIsComplete(&frame->submission)) {
         cursor = &frame->next;
         continue;
      }

      if (wait)
         (void)AO46MetalSubmissionWait(&frame->submission);
      *cursor = frame->next;
      pipe_resource_reference(&frame->source, NULL);
      AO46MetalSubmissionDestroy(&frame->submission);
      free(frame);
   }
}

static bool
ao46_mesa_metal_window_info(const struct ao46_mesa_metal_window *window,
                            uint32_t *out_width, uint32_t *out_height,
                            enum AO46MesaMetalBackendWindowFormat *out_format)
{
   enum AO46MesaMetalBackendWindowFormat format;

   if (!window || !out_width || !out_height || !out_format ||
       !AO46MetalWindowLayerIsCurrent(&window->layer))
      return false;

   switch (window->layer.format) {
   case AO46_METAL_TEXTURE_FORMAT_RGBA8_UNORM:
      format = AO46_MESA_METAL_BACKEND_WINDOW_RGBA8_UNORM;
      break;
   case AO46_METAL_TEXTURE_FORMAT_BGRA8_UNORM:
      format = AO46_MESA_METAL_BACKEND_WINDOW_BGRA8_UNORM;
      break;
   default:
      return false;
   }

   *out_width = window->layer.width;
   *out_height = window->layer.height;
   *out_format = format;
   return true;
}

bool
AO46MesaMetalBackendWindowAcquire(
   void *native_window, struct AO46MesaMetalBackendWindow *out_window)
{
   const struct AO46MetalAdapter *adapter = AO46MetalBackendGetAdapter();
   struct ao46_mesa_metal_window *window;

   if (!adapter || !native_window || !out_window || out_window->private_state)
      return false;

   window = calloc(1, sizeof(*window));
   if (!window)
      return false;

   if (!AO46MetalWindowLayerAcquire(adapter, native_window, &window->layer)) {
      free(window);
      return false;
   }

   window->swap_interval = 1;
   AO46MetalWindowLayerSetDisplaySync(&window->layer, true);
   out_window->private_state = window;
   return true;
}

bool
AO46MesaMetalBackendWindowIsCurrent(
   const struct AO46MesaMetalBackendWindow *window)
{
   struct ao46_mesa_metal_window *state = ao46_mesa_metal_window_state(window);

   return state && AO46MetalWindowLayerIsCurrent(&state->layer);
}

bool
AO46MesaMetalBackendWindowGetInfo(
   const struct AO46MesaMetalBackendWindow *window, uint32_t *out_width,
   uint32_t *out_height, enum AO46MesaMetalBackendWindowFormat *out_format)
{
   return ao46_mesa_metal_window_info(ao46_mesa_metal_window_state(window),
                                      out_width, out_height, out_format);
}

void
AO46MesaMetalBackendWindowSetSwapInterval(
   const struct AO46MesaMetalBackendWindow *window, unsigned interval)
{
   struct ao46_mesa_metal_window *state = ao46_mesa_metal_window_state(window);

   if (!state || interval > 1)
      return;

   state->swap_interval = interval;
   AO46MetalWindowLayerSetDisplaySync(&state->layer, interval != 0);
}

bool
AO46MesaMetalBackendWindowRefresh(
   void *native_window, struct AO46MesaMetalBackendWindow *window)
{
   struct AO46MesaMetalBackendWindow replacement = {0};
   struct ao46_mesa_metal_window *old_state;

   if (!native_window || !window)
      return false;

   old_state = ao46_mesa_metal_window_state(window);
   if (old_state && AO46MetalWindowLayerIsCurrent(&old_state->layer))
      return true;

   if (!AO46MesaMetalBackendWindowAcquire(native_window, &replacement))
      return false;

   if (old_state) {
      AO46MesaMetalBackendWindowSetSwapInterval(&replacement,
                                                old_state->swap_interval);
      AO46MesaMetalBackendWindowRelease(window);
   }

   *window = replacement;
   return true;
}

bool
AO46MesaMetalBackendWindowPresent(
   struct AO46MesaMetalBackendWindow *window, struct pipe_context *context,
   struct pipe_resource *source)
{
   struct ao46_mesa_metal_window *state = ao46_mesa_metal_window_state(window);
   const struct AO46MetalAdapter *adapter;
   const struct AO46MetalTexture *source_texture;
   struct AO46MetalDrawable drawable = {0};
   struct AO46MetalSubmission submission = {0};
   struct ao46_mesa_metal_presentation *frame = NULL;
   bool presented = false;

   if (!state || !context || !source ||
       !AO46MetalWindowLayerIsCurrent(&state->layer))
      return false;

   adapter = AO46MetalBackendGetAdapter();
   if (!adapter || !AO46MetalGalliumResourceGetMetalTexture(source,
                                                              &source_texture) ||
       !AO46MetalGalliumContextPrepareForExternalMTL4Submission(context))
      return false;

   ao46_mesa_metal_window_collect(state, false);
   if (!AO46MetalDrawableAcquireFromLayer(adapter, state->layer.native_layer,
                                          &drawable))
      goto out;

   if (source_texture->width != drawable.texture.width ||
       source_texture->height != drawable.texture.height ||
       source_texture->format != drawable.texture.format ||
       !AO46MetalTextureCopySubmit(adapter, source_texture, 0, 0,
                                   &drawable.texture, 0, 0,
                                   source_texture->width,
                                   source_texture->height, &submission))
      goto out;

   frame = calloc(1, sizeof(*frame));
   if (!frame || !AO46MetalDrawablePresent(&drawable, &submission))
      goto out;

   pipe_resource_reference(&frame->source, source);
   frame->submission = submission;
   frame->next = state->presentations;
   state->presentations = frame;
   submission = (struct AO46MetalSubmission){0};
   frame = NULL;
   presented = true;

out:
   AO46MetalDrawableRelease(&drawable);
   if (submission.native_command_buffer)
      AO46MetalSubmissionDestroy(&submission);
   free(frame);
   return presented;
}

void
AO46MesaMetalBackendWindowRelease(
   struct AO46MesaMetalBackendWindow *window)
{
   struct ao46_mesa_metal_window *state;

   if (!window)
      return;

   state = ao46_mesa_metal_window_state(window);
   if (!state)
      return;

   ao46_mesa_metal_window_collect(state, true);
   AO46MetalWindowLayerRelease(&state->layer);
   free(state);
   window->private_state = NULL;
}
