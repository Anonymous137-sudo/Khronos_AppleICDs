/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#include "AO46MesaPolyKernelCatalog.h"

#if AO46_HAVE_MESA_LIBKK
#include "libkk_shaders.h"

#include "kosmickrisp/clc/kk_precompiled_shader.h"
#endif

bool
AO46MesaPolyKernelSourceGet(enum AO46MesaPolyKernel kernel,
                            struct AO46MesaPolyKernelSource *out_source)
{
#if AO46_HAVE_MESA_LIBKK
   enum libkk_program program;
   const uint32_t *binary;
   const struct kk_precompiled_info *info;

   if (!out_source)
      return false;

   switch (kernel) {
   case AO46_MESA_POLY_KERNEL_PREFIX_SUM:
      program = LIBKK_PREFIX_SUM_TESS;
      break;
   case AO46_MESA_POLY_KERNEL_TRIANGLE:
      program = LIBKK_TESS_TRI;
      break;
   case AO46_MESA_POLY_KERNEL_QUAD:
      program = LIBKK_TESS_QUAD;
      break;
   case AO46_MESA_POLY_KERNEL_ISOLINE:
      program = LIBKK_TESS_ISOLINE;
      break;
   default:
      return false;
   }

   binary = libkk_AppleSilicon[program];
   if (!binary)
      return false;

   info = (const struct kk_precompiled_info *)binary;
   if (info->workgroup_size[0] == 0 || info->workgroup_size[1] == 0 ||
       info->workgroup_size[2] == 0)
      return false;

   *out_source = (struct AO46MesaPolyKernelSource){
      .msl_source = (const char *)binary + sizeof(*info),
      .entrypoint = "main_entrypoint",
      .workgroup_size = {
         info->workgroup_size[0],
         info->workgroup_size[1],
         info->workgroup_size[2],
      },
      .requires_gpu_address_root = true,
   };
   return true;
#else
   (void)kernel;
   (void)out_source;
   return false;
#endif
}
