/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMetalBackend.h"

#include "AO46MetalBackend.h"

struct pipe_screen *
AO46MesaMetalBackendCreateScreen(void)
{
   return AO46MetalBackendCreateScreen();
}
