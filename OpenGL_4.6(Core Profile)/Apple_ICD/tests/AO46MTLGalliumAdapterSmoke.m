/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import "mtl_pub.h"

#include "AO46MTLGallium.h"

#include "pipe/p_context.h"
#include "pipe/p_screen.h"

#include <stdio.h>

int
main(void)
{
   struct AO46MetalAdapter adapter = {0};
   struct pipe_screen *screen = NULL;
   struct pipe_context *context = NULL;
   int failed = 0;

   if (!AO46MetalAdapterCreate(&adapter)) {
      fputs("AO46 Gallium adapter smoke could not create the Metal adapter\n",
            stderr);
      return 1;
   }

   screen = AO46MTLGalliumScreenCreate(&adapter);
   context = screen ? screen->context_create(screen, NULL, 0) : NULL;
   if (!screen || !context || !screen->get_name || !screen->get_vendor ||
       !screen->get_name(screen)[0] || !screen->get_vendor(screen)[0] ||
       (__bridge void *)g_mtl_device != adapter.device ||
       (__bridge void *)g_mtl_queue != adapter.queue) {
      fputs("AO46 Gallium adapter smoke did not retain the adapter Metal path\n",
            stderr);
      failed = 1;
      goto out;
   }

out:
   if (context)
      context->destroy(context);
   if (screen)
      screen->destroy(screen);
   if (!failed && (g_mtl_device != nil || g_mtl_queue != nil)) {
      fputs("AO46 Gallium adapter smoke did not release the borrowed Metal path\n",
            stderr);
      failed = 1;
   }
   AO46MetalAdapterDestroy(&adapter);
   return failed;
}
