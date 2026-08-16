/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

struct pipe_screen;
struct AO46MetalAdapter;

enum AO46MetalBackendState {
   AO46_METAL_BACKEND_UNINITIALIZED = 0,
   AO46_METAL_BACKEND_NO_DEVICE,
   AO46_METAL_BACKEND_ADAPTER_READY,
   AO46_METAL_BACKEND_PIPE_SCREEN_INCOMPLETE,
   AO46_METAL_BACKEND_PIPE_SCREEN_READY,
};

enum AO46MetalContextBlocker {
   AO46_METAL_CONTEXT_BLOCKER_DEVICE = 1u << 0,
    AO46_METAL_CONTEXT_BLOCKER_PIPE_SCREEN = 1u << 1,
    AO46_METAL_CONTEXT_BLOCKER_PIPE_CONTEXT = 1u << 2,
    AO46_METAL_CONTEXT_BLOCKER_PRESENTATION = 1u << 3,
    /* Mesa currently realizes the promoted driver as core 3.3, not 4.6. */
    AO46_METAL_CONTEXT_BLOCKER_GL46_CAPABILITY = 1u << 4,
};

enum AO46MetalBackendState AO46MetalBackendInitialize(void);
const char *AO46MetalBackendStateName(enum AO46MetalBackendState state);
uint32_t AO46MetalBackendContextBlockers(void);
bool AO46MetalBackendAdapterIsReady(void);
bool AO46MetalBackendCanPresentWindow(void);
/* Shared execution adapter owned by the active Mesa Gallium screen. */
const struct AO46MetalAdapter *AO46MetalBackendGetAdapter(void);

/*
 * The active screen factory. It returns the promoted Mesa-facing Gallium
 * screen over the shared AO46 Metal adapter. This admits offscreen CGL/Mesa
 * contexts; window presentation remains separately profile-gated.
 */
struct pipe_screen *AO46MetalBackendCreateScreen(void);
