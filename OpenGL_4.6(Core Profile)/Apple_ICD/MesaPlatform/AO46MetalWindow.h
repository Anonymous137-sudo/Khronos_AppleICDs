/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "AO46MetalAdapter.h"

enum AO46MetalWindowColorSpace {
   /* The current RGBA8/BGRA8 window path is explicitly sRGB only. */
   AO46_METAL_WINDOW_COLOR_SPACE_SRGB,
};

/* A retained public CAMetalLayer derived from an NSView, NSWindow, or layer. */
struct AO46MetalWindowLayer {
   const struct AO46MetalAdapter *adapter;
   void *native_layer;
   uint32_t width;
   uint32_t height;
   enum AO46MetalTextureFormat format;
   enum AO46MetalWindowColorSpace color_space;
};

bool AO46MetalWindowLayerAcquire(const struct AO46MetalAdapter *adapter,
                                 void *native_window_or_view,
                                 struct AO46MetalWindowLayer *out_layer);
bool AO46MetalWindowLayerIsCurrent(const struct AO46MetalWindowLayer *layer);
void AO46MetalWindowLayerSetDisplaySync(const struct AO46MetalWindowLayer *layer,
                                        bool enabled);
void AO46MetalWindowLayerRelease(struct AO46MetalWindowLayer *layer);
