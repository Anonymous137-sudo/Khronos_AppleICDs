/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>

#include "AppleAGXOpaqueCarrier.h"

struct AppleAGXNativeBridge;
struct AppleAGXMetalResourceRef;

/* Apple-created queue and command-buffer state that owns a configured command
 * storage allocation. It is intentionally not a submission interface and
 * never creates an encoder or sends GPU work. */
struct AppleAGXConfiguredCarrier {
   const struct AppleAGXNativeBridge *bridge;
   void *queue;
   void *command_buffer;
   void *queue_descriptor;
   void *storage;
};

/* Kernel-command storage owned and initialized by Apple's command-buffer
 * factory. The pointers remain opaque to AO46; this view only validates the
 * range exposed by the profiled runtime getter. */
struct AppleAGXConfiguredCarrierKernelCommands {
   void *start;
   void *current;
   void *end;
};

bool AppleAGXConfiguredCarrierCreate(
   const struct AppleAGXNativeBridge *bridge,
   struct AppleAGXConfiguredCarrier *out_carrier);
bool AppleAGXConfiguredCarrierIsCurrent(
   const struct AppleAGXConfiguredCarrier *carrier);
bool AppleAGXConfiguredCarrierSnapshotRead(
   const struct AppleAGXConfiguredCarrier *carrier,
   struct AppleAGXOpaqueCarrierSnapshot *out_snapshot);
bool AppleAGXConfiguredCarrierKernelCommandsRead(
   const struct AppleAGXConfiguredCarrier *carrier,
   struct AppleAGXConfiguredCarrierKernelCommands *out_commands);
/* Performs exactly one direct storage-level begin/end segment pair using the
 * validated Apple-owned command range. It admits no resources, writes no
 * command bytes, and never commits or submits the carrier. */
bool AppleAGXConfiguredCarrierNoResourceSegmentSmoke(
   const struct AppleAGXConfiguredCarrier *carrier);
/* Admits one existing Apple-owned MTLBuffer binding to the carrier resource
 * list during a balanced segment lifecycle. The caller retains the buffer;
 * this does not encode commands, commit a queue, or submit GPU work. */
bool AppleAGXConfiguredCarrierAddMetalResource(
   const struct AppleAGXConfiguredCarrier *carrier,
   const struct AppleAGXMetalResourceRef *resource_ref);
void AppleAGXConfiguredCarrierDestroy(
   struct AppleAGXConfiguredCarrier *carrier);
