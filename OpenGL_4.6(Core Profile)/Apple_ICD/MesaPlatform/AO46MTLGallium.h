/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include "AO46MetalAdapter.h"

struct pipe_screen;

/*
 * Creates the Mesa-facing Gallium screen over an adapter-owned Metal device
 * and queue. The adapter must outlive every screen and context it creates.
 */
struct pipe_screen *AO46MTLGalliumScreenCreate(
   const struct AO46MetalAdapter *adapter);
