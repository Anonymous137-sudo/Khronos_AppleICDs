/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Mesa libkk kernels AO46 needs for the poly tessellation sequence. */
enum AO46MesaPolyKernel {
   AO46_MESA_POLY_KERNEL_PREFIX_SUM = 0,
   AO46_MESA_POLY_KERNEL_TRIANGLE = 1,
   AO46_MESA_POLY_KERNEL_QUAD = 2,
   AO46_MESA_POLY_KERNEL_ISOLINE = 3,
   AO46_MESA_POLY_KERNEL_COUNT,
};

/* Immutable MSL emitted by Mesa's KosmicKrisp libkk build. */
struct AO46MesaPolyKernelSource {
   const char *msl_source;
   const char *entrypoint;
   uint16_t workgroup_size[3];
   bool requires_gpu_address_root;
};

/*
 * Returns Mesa's generated source only when AO46 is configured with a Mesa
 * build that includes KosmicKrisp libkk artifacts. The kernels use Mesa's
 * original GPU-address root-descriptor ABI, supported by AO46 through public
 * MTLBuffer.gpuAddress on capable macOS hosts.
 */
bool AO46MesaPolyKernelSourceGet(enum AO46MesaPolyKernel kernel,
                                 struct AO46MesaPolyKernelSource *out_source);
