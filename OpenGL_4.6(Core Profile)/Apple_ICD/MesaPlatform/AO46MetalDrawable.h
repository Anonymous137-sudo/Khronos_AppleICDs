/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include "AO46MetalAdapter.h"

/*
 * A frame-scoped CAMetalDrawable. Its texture is a normal AO46 render target,
 * while the drawable handle owns the matching presentation lifetime.
 */
struct AO46MetalDrawable {
   const struct AO46MetalAdapter *adapter;
   void *native_drawable;
   struct AO46MetalTexture texture;
   uint64_t generation;
   bool retained_by_submission;
};

/* Acquires a drawable from a caller-owned CAMetalLayer on AO46's device. */
bool AO46MetalDrawableAcquireFromLayer(
   const struct AO46MetalAdapter *adapter, void *native_metal_layer,
   struct AO46MetalDrawable *out_drawable);

bool AO46MetalDrawableIsCurrent(const struct AO46MetalDrawable *drawable);
void AO46MetalDrawableRelease(struct AO46MetalDrawable *drawable);

/* Presents an already submitted frame. MTL4 presentation stays GPU ordered. */
bool AO46MetalDrawablePresent(struct AO46MetalDrawable *drawable,
                              struct AO46MetalSubmission *submission);
