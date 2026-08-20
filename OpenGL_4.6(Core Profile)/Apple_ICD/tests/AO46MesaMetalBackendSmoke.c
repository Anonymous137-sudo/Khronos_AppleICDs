/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaMetalBackend.h"

#include "pipe/p_screen.h"

#include <stdio.h>
#include <string.h>

int
main(void)
{
   struct pipe_screen *screen = AO46MesaMetalBackendCreateScreen();

   if (!screen || !screen->get_name) {
      fprintf(stderr, "AO46 Mesa backend did not create a Gallium screen\n");
      return 1;
   }

   if (strcmp(screen->get_name(screen), "AO46 Metal Gallium") != 0) {
      fprintf(stderr, "unexpected Gallium screen name: %s\n",
              screen->get_name(screen));
      return 1;
   }

   return 0;
}
