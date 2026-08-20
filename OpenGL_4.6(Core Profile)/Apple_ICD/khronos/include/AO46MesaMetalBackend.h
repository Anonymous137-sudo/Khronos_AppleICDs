/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/*
 * Internal backend boundary for Mesa's AO46 Gallium registration.  The
 * declaration purposefully contains no CGL, NSOpenGL, EGL, or GL API types.
 */

struct pipe_context;
struct pipe_resource;
struct pipe_screen;

enum AO46MesaMetalBackendWindowFormat {
   AO46_MESA_METAL_BACKEND_WINDOW_RGBA8_UNORM,
   AO46_MESA_METAL_BACKEND_WINDOW_BGRA8_UNORM,
};

/*
 * An opaque, retained public CAMetalLayer lifecycle for Mesa's EGL driver.
 * Applications still pass a standard native window handle to eglCreateWindowSurface;
 * this state never exposes CGL, NSOpenGL, or framework ABI objects.
 */
struct AO46MesaMetalBackendWindow {
   void *private_state;
};

#ifdef __cplusplus
extern "C" {
#endif

struct pipe_screen *AO46MesaMetalBackendCreateScreen(void);

bool AO46MesaMetalBackendWindowAcquire(
   void *native_window, struct AO46MesaMetalBackendWindow *out_window);
bool AO46MesaMetalBackendWindowIsCurrent(
   const struct AO46MesaMetalBackendWindow *window);
bool AO46MesaMetalBackendWindowGetInfo(
   const struct AO46MesaMetalBackendWindow *window, uint32_t *out_width,
   uint32_t *out_height, enum AO46MesaMetalBackendWindowFormat *out_format);
void AO46MesaMetalBackendWindowSetSwapInterval(
   const struct AO46MesaMetalBackendWindow *window, unsigned interval);
bool AO46MesaMetalBackendWindowRefresh(
   void *native_window, struct AO46MesaMetalBackendWindow *window);
bool AO46MesaMetalBackendWindowPresent(
   struct AO46MesaMetalBackendWindow *window, struct pipe_context *context,
   struct pipe_resource *source);
void AO46MesaMetalBackendWindowRelease(
   struct AO46MesaMetalBackendWindow *window);

#ifdef __cplusplus
}
#endif
