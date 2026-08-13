/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>

#include "AppleAGXMetalAllocation.h"
#include "AppleAGXMetalResourceRef.h"
#include "asahi/lib/agx_macos_mesa_device.h"

struct AppleAGXNativeBridge;
struct agx_macos_device_session;

/* This provider makes one public Apple allocation the lifetime root for a
 * CPU-visible Mesa BO. It does not translate GL commands through Metal: the
 * only private operation it enables is the already-profiled resource-list
 * admission of the retained Apple buffer. It intentionally declares neither
 * USC low-VA nor executable-shader capability. */
struct AppleAGXMetalBOProvider {
   const struct AppleAGXNativeBridge *bridge;
   const struct agx_macos_device_session *session;
   struct agx_macos_mesa_bo_provider mesa_provider;
};

bool AppleAGXMetalBOProviderInit(
   struct AppleAGXMetalBOProvider *provider,
   const struct AppleAGXNativeBridge *bridge,
   const struct agx_macos_device_session *session);
bool AppleAGXMetalBOProviderIsCurrent(
   const struct AppleAGXMetalBOProvider *provider);
const struct agx_macos_mesa_bo_provider *
AppleAGXMetalBOProviderMesaProvider(
   const struct AppleAGXMetalBOProvider *provider);

/* Returns the exact retained Apple resource view for a provider-backed Mesa
 * BO. The returned view is borrowed and must not outlive the Mesa BO. */
bool AppleAGXMetalBOProviderReadMesaBOResource(
   const struct AppleAGXMetalBOProvider *provider,
   const struct agx_device *device, const struct agx_bo *bo,
   struct AppleAGXMetalResourceRef *out_ref);
void AppleAGXMetalBOProviderDestroy(struct AppleAGXMetalBOProvider *provider);
